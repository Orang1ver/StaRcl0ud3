@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permission...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
schtasks /Delete /TN "GameTimeTracker" /F
echo Old task removed. You can close this window.
pause
