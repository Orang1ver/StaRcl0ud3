# StaRcl0ud3

自用的几个 Windows 小工具,全部**只在本机运行**:不联网、不上传、数据只存在自己电脑的文件夹里。

## [game-time-tracker](game-time-tracker/)

「游戏时长统计」。后台记录游戏进程的运行时长,用本地网页看统计面板。

- 默认统计:原神(国服/国际服)、崩坏:星穹铁道、绝区零、我的世界、CS2,其它游戏可在面板里自己加
- 面板:今日 / 近 7 天 / 累计总览、近 14 天趋势图、活跃日历热力图、各游戏总览、最近时段、近 7 天明细
- 记录管理:删除单条时段、按天清除、按游戏清空、手动补录漏掉的时间、导出 CSV、每日自动备份
- 设置:每日目标进度、连续游戏提醒、三套主题配色、刷新间隔、显示模块开关、开机自启
- 统计口径:进程只要在运行就计时;少于 1 分钟的时段默认不计入(可调)

详细说明见 [game-time-tracker/README.md](game-time-tracker/README.md)。

> 打包好的 `GameTimeTracker.exe` 约 90MB,不进仓库,放在 [Releases](../../releases) 里。
> 源码可以直接用 Node 运行(`从源码运行.cmd`),也可以按 `构建exe.cmd` 自己打包。

## [mihoyo-daily-reminder](mihoyo-daily-reminder/)

给 **原神 / 崩坏:星穹铁道 / 绝区零** 用的每日任务助手。桌面程序入口 `desktop-app.cmd`,
另有 23:30 的计划任务提醒,打卡按每日 04:00 刷新。

带一套奖励系统:XP、代币、连击、冻结、里程碑、等级和兑换商店,规则全部写在 `rewards.json` 里,
改规则不用动脚本。自检脚本:`build/test-rewards.ps1`。

详细说明见 [mihoyo-daily-reminder/README.md](mihoyo-daily-reminder/README.md)。
