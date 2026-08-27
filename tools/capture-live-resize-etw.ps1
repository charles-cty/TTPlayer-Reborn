<#
.SYNOPSIS
    Capture an xperf CPU(+cswitch) trace of complex playlist/lyric live resize.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'C:\My\Repos\TTPlayer-Reborn',
    [switch]$SkipTrace
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$xperf = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe'
$python = 'C:\Program Files\Python312\python.exe'
$exe = Join-Path $Repo 'pascal\bin\ttplayer.exe'
$driver = Join-Path $Repo 'tools\profile-live-resize.py'
$work = Join-Path $env:TEMP 'ttplayer-zoom-profile'

if (-not (Test-Path -LiteralPath $xperf)) { throw "missing xperf: $xperf" }
if (-not (Test-Path -LiteralPath $python)) { throw "missing python: $python" }
if (-not (Test-Path -LiteralPath $exe)) { throw "missing ttplayer: $exe" }
if (-not (Test-Path -LiteralPath $driver)) { throw "missing driver: $driver" }

New-Item -ItemType Directory -Force -Path $work | Out-Null
Set-Location -LiteralPath $work
Remove-Item -LiteralPath (Join-Path $work '*') -Force -ErrorAction SilentlyContinue

$kernel = Join-Path $work 'kernel.etl'
$merged = Join-Path $work 'merged.etl'
$phases = Join-Path $work 'zoom-phases.log'
$gestureLog = Join-Path $work 'gesture.log'
$env:TTPLAYER_ZOOM_PHASES_LOG = $phases

Write-Host "WORK=$work"
Write-Host "PHASES=$phases"

Get-Process ttplayer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

$started = $false
try {
    if (-not $SkipTrace) {
        wpr.exe -status | Out-Host
        & $xperf -on PROC_THREAD+LOADER+PROFILE `
            -stackwalk PROFILE `
            -f $kernel
        if ($LASTEXITCODE -ne 0) { throw "xperf start failed: $LASTEXITCODE" }
        $started = $true
        Start-Sleep -Milliseconds 400
    }

    $pyArgs = @(
        $driver,
        '--exe', $exe,
        '--workdir', (Join-Path $Repo 'pascal\bin'),
        '--out', $work
    )
    Write-Host "RUN $($pyArgs -join ' ')"
    & $python @pyArgs *>&1 | Tee-Object -FilePath $gestureLog
    $pyExit = $LASTEXITCODE

    if (-not $SkipTrace) {
        & $xperf -d $merged
        if ($LASTEXITCODE -ne 0) { throw "xperf merge failed: $LASTEXITCODE" }
        $started = $false
    }

    if ($pyExit -ne 0) { throw "gesture driver failed: $pyExit" }
}
finally {
    if ($started) {
        & $xperf -stop 2>$null
    }
}

if ($SkipTrace) {
    Write-Host "SKIPPED_TRACE"
    exit 0
}

$processTxt = Join-Path $work 'process.txt'
$utilTxt = Join-Path $work 'profile-util.txt'
$detailTxt = Join-Path $work 'profile-detail.txt'

& $xperf -i $merged -o $processTxt -a process
if ($LASTEXITCODE -ne 0) { throw "xperf process report failed: $LASTEXITCODE" }
& $xperf -i $merged -o $utilTxt -a profile
if ($LASTEXITCODE -ne 0) { throw "xperf profile util failed: $LASTEXITCODE" }
& $xperf -i $merged -o $detailTxt -a profile -detail
if ($LASTEXITCODE -ne 0) { throw "xperf profile detail failed: $LASTEXITCODE" }

Write-Host "ETL=$merged"
Write-Host "UTIL=$utilTxt"
Write-Host "DETAIL=$detailTxt"
Write-Host "GESTURE=$gestureLog"
Write-Host "DONE"
