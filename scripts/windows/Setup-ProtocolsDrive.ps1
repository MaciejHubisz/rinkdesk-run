<#
# Setup-ProtocolsDrive.ps1  — one-time helper for a Windows PC (rinkdesk-run).
#
# WHAT IT DOES
#   Installs Google Drive for desktop, restricts sign-in to one owner Google
#   account, mounts My Drive as a drive letter, then creates the protocols
#   folder (same name rinkdesk-run writes PDFs into by default) inside My Drive
#   so every generated protocol is shared to Google Drive automatically.
#
# HOW TO RUN  (run once per PC, in an ADMIN PowerShell, from rinkdesk-run)
#   powershell -ExecutionPolicy Bypass -File scripts\windows\Setup-ProtocolsDrive.ps1 `
#     -OwnerEmail maciej@example.com -Share ref@example.com,trener@example.com
#
#   Optional: -ProtocolsFolder protocols  -DriveLetter G  -TimeOutMinutes 15
#
#   Administrator rights are required (software install + HKLM registry).
#   Exactly ONE interactive step is expected: the Google account picker /
#   browser login that Drive for desktop opens on first launch. Everything else
#   is automatic. If the drive was not ready yet, just re-run this script later
#   (it is idempotent) or re-run after signing in.
#
# AFTERWARDS — share the folder once
#   Drive for desktop cannot grant file/folder sharing from the CLI. When this
#   script finishes it opens drive.google.com — there, right-click the
#   protocols folder and add the -Share people once. The script prints the full
#   path you give rinkdesk-run, e.g.:
#     .\scripts\windows\windows.cmd --start --protocols-path "G:\My Drive\protocols"
#   No passwords or tokens are stored by this script.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$OwnerEmail,

  [Parameter(Mandatory = $false)]
  [string]$ProtocolsFolder = 'protocols',

  [Parameter(Mandatory = $false)]
  [string]$DriveLetter = 'G',

  [Parameter(Mandatory = $false)]
  [string[]]$Share = @(),

  [Parameter(Mandatory = $false)]
  [int]$TimeOutMinutes = 15
)

$ErrorActionPreference = 'Stop'
$InstallerUrl  = 'https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe'
$TempInstaller = Join-Path $env:TEMP 'GoogleDriveSetup.exe'
$DriveFSKey    = 'HKLM:\Software\Google\DriveFS'

# Same protocol-folder name the generator already uses by default.
$ProtocolFolderName = $ProtocolsFolder.Trim()

# Known localized names of "My Drive" under the mount root.
$MyDriveNames = @('My Drive', 'Mój dysk')

function Write-Step([string]$Text) {
  Write-Host ('==> ' + $Text) -ForegroundColor Cyan
}
function Fail([string]$Text) {
  Write-Host ('error: ' + $Text) -ForegroundColor Red
  exit 1
}

# --- 0. Administrator check (needed for install + HKLM registry) -------------
$Principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Fail 'Administrator rights are required. Reopen this PowerShell "as Administrator" and re-run.'
}

if ($OwnerEmail -notmatch '^[^@\s]+@[^@\s]+$') {
  Fail "OwnerEmail does not look like an email address: $OwnerEmail"
}
if ($DriveLetter -notmatch '^[A-Za-z]$') {
  Fail 'DriveLetter must be a single letter (e.g. G).'
}
$DriveLetter = $DriveLetter.ToUpper()
if ($ProtocolFolderName -eq '' -or $ProtocolFolderName -match '[\\/:*?"<>|]') {
  Fail 'ProtocolsFolder must be a plain folder name.'
}

Write-Host 'RinkDesk protocols -> Google Drive setup'
Write-Host "  owner account : $OwnerEmail"
Write-Host "  protocols dir : $ProtocolsFolder"
Write-Host "  drive letter  : $DriveLetter`:\"
if ($Share.Count -gt 0) {
  Write-Host "  share to      : $($Share -join ', ')"
}

# --- 1. Resolve the GoogleDriveFS.exe location if already installed ----------
function Get-DriveFSExe {
  $candidates = @()
  foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($base) {
      $candidates += (Join-Path $base 'Google\Drive File Stream\GoogleDriveFS.exe')
      $candidates += (Join-Path $base 'Google\DriveFS\GoogleDriveFS.exe')
    }
  }
  foreach ($p in $candidates) {
    if (Test-Path $p) { return $p }
  }
  # Uninstall registry is the authoritative "is it present" check.
  $roots = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
  foreach ($r in $roots) {
    foreach ($k in (Get-ItemProperty $r -ErrorAction SilentlyContinue)) {
      $dn = $k.DisplayName
      if ($dn -match 'Drive File Stream|Google Drive' -and $k.UninstallString) {
        $exe = Join-Path (Split-Path (Split-Path $k.InstallLocation -ErrorAction SilentlyContinue)) 'GoogleDriveFS.exe'
        if (Test-Path $exe) { return $exe }
      }
    }
  }
  return $null
}

$DriveFSExe = Get-DriveFSExe
if (-not $DriveFSExe) {
  Write-Step "Google Drive for desktop is not installed - downloading official installer"
  Write-Host "  $InstallerUrl"
  try {
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $TempInstaller -UseBasicParsing
  } catch {
    Fail "could not download the installer: $($_.Exception.Message)"
  }
  Write-Step 'Installing silently (--silent --desktop_shortcut --skip_launch_new)'
  $proc = Start-Process -FilePath $TempInstaller `
            -ArgumentList '--silent','--desktop_shortcut','--skip_launch_new' `
            -Wait -PassThru -NoNewWindow
  if ($proc.ExitCode -ne 0) {
    Fail "installer exited with code $($proc.ExitCode)."
  }
  $DriveFSExe = Get-DriveFSExe
  if (-not $DriveFSExe) {
    Fail 'installer finished but GoogleDriveFS.exe was not found - please re-run after install.'
  }
} else {
  Write-Step "Google Drive for desktop already installed: $DriveFSExe"
}

# --- 2. Registry: restrict sign-in + set the mount drive letter --------------
# AllowedAccountsPattern = RE2 regex of accounts allowed to sign in here.
# Restricting to exactly the owner keeps the picker to that one account.
$pattern = '^' + [regex]::Escape($OwnerEmail) + '$'
Write-Step 'Restricting Drive sign-in to the owner account'
try {
  New-Item -Path $DriveFSKey -Force | Out-Null
  New-ItemProperty -Path $DriveFSKey -Name 'AllowedAccountsPattern' `
    -Value $pattern -PropertyType String -Force | Out-Null
  # DefaultMountPoint hint: the chosen drive letter. (If a particular build
  # needs it, a trailing colon "G:" also works; the script detects the real
  # mount below, so this is a best-effort hint, not authoritative.)
  New-ItemProperty -Path $DriveFSKey -Name 'DefaultMountPoint' `
    -Value $DriveLetter -PropertyType String -Force | Out-Null
} catch {
  Fail "could not write DriveFS registry keys: $($_.Exception.Message)"
}

# --- 3. Launch Drive for desktop ---------------------------------------------
# One interactive Google account picker / browser login is expected here.
$running = Get-Process GoogleDriveFS -ErrorAction SilentlyContinue
if (-not $running) {
  Write-Step 'Launching Google Drive for desktop (one interactive Google login follows)'
  Start-Process -FilePath $DriveFSExe | Out-Null
} else {
  Write-Step 'Google Drive for desktop is already running'
}

# --- 4. Poll until My Drive is mounted, then create the protocols folder -----
function Get-MountBase {
  # Where the drive letter mount lives if present.
  $letterPath = "${DriveLetter}:\"
  if (Test-Path $letterPath) { return @($letterPath) }
  # Fallbacks for mirror-style mounts (in case the drive-letter setting is not honored).
  $fb = @()
  foreach ($base in @((Join-Path $env:USERPROFILE 'Google Drive'), $env:USERPROFILE)) {
    if (Test-Path $base) { $fb += $base }
  }
  return $fb
}

function Get-MyDriveRoot {
  foreach ($base in (Get-MountBase)) {
    # New model: My Drive is a subfolder of the mount root.
    foreach ($name in $MyDriveNames) {
      $d = Join-Path $base $name
      if (Test-Path $d) { return $d }
    }
    # Legacy File-Stream letter mounts expose My Drive content at the root.
    if ($base -match '^[A-Z]:\\$') { return $base }
  }
  return $null
}

$deadline = (Get-Date).AddMinutes($TimeOutMinutes)
$protocolsPath = $null
while ($true) {
  $root = Get-MyDriveRoot
  if ($root) {
    # Works for both layouts: new mounts have a "My Drive" subfolder, legacy
    # letter mounts expose My Drive content at the drive root itself.
    $candidate = Join-Path $root $ProtocolFolderName
    try {
      New-Item -Path $candidate -ItemType Directory -Force | Out-Null
      $protocolsPath = $candidate
      break
    } catch { }
  }
  if ((Get-Date) -gt $deadline) {
    Write-Host ''
    Write-Host 'My Drive has not appeared yet.' -ForegroundColor Yellow
    Write-Host 'Complete the Google login in the window that opened, then re-run this' -ForegroundColor Yellow
    Write-Host 'same command - it is idempotent and will finish the setup.' -ForegroundColor Yellow
    exit 1
  }
  Write-Host -NoNewline '.'
  Start-Sleep -Seconds 5
}
Write-Host ''

# --- 5. Marker + open in Explorer and on the web -----------------------------
Write-Step "Creating protocols folder: $protocolsPath"
$marker = Join-Path $protocolsPath '_setup.txt'
$markerLines = @(
  'RinkDesk protocols folder (Google Drive).',
  "Owner: $OwnerEmail",
  "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
  'Share this folder once with:'
)
if ($Share.Count -gt 0) {
  $markerLines += ($Share -join ', ')
} else {
  $markerLines += '(none provided)'
}
$markerLines -join "`r`n" | Set-Content -Path $marker -Encoding UTF8

Write-Step "Opening $protocolsPath in Explorer"
Start-Process explorer.exe $protocolsPath | Out-Null

Write-Step 'Opening drive.google.com - share the protocols folder there once'
Start-Process 'https://drive.google.com' | Out-Null

Write-Host ''
if ($Share.Count -gt 0) {
  Write-Host 'Share these accounts on the protocols folder (browser -> right-click -> Share):' -ForegroundColor Green
  foreach ($email in $Share) {
    Write-Host "    - $email" -ForegroundColor Green
  }
  Write-Host ''
  Write-Host 'Note: Drive for desktop cannot grant sharing from the CLI; this one step is manual.' -ForegroundColor Yellow
}

Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  Point rinkdesk-run at this protocols folder:' -ForegroundColor White
Write-Host "      .\scripts\windows\windows.cmd --start --protocols-path `"$protocolsPath`"" -ForegroundColor White
Write-Host '  (or set RINKDESK_PROTOCOLS_PATH to that path).' -ForegroundColor White
Write-Host '================================================================' -ForegroundColor Cyan
