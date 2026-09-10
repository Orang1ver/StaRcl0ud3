#requires -version 5.1
<#
.SYNOPSIS
  注册 / 查看 / 删除“米哈游每日提醒”Windows 计划任务。

.DESCRIPTION
  计划任务本身只跑 daily-reminder.ps1：每天到点先看打卡数据，
  三款都清完的日子静默退出，没清完才弹出提醒窗口。
  提醒时间也可以在桌面程序（desktop-app.cmd）的设置页里改、暂停或重新启用。

.PARAMETER Time
  每日提醒时间，默认 23:30。
.PARAMETER Remove
  删除已注册的计划任务。
.PARAMETER Status
  查看当前计划任务状态。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Time 22:00
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$Time = '23:30',
    [switch]$Remove,
    [switch]$Status
)

. (Join-Path $PSScriptRoot 'lib.ps1')

$taskName = Get-ReminderTaskName

function Show-Status {
    $task = Get-ReminderTask -TaskName $taskName
    if (-not $task) {
        Write-Output '计划任务尚未注册。'
        return
    }

    Write-Output ("任务名：{0}" -f $task.TaskName)
    Write-Output ("状态：{0}" -f $task.State)
    Write-Output ("提醒时间：每天 {0}" -f (Get-ReminderTaskClock -Task $task))

    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    if ($info) {
        Write-Output ("上次运行：{0}" -f $info.LastRunTime)
        Write-Output ("下次运行：{0}" -f $info.NextRunTime)
    }
}

if ($Status) {
    Show-Status
    return
}

if ($Remove) {
    $existing = Get-ReminderTask -TaskName $taskName
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Output "已删除计划任务：$taskName"
    }
    else {
        Write-Output '计划任务不存在，无需删除。'
    }
    return
}

$null = Register-ReminderTask -Time $Time -TaskName $taskName
Write-Output "已注册计划任务：$taskName（每天 $Time 提醒，三款都清完的日子自动跳过）"
Show-Status
