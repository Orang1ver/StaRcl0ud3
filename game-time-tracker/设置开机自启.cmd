@echo off
setlocal
cd /d "%~dp0"
title 设置开机自启 + 防掉线

set "EXE=%~dp0GameTimeTracker.exe"
if not exist "%EXE%" (
  echo [x] 没找到 GameTimeTracker.exe，请把本脚本和 exe 放在同一个文件夹里。
  pause
  exit /b 1
)

echo [1/3] 写注册表：登录后自动启动
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v GameTimeTrackerApp /t REG_SZ /d "\"%EXE%\"" /f >nul
if errorlevel 1 (
  echo     [x] 写入失败，可能被安全软件拦了。
  pause
  exit /b 1
)
echo     OK

echo [2/3] 建"防掉线"计划任务：每 5 分钟检查一次，没在跑就拉起来
schtasks /Create /TN "GameTimeTrackerWatchdog" /TR "\"%EXE%\"" /SC MINUTE /MO 5 /RL LIMITED /F >nul
if errorlevel 1 (
  echo     [x] 创建失败（多半是杀毒软件拦截）。可以稍后重试，或手动在"任务计划程序"里加一个。
) else (
  echo     OK
)

echo [3/3] 立刻启动一次
start "" "%EXE%"
timeout /t 3 /nobreak >nul

echo.
echo ===== 当前状态 =====
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v GameTimeTrackerApp
echo.
schtasks /Query /TN "GameTimeTrackerWatchdog" /FO LIST
echo.
echo 完成。之后即使它被关掉、被安全软件杀掉，最多 5 分钟会自动回来。
echo 想看统计：双击"打开统计面板.bat"或桌面快捷方式。
echo.
echo 排查用：文件夹里的 tracker.log 记录了每次启动/重复启动的时间。
pause
