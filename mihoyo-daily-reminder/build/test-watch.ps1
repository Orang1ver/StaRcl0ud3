#requires -version 5.1
<#
.SYNOPSIS
  看门进程自检：真起一个假「游戏」，真等它退出，确认看门进程能在正确的时候触发。

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File .\build\test-watch.ps1
  用一份 cmd.exe 的副本冒充游戏进程（进程名可控、不会弹窗），
  跑完比对 history.json 的指纹，确认自检没碰你的真实打卡数据。
#>
[CmdletBinding()]
param([string]$ProjectRoot)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $ProjectRoot 'lib.ps1')

$script:passed = 0
$script:failed = 0
function Check {
    param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") {
        $script:passed++
        Write-Output ('  [OK]   ' + $Name + ' = ' + $Actual)
    }
    else {
        $script:failed++
        Write-Output ('  [FAIL] ' + $Name + ' = ' + $Actual + '（期望 ' + $Expected + '）')
    }
}
function Check-True {
    param([string]$Name, $Actual)
    if ($Actual) { $script:passed++; Write-Output ('  [OK]   ' + $Name) }
    else { $script:failed++; Write-Output ('  [FAIL] ' + $Name + ' 不成立') }
}

$realHistory = Join-Path $ProjectRoot 'history.json'
$hashBefore = $null
if (Test-Path -LiteralPath $realHistory) {
    $hashBefore = (Get-FileHash -LiteralPath $realHistory -Algorithm SHA256).Hash
}

$watchScript = Join-Path $ProjectRoot 'watch-games.ps1'
$winPs = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$dummyName = 'mihoyo-watch-dummy'
$dummyExe = Join-Path $env:TEMP ($dummyName + '.exe')
$lockFile = Join-Path $env:TEMP 'mihoyo-watch-test.lock'
$resultFile = Join-Path $env:TEMP 'mihoyo-watch-test.json'

foreach ($f in @($lockFile, $resultFile)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}
Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\cmd.exe') -Destination $dummyExe -Force

function Start-DummyGame {
    param([int]$Seconds = 6)
    # 冒充游戏：进程名是 mihoyo-watch-dummy，跑几秒自己退
    return Start-Process -FilePath $dummyExe -ArgumentList @('/c', ('ping -n ' + $Seconds + ' 127.0.0.1 > nul')) -PassThru -WindowStyle Hidden
}

function Start-Watcher {
    param([string[]]$Names, [int]$GraceSeconds = 8, [int]$PollSeconds = 1, [int]$MinSeconds = 2)

    $childArgs = @(
        '-ProcessNames', ($Names -join ','),
        '-Mode', 'none',
        '-MaxHours', '1',
        '-MinSeconds', "$MinSeconds",
        '-PollSeconds', "$PollSeconds",
        '-GraceSeconds', "$GraceSeconds",
        '-LockPath', "`"$lockFile`"",
        '-ResultPath', "`"$resultFile`""
    )

    # 有独立宿主 exe 就走 exe（顺便验证 --watch 这条路），没有才退回 powershell
    $hostExe = Get-ReminderHostPath
    if ($hostExe) {
        return Start-Process -FilePath $hostExe -ArgumentList (@('--watch') + $childArgs) -WindowStyle Hidden -PassThru
    }

    $childArgs = @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$watchScript`""
    ) + $childArgs
    return Start-Process -FilePath $winPs -ArgumentList $childArgs -WindowStyle Hidden -PassThru
}

function Wait-File {
    param([string]$Path, [int]$TimeoutSeconds = 40)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Write-Output '=== 看门进程自检 ==='

Write-Output ''
Write-Output '--- 1. 设置读写 ---'
$tempSettings = Join-Path $env:TEMP 'mihoyo-watch-settings-test.json'
if (Test-Path -LiteralPath $tempSettings) { Remove-Item -LiteralPath $tempSettings -Force }
$settings = Read-ReminderWatchSettings -Paths @($tempSettings)
Check '默认开启' $settings.Enabled 'True'
Check '默认模式是弹窗确认' $settings.Mode 'ask'
$settings.Mode = 'app'
$settings.Enabled = $false
$null = Save-ReminderWatchSettings -Settings $settings -Path $tempSettings
$again = Read-ReminderWatchSettings -Paths @($tempSettings)
Check '模式存得住' $again.Mode 'app'
Check '开关存得住' $again.Enabled 'False'
Remove-Item -LiteralPath $tempSettings -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Output '--- 2. 游戏真退出后触发 ---'
$dummy = Start-DummyGame -Seconds 6
Check-True '假游戏起来了' ([bool](Get-Process -Id $dummy.Id -ErrorAction SilentlyContinue))
$watcher = Start-Watcher -Names @($dummyName)
Check-True '看门进程拿到了结果文件' (Wait-File -Path $resultFile -TimeoutSeconds 40)
$result = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
Check '触发了' $result.fired 'True'
Check '模式正确' $result.mode 'none'
Check '记下了盯的进程' $result.names $dummyName
Check-True '没留下锁文件' (-not (Test-Path -LiteralPath $lockFile))
$watcher.Refresh()
Check-True '看门进程自己退出了' ([bool]$watcher.HasExited)

Write-Output ''
Write-Output '--- 3. 游戏根本没起来：不该触发 ---'
Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
$watcher2 = Start-Watcher -Names @('mihoyo-watch-not-exist') -GraceSeconds 3 -PollSeconds 1
Check-True '没游戏也写出了结果文件' (Wait-File -Path $resultFile -TimeoutSeconds 20)
$result2 = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
Check '没触发' $result2.fired 'False'
Check-True '写了原因' ([string]$result2.reason).Length -gt 0
$watcher2.Refresh()
Check-True '看门进程自己退出了' ([bool]$watcher2.HasExited)

Write-Output ''
Write-Output '--- 4. 已经有一个看门进程时，第二个直接退出 ---'
Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
$dummy2 = Start-DummyGame -Seconds 8
$first = Start-Watcher -Names @($dummyName) -GraceSeconds 8 -PollSeconds 1
Start-Sleep -Seconds 2
$second = Start-Watcher -Names @($dummyName) -GraceSeconds 3 -PollSeconds 1
Start-Sleep -Seconds 4
$second.Refresh()
Check-True '第二个看门进程早早退出了' ([bool]$second.HasExited)
Check-True '第一个还在盯着' (-not $first.HasExited)
$first.Refresh()
if (-not $first.HasExited) { Stop-Process -Id $first.Id -Force -ErrorAction SilentlyContinue }
if ($dummy -and -not $dummy.HasExited) { Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue }
if ($dummy2 -and -not $dummy2.HasExited) { Stop-Process -Id $dummy2.Id -Force -ErrorAction SilentlyContinue }

# 收尾
foreach ($f in @($lockFile, $resultFile, $dummyExe)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
Write-Output '=== 真实数据文件有没有被动过 ==='
$hashAfter = $null
if (Test-Path -LiteralPath $realHistory) {
    $hashAfter = (Get-FileHash -LiteralPath $realHistory -Algorithm SHA256).Hash
}
if ($hashBefore -eq $hashAfter) { $script:passed++; Write-Output '  [OK]   history.json 指纹没变' }
else { $script:failed++; Write-Output '  [FAIL] history.json 被改动了！' }

Write-Output ''
Write-Output ('=== 结果：通过 ' + $script:passed + ' 项，失败 ' + $script:failed + ' 项 ===')
if ($script:failed -gt 0) { exit 1 }
