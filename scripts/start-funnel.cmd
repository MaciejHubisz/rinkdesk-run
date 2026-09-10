@echo off
setlocal
REM Windows twin of ./start-funnel.sh. Forwards flags into PowerShell.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-funnel.ps1" %*
exit /b %ERRORLEVEL%
