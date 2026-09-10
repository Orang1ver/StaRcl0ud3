# Game Time Stats UI
param([switch]$Test)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:csvPath = Join-Path $script:dir 'activity.csv'

$script:displayNames = @{
    'yuanshen'         = '原神'
    'genshinimpact'    = '原神'
    'starrail'         = '崩坏：星穹铁道'
    'zenlesszonezero'  = '绝区零'
}

function Get-DisplayName {
    param([string]$processName)
    $key = $processName.ToLowerInvariant()
    if ($script:displayNames.ContainsKey($key)) {
        return $script:displayNames[$key]
    }
    return $processName
}

function Read-Stats {
    $empty = [pscustomobject]@{
        Today = 0.0
        Week  = 0.0
        All   = 0.0
        Rows  = @()
    }

    if (-not (Test-Path -LiteralPath $script:csvPath)) { return $empty }

    $records = @(Import-Csv -LiteralPath $script:csvPath -Encoding UTF8)
    if ($records.Count -eq 0) { return $empty }

    $today = (Get-Date).Date
    $weekStart = $today.AddDays(-6)
    $map = @{}
    $todayMinutes = 0.0
    $weekMinutes = 0.0
    $allMinutes = 0.0

    foreach ($rec in $records) {
        try {
            $start = [datetime]::Parse($rec.Start)
            $end = [datetime]::Parse($rec.End)
        } catch {
            continue
        }

        $minutes = ($end - $start).TotalMinutes
        if ($minutes -le 0) { continue }

        $date = $start.Date
        $allMinutes += $minutes
        if ($date -eq $today) { $todayMinutes += $minutes }
        if ($date -ge $weekStart) { $weekMinutes += $minutes }

        $key = $date.ToString('yyyy-MM-dd') + '|' + $rec.Process.ToLowerInvariant()
        if (-not $map.ContainsKey($key)) {
            $map[$key] = [pscustomobject]@{
                Date     = $date
                DateText = $date.ToString('yyyy-MM-dd')
                Process  = $rec.Process
                Display  = (Get-DisplayName $rec.Process)
                Minutes  = 0.0
            }
        }
        $map[$key].Minutes += $minutes
    }

    $rows = @($map.Values | Sort-Object -Property Date, Minutes -Descending)
    return [pscustomobject]@{
        Today = $todayMinutes
        Week  = $weekMinutes
        All   = $allMinutes
        Rows  = $rows
    }
}

function Update-Stats {
    $stats = Read-Stats

    $script:valueToday.Text = '{0:N1} 分钟' -f $stats.Today
    $script:valueWeek.Text = '{0:N1} 分钟' -f $stats.Week
    $script:valueAll.Text = '{0:N1} 分钟' -f $stats.All

    $script:grid.SuspendLayout()
    $script:grid.Rows.Clear()

    if ($stats.Rows.Count -eq 0) {
        $script:grid.Rows.Add('暂无记录', '', '', '')
    } else {
        foreach ($row in $stats.Rows) {
            $script:grid.Rows.Add($row.DateText, $row.Display, ('{0:N1} 分钟' -f $row.Minutes), $row.Process)
        }
    }

    $script:grid.ResumeLayout()
    $script:statusLabel.Text = '数据更新于 ' + (Get-Date -Format 'HH:mm:ss') + ' · 共 ' + $stats.Rows.Count + ' 条汇总 · 每 5 秒自动刷新'
}

if ($Test) {
    Write-Host 'stats-ui loaded OK'
    exit 0
}

function New-SummaryBox {
    param([string]$titleText)

    $box = New-Object System.Windows.Forms.GroupBox
    $box.Text = $titleText
    $box.Width = 232
    $box.Height = 82

    $value = New-Object System.Windows.Forms.Label
    $value.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
    $value.AutoSize = $true
    $value.Location = New-Object System.Drawing.Point(12, 30)
    $value.Text = '0.0 分钟'
    $box.Controls.Add($value)

    return @{ Box = $box; Value = $value }
}

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = '游戏时长统计'
$script:form.Size = New-Object System.Drawing.Size(820, 620)
$script:form.StartPosition = 'CenterScreen'
$script:form.MinimumSize = New-Object System.Drawing.Size(640, 460)
$script:form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$script:form.ShowIcon = $false

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = 'Top'
$topPanel.Height = 104

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Fill'
$flow.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 6)

$todayInfo = New-SummaryBox '今日时长'
$weekInfo = New-SummaryBox '近 7 天'
$allInfo = New-SummaryBox '累计时长'

$flow.Controls.Add($todayInfo.Box)
$flow.Controls.Add($weekInfo.Box)
$flow.Controls.Add($allInfo.Box)
$topPanel.Controls.Add($flow)

$script:valueToday = $todayInfo.Value
$script:valueWeek = $weekInfo.Value
$script:valueAll = $allInfo.Value

$bottomPanel = New-Object System.Windows.Forms.Panel
$bottomPanel.Dock = 'Bottom'
$bottomPanel.Height = 38

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '立即刷新'
$refreshButton.Width = 90
$refreshButton.Height = 28
$refreshButton.Anchor = 'Top, Right'
$refreshButton.Location = New-Object System.Drawing.Point(710, 5)
$refreshButton.Add_Click({ Update-Stats })

$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Text = '准备读取数据...'
$script:statusLabel.AutoSize = $true
$script:statusLabel.Location = New-Object System.Drawing.Point(12, 10)

$bottomPanel.Controls.Add($refreshButton)
$bottomPanel.Controls.Add($script:statusLabel)

$script:grid = New-Object System.Windows.Forms.DataGridView
$script:grid.Dock = 'Fill'
$script:grid.ReadOnly = $true
$script:grid.AllowUserToAddRows = $false
$script:grid.AllowUserToDeleteRows = $false
$script:grid.RowHeadersVisible = $false
$script:grid.SelectionMode = 'FullRowSelect'
$script:grid.BackgroundColor = 'White'
$script:grid.AutoSizeRowsMode = 'AllCells'

$colDate = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colDate.HeaderText = '日期'
$colDate.FillWeight = 25
$colDate.AutoSizeMode = 'Fill'

$colGame = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colGame.HeaderText = '游戏'
$colGame.FillWeight = 30
$colGame.AutoSizeMode = 'Fill'

$colTime = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTime.HeaderText = '时长'
$colTime.FillWeight = 18
$colTime.AutoSizeMode = 'Fill'

$colProc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colProc.HeaderText = '进程名'
$colProc.FillWeight = 27
$colProc.AutoSizeMode = 'Fill'

$script:grid.Columns.Add($colDate)
$script:grid.Columns.Add($colGame)
$script:grid.Columns.Add($colTime)
$script:grid.Columns.Add($colProc)

$script:form.Controls.Add($topPanel)
$script:form.Controls.Add($bottomPanel)
$script:form.Controls.Add($script:grid)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Stats })
$timer.Start()

Update-Stats
[void][System.Windows.Forms.Application]::Run($script:form)
