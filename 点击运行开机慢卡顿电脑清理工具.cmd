@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0"
set "SCRIPT="
for %%F in ("%~dp0*.ps1") do if not defined SCRIPT set "SCRIPT=%%~fF"
if not defined SCRIPT goto :nofile
title %~n0
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
echo.
pause
exit /b 0
:nofile
echo   [ERROR] *.ps1 not found in this folder
echo   %~dp0
dir /b
pause
exit /b 1