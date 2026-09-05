<#
.SYNOPSIS
    Resolve Windows build tools from environment variables or PATH.

    No hardcoded C:\lazarus or C:\msys64. Set:

      MSYS2_ROOT   MSYS2 install root (usr\bin\bash.exe, mingw64\bin)
      MSYS2_BASH   optional full path to MSYS2 bash.exe
      MINGW64_BIN  optional MinGW64 bin directory
      LAZARUS_DIR  Lazarus root (lazbuild.exe)
      LAZBUILD     optional full path to lazbuild.exe
#>
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-Msys2Root {
    if (-not $env:MSYS2_ROOT) {
        throw '未设置 MSYS2_ROOT。请指向 MSYS2 安装根目录（内含 usr\bin\bash.exe 与 mingw64\bin）。'
    }
    if (-not (Test-Path -LiteralPath $env:MSYS2_ROOT)) {
        throw "MSYS2_ROOT 不存在：$($env:MSYS2_ROOT)"
    }
    return [System.IO.Path]::GetFullPath($env:MSYS2_ROOT)
}

function Get-Mingw64Bin {
    if ($env:MINGW64_BIN) {
        if (-not (Test-Path -LiteralPath $env:MINGW64_BIN)) {
            throw "MINGW64_BIN 不存在：$($env:MINGW64_BIN)"
        }
        return [System.IO.Path]::GetFullPath($env:MINGW64_BIN)
    }
    $bin = Join-Path (Get-Msys2Root) 'mingw64\bin'
    if (-not (Test-Path -LiteralPath $bin)) {
        throw "找不到 MinGW64 bin：$bin（设置 MSYS2_ROOT 或 MINGW64_BIN）"
    }
    return $bin
}

function Add-Mingw64ToPath {
    $mingw = Get-Mingw64Bin
    $parts = @($mingw)
    if ($env:MSYS2_ROOT) {
        $usr = Join-Path $env:MSYS2_ROOT 'usr\bin'
        if (Test-Path -LiteralPath $usr) {
            $parts += $usr
        }
    }
    $env:PATH = ($parts -join ';') + ';' + $env:PATH
}

function Get-Msys2Bash {
    if ($env:MSYS2_BASH) {
        if (-not (Test-Path -LiteralPath $env:MSYS2_BASH)) {
            throw "MSYS2_BASH 不存在：$($env:MSYS2_BASH)"
        }
        return $env:MSYS2_BASH
    }
    $bash = Join-Path (Get-Msys2Root) 'usr\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) {
        throw "找不到 $bash。请设置 MSYS2_ROOT 或 MSYS2_BASH。"
    }
    return $bash
}

function Get-LazbuildPath {
    if ($env:LAZBUILD) {
        if (-not (Test-Path -LiteralPath $env:LAZBUILD)) {
            throw "LAZBUILD 不存在：$($env:LAZBUILD)"
        }
        return $env:LAZBUILD
    }
    if ($env:LAZARUS_DIR) {
        $p = Join-Path $env:LAZARUS_DIR 'lazbuild.exe'
        if (Test-Path -LiteralPath $p) { return $p }
        throw "LAZARUS_DIR 下没有 lazbuild.exe：$p"
    }
    $cmd = Get-Command lazbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command lazbuild -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw '找不到 lazbuild。请设置 LAZARUS_DIR 或 LAZBUILD，或把 lazbuild 加入 PATH。'
}

function Get-LazarusDir {
    if ($env:LAZARUS_DIR) {
        if (-not (Test-Path -LiteralPath $env:LAZARUS_DIR)) {
            throw "LAZARUS_DIR 不存在：$($env:LAZARUS_DIR)"
        }
        return [System.IO.Path]::GetFullPath($env:LAZARUS_DIR)
    }
    Split-Path -Parent (Get-LazbuildPath)
}
