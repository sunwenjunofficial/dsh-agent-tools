#requires -Version 5.1
<#
  git-credential-github.ps1 - git credential helper backed by a DPAPI-sealed token.

  Registered with:
    git config --global credential.https://github.com.helper "!C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:/Users/<you>/.dsh/tools/git-credential-github.ps1"

  git calls this with a single argument: get | store | erase
  On 'get' we print the credentials on stdout; nothing is written to disk in plaintext.

  ASCII-only on purpose (Windows PowerShell 5.1 reads non-BOM files as ANSI).
#>
param([Parameter(Mandatory = $true, Position = 0)][string]$Action)

$ErrorActionPreference = 'SilentlyContinue'
if ($Action -ne 'get') { exit 0 }

$TokenFile = Join-Path $env:USERPROFILE '.dsh\secrets\github-token.bin'
if (-not (Test-Path $TokenFile)) { exit 0 }

Add-Type -AssemblyName System.Security
try {
  $enc = [System.IO.File]::ReadAllBytes($TokenFile)
  $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, 'CurrentUser')
  $token = [System.Text.Encoding]::UTF8.GetString($bytes)
} catch { exit 0 }

if (-not $token) { exit 0 }

Write-Output 'protocol=https'
Write-Output 'host=github.com'
Write-Output 'username=x-access-token'
Write-Output "password=$token"
exit 0
