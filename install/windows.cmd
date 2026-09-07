@echo off
setlocal
REM Forwards flags into WSL without PowerShell eating -p / -n.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows.ps1" %*
exit /b %ERRORLEVEL%
