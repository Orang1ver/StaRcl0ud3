#requires -version 5.1
<#
.SYNOPSIS
  米哈游每日助手 · 桌面程序（原神 / 崩坏：星穹铁道 / 绝区零）

.DESCRIPTION
  双击 desktop-app.cmd 打开，或者在设置页里一键创建桌面快捷方式。

  界面分三块：
    今日委托 —— 三张游戏卡，一眼看出今天清完了没有；点「标记完成」写进打卡数据，
               点「启动」直接拉起游戏；三款都清完会放一段庆祝动画。
    打卡记录 —— 连续天数、累计天数、称号、徽章，以及最近 5 周的日历。
    设置     —— 改提醒时间、启用/暂停计划任务、查看数据文件、创建快捷方式。

  打卡数据（history.json）和 23:30 的提醒弹窗共用一份：在桌面程序里标记过
  「全部完成」的日子，晚上不会再来打扰你。

.PARAMETER CheckOnly
  只打印三款游戏的可执行文件路径和今天的打卡状态，不开窗口。

.EXAMPLE
  powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\desktop-app.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop-app.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly
)

. (Join-Path $PSScriptRoot 'lib.ps1')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ============================================================
#  状态
# ============================================================
$script:window     = $null
$script:games      = @()
$script:data       = $null
$script:todayKey   = (Get-ReminderToday).ToString('yyyy-MM-dd')
$script:states     = @()
$script:panel      = 'today'
$script:celebrated = $false
$script:toast      = $null
$script:toastText  = $null
$script:toastTimer = $null

# 三款游戏的圆形图标配色，顺序和 Get-GameList 一致
$script:IconStyles = @(
    @{ Bg = '#2E6FE3C1'; Fg = '#FF9CF3D6' }
    @{ Bg = '#317DB4FF'; Fg = '#FFB9D7FF' }
    @{ Bg = '#2EFFD37E'; Fg = '#FFFFE3A4' }
)

# ============================================================
#  小工具
# ============================================================
function Get-DesktopDateLabel {
    param([datetime]$Date = (Get-Date))

    $weekNames = @('周日', '周一', '周二', '周三', '周四', '周五', '周六')
    return ('{0}月{1}日 · {2}' -f $Date.Month, $Date.Day, $weekNames[[int]$Date.DayOfWeek])
}

function Get-DesktopDoneCount {
    $count = 0
    foreach ($state in @($script:states)) {
        if ($state) { $count++ }
    }
    return $count
}

function Test-DesktopAllDone {
    if (@($script:states).Count -eq 0) { return $false }
    foreach ($state in @($script:states)) {
        if (-not $state) { return $false }
    }
    return $true
}

function Enter-DesktopSingleInstance {
    <#
    已经有一个窗口开着就不再开第二个（双击两次 exe 的情况）。
    拿不到互斥体时一律放行，别因为这个小功能挡住主流程。
    #>
    try {
        $created = $false
        $script:instanceMutex = [System.Threading.Mutex]::new($true, 'Local\MiHoYoDailyHelper', [ref]$created)
        return [bool]$created
    }
    catch {
        return $true
    }
}

function Test-DesktopWindowExists {
    <#
    真的有一个「米哈游每日助手」窗口开着吗？
    万一上次退出时留了个没有窗口的残留进程，互斥体还在，这里就不会把入口挡死。
    #>
    foreach ($item in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($item.MainWindowTitle -like '*米哈游每日助手*') { return $true }
        }
        catch {
            continue
        }
    }
    return $false
}

function Update-DesktopClock {
    if (-not $script:window) { return }
    $label = $script:window.FindName('TitleBarDate')
    if ($label) { $label.Text = (Get-Date).ToString('HH:mm · MM-dd') }
}

function Update-DesktopProgressBar {
    if (-not $script:window) { return }
    $bar = $script:window.FindName('TodayProgressBar')
    if (-not $bar) { return }

    $trackWidth = 0.0
    if ($bar.Parent -and $bar.Parent.ActualWidth -gt 0) {
        $trackWidth = [double]$bar.Parent.ActualWidth
    }
    $total = @($script:states).Count
    if ($total -le 0) {
        $bar.Width = 0
        return
    }
    $bar.Width = [Math]::Round($trackWidth * (Get-DesktopDoneCount) / $total, 1)
}

function Start-DesktopRefresh {
    <# 隔一小会儿再刷一次（刚点过启动，游戏进程需要时间起来） #>
    param([int]$DelayMs = 2500)

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($DelayMs)
    $timer.Add_Tick({
        param($sender, $eventArgs)
        if ($sender) { $sender.Stop() }
        Update-DesktopToday
    })
    $timer.Start()
}

# ============================================================
#  底部轻提示（不打断操作）
# ============================================================
function Show-DesktopToast {
    param(
        [string]$Text,
        [string]$Kind = 'ok'
    )

    $window = $script:window
    if (-not $window) { return }

    $accent = '#FFFFDE9E'
    switch ($Kind) {
        'ok'   { $accent = '#FF7FE0B2' }
        'skip' { $accent = '#FF9CC3FF' }
        'fail' { $accent = '#FFF6AEA3' }
    }

    if (-not $script:toast) {
        $outer = $window.FindName('RootBorder').Child

        $border = New-Object System.Windows.Controls.Border
        $border.CornerRadius = New-Object System.Windows.CornerRadius(12)
        $border.Background = New-UiBrush '#F21B2130'
        $border.BorderThickness = New-Object System.Windows.Thickness(1)
        $border.Padding = New-Object System.Windows.Thickness(15, 9, 15, 9)
        $border.Margin = New-Object System.Windows.Thickness(0, 0, 0, 12)
        $border.HorizontalAlignment = 'Center'
        $border.VerticalAlignment = 'Bottom'
        $border.Opacity = 0
        $border.IsHitTestVisible = $false
        [System.Windows.Controls.Grid]::SetRow($border, 1)
        [System.Windows.Controls.Grid]::SetColumnSpan($border, 2)
        [System.Windows.Controls.Panel]::SetZIndex($border, 80)

        # 注意：这里的变量别叫 $text，会和上面 [string]$Text 参数撞名后被强制转成字符串
        $label = New-Object System.Windows.Controls.TextBlock
        $label.FontSize = 12.5
        $label.TextWrapping = 'Wrap'
        $label.MaxWidth = 560
        $label.TextAlignment = 'Center'
        $label.Foreground = New-UiBrush '#FFE8EDF9'
        $border.Child = $label

        $null = $outer.Children.Add($border)
        $script:toast = $border
        $script:toastText = $label
    }

    $script:toast.BorderBrush = New-UiBrush $accent
    $script:toastText.Text = $Text

    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeIn.To = 1.0
    $fadeIn.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(160))
    $script:toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)

    if (-not $script:toastTimer) {
        $script:toastTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:toastTimer.Interval = [TimeSpan]::FromSeconds(4)
        $script:toastTimer.Add_Tick({
            param($sender, $eventArgs)
            Hide-DesktopToast
        })
    }
    $script:toastTimer.Stop()
    $script:toastTimer.Start()
}

function Hide-DesktopToast {
    if ($script:toastTimer) { $script:toastTimer.Stop() }
    if (-not $script:toast) { return }

    $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeOut.To = 0.0
    $fadeOut.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(260))
    $script:toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
}

# ============================================================
#  今日委托：卡片和进度
# ============================================================
function Update-DesktopGameCard {
    param(
        [int]$Index,
        [bool]$Done
    )

    $window = $script:window
    $game = $script:games[$Index]

    $card = $window.FindName("GameCard$Index")
    $status = $window.FindName("GameStatus$Index")
    $pill = $window.FindName("GamePill$Index")
    $pillText = $window.FindName("GamePillText$Index")
    $toggle = $window.FindName("GameToggle$Index")
    $launch = $window.FindName("GameLaunch$Index")
    $icon = $window.FindName("GameIcon$Index")

    $running = Test-GameRunning -ProcessName $game.ProcessName
    $game.Running = $running

    # 先还原成“未完成”的默认样子，后面按状态覆盖
    $card.Opacity = 1
    $card.IsHitTestVisible = $true
    $card.Background = New-UiBrush '#1FFFFFFF'
    $card.BorderBrush = New-UiBrush '#1FFFFFFF'
    $icon.Opacity = 1
    $toggle.IsEnabled = $true
    $toggle.Content = '标记完成'
    $launch.IsEnabled = $true
    $launch.Content = '启动'

    if (-not $game.Found) {
        $card.Opacity = 0.6
        $pill.Background = New-UiBrush '#26000000'
        $pillText.Text = '未找到'
        $pillText.Foreground = New-UiBrush '#FFFFC9BE'
        $status.Text = '没找到游戏文件，先用米哈游启动器进一次游戏'
        $status.Foreground = New-UiBrush '#FFF6AEA3'
        $launch.IsEnabled = $false
        $launch.Content = '未找到'
        return
    }

    if ($Done) {
        $card.Background = New-UiBrush '#E01C332B'
        $card.BorderBrush = New-UiBrush '#4D34D399'
        $icon.Opacity = 0.6
        $pill.Background = New-UiBrush '#26000000'
        $pillText.Text = '已完成'
        $pillText.Foreground = New-UiBrush '#FFA5EFCB'
        $toggle.Content = '撤销标记'
        if ($running) {
            $status.Text = '今日已清 · 游戏正在运行'
            $launch.IsEnabled = $false
            $launch.Content = '运行中'
        }
        else {
            $status.Text = '今日已清 · 明天 04:00 重新开始'
        }
        $status.Foreground = New-UiBrush '#FF7FE0B2'
        return
    }

    if ($running) {
        $pill.Background = New-UiBrush '#26000000'
        $pillText.Text = '运行中'
        $pillText.Foreground = New-UiBrush '#FFC9E1FF'
        $status.Text = '正在运行 · 领完奖励记得标记完成'
        $status.Foreground = New-UiBrush '#FF9CC3FF'
        $launch.IsEnabled = $false
        $launch.Content = '运行中'
        return
    }

    $pill.Background = New-UiBrush '#26000000'
    $pillText.Text = '未完成'
    $pillText.Foreground = New-UiBrush '#FFB7C2DE'
    $status.Text = '还没清完 · 今天的体力还留着'
    $status.Foreground = New-UiBrush '#FFB7C2DE'
}

function Update-DesktopToday {
    if (-not $script:window) { return }
    $window = $script:window

    $total = @($script:games).Count
    for ($i = 0; $i -lt $total; $i++) {
        Update-DesktopGameCard -Index $i -Done ([bool]$script:states[$i])
    }

    $done = Get-DesktopDoneCount
    # 用 04:00 刷新的口径：凌晨 0-4 点仍然算前一天，和打卡数据保持一致
    $window.FindName('TodayDateText').Text = Get-DesktopDateLabel -Date (Get-ReminderToday)
    $window.FindName('TodayProgressText').Text = '{0} / {1}' -f $done, $total

    $summaryText = '今天三款都还没清，点「标记完成」或者「启动」都行。'
    if ($done -ge $total -and $total -gt 0) {
        $summaryText = '三款都清完了，今天可以安心睡。'
    }
    elseif ($done -gt 0) {
        $left = @()
        for ($i = 0; $i -lt $total; $i++) {
            if (-not $script:states[$i]) { $left += $script:games[$i].Display }
        }
        $summaryText = '已经清完 {0} 款，还差：{1}' -f $done, ($left -join '、')
    }
    $window.FindName('TodaySummaryText').Text = $summaryText

    $stats = Get-ReminderStats -Dates (Get-ReminderHistoryDatesFromDisk -Data $script:data)

    $sideToday = $window.FindName('SideTodayText')
    if ($done -ge $total -and $total -gt 0) {
        $sideToday.Text = '今天已完成'
        $sideToday.Foreground = New-UiBrush '#FF7FE0B2'
    }
    elseif ($done -gt 0) {
        $sideToday.Text = '还差 {0} 款' -f ($total - $done)
        $sideToday.Foreground = New-UiBrush '#FFFFDE9E'
    }
    else {
        $sideToday.Text = '还没打卡'
        $sideToday.Foreground = New-UiBrush '#FFFFFFFF'
    }

    $reward = Get-RewardState -Rules $script:rewards -Data $script:data -Today (Get-ReminderToday)
    $window.FindName('SideStreakValue').Text = '{0} 天' -f $reward.Streak
    $freezeLeft = $reward.FreezePerWeek - $reward.FreezeUsed
    $window.FindName('SideStreakNote').Text = ('累计 {0} 天 · 称号「{1}」· 本周冻结还剩 {2}/{3}' -f $reward.TotalDays, $stats.Title, $freezeLeft, $reward.FreezePerWeek)

    Update-DesktopProgressBar
}

# ============================================================
#  打卡记录 / 设置页
# ============================================================
function Refresh-DesktopRecords {
    if (-not $script:window) { return }

    foreach ($name in @('BadgesPanel', 'CalendarGrid', 'RecentPanel')) {
        $panel = $script:window.FindName($name)
        if ($panel) { $panel.Children.Clear() }
    }
    Update-ReminderStatsVisuals -Window $script:window -Data $script:data
}

function Refresh-DesktopSettings {
    if (-not $script:window) { return }
    $window = $script:window

    $stateText = $window.FindName('TaskStateText')
    $timeInput = $window.FindName('TimeInput')
    $task = Get-ReminderTask

    if ($task) {
        $stateName = '已启用'
        switch ([string]$task.State) {
            'Disabled' { $stateName = '已暂停' }
            'Running'  { $stateName = '正在运行' }
        }

        $clock = Get-ReminderTaskClock -Task $task
        if (-not $clock) { $clock = '23:30' }

        $nextRun = ''
        try {
            $info = Get-ScheduledTaskInfo -TaskName (Get-ReminderTaskName) -ErrorAction Stop
            if ($info -and $info.NextRunTime) {
                $nextRun = ' · 下次运行 ' + ([datetime]$info.NextRunTime).ToString('MM-dd HH:mm')
            }
        }
        catch {
            $nextRun = ''
        }

        $stateText.Text = ('每天 {0} 提醒（{1}）{2}；三款都清完的日子会自动跳过。' -f $clock, $stateName, $nextRun)
        $stateText.Foreground = New-UiBrush '#FF7FE0B2'
        if ($stateName -eq '已暂停') { $stateText.Foreground = New-UiBrush '#FFFFDE9E' }
        $timeInput.Text = $clock
    }
    else {
        $stateText.Text = '还没有注册计划任务。填好时间点「保存时间」，就会按这个时间注册一个。'
        $stateText.Foreground = New-UiBrush '#FFF6AEA3'
        if (-not ([string]$timeInput.Text).Trim()) { $timeInput.Text = '23:30' }
    }

    $path = [string]$script:data.Path
    $window.FindName('DataPathText').Text = '记录文件：' + $path

    $complete = @(Get-ReminderCompleteDays -Data $script:data)
    $partial = @(Get-ReminderPartialDays -Data $script:data)
    $window.FindName('DataSummaryText').Text = ('共 {0} 天有记录：三款全清 {1} 天，只清了一部分 {2} 天。' -f ($complete.Count + $partial.Count), $complete.Count, $partial.Count)

    $window.FindName('AboutText').Text = '打卡数据只记日期和游戏名，不含账号信息。游戏每日 04:00 刷新，所以凌晨 0-4 点仍算前一天。这个窗口和 23:30 的提醒弹窗共用同一份数据。'
}

function Set-DesktopPanel {
    param([string]$Name)

    if (-not $script:window) { return }
    $script:panel = $Name

    $panels = @{ today = 'TodayPanel'; records = 'RecordsPanel'; rewards = 'RewardsPanel'; settings = 'SettingsPanel' }
    foreach ($key in @('today', 'records', 'rewards', 'settings')) {
        $panel = $script:window.FindName($panels[$key])
        if (-not $panel) { continue }
        if ($key -eq $Name) { $panel.Visibility = 'Visible' }
        else { $panel.Visibility = 'Collapsed' }
    }

    $buttons = @{ today = 'NavTodayButton'; records = 'NavRecordsButton'; rewards = 'NavRewardsButton'; settings = 'NavSettingsButton' }
    foreach ($key in @('today', 'records', 'rewards', 'settings')) {
        $button = $script:window.FindName($buttons[$key])
        if (-not $button) { continue }
        if ($key -eq $Name) {
            $button.Background = New-UiBrush '#26F2C463'
            $button.Foreground = New-UiBrush '#FFFFE3A4'
        }
        else {
            $button.Background = [System.Windows.Media.Brushes]::Transparent
            $button.Foreground = New-UiBrush '#FFB7C2DE'
        }
    }

    if ($Name -eq 'records') { Refresh-DesktopRecords }
    if ($Name -eq 'rewards') { Refresh-DesktopRewards }
    if ($Name -eq 'settings') { Refresh-DesktopSettings }
}
# ============================================================
#  奖励中心：等级 / 代币 / 里程碑 / 商店
# ============================================================
function Update-DesktopXpBar {
    <# 经验条宽度跟着卡片走 #>
    if (-not $script:window) { return }
    $bar = $script:window.FindName('XpBar')
    if (-not $bar) { return }

    $state = Get-RewardState -Rules $script:rewards -Data $script:data -Today (Get-ReminderToday)
    $trackWidth = 0.0
    if ($bar.Parent -and $bar.Parent.ActualWidth -gt 0) { $trackWidth = [double]$bar.Parent.ActualWidth }
    $bar.Width = [Math]::Round($trackWidth * [double]$state.LevelProgress, 1)
}

function Refresh-DesktopRewards {
    <# 把奖励中心整页画一遍 #>
    if (-not $script:window) { return }
    $window = $script:window
    if (-not $script:rewards) { $script:rewards = Read-RewardRules }

    $state = Get-RewardState -Rules $script:rewards -Data $script:data -Today (Get-ReminderToday)
    $freezeLeft = $state.FreezePerWeek - $state.FreezeUsed

    # 顶部一行：连续 / 最长 / 冻结
    $nextMilestone = $null
    foreach ($ms in $state.Milestones) {
        if (-not $ms.Unlocked) { $nextMilestone = $ms; break }
    }
    $summary = '连续 {0} 天 · 最长 {1} 天 · 本周冻结还剩 {2}/{3}' -f $state.Streak, $state.BestStreak, $freezeLeft, $state.FreezePerWeek
    if ($nextMilestone) {
        $summary += ' · 再坚持 {0} 天解锁「{1}」' -f $nextMilestone.Remain, $nextMilestone.Title
    }
    else {
        $summary += ' · 里程碑已全部解锁'
    }
    $window.FindName('RewardSummaryText').Text = $summary

    # 等级
    $window.FindName('LevelValue').Text = [string]$state.Level
    $window.FindName('XpText').Text = '{0} / {1} XP　（累计 {2} XP）' -f $state.LevelInto, $state.LevelNeed, $state.Xp
    Update-DesktopXpBar

    # 代币
    $window.FindName('CoinBalanceValue').Text = [string]$state.Balance
    $window.FindName('CoinDetailText').Text = '累计赚 {0} · 已花 {1}' -f $state.CoinEarned, $state.CoinSpent

    # 今天
    $entry = $state.TodayEntry
    if ($entry -and $entry.Complete) {
        $window.FindName('TodayGainText').Foreground = New-UiBrush '#FF7FE0B2'
        $window.FindName('TodayGainText').Text = '三款全清：+{0} 代币 · +{1} XP（连击倍率 ×{2}）' -f [int][Math]::Round($entry.Coin), [int][Math]::Round($entry.Xp), $entry.Multiplier
    }
    elseif ($entry -and $entry.Done -gt 0) {
        $window.FindName('TodayGainText').Foreground = New-UiBrush '#FFFFDE9E'
        $window.FindName('TodayGainText').Text = '已经清完 {0}/{1}：+{2} 代币 · +{3} XP；全部清完还有「全清奖励」' -f $entry.Done, $entry.Required, [int][Math]::Round($entry.Coin), [int][Math]::Round($entry.Xp)
    }
    else {
        $window.FindName('TodayGainText').Foreground = New-UiBrush '#FFB7C2DE'
        $window.FindName('TodayGainText').Text = '今天还没打卡。清完三款有 +45 代币 · +135 XP，连击越高倍率越高。'
    }
    $window.FindName('StreakDetailText').Text = '累计打卡 {0} 天 · 连击倍率 ×{1}（{2} 天封顶 2 倍）' -f $state.TotalDays, $state.TodayMultiplier, 100

    # 里程碑
    $milestones = $window.FindName('MilestonePanel')
    $milestones.Children.Clear()
    foreach ($ms in $state.Milestones) {
        $chip = New-Object System.Windows.Controls.Border
        $chip.CornerRadius = New-Object System.Windows.CornerRadius(12)
        $chip.Padding = New-Object System.Windows.Thickness(14, 9, 14, 9)
        $chip.Margin = New-Object System.Windows.Thickness(0, 0, 8, 8)
        $chip.BorderThickness = New-Object System.Windows.Thickness(1)
        if ($ms.Unlocked) {
            $chip.Background = New-UiBrush '#40F2C463'
            $chip.BorderBrush = New-UiBrush '#80FFD98A'
        }
        else {
            $chip.Background = New-UiBrush '#26000000'
            $chip.BorderBrush = New-UiBrush '#26FFFFFF'
        }

        $stack = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = '{0} 天 · {1}' -f $ms.Days, $ms.Title
        $title.FontSize = 12.5
        $title.HorizontalAlignment = 'Center'
        $title.Foreground = New-UiBrush $(if ($ms.Unlocked) { '#FFFFE3A4' } else { '#FFB7C2DE' })
        $note = New-Object System.Windows.Controls.TextBlock
        if ($ms.Unlocked) { $note.Text = '已解锁 · +{0} 代币' -f $ms.Coin }
        else { $note.Text = '还差 {0} 天 · +{1} 代币' -f $ms.Remain, $ms.Coin }
        $note.FontSize = 11
        $note.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
        $note.HorizontalAlignment = 'Center'
        $note.Foreground = New-UiBrush $(if ($ms.Unlocked) { '#FF7FE0B2' } else { '#FFA6B0CE' })
        $null = $stack.Children.Add($title)
        $null = $stack.Children.Add($note)
        $chip.Child = $stack
        $null = $milestones.Children.Add($chip)
    }

    # 商店
    $shop = $window.FindName('ShopPanel')
    $shop.Children.Clear()
    foreach ($item in (Get-RewardShop -Rules $script:rewards)) {
        $owned = ($item.Price -le $state.Balance)

        $row = New-Object System.Windows.Controls.Border
        $row.CornerRadius = New-Object System.Windows.CornerRadius(12)
        $row.Background = New-UiBrush '#26000000'
        $row.Padding = New-Object System.Windows.Thickness(14, 10, 14, 10)
        $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)

        $grid = New-Object System.Windows.Controls.Grid
        $colA = New-Object System.Windows.Controls.ColumnDefinition
        $colA.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $colB = New-Object System.Windows.Controls.ColumnDefinition
        $colB.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
        $null = $grid.ColumnDefinitions.Add($colA)
        $null = $grid.ColumnDefinitions.Add($colB)

        $text = New-Object System.Windows.Controls.StackPanel
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $item.Title
        $name.FontSize = 13
        $name.Foreground = New-UiBrush '#FFFFFFFF'
        $price = New-Object System.Windows.Controls.TextBlock
        $price.Text = '{0} 代币{1}' -f $item.Price, $(if ($owned) { '' } else { '（还差 ' + ($item.Price - $state.Balance) + '）' })
        $price.FontSize = 11.5
        $price.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
        $price.Foreground = New-UiBrush $(if ($owned) { '#FFFFDE9E' } else { '#FFA6B0CE' })
        $null = $text.Children.Add($name)
        $null = $text.Children.Add($price)

        $button = New-Object System.Windows.Controls.Button
        $button.Content = '兑换'
        $button.Width = 78
        $button.Height = 32
        $button.Style = $window.FindResource('OutlineButton')
        $button.Tag = $item.Id
        $button.IsEnabled = $owned
        $button.VerticalAlignment = 'Center'
        $button.Add_Click({
            param($sender, $eventArgs)
            Invoke-DesktopRedeem -Id ([string]$sender.Tag)
        })
        [System.Windows.Controls.Grid]::SetColumn($button, 1)

        $null = $grid.Children.Add($text)
        $null = $grid.Children.Add($button)
        $row.Child = $grid
        $null = $shop.Children.Add($row)
    }

    # 最近兑换
    $panel = $window.FindName('RedemptionPanel')
    $panel.Children.Clear()
    $history = @($script:data.Redemptions)
    if ($history.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = '还没有兑换记录。攒够代币点上面的「兑换」，这里会留下记录，点错了可以撤销。'
        $empty.FontSize = 11.5
        $empty.TextWrapping = 'Wrap'
        $empty.Foreground = New-UiBrush '#FFA6B0CE'
        $null = $panel.Children.Add($empty)
    }
    else {
        foreach ($record in @($history | Select-Object -Last 5 | Sort-Object { $_.At } -Descending)) {
            $line = New-Object System.Windows.Controls.TextBlock
            $when = ''
            try { $when = ([datetime]$record.At).ToString('MM-dd HH:mm') } catch { $when = [string]$record.At }
            $line.Text = '· {0}　{1} 代币　{2}' -f $record.Title, $record.Price, $when
            $line.FontSize = 11.5
            $line.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
            $line.Foreground = New-UiBrush '#FFB7C2DE'
            $null = $panel.Children.Add($line)
        }
    }
    $window.FindName('UndoRedeemButton').IsEnabled = ($history.Count -gt 0)
}

function Invoke-DesktopRedeem {
    param([string]$Id)

    try {
        $item = Add-RewardRedemption -Data $script:data -Rules $script:rewards -Id $Id
        $left = (Get-RewardState -Rules $script:rewards -Data $script:data -Today (Get-ReminderToday)).Balance
        Show-DesktopToast -Text ('兑换了「{0}」，还剩 {1} 代币。' -f $item.Title, $left) -Kind 'ok'
    }
    catch {
        Show-DesktopToast -Text ([string]$_.Exception.Message) -Kind 'fail'
    }
    Refresh-DesktopRewards
    Update-DesktopToday
}

function Invoke-DesktopUndoRedeem {
    $last = Remove-LastRewardRedemption -Data $script:data
    if ($last) {
        Show-DesktopToast -Text ('已撤销「{0}」，退回 {1} 代币。' -f $last.Title, $last.Price) -Kind 'skip'
    }
    else {
        Show-DesktopToast -Text '没有可撤销的兑换记录。' -Kind 'skip'
    }
    Refresh-DesktopRewards
    Update-DesktopToday
}


# ============================================================
#  交互动作
# ============================================================
function Switch-DesktopGame {
    <# 点「标记完成 / 撤销标记」 #>
    param([int]$Index)

    if ($Index -lt 0 -or $Index -ge @($script:games).Count) { return }

    $game = $script:games[$Index]
    $done = -not [bool]$script:states[$Index]
    $script:states[$Index] = $done
    $null = Set-ReminderGameState -Data $script:data -Date $script:todayKey -Game $game.Display -Done $done

    Update-DesktopToday

    if ($done) {
        Show-DesktopToast -Text ('「{0}」标记完成。' -f $game.Display) -Kind 'ok'
        if (Test-DesktopAllDone) { Start-DesktopCelebration -DelayMs 560 }
    }
    else {
        $script:celebrated = $false
        Show-DesktopToast -Text ('「{0}」已撤销标记。' -f $game.Display) -Kind 'skip'
    }

    if ($script:panel -eq 'records') { Refresh-DesktopRecords }
    if ($script:panel -eq 'rewards') { Refresh-DesktopRewards }
    if ($script:panel -eq 'settings') { Refresh-DesktopSettings }
}

function Complete-DesktopAll {
    <# 点「全部完成，收下今日打卡」 #>
    for ($i = 0; $i -lt @($script:games).Count; $i++) { $script:states[$i] = $true }
    $null = Set-ReminderDayComplete -Data $script:data -Date $script:todayKey
    Update-DesktopToday
    if ($script:panel -eq 'records') { Refresh-DesktopRecords }
    if ($script:panel -eq 'rewards') { Refresh-DesktopRewards }
    if ($script:panel -eq 'settings') { Refresh-DesktopSettings }
    Start-DesktopCelebration -DelayMs 260
}

function Start-DesktopGameWatcher {
    <#
    桌面程序里启动的游戏也一样要有人看着：你关掉游戏之后回来提醒 / 唤出程序。
    设置跟 23:30 的弹窗共用一份 watch.json。
    #>
    param([string[]]$ProcessNames)

    try {
        $settings = Read-ReminderWatchSettings
        if (-not [bool]$settings.Enabled) { return }
        if ([string]$settings.Mode -eq 'none') { return }

        $names = @()
        foreach ($name in @($ProcessNames)) {
            if ($name) { $names += [string]$name }
        }
        if ($names.Count -eq 0) { return }

        $null = Start-ReminderWatcher -ProcessNames $names -Mode ([string]$settings.Mode)
    }
    catch {
        Write-ReminderLog ('桌面程序：看门进程启动失败 ' + $_.Exception.Message)
    }
}

function Start-DesktopGame {
    <# 点单张卡片的「启动」 #>
    param([int]$Index)

    if ($Index -lt 0 -or $Index -ge @($script:games).Count) { return }
    $game = $script:games[$Index]

    if (-not $game.Found) {
        Show-DesktopToast -Text ('没找到「{0}」的游戏文件，先用米哈游启动器进一次游戏。' -f $game.Display) -Kind 'fail'
        return
    }
    if (Test-GameRunning -ProcessName $game.ProcessName) {
        Show-DesktopToast -Text ('「{0}」已经在运行了。' -f $game.Display) -Kind 'skip'
        Update-DesktopToday
        return
    }

    try {
        $folder = Split-Path -Path $game.ExePath -Parent
        Start-Process -FilePath $game.ExePath -WorkingDirectory $folder
        Show-DesktopToast -Text ('正在启动「{0}」，清完记得回来标记完成。' -f $game.Display) -Kind 'ok'
        Write-ReminderLog ('桌面程序：启动 ' + $game.Display)
        Start-DesktopGameWatcher -ProcessNames @($game.ProcessName)
    }
    catch {
        Show-DesktopToast -Text ('「{0}」启动失败：{1}' -f $game.Display, $_.Exception.Message) -Kind 'fail'
        Write-ReminderLog ('桌面程序：启动失败 ' + $_.Exception.Message)
    }
    Start-DesktopRefresh -DelayMs 3000
}

function Invoke-DesktopLaunchMissing {
    <# 点「启动没清完的」 #>
    $checked = @()
    for ($i = 0; $i -lt @($script:games).Count; $i++) {
        if ($script:states[$i]) { $checked += $script:games[$i].Display }
    }

    if (@($script:games).Count -gt 0 -and $checked.Count -ge @($script:games).Count) {
        Show-DesktopToast -Text '三款今天都已经完成了，不用再启动。' -Kind 'skip'
        return
    }

    $results = @(Start-MissingGames -Games $script:games -CheckedNames $checked)
    if ($results.Count -eq 0) {
        Show-DesktopToast -Text '没有需要启动的游戏。' -Kind 'skip'
        return
    }

    $kind = 'ok'
    foreach ($item in $results) {
        if ($item.Kind -eq 'fail') { $kind = 'fail' }
    }
    $lines = @()
    foreach ($item in $results) { $lines += ('● ' + $item.Text) }
    Show-DesktopToast -Text ($lines -join '     ') -Kind $kind

    $watchNames = @()
    for ($i = 0; $i -lt @($script:games).Count; $i++) {
        if ($script:states[$i]) { continue }
        if (-not $script:games[$i].Found) { continue }
        $watchNames += $script:games[$i].ProcessName
    }
    Start-DesktopGameWatcher -ProcessNames $watchNames

    Update-DesktopToday
    Start-DesktopRefresh -DelayMs 3000
}

function Invoke-DesktopSnooze {
    <# 点「10 分钟后再提醒」 #>
    $minutes = 10
    $reminderScript = Join-Path $PSScriptRoot 'daily-reminder.ps1'

    if (-not (Test-Path -LiteralPath $reminderScript)) {
        Show-DesktopToast -Text '找不到 daily-reminder.ps1，没法安排稍后提醒。' -Kind 'fail'
        return
    }

    try {
        $null = Start-ReminderHostProcess -Kind reminder -ExtraArgs @('-DelaySeconds', ([string]($minutes * 60)))
        $when = (Get-Date).AddMinutes($minutes).ToString('HH:mm')
        Show-DesktopToast -Text ('好，{0} 分钟后（{1}）再提醒你；这中间清完了就不会再弹。' -f $minutes, $when) -Kind 'ok'
        Write-ReminderLog ('桌面程序：安排 {0} 分钟后再提醒' -f $minutes)
    }
    catch {
        Show-DesktopToast -Text ('安排稍后提醒失败：{0}' -f $_.Exception.Message) -Kind 'fail'
    }
}

# ============================================================
#  庆祝
# ============================================================
function Start-DesktopCelebration {
    param([int]$DelayMs = 300)

    if ($script:celebrated) { return }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($DelayMs)
    $timer.Add_Tick({
        param($sender, $eventArgs)
        if ($sender) { $sender.Stop() }
        Show-DesktopCelebration
    })
    $timer.Start()
}

function Show-DesktopCelebration {
    if ($script:celebrated) { return }
    $script:celebrated = $true

    $reward = Get-RewardState -Rules $script:rewards -Data $script:data -Today (Get-ReminderToday)
    $gainText = '今日 +{0} 代币 · +{1} XP（倍率 ×{2}）' -f [int][Math]::Round($reward.TodayCoin), [int][Math]::Round($reward.TodayXp), $reward.TodayMultiplier

    $stats = Show-ReminderCelebrationLayer -Window $script:window -MarkComplete -GainText $gainText
    if ($stats) {
        Write-ReminderLog ('桌面程序：今天全部完成，连续 {0} 天，累计 {1} 天' -f $stats.Streak, $stats.Total)
    }

    $script:data = Read-ReminderData
    Update-DesktopToday
    if ($script:panel -eq 'records') { Refresh-DesktopRecords }
    if ($script:panel -eq 'rewards') { Refresh-DesktopRewards }
    if ($script:panel -eq 'settings') { Refresh-DesktopSettings }
}

function Hide-DesktopCelebration {
    Hide-ReminderCelebrationLayer -Window $script:window
    Update-DesktopToday
}

# ============================================================
#  设置页动作
# ============================================================
function Save-DesktopReminderTime {
    $value = ([string]$script:window.FindName('TimeInput').Text).Trim()
    if ($value -notmatch '^\d{1,2}:\d{2}$') {
        Show-DesktopToast -Text '时间要写成 HH:mm，比如 23:30。' -Kind 'fail'
        return
    }

    try {
        $null = Register-ReminderTask -Time $value
        Refresh-DesktopSettings
        Show-DesktopToast -Text ('计划任务已设为每天 {0} 提醒；三款都清完的日子不会打扰你。' -f $value) -Kind 'ok'
        Write-ReminderLog ('桌面程序：注册计划任务，时间 ' + $value)
    }
    catch {
        Show-DesktopToast -Text ('注册计划任务失败：{0}' -f $_.Exception.Message) -Kind 'fail'
        Write-ReminderLog ('桌面程序：注册计划任务失败 ' + $_.Exception.Message)
    }
}

function Set-DesktopTaskEnabled {
    param([bool]$Enabled)

    try {
        if (-not (Get-ReminderTask)) {
            $clock = ([string]$script:window.FindName('TimeInput').Text).Trim()
            if ($clock -notmatch '^\d{1,2}:\d{2}$') { $clock = '23:30' }
            $null = Register-ReminderTask -Time $clock
        }

        if ($Enabled) {
            Enable-ScheduledTask -TaskName (Get-ReminderTaskName) -ErrorAction Stop | Out-Null
        }
        else {
            Disable-ScheduledTask -TaskName (Get-ReminderTaskName) -ErrorAction Stop | Out-Null
        }

        Refresh-DesktopSettings
        if ($Enabled) { Show-DesktopToast -Text '提醒已经启用。' -Kind 'ok' }
        else { Show-DesktopToast -Text '提醒已暂停，随时可以再启用。' -Kind 'skip' }
    }
    catch {
        Show-DesktopToast -Text ('操作计划任务失败：{0}' -f $_.Exception.Message) -Kind 'fail'
    }
}

function Open-DesktopDataFolder {
    $path = [string]$script:data.Path
    if (-not $path) { return }
    $folder = Split-Path -Path $path -Parent
    if (Test-Path -LiteralPath $folder) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
    }
    else {
        Show-DesktopToast -Text '还没有生成记录文件，先在今日委托里标记一次完成。' -Kind 'skip'
    }
}

function Register-DesktopShortcut {
    <# 在桌面和开始菜单各放一个快捷方式：优先指向带图标的 exe，没有 exe 就用 powershell 跑脚本 #>
    $windowPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $appScript = Join-Path $PSScriptRoot 'desktop-app.ps1'
    $appExe = Join-Path $PSScriptRoot '米哈游每日助手.exe'
    $iconPath = Join-Path $PSScriptRoot 'assets\app.ico'

    $targets = New-Object System.Collections.Generic.List[string]
    $targets.Add((Join-Path ([Environment]::GetFolderPath('Desktop')) '米哈游每日助手.lnk'))
    $programs = [Environment]::GetFolderPath('Programs')
    if ($programs) { $targets.Add((Join-Path $programs '米哈游每日助手.lnk')) }

    $shell = New-Object -ComObject WScript.Shell
    $created = @()
    foreach ($file in $targets) {
        try {
            $shortcut = $shell.CreateShortcut($file)
            if (Test-Path -LiteralPath $appExe) {
                $shortcut.TargetPath = $appExe
                $shortcut.Arguments = ''
            }
            else {
                $shortcut.TargetPath = $windowPowerShell
                $shortcut.Arguments = ('-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "{0}"' -f $appScript)
            }
            $shortcut.WorkingDirectory = $PSScriptRoot
            if (Test-Path -LiteralPath $iconPath) {
                $shortcut.IconLocation = $iconPath
            }
            else {
                $shortcut.IconLocation = ('{0},0' -f $windowPowerShell)
            }
            $shortcut.Description = '米哈游每日助手 · 看看今天三款游戏清完了没有'
            $shortcut.Save()
            $created += $file
        }
        catch {
            Write-ReminderLog ('创建快捷方式失败：' + $file + ' | ' + $_.Exception.Message)
        }
    }
    return $created
}

function Reset-DesktopData {
    $answer = [System.Windows.MessageBox]::Show(
        $script:window,
        '确定要清空所有打卡记录吗？清空之后连续天数会从 0 重新开始算。',
        '清空打卡记录',
        'YesNo',
        'Warning')
    if ($answer -ne 'Yes') { return }

    # 清空之前先留一份备份，写错了还能捞回来
    $backupPath = $null
    $historyPath = [string]$script:data.Path
    if ($historyPath -and (Test-Path -LiteralPath $historyPath)) {
        $backupPath = Join-Path (Split-Path -Path $historyPath -Parent) 'history.backup.json'
        try {
            Copy-Item -LiteralPath $historyPath -Destination $backupPath -Force
        }
        catch {
            $backupPath = $null
            Write-ReminderLog ('备份打卡记录失败：' + $_.Exception.Message)
        }
    }

    $script:data.Days = @{}
    $null = Save-ReminderData -Data $script:data
    $script:states = New-Object bool[] @($script:games).Count
    $script:celebrated = $false
    Update-DesktopToday
    Refresh-DesktopRecords
    Refresh-DesktopSettings
    if ($backupPath) {
        Show-DesktopToast -Text ('打卡记录已经清空了，清空前的那份备份在同目录的 history.backup.json。') -Kind 'skip'
    }
    else {
        Show-DesktopToast -Text '打卡记录已经清空了。' -Kind 'skip'
    }
    Write-ReminderLog '桌面程序：清空打卡记录'
}

function Open-DesktopReminderPreview {
    $reminderScript = Join-Path $PSScriptRoot 'daily-reminder.ps1'

    if (-not (Test-Path -LiteralPath $reminderScript)) {
        Show-DesktopToast -Text '找不到 daily-reminder.ps1。' -Kind 'fail'
        return
    }

    try {
        $null = Start-ReminderHostProcess -Kind reminder -ExtraArgs @('-Force')
        Show-DesktopToast -Text '已经打开 23:30 的提醒弹窗（强制显示，方便看效果）。' -Kind 'skip'
    }
    catch {
        Show-DesktopToast -Text ('打开提醒弹窗失败：{0}' -f $_.Exception.Message) -Kind 'fail'
    }
}

function Open-DesktopAppFolder {
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $PSScriptRoot)
}

# ============================================================
#  建窗口 + 接线
# ============================================================
function New-DesktopWindow {
    $xamlPath = Join-Path $PSScriptRoot 'desktop-app.xaml'
    if (-not (Test-Path -LiteralPath $xamlPath)) {
        throw "找不到界面文件：$xamlPath"
    }

    $xaml = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $script:window = $window
    Set-ReminderWindowIcon -Window $window

    # ---- 数据 ----
    $script:todayKey = (Get-ReminderToday).ToString('yyyy-MM-dd')
    $script:games = @(Get-GameList)
    $script:data = Read-ReminderData
    $script:rewards = Read-RewardRules

    $marked = @(Get-ReminderDayGames -Data $script:data -Date $script:todayKey)
    $script:states = New-Object bool[] @($script:games).Count
    for ($i = 0; $i -lt @($script:games).Count; $i++) {
        $script:states[$i] = ($marked -contains $script:games[$i].Display)
    }
    $script:celebrated = $false
    $script:panel = 'today'

    $markedText = '（无）'
    if ($marked.Count -gt 0) { $markedText = $marked -join '、' }
    Write-ReminderLog ('桌面程序启动：今天 {0}，已标记 {1}' -f $script:todayKey, $markedText)

    # ---- 游戏卡片 ----
    for ($i = 0; $i -lt @($script:games).Count; $i++) {
        $index = $i

        $card = $window.FindName("GameCard$i")
        $card.Tag = $index          # 带 Tag 的 Border 不参与窗口拖动

        $style = $script:IconStyles[$index % $script:IconStyles.Count]
        $icon = $window.FindName("GameIcon$i")
        $icon.Background = New-UiBrush $style.Bg
        $window.FindName("GameIconText$i").Foreground = New-UiBrush $style.Fg

        $toggle = $window.FindName("GameToggle$i")
        $toggle.Tag = $index
        $toggle.Add_Click({
            param($sender, $eventArgs)
            Switch-DesktopGame -Index ([int]$sender.Tag)
        })

        $launch = $window.FindName("GameLaunch$i")
        $launch.Tag = $index
        $launch.Add_Click({
            param($sender, $eventArgs)
            Start-DesktopGame -Index ([int]$sender.Tag)
        })
    }

    # ---- 左侧导航 ----
    foreach ($pair in @(@('NavTodayButton', 'today'), @('NavRecordsButton', 'records'), @('NavRewardsButton', 'rewards'), @('NavSettingsButton', 'settings'))) {
        $button = $window.FindName($pair[0])
        $button.Tag = $pair[1]
        $button.Add_Click({
            param($sender, $eventArgs)
            Set-DesktopPanel -Name ([string]$sender.Tag)
        })
    }

    # ---- 今日委托底部 ----
    $window.FindName('CompleteAllButton').Add_Click({
        param($sender, $eventArgs)
        Complete-DesktopAll
    })
    $window.FindName('LaunchMissingButton').Add_Click({
        param($sender, $eventArgs)
        Invoke-DesktopLaunchMissing
    })
    $window.FindName('AppSnoozeButton').Add_Click({
        param($sender, $eventArgs)
        Invoke-DesktopSnooze
    })

    # ---- 设置页 ----
    $window.FindName('SaveTimeButton').Add_Click({
        param($sender, $eventArgs)
        Save-DesktopReminderTime
    })
    $window.FindName('EnableTaskButton').Add_Click({
        param($sender, $eventArgs)
        Set-DesktopTaskEnabled -Enabled $true
    })
    $window.FindName('DisableTaskButton').Add_Click({
        param($sender, $eventArgs)
        Set-DesktopTaskEnabled -Enabled $false
    })
    $window.FindName('OpenDataFolderButton').Add_Click({
        param($sender, $eventArgs)
        Open-DesktopDataFolder
    })
    $window.FindName('RefreshDataButton').Add_Click({
        param($sender, $eventArgs)
        $script:data = Read-ReminderData
        $marked = @(Get-ReminderDayGames -Data $script:data -Date $script:todayKey)
        for ($i = 0; $i -lt @($script:games).Count; $i++) {
            $script:states[$i] = ($marked -contains $script:games[$i].Display)
        }
        Update-DesktopToday
        Refresh-DesktopRecords
        Refresh-DesktopSettings
        Show-DesktopToast -Text '已重新读取打卡数据。' -Kind 'ok'
    })
    $window.FindName('ResetDataButton').Add_Click({
        param($sender, $eventArgs)
        Reset-DesktopData
    })
    $window.FindName('ShortcutButton').Add_Click({
        param($sender, $eventArgs)
        try {
            $files = @(Register-DesktopShortcut)
            if ($files.Count -eq 0) {
                Show-DesktopToast -Text '快捷方式没能创建，看看日志里的原因。' -Kind 'fail'
            }
            else {
                $names = @()
                foreach ($file in $files) { $names += (Split-Path -Path $file -Leaf) }
                Show-DesktopToast -Text ('快捷方式已创建 {0} 个：{1}' -f $files.Count, ($names -join '、')) -Kind 'ok'
            }
        }
        catch {
            Show-DesktopToast -Text ('创建快捷方式失败：{0}' -f $_.Exception.Message) -Kind 'fail'
        }
    })
    $window.FindName('AboutReminderButton').Add_Click({
        param($sender, $eventArgs)
        Open-DesktopReminderPreview
    })
    $window.FindName('OpenFolderButton').Add_Click({
        param($sender, $eventArgs)
        Open-DesktopAppFolder
    })

    # ---- 庆祝层 ----
    $window.FindName('CelebrationAcceptButton').Add_Click({
        param($sender, $eventArgs)
        Hide-DesktopCelebration
        Show-DesktopToast -Text '打卡记录已保存，明天 04:00 见。' -Kind 'ok'
    })
    $window.FindName('CelebrationRecordsButton').Add_Click({
        param($sender, $eventArgs)
        Hide-ReminderCelebrationLayer -Window $script:window
        Set-DesktopPanel -Name 'records'
    })
    $window.FindName('CelebrationBackButton').Add_Click({
        param($sender, $eventArgs)
        Hide-DesktopCelebration
    })

    # ---- 窗口按钮 ----
    $window.FindName('MinimizeButton').Add_Click({
        param($sender, $eventArgs)
        $script:window.WindowState = 'Minimized'
    })
    $window.FindName('CloseMiniButton').Add_Click({
        param($sender, $eventArgs)
        $script:window.Close()
    })

    # ---- 奖励中心：撤销兑换 ----
    $window.FindName('UndoRedeemButton').Add_Click({
        param($sender, $eventArgs)
        Invoke-DesktopUndoRedeem
    })

    # ---- Esc：有庆祝层先收起来，否则关窗（弹层的退出通道） ----
    $window.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -ne [System.Windows.Input.Key]::Escape) { return }
        $layer = $script:window.FindName('CelebrationLayer')
        if ($layer -and $layer.Visibility.ToString() -eq 'Visible') {
            Hide-DesktopCelebration
        }
        else {
            $script:window.Close()
        }
        $eventArgs.Handled = $true
    })

    # ---- 无边框窗口拖动 ----
    Enable-ReminderWindow -Window $window

    # ---- 进度条宽度跟着窗口走 ----
    $track = $window.FindName('TodayProgressBar').Parent
    if ($track) {
        $track.Add_SizeChanged({
            param($sender, $eventArgs)
            Update-DesktopProgressBar
        })
    }
    $xpTrack = $window.FindName('XpBar').Parent
    if ($xpTrack) {
        $xpTrack.Add_SizeChanged({
            param($sender, $eventArgs)
            Update-DesktopXpBar
        })
    }
    $window.Add_Loaded({
        param($sender, $eventArgs)
        Update-DesktopProgressBar
    })
    $window.Add_SizeChanged({
        param($sender, $eventArgs)
        Update-DesktopProgressBar
    })

    # ---- 顶栏时间 ----
    Update-DesktopClock
    $script:clockTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:clockTimer.Interval = [TimeSpan]::FromSeconds(20)
    $script:clockTimer.Add_Tick({
        param($sender, $eventArgs)
        Update-DesktopClock
    })
    $script:clockTimer.Start()

    # ---- 首屏 ----
    Update-DesktopToday
    Set-DesktopPanel -Name 'today'

    # ---- 关窗时收尾：停掉定时器并记一笔日志 ----
    $window.Add_Closed({
        param($sender, $eventArgs)
        if ($script:clockTimer) { $script:clockTimer.Stop() }
        if ($script:toastTimer) { $script:toastTimer.Stop() }
        Write-ReminderLog '桌面程序：窗口已关闭'
    })

    return $window
}

function Show-DesktopApp {
    $window = New-DesktopWindow
    $null = $window.ShowDialog()
    Write-ReminderLog '桌面程序：退出'
}

# ============================================================
#  入口
# ============================================================
if ($CheckOnly) {
    foreach ($game in @(Get-GameList)) {
        $status = '未找到'
        if ($game.Found) { $status = $game.ExePath }
        $running = ''
        if ($game.Running) { $running = '（运行中）' }
        Write-Output ('{0,-16} {1} {2}' -f $game.Display, $status, $running)
    }

    $data = Read-ReminderData
    $todayKey = (Get-ReminderToday).ToString('yyyy-MM-dd')
    $marked = @(Get-ReminderDayGames -Data $data -Date $todayKey)
    $markedText = '（无）'
    if ($marked.Count -gt 0) { $markedText = $marked -join '、' }
    Write-Output ('今天 {0} 已标记：{1}' -f $todayKey, $markedText)
    Write-Output ('记录文件：{0}' -f $data.Path)
    return
}

if ((-not (Enter-DesktopSingleInstance)) -and (Test-DesktopWindowExists)) {
    $null = [System.Windows.MessageBox]::Show(
        '米哈游每日助手已经在运行了，去任务栏看看它。',
        '米哈游每日助手',
        'OK',
        'Information')
    return
}

Show-DesktopApp
