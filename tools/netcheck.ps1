#requires -Version 5.1
<#
  netcheck.ps1 - Clash Verge / network self-check.

  Diagnoses: process, mixed port 7897, system proxy, direct-vs-proxy reachability.
  ASCII-only on purpose (Windows PowerShell 5.1 reads non-BOM files as ANSI).
#>
[CmdletBinding()]
param(
  [int]$Port = 7897,
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$proxyUrl = "http://127.0.0.1:$Port"

function Write-Head($t) { Write-Host ""; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Ok($t)   { Write-Host ("  [ok]   " + $t) -ForegroundColor Green }
function Warn($t) { Write-Host ("  [warn] " + $t) -ForegroundColor Yellow }
function Bad($t)  { Write-Host ("  [FAIL] " + $t) -ForegroundColor Red }
function Info($t) { Write-Host ("         " + $t) -ForegroundColor DarkGray }

$problems = New-Object System.Collections.ArrayList

# ---------- 1. processes ----------
Write-Head "1. Clash Verge processes"
$core = Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue
$app  = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue
if ($core) { Ok ("verge-mihomo pid=" + ($core.Id -join ',')) } else { Bad "verge-mihomo NOT running"; [void]$problems.Add('core-down') }
if ($app)  { Ok ("clash-verge  pid=" + ($app.Id -join ',')) } else { Warn "clash-verge (GUI) not running - core may still work" }

# ---------- 2. port ----------
Write-Head "2. Mixed port $Port"
$listening = $false
try {
  $c = New-Object System.Net.Sockets.TcpClient
  $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
  $listening = $iar.AsyncWaitHandle.WaitOne(1500) -and $c.Connected
  $c.Close()
} catch { $listening = $false }
if ($listening) { Ok "127.0.0.1:$Port accepting connections" }
else { Bad "127.0.0.1:$Port closed - proxy is OFF (start Verge / enable system proxy)"; [void]$problems.Add('port-closed') }

# ---------- 3. system proxy ----------
Write-Head "3. Windows system proxy"
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$p = Get-ItemProperty $k -ErrorAction SilentlyContinue
if ($p.ProxyEnable -eq 1) {
  Ok ("ProxyEnable=1  ProxyServer=" + $p.ProxyServer)
  if ($p.ProxyServer -notmatch [regex]::Escape(":$Port")) { Warn "system proxy port differs from $Port" }
} else {
  Warn "ProxyEnable=0 - GUI apps will go direct"
  [void]$problems.Add('sysproxy-off')
}

# ---------- 4. reachability matrix ----------
Write-Head "4. Reachability: direct vs proxy"
$targets = @(
  @{ n = 'api.github.com';    u = 'https://api.github.com/zen' },
  @{ n = 'github.com';        u = 'https://github.com/' },
  @{ n = 'raw.github';        u = 'https://raw.githubusercontent.com/git/git/master/README.md' },
  @{ n = 'google-204';        u = 'https://www.gstatic.com/generate_204' },
  @{ n = 'openai';            u = 'https://api.openai.com/v1/models' },
  @{ n = 'npm-registry';      u = 'https://registry.npmjs.org/' },
  @{ n = 'pypi';              u = 'https://pypi.org/simple/' },
  @{ n = 'baidu (domestic)';  u = 'https://www.baidu.com/' }
)

$rows = @()
foreach ($t in $targets) {
  $d = 'err'; $x = 'err'
  if ($env:NO_DIRECT -ne '1') {
    $d = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 8 --noproxy '*' $t.u 2>$null)
  }
  if ($listening) {
    $x = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 12 -x $proxyUrl $t.u 2>$null)
  }
  $rows += [pscustomobject]@{ Target = $t.n; Direct = $d; Proxy = $x }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

$proxyFail = @($rows | Where-Object { $_.Proxy -eq '000' -or $_.Proxy -eq 'err' }).Count
$proxyOk   = @($rows | Where-Object { $_.Proxy -match '^[1234]\d\d$' }).Count
if ($listening) {
  if ($proxyFail -eq 0) { Ok ("all $($rows.Count) targets reachable through proxy") }
  else { Bad ("$proxyFail target(s) unreachable through proxy") ; [void]$problems.Add('proxy-blocked') }
}

# ---------- 5. verdict ----------
Write-Head "Verdict"
if ($problems.Count -eq 0) {
  Ok "network looks healthy"
} else {
  Warn ("issues: " + ($problems -join ', '))
  Info "core-down    -> Start-Process 'C:\Program Files\Clash Verge\clash-verge.exe'"
  Info "port-closed  -> Verge GUI: turn on system proxy / restart core"
  Info "proxy-blocked-> node dead: node ~/.dsh/tools/clash.mjs best Proxies"
  Info "                 or service group pinned to DIRECT: clash.mjs use GitHub Proxies"
}
Info "env vars: `$env:HTTPS_PROXY='$proxyUrl'  (node fetch also needs NODE_USE_ENV_PROXY=1)"

if ($problems.Count -gt 0) { exit 1 } else { exit 0 }
