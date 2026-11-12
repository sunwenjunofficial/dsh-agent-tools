#requires -Version 5.1
<#
  github.ps1 - publish a project to GitHub with version control.

  Actions:
    token-save   store a PAT encrypted with DPAPI (current Windows user only)
    token-check  report whether a token is stored
    whoami       verify the token against the GitHub API
    ignore       create/repair .gitignore for a project
    audit        scan a project for secrets / huge files (no git changes)
    publish      commit + tag + push (creates the repo on first run)

  Examples:
    powershell -File github.ps1 -Action token-save -Token ghp_xxx
    powershell -File github.ps1 -Action whoami
    powershell -File github.ps1 -Action publish -ProjectPath .\rawmate -Message "feat: card status" -Bump patch

  ASCII-only on purpose (Windows PowerShell 5.1 reads non-BOM files as ANSI).
#>
[CmdletBinding(DefaultParameterSetName = 'run')]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('token-save', 'token-check', 'token-clear', 'whoami', 'ignore', 'audit', 'publish', 'status')]
  [string]$Action,

  [string]$Token,
  [string]$ProjectPath = '.',
  [string]$Message,
  [ValidateSet('patch', 'minor', 'major', 'none')]
  [string]$Bump = 'patch',
  [string]$RepoName,
  [string]$Description = '',
  [switch]$Private,
  [switch]$NoPush,
  [switch]$Force,
  [switch]$WhatIf
)

# 'Continue': git writes to stderr on perfectly normal situations (unborn HEAD,
# no tags yet) and EAP=Stop would turn those into terminating errors.
$ErrorActionPreference = 'Continue'
$SecretDir = Join-Path $env:USERPROFILE '.dsh\secrets'
$TokenFile = Join-Path $SecretDir 'github-token.bin'
$script:CachedProxyUrl = $null

function Get-ProxyUrl {
  # ask the Clash tool for the live mixed port; fall back to the documented default
  if ($script:CachedProxyUrl) { return $script:CachedProxyUrl }
  $port = 0
  $clash = Join-Path $env:USERPROFILE '.dsh\tools\clash.mjs'
  if ((Test-Path $clash) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    $out = & node $clash port 2>$null
    if ($out -match '^\s*(\d+)\s*$') { $port = [int]$Matches[1] }
  }
  if ($port -le 0) { $port = 7897 }
  $script:CachedProxyUrl = "http://127.0.0.1:$port"
  return $script:CachedProxyUrl
}
$GhUser = 'sunwenjunofficial'

# ---------------------------------------------------------------- token (DPAPI)

function Add-SecurityAssembly {
  Add-Type -AssemblyName System.Security -ErrorAction Stop
}

function Save-Token {
  param([string]$Plain)
  if (-not $Plain) { throw 'token is empty' }
  if ($Plain -notmatch '^(ghp_|github_pat_)') { throw 'token should start with ghp_ or github_pat_' }
  Add-SecurityAssembly
  if (-not (Test-Path $SecretDir)) { New-Item -ItemType Directory -Path $SecretDir -Force | Out-Null }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
  $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser')
  [System.IO.File]::WriteAllBytes($TokenFile, $enc)
  Write-Host ("[ok] token stored (DPAPI) -> " + $TokenFile) -ForegroundColor Green
  Write-Host "     readable only by this Windows user on this machine"
}

function Get-Token {
  if (-not (Test-Path $TokenFile)) { return $null }
  Add-SecurityAssembly
  $enc = [System.IO.File]::ReadAllBytes($TokenFile)
  $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, 'CurrentUser')
  return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Require-Token {
  $t = Get-Token
  if (-not $t) { throw "no GitHub token stored. run: github.ps1 -Action token-save -Token <PAT>" }
  return $t
}

# ------------------------------------------------------------------ GitHub API

function Invoke-GitHubApi {
  param(
    [string]$Method = 'GET',
    [string]$Path,
    $Body = $null,
    [switch]$AllowFail
  )
  $t = Require-Token
  $params = @{
    Uri         = 'https://api.github.com' + $Path
    Method      = $Method
    Headers     = @{
      Authorization          = "Bearer $t"
      Accept                 = 'application/vnd.github+json'
      'User-Agent'           = 'dsh-agent'
      'X-GitHub-Api-Version' = '2022-11-28'
    }
    TimeoutSec  = 30
    ErrorAction = 'Stop'
  }
  if ($Body) {
    $params.Body = ($Body | ConvertTo-Json -Depth 6)
    $params.ContentType = 'application/json'
  }
  try {
    return Invoke-RestMethod @params
  } catch {
    if ($AllowFail) { return $null }
    $msg = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $msg + ' | ' + $_.ErrorDetails.Message }
    throw "GitHub API $Method $Path failed: $msg"
  }
}

function New-GitHubRepo {
  param([string]$Name, [string]$Desc = '', [switch]$Private)
  $existing = Invoke-GitHubApi -Path ("/repos/$GhUser/$Name") -AllowFail
  if ($existing) {
    Write-Host ("[ok] repo already exists: " + $existing.html_url) -ForegroundColor Yellow
    return $existing
  }
  $body = @{
    name        = $Name
    description = $Desc
    private     = [bool]$Private
    has_issues  = $true
    has_wiki    = $false
    auto_init   = $false
  }
  $r = Invoke-GitHubApi -Method POST -Path '/user/repos' -Body $body
  Write-Host ("[ok] created repo: " + $r.html_url) -ForegroundColor Green
  return $r
}

# ------------------------------------------------------------------- gitignore

$IgnoreLines = @(
  '# --- added by dsh github.ps1 ---'
  '.env'
  '.env.*'
  '!.env.example'
  '*.log'
  '.DS_Store'
  'Thumbs.db'
  'desktop.ini'
  ''
  '# python'
  '__pycache__/'
  '*.py[cod]'
  '*.egg-info/'
  '.pytest_cache/'
  '.mypy_cache/'
  '.venv/'
  'venv/'
  'env/'
  ''
  '# node'
  'node_modules/'
  '.pnpm-store/'
  '.next/'
  '.nuxt/'
  '.turbo/'
  ''
  '# rust / go / java build'
  'target/'
  '*.class'
  '*.jar'
  '.gradle/'
  'build/'
  'out/'
  ''
  '# android'
  'local.properties'
  '*.apk'
  '*.aab'
  '*.jks'
  '*.keystore'
  '.cxx/'
  'captures/'
  '.externalNativeBuild/'
  ''
  '# editors / os'
  '.vscode/settings.json'
  '.idea/'
  '*.swp'
  '*.bak'
)

function Ensure-GitIgnore {
  param([string]$Root)
  $f = Join-Path $Root '.gitignore'
  $existing = if (Test-Path $f) { Get-Content $f -Encoding UTF8 } else { @() }
  $missing = @()
  foreach ($line in $IgnoreLines) {
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($existing -contains $line) { continue }
    $missing += $line
  }
  if ($missing.Count -eq 0) { Write-Host '[ok] .gitignore already covers the basics' ; return }
  $block = @('', '# --- added by dsh github.ps1 ---') + $missing
  Add-Content -Path $f -Value $block -Encoding UTF8
  Write-Host ("[ok] .gitignore +" + $missing.Count + " rules: " + ($missing -join ' ')) -ForegroundColor Green
}

# ---------------------------------------------------------------- secret audit

$SecretFilePatterns = @(
  '^\.env$', '^\.env\.', '\.pem$', '\.pfx$', '\.p12$', '^id_rsa', '^id_ed25519',
  '\.keystore$', '^credentials\.json$', '^secrets?\.(json|ya?ml|txt)$', '\.kdbx$'
)
$SecretContentPatterns = @(
  'ghp_[0-9A-Za-z]{30,}',
  'github_pat_[0-9A-Za-z_]{20,}',
  'sk-[A-Za-z0-9]{32,}',
  'AKIA[0-9A-Z]{16}',
  'xox[baprs]-[0-9A-Za-z-]{10,}',
  '-----BEGIN [A-Z ]*PRIVATE KEY-----',
  '(password|passwd|secret|api[_-]?key|access[_-]?token)\s*[:=]\s*[''"][^''"]{10,}[''"]'
)
$SecretPlaceholders = 'your|example|xxx|placeholder|changeme|<.*>|\*\*\*|TODO|dummy|sample'

function Test-SensitiveContent {
  param([string]$Root, [string[]]$Files)
  $hits = New-Object System.Collections.ArrayList
  foreach ($rel in $Files) {
    $full = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $leaf = Split-Path $rel -Leaf
    foreach ($p in $SecretFilePatterns) {
      if ($leaf -match $p -and $rel -notmatch '\.env\.example$') {
        [void]$hits.Add([pscustomobject]@{ File = $rel; Reason = "sensitive filename ($p)"; Detail = '' })
      }
    }
    $size = (Get-Item -LiteralPath $full).Length
    if ($size -gt 50MB) {
      [void]$hits.Add([pscustomobject]@{ File = $rel; Reason = ('large file {0:N1} MB' -f ($size / 1MB)); Detail = 'GitHub hard-limits 100 MB' })
    }
    if ($size -eq 0 -or $size -gt 2MB) { continue }
    if ($leaf -match '\.(png|jpe?g|gif|webp|ico|zip|gz|7z|rar|pdf|woff2?|ttf|mp4|apk|exe|dll|so|dylib|bin|dat|db|sqlite)$') { continue }
    $lines = Get-Content -LiteralPath $full -Encoding UTF8 -ErrorAction SilentlyContinue -TotalCount 5000
    if (-not $lines) { continue }
    $ln = 0
    foreach ($line in $lines) {
      $ln++
      if ($line.Length -gt 500) { continue }
      foreach ($p in $SecretContentPatterns) {
        if ($line -match $p) {
          if ($line -match $SecretPlaceholders) { break }
          [void]$hits.Add([pscustomobject]@{ File = $rel; Reason = 'possible secret'; Detail = ("line ${ln}: " + $line.Trim().Substring(0, [Math]::Min(90, $line.Trim().Length))) })
          break
        }
      }
    }
  }
  return $hits
}

# ---------------------------------------------------------------------- history

function GitOut {
  param([string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git @GitArgs 2>$null
    return @($out)
  } finally { $ErrorActionPreference = $prev }
}

function Get-GitBranch {
  # symbolic-ref works on an unborn branch, rev-parse does not
  $b = GitOut @('symbolic-ref', '--short', 'HEAD')
  if ($b -and $LASTEXITCODE -eq 0) { return [string]($b -join '') }
  $b = GitOut @('rev-parse', '--abbrev-ref', 'HEAD')
  if ($b) { return [string]($b -join '') }
  return 'main'
}

function Get-RepoState {
  param([string]$Root)
  Push-Location $Root
  try {
    $isRepo = $false
    try { GitOut @('rev-parse', '--is-inside-work-tree') | Out-Null; $isRepo = ($LASTEXITCODE -eq 0) } catch { $isRepo = $false }
    if (-not $isRepo) { return [pscustomobject]@{ IsRepo = $false } }
    $branch = Get-GitBranch
    $tag = (GitOut @('describe', '--tags', '--abbrev=0', '--match', 'v*')) -join ''
    $remote = (GitOut @('remote', 'get-url', 'origin')) -join ''
    $dirty = @(GitOut @('status', '--porcelain')).Count
    return [pscustomobject]@{ IsRepo = $true; Branch = $branch; Tag = $tag; Remote = $remote; Changed = $dirty }
  } finally { Pop-Location }
}

function Get-NextVersion {
  param([string]$LatestTag, [string]$Kind)
  if ($Kind -eq 'none') { return $null }
  # first ever version is v0.1.0 whatever the bump kind says
  if (-not $LatestTag -or $LatestTag -notmatch '^v(\d+)\.(\d+)\.(\d+)') { return 'v0.1.0' }
  $major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]
  switch ($Kind) {
    'major' { $major++; $minor = 0; $patch = 0 }
    'minor' { $minor++; $patch = 0 }
    'patch' { $patch++ }
  }
  return "v$major.$minor.$patch"
}

function Get-DefaultMessage {
  param([string]$Root)
  Push-Location $Root
  try {
    $files = @(GitOut @('diff', '--cached', '--name-only'))
    if ($files.Count -eq 0) { return 'chore: sync' }
    $shown = ($files | Select-Object -First 5) -join ', '
    if ($files.Count -gt 5) { $shown = $shown + " (+$($files.Count - 5) more)" }
    return "chore: update $shown"
  } finally { Pop-Location }
}

function Invoke-Git {
  param([string[]]$GitArgs, [switch]$AllowFail)
  # never let Git Credential Manager pop a GUI dialog; our DPAPI helper supplies the token
  $env:GCM_INTERACTIVE = 'never'
  & git @GitArgs 2>&1 | ForEach-Object { Write-Host ("     " + $_) -ForegroundColor DarkGray }
  if ($LASTEXITCODE -ne 0 -and -not $AllowFail) { throw ("git " + ($GitArgs -join ' ') + " failed (exit $LASTEXITCODE)") }
  return $LASTEXITCODE
}

# --------------------------------------------------------------------- publish

function Invoke-Publish {
  param(
    [string]$Path, [string]$Msg, [string]$Kind, [string]$Name, [string]$Desc,
    [switch]$Priv, [switch]$SkipPush, [switch]$ForceIt, [switch]$DryRun
  )

  if (-not (Test-Path $Path)) { throw "project path not found: $Path" }
  $root = (Resolve-Path $Path).Path
  Write-Host ""
  Write-Host ("=== publishing " + $root + " ===") -ForegroundColor Cyan

  Push-Location $root
  try {
    # --- 1. repo ---
    $state = Get-RepoState -Root $root
    if (-not $state.IsRepo) {
      Write-Host '[..] not a git repo -> git init -b main'
      if (-not $DryRun) { Invoke-Git @('init', '-b', 'main') | Out-Null }
      $state = Get-RepoState -Root $root
    } else {
      Write-Host ("[ok] git repo on branch " + $state.Branch)
    }

    # --- 2. ignore rules ---
    if (-not $DryRun) { Ensure-GitIgnore -Root $root }

    # --- 3. stage ---
    if (-not $DryRun) {
      Invoke-Git @('add', '-A') | Out-Null
      $staged = @(GitOut @('diff', '--cached', '--name-only'))
    } else {
      # dry run must not touch the index: report what *would* be committed
      $staged = @(GitOut @('status', '--porcelain')) | ForEach-Object { ($_ -replace '^...', '').Trim() }
    }
    Write-Host ("[..] staged files: " + $staged.Count)

    # --- 4. secret audit ---
    $hits = Test-SensitiveContent -Root $root -Files $staged
    if ($hits.Count -gt 0) {
      Write-Host ""
      Write-Host '[!!] sensitive content detected - aborting before commit' -ForegroundColor Red
      $hits | Format-Table -AutoSize | Out-String | Write-Host
      Write-Host '     fix: add to .gitignore, move the secret to an env var, then re-run.' -ForegroundColor Yellow
      Write-Host '     override (only if you are sure): -Force' -ForegroundColor Yellow
      if (-not $ForceIt) {
        if (-not $DryRun) { Invoke-Git @('reset', '-q') -AllowFail | Out-Null }
        throw 'aborted: secrets in working tree'
      }
    } else {
      Write-Host '[ok] secret scan clean'
    }

    if ($staged.Count -gt 2000) {
      Write-Host ("[!!] " + $staged.Count + " files staged - is a build artifact dir included?") -ForegroundColor Yellow
    }

    # --- 5. commit ---
    $hasChanges = $staged.Count -gt 0
    if ($hasChanges) {
      if (-not $Msg) { $Msg = Get-DefaultMessage -Root $root }
      Write-Host ("[..] commit: " + $Msg)
      if (-not $DryRun) { Invoke-Git @('commit', '-q', '-m', $Msg) | Out-Null }
    } else {
      Write-Host '[ok] nothing to commit (working tree clean)'
    }

    # --- 6. version tag ---
    $state = Get-RepoState -Root $root
    $nextTag = Get-NextVersion -LatestTag $state.Tag -Kind $Kind
    if ($nextTag) {
      Write-Host ("[..] tag: " + $nextTag + "  (previous: " + ($(if ($state.Tag) { $state.Tag } else { 'none' })) + ")")
      if (-not $DryRun) {
        $tagMsg = if ($Msg) { $Msg } else { "release $nextTag" }
        Invoke-Git @('tag', '-a', $nextTag, '-m', $tagMsg) -AllowFail | Out-Null
      }
    }

    # --- 7. remote ---
    if (-not $state.Remote) {
      if (-not $Name) { $Name = (Split-Path $root -Leaf) }
      $Name = ($Name -replace '[^0-9A-Za-z._-]', '-').Trim('-')
      if ($DryRun) {
        Write-Host ("[..] would create repo " + $GhUser + "/" + $Name)
      } else {
        $repo = New-GitHubRepo -Name $Name -Desc $Desc -Private:$Priv
        Invoke-Git @('remote', 'add', 'origin', $repo.clone_url) | Out-Null
        $state = Get-RepoState -Root $root
      }
    } else {
      Write-Host ("[ok] remote origin -> " + $state.Remote)
    }

    if ($SkipPush) { Write-Host '[ok] -NoPush: stopping before push'; return }
    if ($DryRun) { Write-Host '[ok] dry run complete'; return }

    # --- 8. push (direct, then via Clash) ---
    $branch = Get-GitBranch
    $proxyUrl = Get-ProxyUrl
    Write-Host ("[..] pushing " + $branch + " ...")
    $code = Invoke-Git @('push', '-u', 'origin', $branch, '--follow-tags') -AllowFail
    if ($code -ne 0) {
      Write-Host ("[..] direct push failed -> retry through Clash proxy " + $proxyUrl) -ForegroundColor Yellow
      $code = Invoke-Git @('-c', "http.proxy=$proxyUrl", 'push', '-u', 'origin', $branch, '--follow-tags') -AllowFail
      if ($code -ne 0) { throw 'push failed even through proxy' }
      Invoke-Git @('config', 'http.proxy', $proxyUrl) -AllowFail | Out-Null
      Write-Host ("[ok] saved http.proxy=" + $proxyUrl + " for this repo") -ForegroundColor Yellow
    }

    # --- 9. report ---
    $sha = (GitOut @('rev-parse', '--short', 'HEAD')) -join ''
    $url = (GitOut @('remote', 'get-url', 'origin')) -join ''
    $url = $url -replace '\.git$', ''
    Write-Host ""
    Write-Host '[ok] published' -ForegroundColor Green
    Write-Host ("     repo   : " + $url)
    Write-Host ("     commit : " + $sha + "  " + $Msg)
    if ($nextTag) { Write-Host ("     tag    : " + $nextTag) }
  } finally {
    Pop-Location
  }
}

# ------------------------------------------------------------------------- main

switch ($Action) {
  'token-save' { Save-Token -Plain $Token }
  'token-check' {
    if (Test-Path $TokenFile) {
      $t = Get-Token
      Write-Host ("[ok] token present (" + $t.Length + " chars, ..." + $t.Substring($t.Length - 4) + ")") -ForegroundColor Green
    } else {
      Write-Host '[--] no token stored' -ForegroundColor Yellow
    }
  }
  'token-clear' {
    if (Test-Path $TokenFile) { Remove-Item $TokenFile -Force; Write-Host '[ok] token removed' }
    else { Write-Host '[--] nothing to remove' }
  }
  'whoami' {
    $u = Invoke-GitHubApi -Path '/user'
    Write-Host ("[ok] authenticated as " + $u.login + " (" + $u.name + ")") -ForegroundColor Green
    Write-Host ("     repos: " + $u.public_repos + " public / " + $u.total_private_repos + " private")
    if ($u.login -ne $GhUser) { Write-Host ("[!!] token belongs to " + $u.login + ", expected " + $GhUser) -ForegroundColor Yellow }
  }
  'ignore' { Ensure-GitIgnore -Root (Resolve-Path $ProjectPath).Path }
  'audit' {
    $root = (Resolve-Path $ProjectPath).Path
    Push-Location $root
    try {
      $files = @(GitOut @('ls-files')) + @(GitOut @('ls-files', '-o', '--exclude-standard'))
      if ($files.Count -eq 0) {
        # not a git repo yet: walk the tree, skipping the usual junk
        $skip = 'node_modules|__pycache__|\.git$|\.venv|venv|\.pytest_cache|\.mypy_cache|target|dist|build|\.gradle|\.idea'
        $files = Get-ChildItem $root -Recurse -File -Force -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -notmatch $skip } |
          ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\', '/') }
      }
    } finally { Pop-Location }
    $files = $files | Sort-Object -Unique
    Write-Host ("[..] scanning " + $files.Count + " files")
    $hits = Test-SensitiveContent -Root $root -Files $files
    if ($hits.Count -eq 0) { Write-Host '[ok] clean' -ForegroundColor Green }
    else { $hits | Format-Table -AutoSize | Out-String | Write-Host }
  }
  'status' {
    $state = Get-RepoState -Root (Resolve-Path $ProjectPath).Path
    $state | Format-List | Out-String | Write-Host
  }
  'publish' {
    Invoke-Publish -Path $ProjectPath -Msg $Message -Kind $Bump -Name $RepoName -Desc $Description `
      -Priv:$Private -SkipPush:$NoPush -ForceIt:$Force -DryRun:$WhatIf
  }
}
