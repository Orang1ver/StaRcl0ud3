#requires -version 5.1
<#
.SYNOPSIS
  看门进程：盯着刚启动的游戏，全部退出之后再回来提醒你。

.DESCRIPTION
  弹窗里点了「启动游戏」之后，daily-reminder.ps1 会把这个脚本起成独立进程。
  它只做三件事：
    1. 先等游戏真的起来（默认最多等 3 分钟，防止点了启动又取消）；
    2. 等这几个游戏进程全部退出（每 15 秒看一次，要连续两次看不到才算退干净，
       免得游戏自己重启的那一瞬间误判；同时会跳过一次都没跑满 90 秒的情况）；
    3. 按 mode 做事：
         ask  -> 重新弹一次提醒弹窗（三款都清了的话它会自己静默退出，不重复道喜）
         app  -> 直接把桌面程序唤到前台
         none -> 只写日志，什么都不做（测试用）

  设置存在同目录的 watch.json，也可以在弹窗的「启动结果」里直接改。

.PARAMETER ProcessNames
  要盯的进程名，逗号分隔（例如 YuanShen,StarRail）。大小写不敏感。
.PARAMETER Mode
  ask / app / none，见上。
.PARAMETER MaxHours
  最多盯多少小时，超时就不管了。默认 6。
.PARAMETER MinSeconds
  这次游戏至少跑了多少秒才算数（防止启动失败时误触发）。默认 90。
.PARAMETER PollSeconds
  轮询间隔秒数，默认 15。
.PARAMETER GraceSeconds
  等游戏起来的最长秒数，默认 180。
.PARAMETER LockPath
  锁文件路径（同一时间只允许一个看门进程）。默认 %TEMP%\mihoyo-daily-watch.lock。
.PARAMETER ResultPath
  结果 JSON 路径，方便排查和自动化测试。默认 %TEMP%\mihoyo-daily-watch.json。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\watch-games.ps1 -ProcessNames YuanShen,StarRail -Mode ask
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\watch-games.ps1 -ProcessNames notepad -Mode none -PollSeconds 1
#>
[CmdletBinding()]
param(
    [string[]]$ProcessNames = @(),
    [ValidateSet('ask', 'app', 'none')][string]$Mode = 'ask',
    [int]$MaxHours = 6,
    [int]$MinSeconds = 90,
    [int]$PollSeconds = 15,
    [int]$GraceSeconds = 180,
    [string]$LockPath = '',
    [string]$ResultPath = ''
)

. (Join-Path $PSScriptRoot 'lib.ps1')

$ErrorActionPreference = 'Continue'

# -ProcessNames 可能是数组，也可能是一整串逗号分隔的
$names = @()
foreach ($entry in @($ProcessNames)) {
    foreach ($part in ([string]$entry -split ',')) {
        $trimmed = $part.Trim()
        if ($trimmed) { $names += $trimmed }
    }
}

if ($names.Count -eq 0) {
    Write-ReminderLog '看门进程：没有指定要盯的游戏进程，退出'
    return
}

if ($PollSeconds -lt 1) { $PollSeconds = 1 }
if ($GraceSeconds -lt $PollSeconds) { $GraceSeconds = $PollSeconds }
if ($MinSeconds -lt 0) { $MinSeconds = 0 }
if ($MaxHours -lt 1) { $MaxHours = 1 }

if (-not $LockPath) { $LockPath = Join-Path $env:TEMP 'mihoyo-daily-watch.lock' }
if (-not $ResultPath) { $ResultPath = Join-Path $env:TEMP 'mihoyo-daily-watch.json' }

function Get-WatchedProcess {
    <# 正在跑的被盯进程（跳过自己） #>
    $found = @()
    foreach ($proc in @(Get-Process -Name $names -ErrorAction SilentlyContinue)) {
        if ($proc.Id -eq $PID) { continue }
        $found += $proc
    }
    return $found
}

# ---- 锁：同一时间只留一个看门进程 ----
if (Test-Path -LiteralPath $LockPath) {
    $holderAlive = $false
    $holderId = 0
    try {
        $lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $holderId = [int]$lock.pid
        if ($holderId -gt 0) {
            $holderAlive = [bool](Get-Process -Id $holderId -ErrorAction SilentlyContinue)
        }
    }
    catch { }

    if ($holderAlive) {
        Write-ReminderLog ('看门进程：已经有一个在盯着（PID ' + $holderId + '），这个就不重复了')
        return
    }
}

$startedAt = Get-Date
$fired = $false
$reason = ''

try {
    try {
        $lockObject = [pscustomobject]@{
            pid   = $PID
            at    = $startedAt.ToString('s')
            names = ($names -join ',')
            mode  = $Mode
        }
        [System.IO.File]::WriteAllText($LockPath, ($lockObject | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-ReminderLog ('写看门锁失败：' + $_.Exception.Message) }

    Write-ReminderLog ('看门进程启动：盯 ' + ($names -join '、') + '，模式 ' + $Mode)

    # ---- 1. 等游戏真的起来 ----
    $seen = $false
    $graceUntil = $startedAt.AddSeconds($GraceSeconds)
    while ((Get-Date) -lt $graceUntil) {
        $running = Get-WatchedProcess
        if ($running.Count -gt 0) { $seen = $true; break }
        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $seen) {
        $reason = ('等了 ' + $GraceSeconds + ' 秒也没看到游戏起来，撤了')
        Write-ReminderLog ('看门进程：' + $reason)
    }
    else {
        $seenNames = @(Get-WatchedProcess | Select-Object -ExpandProperty ProcessName -Unique)
        Write-ReminderLog ('看门进程：' + ($seenNames -join '、') + ' 在跑，开始等它退出')

        # ---- 2. 等全部退出 ----
        $maxUntil = $startedAt.AddHours($MaxHours)
        $goneStreak = 0
        while ($true) {
            $running = Get-WatchedProcess
            if ($running.Count -eq 0) { $goneStreak++ } else { $goneStreak = 0 }

            $elapsed = ((Get-Date) - $startedAt).TotalSeconds
            if ($goneStreak -ge 2 -and $elapsed -ge $MinSeconds) { $fired = $true; break }
            if ((Get-Date) -ge $maxUntil) {
                $reason = ('盯了 ' + $MaxHours + ' 小时还没退，不管了')
                break
            }
            Start-Sleep -Seconds $PollSeconds
        }
    }
}
finally {
    # 先放锁：等下唤起的新弹窗可能又要起一个新的看门进程
    try { if (Test-Path -LiteralPath $LockPath) { Remove-Item -LiteralPath $LockPath -Force } } catch { }
}

$sessionMinutes = [int][Math]::Round(((Get-Date) - $startedAt).TotalMinutes)

if ($fired) {
    Write-ReminderLog ('看门进程：游戏退出（这次约 ' + $sessionMinutes + ' 分钟），执行 ' + $Mode)
    try {
        if ($Mode -eq 'ask') {
            $reminder = Join-Path $PSScriptRoot 'daily-reminder.ps1'
            if (Test-Path -LiteralPath $reminder) {
                # -SkipWhenDone：刚玩完的那次不再道喜，道喜留给 23:30 那一趟
                $null = Start-ReminderHostProcess -Kind reminder -ExtraArgs @('-SkipWhenDone')
            }
            else {
                Write-ReminderLog '找不到 daily-reminder.ps1，没法重新弹提醒'
            }
        }
        elseif ($Mode -eq 'app') {
            $appPath = Get-ReminderAppPath
            if ($appPath) {
                Start-Process -FilePath $appPath
                Write-ReminderLog ('已唤起桌面程序：' + $appPath)
            }
            else {
                Write-ReminderLog '找不到桌面程序入口，跳过'
            }
        }
    }
    catch {
        Write-ReminderLog ('看门进程执行失败：' + $_.Exception.Message)
    }
}
elseif (-not $reason) {
    $reason = '没有触发'
}

# 结果文件：排查和自动化测试都看它
try {
    $resultObject = [pscustomobject]@{
        fired          = $fired
        mode           = $Mode
        names          = ($names -join ',')
        sessionMinutes = $sessionMinutes
        reason         = $reason
        at             = (Get-Date).ToString('s')
    }
    [System.IO.File]::WriteAllText($ResultPath, ($resultObject | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
catch { Write-ReminderLog ('写看门结果失败：' + $_.Exception.Message) }
