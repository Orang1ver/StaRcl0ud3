param(
    [int]$PollSeconds = 2,
    [int]$CheckpointSeconds = 60,
    [switch]$Auto,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptDir 'activity.csv'
$listPath = Join-Path $scriptDir 'games.txt'
$stopPath = Join-Path $scriptDir 'stop.txt'
$errorLogPath = Join-Path $scriptDir 'tracker-error.log'

function Read-GameList {
    if (-not (Test-Path -LiteralPath $listPath)) { return @() }
    return @(
        Get-Content -LiteralPath $listPath -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and -not $_.StartsWith('#') } |
            ForEach-Object { $_.ToLowerInvariant() }
    )
}

function Append-Segment {
    param(
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$ProcessName
    )

    if ($EndTime -le $StartTime) { return }

    $row = [pscustomobject]@{
        Start   = $StartTime.ToString('yyyy-MM-dd HH:mm:ss')
        End     = $EndTime.ToString('yyyy-MM-dd HH:mm:ss')
        Process = $ProcessName
        Title   = ''
    }

    $lines = @($row | ConvertTo-Csv -NoTypeInformation)
    if ($lines.Count -ge 2) {
        Add-Content -LiteralPath $logPath -Value $lines[1] -Encoding UTF8
    }
}

$gameList = @(Read-GameList)

if ($Test) {
    Write-Host ('OK - tracker loaded. Games in list: ' + ($gameList -join ', '))
    exit 0
}

if ($gameList.Count -eq 0) {
    Write-Host 'games.txt has no game names yet.'
    Write-Host 'Add one process name per line first, then start again.'
    exit 1
}

if (Test-Path -LiteralPath $stopPath) {
    Remove-Item -LiteralPath $stopPath -Force
}

$createdNew = $false
$instanceMutex = New-Object System.Threading.Mutex($true, 'GameTimeTrackerSingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    if (-not $Auto) { Write-Host 'Tracker is already running. Stop it first, then start again.' }
    exit 0
}

if (-not (Test-Path -LiteralPath $logPath)) {
    'Start,End,Process,Title' | Set-Content -LiteralPath $logPath -Encoding UTF8
}

if (-not $Auto) {
    Write-Host '=== Game Time Tracker (runtime mode) ==='
    Write-Host ('Watching: ' + ($gameList -join ', '))
    Write-Host ('Data file: ' + $logPath)
    Write-Host 'Time is counted while a watched process is running, whether it is'
    Write-Host 'in the foreground, minimized, or idle. Press Q to stop.'
    Write-Host ''
}

$active = @{}
$quit = $false
$count = 0
$minimumFlushSeconds = [math]::Max(2, $PollSeconds)

while (-not $quit) {
    Start-Sleep -Milliseconds ($PollSeconds * 1000)

    if (-not $Auto) {
        $keyInfo = $null
        try {
            if ([Console]::KeyAvailable) { $keyInfo = [Console]::ReadKey($true) }
        } catch { }

        if ($null -ne $keyInfo -and $keyInfo.Key.ToString() -eq 'Q') {
            $quit = $true
            break
        }
    }

    try {
        $gameList = @(Read-GameList)

        if (Test-Path -LiteralPath $stopPath) {
            Remove-Item -LiteralPath $stopPath -Force
            $quit = $true
            break
        }

        $now = Get-Date
        $processNames = @{}

        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            if ($null -ne $p -and $p.ProcessName) {
                $processNames[$p.ProcessName.ToLowerInvariant()] = $true
            }
        }

        if ($gameList -contains 'minecraft') {
            try {
                $javaProcesses = @(Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction SilentlyContinue)
                foreach ($javaProcess in $javaProcesses) {
                    if ($javaProcess.CommandLine -and $javaProcess.CommandLine -match 'net\.minecraft\.client\.main\.Main') {
                        $processNames['minecraft'] = $true
                        break
                    }
                }
            } catch {
                # Minecraft detection is optional; ignore any failure so tracking never stops.
            }
        }

        foreach ($game in $gameList) {
            if ($processNames.ContainsKey($game)) {
                if (-not $active.ContainsKey($game)) {
                    $active[$game] = $now
                    if (-not $Auto) {
                        Write-Host ('{0}  started : {1}' -f $now.ToString('HH:mm:ss'), $game) -ForegroundColor Green
                    }
                }
                else {
                    $lastCheck = $active[$game]
                    if (($now - $lastCheck).TotalSeconds -ge $CheckpointSeconds) {
                        Append-Segment $lastCheck $now $game
                        $count++
                        $active[$game] = $now
                    }
                }
            }
            elseif ($active.ContainsKey($game)) {
                $lastCheck = $active[$game]
                if (($now - $lastCheck).TotalSeconds -ge $minimumFlushSeconds) {
                    Append-Segment $lastCheck $now $game
                    $count++
                }
                $active.Remove($game)
                if (-not $Auto) {
                    Write-Host ('{0}  stopped : {1}' -f $now.ToString('HH:mm:ss'), $game) -ForegroundColor Yellow
                }
            }
        }
    } catch {
        try {
            $errorMessage = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message
            Add-Content -LiteralPath $errorLogPath -Value $errorMessage -Encoding UTF8
        } catch { }
    }
}

foreach ($game in @($active.Keys)) {
    $lastCheck = $active[$game]
    if (((Get-Date) - $lastCheck).TotalSeconds -ge $minimumFlushSeconds) {
        Append-Segment $lastCheck (Get-Date) $game
        $count++
    }
}

if (-not $Auto) {
    Write-Host ''
    Write-Host ('Stopped. Records saved: ' + $count)
    Write-Host 'Run show-report.bat to see the totals.'
}
