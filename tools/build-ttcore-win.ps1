<#
.SYNOPSIS
    用 MSYS2 MinGW64 + Ninja 只编 ttcore.dll（BUILD_QT_APP=OFF），并部署到独立 Pascal 构建目录。
    FFmpeg 与 MinGW CRT 静态打进 DLL；SDL2.dll 复制到同一目录。
    路径来自环境变量或 PATH，不写死 C:\msys64：

      MSYS2_ROOT   MSYS2 安装根目录
      MINGW64_BIN  可选，MinGW64 bin
      SDL2_PREFIX  可选，官方 MinGW SDL2 根目录

.PARAMETER Config
    Debug / Release / Profile（默认 Debug）。
    Profile = Release 优化 + DWARF，Windows 上再经 cv2pdb 生成 PDB。

.PARAMETER DeployConfig
    可选，将运行时部署到指定的 Pascal 配置目录。默认与 Config 相同。
    例如 HeapTrc 的 Pascal 产物使用 Debug ttcore，但部署到 heaptrc 目录。
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release', 'Profile')]
    [string]$Config = 'Debug',
    [ValidateSet('', 'Debug', 'Release', 'Profile', 'HeapTrc')]
    [string]$DeployConfig = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $RepoRoot
. (Join-Path $PSScriptRoot 'Cv2pdb.ps1')

$ffmpegLib = Join-Path $RepoRoot 'build\windows\deps\ffmpeg-mingw64\prefix\lib\libavcodec.a'
if (-not (Test-Path -LiteralPath $ffmpegLib)) {
    Write-Host '[build-ttcore-win] static FFmpeg prefix missing, building it'
    & (Join-Path $PSScriptRoot 'build-ffmpeg-win.ps1')
}

. (Join-Path $PSScriptRoot 'WinToolchain.ps1')
if ($env:MSYS2_ROOT -or $env:MINGW64_BIN) {
    Add-Mingw64ToPath
}

$commands = @{}
foreach ($name in @('cmake.exe', 'ninja.exe', 'pkg-config.exe', 'gcc.exe', 'g++.exe', 'windres.exe')) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $c) {
        throw "找不到 $name。设置 MSYS2_ROOT（或 MINGW64_BIN）或把 MinGW64 bin 加入 PATH。"
    }
    $commands[$name] = $c
}

$cv2pdb = $null
if ($Config -ne 'Release') {
    $cv2pdb = Get-Cv2pdbExecutable
}

$configDir = $Config.ToLowerInvariant()
$deployConfigDir = if ($DeployConfig) {
    $DeployConfig.ToLowerInvariant()
} else {
    $configDir
}
$BuildDir = Join-Path $RepoRoot "build\windows\ttcore\$configDir"
$PascalRuntimeDir = Join-Path $RepoRoot "build\windows\pascal\$deployConfigDir"
$gcc = $commands['gcc.exe'].Source.Replace('\', '/')
$gxx = $commands['g++.exe'].Source.Replace('\', '/')
$windres = $commands['windres.exe'].Source.Replace('\', '/')
$cmakeArgs = @(
    '-S', $RepoRoot,
    '-B', $BuildDir,
    '-G', 'Ninja',
    "-DCMAKE_C_COMPILER=$gcc",
    "-DCMAKE_CXX_COMPILER=$gxx",
    "-DCMAKE_RC_COMPILER=$windres",
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

$dll = Join-Path $BuildDir 'ttcore.dll'
if (-not (Test-Path -LiteralPath $dll)) { throw "未生成 $dll" }
New-Item -ItemType Directory -Force -Path $PascalRuntimeDir | Out-Null
Copy-Item -LiteralPath $dll -Destination $PascalRuntimeDir -Force
Copy-Item -LiteralPath (Join-Path $BuildDir 'ttcore_probe.exe') -Destination $PascalRuntimeDir -Force
Write-Host "[build-ttcore-win] $dll ($((Get-Item -LiteralPath $dll).Length) bytes)"
$sdl2 = Join-Path $BuildDir 'SDL2.dll'
if (-not (Test-Path -LiteralPath $sdl2)) { throw "未生成 $sdl2" }
Copy-Item -LiteralPath $sdl2 -Destination $PascalRuntimeDir -Force
Write-Host "[build-ttcore-win] runtime deployed to $PascalRuntimeDir"

if ($Config -ne 'Release') {
    $pdb = Join-Path $BuildDir 'ttcore.pdb'
    if (-not (Test-Path -LiteralPath $pdb)) {
        throw "未生成 $pdb（cv2pdb）"
    }
    Copy-Item -LiteralPath $pdb -Destination $PascalRuntimeDir -Force
    Write-Host "[build-ttcore-win] $pdb ($((Get-Item -LiteralPath $pdb).Length) bytes)"
}

$objdumpCmd = Get-Command objdump.exe -ErrorAction SilentlyContinue
$objdump = if ($objdumpCmd) { $objdumpCmd.Source } else { $null }
if ($objdump -and (Test-Path -LiteralPath $objdump)) {
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
