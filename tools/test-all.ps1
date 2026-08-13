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
#>
[CmdletBinding()]
param(
    [switch]$SkipLayer1,
    [switch]$SkipFPCUnit
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
    $testsExe = Join-Path $RepoRoot 'pascal\bin\tests.exe'
    if (-not (Test-Path $testsExe)) {
        throw "找不到 tests.exe，请先运行 tools\build-pascal.ps1"
    }
    & $testsExe -a --format=plain
    if ($LASTEXITCODE -ne 0) { $failed += 'FPCUnit' }
}

# ── 汇总 ─────────────────────────────────────────────────────────────────────
Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "[test-all] 失败：$($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host '[test-all] 全部测试通过' -ForegroundColor Green
