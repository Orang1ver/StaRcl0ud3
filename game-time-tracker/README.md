# 游戏时长统计(GameTimeTracker)

一个只在本机运行的 Windows 小工具:记录你每天玩游戏的时长。
后台静默统计,数据全部存在自己电脑的文件夹里,不联网、不上传。

统计范围默认是原神(国服/国际服)、崩坏:星穹铁道、绝区零、我的世界、CS2,
其它游戏可以在面板里点「添加游戏」自己加。

## 功能

- **本地网页面板**:总览卡片、最近时段、近 14 天趋势图、活跃日历热力图、各游戏总览、近 7 天明细
- **记录管理**:单条时段删除、按天清除、按游戏清空、手动补录、导出 CSV、每日自动备份
- **设置面板**:每日目标 + 进度条、连续游戏提醒、三套主题、刷新间隔、显示模块开关、开机自启、自动备份
- **统计口径**:进程运行即计时(最小化、挂机也算);少于 N 分钟的时段不计入(默认 1 分钟,可改)
- **开机自启**:登录后静默后台运行,不弹窗、不占任务栏

## 快速开始(用打包好的 exe)

1. 到 [Releases](../../releases) 下载分享包 zip 并解压到一个固定位置
   (例如 `D:\游戏时长统计\`,**不要**放 `C:\Program Files`,程序需要往自己所在文件夹写数据)
2. 双击 `打开统计面板.bat` 打开面板并开始统计
3. 想省事,再双击 `创建桌面快捷方式.bat`,之后从桌面点「游戏时长统计」即可

> 第一次运行 Windows 可能提示「已保护你的电脑」(程序没有数字签名),
> 点「更多信息 → 仍要运行」即可;杀毒软件误报就把整个文件夹加进信任区。

## 从源码运行(需要 Node.js)

双击 `从源码运行.cmd`,或者手动:

```bat
node dashboard-server.js --standalone
```

然后浏览器打开 http://127.0.0.1:8770 。加 `--open` 参数可以自动打开面板窗口。

## 打包成单个 exe

双击 `构建exe.cmd`。它做的事就是官方 Node SEA 流程:

```bat
node --experimental-sea-config sea-config.json
node -e "require('fs').copyFileSync(process.execPath,'GameTimeTracker.exe')"
npx -y postject GameTimeTracker.exe NODE_SEA_BLOB sea-prep.blob --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2
node flip-subsystem.js GameTimeTracker.exe
```

产物 `GameTimeTracker.exe` 约 90MB(内置 Node 运行时,别人电脑不用装任何东西),已加入 `.gitignore`。

## 统计规则

- **进程只要在运行就计时**:最小化、挂后台、挂机都算
- 每 **60 秒**把这段时间写进 `activity.csv`;游戏退出时补写剩余部分(不足 2 秒的碎片丢弃)
- 顶部「今日 / 近 7 天 / 累计」按**同时段去重**:同时开两个游戏只算一次
- **少于 1 分钟的时段默认不计入**(设置里可改,填 0 = 全部计入);原始数据仍保留在 CSV 里

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `GameTimeTracker.exe` | 打包好的程序(不在仓库里,见 Releases) |
| `dashboard-server.js` | 主程序:后台计时 + 本地网页服务 + 设置接口 |
| `dashboard.html` | 面板网页(单文件,无外部依赖,图标已内嵌) |
| `games.txt` | 要统计的进程名,一行一个(不带 `.exe`) |
| `games.json` | 自定义显示名与头像映射 |
| `avatars/` | 头像图片 |
| `settings.json` | 面板设置(目标、提醒、主题、刷新间隔等) |
| `activity.csv` | 计时记录:`开始时间,结束时间,进程名,备注` |
| `backups/` | 每日自动备份 |
| `legacy-powershell/` | 最早的 PowerShell 版本,已被 exe 取代,留作参考 |

`activity.csv`、`backups/`、`*.exe`、`sea-prep.blob` 都在 `.gitignore` 里,不会进仓库。

## 常见问题

**任务栏里显示的是浏览器图标?**
面板是用 Edge/Chrome 的「应用模式窗口」打开的(没有地址栏),图标取自网页里内嵌的 favicon。

**挪动文件夹后快捷方式打不开了?**
快捷方式和开机自启里存的是绝对路径。挪动后重新跑一次 `创建桌面快捷方式.bat`,
并在面板「设置 → 开机自动启动统计」里重新勾一次。

**关掉面板窗口后还在统计吗?**
在。关窗口只是关掉面板,后台统计继续;想彻底停止用任务管理器结束 `GameTimeTracker.exe`。

**记错了怎么办?**
在「最近时段」或「查看全部记录」里可以单独删某一条,漏记的时间用「补录记录」补上。

## 已知限制

- 仅支持 Windows(`tasklist` 读进程、注册表设置自启)
- 需要 Edge 或 Chrome 才能以无地址栏窗口打开面板;都没有时用系统默认浏览器打开
- 只判断进程是否在运行,不区分前台/后台
