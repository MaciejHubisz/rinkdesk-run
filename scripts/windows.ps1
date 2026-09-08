# Jump into WSL and run ./start.sh.
#   .\scripts\windows.cmd --start
#   .\scripts\windows.ps1 --start
#   .\scripts\windows.cmd --start --export-path D:\rinkdesk-exports
param(
  [Alias('p')]
  [string]$Port,
  [Alias('n')]
  [switch]$NoOpen,
  [Alias('h')]
  [switch]$Help,
  [Alias('V')]
  [switch]$Version,
  [Alias('export-path')]
  [string]$ExportPath,
  [Alias('no-build')]
  [switch]$NoBuild,
  [switch]$Start,
  [switch]$Stop,
  [switch]$Manual,
  [switch]$ForceRecreate,
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
  Fail "WSL is required. Administrator PowerShell: wsl --install"
}

$distro = Get-LinuxDistro
if (-not $distro) {
  Fail "No WSL Linux distro (docker-desktop is not enough). wsl --install -d Ubuntu"
}

function ConvertTo-WslPath([string]$Path) {
  if ($Path -match '^/') {
    return $Path
  }
  $full = $Path
  if (-not [System.IO.Path]::IsPathRooted($Path)) {
    $full = Join-Path (Get-Location) $Path
  }
  $full = [System.IO.Path]::GetFullPath($full)
  $unix = (& wsl.exe -d $distro wslpath -a $full | Select-Object -First 1)
  $unix = ([string]$unix).Trim() -replace "`0", '' -replace "`r", ''
  if (-not $unix) { Fail "could not map $Path into WSL ($distro)" }
  return $unix
}

$forward = New-Object System.Collections.Generic.List[string]
if ($Start) { [void]$forward.Add('--start') }
if ($ForceRecreate) { [void]$forward.Add('--force-recreate') }
if ($Stop) { [void]$forward.Add('--stop') }
if ($Manual) { [void]$forward.Add('--manual') }
if ($Help) { [void]$forward.Add('--help') }
if ($Version) { [void]$forward.Add('--version') }
if ($NoOpen) { [void]$forward.Add('--no-open') }
if ($NoBuild) { [void]$forward.Add('--no-build') }
if ($Port) { [void]$forward.Add('--port'); [void]$forward.Add("$Port") }
if ($ExportPath) {
  [void]$forward.Add('--export-path')
  [void]$forward.Add((ConvertTo-WslPath $ExportPath))
}
foreach ($a in @($Argv)) {
  if ($null -ne $a -and "$a" -ne '') { [void]$forward.Add("$a") }
}

$unix = (& wsl.exe -d $distro wslpath -a $Root | Select-Object -First 1)
$unix = ([string]$unix).Trim() -replace "`0", '' -replace "`r", ''
if (-not $unix) { Fail "could not map $Root into WSL ($distro)" }

Write-Host "RinkDesk  Windows → WSL ($distro)"
$wslArgs = @('-d', $distro, '-e', 'bash', "$unix/start.sh") + $forward
& wsl.exe @wslArgs
exit $LASTEXITCODE
