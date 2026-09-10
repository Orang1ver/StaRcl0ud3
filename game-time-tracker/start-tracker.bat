@echo off
cd /d "%~dp0"
echo Starting tracker... press Q in the window to stop.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tracker.ps1"
pause
