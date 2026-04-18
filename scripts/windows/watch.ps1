[CmdletBinding()]
param(
    [string]$WatchDir,
    [string]$ProcessScript,
    [int]$FileStableSeconds = 3,
    [int]$IdleSweepSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptRoot)
$dataRoot = if ($env:DJ_PIPELINEZ_DATA_ROOT) {
    $env:DJ_PIPELINEZ_DATA_ROOT
} else {
    Join-Path $repoRoot "state\upscale"
}

if (-not $PSBoundParameters.ContainsKey("WatchDir")) {
    $WatchDir = if ($env:DJ_PIPELINEZ_WATCH_DIR) {
        $env:DJ_PIPELINEZ_WATCH_DIR
    } else {
        Join-Path $dataRoot "incoming"
    }
}

if (-not $PSBoundParameters.ContainsKey("ProcessScript")) {
    $ProcessScript = Join-Path $scriptRoot "process.ps1"
}

$WatchDir = [System.IO.Path]::GetFullPath($WatchDir)
$ProcessScript = [System.IO.Path]::GetFullPath($ProcessScript)

$supportedExtensions = @(".mp4", ".mov", ".mkv", ".avi", ".webm")

function Test-FinishedCopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$StableSeconds
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $first = (Get-Item -LiteralPath $Path).Length
    Start-Sleep -Seconds $StableSeconds

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $second = (Get-Item -LiteralPath $Path).Length
    if ($first -le 0 -or $first -ne $second) {
        return $false
    }

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )
        $stream.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Invoke-Processor {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    Write-Host "[watcher] found ready file: $($File.FullName)"

    try {
        & $ProcessScript -InputPath $File.FullName
    } catch {
        Write-Warning "[watcher] processor failed for $($File.FullName): $($_.Exception.Message)"
    }
}

function Process-Pending {
    $files = Get-ChildItem -LiteralPath $WatchDir -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime, Name

    foreach ($file in $files) {
        $extension = $file.Extension.ToLowerInvariant()

        if ($supportedExtensions -notcontains $extension) {
            Write-Host "[watcher] ignoring unsupported file: $($file.FullName)"
            continue
        }

        if (Test-FinishedCopy -Path $file.FullName -StableSeconds $FileStableSeconds) {
            Invoke-Processor -File $file
        } else {
            Write-Host "[watcher] file still copying: $($file.FullName)"
        }
    }
}

if (-not (Test-Path -LiteralPath $ProcessScript -PathType Leaf)) {
    throw "process script not found: $ProcessScript"
}

New-Item -ItemType Directory -Path $WatchDir -Force | Out-Null

Write-Host "[watcher] watching $WatchDir"
Process-Pending

$watcher = [System.IO.FileSystemWatcher]::new($WatchDir)
$watcher.Filter = "*"
$watcher.IncludeSubdirectories = $false
$watcher.NotifyFilter = [System.IO.NotifyFilters]"FileName, LastWrite, Size, CreationTime"
$watcher.EnableRaisingEvents = $true

$subscriptions = @(
    Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier "dj-pipelinez.created",
    Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier "dj-pipelinez.changed",
    Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier "dj-pipelinez.renamed"
)

try {
    while ($true) {
        $event = Wait-Event -Timeout $IdleSweepSeconds

        if ($null -ne $event) {
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }

        Process-Pending
    }
} finally {
    foreach ($subscription in $subscriptions) {
        Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
    }

    $watcher.Dispose()
}
