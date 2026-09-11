@echo off
cd /d "%~dp0"
title 游戏时长统计(源码运行)

where node >nul 2>nul
if errorlevel 1 (
  echo [x] 需要先安装 Node.js: https://nodejs.org
  pause
  exit /b 1
)

echo 正在后台启动统计服务 ...
start "" /min cmd /c "node "%~dp0dashboard-server.js" --standalone > "%~dp0server.log" 2>&1"
timeout /t 2 /nobreak >nul
start "" "http://127.0.0.1:8770"

echo.
echo 统计已在后台运行,面板已用默认浏览器打开。
echo 想停止:用任务管理器结束 node.exe,或双击 legacy-powershell\stop-dashboard.bat
pause
