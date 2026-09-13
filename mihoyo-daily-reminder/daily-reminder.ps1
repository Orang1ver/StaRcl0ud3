#requires -version 5.1
<#
.SYNOPSIS
  米哈游每日提醒弹窗（原神 / 崩坏：星穹铁道 / 绝区零）

.DESCRIPTION
  每天 23:30 由计划任务调用。先看今天的打卡数据：
    - 还没清完 -> 弹出卡片窗口，可以点卡片标记完成、启动游戏；
    - 已经全部完成 -> 照样弹窗，但弹的是「恭喜完成」的庆祝层（彩带 + 徽章 + 今日收入），
      这一步不会再催你清任务；点「收下祝福」关掉，点「回去再检查一下」能翻到下面的卡片。
  弹窗里的勾选同样写进 history.json，和桌面程序共用一份数据。

.PARAMETER CheckOnly
  只检测并打印三个游戏的可执行文件路径，不弹窗。
.PARAMETER CheckComplete
  只打印今天的完成状态（complete / incomplete）后退出。
.PARAMETER Force
  忽略“今天已完成”的判断，强制弹普通的提醒窗口（给“立即预览提醒弹窗”用；
  已经完成的日子加它也不会进恭喜模式）。
.PARAMETER SkipWhenDone
  今天已经全部完成时直接静默退出，不弹恭喜窗口（看门进程回来时用，
  免得玩完刚关游戏又被恭喜一次）。
.PARAMETER ForceCongrats
  不看打卡数据、也不写打卡数据，直接弹一次「恭喜完成」窗口（预览用）。
.PARAMETER SnoozeMinutes
  点“稍后提醒”后等待的分钟数，默认 10 分钟。
.PARAMETER DelaySeconds
  启动后先等待若干秒再弹窗（“稍后提醒”用的就是这个）。

.PARAMETER NoRun
  只加载函数、不真正跑（自检和调试用）。

.EXAMPLE
  powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\daily-reminder.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\daily-reminder.ps1 -CheckComplete
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$CheckComplete,
    [switch]$Force,
    [switch]$NoRun,
    [switch]$SkipWhenDone,
    [switch]$ForceCongrats,
    [int]$SnoozeMinutes = 10,
    [int]$DelaySeconds = 0
)

. (Join-Path $PSScriptRoot 'lib.ps1')

$script:dialogChoice = 'cancel'
$script:dialogWindow = $null
$script:dialogGames = @()
$script:dialogStates = @()
$script:dialogTodayKey = $null
$script:dialogPreview = $false
function Set-ReminderCardVisual {
    param(
        [int]$Index,
        [bool]$Done,
        [bool]$Running,
        [bool]$Found,
        [object]$Window
    )

    $card = $Window.FindName("Card$Index")
    $statusText = $Window.FindName("StatusText$Index")
    $ringBorder = $Window.FindName("RingBorder$Index")
    $ringText = $Window.FindName("RingText$Index")
    $icon = $Window.FindName("IconCircle$Index")
    $transparent = [System.Windows.Media.Brushes]::Transparent

    if (-not $Found) {
        $card.Opacity = 0.55
        $card.IsHitTestVisible = $false
        $statusText.Text = '未找到游戏文件，将跳过启动'
        $statusText.Foreground = New-UiBrush '#FFF6AEA3'
        $ringBorder.Background = $transparent
        $ringBorder.BorderBrush = New-UiBrush '#66EB9488'
        $ringText.Text = '!'
        $ringText.Foreground = New-UiBrush '#FFF6AEA3'
        return
    }

    $card.Opacity = 1
    $card.IsHitTestVisible = $true

    if ($Done) {
        $card.Background = New-UiBrush '#2634D399'
        $statusText.Foreground = New-UiBrush '#FF7FE0B2'
        if ($Running) {
            $statusText.Text = '已完成 · 正在运行，无需重复启动'
        }
        else {
            $statusText.Text = '已完成 · 今日已清'
        }
        $ringBorder.Background = New-UiBrush '#FF2EDC8F'
        $ringBorder.BorderBrush = $transparent
        $ringText.Text = '✓'
        $ringText.Foreground = New-UiBrush '#FF0A2A1D'
        $icon.Opacity = 0.55
        return
    }

    $card.Background = New-UiBrush '#22FFFFFF'
    $icon.Opacity = 1
    if ($Running) {
        $statusText.Text = '正在运行 · 点卡片标为已完成'
        $statusText.Foreground = New-UiBrush '#FF9CC3FF'
        $ringBorder.Background = $transparent
        $ringBorder.BorderBrush = New-UiBrush '#FF9CC3FF'
        $ringText.Text = '▶'
        $ringText.Foreground = New-UiBrush '#FFCFE4FF'
    }
    else {
        $statusText.Text = '还没清完 · 点卡片标记完成'
        $statusText.Foreground = New-UiBrush '#FFB7C2DE'
        $ringBorder.Background = $transparent
        $ringBorder.BorderBrush = New-UiBrush '#66FFFFFF'
        $ringText.Text = '?'
        $ringText.Foreground = New-UiBrush '#FFD8E0F2'
    }
}

function Show-ReminderCelebration {
    <#
    弹窗里的庆祝层交给 lib.ps1 里的共用实现，
    这里只负责记住“已经庆祝过”，避免重复弹。
    #>
    param($Window, [switch]$Preview)

    $script:celebrationShown = $true
    $script:celebrationPending = $false
    $rules = Read-RewardRules
    $data = Read-ReminderData
    $reward = Get-RewardState -Rules $rules -Data $data
    $gainText = '今日 +{0} 代币 · +{1} XP（倍率 ×{2}）' -f [int][Math]::Round($reward.TodayCoin), [int][Math]::Round($reward.TodayXp), $reward.TodayMultiplier
    if ($Preview) {
        # 预览：只画样子，绝不往打卡记录里写“今天完成了”
        $stats = Show-ReminderCelebrationLayer -Window $Window -GainText $gainText
    }
    else {
        $stats = Show-ReminderCelebrationLayer -Window $Window -MarkComplete -GainText $gainText
    }
    if ($stats) {
        Update-ReminderStreakLabel -Window $Window -Stats $stats
    }
}

function Show-ReminderCongrats {
    <#
    23:30 的那一趟三款已经清完了：弹的是道喜，不是催任务。
    庆祝层直接复用，只把标题 / 副标题换成“已经完成”的说法。
    #>
    param($Window, [switch]$Preview)

    Show-ReminderCelebration -Window $Window -Preview:$Preview

    $titleText = $Window.FindName('CelebrationTitle')
    if ($titleText) { $titleText.Text = '恭喜，今日任务全部完成！' }

    $subtitle = $Window.FindName('CelebrationSubtitle')
    if ($subtitle) { $subtitle.Text = '三款游戏一个都没落下，今天的奖励已经入账。明天 23:30 再见。' }
}

function Set-ReminderCongratsHeader {
    <# 恭喜模式：把卡片窗口的头部文案也换成道喜的话（点「回去再检查一下」会看到它） #>
    param($Window)

    $tag = $Window.FindName('HeaderTagText')
    if ($tag) { $tag.Text = '今日打卡 · 已经完成' }

    $title = $Window.FindName('HeaderTitleText')
    if ($title) { $title.Text = '恭喜，今天全部清完！' }

    $subtitle = $Window.FindName('HeaderSubtitleText')
    if ($subtitle) { $subtitle.Text = '原神 · 星穹铁道 · 绝区零 三款都完成了，奖励已经入账。' }
}

function Hide-ReminderCelebration {
    param($Window)

    Hide-ReminderCelebrationLayer -Window $Window
}

function Show-ReminderStatsDialog {
    param($Owner)

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $xamlPath = Join-Path $PSScriptRoot 'stats.xaml'
    if (-not (Test-Path -LiteralPath $xamlPath)) {
        throw "找不到打卡记录界面文件：$xamlPath"
    }
    $xaml = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)

    $data = Read-ReminderData
    Set-ReminderWindowIcon -Window $window
    Write-ReminderLog ('打开打卡记录：' + (Get-ReminderToday).ToString('yyyy-MM-dd'))

    Update-ReminderStatsVisuals -Window $window -Data $data

    Enable-ReminderWindow -Window $window
    $okButton = $window.FindName('OKButton')
    $okButton.Add_Click({ $window.Close() })

    if ($Owner) {
        $window.Owner = $Owner
        $window.WindowStartupLocation = 'CenterOwner'
    }

    $script:statsWindow = $window
    try {
        $null = $window.ShowDialog()
    }
    finally {
        $script:statsWindow = $null
    }
}

function Show-ReminderDialog {
    <#
    -Completed：这次进来的时候三款就已经清完了（23:30 那道检查），
    弹的是「恭喜完成」，所以藏掉催任务的按钮、开场就把庆祝层铺上去。
    #>
    param($Games, [switch]$Completed, [switch]$Preview)

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $xamlPath = Join-Path $PSScriptRoot 'reminder.xaml'
    if (-not (Test-Path -LiteralPath $xamlPath)) {
        throw "找不到界面文件：$xamlPath"
    }
    $xaml = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)

    $script:dialogWindow = $window
    Set-ReminderWindowIcon -Window $window
    $script:dialogGames = $Games
    $script:dialogTodayKey = (Get-ReminderToday).ToString('yyyy-MM-dd')
    $script:dialogPreview = [bool]$Preview
    $markedToday = @(Get-ReminderDayGames -Date $script:dialogTodayKey)

    $script:dialogStates = New-Object bool[] $Games.Count
    for ($i = 0; $i -lt $Games.Count; $i++) {
        $script:dialogStates[$i] = ($markedToday -contains $Games[$i].Display)
    }
    $script:celebrationShown = $false
    $script:celebrationPending = $false

    $iconStyles = @(
        @{ IconBg = '#2E6FE3C1'; IconFg = '#FF9CF3D6' }
        @{ IconBg = '#317DB4FF'; IconFg = '#FFB9D7FF' }
        @{ IconBg = '#2EFFD37E'; IconFg = '#FFFFE3A4' }
    )

    for ($i = 0; $i -lt $Games.Count; $i++) {
        $card = $window.FindName("Card$i")
        $icon = $window.FindName("IconCircle$i")
        $iconText = $window.FindName("IconText$i")

        if ($card) {
            $card.Tag = $i
            $icon.Background = New-UiBrush $iconStyles[$i].IconBg
            $iconText.Foreground = New-UiBrush $iconStyles[$i].IconFg

            $null = $card.Add_MouseLeftButtonUp({
                param($sender, $eventArgs)
                $idx = [int]$sender.Tag
                $script:dialogStates[$idx] = -not $script:dialogStates[$idx]
                # 同步写进今天的打卡数据，桌面程序那边立刻能看到
                $null = Set-ReminderGameState -Date $script:dialogTodayKey -Game $script:dialogGames[$idx].Display -Done $script:dialogStates[$idx]
                Set-ReminderCardVisual `
                    -Index $idx `
                    -Done $script:dialogStates[$idx] `
                    -Running $script:dialogGames[$idx].Running `
                    -Found $script:dialogGames[$idx].Found `
                    -Window $script:dialogWindow
                if (-not $script:celebrationShown -and -not $script:celebrationPending -and
                    (Test-ReminderAllDone -States $script:dialogStates -Games $script:dialogGames)) {
                    # 停半秒，让用户看到最后一张卡片变成“已完成”，再弹出庆祝
                    $script:celebrationPending = $true
                    $timer = New-Object System.Windows.Threading.DispatcherTimer
                    $timer.Interval = [TimeSpan]::FromMilliseconds(520)
                    $timer.Add_Tick({
                        param($sender, $eventArgs)
                        if ($sender) { $sender.Stop() }
                        try {
                            Show-ReminderCelebration -Window $script:dialogWindow
                        }
                        catch {
                            Write-ReminderLog ("庆祝弹窗显示失败：" + $_.Exception.Message + " | " + $_.InvocationInfo.PositionMessage)
                        }
                    })
                    $timer.Start()
                }
                $eventArgs.Handled = $true
            })

            Set-ReminderCardVisual `
                -Index $i `
                -Done $script:dialogStates[$i] `
                -Running $Games[$i].Running `
                -Found $Games[$i].Found `
                -Window $window
        }
    }

    Update-ReminderStreakLabel -Window $window

    Enable-ReminderWindow -Window $window

    $closeButton = $window.FindName('CloseButton')
    $launchButton = $window.FindName('LaunchButton')
    $doneButton = $window.FindName('DoneButton')
    $snoozeButton = $window.FindName('SnoozeButton')
    if ($SnoozeMinutes -ne 10) {
        $snoozeButton.Content = "$SnoozeMinutes 分钟后提醒"
    }

    $closeButton.Add_Click({
        $script:dialogChoice = 'cancel'
        $script:dialogWindow.Close()
    })
    $launchButton.Add_Click({
        $script:dialogChoice = 'launch'
        $script:dialogWindow.Close()
    })
    $doneButton.Add_Click({
        for ($i = 0; $i -lt $script:dialogGames.Count; $i++) {
            $script:dialogStates[$i] = $true
            Set-ReminderCardVisual `
                -Index $i `
                -Done $true `
                -Running $script:dialogGames[$i].Running `
                -Found $script:dialogGames[$i].Found `
                -Window $script:dialogWindow
        }
        $null = Set-ReminderDayComplete -Date $script:dialogTodayKey
        if (-not $script:celebrationShown -and (Test-ReminderAllDone -States $script:dialogStates -Games $script:dialogGames)) {
            # 先发奖励、再退出；用户点“收下祝福”后才关窗
            Show-ReminderCelebration -Window $script:dialogWindow
            return
        }
        $script:dialogChoice = 'done'
        $script:dialogWindow.Close()
    })
    $snoozeButton.Add_Click({
        $script:dialogChoice = 'snooze'
        $script:dialogWindow.Close()
    })

    $celebrationAcceptButton = $window.FindName('CelebrationAcceptButton')
    $celebrationBackButton = $window.FindName('CelebrationBackButton')
    $celebrationAcceptButton.Add_Click({
        $script:dialogChoice = 'done'
        $script:dialogWindow.Close()
    })
    $celebrationBackButton.Add_Click({
        Hide-ReminderCelebration -Window $script:dialogWindow
    })

    # ---- Esc：有庆祝层先收起来，否则当作「取消」关掉弹窗 ----
    $window.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -ne [System.Windows.Input.Key]::Escape) { return }
        $layer = $script:dialogWindow.FindName('CelebrationLayer')
        if ($layer -and $layer.Visibility.ToString() -eq 'Visible') {
            Hide-ReminderCelebration -Window $script:dialogWindow
        }
        else {
            $script:dialogChoice = 'cancel'
            $script:dialogWindow.Close()
        }
        $eventArgs.Handled = $true
    })

    $statsButton = $window.FindName('StatsButton')
    $celebrationStatsButton = $window.FindName('CelebrationStatsButton')
    $statsButton.Add_Click({
        Show-ReminderStatsDialog -Owner $script:dialogWindow
    })
    $celebrationStatsButton.Add_Click({
        Show-ReminderStatsDialog -Owner $script:dialogWindow
    })

    if ($Completed) {
        # 三款早就清完了：藏掉“启动未完成的游戏 / 稍后提醒”，换成道喜的样子
        if ($Preview) {
            # 预览：卡片全按“已完成”画出来，但不动打卡记录
            for ($i = 0; $i -lt $Games.Count; $i++) {
                $script:dialogStates[$i] = $true
                Set-ReminderCardVisual `
                    -Index $i `
                    -Done $true `
                    -Running $Games[$i].Running `
                    -Found $Games[$i].Found `
                    -Window $window
            }
        }
        $launchButton.Visibility = 'Collapsed'
        $launchButton.IsDefault = $false          # 让回车落到「收下祝福」上
        $snoozeButton.Visibility = 'Collapsed'
        $snoozeSep = $window.FindName('SnoozeSep')
        if ($snoozeSep) { $snoozeSep.Visibility = 'Collapsed' }
        $doneButton.Content = '知道了'
        Set-ReminderCongratsHeader -Window $window
        # 等窗口显示出来再铺庆祝层：这时候才有真实尺寸，彩带不会挤成一团
        $window.Add_Loaded({
            try {
                Show-ReminderCongrats -Window $script:dialogWindow -Preview:$script:dialogPreview
            }
            catch {
                Write-ReminderLog ("恭喜窗口显示失败：" + $_.Exception.Message + " | " + $_.InvocationInfo.PositionMessage)
            }
        })
    }

    $null = $window.ShowDialog()

    $checkedNames = @()
    for ($i = 0; $i -lt $Games.Count; $i++) {
        if ($script:dialogStates[$i]) {
            $checkedNames += $Games[$i].Display
        }
    }
    return [pscustomobject]@{
        Choice  = $script:dialogChoice
        Checked = $checkedNames
    }
}

function Show-LaunchResultDialog {
    <#
    启动结果窗口。顺便让用户选「游戏关掉之后怎么办」：
      ask  = 重新弹这个提醒，让我确认（默认）
      app  = 直接打开桌面程序
      none = 不用管
    返回最终选择，并写进 watch.json。
    #>
    param($Results, [string]$WatchMode = '')

    $settings = Read-ReminderWatchSettings
    if (-not $WatchMode) {
        if ([bool]$settings.Enabled) { $WatchMode = [string]$settings.Mode } else { $WatchMode = 'none' }
    }
    if ($WatchMode -notin @('ask', 'app', 'none')) { $WatchMode = 'ask' }
    $script:watchChoice = $WatchMode

    if ($Results.Count -eq 0) { return $WatchMode }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $xamlPath = Join-Path $PSScriptRoot 'result.xaml'
    if (-not (Test-Path -LiteralPath $xamlPath)) {
        throw "找不到结果窗口界面文件：$xamlPath"
    }
    $xaml = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $messageRows = $window.FindName('MessageRows')
    Set-ReminderWindowIcon -Window $window

    foreach ($item in $Results) {
        $colorHex = switch ($item.Kind) {
            'launched' { '#FF7FE0B2' }
            'skip'     { '#FF9CC3FF' }
            default    { '#FFF6AEA3' }
        }
        $row = New-Object System.Windows.Controls.TextBlock
        $row.Text = '●  ' + $item.Text
        $row.FontSize = 13
        $row.Foreground = New-UiBrush $colorHex
        $row.TextWrapping = 'Wrap'
        $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
        $null = $messageRows.Children.Add($row)
    }

    # ---- 游戏退出后的看门设置 ----
    $divider = New-Object System.Windows.Controls.Border
    $divider.Height = 1
    $divider.Margin = New-Object System.Windows.Thickness(0, 6, 0, 12)
    $divider.Background = New-UiBrush '#33FFFFFF'
    $null = $messageRows.Children.Add($divider)

    $watchTitle = New-Object System.Windows.Controls.TextBlock
    $watchTitle.Text = '游戏关掉之后'
    $watchTitle.FontSize = 12.5
    $watchTitle.FontWeight = 'SemiBold'
    $watchTitle.Foreground = New-UiBrush '#FFFFDE9E'
    $null = $messageRows.Children.Add($watchTitle)

    $watchHint = New-Object System.Windows.Controls.TextBlock
    $watchHint.Text = '会盯着这次启动的游戏，等你全部退出之后：'
    $watchHint.FontSize = 11.5
    $watchHint.Margin = New-Object System.Windows.Thickness(0, 4, 0, 2)
    $watchHint.Foreground = New-UiBrush '#FFB7C2DE'
    $watchHint.TextWrapping = 'Wrap'
    $null = $messageRows.Children.Add($watchHint)

    foreach ($option in @(
            @{ Text = '重新弹这个提醒，让我确认一下'; Value = 'ask' },
            @{ Text = '直接打开桌面程序'; Value = 'app' },
            @{ Text = '不用管，我自己记'; Value = 'none' })) {
        $radio = New-Object System.Windows.Controls.RadioButton
        $radio.Content = $option.Text
        $radio.Tag = $option.Value
        $radio.GroupName = 'WatchMode'
        $radio.FontSize = 12.5
        $radio.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
        $radio.Foreground = New-UiBrush '#FFD8E0F2'
        if ($option.Value -eq $WatchMode) { $radio.IsChecked = $true }
        $radio.Add_Checked({
            param($sender, $eventArgs)
            $script:watchChoice = [string]$sender.Tag
        })
        $null = $messageRows.Children.Add($radio)
    }

    Enable-ReminderWindow -Window $window

    $okButton = $window.FindName('OKButton')
    $okButton.Add_Click({
        $window.Close()
    })

    $null = $window.ShowDialog()

    if (-not $script:watchChoice) { $script:watchChoice = $WatchMode }
    $saved = Read-ReminderWatchSettings
    $saved.Enabled = ($script:watchChoice -ne 'none')
    $saved.Mode = $script:watchChoice
    $null = Save-ReminderWatchSettings -Settings $saved
    Write-ReminderLog ('游戏退出后的处理方式：' + $script:watchChoice)

    return $script:watchChoice
}

function Invoke-DailyReminder {
    if ($DelaySeconds -gt 0) {
        Write-ReminderLog "延迟提醒进程已启动，等待 $DelaySeconds 秒"
        Start-Sleep -Seconds $DelaySeconds
        Write-ReminderLog "延迟结束，准备弹出提醒"
    }

    $games = Get-GameList
    $todayKey = (Get-ReminderToday).ToString('yyyy-MM-dd')
    $data = Read-ReminderData

    if ($CheckOnly) {
        foreach ($game in $games) {
            $status = if ($game.Found) { $game.ExePath } else { '未找到' }
            $running = if ($game.Running) { '（运行中）' } else { '' }
            Write-Output ("{0,-16} {1} {2}" -f $game.Display, $status, $running)
        }
        if ($games.Count -eq 0) {
            Write-Output '没有找到任何游戏。'
        }
        return
    }

    if ($CheckComplete) {
        $complete = Test-ReminderDayComplete -Data $data -Date $todayKey
        $marked = @(Get-ReminderDayGames -Data $data -Date $todayKey)
        Write-Output ('{0} {1}' -f $todayKey, $(if ($complete) { 'complete' } else { 'incomplete' }))
        Write-Output ('已标记：{0}' -f $(if ($marked.Count -gt 0) { $marked -join '、' } else { '（无）' }))
        return
    }

    if ($ForceCongrats) {
        # 预览：不看数据也不写数据，直接弹一次道喜窗口
        Write-ReminderLog '强制预览：直接弹恭喜窗口（不写打卡记录）'
        $preview = Show-ReminderDialog -Games $games -Completed -Preview
        Write-ReminderLog ('恭喜窗口预览已关闭，结果：' + $preview.Choice)
        return
    }

    if ((-not $Force) -and (Test-ReminderDayComplete -Data $data -Date $todayKey)) {
        if ($SkipWhenDone) {
            Write-ReminderLog "今天（$todayKey）三款全部完成，静默退出（本次带 -SkipWhenDone）"
            return
        }
        # 三款都清完了也照样弹，只是弹的是道喜
        Write-ReminderLog "今天（$todayKey）三款全部完成，弹出恭喜窗口"
        $congrats = Show-ReminderDialog -Games $games -Completed
        Write-ReminderLog ("恭喜窗口已关闭，结果：" + $congrats.Choice)
        return
    }

    while ($true) {
        $result = Show-ReminderDialog -Games $games
        if ($result.Choice -ne 'snooze') {
            break
        }

        $delay = $SnoozeMinutes * 60
        Write-ReminderLog "点击了稍后提醒：$SnoozeMinutes 分钟，生成独立提醒进程"
        try {
            $null = Start-ReminderHostProcess -Kind reminder -ExtraArgs @('-DelaySeconds', "$delay")
            Write-ReminderLog "独立提醒进程已启动，本进程退出"
            return
        }
        catch {
            Write-ReminderLog "独立提醒进程启动失败，退回本进程等待：$($_.Exception.Message)"
            Start-Sleep -Seconds $delay
        }
    }

    Write-ReminderLog "本次结果：$($result.Choice)"

    if ($result.Choice -eq 'launch') {
        $launchResults = Start-MissingGames -Games $games -CheckedNames $result.Checked
        $watchMode = Show-LaunchResultDialog -Results $launchResults

        # 起个看门进程：游戏退出之后回来提醒 / 直接唤起桌面程序
        $watchNames = @()
        foreach ($game in $games) {
            if ($result.Checked -contains $game.Display) { continue }
            if (-not $game.Found) { continue }
            $watchNames += $game.ProcessName
        }
        if ($watchMode -and $watchMode -ne 'none' -and $watchNames.Count -gt 0) {
            $null = Start-ReminderWatcher -ProcessNames $watchNames -Mode $watchMode
        }
    }
}

if (-not $NoRun) {
    Invoke-DailyReminder
}
