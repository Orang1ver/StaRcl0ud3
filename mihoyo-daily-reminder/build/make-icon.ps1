#requires -version 5.1
<#
.SYNOPSIS
  生成程序图标：assets\app.ico（多尺寸） + assets\app-256.png + assets\icon-preview.png

.DESCRIPTION
  图标就是「深色圆角方块 + 金色奖章 + 米」——和桌面程序里的配色一致。
  想换设计改这个脚本，然后重新跑一遍：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build\make-icon.ps1
  build-exe.ps1 会自动调用它。

.PARAMETER OutDir
  输出目录，默认是项目下的 assets。
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

Add-Type -AssemblyName System.Drawing

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $projectRoot 'assets' }
if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

$iconFontFamily = 'Microsoft YaHei UI'

function New-RoundedPath {
    param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $path.AddArc([float]$X, [float]$Y, [float]$d, [float]$d, 180, 90)
    $path.AddArc([float]($X + $W - $d), [float]$Y, [float]$d, [float]$d, 270, 90)
    $path.AddArc([float]($X + $W - $d), [float]($Y + $H - $d), [float]$d, [float]$d, 0, 90)
    $path.AddArc([float]$X, [float]($Y + $H - $d), [float]$d, [float]$d, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-IconBitmap {
    param([int]$Size)

    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    $pad = [double]$Size * 0.045
    $tile = New-RoundedPath -X $pad -Y $pad -W ($Size - 2 * $pad) -H ($Size - 2 * $pad) -R ([double]$Size * 0.22)
    $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 44, 51, 82),
        [System.Drawing.Color]::FromArgb(255, 24, 28, 44),
        55.0)
    $g.FillPath($bg, $tile)

    $rimWidth = [Math]::Max(1.0, [double]$Size * 0.012)
    $rim = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 255, 217, 138), [float]$rimWidth)
    $g.DrawPath($rim, $tile)

    $center = [double]$Size / 2.0
    $medalRadius = [double]$Size * 0.285

    # 奖章外面的光晕
    for ($i = 3; $i -ge 1; $i--) {
        $glowRadius = $medalRadius + [double]$Size * 0.05 * $i
        $alpha = 8 + 7 * (3 - $i)
        $glow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 255, 217, 138))
        $g.FillEllipse($glow, [float]($center - $glowRadius), [float]($center - $glowRadius), [float]($glowRadius * 2), [float]($glowRadius * 2))
        $glow.Dispose()
    }

    # 金章
    $medalPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $medalPath.AddEllipse([float]($center - $medalRadius), [float]($center - $medalRadius), [float]($medalRadius * 2), [float]($medalRadius * 2))
    $medalBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($medalPath)
    $medalBrush.CenterColor = [System.Drawing.Color]::FromArgb(255, 255, 236, 187)
    $medalBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(255, 230, 173, 56))
    $medalBrush.CenterPoint = New-Object System.Drawing.PointF([float]($center - $medalRadius * 0.28), [float]($center - $medalRadius * 0.32))
    $g.FillPath($medalBrush, $medalPath)

    # 「米」字：16 像素太小，只留金章
    if ($Size -ge 24) {
        $font = New-Object System.Drawing.Font(
            $iconFontFamily,
            [float]($medalRadius * 1.12),
            [System.Drawing.FontStyle]::Bold,
            [System.Drawing.GraphicsUnit]::Pixel)
        $format = New-Object System.Drawing.StringFormat
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $ink = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 58, 38, 0))
        # 稍微下移一点，让汉字在圆里看起来是正中
        $textTop = [double]$Size * 0.03
        $g.DrawString('米', $font, $ink, (New-Object System.Drawing.RectangleF(0, [float]$textTop, $Size, $Size)), $format)
        $font.Dispose()
        $ink.Dispose()
        $format.Dispose()
    }

    $g.Dispose()
    return $bitmap
}

function New-IconPreview {
    param([string]$Path, [int[]]$Sizes)

    $sheetWidth = 640
    $sheetHeight = 300
    $sheet = New-Object System.Drawing.Bitmap($sheetWidth, $sheetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    $dark = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 32, 36, 52))
    $light = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 245, 246, 250))
    $g.FillRectangle($dark, 0, 0, $sheetWidth, 150)
    $g.FillRectangle($light, 0, 150, $sheetWidth, 150)

    $x = 30
    foreach ($size in $Sizes) {
        $icon = New-IconBitmap -Size $size
        $g.DrawImage($icon, $x, [int](150 - $size), $size, $size)
        $g.DrawImage($icon, $x, [int](150 + (150 - $size) / 2), $size, $size)
        $icon.Dispose()
        $x += $size + 26
    }

    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $darkText = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 170, 182, 216))
    $lightText = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 90, 100, 130))
    $g.DrawString('深色背景 / 任务栏', $font, $darkText, 30, 12)
    $g.DrawString('浅色背景 / 资源管理器', $font, $lightText, 30, 162)

    $g.Dispose()
    $sheet.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $sheet.Dispose()
}

# ---------- 生成 ----------
$iconSizes = @(256, 128, 64, 48, 32, 24, 16)
$frames = @()

foreach ($size in $iconSizes) {
    $bmp = New-IconBitmap -Size $size
    if ($size -eq 256) { $bmp.Save((Join-Path $OutDir 'app-256.png'), [System.Drawing.Imaging.ImageFormat]::Png) }

    $memory = New-Object System.IO.MemoryStream
    $bmp.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
    $frames += ,@{ Size = $size; Bytes = $memory.ToArray() }
    $memory.Dispose()
    $bmp.Dispose()
}

# .ico 容器：ICONDIR + 每个尺寸的 ICONDIRENTRY + PNG 数据
$stream = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($stream)
$writer.Write([uint16]0)
$writer.Write([uint16]1)
$writer.Write([uint16]$frames.Count)

$dataOffset = 6 + 16 * $frames.Count
foreach ($frame in $frames) {
    $dimension = $frame.Size
    if ($dimension -ge 256) { $dimension = 0 }
    $writer.Write([byte]$dimension)
    $writer.Write([byte]$dimension)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$frame.Bytes.Length)
    $writer.Write([uint32]$dataOffset)
    $dataOffset += $frame.Bytes.Length
}
foreach ($frame in $frames) { $writer.Write($frame.Bytes) }
$writer.Flush()

$icoPath = Join-Path $OutDir 'app.ico'
[System.IO.File]::WriteAllBytes($icoPath, $stream.ToArray())
$writer.Dispose()
$stream.Dispose()

New-IconPreview -Path (Join-Path $OutDir 'icon-preview.png') -Sizes @(128, 64, 48, 32, 16)

Write-Output ('图标已生成：' + $icoPath)
Write-Output ('  尺寸：' + ($iconSizes -join ' / ') + ' 像素')
Write-Output ('  预览：' + (Join-Path $OutDir 'icon-preview.png'))
