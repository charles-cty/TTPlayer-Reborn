<#
.SYNOPSIS
    Build the Qt reference application with MSYS2 MinGW64 in the canonical
    build\windows\qt\<config> directory.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release', 'Profile')]
    [string]$Config = 'Debug'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $RepoRoot
. (Join-Path $PSScriptRoot 'WinToolchain.ps1')
. (Join-Path $PSScriptRoot 'Cv2pdb.ps1')

$ffmpegLib = Join-Path $RepoRoot 'build\windows\deps\ffmpeg-mingw64\prefix\lib\libavcodec.a'
if (-not (Test-Path -LiteralPath $ffmpegLib)) {
    & (Join-Path $PSScriptRoot 'build-ffmpeg-win.ps1')
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg build failed: $LASTEXITCODE" }
}

if ($env:MSYS2_ROOT -or $env:MINGW64_BIN) { Add-Mingw64ToPath }
foreach ($name in @('cmake.exe', 'ninja.exe', 'pkg-config.exe', 'gcc.exe', 'g++.exe', 'windres.exe')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "找不到 $name。设置 MSYS2_ROOT（或 MINGW64_BIN）或把 MinGW64 bin 加入 PATH。"
    }
}

$configDir = $Config.ToLowerInvariant()
$BuildDir = Join-Path $RepoRoot "build\windows\qt\$configDir"
$cmakeArgs = @(
    '-S', $RepoRoot,
    '-B', $BuildDir,
    '-G', 'Ninja',
    '-DBUILD_QT_APP=ON',
    "-DCMAKE_BUILD_TYPE=$Config",
    '-DCMAKE_C_COMPILER=gcc.exe',
    '-DCMAKE_CXX_COMPILER=g++.exe',
    '-DCMAKE_RC_COMPILER=windres.exe',
    '-DTTCORE_STATIC_FFMPEG=ON'
)
if ($Config -ne 'Release') {
    $cmakeArgs += "-DCV2PDB_EXECUTABLE=$(Get-Cv2pdbExecutable)"
}

Write-Host "[build-qt-win] cmake $($cmakeArgs -join ' ')"
& cmake.exe @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed: $LASTEXITCODE" }

Write-Host "[build-qt-win] cmake --build TTPlayerReborn ($Config)"
& cmake.exe --build $BuildDir --target TTPlayerReborn
if ($LASTEXITCODE -ne 0) { throw "cmake build failed: $LASTEXITCODE" }

$exe = Join-Path $BuildDir 'TTPlayerReborn.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "未生成 $exe" }
Write-Host "[build-qt-win] $exe ($((Get-Item -LiteralPath $exe).Length) bytes)"
