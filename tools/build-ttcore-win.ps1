<#
.SYNOPSIS
    用 MSYS2 MinGW64 + Ninja 只编 ttcore.dll（BUILD_QT_APP=OFF），并复制到 pascal\bin。
    FFmpeg 与 MinGW CRT 静态打进 DLL；SDL2.dll 复制到同一目录。

.PARAMETER Config
    Debug / Release / Profile（默认 Debug）。
    Profile = Release 优化 + DWARF，Windows 上再经 cv2pdb 生成 PDB。
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release', 'Profile')]
    [string]$Config = 'Debug'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $RepoRoot
. (Join-Path $PSScriptRoot 'Cv2pdb.ps1')

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

$cv2pdb = $null
if ($Config -ne 'Release') {
    $cv2pdb = Get-Cv2pdbExecutable
}

$BuildDir = Join-Path $RepoRoot "build\Windows\ttcore-$($Config.ToLowerInvariant())"
$cmakeArgs = @(
    '-S', $RepoRoot,
    '-B', $BuildDir,
    '-G', 'Ninja',
    '-DBUILD_QT_APP=OFF',
    "-DCMAKE_BUILD_TYPE=$Config",
    '-DTTCORE_STATIC_FFMPEG=ON'
)
if ($cv2pdb) {
    $cmakeArgs += "-DCV2PDB_EXECUTABLE=$cv2pdb"
}
Write-Host "[build-ttcore-win] cmake $($cmakeArgs -join ' ')"
& cmake.exe @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed: $LASTEXITCODE" }

Write-Host "[build-ttcore-win] cmake --build ttcore ttcore_probe ($Config)"
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

if ($Config -ne 'Release') {
    $pdb = Join-Path $RepoRoot 'pascal\bin\ttcore.pdb'
    if (-not (Test-Path -LiteralPath $pdb)) {
        throw "未生成 $pdb（cv2pdb）"
    }
    Write-Host "[build-ttcore-win] $pdb ($((Get-Item -LiteralPath $pdb).Length) bytes)"
}

$objdump = Join-Path 'C:\msys64\mingw64\bin' 'objdump.exe'
if (Test-Path -LiteralPath $objdump) {
    $allowed = @('bcrypt.dll', 'kernel32.dll', 'msvcrt.dll', 'sdl2.dll')
    $deps = @(& $objdump -p $dll | ForEach-Object {
        if ($_ -match 'DLL Name:\s+(\S+)') { $Matches[1] }
    })
    $bad = @($deps | Where-Object { $allowed -notcontains $_.ToLowerInvariant() })
    Write-Host "[build-ttcore-win] imports: $($deps -join ', ')"
    if ($bad.Count -gt 0) {
        throw "ttcore.dll has extra imports (want bcrypt/KERNEL32/msvcrt/SDL2): $($bad -join ', ')"
    }
}
