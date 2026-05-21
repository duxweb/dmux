@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "SCRIPT=%~dp0tool-wrapper.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0..\tool-wrapper.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
