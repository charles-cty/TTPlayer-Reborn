<#
.SYNOPSIS
    用 MSYS2 MinGW64 + Ninja 只编 ttcore.dll（BUILD_QT_APP=OFF），并复制到 pascal\bin。
    不复制 FFmpeg/SDL2/TagLib/MinGW 运行时 DLL：那些由 pacman 管，加载时走 MSYS2 前缀。
#>
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $RepoRoot

$env:PATH = 'C:\msys64\mingw64\bin;C:\msys64\usr\bin;' + $env:PATH
$env:PKG_CONFIG_PATH = 'C:\msys64\mingw64\lib\pkgconfig'

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
    '-DCMAKE_PREFIX_PATH=C:/msys64/mingw64'
)
Write-Host "[build-ttcore-win] cmake $($cmakeArgs -join ' ')"
& cmake.exe @cmakeArgs

Write-Host '[build-ttcore-win] cmake --build ttcore ttcore_probe'
& cmake.exe --build $BuildDir --target ttcore ttcore_probe

$dll = Join-Path $RepoRoot 'pascal\bin\ttcore.dll'
if (-not (Test-Path -LiteralPath $dll)) {
    throw "未生成 $dll"
}
Write-Host "[build-ttcore-win] $dll ($((Get-Item -LiteralPath $dll).Length) bytes)"
