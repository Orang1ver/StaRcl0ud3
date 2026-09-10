# 米哈游每日助手

给 **原神 / 崩坏：星穹铁道 / 绝区零** 做的每日任务助手，电脑上有两个入口，共用同一份打卡数据：

| 入口 | 什么时候用 | 行为 |
| --- | --- | --- |
| **桌面程序** `desktop-app.cmd` | 想主动点进去清任务 | 大窗口，看今天清完没有，点「标记完成」或「启动」 |
| **23:30 提醒** 计划任务 | 到点自动跑 | 先看打卡数据：三款都清完就**静默退出**，没清完才弹提醒窗口 |

三款全部完成时会**恭喜你**：彩带庆祝层 + 金色徽章 + 连续打卡天数。

> 打卡按 **每日 04:00 刷新** 计算（和游戏内每日任务刷新时间一致）：0:00–3:59 之间点完成，仍然算前一天。所以凌晨看到日期是“昨天”是正常的。

## 快速开始

1. 双击 **`米哈游每日助手.exe`**（带图标、没有控制台黑框）打开桌面程序。`desktop-app.cmd` 是等效的备用入口。
2. 在「设置」页点「创建桌面快捷方式」，桌面和开始菜单里就会多一个带图标的「米哈游每日助手」。
3. 在「设置」页填好时间（默认 `23:30`）点「保存时间」，注册每日提醒计划任务。

## 桌面程序

窗口 980×680，无边框深色卡片风格，左边是导航，右边是内容：

- **今日委托**
  - 顶部显示日期、今日进度（`n / 3`）和进度条。
  - 每款游戏一张卡片：圆形图标、完成状态、右侧「标记完成 / 撤销标记」和「启动」。
  - 游戏正在运行时按钮会变成「运行中」，不会重复启动。
  - 底部三个按钮：`全部完成，收下今日打卡`、`启动没清完的`、`10 分钟后再提醒`。
  - 三款都清完会自动放庆祝动画（彩带 + 徽章 + 战绩）。
- **打卡记录**：连续天数 / 累计天数 / 历史最长连续、当前称号、下一枚徽章、4 枚徽章墙、最近 5 周日历、最近 4 次打卡。
- **设置**
  - 每天提醒时间（写入计划任务）、启用 / 暂停提醒。
  - 打卡数据：记录文件路径、汇总、「打开所在文件夹」「重新读取」「清空打卡记录」。
  - 快捷方式：一键在桌面 + 开始菜单创建「米哈游每日助手」。
  - 关于：「立即预览提醒弹窗」（强制显示 23:30 的弹窗看看效果）、「打开程序目录」。

窗口操作：**按住标题栏或空白处可以拖动窗口**（点卡片、按钮不会误拖），右上角是「最小化」和「关闭」。

## 23:30 提醒

计划任务每天 23:30 调用 `daily-reminder.ps1`：

1. 先读打卡数据，**今天三款都已完成 → 直接退出**，不打扰你。
2. 还有没完成的 → 弹出提醒窗口，里面有同样的游戏卡片。
3. 弹窗里点「启动未完成的游戏」，会自动拉起没清完的那款（已经在运行的会跳过）。
4. 点「稍后提醒」会起一个独立进程，10 分钟后再来一次。

在桌面程序里标记过「全部完成」的日子，晚上不会重复弹窗。

### 注册 / 修改 / 删除计划任务

```powershell
# 注册（默认 23:30）
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1

# 改时间
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Time 22:00

# 看状态
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Status

# 删除
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Remove
```

这些操作在桌面程序的「设置」页里也能做。

## 打卡奖励机制

- **触发方式**：把三张卡片都点成「已完成」，或者点「全部完成，收下今日打卡」。
- **庆祝层**：金色徽章 + 彩带下落 + 随机鼓励语 + 战绩（连续 N 天 · 累计 M 天 · 称号）+ 下一枚徽章提示。
- **称号**（按连续天数）：2 天「渐入佳境」、4 天「稳定输出」、7 天「自律达人」、14 天「满勤玩家」、30 天「肝帝本色」。
- **徽章**（按连续天数解锁）：3 天「稳定打卡徽章」、7 天「一周满勤徽章」、14 天「半月坚持徽章」、30 天「月度肝帝徽章」。
- **记录文件**：`history.json`，只保存日期和游戏名，没有任何账号信息。

## 手动测试

```powershell
# 看三款游戏的可执行文件路径 + 今天的打卡状态（不开窗口）
powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop-app.ps1 -CheckOnly

# 直接打开桌面程序
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\desktop-app.ps1

# 只想知道 23:30 的提醒今晚会不会弹
powershell -NoProfile -ExecutionPolicy Bypass -File .\daily-reminder.ps1 -CheckComplete

# 立刻预览提醒弹窗（忽略“今天已完成”的判断）
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\daily-reminder.ps1 -Force
```

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `米哈游每日助手.exe` | 双击打开桌面程序（带图标、无控制台窗口的启动器） |
| `desktop-app.cmd` | 备用入口（万一 exe 跑不起来） |
| `desktop-app.ps1` / `desktop-app.xaml` | 桌面程序逻辑 / 界面 |
| `daily-reminder.ps1` / `reminder.xaml` | 23:30 的提醒弹窗逻辑 / 界面 |
| `stats.xaml` | 打卡记录窗口界面（桌面程序和弹窗共用） |
| `result.xaml` | 启动游戏后的结果窗口 |
| `lib.ps1` | 共用库：游戏路径发现与启动、打卡数据读写、统计、庆祝动画、计划任务注册 |
| `setup.ps1` | 注册 / 查看 / 删除计划任务 |
| `history.json` | 打卡记录（自动生成） |
| `assets\app.ico` / `assets\icon-preview.png` | 程序图标（多尺寸） / 各尺寸预览图 |
| `build\make-icon.ps1` | 重新生成图标 |
| `build\build-exe.ps1` + `build\Launcher.cs` | 重新编译 exe |

## 图标与 exe

图标是照着程序的配色画的：**深色圆角方块 + 金色奖章 + 「米」**，一共打包了 256 / 128 / 64 / 48 / 32 / 24 / 16 七个尺寸，小尺寸下会自动省掉「米」字，任务栏、开始菜单、资源管理器里都不糊。

- 桌面程序窗口、23:30 的提醒弹窗、打卡记录窗口、启动结果窗口都会带上这个图标。
- 重新生成图标：`powershell -NoProfile -ExecutionPolicy Bypass -File .\build\make-icon.ps1`
- 重新编译 exe：`powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-exe.ps1`（用 Windows 自带的 C# 编译器 csc.exe，不需要联网，也不用装任何东西）

`米哈游每日助手.exe` 是个约 60 KB 的启动器（`/target:winexe`，所以双击不会闪黑框）：它把同目录的 `desktop-app.ps1` 用隐藏窗口的方式跑起来，失败时会弹一个提示框告诉你缺了什么。**界面和逻辑仍然在同目录的脚本里，所以整个文件夹要一起留着**；想换位置就整个文件夹一起挪。

> 想要“真正的单文件版”（脚本和界面都塞进 exe，第一次运行自动解压到 `%LOCALAPPDATA%`，exe 可以随便放）也能做，说一声就好。

## 说明
## 界面设计规范

深色界面按 **WCAG 2.1 AA** 校准过对比度，改颜色的时候照着这张表来，改完跑一遍校验：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build\check-contrast.ps1
```

| 用途 | 色值 | 说明 |
| --- | --- | --- |
| 窗口底 | `#2C3352 → #181C2C` | 斜向渐变 |
| 卡片 | `12%` 白压在窗口上 | 合成后约 `#454B67` |
| 药丸 / 徽章 / 日历格 | `12~15%` 黑压在卡片上 | **压暗**而不是提亮，给文字留出对比度 |
| 未来日期格 | `28%` 黑 | |
| 主要文字 | `#FFFFFF` / `#D8E0F2` | 卡片上 8.6:1 / 6.5:1 |
| 次要文字 | `#B7C2DE` | 卡片上 4.8:1，药丸上 5.7:1 |
| 小字说明 | `#A6B0CE` | |
| 状态色（金 / 绿 / 蓝 / 红） | `#FFDE9E` / `#7FE0B2` / `#9CC3FF` / `#F6AEA3` | 全部 ≥4.5:1 |

除了颜色，这几条也是照着做的：

- **键盘可用**：按钮、卡片、导航都能 Tab 到，聚焦时有一圈金色描边（模板里的 `IsKeyboardFocused` 触发器）。
- **Esc 退出通道**：桌面程序按 Esc 先收起庆祝层、再关窗口；提醒弹窗按 Esc 等于「取消」。
- **图标按钮有名字**：最小化 / 关闭这类只有符号的按钮带 `AutomationProperties.Name`，读屏能念出来。
- **尊重系统动画设置**：Windows 里关掉「显示动画」后，庆祝层不做动效也不放彩带。
- **动效只动 transform / opacity**：彩带下落用的是 `TranslateTransform.Y`，不碰布局属性，不引起重排。
- **数字等宽**：进度、天数这类数字用 `Typography.NumeralAlignment="Tabular"`，跳动时不会左右抖。
- **破坏性操作可恢复**：清空打卡记录前会先备份成同目录的 `history.backup.json`。

> 这套规范是拿 `ui-ux-pro-max` skill 过完一轮 UI 之后定的：样式选型走「OLED 深色 + 高对比文字」，具体条目来自它的对比度、焦点态、动效和弹层退出通道规则。

## 说明
*** End Patch

- 需要 Windows 10 / 11，游戏通过米哈游启动器安装（本机检测到 `D:\miHoYo Launcher`）。
- 23:30 时电脑要开着、并且已登录 Windows 才会弹窗；如果当时在休眠/关机，任务会在下次开机后尽快补提醒（`StartWhenAvailable`）。
- 界面基于 WPF，脚本要以单线程单元运行，所以命令行里请带 `-STA`（`.cmd` 和计划任务里已经带上了）。
- 游戏直接启动本体程序（`YuanShen.exe` / `StarRail.exe` / `ZenlessZoneZero.exe`），不经过启动器；需要更新时启动器仍会提示。
- 游戏安装位置变化后会自动从注册表重新定位；找不到时卡片会显示「未找到游戏文件」。
- 改外观：桌面程序改 `desktop-app.xaml`，提醒弹窗改 `reminder.xaml`。
- 日志：`%TEMP%\mihoyo-daily-reminder.log`。
