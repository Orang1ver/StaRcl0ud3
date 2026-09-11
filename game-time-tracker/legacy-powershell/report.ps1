$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptDir 'activity.csv'
$listPath = Join-Path $scriptDir 'games.txt'

if (-not (Test-Path -LiteralPath $logPath)) {
    Write-Host 'No log file found yet. Start the tracker first.'
    exit 1
}

$rows = @(Import-Csv -LiteralPath $logPath -Encoding UTF8)
if ($rows.Count -eq 0) {
    Write-Host 'The log is empty. Start the tracker first.'
    exit 1
}

$gameList = @()
if (Test-Path -LiteralPath $listPath) {
    $gameList = @(
        Get-Content -LiteralPath $listPath -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and -not $_.StartsWith('#') } |
            ForEach-Object { $_.ToLowerInvariant() }
    )
}

$items = @(
    $rows | ForEach-Object {
        $s = [datetime]::Parse($_.Start)
        $e = [datetime]::Parse($_.End)
        $proc = $_.Process
        $isGame = ($gameList.Count -gt 0) -and ($gameList -contains $proc.ToLowerInvariant())
        [pscustomobject]@{
            Date    = $s.Date
            Process = $proc
            Minutes = ($e - $s).TotalMinutes
            IsGame  = $isGame
        }
    }
)

$dayGroups = @($items | Group-Object Date | Sort-Object { $_.Name } -Descending)
$grandGame = 0.0
$grandAll = 0.0

Write-Host '=== Game Time Report ==='
Write-Host '[game] = process matched in games.txt'

foreach ($dayGroup in $dayGroups) {
    Write-Host ''
    Write-Host ('====== ' + $dayGroup.Group[0].Date.ToString('yyyy-MM-dd') + ' ======')

    $procGroups = @(
        $dayGroup.Group |
            Group-Object Process |
            Sort-Object { ($_.Group | Measure-Object -Property Minutes -Sum).Sum } -Descending
    )

    $dayGame = 0.0
    $dayAll = 0.0

    foreach ($pg in $procGroups) {
        $sum = ($pg.Group | Measure-Object -Property Minutes -Sum).Sum
        $dayAll += $sum

        $mark = ''
        if ($pg.Group[0].IsGame) {
            $dayGame += $sum
            $mark = '  [game]'
        }

        Write-Host ('  {0,-24} {1,8:N1} min{2}' -f $pg.Name, $sum, $mark)
    }

    $grandAll += $dayAll
    $grandGame += $dayGame
    Write-Host ('  Day total: {0:N1} min  (game: {1:N1} min)' -f $dayAll, $dayGame)
}

Write-Host ''
Write-Host ('Grand total : {0:N1} min' -f $grandAll)
Write-Host ('Game total  : {0:N1} min' -f $grandGame)

if ($gameList.Count -eq 0) {
    Write-Host ''
    Write-Host 'Tip: to mark games in the report, add their process names to games.txt'
    Write-Host '(one name per line, without ".exe"). Find the name while the game is'
    Write-Host 'running: Task Manager > Details > the game process name.'
}
elseif (($items | Where-Object { $_.IsGame } | Measure-Object).Count -eq 0) {
    Write-Host ''
    Write-Host 'Tip: nothing in games.txt matched the recorded processes. Check the'
    Write-Host 'process names above and update games.txt.'
}
