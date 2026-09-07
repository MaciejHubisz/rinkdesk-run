@echo off
setlocal
REM Forwards every flag to start.ps1 / WSL without PowerShell eating -p / -n.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
exit /b %ERRORLEVEL%
