@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MiPCAudioRacePatch.ps1" -Mode Status
echo.
pause
