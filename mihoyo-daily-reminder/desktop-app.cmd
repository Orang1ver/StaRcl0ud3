@echo off
rem MiHoYo Daily Helper - desktop app launcher
start "" powershell.exe -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "%~dp0desktop-app.ps1"
exit /b 0
