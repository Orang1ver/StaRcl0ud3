# StaRcl0ud3

两个自用的 Windows 小工具。

## [game-time-tracker](game-time-tracker/)

仅在本机运行的「游戏时长统计」工具。检测 `games.txt` 里配置的游戏进程是否在运行，
累计时长并写入 `activity.csv`，通过本地网页看统计面板。

详细用法见 [game-time-tracker/README.txt](game-time-tracker/README.txt)。

运行环境：Windows + PowerShell。计时脚本不联网，只读本机进程列表。

> 仓库里不含 `GameTimeTracker.exe`（90MB+，已加入 `.gitignore`）。
> 需要的话可以用 Node SEA（见 `sea-config.json`）自行构建，或用 `start-tracker.bat` 直接跑脚本。

## [mihoyo-daily-reminder](mihoyo-daily-reminder/)

给 **原神 / 崩坏：星穹铁道 / 绝区零** 用的每日任务助手。桌面程序入口 `desktop-app.cmd`，
另有 23:30 的计划任务提醒。打卡按每日 04:00 刷新。

详细说明见 [mihoyo-daily-reminder/README.md](mihoyo-daily-reminder/README.md)。
