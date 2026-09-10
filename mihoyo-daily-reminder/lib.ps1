#requires -version 5.1
<#
.SYNOPSIS
  米哈游每日助手 · 共享库（桌面程序和 23:30 提醒弹窗都用这一份）

.DESCRIPTION
  包含：游戏路径发现与启动、打卡数据读写（history.json v2）、连续天数/称号/徽章统计、
  WPF 小工具（颜色、无边框窗口拖动）以及打卡记录页的渲染函数。

  这个文件只提供函数，不会自己执行任何逻辑。用法：
    . (Join-Path $PSScriptRoot 'lib.ps1')
#>

function Get-ReminderGames {
    <# 三款游戏的显示名（打卡记录按这个顺序判断“整日完成”） #>
    return @('原神', '崩坏：星穹铁道', '绝区零')
}

function Get-ReminderDataPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    if ($PSScriptRoot) {
        $paths.Add((Join-Path $PSScriptRoot 'history.json'))
    }
    $paths.Add((Join-Path (Join-Path $env:APPDATA 'MiHoYoDailyReminder') 'history.json'))
    return $paths
}

function Read-ReminderData {
    <#
    读取打卡数据（v2）。老版本只有 dates 数组，这里会自动迁移成“三款全部完成”。
    返回对象：@{ Version; Days = @{ 'yyyy-MM-dd' = @('原神', ...) }; Path }
    #>
    param([string[]]$Paths)

    if (-not $Paths) { $Paths = Get-ReminderDataPaths }

    $result = [pscustomobject]@{
        Version = 2
        Days    = @{}
        Path    = $null
    }

    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $json = ConvertFrom-Json -InputObject $raw

            $days = @{}
            if ($json -and $json.PSObject.Properties['days'] -and $json.days) {
                foreach ($prop in $json.days.PSObject.Properties) {
                    $games = @()
                    foreach ($g in @($prop.Value)) {
                        if ($g) { $games += [string]$g }
                    }
                    $days[[string]$prop.Name] = $games
                }
            }
            elseif ($json -and $json.PSObject.Properties['dates'] -and $json.dates) {
                foreach ($d in @($json.dates)) {
                    $key = [string]$d
                    if ($key -match '^\d{4}-\d{2}-\d{2}$') {
                        $days[$key] = @(Get-ReminderGames)
                    }
                }
                if ($days.Count -gt 0) {
                    Write-ReminderLog ("检测到旧版打卡记录，已迁移 {0} 天" -f $days.Count)
                }
            }

            $result.Days = $days
            $result.Path = $p
            return $result
        }
        catch {
            Write-ReminderLog "读取打卡数据失败（$p）：$($_.Exception.Message)"
        }
    }

    $result.Path = (Get-ReminderDataPaths)[0]
    return $result
}

function Save-ReminderData {
    param($Data)

    if (-not $Data) { return $null }

    $daysObject = [ordered]@{}
    foreach ($key in @($Data.Days.Keys | Sort-Object -Descending)) {
        $daysObject[$key] = @($Data.Days[$key])
    }

    $json = [pscustomobject]@{
        version = 2
        updated = (Get-Date).ToString('s')
        days    = $daysObject
    } | ConvertTo-Json -Depth 5

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Data.Path) { $candidates.Add([string]$Data.Path) }
    foreach ($p in (Get-ReminderDataPaths)) {
        if (-not $candidates.Contains($p)) { $candidates.Add($p) }
    }

    foreach ($p in $candidates) {
        try {
            $parent = Split-Path -Path $p -Parent
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                $null = New-Item -ItemType Directory -Path $parent -Force
            }
            [System.IO.File]::WriteAllText($p, $json, [System.Text.UTF8Encoding]::new($false))
            $Data.Path = $p
            return $p
        }
        catch {
            continue
        }
    }
    return $null
}

function Get-ReminderDayGames {
    param($Data, [string]$Date)

    if (-not $Data) { $Data = Read-ReminderData }
    if ($Data.Days.ContainsKey($Date)) { return @($Data.Days[$Date]) }
    return @()
}

function Set-ReminderGameState {
    <#
    标记某天某款游戏是否完成，立刻落盘。
    #>
    param($Data, [string]$Date, [string]$Game, [bool]$Done)

    if (-not $Data) { $Data = Read-ReminderData }

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($g in (Get-ReminderDayGames -Data $Data -Date $Date)) { $list.Add([string]$g) }

    $has = $list.Contains($Game)
    if ($Done -and -not $has) { $list.Add($Game) }
    elseif ((-not $Done) -and $has) { [void]$list.Remove($Game) }

    if ($list.Count -eq 0) { [void]$Data.Days.Remove($Date) }
    else { $Data.Days[$Date] = @($list) }

    return (Save-ReminderData -Data $Data)
}

function Set-ReminderDayComplete {
    <# 把某天直接标成“三款全部完成” #>
    param($Data, [string]$Date)

    if (-not $Data) { $Data = Read-ReminderData }
    $Data.Days[$Date] = @(Get-ReminderGames)
    return (Save-ReminderData -Data $Data)
}

function Test-ReminderDayComplete {
    param($Data, [string]$Date)

    if (-not $Data) { $Data = Read-ReminderData }
    if (-not $Data.Days.ContainsKey($Date)) { return $false }

    $games = @($Data.Days[$Date])
    foreach ($g in (Get-ReminderGames)) {
        if ($games -notcontains $g) { return $false }
    }
    return $true
}

function Get-ReminderCompleteDays {
    param($Data)

    if (-not $Data) { $Data = Read-ReminderData }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Data.Days.Keys)) {
        if (Test-ReminderDayComplete -Data $Data -Date $key) { $list.Add([string]$key) }
    }
    return @($list | Sort-Object -Descending)
}

function Get-ReminderPartialDays {
    param($Data)

    if (-not $Data) { $Data = Read-ReminderData }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Data.Days.Keys)) {
        if (-not (Test-ReminderDayComplete -Data $Data -Date $key)) { $list.Add([string]$key) }
    }
    return @($list | Sort-Object -Descending)
}

function Get-ReminderHistoryDatesFromDisk {
    <# 兼容旧调用：返回“三款全部完成”的日期 #>
    param($Data)

    if (-not $Data) { $Data = Read-ReminderData }
    return Get-ReminderCompleteDays -Data $Data
}


function Write-ReminderLog {
    param([string]$Message)
    try {
        $logPath = Join-Path $env:TEMP 'mihoyo-daily-reminder.log'
        $line = '{0:yyyy-MM-dd HH:mm:ss} [PID {1}] {2}' -f (Get-Date), $PID, $Message
        [System.IO.File]::AppendAllText(
            $logPath,
            $line + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    catch {
        # 日志失败不影响主流程
    }
}

function Get-LauncherRoot {
    <#
    从注册表卸载项里找米哈游启动器的安装目录（三款游戏共用同一个启动器目录）。
    #>
    $views = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($view in $views) {
        if (-not (Test-Path $view)) { continue }
        Get-ChildItem $view -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $props = Get-ItemProperty -Path $_.PSPath -ErrorAction Stop
            }
            catch { return }
            if ($props.DisplayName -and $props.InstallLocation) {
                if ($props.DisplayName -match '原神|星穹|绝区零|崩坏') {
                    if (-not $candidates.Contains($props.InstallLocation)) {
                        $candidates.Add($props.InstallLocation)
                    }
                }
            }
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'games')) {
            return $candidate
        }
    }

    $default = 'D:\miHoYo Launcher'
    if (Test-Path -LiteralPath (Join-Path $default 'games')) {
        return $default
    }
    return $null
}

function Resolve-GameExecutable {
    param(
        [string]$LauncherRoot,
        [string]$SubFolder,
        [string]$ExeName
    )

    if ($LauncherRoot) {
        $direct = Join-Path $LauncherRoot (Join-Path 'games' (Join-Path $SubFolder $ExeName))
        if (Test-Path -LiteralPath $direct) {
            return $direct
        }
    }

    $gamesDir = Join-Path $LauncherRoot 'games'
    if ($LauncherRoot -and (Test-Path -LiteralPath $gamesDir)) {
        $found = Get-ChildItem -LiteralPath $gamesDir -Recurse -File -Filter $ExeName -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '_DLSS5_Backup' } |
            Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }
    return $null
}

function Test-GameRunning {
    param([string]$ProcessName)
    return [bool](Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
}

function Get-GameList {
    $root = Get-LauncherRoot
    if (-not $root) {
        Write-Warning '没有在注册表或默认路径中找到米哈游启动器。'
    }

    $definitions = @(
        @{ Display = '原神';           Folder = 'Genshin Impact Game';    Exe = 'YuanShen.exe' }
        @{ Display = '崩坏：星穹铁道'; Folder = 'Star Rail Game';         Exe = 'StarRail.exe' }
        @{ Display = '绝区零';         Folder = 'ZenlessZoneZero Game';   Exe = 'ZenlessZoneZero.exe' }
    )

    $games = @()
    foreach ($def in $definitions) {
        $exePath = $null
        if ($root) {
            $exePath = Resolve-GameExecutable -LauncherRoot $root -SubFolder $def.Folder -ExeName $def.Exe
        }
        $processName = [System.IO.Path]::GetFileNameWithoutExtension($def.Exe)
        $games += [pscustomobject]@{
            Display     = $def.Display
            ExeName     = $def.Exe
            ExePath     = $exePath
            ProcessName = $processName
            Found       = [bool]$exePath
            Running     = Test-GameRunning -ProcessName $processName
        }
    }
    return $games
}

function New-UiBrush {
    param([string]$Hex)
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    return New-Object System.Windows.Media.SolidColorBrush($color)
}

function Test-ReminderDragAllowed {
    <#
    无边框窗口的拖动判断：点背景/标题可以拖，点卡片和按钮不拖。
    #>
    param($Source, $Root)

    $node = $Source
    $guard = 0
    while ($node -and $node -ne $Root -and $guard -lt 64) {
        $guard++

        if ($node -is [System.Windows.Controls.Primitives.ButtonBase]) { return $false }
        if ($node -is [System.Windows.Controls.Primitives.TextBoxBase]) { return $false }

        if ($node -is [System.Windows.Controls.Border]) {
            $borderName = ''
            if ($node -is [System.Windows.FrameworkElement]) { $borderName = [string]$node.Name }
            if ($node.Tag -ne $null) { return $false }
            if ($borderName -like 'Card*' -or $borderName -like '*Ring*' -or $borderName -eq 'CelebrationCard') { return $false }
        }

        try {
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
        catch {
            $node = $null
        }
    }
    return $true
}

function Add-ReminderDragSupport {
    <#
    给无边框窗口加上“按住空白处/标题可以拖动”的能力。
    #>
    param($Window)

    if (-not $Window) { return }
    $surface = $Window.Content
    if (-not $surface) { return }

    $null = $surface.Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        try {
            if (-not (Test-ReminderDragAllowed -Source $eventArgs.OriginalSource -Root $sender)) { return }
            $target = [System.Windows.Window]::GetWindow($sender)
            if ($target) { $target.DragMove() }
        }
        catch {
            # 鼠标没按住时 DragMove 会抛异常，忽略即可
        }
    })
}

function Enable-ReminderWindow {
    <#
    统一处理无边框窗口：拖动 + 关闭按钮（如果界面里有 CloseButton）。
    #>
    param($Window)

    Add-ReminderDragSupport -Window $Window

    $closeButton = $Window.FindName('CloseButton')
    if ($closeButton) {
        $closeButton.Add_Click({
            param($sender, $eventArgs)
            $target = [System.Windows.Window]::GetWindow($sender)
            if ($target) { $target.Close() }
        })
    }
}

function Set-ReminderWindowIcon {
    <#
    给窗口装上程序图标（assets\app.ico）。
    没有图标文件、或者加载失败时静默跳过，不影响窗口使用。
    #>
    param($Window)

    if (-not $Window) { return }

    $iconPath = Join-Path $PSScriptRoot 'assets\app.ico'
    if (-not (Test-Path -LiteralPath $iconPath)) { return }

    try {
        $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($iconPath)))
    }
    catch {
        # 图标只是好看用的，失败就算了
    }
}

function Get-ReminderToday {
    <#
    米哈游的每日任务在凌晨 4 点刷新，所以 0:00-3:59 之间仍然算前一天。
    提醒本身在 23:30 触发，正常使用不受影响。
    #>
    param([datetime]$Now = (Get-Date))

    return $Now.AddHours(-4).Date
}

function Get-ReminderStats {
    param([string[]]$Dates)

    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in @($Dates)) {
        if ($d) { [void]$set.Add([string]$d) }
    }

    $today = Get-ReminderToday
    $todayKey = $today.ToString('yyyy-MM-dd')
    $doneToday = $set.Contains($todayKey)

    # 今天还没打卡时，从昨天往前数，保留“连续 N 天”的展示
    $cursor = if ($doneToday) { $today } else { $today.AddDays(-1) }
    $streak = 0
    while ($set.Contains($cursor.ToString('yyyy-MM-dd'))) {
        $streak++
        $cursor = $cursor.AddDays(-1)
    }

    if ($streak -ge 30) { $title = '肝帝本色' }
    elseif ($streak -ge 14) { $title = '满勤玩家' }
    elseif ($streak -ge 7) { $title = '自律达人' }
    elseif ($streak -ge 4) { $title = '稳定输出' }
    elseif ($streak -ge 2) { $title = '渐入佳境' }
    elseif ($streak -ge 1) { $title = '开局不错' }
    else { $title = '还没起步' }

    return [pscustomobject]@{
        TodayKey  = $todayKey
        DoneToday = $doneToday
        Streak    = $streak
        Total     = $set.Count
        Title     = $title
    }
}

function Get-ReminderBestStreak {
    param([string[]]$Dates)

    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in @($Dates)) {
        if ($d) { [void]$set.Add([string]$d) }
    }

    $best = 0
    foreach ($key in $set) {
        $day = [datetime]::ParseExact($key, 'yyyy-MM-dd', $null)
        # 只从每段连续打卡的第一天往后数
        if ($set.Contains($day.AddDays(-1).ToString('yyyy-MM-dd'))) { continue }
        $length = 1
        while ($set.Contains($day.AddDays($length).ToString('yyyy-MM-dd'))) {
            $length++
        }
        if ($length -gt $best) { $best = $length }
    }
    return $best
}

function Get-ReminderBadgeList {
    <#
    徽章定义，锁定状态时给出还差几天。
    #>
    $milestones = @(
        @{ Streak = 3;  Name = '稳定打卡徽章'; Stars = 1 }
        @{ Streak = 7;  Name = '一周满勤徽章'; Stars = 2 }
        @{ Streak = 14; Name = '半月坚持徽章'; Stars = 3 }
        @{ Streak = 30; Name = '月度肝帝徽章'; Stars = 4 }
    )

    $list = @()
    foreach ($m in $milestones) {
        $list += [pscustomobject]@{
            Streak   = $m.Streak
            Name     = $m.Name
            Stars    = $m.Stars
            Unlocked = $false
            Remain   = $m.Streak
        }
    }
    return $list
}

function Get-ReminderRewardText {
    param($Stats)

    $milestones = @(
        @{ Streak = 3;  Name = '★ 稳定打卡徽章' }
        @{ Streak = 7;  Name = '★★ 一周满勤徽章' }
        @{ Streak = 14; Name = '★★★ 半月坚持徽章' }
        @{ Streak = 30; Name = '★★★★ 月度肝帝徽章' }
    )

    $earned = '今日打卡徽章 ★'
    $next = $null
    foreach ($m in $milestones) {
        if ($Stats.Streak -ge $m.Streak) { $earned = $m.Name }
        elseif (-not $next) { $next = $m }
    }

    if ($next) {
        return ('奖励：{0} · 再坚持 {1} 天解锁「{2}」' -f $earned, ($next.Streak - $Stats.Streak), $next.Name)
    }
    return ('奖励：{0} · 全部徽章已解锁' -f $earned)
}

function Test-ReminderAllDone {
    param(
        $States,
        $Games
    )

    $anyFound = $false
    for ($i = 0; $i -lt $Games.Count; $i++) {
        if (-not $Games[$i].Found) { continue }
        $anyFound = $true
        if (-not $States[$i]) { return $false }
    }
    return $anyFound
}

function Update-ReminderStreakLabel {
    param(
        $Window,
        $Stats
    )

    if (-not $Window) { return }
    $text = $Window.FindName('StreakText')
    if (-not $text) { return }

    if (-not $Stats) {
        $Stats = Get-ReminderStats -Dates (Get-ReminderHistoryDatesFromDisk)
    }

    if ($Stats.Total -le 0 -and -not $Stats.DoneToday) {
        $text.Visibility = 'Collapsed'
        return
    }

    if ($Stats.DoneToday) {
        $text.Text = '今日已打卡 · 连续 {0} 天 · 累计 {1} 天' -f $Stats.Streak, $Stats.Total
    }
    else {
        $text.Text = '连续 {0} 天 · 累计 {1} 天' -f $Stats.Streak, $Stats.Total
    }
    if ($Stats.Total -gt 0 -and $Stats.Title -ne '还没起步') {
        $text.Text += ' · ' + $Stats.Title
    }
    $text.Visibility = 'Visible'
}

function Start-MissingGames {
    param(
        $Games,
        [string[]]$CheckedNames
    )

    $launched = @()
    $alreadyRunning = @()
    $missing = @()

    foreach ($game in $Games) {
        if ($CheckedNames -contains $game.Display) {
            continue
        }
        if (-not $game.Found) {
            $missing += $game.Display
            continue
        }
        if (Test-GameRunning -ProcessName $game.ProcessName) {
            $alreadyRunning += $game.Display
            continue
        }
        try {
            $folder = Split-Path -Path $game.ExePath -Parent
            Start-Process -FilePath $game.ExePath -WorkingDirectory $folder
            $launched += $game.Display
        }
        catch {
            $missing += $game.Display + '（启动失败：' + $_.Exception.Message + '）'
        }
    }

    $results = @()
    if ($launched.Count -gt 0) {
        $results += [pscustomobject]@{
            Kind = 'launched'
            Text = '已启动：' + ($launched -join '、')
        }
    }
    if ($alreadyRunning.Count -gt 0) {
        $results += [pscustomobject]@{
            Kind = 'skip'
            Text = '已在运行，跳过：' + ($alreadyRunning -join '、')
        }
    }
    if ($missing.Count -gt 0) {
        $results += [pscustomobject]@{
            Kind = 'fail'
            Text = '无法启动：' + ($missing -join '、')
        }
    }

    return $results
}

function Update-ReminderStatsVisuals {
    <#
    把打卡数据画到窗口上（弹窗的打卡记录页和桌面程序共用这一套渲染）。
    界面里需要这些元素名：TodayText / StreakValue / TotalValue / BestValue /
    TitleText / NextBadgeText / BadgesPanel / CalendarGrid / RecentPanel。
    #>
    param($Window, $Data)

    if (-not $Window) { return }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    if (-not $Data) { $Data = Read-ReminderData }

    $dates = @(Get-ReminderCompleteDays -Data $Data)
    $partialDays = @(Get-ReminderPartialDays -Data $Data)
    $stats = Get-ReminderStats -Dates $dates
    $best = Get-ReminderBestStreak -Dates $dates

    $dateSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in $dates) { [void]$dateSet.Add([string]$d) }

    $partialSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in $partialDays) { [void]$partialSet.Add([string]$d) }

    # 头部一行
    $todayText = $Window.FindName('TodayText')
    if ($stats.DoneToday) {
        $todayText.Text = '今天已经打过卡了，连续 {0} 天 · 每日 04:00 刷新' -f $stats.Streak
        $todayText.Foreground = New-UiBrush '#FF7FE0B2'
    }
    elseif ($stats.Streak -gt 0) {
        $todayText.Text = '今天还没打卡 · 昨天为止连续 {0} 天 · 每日 04:00 刷新' -f $stats.Streak
        $todayText.Foreground = New-UiBrush '#FFFFDE9E'
    }
    else {
        $todayText.Text = '还没有打卡记录，今晚清完就能开张'
        $todayText.Foreground = New-UiBrush '#FFB7C2DE'
    }

    $Window.FindName('StreakValue').Text = [string]$stats.Streak
    $Window.FindName('TotalValue').Text = [string]$stats.Total
    $Window.FindName('BestValue').Text = [string]$best

    $titleText = $Window.FindName('TitleText')
    $nextBadgeText = $Window.FindName('NextBadgeText')
    $titleText.Text = if ($stats.Total -gt 0) { '当前称号「{0}」' -f $stats.Title } else { '当前称号「还没起步」' }
    $nextBadgeText.Text = Get-ReminderRewardText -Stats $stats

    # 徽章
    $badgesPanel = $Window.FindName('BadgesPanel')
    $badges = Get-ReminderBadgeList
    foreach ($badge in $badges) {
        if ($stats.Streak -ge $badge.Streak) {
            $badge.Unlocked = $true
            $badge.Remain = 0
        }
        else {
            $badge.Remain = $badge.Streak - $stats.Streak
        }

        $chip = New-Object System.Windows.Controls.Border
        $chip.CornerRadius = New-Object System.Windows.CornerRadius(11)
        $chip.Padding = New-Object System.Windows.Thickness(12, 7, 12, 7)
        $chip.Margin = New-Object System.Windows.Thickness(4, 4, 4, 0)
        if ($badge.Unlocked) {
            $chip.Background = New-UiBrush '#40F2C463'
            $chip.BorderBrush = New-UiBrush '#80FFD98A'
        }
        else {
            $chip.Background = New-UiBrush '#26000000'
            $chip.BorderBrush = New-UiBrush '#26FFFFFF'
        }
        $chip.BorderThickness = New-Object System.Windows.Thickness(1)

        $chipContent = New-Object System.Windows.Controls.StackPanel
        $chipTitle = New-Object System.Windows.Controls.TextBlock
        $chipTitle.Text = ('★' * $badge.Stars) + ' ' + $badge.Name
        $chipTitle.FontSize = 11.5
        $chipTitle.HorizontalAlignment = 'Center'
        $chipTitleColor = '#FFA6B0CE'
        $chipNoteColor = '#FFA6B1CE'
        if ($badge.Unlocked) {
            $chipTitleColor = '#FFFFE3A4'
            $chipNoteColor = '#FF7FE0B2'
        }
        $chipTitle.Foreground = New-UiBrush $chipTitleColor
        $chipNote = New-Object System.Windows.Controls.TextBlock
        if ($badge.Unlocked) { $chipNote.Text = '已解锁' }
        else { $chipNote.Text = '还差 {0} 天' -f $badge.Remain }
        $chipNote.FontSize = 10.5
        $chipNote.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
        $chipNote.HorizontalAlignment = 'Center'
        $chipNote.Foreground = New-UiBrush $chipNoteColor
        $null = $chipContent.Children.Add($chipTitle)
        $null = $chipContent.Children.Add($chipNote)
        $chip.Child = $chipContent
        $null = $badgesPanel.Children.Add($chip)
    }

    # 最近 5 周日历（周一到周日）
    $today = Get-ReminderToday
    $monday = $today.AddDays(-(([int]$today.DayOfWeek + 6) % 7))
    $start = $monday.AddDays(-28)
    $calendarGrid = $Window.FindName('CalendarGrid')
    for ($i = 0; $i -lt 35; $i++) {
        $day = $start.AddDays($i)
        $key = $day.ToString('yyyy-MM-dd')

        $cell = New-Object System.Windows.Controls.Border
        $cell.Width = 33
        $cell.Height = 28
        $cell.Margin = New-Object System.Windows.Thickness(2)
        $cell.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $cell.BorderThickness = New-Object System.Windows.Thickness(1)

        if ($dateSet.Contains($key)) {
            $cell.Background = New-UiBrush '#FFE9B94C'
            $cell.BorderBrush = New-UiBrush '#80FFD98A'
            $textColor = '#FF3A2600'
        }
        elseif ($partialSet.Contains($key)) {
            $cell.Background = New-UiBrush '#2EF2C463'
            $cell.BorderBrush = New-UiBrush '#66FFD98A'
            $textColor = '#FFFFDE9E'
        }
        elseif ($day -gt $today) {
            $cell.Background = New-UiBrush '#47000000'
            $cell.BorderBrush = New-UiBrush '#1FFFFFFF'
            $textColor = '#FF98A2C0'
        }
        else {
            $cell.Background = New-UiBrush '#26000000'
            $cell.BorderBrush = New-UiBrush '#1FFFFFFF'
            $textColor = '#FFA6B0CE'
        }

        $dayText = New-Object System.Windows.Controls.TextBlock
        $dayText.Text = [string]$day.Day
        $dayText.FontSize = 11.5
        $dayText.HorizontalAlignment = 'Center'
        $dayText.VerticalAlignment = 'Center'
        if ($dateSet.Contains($key)) { $dayText.FontWeight = 'Bold' }
        $dayText.Foreground = New-UiBrush $textColor
        $cell.Child = $dayText

        if ($dateSet.Contains($key)) {
            $cell.ToolTip = ('{0} 三款全部完成' -f $key)
        }
        elseif ($partialSet.Contains($key)) {
            $cell.ToolTip = ('{0} 只完成：{1}' -f $key, (@(Get-ReminderDayGames -Data $Data -Date $key) -join '、'))
        }
        elseif ($day -gt $today) {
            $cell.ToolTip = ('{0} 还没到' -f $key)
        }
        else {
            $cell.ToolTip = ('{0} 未打卡' -f $key)
        }

        $null = $calendarGrid.Children.Add($cell)
    }

    # 最近的打卡
    $recentPanel = $Window.FindName('RecentPanel')
    $weekNames = @('周日', '周一', '周二', '周三', '周四', '周五', '周六')
    $recent = @($dates | Sort-Object -Descending | Select-Object -First 4)
    if ($recent.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = '还没有记录。今天清完三款游戏，这里就会有第一条。'
        $empty.FontSize = 12
        $empty.Foreground = New-UiBrush '#FFA6B0CE'
        $null = $recentPanel.Children.Add($empty)
    }
    else {
        foreach ($key in $recent) {
            $row = New-Object System.Windows.Controls.Border
            $row.CornerRadius = New-Object System.Windows.CornerRadius(10)
            $row.Background = New-UiBrush '#26000000'
            $row.Padding = New-Object System.Windows.Thickness(12, 7, 12, 7)
            $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)

            $rowContent = New-Object System.Windows.Controls.Grid
            $colA = New-Object System.Windows.Controls.ColumnDefinition
            $colB = New-Object System.Windows.Controls.ColumnDefinition
            $colB.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
            $colA.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
            $null = $rowContent.ColumnDefinitions.Add($colA)
            $null = $rowContent.ColumnDefinitions.Add($colB)

            $day = [datetime]::ParseExact([string]$key, 'yyyy-MM-dd', $null)
            $left = New-Object System.Windows.Controls.TextBlock
            $left.Text = '{0} {1}' -f $day.ToString('MM-dd'), $weekNames[[int]$day.DayOfWeek]
            $left.FontSize = 12
            $left.Foreground = New-UiBrush '#FFD8E0F2'
            $right = New-Object System.Windows.Controls.TextBlock
            $right.Text = '✓ 已打卡'
            $right.FontSize = 11.5
            $right.HorizontalAlignment = 'Right'
            $right.Foreground = New-UiBrush '#FF7FE0B2'
            [System.Windows.Controls.Grid]::SetColumn($right, 1)

            $null = $rowContent.Children.Add($left)
            $null = $rowContent.Children.Add($right)
            $row.Child = $rowContent
            $null = $recentPanel.Children.Add($row)
        }
    }

}
function New-ReminderConfetti {
    <# 庆祝用的纸屑：一堆小方块从窗口顶上飘下来 #>
    param($Window, [int]$Count = 36)

    if (-not $Window) { return }
    $canvas = $Window.FindName('ConfettiCanvas')
    if (-not $canvas) { return }

    $canvas.Children.Clear()
    $colors = @('#FFF2C463', '#FF7FE0B2', '#FF9CC3FF', '#FFFFDE9E', '#FFF6AEA3', '#FFC7A6FF')
    $random = New-Object System.Random
    $width = 520.0
    if ($canvas.ActualWidth -gt 10) { $width = [double]$canvas.ActualWidth - 20.0 }
    $height = 620.0
    if ($canvas.ActualHeight -gt 10) { $height = [double]$canvas.ActualHeight + 60.0 }

    for ($i = 0; $i -lt $Count; $i++) {
        $rect = New-Object System.Windows.Shapes.Rectangle
        $rect.Width = 5 + $random.Next(6)
        $rect.Height = 9 + $random.Next(9)
        $rect.RadiusX = 2
        $rect.RadiusY = 2
        $rect.Fill = New-UiBrush $colors[$random.Next($colors.Count)]
        $rect.Opacity = 0.5 + $random.NextDouble() * 0.5

        $group = New-Object System.Windows.Media.TransformGroup
        $rotate = New-Object System.Windows.Media.RotateTransform([double]$random.Next(0, 360))
        $translate = New-Object System.Windows.Media.TranslateTransform
        $null = $group.Children.Add($rotate)
        $null = $group.Children.Add($translate)
        $rect.RenderTransform = $group

        [System.Windows.Controls.Canvas]::SetLeft($rect, [double]$random.NextDouble() * $width)
        [System.Windows.Controls.Canvas]::SetTop($rect, -60.0)
        $null = $canvas.Children.Add($rect)

        # 只动 TranslateTransform，不动布局属性，交给 GPU 合成更省 CPU
        $fall = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fall.From = 0.0
        $fall.To = $height + 60.0
        $fall.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(2400 + $random.Next(2000)))
        $fall.BeginTime = [TimeSpan]::FromMilliseconds($random.Next(0, 1800))
        $fall.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $translate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $fall)

        $sway = New-Object System.Windows.Media.Animation.DoubleAnimation
        $sway.From = -14.0
        $sway.To = 14.0
        $sway.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(700 + $random.Next(900)))
        $sway.AutoReverse = $true
        $sway.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $translate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $sway)
    }
}

function Clear-ReminderConfetti {
    param($Window)

    if (-not $Window) { return }
    $canvas = $Window.FindName('ConfettiCanvas')
    if ($canvas) { $canvas.Children.Clear() }
}

function Hide-ReminderCelebrationLayer {
    <# 收起庆祝层（继续清任务时用） #>
    param($Window)

    if (-not $Window) { return }
    $layer = $Window.FindName('CelebrationLayer')
    if (-not $layer) { return }
    Clear-ReminderConfetti -Window $Window
    $layer.Visibility = 'Collapsed'
}

function Show-ReminderCelebrationLayer {
    <#
    “全部完成”庆祝层：写打卡数据、更新称号与奖励文案、放纸屑。
    桌面程序和 23:30 的提醒弹窗共用这一份。
    界面里需要元素名：CelebrationLayer / StreakTagText / CelebrationTitle /
    CelebrationSubtitle / CelebrationStats / CelebrationReward / CelebrationCard / MedalRing。
    返回统计对象（连续/累计/称号），没有庆祝层元素时返回 $null。
    #>
    param($Window, [switch]$MarkComplete)

    if (-not $Window) { return $null }
    $layer = $Window.FindName('CelebrationLayer')
    if (-not $layer) { return $null }

    $todayKey = (Get-ReminderToday).ToString('yyyy-MM-dd')
    if ($MarkComplete) { $historyPath = Set-ReminderDayComplete -Date $todayKey }
    else { $historyPath = (Read-ReminderData).Path }

    $stats = Get-ReminderStats -Dates (Get-ReminderHistoryDatesFromDisk)

    $tagText = $Window.FindName('StreakTagText')
    if ($tagText) {
        if ($stats.Streak -gt 1) { $tagText.Text = '连续 {0} 天完成' -f $stats.Streak }
        else { $tagText.Text = '今日完成' }
    }

    $titleText = $Window.FindName('CelebrationTitle')
    if ($titleText) { $titleText.Text = '今日全部完成！' }

    $subtitleLines = @(
        '三份体力，一点没浪费。今天可以安心睡了。',
        '每日任务全清，原石、星琼、菲林都在路上。',
        '今天的努力，会变成下一次十连的底气。',
        '三款游戏一个都没落下，打卡成功。',
        '体力清空，心情放晴，晚安。'
    )
    $subtitle = $Window.FindName('CelebrationSubtitle')
    if ($subtitle) {
        $subtitle.Text = $subtitleLines[(New-Object System.Random).Next($subtitleLines.Count)]
    }

    $statsText = $Window.FindName('CelebrationStats')
    if ($statsText) {
        $statsText.Text = '连续 {0} 天 · 累计 {1} 天 · 称号「{2}」' -f $stats.Streak, $stats.Total, $stats.Title
    }

    $rewardText = $Window.FindName('CelebrationReward')
    if ($rewardText) { $rewardText.Text = Get-ReminderRewardText -Stats $stats }

    # 尊重系统的「显示动画」设置：关掉了就不放彩带、不做动效
    $motionAllowed = $true
    try { $motionAllowed = [bool][System.Windows.SystemParameters]::ClientAreaAnimation } catch { $motionAllowed = $true }
    $layer.Visibility = 'Visible'
    if ($motionAllowed) {
        # 弹层淡入
        $layer.Opacity = 0
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fade.From = 0.0
        $fade.To = 1.0
        $fade.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(220))
        $layer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

        # 卡片回弹
        $card = $Window.FindName('CelebrationCard')
        if ($card) {
            $scale = New-Object System.Windows.Media.ScaleTransform(0.9, 0.9)
            $card.RenderTransform = $scale
            $back = New-Object System.Windows.Media.Animation.BackEase
            $back.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
            $back.Amplitude = 0.35
            $easeX = $back
            $easeY = $back.Clone()
            $growX = New-Object System.Windows.Media.Animation.DoubleAnimation
            $growX.From = 0.9
            $growX.To = 1.0
            $growX.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(480))
            $growX.EasingFunction = $easeX
            $growY = New-Object System.Windows.Media.Animation.DoubleAnimation
            $growY.From = 0.9
            $growY.To = 1.0
            $growY.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(480))
            $growY.EasingFunction = $easeY
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $growX)
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $growY)
        }

        # 奖章呼吸
        $ring = $Window.FindName('MedalRing')
        if ($ring) {
            $ringScale = New-Object System.Windows.Media.ScaleTransform(1.0, 1.0)
            $ring.RenderTransform = $ringScale
            foreach ($prop in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
                $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
                $pulse.From = 1.0
                $pulse.To = 1.06
                $pulse.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(1100))
                $pulse.AutoReverse = $true
                $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                $pulse.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
                $ringScale.BeginAnimation($prop, $pulse)
            }
        }

        New-ReminderConfetti -Window $Window
    }
    else {
        # 不动画：直接给最终状态
        $layer.Opacity = 1
    }
    Update-ReminderStreakLabel -Window $Window -Stats $stats

    Write-ReminderLog ("庆祝层已显示：连续 {0} 天，累计 {1} 天，记录文件 {2}" -f $stats.Streak, $stats.Total, $historyPath)
    return $stats
}

function Get-ReminderTaskName {
    <# 计划任务名（注册和查询都用这一个） #>
    return 'MiHoYo Daily Reminder'
}

function Get-ReminderTask {
    <# 取计划任务对象，没有注册时返回 $null #>
    param([string]$TaskName = (Get-ReminderTaskName))

    return (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Get-ReminderTaskClock {
    <# 从计划任务里读出提醒时间，返回 HH:mm（读不到返回 $null） #>
    param($Task)

    if (-not $Task) { return $null }
    foreach ($trigger in @($Task.Triggers)) {
        if ($trigger.StartBoundary) {
            try {
                return ([datetime]$trigger.StartBoundary).ToString('HH:mm')
            }
            catch {
                continue
            }
        }
    }
    return $null
}

function Register-ReminderTask {
    <#
    注册（或更新）每天提醒的 Windows 计划任务。
    任务本身只跑 daily-reminder.ps1：已经全部完成的日子会静默退出，不再打扰。
    #>
    param(
        [string]$Time = '23:30',
        [string]$TaskScriptPath,
        [string]$TaskName = (Get-ReminderTaskName)
    )

    if (-not $TaskScriptPath) { $TaskScriptPath = Join-Path $PSScriptRoot 'daily-reminder.ps1' }
    if (-not (Test-Path -LiteralPath $TaskScriptPath)) {
        throw "找不到提醒脚本：$TaskScriptPath"
    }
    if ($Time -notmatch '^\d{1,2}:\d{2}$') {
        throw "时间格式应为 HH:mm，例如 23:30"
    }

    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction `
        -Execute $windowsPowerShell `
        -Argument "-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File `"$TaskScriptPath`""

    $trigger = New-ScheduledTaskTrigger -Daily -At $Time

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
        -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description '每天提醒完成米哈游三款游戏的每日任务与体力；三款都清完的日子不打扰。' `
        -Force | Out-Null

    return (Get-ReminderTask -TaskName $TaskName)
}
