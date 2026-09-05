<#
.SYNOPSIS
    用 MSYS2 MinGW64 编一份音频-only 静态 FFmpeg，安装到 build-ffmpeg-mingw64\prefix。
    不启用 GPL、不拉 x264/gnutls 等外部库。产物给 ttcore.dll 静态链接。
#>
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Src = Join-Path $RepoRoot 'third_party\ffmpeg\configure'
if (-not (Test-Path -LiteralPath $Src)) {
    throw "缺少 third_party\ffmpeg（git submodule update --init --depth 1 third_party/ffmpeg）"
}

. (Join-Path $PSScriptRoot 'WinToolchain.ps1')
$bash = Get-Msys2Bash

$drive = $RepoRoot.Substring(0, 1).ToLowerInvariant()
$unixRoot = '/' + $drive + ($RepoRoot.Substring(2) -replace '\\', '/')

$env:MSYSTEM = 'MINGW64'
$env:CHERE_INVOKING = '1'
$env:MSYS2_PATH_TYPE = 'minimal'

Write-Host "[build-ffmpeg-win] MSYS2 $unixRoot/tools/build-ffmpeg-win.sh"
$argv = @('--login', '-c', "cd '$unixRoot' && exec ./tools/build-ffmpeg-win.sh")
& $bash @argv
if ($LASTEXITCODE -ne 0) {
    throw "build-ffmpeg-win.sh failed with exit $LASTEXITCODE"
}

$lib = Join-Path $RepoRoot 'build-ffmpeg-mingw64\prefix\lib\libavcodec.a'
if (-not (Test-Path -LiteralPath $lib)) {
    throw "未生成 $lib"
}
Write-Host "[build-ffmpeg-win] $lib ($((Get-Item -LiteralPath $lib).Length) bytes)"
