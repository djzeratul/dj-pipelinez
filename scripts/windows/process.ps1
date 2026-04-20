[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$EnvName,

        [Parameter(Mandatory = $true)]
        [string[]]$CommandNames
    )

    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        if (-not (Test-Path -LiteralPath $envValue -PathType Leaf)) {
            throw "$EnvName points to a missing file: $envValue"
        }

        return [System.IO.Path]::GetFullPath($envValue)
    }

    foreach ($commandName in $CommandNames) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    throw "$Label not found. Put it on PATH or set $EnvName."
}

function Reserve-UniquePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$LeafName
    )

    $candidate = Join-Path $Directory $LeafName
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($LeafName)
    $extension = [System.IO.Path]::GetExtension($LeafName)
    $index = 1

    do {
        $candidate = Join-Path $Directory ("{0}_{1}{2}" -f $stem, $index, $extension)
        $index += 1
    } while (Test-Path -LiteralPath $candidate)

    return $candidate
}

function Get-PngCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return 0
    }

    return (Get-ChildItem -LiteralPath $Directory -Filter "*.png" -File -ErrorAction SilentlyContinue | Measure-Object).Count
}

function Format-Duration {
    param(
        [Parameter(Mandatory = $true)]
        [int]$TotalSeconds
    )

    return [TimeSpan]::FromSeconds([Math]::Max(0, $TotalSeconds)).ToString("hh\:mm\:ss")
}

function Format-Eta {
    param(
        [Parameter(Mandatory = $true)]
        [int]$TotalSeconds
    )

    $seconds = [Math]::Max(0, $TotalSeconds)

    if ($seconds -lt 60) {
        return "{0}s" -f $seconds
    }

    if ($seconds -lt 3600) {
        return "{0}m {1:D2}s" -f [Math]::Floor($seconds / 60), ($seconds % 60)
    }

    if ($seconds -lt 86400) {
        return "{0}h {1:D2}m" -f [Math]::Floor($seconds / 3600), [Math]::Floor(($seconds % 3600) / 60)
    }

    return "{0}d {1:D2}h" -f [Math]::Floor($seconds / 86400), [Math]::Floor(($seconds % 86400) / 3600)
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptRoot)
$dataRoot = if ($env:DJ_PIPELINEZ_DATA_ROOT) {
    $env:DJ_PIPELINEZ_DATA_ROOT
} else {
    Join-Path $repoRoot "state\upscale"
}

$queueDir = if ($env:DJ_PIPELINEZ_WATCH_DIR) {
    $env:DJ_PIPELINEZ_WATCH_DIR
} else {
    Join-Path $dataRoot "incoming"
}
$originalsDir = Join-Path $dataRoot "originals"
$workRoot = Join-Path $dataRoot "work"
$outDir = Join-Path $dataRoot "outgoing"
$failDir = Join-Path $dataRoot "failed"

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    Write-Host "[worker] file no longer exists, skipping: $InputPath"
    return
}

$resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path
$baseName = [System.IO.Path]::GetFileName($resolvedInput)
$stem = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInput)

$realSrExe = Resolve-Executable -Label "Real-ESRGAN" -EnvName "DJ_PIPELINEZ_REALSR_EXE" -CommandNames @("realesrgan-ncnn-vulkan.exe", "realesrgan-ncnn-vulkan")
$ffmpegExe = Resolve-Executable -Label "ffmpeg" -EnvName "FFMPEG_EXE" -CommandNames @("ffmpeg.exe", "ffmpeg")
$ffprobeExe = Resolve-Executable -Label "ffprobe" -EnvName "FFPROBE_EXE" -CommandNames @("ffprobe.exe", "ffprobe")

$realSrDir = Split-Path -Parent $realSrExe
$modelName = if ($env:DJ_PIPELINEZ_MODEL_NAME) { $env:DJ_PIPELINEZ_MODEL_NAME } else { "realesrgan-x4plus" }
$tileSize = if ($env:DJ_PIPELINEZ_TILE_SIZE) { $env:DJ_PIPELINEZ_TILE_SIZE } else { "256" }
$threads = if ($env:DJ_PIPELINEZ_THREADS) { $env:DJ_PIPELINEZ_THREADS } else { "1:1:1" }
$cq = if ($env:DJ_PIPELINEZ_CQ) { $env:DJ_PIPELINEZ_CQ } else { "18" }
$preset = if ($env:DJ_PIPELINEZ_PRESET) { $env:DJ_PIPELINEZ_PRESET } else { "p5" }
$targetWidth = if ($env:DJ_PIPELINEZ_TARGET_WIDTH) { [int]$env:DJ_PIPELINEZ_TARGET_WIDTH } else { 3840 }
$targetHeight = if ($env:DJ_PIPELINEZ_TARGET_HEIGHT) { [int]$env:DJ_PIPELINEZ_TARGET_HEIGHT } else { 2160 }
$debugMode = $env:DEBUG -eq "1"
$videoFilter = "scale={0}:{1}:force_original_aspect_ratio=decrease,pad={0}:{1}:(ow-iw)/2:(oh-ih)/2" -f $targetWidth, $targetHeight

New-Item -ItemType Directory -Path $queueDir, $originalsDir, $workRoot, $outDir, $failDir -Force | Out-Null

$mutexName = "Global\DjPipelinez.Process"
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$lockTaken = $false
$jobDir = $null
$framesDir = $null
$upscaledDir = $null
$claimedInput = $null
$upscaleProcess = $null

try {
    $lockTaken = $mutex.WaitOne()

    if (-not (Test-Path -LiteralPath $resolvedInput -PathType Leaf)) {
        Write-Host "[worker] file no longer exists, skipping: $resolvedInput"
        return
    }

    $jobDir = Join-Path $workRoot ("{0}.{1}" -f $stem, [guid]::NewGuid().ToString("N"))
    $framesDir = Join-Path $jobDir "frames"
    $upscaledDir = Join-Path $jobDir "upscaled"
    New-Item -ItemType Directory -Path $framesDir, $upscaledDir -Force | Out-Null

    Write-Host "[worker] claiming $resolvedInput"
    $claimedInput = Reserve-UniquePath -Directory $originalsDir -LeafName $baseName
    Move-Item -LiteralPath $resolvedInput -Destination $claimedInput
    Write-Host "[worker] processing $claimedInput"

    $jobStart = Get-Date

    $sourceFps = (& $ffprobeExe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $claimedInput 2>$null |
        Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($sourceFps)) {
        $sourceFps = "30/1"
    }

    & $ffmpegExe -hide_banner -y -threads 6 -i $claimedInput -vsync 0 (Join-Path $framesDir "frame_%08d.png")
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg frame extraction failed."
    }

    $totalFrames = Get-PngCount -Directory $framesDir
    Write-Host "[worker] total frames: $totalFrames"

    if ($totalFrames -eq 0) {
        throw "extract failed: no frames generated"
    }

    $upscaleArgs = @(
        "-i", $framesDir,
        "-o", $upscaledDir,
        "-n", $modelName,
        "-s", "4",
        "-t", $tileSize,
        "-j", $threads
    )

    $upscaleStart = Get-Date
    $stdoutLog = Join-Path $jobDir "realesrgan.stdout.log"
    $stderrLog = Join-Path $jobDir "realesrgan.stderr.log"

    $startInfo = @{
        FilePath = $realSrExe
        ArgumentList = $upscaleArgs
        WorkingDirectory = $realSrDir
        PassThru = $true
    }

    if ($debugMode) {
        $startInfo["NoNewWindow"] = $true
    } else {
        $startInfo["RedirectStandardOutput"] = $stdoutLog
        $startInfo["RedirectStandardError"] = $stderrLog
    }

    $upscaleProcess = Start-Process @startInfo

    while (-not $upscaleProcess.HasExited) {
        Start-Sleep -Seconds 2
        $upscaleProcess.Refresh()

        $done = Get-PngCount -Directory $upscaledDir
        $elapsed = [int][Math]::Max(0, ((Get-Date) - $upscaleStart).TotalSeconds)

        if ($done -gt 0 -and $elapsed -gt 0) {
            $upscaleFps = $done / $elapsed
            $remaining = [Math]::Max(0, $totalFrames - $done)
            $etaSeconds = if ($upscaleFps -gt 0) { [int][Math]::Round($remaining / $upscaleFps) } else { 0 }
        } else {
            $upscaleFps = 0.0
            $etaSeconds = 0
        }

        $percentComplete = if ($totalFrames -gt 0) {
            [Math]::Min(100, [int][Math]::Round(($done / $totalFrames) * 100))
        } else {
            0
        }

        $status = "{0} / {1} | {2:N2} fps | ETA {3}" -f $done, $totalFrames, $upscaleFps, (Format-Eta -TotalSeconds $etaSeconds)
        Write-Progress -Activity "Upscaling frames" -Status $status -PercentComplete $percentComplete
    }

    $upscaleProcess.WaitForExit()
    Write-Progress -Activity "Upscaling frames" -Completed

    if ($upscaleProcess.ExitCode -ne 0) {
        if (-not $debugMode -and (Test-Path -LiteralPath $stderrLog)) {
            $stderrTail = Get-Content -LiteralPath $stderrLog -Tail 20 -ErrorAction SilentlyContinue
            if ($stderrTail) {
                Write-Host "[worker] Real-ESRGAN stderr:"
                $stderrTail | ForEach-Object { Write-Host $_ }
            }
        }

        throw "Real-ESRGAN exited with code $($upscaleProcess.ExitCode)."
    }

    $upscaledCount = Get-PngCount -Directory $upscaledDir
    if ($upscaledCount -eq 0) {
        throw "upscale failed: no output frames generated"
    }

    $outputPath = Reserve-UniquePath -Directory $outDir -LeafName ("{0}_4k.mp4" -f $stem)

    & $ffmpegExe -hide_banner -y -threads 6 -framerate $sourceFps -i (Join-Path $upscaledDir "frame_%08d.png") -i $claimedInput -map "0:v:0" -map "1:a?" -c:v hevc_nvenc -preset $preset -cq $cq -pix_fmt yuv420p -vf $videoFilter -c:a copy -shortest $outputPath
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg encode failed."
    }

    $jobEnd = Get-Date
    $upscaleElapsed = [int][Math]::Max(0, ($upscaleProcess.ExitTime - $upscaleStart).TotalSeconds)
    $totalElapsed = [int][Math]::Max(0, ($jobEnd - $jobStart).TotalSeconds)
    $avgUpscaleFps = if ($upscaleElapsed -gt 0) {
        "{0:N2}" -f ($totalFrames / $upscaleElapsed)
    } else {
        "0.00"
    }

    Write-Host "[worker] finished -> $outputPath"
    Write-Host "[worker] summary | total: $(Format-Duration -TotalSeconds $totalElapsed) | avg upscale: $avgUpscaleFps fps"
} catch {
    Write-Host "[worker] $($_.Exception.Message)"
    if ($claimedInput) {
        Write-Host "[worker] original retained at $claimedInput"
    }

    throw
} finally {
    if ($upscaleProcess -and -not $upscaleProcess.HasExited) {
        try {
            $upscaleProcess.Kill($true)
        } catch {
        }
    }

    Write-Progress -Activity "Upscaling frames" -Completed -ErrorAction SilentlyContinue

    if ($jobDir -and (Test-Path -LiteralPath $jobDir)) {
        Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($lockTaken) {
        $mutex.ReleaseMutex() | Out-Null
    }

    $mutex.Dispose()
}
