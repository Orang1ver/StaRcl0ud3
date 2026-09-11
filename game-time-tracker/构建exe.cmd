@echo off
cd /d "%~dp0"
title 构建 GameTimeTracker.exe

where node >nul 2>nul
if errorlevel 1 (
  echo [x] 需要先安装 Node.js: https://nodejs.org
  pause
  exit /b 1
)

tasklist /fi "imagename eq GameTimeTracker.exe" 2>nul | findstr /i GameTimeTracker >nul
if not errorlevel 1 (
  echo [x] GameTimeTracker.exe 正在运行,先退出它再构建。
  pause
  exit /b 1
)

echo [1/4] 生成 sea-prep.blob ...
node --experimental-sea-config sea-config.json || goto :fail

echo [2/4] 复制 node.exe 作为程序壳 ...
node -e "require('fs').copyFileSync(process.execPath,'GameTimeTracker.exe')" || goto :fail

echo [3/4] 注入 blob(首次会联网下载 postject) ...
call npx -y postject GameTimeTracker.exe NODE_SEA_BLOB sea-prep.blob --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 || goto :fail

echo [4/4] 改成 GUI 子系统(双击不弹黑窗口) ...
node flip-subsystem.js GameTimeTracker.exe || goto :fail

echo.
echo 构建完成: %~dp0GameTimeTracker.exe
pause
exit /b 0

:fail
echo.
echo 构建失败,把上面的报错发给我就行。
pause
exit /b 1
