#requires -version 5.1
<#
.SYNOPSIS
  把启动器编译成「米哈游每日助手.exe」（带图标、无控制台窗口）。

.DESCRIPTION
  用的是 Windows 自带的 C# 编译器（csc.exe），不需要联网、不用装任何东西。
  图标取自 assets\app.ico，没有就先用 build\make-icon.ps1 生成。
  除了 WinForms，还要引用 Windows 自带的 PowerShell 引擎（System.Management.Automation.dll，
  在 GAC 里），因为 exe 是「把 PowerShell 引擎装进自己进程里跑脚本」的独立宿主。

.PARAMETER OutFile
  输出的 exe 路径，默认在项目根目录：米哈游每日助手.exe
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $PSScriptRoot 'Launcher.cs'
$iconPath = Join-Path $projectRoot 'assets\app.ico'
$tempExe = Join-Path $projectRoot 'mihoyo-daily-helper.build.exe'
if (-not $OutFile) { $OutFile = Join-Path $projectRoot '米哈游每日助手.exe' }

if (-not (Test-Path -LiteralPath $iconPath)) {
    Write-Output '没有找到图标，先生成一份……'
    & (Join-Path $PSScriptRoot 'make-icon.ps1')
}

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $null
foreach ($candidate in $cscCandidates) {
    if (Test-Path -LiteralPath $candidate) { $csc = $candidate; break }
}
if (-not $csc) { throw '没有找到系统自带的 C# 编译器 csc.exe。' }

$frameworkDir = Split-Path -Parent $csc
$winForms = Join-Path $frameworkDir 'System.Windows.Forms.dll'
if (-not (Test-Path -LiteralPath $winForms)) { throw ('没有找到 System.Windows.Forms.dll：' + $winForms) }

# PowerShell 引擎（宿主要用）：先从 GAC 的固定路径找，找不到就扫一遍
$automation = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll'
if (-not (Test-Path -LiteralPath $automation)) {
    $automation = Get-ChildItem (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'System.Management.Automation.dll' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
}
if (-not $automation -or -not (Test-Path -LiteralPath $automation)) {
    throw '没有找到 System.Management.Automation.dll（Windows PowerShell 引擎），没法编译独立宿主。'
}

# 先编译成 ASCII 文件名，再改成中文名：命令行里塞中文容易踩编码的坑
if (Test-Path -LiteralPath $tempExe) { Remove-Item -LiteralPath $tempExe -Force }

$compilerArguments = @(
    '/nologo'
    '/target:winexe'
    '/optimize+'
    '/platform:anycpu'
    ('/out:' + $tempExe)
    ('/win32icon:' + $iconPath)
    ('/reference:' + $winForms)
    ('/reference:' + $automation)
    $sourcePath
)

Write-Output ('正在编译：' + $sourcePath)
Write-Output ('  引擎引用：' + $automation)
& $csc $compilerArguments
if ($LASTEXITCODE -ne 0) { throw ('编译失败，退出码 ' + $LASTEXITCODE) }
if (-not (Test-Path -LiteralPath $tempExe)) { throw '编译没有产出 exe。' }

if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
Move-Item -LiteralPath $tempExe -Destination $OutFile -Force

$info = Get-Item -LiteralPath $OutFile
Write-Output ('已生成：' + $info.FullName)
Write-Output ('  大小：' + [Math]::Round($info.Length / 1KB, 1) + ' KB')
Write-Output ('  图标：' + $iconPath)
Write-Output '  双击即可打开桌面程序（进程名就是这个 exe，不会再起 powershell.exe）。'
Write-Output '  命令行：--reminder 提醒弹窗 / --watch 看门进程 / --script <脚本名>。'
Write-Output '  脚本文件要留在同一个文件夹里（必须是带 BOM 的 UTF-8）。'
