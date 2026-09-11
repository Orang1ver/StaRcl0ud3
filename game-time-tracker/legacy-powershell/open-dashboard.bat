@echo off
cd /d "%~dp0"
start "" /min cmd /c "node "%~dp0dashboard-server.js" > "%~dp0server.log" 2>&1"
timeout /t 1 /nobreak >nul
start "" "http://127.0.0.1:8770"
