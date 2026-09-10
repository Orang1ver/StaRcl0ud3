#requires -version 5.1
<#
.SYNOPSIS
  按 WCAG 2.1 复算界面配色的对比度，改颜色之后跑一遍确认没有掉到 4.5:1 以下。

.DESCRIPTION
  界面里所有文字都压在「半透明叠半透明」的表面上，肉眼看不出真实对比度，
  所以这里把每一层都合成出来再算。改配色时改下面的 $palette，然后跑：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build\check-contrast.ps1
#>
[CmdletBinding()]
param()

$palette = [ordered]@{
    # 窗口是渐变，其余表面都压在渐变最亮的一端（最差情况）：
    #   卡片   = 12% 白压窗口，药丸/徽章/日历格 = 12~15% 黑压卡片，未来格 = 28% 黑
    PageTop = '#2C3352'

    # 文字
    TextPrimary = '#FFFFFF'
    TextBody = '#D8E0F2'
    TextMuted = '#B7C2DE'
    TextFaint = '#A6B0CE'
    TextLocked = '#A6B1CE'
    TextFuture = '#98A2C0'
    Gold = '#FFDE9E'
    Green = '#7FE0B2'
    Blue = '#9CC3FF'
    Red = '#F6AEA3'
}

function Get-Lum {
    param([string]$Hex)
    $h = $Hex.TrimStart('#')
    if ($h.Length -eq 8) { $h = $h.Substring(2) }
    $vals = @(0, 2, 4) | ForEach-Object { [Convert]::ToInt32($h.Substring($_, 2), 16) / 255.0 }
    $f = { param($c) if ($c -le 0.03928) { $c / 12.92 } else { [Math]::Pow((($c + 0.055) / 1.055), 2.4) } }
    return 0.2126 * (& $f $vals[0]) + 0.7152 * (& $f $vals[1]) + 0.0722 * (& $f $vals[2])
}

function Get-Contrast {
    param([string]$Fg, [string]$Bg)
    $l1 = Get-Lum $Fg
    $l2 = Get-Lum $Bg
    return [Math]::Round((([Math]::Max($l1, $l2)) + 0.05) / (([Math]::Min($l1, $l2)) + 0.05), 2)
}

function Get-Composite {
    param([string]$Overlay, [string]$Bg, [double]$Alpha)
    $h = $Overlay.TrimStart('#'); if ($h.Length -eq 8) { $h = $h.Substring(2) }
    $bh = $Bg.TrimStart('#'); if ($bh.Length -eq 8) { $bh = $bh.Substring(2) }
    $out = ''
    for ($i = 0; $i -lt 3; $i++) {
        $c = [Convert]::ToInt32($h.Substring($i * 2, 2), 16)
        $b = [Convert]::ToInt32($bh.Substring($i * 2, 2), 16)
        $out += ('{0:X2}' -f [int][Math]::Round($c * $Alpha + $b * (1 - $Alpha)))
    }
    return '#' + $out
}

$page = $palette.PageTop
$card = Get-Composite -Overlay '#FFFFFF' -Bg $page -Alpha 0.12
$sidebar = Get-Composite -Overlay '#FFFFFF' -Bg $page -Alpha 0.07
$chip = Get-Composite -Overlay '#000000' -Bg $card -Alpha 0.15
$cell = Get-Composite -Overlay '#000000' -Bg $card -Alpha 0.12
$futureCell = Get-Composite -Overlay '#000000' -Bg $card -Alpha 0.28
$popupCard = Get-Composite -Overlay '#FFFFFF' -Bg '#343B5F' -Alpha 0.084

$surfaces = [ordered]@{
    '窗口'   = $page
    '侧栏'   = $sidebar
    '卡片'   = $card
    '药丸'   = $chip
    '日历格' = $cell
    '未来格' = $futureCell
    '弹窗卡' = $popupCard
}

$pairs = @(
    @{ T = 'TextPrimary'; S = '窗口' }
    @{ T = 'TextPrimary'; S = '卡片' }
    @{ T = 'TextBody'; S = '卡片' }
    @{ T = 'TextMuted'; S = '窗口' }
    @{ T = 'TextMuted'; S = '侧栏' }
    @{ T = 'TextMuted'; S = '卡片' }
    @{ T = 'TextMuted'; S = '药丸' }
    @{ T = 'TextFaint'; S = '药丸' }
    @{ T = 'TextFaint'; S = '日历格' }
    @{ T = 'TextLocked'; S = '药丸' }
    @{ T = 'TextFuture'; S = '未来格' }
    @{ T = 'Gold'; S = '卡片' }
    @{ T = 'Green'; S = '卡片' }
    @{ T = 'Blue'; S = '卡片' }
    @{ T = 'Red'; S = '卡片' }
    @{ T = 'TextMuted'; S = '弹窗卡' }
)

Write-Output '表面（合成后的实际颜色）：'
foreach ($k in $surfaces.Keys) { Write-Output ('  ' + $k.PadRight(8) + $surfaces[$k]) }
Write-Output ''
Write-Output ('{0,-14} {1,-10} {2,-8} {3}' -f '文字', '背景', '对比度', '结论')

$failed = 0
foreach ($pair in $pairs) {
    $fg = $palette[$pair.T]
    $bg = $surfaces[$pair.S]
    $ratio = Get-Contrast -Fg $fg -Bg $bg
    $verdict = 'X 不足 4.5'
    if ($ratio -ge 7) { $verdict = 'OK AAA' }
    elseif ($ratio -ge 4.5) { $verdict = 'OK AA' }
    else { $failed++ }
    Write-Output ('{0,-14} {1,-10} {2,-8} {3}' -f $pair.T, $pair.S, $ratio, $verdict)
}

Write-Output ''
if ($failed -eq 0) { Write-Output '全部组合达到 WCAG AA（4.5:1）' }
else { Write-Output ('仍有 ' + $failed + ' 个组合不达标，别就这么发出去') }
