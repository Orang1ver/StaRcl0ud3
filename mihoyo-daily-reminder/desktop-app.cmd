@echo off
rem 米哈游每日助手 - 桌面程序备用入口
rem 优先用宿主 exe（进程名就是米哈游每日助手，不会再起 powershell.exe）；
rem exe 不在时才退回用 powershell 跑脚本。
if exist "%~dp0米哈游每日助手.exe" (
  start "" "%~dp0米哈游每日助手.exe"
) else (
  start "" powershell.exe -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "%~dp0desktop-app.ps1"
)
exit /b 0
