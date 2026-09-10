# RinkDesk — expose ONLY the read-only live page to the internet via
# Tailscale Funnel, from scratch, on Windows.
#
# This is the Windows twin of ./start-funnel.sh. It installs Tailscale if
# needed, starts its service, logs in (interactive the first time), starts the
# desk (via WSL) if the live listener is down, then enables the Funnel.
#
#   .\scripts\start-funnel.cmd
#   .\scripts\start-funnel.cmd --path /scores
#   .\scripts\start-funnel.cmd --port 8766
#   .\scripts\start-funnel.cmd --authkey tskey-auth-...
#   .\scripts\start-funnel.cmd --no-desk
#   .\scripts\start-funnel.cmd --status
#   .\scripts\start-funnel.cmd --stop
param(
  [Alias('path')]
  [string]$Path = '/live',
  [Alias('port')]
  [string]$Port = '8766',
  [Alias('authkey')]
  [string]$AuthKey,
  [Alias('no-desk')]
  [switch]$NoDesk,
  [switch]$Status,
  [switch]$Stop,
  [Alias('h')]
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Argv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent

function Fail([string]$Message) {
  Write-Host "error: $Message" -ForegroundColor Red
  exit 1
}

function Say([string]$Message, [string]$Color = 'Gray') {
  Write-Host $Message -ForegroundColor $Color
}

function Show-Usage {
  Write-Host @"
RinkDesk live funnel (Windows)

  .\scripts\start-funnel.cmd                 set up Tailscale and expose the live page
  .\scripts\start-funnel.cmd --path /scores  use a different URL path
  .\scripts\start-funnel.cmd --port 8766     live listener port
  .\scripts\start-funnel.cmd --authkey KEY   non-interactive Tailscale login
  .\scripts\start-funnel.cmd --no-desk       do not auto-start the desk
  .\scripts\start-funnel.cmd --status        show current funnel config
  .\scripts\start-funnel.cmd --stop          stop exposing the path

Everything is automatic except the Tailscale login, which opens in a browser
the first time. Tailscale runs on Windows and points at the loopback live
listener that Docker Desktop publishes from WSL.
"@
}

if ($Help) { Show-Usage; exit 0 }

if (-not $Path.StartsWith('/')) { $Path = "/$Path" }
$Path = $Path.TrimEnd('/')
if (-not $Path) { $Path = '/live' }

if (-not ($Port -as [int]) -or [int]$Port -lt 1) { Fail "--port needs a port number" }

function Find-Tailscale {
  $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $candidates = @()
  foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($base) { $candidates += (Join-Path $base 'Tailscale\tailscale.exe') }
  }
  foreach ($c in $candidates) {
    if (Test-Path $c) { return $c }
  }
  return $null
}

function Install-Tailscale {
  Say "Tailscale is not installed - installing it now..." 'White'
  if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    & winget.exe install --id Tailscale.Tailscale -e --source winget `
      --accept-package-agreements --accept-source-agreements | Out-Host
  } else {
    $setup = Join-Path $env:TEMP 'tailscale-setup-latest.exe'
    Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' -OutFile $setup
    Start-Process -FilePath $setup -ArgumentList '/quiet' -Wait
  }
  $ts = Find-Tailscale
  if (-not $ts) { Fail "Tailscale installed but tailscale.exe was not found" }
  return $ts
}

function Get-TsJson([string]$Ts) {
  try {
    $raw = & $Ts status --json 2>$null | Out-String
    if ($raw -and $raw.TrimStart().StartsWith('{')) { return ($raw | ConvertFrom-Json) }
  } catch { }
  return $null
}

function Get-TsState([string]$Ts) {
  $j = Get-TsJson $Ts
  if ($j -and $j.BackendState) { return "$($j.BackendState)" }
  return ''
}

function Get-EnableUrl([string]$Ts) {
  $j = Get-TsJson $Ts
  if ($j -and $j.Self -and $j.Self.ID) {
    return "https://login.tailscale.com/f/funnel?node=$($j.Self.ID)"
  }
  return ''
}

function Write-Link([string]$Url) {
  $esc = [char]27
  $st = "$([char]27)\"
  Write-Host "$esc]8;;$Url$st$Url$esc]8;;$st"
}

function Ensure-Service([string]$Ts) {
  $svc = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -eq 'Running') { return }
  Say 'Starting the Tailscale service...' 'White'
  try {
    Start-Service -Name Tailscale
  } catch {
    Fail "could not start the Tailscale service. Run this in an Administrator PowerShell:
  Start-Service Tailscale"
  }
  for ($i = 0; $i -lt 30; $i++) {
    $now = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    if ((Get-TsState $Ts) -or ($now -and $now.Status -eq 'Running')) { return }
    Start-Sleep -Seconds 1
  }
  Fail "the Tailscale service did not come up"
}

function Ensure-Login([string]$Ts) {
  if ((Get-TsState $Ts) -eq 'Running') { return }
  Say 'Tailscale is not connected - starting login...' 'White'
  if ($AuthKey) {
    & $Ts up --authkey $AuthKey
  } else {
    Say 'Finish the login in the browser window that opens.' 'DarkGray'
    & $Ts up
  }
  for ($i = 0; $i -lt 60; $i++) {
    if ((Get-TsState $Ts) -eq 'Running') { Say 'Tailscale connected' 'Green'; return }
    Start-Sleep -Seconds 1
  }
  Fail "Tailscale is still not connected - run: tailscale up"
}

function Test-Live([string]$LivePort) {
  try {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$LivePort/" | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Ensure-Desk([string]$LivePort) {
  if ($NoDesk) { return }
  if (Test-Live $LivePort) { Say "desk already answering on 127.0.0.1:$LivePort" 'DarkGray'; return }
  Say 'Live listener is not up - starting the desk...' 'White'
  & (Join-Path $PSScriptRoot 'windows.cmd') --start -n
  for ($i = 0; $i -lt 60; $i++) {
    if (Test-Live $LivePort) { return }
    Start-Sleep -Seconds 1
  }
  Fail "the live listener did not come up on 127.0.0.1:$LivePort"
}

$ts = Find-Tailscale
if (-not $ts) { $ts = Install-Tailscale }

if ($Status) {
  & $ts funnel status
  exit $LASTEXITCODE
}

if ($Stop) {
  Say "Stopping funnel for $Path..." 'White'
  & $ts funnel --set-path $Path off
  if ($LASTEXITCODE -ne 0) {
    Say 'could not remove just that path; resetting all funnel config' 'DarkGray'
    & $ts funnel reset
  }
  Say 'done' 'Green'
  exit $LASTEXITCODE
}

Ensure-Service $ts
Ensure-Login $ts
Ensure-Desk $Port

Say "Exposing http://127.0.0.1:$Port at $Path" 'White'
$eurl = Get-EnableUrl $ts
if ($eurl) {
  Say 'If Funnel is not enabled yet, enable it once (click the link):' 'DarkGray'
  Write-Link $eurl
}
$tmp = [System.IO.Path]::GetTempFileName()
& $ts funnel --bg --set-path $Path "http://127.0.0.1:$Port" 2>&1 |
  Tee-Object -FilePath $tmp | Out-Host
$rc = $LASTEXITCODE
$out = Get-Content -Raw $tmp -ErrorAction SilentlyContinue
Remove-Item $tmp -ErrorAction SilentlyContinue
if ($rc -ne 0) {
  if ($out -match '(?i)not enabled|enable.*funnel|funnel.*(disabled|admin|acl)') {
    Fail "Funnel is not enabled for your tailnet yet.
  Open the link above (Tailscale admin -> Access controls) to enable Funnel, then re-run."
  }
  Fail 'could not start the funnel (see the message above)'
}

$dns = ''
$j = Get-TsJson $ts
if ($j -and $j.Self -and $j.Self.DNSName) { $dns = "$($j.Self.DNSName)".TrimEnd('.') }
if ($dns) {
  Say "Live page:  https://$dns$Path/" 'Green'
} else {
  Say 'Run "tailscale funnel status" for the public URL.'
}
Say "Only $Path is public; the desk itself stays private." 'DarkGray'
