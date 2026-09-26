#requires -version 5.1
<#
.SYNOPSIS
  尘歌壶自检：验证洞天宝钱的累积 / 封顶 / 存满时间 / 剩余文案 / 记录读写。

.DESCRIPTION
  改了尘歌壶相关的代码之后跑一遍：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build\test-serenitea.ps1
  这里全部用假数据和临时文件，不会碰真实的 serenitea.json，
  也不会注册 / 删除任何计划任务。
#>
[CmdletBinding()]
param([string]$ProjectRoot)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $ProjectRoot 'lib.ps1')

# 安全阀：开工前记下真实记录的指纹，收工时再比一次
$realFile = Join-Path $ProjectRoot 'serenitea.json'
$realHashBefore = $null
if (Test-Path -LiteralPath $realFile) {
    $realHashBefore = (Get-FileHash -LiteralPath $realFile -Algorithm SHA256).Hash
}
$tempFile = Join-Path $env:TEMP 'mihoyo-serenitea-test.json'
if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }

$script:passed = 0
$script:failed = 0

function Check {
    param([string]$Name, $Actual, $Expected)
    $ok = ("$Actual" -eq "$Expected")
    if ($ok) {
        $script:passed++
        Write-Output ('  [OK]   ' + $Name + ' = ' + $Actual)
    }
    else {
        $script:failed++
        Write-Output ('  [FAIL] ' + $Name + ' = ' + $Actual + '（期望 ' + $Expected + '）')
    }
}

# 用户举的例子：2026-09-26 18:37 取完宝钱
$base = [datetime]::ParseExact('2026-09-26T18:37:00', 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

function New-Record {
    param([datetime]$Last = $base, $Path = $tempFile)
    return [pscustomobject]@{ LastCollected = $Last; Path = $Path }
}

function Get-StateAt {
    param([double]$Hours)
    return (Get-SereniteaState -Record (New-Record) -Now $base.AddHours($Hours))
}

Write-Output '=== 1. 宝钱累积（30 枚/小时） ==='
Check '刚取完 0 枚' (Get-StateAt -Hours 0).Coins 0
Check '2 分钟 1 枚' (Get-StateAt -Hours (2.0 / 60)).Coins 1
Check '半小时 15 枚' (Get-StateAt -Hours 0.5).Coins 15
Check '2 小时 60 枚' (Get-StateAt -Hours 2).Coins 60
Check '24 小时 720 枚' (Get-StateAt -Hours 24).Coins 720
Check '79 小时 2370 枚' (Get-StateAt -Hours 79).Coins 2370

Write-Output ''
Write-Output '=== 2. 存满封顶（2400 = 80 小时） ==='
Check '79 小时 59 分还没满（2399）' (Get-StateAt -Hours (79 + 59.0 / 60)).Coins 2399
$full = Get-StateAt -Hours 80
Check '80 小时整存满 2400' $full.Coins 2400
Check '存满标记' $full.IsFull $true
Check '还差 0 枚' $full.Remaining 0
Check '80 小时后进度条 100%' ([Math]::Round($full.Progress, 4)) 1
Check '200 小时仍然 2400（封顶）' (Get-StateAt -Hours 200).Coins 2400
Check '200 小时进度条不超 1' (Get-StateAt -Hours 200).Progress 1

Write-Output ''
Write-Output '=== 3. 存满时刻 = 取完 + 80 小时 ==='
$mid = Get-StateAt -Hours 10
Check 'FullAt（18:37 取完 -> 09-30 02:37 满）' ($mid.FullAt.ToString('yyyy-MM-dd HH:mm')) '2026-09-30 02:37'
Check '10 小时后离满还有 70 小时' ($mid.TimeToFull.TotalHours) 70
Check '离满剩余文案' (Get-SereniteaDurationText -Span $mid.TimeToFull) '2 天 22 小时'
$almost = Get-SereniteaState -Record (New-Record) -Now $base.AddHours(80).AddMinutes(-30)
Check '满前 30 分钟的剩余文案' (Get-SereniteaDurationText -Span $almost.TimeToFull) '30 分钟'

Write-Output ''
Write-Output '=== 4. 异常输入不炸 ==='
$backwards = Get-SereniteaState -Record (New-Record -Last $base.AddHours(5)) -Now $base
Check '时钟倒挂：0 枚' $backwards.Coins 0
Check '时钟倒挂：不算满' $backwards.IsFull $false
$none = Get-SereniteaState -Record ([pscustomobject]@{ LastCollected = $null; Path = $tempFile })
Check '没有记录：HasRecord 否' $none.HasRecord $false
Check '没有记录：FullAt 为空' $none.FullAt $null
$noProp = Get-SereniteaState -Record ([pscustomobject]@{})
Check '记录缺字段：HasRecord 否' $noProp.HasRecord $false
Check '上限常量' (Get-SereniteaCap) 2400
Check '80 小时常量' (Get-SereniteaHoursToFull) 80

Write-Output ''
Write-Output '=== 5. 剩余时间文案 ==='
Check '45 分钟' (Get-SereniteaDurationText -Span (New-TimeSpan -Minutes 45)) '45 分钟'
Check '90 分钟' (Get-SereniteaDurationText -Span (New-TimeSpan -Minutes 90)) '1 小时 30 分钟'
Check '26 小时 30 分' (Get-SereniteaDurationText -Span (New-TimeSpan -Minutes (26 * 60 + 30))) '1 天 2 小时'
Check '80 小时（整段存满）' (Get-SereniteaDurationText -Span (New-TimeSpan -Hours 80)) '3 天 8 小时'
Check '0 分钟' (Get-SereniteaDurationText -Span (New-TimeSpan -Seconds 30)) '0 分钟'

Write-Output ''
Write-Output '=== 6. 记录读写（写进临时文件） ==='
$rec = New-Record
Check '保存返回路径' (Save-SereniteaData -Data $rec) $tempFile
$read = Read-SereniteaData -Paths @($tempFile)
Check '读回 LastCollected' ($read.LastCollected.ToString('s')) ($base.ToString('s'))
Check '读回 Path' $read.Path $tempFile

$noPath = [pscustomobject]@{ LastCollected = $base }
Check '没有 Path 的数据拒绝落盘' (Save-SereniteaData -Data $noPath) $null
Check '确实没写出来' (Test-Path -LiteralPath $tempFile) $true

$missing = Read-SereniteaData -Paths @(Join-Path $env:TEMP 'mihoyo-serenitea-not-exist.json')
Check '文件不存在：HasRecord 相当于没记录' ($null -eq $missing.LastCollected) $true
Check '文件不存在：Path 指向该写的位置' ($missing.Path -like '*mihoyo-serenitea-not-exist.json') $true

Write-Output ''
Write-Output '=== 7. 记一笔取宝钱（不排计划任务） ==='
$collected = Set-SereniteaCollected -At $base.AddHours(1) -Paths @($tempFile) -NoReminder
Check '刚取完 = 0 枚' $collected.Coins 0
Check '新一轮的存满时刻' ($collected.FullAt.ToString('yyyy-MM-dd HH:mm')) '2026-09-30 03:37'
$reread = Read-SereniteaData -Paths @($tempFile)
Check '写入的就是取完那一刻' ($reread.LastCollected.ToString('s')) ($base.AddHours(1).ToString('s'))
Check '任务名常量' (Get-SereniteaTaskName) 'MiHoYo Serenitea Reminder'

Write-Output ''
Write-Output '=== 8. 真实记录文件有没有被动过 ==='
$realHashAfter = $null
if (Test-Path -LiteralPath $realFile) {
    $realHashAfter = (Get-FileHash -LiteralPath $realFile -Algorithm SHA256).Hash
}
if ($realHashBefore -eq $realHashAfter) {
    $script:passed++
    Write-Output ('  [OK]   serenitea.json 指纹没变（' + $(if ($realHashAfter) { $realHashAfter.Substring(0, 12) + '…' } else { '文件不存在' }) + '）')
}
else {
    $script:failed++
    Write-Output ('  [FAIL] serenitea.json 被改动了！前 ' + $realHashBefore + ' -> 后 ' + $realHashAfter)
}
if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }

Write-Output ''
Write-Output ('=== 结果：通过 ' + $script:passed + ' 项，失败 ' + $script:failed + ' 项 ===')
if ($script:failed -gt 0) { exit 1 }
