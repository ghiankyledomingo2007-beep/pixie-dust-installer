@echo off
setlocal
echo Pixie Dust setup
echo Keep this window open until setup finishes. First-time setup may download several GB.
echo.
set "PIXIE_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PIXIE_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PIXIE_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-pixie-dust.ps1" %*
set "PIXIE_EXIT=%ERRORLEVEL%"
echo.
if not "%PIXIE_EXIT%"=="0" echo Setup stopped. See the error and setup log location above. Your files were kept.
pause
exit /b %PIXIE_EXIT%
