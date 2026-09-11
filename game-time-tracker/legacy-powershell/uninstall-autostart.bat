@echo off

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permission...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Removing auto-start task...
schtasks /Delete /TN "GameTimeTracker" /F
echo. > "%~dp0stop.txt"
echo Done. It will not start at next login, and the running one is stopping.
pause
