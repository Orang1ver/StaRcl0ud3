@echo off
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permission...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Installing auto-start task...
schtasks /Create /TN "GameTimeTracker" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0tracker.ps1\" -Auto" /SC ONLOGON /RL LIMITED /F
schtasks /Run /TN "GameTimeTracker" >nul 2>&1
echo Done. The tracker now runs in the background automatically.
pause
