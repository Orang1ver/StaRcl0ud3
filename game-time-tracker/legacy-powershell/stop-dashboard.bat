@echo off
for /f "tokens=5" %%a in ('netstat -ano ^| findstr :8770 ^| findstr LISTENING') do taskkill /PID %%a /F >nul 2>&1
echo Dashboard server stopped.
pause
