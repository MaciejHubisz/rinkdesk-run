# RinkDesk Windows entry. PowerShell cannot run start.sh itself — this
# jumps into WSL and runs ./start.sh (Linux path: Homebrew, docker/podman).
#
#   .\start.ps1
#   .\start.ps1 --start
#   .\start.ps1 --force-recreate
#   .\start.ps1 --stop
#   .\start.ps1 --manual
#   powershell -File .\start.ps1 --help
#
# First time (Administrator PowerShell):  wsl --install
# Also install Docker Desktop and enable WSL integration for your distro.

param(
  [Alias('p')]
  [string]$Port,
  [Alias('n')]
  [switch]$NoOpen,
  [Alias('h')]
  [switch]$Help,
  [Alias('V')]
  [switch]$Version,
  [Alias('H')]
  [string]$BindHost,
  [switch]$Start,
  [switch]$Stop,
  [switch]$Manual,
  [switch]$Data,
  [switch]$ForceRecreate,
  [switch]$Setup,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Argv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

function Fail([string]$Message) {
  Write-Host "error: $Message" -ForegroundColor Red
  exit 1
}

function Get-LinuxDistro {
  $names = @()
  $utf8 = & wsl.exe --list --quiet --utf8 2>$null
  if ($LASTEXITCODE -eq 0 -and $utf8) {
    $names = @($utf8 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  } else {
    $raw = (& wsl.exe --list --quiet 2>$null | Out-String)
    $names = @(
      $raw -replace "`0", '' -split "[\r\n]+" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )
  }
  foreach ($n in $names) {
    if ($n -match '^(docker-desktop|docker-desktop-data|rancher-desktop)') { continue }
    return $n
  }
  return $null
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Fail @"
WSL is required to run RinkDesk on Windows.
  1. Open PowerShell as Administrator
  2. wsl --install
  3. Reboot, install Docker Desktop (WSL2 backend), cd to this folder, run: .\start.ps1
"@
}

$distro = Get-LinuxDistro
if (-not $distro) {
  Fail @"
No WSL Linux distro found (docker-desktop is not enough).
  In PowerShell as Administrator:  wsl --install -d Ubuntu
  Then reboot, enable Docker Desktop → Settings → Resources → WSL integration,
  and run:  .\start.ps1
"@
}

$forward = New-Object System.Collections.Generic.List[string]
if ($Start) { [void]$forward.Add('--start') }
if ($ForceRecreate) { [void]$forward.Add('--force-recreate') }
if ($Setup) { [void]$forward.Add('--setup') }
if ($Stop) { [void]$forward.Add('--stop') }
if ($Manual -or $Data) { [void]$forward.Add('--manual') }
if ($Help) { [void]$forward.Add('--help') }
if ($Version) { [void]$forward.Add('--version') }
if ($NoOpen) { [void]$forward.Add('--no-open') }
if ($Port) { [void]$forward.Add('--port'); [void]$forward.Add("$Port") }
if ($BindHost) { [void]$forward.Add('--host'); [void]$forward.Add($BindHost) }
foreach ($a in @($Argv)) {
  if ($null -ne $a -and "$a" -ne '') { [void]$forward.Add("$a") }
}

$unix = (& wsl.exe -d $distro wslpath -a $Root | Select-Object -First 1)
$unix = ([string]$unix).Trim() -replace "`0", '' -replace "`r", ''
if (-not $unix) {
  Fail "could not map $Root into WSL distro $distro"
}

Write-Host "RinkDesk  Windows → WSL ($distro), Linux path"

$wslArgs = @('-d', $distro, '-e', 'bash', "$unix/start.sh") + $forward
& wsl.exe @wslArgs
exit $LASTEXITCODE
