@echo off
chcp 65001 >nul
rem 米哈游每日助手 - 桌面程序备用入口
rem 优先用宿主 exe（进程名就是米哈游每日助手，不会再起 powershell.exe）；
rem 本机启用脚本模式或 exe 不在时，使用 Windows PowerShell 跑脚本。
if exist "%~dp0.use-script-host" goto script
if not exist "%~dp0米哈游每日助手.exe" goto script
start "" "%~dp0米哈游每日助手.exe"
exit /b 0

:script
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "%~dp0desktop-app.ps1"
exit /b 0
