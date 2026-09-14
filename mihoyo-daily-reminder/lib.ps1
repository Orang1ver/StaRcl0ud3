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
    读取打卡数据（v3）。老版本只有 dates 数组，这里会自动迁移成“三款全部完成”。
    返回对象：@{ Version; Days = @{ 'yyyy-MM-dd' = @('原神', ...) }; Redemptions; Path }
    Redemptions 是奖励商店的兑换记录（代币余额由它算出来）。
    #>
    param([string[]]$Paths)

    if (-not $Paths) { $Paths = Get-ReminderDataPaths }

    $result = [pscustomobject]@{
        Version     = 3
        Days        = @{}
        Redemptions = @()
        Path        = $null
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
            $redemptions = @()
            if ($json -and $json.PSObject.Properties['redemptions'] -and $json.redemptions) {
                foreach ($r in @($json.redemptions)) {
                    $redemptions += [pscustomobject]@{
                        Id    = [string]$r.id
                        Title = [string]$r.title
                        Price = [int]$r.price
                        At    = [string]$r.at
                    }
                }
            }
            $result.Redemptions = @($redemptions)
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

    # 安全阀：只认「从文件里读出来的」数据。
    # 手工构造的假数据（比如测试里造的）没有 Path，绝对不能让它落到真实记录上——
    # 之前就因为这个，测试数据把真实打卡记录覆盖过一次。
    if (-not $Data.PSObject.Properties['Path'] -or [string]::IsNullOrWhiteSpace([string]$Data.Path)) {
        Write-ReminderLog '拒绝保存：这份数据没有指定记录文件路径（大概率是测试用的假数据），已跳过写入。'
        return $null
    }

    $daysObject = [ordered]@{}
    foreach ($key in @($Data.Days.Keys | Sort-Object -Descending)) {
        $daysObject[$key] = @($Data.Days[$key])
    }

    $redemptions = @()
    foreach ($r in @($Data.Redemptions)) {
        if (-not $r) { continue }
        $redemptions += [pscustomobject]@{
            id    = [string]$r.Id
            title = [string]$r.Title
            price = [int]$r.Price
            at    = [string]$r.At
        }
    }

    $json = [pscustomobject]@{
        version     = 3
        updated     = (Get-Date).ToString('s')
        days        = $daysObject
        redemptions = $redemptions
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

function Enable-ReminderSoftTopmost {
    <#
    弹窗的置顶策略：弹出来的时候在最上面（免得正打着游戏看不见），
    但你只要切到别的窗口，它立刻取消置顶让开，不再赖在人家头上。
    再点回弹窗，它又会抬上来。

    注意：这是「软置顶」。别改成用 Win32 SetWindowPos 定时重抬的那种硬置顶，
    用户明确说过强制置顶很烦。
    #>
    param($Window)

    if (-not $Window) { return }

    $Window.Topmost = $true

    # Activated / Deactivated 的脚本块要 GetNewClosure()，
    # 不然函数返回后 $Window 就丢了，弹窗会一直卡在置顶状态。
    $raise = { $Window.Topmost = $true }.GetNewClosure()
    $drop = { $Window.Topmost = $false }.GetNewClosure()
    $Window.Add_Activated($raise)
    $Window.Add_Deactivated($drop)
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
    徽章墙。名字和天数都来自 rewards.json 的 milestones，和奖励中心是同一份配置。
    #>
    param($Rules)

    if (-not $Rules) { $Rules = Read-RewardRules }

    $list = @()
    $index = 0
    foreach ($m in (Get-RewardMilestones -Rules $Rules)) {
        $index++
        $stars = [Math]::Min(4, [Math]::Max(1, [int][Math]::Ceiling($index * 4.0 / [Math]::Max(1, @(Get-RewardMilestones -Rules $Rules).Count))))
        $list += [pscustomobject]@{
            Streak   = $m.Days
            Name     = $m.Title
            Stars    = $stars
            Coin     = $m.Coin
            Unlocked = $false
            Remain   = $m.Days
        }
    }
    return $list
}

function Get-ReminderRewardText {
    <# 庆祝层上那行「奖励：…」 #>
    param($Stats, $Rules)

    if (-not $Rules) { $Rules = Read-RewardRules }

    $earned = '今日打卡 ★'
    $next = $null
    $index = 0
    foreach ($m in (Get-RewardMilestones -Rules $Rules)) {
        $index++
        $label = '{0} {1} 天「{2}」' -f ('★' * [Math]::Min(4, $index)), $m.Days, $m.Title
        if ($Stats.Streak -ge $m.Days) { $earned = $label }
        elseif (-not $next) { $next = $m }
    }

    if ($next) {
        return ('奖励：{0} · 再坚持 {1} 天解锁「{2} 天 {3}」' -f $earned, ($next.Days - $Stats.Streak), $next.Days, $next.Title)
    }
    return ('奖励：{0} · 全部里程碑已解锁' -f $earned)
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
        $rules = Read-RewardRules
        $data = Read-ReminderData
        $Stats = Get-ReminderStats -Dates (Get-ReminderHistoryDatesFromDisk -Data $data)
        $Stats.Streak = (Get-RewardState -Rules $rules -Data $data).Streak
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
    # 连击和最长连击走奖励引擎的口径（含「每周一次冻结」，和奖励中心一致）
    $rules = Read-RewardRules
    $reward = Get-RewardState -Rules $rules -Data $Data
    $stats.Streak = $reward.Streak
    $best = $reward.BestStreak

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
    $nextBadgeText.Text = Get-ReminderRewardText -Stats $stats -Rules $rules

    # 徽章
    $badgesPanel = $Window.FindName('BadgesPanel')
    $badges = Get-ReminderBadgeList -Rules $rules
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
    param($Window, [switch]$MarkComplete, [string]$GainText)

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

    # 今日收入（有奖励引擎时由调用方传进来）
    # 注意：局部变量别叫 $gainText，会和 [string]$GainText 参数同名，被转成字符串后 .Text 就没了
    $gainElement = $Window.FindName('CelebrationGain')
    if ($gainElement) {
        if ($GainText) { $gainElement.Text = $GainText }
        else { $gainElement.Text = '' }
    }

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
    任务本身只跑 daily-reminder.ps1：已经全部完成的日子弹「恭喜完成」，没清完才弹提醒窗口。
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

    # 计划任务优先直接调用宿主 exe：任务管理器里看到的是「米哈游每日助手」，
    # 而不是一串 powershell.exe。exe 不在时才退回 powershell -File。
    $hostExe = Get-ReminderHostPath
    if ($hostExe) {
        $action = New-ScheduledTaskAction -Execute $hostExe -Argument '--reminder' -WorkingDirectory $PSScriptRoot
    }
    else {
        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction `
            -Execute $windowsPowerShell `
            -Argument "-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File `"$TaskScriptPath`""
    }

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
        -Description '每天提醒完成米哈游三款游戏的每日任务与体力；三款都清完的日子道一声喜。' `
        -Force | Out-Null

    return (Get-ReminderTask -TaskName $TaskName)
}

# ============================================================
#  奖励引擎（通用，和具体任务无关）
#  ------------------------------------------------------------
#  设计参考 the-forge（MIT）的做法：
#    * 打卡记录是唯一真相，XP / 等级 / 代币全部由它推导，不单独存；
#    * 规则全部放在 rewards.json，改数值不用碰脚本；
#    * 任务名由规则决定，所以「三款游戏」换成「背单词 / 做题」也能直接用。
# ============================================================

function Get-RewardRulePaths {
    <# 规则文件位置：优先程序目录，其次 %APPDATA% #>
    $paths = New-Object System.Collections.Generic.List[string]
    if ($PSScriptRoot) {
        $paths.Add((Join-Path $PSScriptRoot 'rewards.json'))
    }
    $paths.Add((Join-Path (Join-Path $env:APPDATA 'MiHoYoDailyReminder') 'rewards.json'))
    return $paths
}

function Get-DefaultRewardRulesJson {
    <# 没有 rewards.json 时自动写一份默认规则 #>
    return @"
{
  "_note": "奖励规则。改这个文件就能调奖励，不用改脚本。任务名必须和打卡记录里的名字一致。",
  "version": 1,
  "tasks": {
    "原神": { "coin": 10, "xp": 30, "countsForStreak": true },
    "崩坏：星穹铁道": { "coin": 10, "xp": 30, "countsForStreak": true },
    "绝区零": { "coin": 10, "xp": 30, "countsForStreak": true }
  },
  "defaultTask": { "coin": 10, "xp": 30, "countsForStreak": true },
  "allClearBonus": { "coin": 15, "xp": 45 },
  "streak": { "freezePerWeek": 1, "bonusPerDay": 0.01, "bonusCapDays": 100 },
  "weekly": { "grade": 75 },
  "levels": { "curve": "habitica" },
  "milestones": [
    { "days": 7, "title": "一周不断", "coin": 50 },
    { "days": 30, "title": "满月坚持", "coin": 200 },
    { "days": 100, "title": "百日不辍", "coin": 600 },
    { "days": 365, "title": "一年之约", "coin": 2000 }
  ],
  "shop": [
    { "id": "game-hour", "title": "额外一小时游戏", "price": 90 },
    { "id": "milk-tea", "title": "一杯奶茶", "price": 180 },
    { "id": "movie", "title": "看一场电影", "price": 360 },
    { "id": "lazy-day", "title": "一天不做也不心疼", "price": 540 }
  ]
}
"@
}

function Read-RewardRules {
    <#
    读取 rewards.json；没有就写一份默认的。
    返回的对象上会挂一个 Path 属性，方便界面显示规则文件位置。
    #>
    param([string[]]$Paths)

    if (-not $Paths) { $Paths = Get-RewardRulePaths }

    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $rules = ConvertFrom-Json -InputObject $raw
            $rules | Add-Member -NotePropertyName Path -NotePropertyValue $p -Force
            return $rules
        }
        catch {
            Write-ReminderLog ('读取奖励规则失败（' + $p + '）：' + $_.Exception.Message)
        }
    }

    $target = (Get-RewardRulePaths)[0]
    $json = Get-DefaultRewardRulesJson
    try {
        [System.IO.File]::WriteAllText($target, $json, [System.Text.UTF8Encoding]::new($false))
        Write-ReminderLog ('已生成默认奖励规则：' + $target)
    }
    catch {
        Write-ReminderLog ('写入默认奖励规则失败：' + $_.Exception.Message)
    }

    $rules = ConvertFrom-Json -InputObject $json
    $rules | Add-Member -NotePropertyName Path -NotePropertyValue $target -Force
    return $rules
}

function Get-RewardNumber {
    <# 从规则对象里取一个数字，取不到就用默认值 #>
    param($Object, [string]$Name, [double]$Default)

    if ($Object) {
        $prop = $Object.PSObject.Properties[$Name]
        if ($prop -and $prop.Value -ne $null -and "$($prop.Value)" -ne '') {
            try { return [double]$prop.Value } catch { }
        }
    }
    return $Default
}

function Get-RewardTaskRule {
    <# 取某个任务的规则，没配就返回 $null（调用方改用 defaultTask） #>
    param($Rules, [string]$Name)

    if (-not $Rules) { return $null }
    $tasks = $Rules.PSObject.Properties['tasks']
    if (-not $tasks -or -not $tasks.Value) { return $null }
    $prop = $tasks.Value.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-RewardRequiredTasks {
    <# 要全部完成才算「今天清完」的任务（countsForStreak 不为 false 的） #>
    param($Rules)

    $list = New-Object System.Collections.Generic.List[string]
    if ($Rules) {
        $tasks = $Rules.PSObject.Properties['tasks']
        if ($tasks -and $tasks.Value) {
            foreach ($prop in $tasks.Value.PSObject.Properties) {
                $counts = Get-RewardNumber -Object $prop.Value -Name 'countsForStreak' -Default 1
                if ($counts -ne 0) { $list.Add($prop.Name) }
            }
        }
    }
    if ($list.Count -eq 0) {
        foreach ($name in (Get-ReminderGames)) { $list.Add($name) }
    }
    # 注意：不要把 List 直接塞进 @()，PowerShell 5.1 会抛 "Argument types do not match"
    return $list.ToArray()
}

function Get-RewardShop {
    <# 商店里的自定义奖励 #>
    param($Rules)

    $items = @()
    if ($Rules) {
        $shop = $Rules.PSObject.Properties['shop']
        if ($shop -and $shop.Value) {
            foreach ($item in @($shop.Value)) {
                $items += [pscustomobject]@{
                    Id    = [string]$item.id
                    Title = [string]$item.title
                    Price = [int](Get-RewardNumber -Object $item -Name 'price' -Default 100)
                }
            }
        }
    }
    return $items
}

function Get-RewardMilestones {
    <# 里程碑（连续 N 天的奖励），按天数从少到多 #>
    param($Rules)

    $list = @()
    if ($Rules) {
        $ms = $Rules.PSObject.Properties['milestones']
        if ($ms -and $ms.Value) {
            foreach ($item in @($ms.Value)) {
                $list += [pscustomobject]@{
                    Days  = [int](Get-RewardNumber -Object $item -Name 'days' -Default 7)
                    Title = [string]$item.title
                    Coin  = [int](Get-RewardNumber -Object $item -Name 'coin' -Default 0)
                }
            }
        }
    }
    if ($list.Count -eq 0) {
        $list = @(
            [pscustomobject]@{ Days = 7;   Title = '一周不断'; Coin = 50 }
            [pscustomobject]@{ Days = 30;  Title = '满月坚持'; Coin = 200 }
            [pscustomobject]@{ Days = 100; Title = '百日不辍'; Coin = 600 }
            [pscustomobject]@{ Days = 365; Title = '一年之约'; Coin = 2000 }
        )
    }
    return @($list | Sort-Object Days)
}

function Get-RewardWeekKey {
    <# 某一天所在那一周的钥匙（用周一做代表），冻结额度按周计算 #>
    param([datetime]$Date)

    $monday = $Date.AddDays(-(([int]$Date.DayOfWeek + 6) % 7))
    return $monday.ToString('yyyy-MM-dd')
}

function Get-RewardMultiplier {
    <# 连击倍率：线性增长并封顶（100 天 = 2 倍）。不要用指数，指数会把经济搞崩 #>
    param($Rules, [double]$Streak)

    $perDay = Get-RewardNumber -Object $Rules.streak -Name 'bonusPerDay' -Default 0.01
    $capDays = Get-RewardNumber -Object $Rules.streak -Name 'bonusCapDays' -Default 100
    $effective = [Math]::Min($Streak, $capDays)
    if ($effective -lt 0) { $effective = 0 }
    return [Math]::Round(1 + $effective * $perDay, 4)
}

function Get-RewardLevelNeed {
    <# 升到下一级还需要多少 XP #>
    param($Rules, [int]$Level)

    $curve = 'habitica'
    if ($Rules) {
        $levels = $Rules.PSObject.Properties['levels']
        if ($levels -and $levels.Value -and $levels.Value.curve) { $curve = [string]$levels.Value.curve }
    }

    switch ($curve) {
        'linear' {
            # 每级 +25：100 / 125 / 150 …，前期慢、后期不失控
            return 100 + 25 * ($Level - 1)
        }
        'gentle' {
            # 每级贵 6%：100 / 106 / 112 …
            return [int][Math]::Round(100 * [Math]::Pow(1.06, $Level - 1))
        }
        default {
            # Habitica 的曲线（源码实证）：前 4 级便宜，之后二次增长
            if ($Level -lt 5) { return 25 * $Level }
            if ($Level -eq 5) { return 150 }
            return [int]([Math]::Round((($Level * $Level) * 0.25 + 10 * $Level + 139.75) / 10) * 10)
        }
    }
}

function Get-RewardLevelFromXp {
    <# 由总 XP 推等级：返回等级 + 当前等级的进度 #>
    param($Rules, [double]$Xp)

    $level = 1
    $rest = [double]$Xp
    $guard = 0
    while ($guard -lt 500) {
        $guard++
        $need = Get-RewardLevelNeed -Rules $Rules -Level $level
        if ($need -le 0 -or $rest -lt $need) { break }
        $rest -= $need
        $level++
    }
    $nextNeed = Get-RewardLevelNeed -Rules $Rules -Level $level
    return [pscustomobject]@{
        Level    = $level
        Into     = [int][Math]::Round($rest)
        Need     = $nextNeed
        Progress = $(if ($nextNeed -gt 0) { [Math]::Round($rest / $nextNeed, 4) } else { 0 })
    }
}

function Get-RewardDayResult {
    <#
    某一天的基础奖励（不含连击倍率）：逐项给币/经验，全部任务清完再加全清奖励。
    纯函数，不读盘。
    #>
    param($Rules, [string[]]$Items)

    $items = @($Items)
    $coin = 0.0
    $xp = 0.0

    foreach ($name in $items) {
        $rule = Get-RewardTaskRule -Rules $Rules -Name $name
        if (-not $rule -and $Rules) { $rule = $Rules.defaultTask }
        $coin += Get-RewardNumber -Object $rule -Name 'coin' -Default 10
        $xp += Get-RewardNumber -Object $rule -Name 'xp' -Default 30
    }

    $required = Get-RewardRequiredTasks -Rules $Rules
    $done = 0
    foreach ($name in $required) {
        if ($items -contains $name) { $done++ }
    }
    $allClear = ($required.Count -gt 0 -and $done -ge $required.Count)
    if ($allClear) {
        $coin += Get-RewardNumber -Object $Rules.allClearBonus -Name 'coin' -Default 15
        $xp += Get-RewardNumber -Object $Rules.allClearBonus -Name 'xp' -Default 45
    }

    return [pscustomobject]@{
        Coin     = [double]$coin
        Xp       = [double]$xp
        Done     = $done
        Required = $required.Count
        AllClear = $allClear
    }
}

function Get-RewardLedger {
    <#
    按时间顺序把每天的奖励算一遍（整套系统的核心）。
    每一项都带当天结束时的连击、当时生效的倍率、以及是不是靠冻结日桥过去的。

    口径说明：
      * 倍率用「包含当天在内」的连击算（和 Habitica 的 streakBonus 一致）；
      * 今天还没打卡不算断签，也不消耗冻结额度；
      * 冻结额度按周计（freezePerWeek，默认每周 1 次），用完再漏才清零连击；
      * 连击刚好踩到里程碑的当天，把里程碑奖励也算进当天收入。
    #>
    param($Rules, $Data, [datetime]$Today)

    if (-not $Rules) { $Rules = Read-RewardRules }
    if (-not $Data) { $Data = Read-ReminderData }
    if (-not $Today) { $Today = Get-ReminderToday }

    $todayDate = $Today.Date
    $required = Get-RewardRequiredTasks -Rules $Rules
    $freezePerWeek = Get-RewardNumber -Object $Rules.streak -Name 'freezePerWeek' -Default 1
    $milestones = Get-RewardMilestones -Rules $Rules

    $start = $todayDate
    if (@($Data.Days.Keys).Count -gt 0) {
        $oldest = (@($Data.Days.Keys | Sort-Object))[0]
        try { $start = [datetime]::ParseExact([string]$oldest, 'yyyy-MM-dd', $null) } catch { $start = $todayDate }
    }
    $entries = New-Object System.Collections.Generic.List[object]
    $freezeUsed = @{}
    $streak = 0
    $best = 0
    $cursor = $start
    $guard = 0

    while ($cursor -le $todayDate -and $guard -lt 3000) {
        $guard++
        $key = $cursor.ToString('yyyy-MM-dd')
        $items = @(Get-ReminderDayGames -Data $Data -Date $key)

        $done = 0
        foreach ($name in $required) {
            if ($items -contains $name) { $done++ }
        }
        $complete = ($required.Count -gt 0 -and $done -ge $required.Count)

        $bridged = $false
        if ($complete) {
            $streak++
            if ($streak -gt $best) { $best = $streak }
        }
        elseif ($cursor.Date -eq $todayDate) {
            # 今天还没结束，不算断签
        }
        else {
            $weekKey = Get-RewardWeekKey -Date $cursor
            $used = 0
            if ($freezeUsed.ContainsKey($weekKey)) { $used = $freezeUsed[$weekKey] }
            if ($used -lt $freezePerWeek) {
                $freezeUsed[$weekKey] = $used + 1
                $bridged = $true
            }
            else {
                $streak = 0
            }
        }

        $multiplier = Get-RewardMultiplier -Rules $Rules -Streak $streak
        $base = Get-RewardDayResult -Rules $Rules -Items $items

        $milestoneCoin = 0.0
        $milestoneTitle = $null
        if ($complete) {
            foreach ($ms in $milestones) {
                if ($ms.Days -eq $streak -and $ms.Coin -gt 0) {
                    $milestoneCoin += $ms.Coin
                    $milestoneTitle = $ms.Title
                }
            }
        }

        $coin = [Math]::Round($base.Coin * $multiplier, 2) + $milestoneCoin
        $xp = [Math]::Round($base.Xp * $multiplier, 2)

        $entries.Add([pscustomobject]@{
            Date       = $key
            Items      = @($items)
            Done       = $done
            Required   = $required.Count
            Complete   = $complete
            AllClear   = $base.AllClear
            Bridged    = $bridged
            Streak     = $streak
            Multiplier = $multiplier
            BaseCoin   = [double]$base.Coin
            BaseXp     = [double]$base.Xp
            Coin       = [double]$coin
            Xp         = [double]$xp
            Milestone  = $milestoneTitle
        })
        $cursor = $cursor.AddDays(1)
    }

    return $entries.ToArray()
}

function Get-RewardState {
    <#
    奖励总览：等级 / XP / 代币余额 / 连击 / 里程碑 / 今日收入。
    全部由打卡记录 + rewards.json 推导，没有额外状态。
    #>
    param($Rules, $Data, [datetime]$Today)

    if (-not $Rules) { $Rules = Read-RewardRules }
    if (-not $Data) { $Data = Read-ReminderData }
    if (-not $Today) { $Today = Get-ReminderToday }

    $ledger = @(Get-RewardLedger -Rules $Rules -Data $Data -Today $Today)
    $xpTotal = 0.0
    $coinEarned = 0.0
    $best = 0
    $lastComplete = $null
    $completeDays = 0
    foreach ($entry in $ledger) {
        $xpTotal += $entry.Xp
        $coinEarned += $entry.Coin
        if ($entry.Streak -gt $best) { $best = $entry.Streak }
        if ($entry.Complete) {
            $lastComplete = $entry
            $completeDays++
        }
    }

    $todayKey = $Today.ToString('yyyy-MM-dd')
    $todayEntry = $null
    foreach ($entry in $ledger) { if ($entry.Date -eq $todayKey) { $todayEntry = $entry } }

    $weekKey = Get-RewardWeekKey -Date $Today
    $freezePerWeek = Get-RewardNumber -Object $Rules.streak -Name 'freezePerWeek' -Default 1
    $freezeUsedThisWeek = 0
    foreach ($entry in $ledger) {
        if (-not $entry.Bridged) { continue }
        $entryDate = [datetime]::ParseExact($entry.Date, 'yyyy-MM-dd', $null)
        if ((Get-RewardWeekKey -Date $entryDate) -eq $weekKey) { $freezeUsedThisWeek++ }
    }

    $spent = 0
    foreach ($r in @($Data.Redemptions)) { $spent += [int]$r.Price }

    $level = Get-RewardLevelFromXp -Rules $Rules -Xp $xpTotal

    $milestoneList = @()
    foreach ($ms in (Get-RewardMilestones -Rules $Rules)) {
        $unlocked = ($best -ge $ms.Days)
        $milestoneList += [pscustomobject]@{
            Days     = $ms.Days
            Title    = $ms.Title
            Coin     = $ms.Coin
            Unlocked = $unlocked
            Remain   = $(if ($unlocked) { 0 } else { $ms.Days - $best })
        }
    }

    $todayCoin = 0
    $todayXp = 0
    $todayMultiplier = 1
    if ($todayEntry) {
        $todayCoin = $todayEntry.Coin
        $todayXp = $todayEntry.Xp
        $todayMultiplier = $todayEntry.Multiplier
    }

    return [pscustomobject]@{
        Rules            = $Rules
        Ledger           = $ledger
        Xp               = [int][Math]::Round($xpTotal)
        Level            = $level.Level
        LevelInto        = $level.Into
        LevelNeed        = $level.Need
        LevelProgress    = $level.Progress
        CoinEarned       = [int][Math]::Round($coinEarned)
        CoinSpent        = $spent
        Balance          = [int][Math]::Round($coinEarned) - $spent
        Streak           = $(if ($todayEntry) { $todayEntry.Streak } else { 0 })
        BestStreak       = $best
        FreezePerWeek    = $freezePerWeek
        FreezeUsed       = $freezeUsedThisWeek
        Milestones       = @($milestoneList)
        TodayCoin        = $todayCoin
        TodayXp          = $todayXp
        TodayMultiplier  = $todayMultiplier
        TodayEntry       = $todayEntry
        LastCompleteDate = $(if ($lastComplete) { $lastComplete.Date } else { $null })
        TotalDays        = $completeDays
    }
}

function Add-RewardRedemption {
    <# 用代币兑换一个自定义奖励（只记一笔兑换，余额是算出来的） #>
    param($Data, $Rules, [string]$Id)

    if (-not $Data) { $Data = Read-ReminderData }
    if (-not $Rules) { $Rules = Read-RewardRules }

    $item = $null
    foreach ($candidate in (Get-RewardShop -Rules $Rules)) {
        if ($candidate.Id -eq $Id) { $item = $candidate; break }
    }
    if (-not $item) { throw ('商店里没有这个奖励：' + $Id) }

    $state = Get-RewardState -Rules $Rules -Data $Data
    if ($state.Balance -lt $item.Price) {
        throw ('代币不够：需要 {0}，现在只有 {1}' -f $item.Price, $state.Balance)
    }

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Data.Redemptions)) { $list.Add($r) }
    $list.Add([pscustomobject]@{
        Id    = $item.Id
        Title = $item.Title
        Price = $item.Price
        At    = (Get-Date).ToString('s')
    })
    $Data.Redemptions = $list.ToArray()
    $null = Save-ReminderData -Data $Data
    Write-ReminderLog ('兑换奖励：{0}（{1} 代币）' -f $item.Title, $item.Price)
    return $item
}

function Remove-LastRewardRedemption {
    <# 兑换点错了，撤掉最后一条 #>
    param($Data)

    if (-not $Data) { $Data = Read-ReminderData }
    $list = @($Data.Redemptions)
    if ($list.Count -eq 0) { return $null }

    $last = $list[$list.Count - 1]
    if ($list.Count -le 1) { $Data.Redemptions = @() }
    else { $Data.Redemptions = @($list[0..($list.Count - 2)]) }

    $null = Save-ReminderData -Data $Data
    Write-ReminderLog ('撤销兑换：' + $last.Title)
    return $last
}

# ============================================================
#  看门：游戏退出后回来提醒（M3）
#  ------------------------------------------------------------
#  弹窗里点了「启动游戏」之后，起一个独立的看门进程盯着这几个游戏进程：
#  它们全部退出之后，要么重新弹提醒弹窗确认，要么直接把桌面程序唤到前台。
#  设置存在 watch.json，弹窗的「启动结果」里可以直接改。
# ============================================================

function Get-ReminderWatchPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    if ($PSScriptRoot) { $paths.Add((Join-Path $PSScriptRoot 'watch.json')) }
    $paths.Add((Join-Path (Join-Path $env:APPDATA 'MiHoYoDailyReminder') 'watch.json'))
    return $paths
}

function New-ReminderWatchSettings {
    <# 默认：开启、打完后重新弹提醒确认 #>
    return [pscustomobject]@{
        Enabled      = $true
        Mode         = 'ask'      # ask = 重新弹提醒确认 / app = 打开桌面程序 / none = 不管
        MaxHours     = 6
        MinSeconds   = 90
        PollSeconds  = 15
        GraceSeconds = 180
        Path         = ''
    }
}

function Read-ReminderWatchSettings {
    param([string[]]$Paths)

    if (-not $Paths) { $Paths = Get-ReminderWatchPaths }
    $settings = New-ReminderWatchSettings

    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $json = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $json.enabled) { $settings.Enabled = [bool]$json.enabled }
            if ($json.mode) { $settings.Mode = [string]$json.mode }
            if ($json.maxHours) { $settings.MaxHours = [int]$json.maxHours }
            if ($json.minSeconds) { $settings.MinSeconds = [int]$json.minSeconds }
            if ($json.pollSeconds) { $settings.PollSeconds = [int]$json.pollSeconds }
            if ($json.graceSeconds) { $settings.GraceSeconds = [int]$json.graceSeconds }
            $settings.Path = $p
            break
        }
        catch {
            Write-ReminderLog ('读取看门设置失败（' + $p + '）：' + $_.Exception.Message)
        }
    }

    if (-not $settings.Path) { $settings.Path = $Paths[0] }
    if ($settings.Mode -notin @('ask', 'app', 'none')) { $settings.Mode = 'ask' }
    return $settings
}

function Save-ReminderWatchSettings {
    param($Settings, [string]$Path)

    if (-not $Settings) { return $null }
    if (-not $Path) {
        if ($Settings.Path) { $Path = $Settings.Path }
        else { $Path = (Get-ReminderWatchPaths)[0] }
    }

    try {
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
        $json = [pscustomobject]@{
            _note        = '游戏退出后的看门设置：mode = ask（重新弹提醒确认）/ app（打开桌面程序）/ none（不管）'
            enabled      = [bool]$Settings.Enabled
            mode         = [string]$Settings.Mode
            maxHours     = [int]$Settings.MaxHours
            minSeconds   = [int]$Settings.MinSeconds
            pollSeconds  = [int]$Settings.PollSeconds
            graceSeconds = [int]$Settings.GraceSeconds
        } | ConvertTo-Json
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
        $Settings.Path = $Path
        return $Path
    }
    catch {
        Write-ReminderLog ('保存看门设置失败：' + $_.Exception.Message)
        return $null
    }
}

function Get-ReminderAppPath {
    <# 桌面程序入口：优先用打包好的 exe，没有就用 cmd #>
    $exe = Join-Path $PSScriptRoot '米哈游每日助手.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    $cmd = Join-Path $PSScriptRoot 'desktop-app.cmd'
    if (Test-Path -LiteralPath $cmd) { return $cmd }
    return $null
}

function Get-ReminderHostPath {
    <# 独立宿主 exe：它把 PowerShell 引擎装在自己进程里跑脚本，所以不会有 powershell.exe 冒出来 #>
    $exe = Join-Path $PSScriptRoot '米哈游每日助手.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    return $null
}

function Start-ReminderHostProcess {
    <#
    起一个独立进程跑某个脚本。
      优先：米哈游每日助手.exe --reminder / --watch / --desktop / --script <名字>
      退路：exe 不在时（比如只拷了脚本）才回退到 powershell.exe -File
    #>
    param(
        [ValidateSet('desktop', 'reminder', 'watch', 'script')][string]$Kind = 'reminder',
        [string[]]$ExtraArgs = @(),
        [string]$ScriptName = '',
        [switch]$PassThru
    )

    $arguments = @()
    $hostExe = Get-ReminderHostPath

    if ($hostExe) {
        $fileName = $hostExe
        switch ($Kind) {
            'desktop' { $arguments += '--desktop' }
            'watch' { $arguments += '--watch' }
            'script' { $arguments += @('--script', $ScriptName) }
            default { $arguments += '--reminder' }
        }
    }
    else {
        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
            throw '既没有宿主 exe，也没有 Windows PowerShell。'
        }
        $scriptFile = 'daily-reminder.ps1'
        if ($Kind -eq 'watch') { $scriptFile = 'watch-games.ps1' }
        elseif ($Kind -eq 'desktop') { $scriptFile = 'desktop-app.ps1' }
        elseif ($Kind -eq 'script') { $scriptFile = $ScriptName }

        $fileName = $windowsPowerShell
        $arguments += @(
            '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f (Join-Path $PSScriptRoot $scriptFile))
        )
    }

    foreach ($extra in @($ExtraArgs)) { $arguments += $extra }

    $parameters = @{
        FilePath         = $fileName
        WorkingDirectory = $PSScriptRoot
        WindowStyle      = 'Hidden'
    }
    if ($arguments.Count -gt 0) { $parameters.ArgumentList = $arguments }
    if ($PassThru) { $parameters.PassThru = $true }

    return (Start-Process @parameters)
}

function Start-ReminderWatcher {
    <#
    起一个独立进程盯着这些游戏（弹窗脚本不等，免得一直占着计划任务的进程）。
    返回刚起来的看门进程，起不来就返回 $null。
    #>
    param(
        [string[]]$ProcessNames,
        [string]$Mode = 'ask'
    )

    if (-not $ProcessNames -or @($ProcessNames).Count -eq 0) { return $null }
    if (-not $Mode -or $Mode -eq 'none') { return $null }

    $scriptPath = Join-Path $PSScriptRoot 'watch-games.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-ReminderLog '找不到 watch-games.ps1，没法起看门进程'
        return $null
    }

    $settings = Read-ReminderWatchSettings
    $childArgs = @(
        '-ProcessNames', (@($ProcessNames) -join ','),
        '-Mode', $Mode,
        '-MaxHours', [string]([int]$settings.MaxHours),
        '-MinSeconds', [string]([int]$settings.MinSeconds),
        '-PollSeconds', [string]([int]$settings.PollSeconds),
        '-GraceSeconds', [string]([int]$settings.GraceSeconds)
    )

    try {
        $proc = Start-ReminderHostProcess -Kind watch -ExtraArgs $childArgs -PassThru
        Write-ReminderLog ('看门进程已启动：盯 ' + (@($ProcessNames) -join '、') + '，退出后 ' + $Mode + '（PID ' + $proc.Id + '）')
        return $proc
    }
    catch {
        Write-ReminderLog ('看门进程启动失败：' + $_.Exception.Message)
        return $null
    }
}
