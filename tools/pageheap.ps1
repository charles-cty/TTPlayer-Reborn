<#
.SYNOPSIS
    Enable / disable / query Windows full page heap (GFlags) for TTPlayer binaries.

.DESCRIPTION
    HeapTrc (-gh) covers the Pascal heap. ttcore.dll / FFmpeg / SDL use the
    CRT/Windows heap — use this script on top of a HeapTrc build.

    Full page heap places each allocation on its own page with a guard page and
    does not reuse freed VA, so UAF / double-free fault at the bad access.
    gflags.exe is in the classic Debugging Tools for Windows kit (not the Store
    WinDbg package). Requires elevation for IFEO writes.

    ALWAYS -Action Disable when finished: the flag is per-image in the registry
    and will slow every later run of that exe name.

.PARAMETER Action
    Enable, Disable, or Status (default Status).

.PARAMETER Image
    Exe file name only (not a path). Default: tests_heaptrc.exe.
    Repeatable via -Image on a single call; also accepts remaining arguments.

.EXAMPLE
    pwsh tools/pageheap.ps1 -Action Enable tests_heaptrc.exe ttplayer_heaptrc.exe
    pwsh tools/pageheap.ps1 -Action Status
    pwsh tools/pageheap.ps1 -Action Disable tests_heaptrc.exe ttplayer_heaptrc.exe
#>
[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Disable', 'Status')]
    [string]$Action = 'Status',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Image = @('tests_heaptrc.exe')
)

$ErrorActionPreference = 'Stop'

function Find-Gflags {
    $candidates = @(
        'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\gflags.exe',
        'C:\Program Files\Windows Kits\10\Debuggers\x64\gflags.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $fromPath = Get-Command gflags.exe -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    throw @"
找不到 gflags.exe。完整 PageHeap 需要经典 Windows 调试工具包（Windows SDK / WDK
Debuggers），不是 Microsoft Store 的 WinDbg。安装后应存在：
  C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\gflags.exe
"@
}

$gflags = Find-Gflags
$images = @($Image | ForEach-Object { Split-Path -Leaf $_ } | Where-Object { $_ })
if ($images.Count -eq 0) { $images = @('tests_heaptrc.exe') }

switch ($Action) {
    'Status' {
        Write-Host "[pageheap] gflags=$gflags" -ForegroundColor Cyan
        & $gflags /p
        if ($LASTEXITCODE -ne 0) { throw "gflags /p failed: $LASTEXITCODE" }
    }
    'Enable' {
        foreach ($img in $images) {
            Write-Host "[pageheap] ENABLE full page heap: $img" -ForegroundColor Yellow
            & $gflags /p /enable $img /full
            if ($LASTEXITCODE -ne 0) { throw "gflags enable failed for $img : $LASTEXITCODE" }
        }
        & $gflags /p
        Write-Host '[pageheap] 用完后务必 Disable，IFEO 项会一直留在注册表里。' -ForegroundColor Yellow
    }
    'Disable' {
        foreach ($img in $images) {
            Write-Host "[pageheap] DISABLE page heap: $img" -ForegroundColor Cyan
            & $gflags /p /disable $img
            if ($LASTEXITCODE -ne 0) { throw "gflags disable failed for $img : $LASTEXITCODE" }
        }
        & $gflags /p
    }
}
