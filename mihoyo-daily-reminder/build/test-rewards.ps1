#requires -version 5.1
<#
.SYNOPSIS
  奖励引擎自检：用构造出来的打卡记录验证 XP / 代币 / 连击 / 冻结 / 里程碑 / 等级 / 兑换。

.DESCRIPTION
  改了 rewards.json 之后跑一遍，确认规则没把经济搞崩：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build\test-rewards.ps1
  这里全部用假数据，不会碰你的 history.json。
#>
[CmdletBinding()]
param([string]$ProjectRoot)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $ProjectRoot 'lib.ps1')

$rules = Read-RewardRules -Paths (Join-Path $ProjectRoot 'rewards.json')
$todayKey = '2026-09-10'          # 周四，方便构造「同一周内漏两天」
$today = [datetime]::ParseExact($todayKey, 'yyyy-MM-dd', $null)

# 安全阀：这个脚本只许玩假的。真实记录文件在开工前记下指纹，收工时再比一次。
$realHistory = Join-Path $ProjectRoot 'history.json'
$realHashBefore = $null
if (Test-Path -LiteralPath $realHistory) {
    $realHashBefore = (Get-FileHash -LiteralPath $realHistory -Algorithm SHA256).Hash
}
$tempHistory = Join-Path $env:TEMP 'mihoyo-reward-test.json'

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

function Check-Range {
    param([string]$Name, $Actual, [double]$Min, [double]$Max)
    $value = [double]$Actual
    $ok = ($value -ge $Min -and $value -le $Max)
    if ($ok) {
        $script:passed++
        Write-Output ('  [OK]   ' + $Name + ' = ' + $Actual)
    }
    else {
        $script:failed++
        Write-Output ('  [FAIL] ' + $Name + ' = ' + $Actual + '（期望 ' + $Min + ' ~ ' + $Max + '）')
    }
}

function New-FakeData {
    param([int[]]$DoneOffsets, [int[]]$PartialOffsets = @())
    $days = @{}
    foreach ($o in $DoneOffsets) { $days[$today.AddDays($o).ToString('yyyy-MM-dd')] = @('原神', '崩坏：星穹铁道', '绝区零') }
    foreach ($o in $PartialOffsets) { $days[$today.AddDays($o).ToString('yyyy-MM-dd')] = @('原神') }
    # Path 必须指向临时文件：万一哪段代码顺手保存，也只会写到临时文件里
    return [pscustomobject]@{ Version = 3; Days = $days; Redemptions = @(); Path = $tempHistory }
}

function New-State {
    param([int[]]$Done, [int[]]$Partial = @(), $Redemptions = $null)
    $data = New-FakeData -DoneOffsets $Done -PartialOffsets $Partial
    if ($Redemptions) { $data.Redemptions = $Redemptions }
    return Get-RewardState -Rules $rules -Data $data -Today $today
}

Write-Output '=== 1. 单日全清（基础值） ==='
$day = Get-RewardDayResult -Rules $rules -Items @('原神', '崩坏：星穹铁道', '绝区零')
Check '全清一天的基础代币' $day.Coin 45
Check '全清一天的基础 XP' $day.Xp 135
Check '全清标记' $day.AllClear $true
$partial = Get-RewardDayResult -Rules $rules -Items @('原神')
Check '只清一款：不发全清奖励' $partial.Coin 10
Check '只清一款：XP' $partial.Xp 30

$s1 = New-State -Done @(0)
Check '单日：连击' $s1.Streak 1
Check '单日：余额' $s1.Balance 45
Check '单日：等级（Habitica 曲线前 4 级很便宜）' $s1.Level 3
Check '单日：今日代币' ([Math]::Round($s1.TodayCoin)) 45

Write-Output ''
Write-Output '=== 2. 连续 7 天：里程碑 ==='
$s7 = New-State -Done @(0, -1, -2, -3, -4, -5, -6)
Check '连击' $s7.Streak 7
Check '最长连击' $s7.BestStreak 7
Check '7 天里程碑解锁' $s7.Milestones[0].Unlocked $true
Check '30 天里程碑仍锁着' $s7.Milestones[1].Unlocked $false
Check '还差几天到 30 天' $s7.Milestones[1].Remain 23
Check '里程碑奖励已计入余额（> 7 天基础值）' ($s7.Balance -gt 315) $true

Write-Output ''
Write-Output '=== 3. 倍率封顶（不要指数） ==='
$m1 = Get-RewardMultiplier -Rules $rules -Streak 0
$m50 = Get-RewardMultiplier -Rules $rules -Streak 50
$m100 = Get-RewardMultiplier -Rules $rules -Streak 100
$m300 = Get-RewardMultiplier -Rules $rules -Streak 300
Check '0 天倍率' $m1 1
Check '50 天倍率' $m50 1.5
Check '100 天倍率' $m100 2
Check '300 天仍然封顶在 2 倍' $m300 2

Write-Output ''
Write-Output '=== 4. 冻结日：同一周漏一天不算断 ==='
$sFreeze = New-State -Done @(0, -1, -3, -4)
Check '冻结桥接后连击' $sFreeze.Streak 4
Check '本周用掉冻结次数' $sFreeze.FreezeUsed 1
Check '冻结额度' $sFreeze.FreezePerWeek 1

Write-Output ''
Write-Output '=== 5. 同一周漏两天：第二次就清零 ==='
$sBreak = New-State -Done @(0, -1, -4, -5)
Check '清零后重新数' $sBreak.Streak 2
Check '本周冻结已用完' $sBreak.FreezeUsed 1

Write-Output ''
Write-Output '=== 6. 隔周漏（额度按周重置） ==='
$sTwoWeeks = New-State -Done @(0, -1, -8, -9, -10, -11)
Check '上周的冻结不占本周额度（连击被清零重算）' ($sTwoWeeks.Streak -ge 2) $true

Write-Output ''
Write-Output '=== 7. 等级曲线 ==='
Check 'L1 升 L2 需要' (Get-RewardLevelNeed -Rules $rules -Level 1) 25
Check 'L5 升 L6 需要' (Get-RewardLevelNeed -Rules $rules -Level 5) 150
Check 'L10 升 L11 需要' (Get-RewardLevelNeed -Rules $rules -Level 10) 260
$lv = Get-RewardLevelFromXp -Rules $rules -Xp 1000
Check '1000 XP 大概到几级' $lv.Level 8

Write-Output ''
Write-Output '=== 8. 商店兑换 ==='
$sShop = New-State -Done @(0, -1, -2, -3, -4, -5, -6, -7, -8, -9)
$before = $sShop.Balance
$cheap = (Get-RewardShop -Rules $rules | Sort-Object Price)[0]
$data2 = New-FakeData -Done @(0, -1, -2, -3, -4, -5, -6, -7, -8, -9)
$item = Add-RewardRedemption -Data $data2 -Rules $rules -Id $cheap.Id
Check '兑换的是最便宜那件' $item.Id $cheap.Id
$after = (Get-RewardState -Rules $rules -Data $data2 -Today $today).Balance
Check '兑换后代币减少' ($before - $after) $cheap.Price
Check '兑换记录条数' (@($data2.Redemptions).Count) 1
$undo = Remove-LastRewardRedemption -Data $data2
Check '撤销兑换' $undo.Id $cheap.Id
Check '撤销后记录清空' (@($data2.Redemptions).Count) 0

Write-Output ''
Write-Output '=== 9. 代币不够时不能兑换 ==='
$data3 = New-FakeData -Done @(0)
$blocked = $false
try { $null = Add-RewardRedemption -Data $data3 -Rules $rules -Id 'movie' } catch { $blocked = $true }
Check '余额不足会拦下来' $blocked $true

Write-Output ''
Write-Output '=== 10. 空数据不炸 ==='
$empty = Get-RewardState -Rules $rules -Data (New-FakeData -Done @()) -Today $today
Check '空数据等级' $empty.Level 1
Check '空数据余额' $empty.Balance 0
Check '空数据连击' $empty.Streak 0
Check '空数据累计天数' $empty.TotalDays 0

Write-Output ''
Write-Output '=== 11. 补录：昨天完成但忘了记 ==='
$bfData = [pscustomobject]@{ Version = 3; Days = @{}; Redemptions = @(); Path = $tempHistory }
$null = Set-ReminderDayGames -Data $bfData -Date $todayKey -Games @('原神', '崩坏：星穹铁道', '绝区零')
$beforeBackfill = Get-RewardState -Rules $rules -Data $bfData -Today $today
Check '补录前连击（只有今天）' $beforeBackfill.Streak 1
Check '补录前余额' $beforeBackfill.Balance 45

$null = Set-ReminderDayGames -Data $bfData -Date $today.AddDays(-1).ToString('yyyy-MM-dd') -Games @('原神', '崩坏：星穹铁道', '绝区零')
$afterBackfill = Get-RewardState -Rules $rules -Data $bfData -Today $today
Check '补录昨天后连击接上' $afterBackfill.Streak 2
# 昨天补录后成了 2 连，当天收入按「当天的连击倍率」算；总余额是先累加再取整
$backfillDayCoin = 45 * (Get-RewardMultiplier -Rules $rules -Streak 2)
Check '补录后余额（今天 45 + 昨天按当天倍率补发）' $afterBackfill.Balance ([int][Math]::Round(45 + $backfillDayCoin))
Check '补录后累计天数' $afterBackfill.TotalDays 2
Check '补录写进了临时记录文件' (Test-Path -LiteralPath $tempHistory) $true

Write-Output ''
Write-Output '=== 12. 补录的去重 / 删除 / 改错 ==='
$dedupe = [pscustomobject]@{ Version = 3; Days = @{}; Redemptions = @(); Path = $tempHistory }
$null = Set-ReminderDayGames -Data $dedupe -Date '2026-09-01' -Games @('原神', '原神', '崩坏：星穹铁道')
Check '同一天重复记录会去重' (@($dedupe.Days['2026-09-01']).Count) 2

$null = Set-ReminderDayGames -Data $dedupe -Date '2026-09-01' -Games @()
Check '全部取消勾选后这一天从记录里删掉' ($dedupe.Days.ContainsKey('2026-09-01')) $false

$fix = [pscustomobject]@{ Version = 3; Days = @{}; Redemptions = @(); Path = $tempHistory }
$null = Set-ReminderDayGames -Data $fix -Date '2026-09-01' -Games @('原神', '崩坏：星穹铁道', '绝区零')
$null = Set-ReminderDayGames -Data $fix -Date '2026-09-01' -Games @('原神')
$fixed = Get-RewardState -Rules $rules -Data $fix -Today $today
Check '记错改成部分完成：不再算全清' $fixed.TotalDays 0
Check '部分完成也按当天倍率发了币' $fixed.Balance 10

Write-Output ''
Write-Output '=== 13. 真实记录文件有没有被动过 ==='
$realHashAfter = $null
if (Test-Path -LiteralPath $realHistory) {
    $realHashAfter = (Get-FileHash -LiteralPath $realHistory -Algorithm SHA256).Hash
}
if ($realHashBefore -eq $realHashAfter) {
    $script:passed++
    Write-Output ('  [OK]   history.json 指纹没变（' + $(if ($realHashAfter) { $realHashAfter.Substring(0, 12) + '…' } else { '文件不存在' }) + '）')
}
else {
    $script:failed++
    Write-Output ('  [FAIL] history.json 被改动了！前 ' + $realHashBefore + ' -> 后 ' + $realHashAfter)
}
if (Test-Path -LiteralPath $tempHistory) { Remove-Item -LiteralPath $tempHistory -Force -ErrorAction SilentlyContinue }

Write-Output ''
Write-Output ('=== 结果：通过 ' + $script:passed + ' 项，失败 ' + $script:failed + ' 项 ===')
if ($script:failed -gt 0) { exit 1 }
