<#
.SYNOPSIS
    串联 Layer 1 / Layer 2+3+4 / gen-golden 的统一测试入口。

.DESCRIPTION
    执行顺序：
      1. Layer 1  — 解析差分（Pascal ttdump vs Qt golden skinjson）
      2. Layer 2+3+4 — FPCUnit（快照测试 + expect 逻辑测试 + metamorphic 测试）

    测试前无需重新构建（调用方若需要可先运行 tools\build-pascal.ps1）。
    任一层失败则整体以非零退出码结束。

.PARAMETER SkipLayer1
    跳过 Layer 1（差分测试）。

.PARAMETER SkipFPCUnit
    跳过 Layer 2/3/4（FPCUnit）。

.PARAMETER HeapTrace
    跑 HeapTrc 构建的 FPCUnit（pascal\bin\tests_heaptrc.exe）。
    先 tools\build-pascal.ps1 -HeapTrace。Windows 与 Linux 都用这一套 Pascal
    堆追踪；Windows 上 C++/CRT 堆另加 tools\pageheap.ps1。
    未设置 HEAPTRC_KEEP_RELEASED 时默认打开，UAF 会变成 Invalid pointer。
#>
[CmdletBinding()]
param(
    [switch]$SkipLayer1,
    [switch]$SkipFPCUnit,
    [switch]$SkipSmoke,    # 跳过 GUI 冒烟测试（无显示环境时使用）
    [switch]$HeapTrace     # 跑 pascal\bin\tests_heaptrc.exe（先 tools\build-pascal.ps1 -HeapTrace）
)

$ErrorActionPreference = 'Stop'

# 抑制系统弹窗（DLL 缺失等）
Add-Type -Namespace Win32 -Name NM -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint m);
'@
[Win32.NM]::SetErrorMode(0x8003) | Out-Null

$env:PATH = 'C:\msys64\mingw64\bin;' + $env:PATH
$RepoRoot = Split-Path -Parent $PSScriptRoot
$failed = @()

# ── Layer 1：解析差分（Pascal ttdump vs Qt golden） ──────────────────────────
if (-not $SkipLayer1) {
    Write-Host ''
    Write-Host '── Layer 1  差分测试（ttdump vs golden skinjson）──' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'test-layer1.ps1')
    if ($LASTEXITCODE -ne 0) { $failed += 'Layer1' }
}

# ── Layer 2 / 3 / 4：FPCUnit（快照 + expect + metamorphic）─────────────────
if (-not $SkipFPCUnit) {
    Write-Host ''
    Write-Host '── Layer 2/3/4  FPCUnit（快照 / expect / metamorphic）──' -ForegroundColor Cyan
    $testsName = if ($HeapTrace) { 'tests_heaptrc.exe' } else { 'tests.exe' }
    $testsExe = Join-Path $RepoRoot "pascal\bin\$testsName"
    if (-not (Test-Path $testsExe)) {
        if ($HeapTrace) {
            throw "找不到 tests_heaptrc.exe，请先运行 tools\build-pascal.ps1 -HeapTrace"
        }
        throw "找不到 tests.exe，请先运行 tools\build-pascal.ps1"
    }
    if ($HeapTrace) {
        $dumpPath = Join-Path $RepoRoot 'pascal\bin\tests_heaptrc.heaptrc'
        if (-not $env:HEAPTRC_KEEP_RELEASED) {
            $env:HEAPTRC_KEEP_RELEASED = '1'
        }
        Write-Host "  HeapTrc：$testsExe" -ForegroundColor Yellow
        Write-Host "  HEAPTRC_KEEP_RELEASED=$($env:HEAPTRC_KEEP_RELEASED)  dump=$dumpPath" -ForegroundColor Yellow
        if (Test-Path $dumpPath) { Remove-Item -LiteralPath $dumpPath -Force }
    }
    & $testsExe -a --format=plain
    if ($LASTEXITCODE -ne 0) { $failed += 'FPCUnit' }
    if ($HeapTrace) {
        $dumpPath = Join-Path $RepoRoot 'pascal\bin\tests_heaptrc.heaptrc'
        if (-not (Test-Path $dumpPath)) {
            Write-Host "  [HeapTrc] 没有 dump：$dumpPath" -ForegroundColor Red
            $failed += 'HeapTrcDump'
        } else {
            $dump = Get-Content -LiteralPath $dumpPath -Raw
            if ($dump -match 'Invalid pointer' -or $dump -match 'Marked memory at') {
                Write-Host "  [HeapTrc] dump 里有 Invalid pointer / Marked memory：$dumpPath" -ForegroundColor Red
                $failed += 'HeapTrcError'
            } elseif ($dump -match '(?m)^(\d+) unfreed memory blocks') {
                $unfreed = [int]$Matches[1]
                if ($unfreed -ne 0) {
                    Write-Host "  [HeapTrc] $unfreed unfreed blocks — $dumpPath" -ForegroundColor Red
                    $failed += 'HeapTrcLeak'
                } else {
                    Write-Host "  [HeapTrc] dump OK，0 unfreed：$dumpPath" -ForegroundColor Green
                }
            } else {
                Write-Host "  [HeapTrc] dump 写成了，但没有 unfreed 行：$dumpPath" -ForegroundColor Yellow
            }
        }
    }
}

# ── Layer 5：GUI 冒烟测试（pywinauto，需要可见桌面会话）────────────────────
if (-not $SkipSmoke) {
    Write-Host ''
    Write-Host '── Layer 5  GUI 冒烟（skinpreview + pywinauto）──' -ForegroundColor Cyan
    $smokeScript = Join-Path $PSScriptRoot 'smoke_skinpreview.py'
    $pyExe = 'C:\Program Files\Python312\python.exe'
    if (-not (Test-Path $pyExe)) {
        Write-Host '  [跳过] 未找到 Python，请安装 python.org Python 3.12+' -ForegroundColor Yellow
    } elseif (-not (Test-Path (Join-Path $RepoRoot 'pascal\bin\skinpreview.exe'))) {
        Write-Host '  [跳过] skinpreview.exe 未构建，请先运行 tools\build-pascal.ps1' -ForegroundColor Yellow
    } else {
        & $pyExe $smokeScript
        if ($LASTEXITCODE -ne 0) { $failed += 'Smoke' }
    }
}

# ── 汇总 ─────────────────────────────────────────────────────────────────────
Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "[test-all] 失败：$($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host '[test-all] 全部测试通过' -ForegroundColor Green
