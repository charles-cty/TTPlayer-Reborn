<#
.SYNOPSIS
    用 MSYS2 MinGW64 + Ninja 只编 ttcore.dll（BUILD_QT_APP=OFF），并复制到 pascal\bin。
    FFmpeg 与 MinGW CRT 静态打进 DLL；SDL2.dll 复制到同一目录。
#>
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $RepoRoot

$ffmpegLib = Join-Path $RepoRoot 'build-ffmpeg-mingw64\prefix\lib\libavcodec.a'
if (-not (Test-Path -LiteralPath $ffmpegLib)) {
    Write-Host '[build-ttcore-win] static FFmpeg prefix missing, building it'
    & (Join-Path $PSScriptRoot 'build-ffmpeg-win.ps1')
}

$env:PATH = 'C:\msys64\mingw64\bin;C:\msys64\usr\bin;' + $env:PATH

foreach ($name in @('cmake.exe', 'ninja.exe', 'pkg-config.exe', 'g++.exe')) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $c) { throw "找不到 $name（需要 MSYS2 mingw-w64 工具链）" }
}

$BuildDir = Join-Path $RepoRoot 'build-ttcore-mingw64'
$cmakeArgs = @(
    '-S', $RepoRoot,
    '-B', $BuildDir,
    '-G', 'Ninja',
    '-DBUILD_QT_APP=OFF',
    '-DCMAKE_BUILD_TYPE=RelWithDebInfo',
    '-DTTCORE_STATIC_FFMPEG=ON'
)
Write-Host "[build-ttcore-win] cmake $($cmakeArgs -join ' ')"
& cmake.exe @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed: $LASTEXITCODE" }

Write-Host '[build-ttcore-win] cmake --build ttcore ttcore_probe'
& cmake.exe --build $BuildDir --target ttcore ttcore_probe
if ($LASTEXITCODE -ne 0) { throw "cmake build failed: $LASTEXITCODE" }

$dll = Join-Path $RepoRoot 'pascal\bin\ttcore.dll'
if (-not (Test-Path -LiteralPath $dll)) {
    throw "未生成 $dll"
}
Write-Host "[build-ttcore-win] $dll ($((Get-Item -LiteralPath $dll).Length) bytes)"
$sdl2 = Join-Path $RepoRoot 'pascal\bin\SDL2.dll'
if (Test-Path -LiteralPath $sdl2) {
    Write-Host "[build-ttcore-win] $sdl2 ($((Get-Item -LiteralPath $sdl2).Length) bytes)"
} else {
    throw "未复制 $sdl2"
}
