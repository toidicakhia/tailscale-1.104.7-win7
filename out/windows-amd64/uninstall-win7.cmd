@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-win7.ps1" %*
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo Uninstallation failed with exit code %RC%.
pause
exit /b %RC%
