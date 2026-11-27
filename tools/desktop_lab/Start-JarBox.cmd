@echo off
setlocal
where wsl.exe >nul 2>&1 || goto missing
wsl.exe -d Ubuntu-24.04 -- bash -lc "exit 0" || goto missing
pushd "%~dp0"
wsl.exe -d Ubuntu-24.04 -- bash ./start-wsl.sh
set RESULT=%ERRORLEVEL%
popd
if not "%RESULT%"=="0" pause
exit /b %RESULT%
:missing
echo Requires WSL2 Ubuntu-24.04 and WSLg. One-time setup in Windows Terminal:
echo wsl --install -d Ubuntu-24.04
echo Complete Ubuntu setup, then double-click this file again.
pause
exit /b 2
