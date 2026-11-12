#requires -Version 5.1
<#
  netcheck.ps1 - Clash Verge / network self-check (and self-heal).

  Checks: kernel pipe -> mixed port -> Windows system proxy -> direct-vs-proxy
          reachability -> proxy egress IP.  Starts Clash Verge automatically
          when the kernel is down (use -NoStart to skip).

  Always exits 0; parse the final "VERDICT: ok|degraded|down" line instead.
  ASCII-only on purpose (Windows PowerShell 5.1 reads non-BOM files as ANSI).
#>
[CmdletBinding()]
param(
  [string]$Port,
  [switch]$NoStart,
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$Tools = Join-Path $env:USERPROFILE '.dsh\tools'
$Clash = Join-Path $Tools 'clash.mjs'
$VergeExe = 'C:\Program Files\Clash Verge\clash-verge.exe'
$issues = New-Object System.Collections.ArrayList

function Write-Head($t) { if (-not $Quiet) { Write-Host ""; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan } }
function Ok($t)   { if (-not $Quiet) { Write-Host ("  [ok]   " + $t) -ForegroundColor Green } }
function Warn($t) { if (-not $Quiet) { Write-Host ("  [warn] " + $t) -ForegroundColor Yellow } }
function Bad($t)  { if (-not $Quiet) { Write-Host ("  [FAIL] " + $t) -ForegroundColor Red } }
function Info($t) { if (-not $Quiet) { Write-Host ("         " + $t) -ForegroundColor DarkGray } }

function Test-PortOpen([int]$p) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
    $open = $iar.AsyncWaitHandle.WaitOne(1200) -and $c.Connected
    $c.Close()
    return $open
  } catch { return $false }
}

function Get-Curl($url, [string]$ProxyUrl) {
  $a = @('-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', '12')
  if ($ProxyUrl) { $a += @('-x', $ProxyUrl) } else { $a += '--noproxy' ; $a += '*' }
  $a += $url
  $r = & curl.exe @a 2>$null
  if (-not $r) { return '000' }
  return ($r | Select-Object -Last 1)
}

function Get-EgressIp([string]$ProxyUrl) {
  # several services: one of them is usually rate-limited by the shared exit IP
  foreach ($u in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
    $a = @('-s', '--max-time', '10')
    if ($ProxyUrl) { $a += @('-x', $ProxyUrl) } else { $a += '--noproxy' ; $a += '*' }
    $a += $u
    $r = & curl.exe @a 2>$null
    if ($r) {
      $ip = (($r | Out-String).Trim() -split '\s+')[0]
      if ($ip -match '^[0-9a-fA-F:.]{7,}$') { return $ip }
    }
  }
  return ''
}

# ---------------------------------------------------------------- 1. kernel
Write-Head '1. mihomo kernel'

$coreUp = $false
$pipe = $null
if (Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) {
  $pipe = ((Get-ChildItem '\\.\pipe\' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^verge-mihomo-' } |
            Select-Object -ExpandProperty Name) -join ', ')
}
if ($pipe) { $coreUp = $true; Ok "kernel pipe: $pipe" } else { Warn 'kernel pipe not found' }

if (-not $coreUp -and -not $NoStart) {
  Info 'starting Clash Verge ...'
  $nodeOk = (Get-Command node -ErrorAction SilentlyContinue)
  if ($nodeOk) {
    & node $Clash start 2>&1 | ForEach-Object { Info $_ }
    $pipe = ((Get-ChildItem '\\.\pipe\' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^verge-mihomo-' } |
              Select-Object -ExpandProperty Name) -join ', ')
    if ($pipe) { $coreUp = $true; Ok 'kernel came up after auto-start' }
  } elseif (Test-Path $VergeExe) {
    Start-Process $VergeExe
    Start-Sleep -Seconds 12
    $pipe = ((Get-ChildItem '\\.\pipe\' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^verge-mihomo-' } |
              Select-Object -ExpandProperty Name) -join ', ')
    if ($pipe) { $coreUp = $true; Ok 'kernel came up after auto-start' }
  }
}
if (-not $coreUp) { Bad 'kernel is down (auto-start failed or -NoStart)'; [void]$issues.Add('kernel-down') }

# ------------------------------------------------------------------ 2. port
Write-Head '2. mixed port'

if (-not $Port) {
  $p = ''
  if (Get-Command node -ErrorAction SilentlyContinue) { $p = (& node $Clash port 2>$null | Select-Object -Last 1) }
  if ($p -match '^\d+$') { $Port = [int]$p } else { $Port = 7897 }
}
$proxyUrl = "http://127.0.0.1:$Port"
if (Test-PortOpen $Port) {
  Ok "127.0.0.1:$Port accepting connections"
} else {
  Bad "127.0.0.1:$Port closed - proxy is OFF"
  [void]$issues.Add('port-closed')
}

# --------------------------------------------------------- 3. system proxy
Write-Head '3. Windows system proxy'
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$p = Get-ItemProperty $k -ErrorAction SilentlyContinue
if ($p.ProxyEnable -eq 1) {
  Ok "ProxyEnable=1  ProxyServer=$($p.ProxyServer)"
  if ($p.ProxyServer -notmatch [regex]::Escape(":$Port")) {
    Warn "system proxy port differs from $Port"
    [void]$issues.Add('sysproxy-mismatch')
  }
} else {
  Warn 'ProxyEnable=0 - GUI apps go direct'
  [void]$issues.Add('sysproxy-off')
}

# -------------------------------------------------------- 4. reachability
Write-Head '4. Reachability: direct vs proxy'
$targets = @(
  @{ n = 'api.github.com';   u = 'https://api.github.com/zen' },
  @{ n = 'github.com';       u = 'https://github.com/' },
  @{ n = 'raw.github';       u = 'https://raw.githubusercontent.com/git/git/master/README.md' },
  @{ n = 'google-204';       u = 'https://www.gstatic.com/generate_204' },
  @{ n = 'openai';           u = 'https://api.openai.com/v1/models' },
  @{ n = 'npm-registry';     u = 'https://registry.npmjs.org/' },
  @{ n = 'pypi';             u = 'https://pypi.org/simple/' },
  @{ n = 'baidu (domestic)'; u = 'https://www.baidu.com/' }
)

$rows = @()
foreach ($t in $targets) {
  $d = '000'
  if (-not $env:NO_DIRECT -and -not $env:NO_DIRECT_CHECK) { $d = Get-Curl $t.u '' }
  $x = '000'
  if (Test-PortOpen $Port) { $x = Get-Curl $t.u $proxyUrl }
  $rows += [pscustomobject]@{ Target = $t.n; Direct = $d; Proxy = $x }
}
if (-not $Quiet) { $rows | Format-Table -AutoSize | Out-String | Write-Host }

$proxyOkCount = @($rows | Where-Object { $_.Proxy -match '^[1-5]\d\d$' }).Count
$proxyDeadCount = @($rows | Where-Object { $_.Proxy -eq '000' }).Count
if (Test-PortOpen $Port) {
  if ($proxyDeadCount -eq 0) { Ok "all $($rows.Count) targets answered through proxy" }
  else { Bad "$proxyDeadCount target(s) got no answer through proxy"; [void]$issues.Add('proxy-blocked') }
}

# ------------------------------------------------------------- 5. egress
Write-Head '5. Egress IP'
$ipProxy = ''
if (Test-PortOpen $Port) { $ipProxy = Get-EgressIp $proxyUrl }
if ($ipProxy) { Ok "via proxy : $ipProxy" } else { Warn 'via proxy : (no answer)' }
if ($env:NO_DIRECT -ne '1' -and -not $env:NO_DIRECT_CHECK) {
  $ipDirect = Get-EgressIp ''
  if ($ipDirect) {
    Info "direct    : $ipDirect"
    if ($ipDirect -eq $ipProxy) { Warn 'same IP both ways - proxy may not be tunnelling' ; [void]$issues.Add('not-tunnelling') }
  } else {
    Info 'direct    : (blocked, expected in CN)'
  }
}

# ---------------------------------------------------------------- verdict
Write-Head 'Verdict'
$verdict = 'ok'
if (@($issues | Where-Object { $_ -in @('kernel-down', 'port-closed') }).Count -gt 0) { $verdict = 'down' }
elseif ($issues.Count -gt 0) { $verdict = 'degraded' }

switch ($verdict) {
  'ok' { Ok 'network healthy' }
  'degraded' { Warn ('issues: ' + ($issues -join ', ')) }
  'down' { Bad ('issues: ' + ($issues -join ', ')) }
}
if ($verdict -ne 'ok') {
  Info 'kernel-down  -> Start-Process "C:\Program Files\Clash Verge\clash-verge.exe"'
  Info 'port-closed  -> open Verge UI and switch the kernel on'
  Info 'proxy-blocked-> node ~/.dsh/tools/clash.mjs best Proxies   (all fail = subscription expired)'
  Info 'sysproxy-*   -> node ~/.dsh/tools/clash.mjs status ; fix in Verge UI settings'
}
Write-Host "VERDICT: $verdict"
exit 0
