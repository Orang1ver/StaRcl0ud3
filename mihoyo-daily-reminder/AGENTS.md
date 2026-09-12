# 米哈游每日助手 · 工作约定

> 这个文件夹就是「米哈游每日助手」这个 Codex 项目。改这个项目之前先看完这份约定。

**开工第一件事：读 `项目现状.md`** —— 那里面是当前状态、几个入口怎么起、数据结构、
设计决定和踩过的坑。读完再动手，能省掉一轮"这个为什么这么写"。

给 **原神 / 崩坏：星穹铁道 / 绝区零** 做的每日任务助手：桌面程序 + 23:30 的提醒弹窗，
共用一份打卡数据；三款都清完有庆祝，连续打卡有奖励（XP / 代币 / 里程碑 / 商店）。

## 改代码：必须走分支 + 独立工作区

用户平时就在用这个程序，**不要直接改他正在用的目录**：

```powershell
# 1. 开分支 + 独立工作区（放在仓库旁边、名字以 .dev 结尾）
git -C "C:\Users\StarRiver\Desktop\code\StaRcl0ud3" worktree add "C:\Users\StarRiver\Desktop\code\StaRcl0ud3.dev" -b "feat/简短名字"

# 2. 编辑、跑测试都在那里面做，测试脚本要传 -ProjectRoot
powershell -NoProfile -ExecutionPolicy Bypass -File .\build\test-rewards.ps1 -ProjectRoot "<那个 worktree>\mihoyo-daily-reminder"

# 3. 全绿后合并回用户目录
git -C "C:\Users\StarRiver\Desktop\code\StaRcl0ud3" merge --no-ff "feat/简短名字"

# 4. 收尾
git -C "C:\Users\StarRiver\Desktop\code\StaRcl0ud3" worktree remove "C:\Users\StarRiver\Desktop\code\StaRcl0ud3.dev"
git -C "C:\Users\StarRiver\Desktop\code\StaRcl0ud3" branch -d "feat/简短名字"
git -C "C:\Users\StarRiver\Desktop\code\StaRcl0ud3" push origin main
```

5. 最后告诉用户「关掉再打开程序」就能看到新版本。

> 注意：这个仓库（`StaRcl0ud3`）里还有另一个项目 `game-time-tracker`（游戏时长统计）。
> 那个项目**不属于这个 Codex 项目的工作范围**，别顺手改它。

## 仓库与分支

- 仓库根：`C:\Users\StarRiver\Desktop\code\StaRcl0ud3`（本项目的文件在它的 `mihoyo-daily-reminder\` 下）
- 工作分支：`main`
- 远程：`https://github.com/Orang1ver/StaRcl0ud3`
- `米哈游每日助手.exe` 是**提交进仓库的**（60KB 左右的启动器/宿主），改完 `build\Launcher.cs`
  要重新编译：`powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-exe.ps1`

## 数据文件：绝对不要提交、不要覆盖

`history.json`（打卡记录）、`watch.json`（看门设置）都在 .gitignore 里；
合并时不要用 `git checkout --` 之类命令覆盖工作区的用户数据。
自检脚本（`build\test-rewards.ps1`）会在跑前跑后比对 `history.json` 的 SHA256。

## 改完之前必须做

- `build\test-rewards.ps1`（奖励数学，40 项）和 `build\test-watch.ps1`（看门进程，18 项）全绿，
  两个都要传 `-ProjectRoot`
- 颜色改动跑 `build\check-contrast.ps1`
- 合并后确认用户目录里确实是新版本（对比 exe 哈希 / 看关键几行）

## 这套程序的几个关键事实

- **exe 是独立宿主**：`米哈游每日助手.exe` 把 Windows 自带的 PowerShell 引擎装进自己进程里跑脚本，
  所以任务管理器里就是它自己，不会冒出 `powershell.exe`。
  命令行：`（空）= 桌面程序` / `--reminder = 提醒弹窗` / `--watch = 看门进程` / `--script X.ps1`。
  **它调用的 `.ps1` 必须带 UTF-8 BOM**，否则中文乱码、直接解析失败。
- 计划任务、稍后提醒、看门进程都走这个 exe（找不到 exe 才退回 `powershell -File`）。
- 桌面程序的窗口是 WPF + 无边框，走 `lib.ps1` 的 `Enable-ReminderWindow` 支持拖动。
- 打卡按**每日 04:00 刷新**算（0:00–3:59 仍算前一天）。
- 单实例：靠互斥体 + 按窗口标题找进程；第二个实例会提示「已经在运行了」。

## 和这个用户打交道的习惯

- 中文交流，尽量少弹窗、少让他手工操作
- 每次讲清「改了什么 / 为什么 / 怎么验证的」
- 改完顺手 commit + push 到 GitHub；网络不通就说明，等恢复再推
- 界面是深色卡片风（`#343B5F`→`#1C2034` 渐变底 + 金色 `#F2C463` 强调色），
  跟学习计划那个「蓝图风」不是一套配色，别互相抄
