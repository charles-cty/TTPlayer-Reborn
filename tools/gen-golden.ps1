<#
.SYNOPSIS
    生成 UI 一致性测试的 golden 基准数据（由 Qt 参照实现产出）。

.DESCRIPTION
    Qt 版是 Lazarus 重写的参照实现。本脚本构建 Qt 版并对仓库中每个皮肤导出：
      - tests/golden/skinjson/<皮肤>.json   皮肤解析结果（Layer 1 差分基准）
    后续 FrameDumper 就绪后还会导出帧快照与文本掩码（Layer 2 基准）。

    迁移期 golden 由 Qt 版生成，测的是"Pascal 版 == Qt 版"；
    迁移完成后可改为固化 Pascal 版输出，转为回归测试。

.PARAMETER SkipBuild
    跳过 Qt 版构建，直接使用已有可执行文件。
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $RepoRoot 'build-mingw64'
$Exe      = Join-Path $BuildDir 'TTPlayerReborn.exe'
$SkinDir  = Join-Path $RepoRoot 'Skin'
$JsonDir  = Join-Path $RepoRoot 'tests\golden\skinjson'
$FrameDir = Join-Path $RepoRoot 'tests\golden\frames'
$MaskDir  = Join-Path $RepoRoot 'tests\golden\masks'

# 运行时依赖（Qt/FFmpeg 等 DLL）来自 MinGW64，无论是否构建都需要在 PATH 中。
. (Join-Path $PSScriptRoot 'WinToolchain.ps1')
if ($env:MSYS2_ROOT -or $env:MINGW64_BIN) {
    Add-Mingw64ToPath
}

# 抑制"找不到 DLL"等系统错误弹窗（SetErrorMode 会被子进程继承），
# 否则批量运行时一旦出错会挂起等待人工点击。
Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetErrorMode(uint uMode);
'@
# SEM_FAILCRITICALERRORS (0x1) | SEM_NOGPFAULTERRORBOX (0x2) | SEM_NOOPENFILEERRORBOX (0x8000)
[Win32.NativeMethods]::SetErrorMode(0x8003) | Out-Null

# 渲染确定性：固定 1x 缩放，避免高 DPI 机器产出不同的 golden。
$env:QT_SCALE_FACTOR = '1'
$env:QT_ENABLE_HIGHDPI_SCALING = '0'
$env:QT_AUTO_SCREEN_SCALE_FACTOR = '0'

if (-not $SkipBuild) {
    Write-Host '[gen-golden] 构建 Qt 参照实现...' -ForegroundColor Cyan
    cmake --build $BuildDir
    if ($LASTEXITCODE -ne 0) { throw "Qt 版构建失败（退出码 $LASTEXITCODE）" }
}

if (-not (Test-Path $Exe)) { throw "找不到可执行文件：$Exe" }
New-Item -ItemType Directory -Force -Path $JsonDir, $FrameDir, $MaskDir | Out-Null

# 皮肤清单：Skin/ 下所有 .skn 归档。
$skins = Get-ChildItem -Path $SkinDir -Filter '*.skn' | Sort-Object Name

$failed = @()
foreach ($skin in $skins) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($skin.Name)
    $out  = Join-Path $JsonDir "$name.json"

    Write-Host "[gen-golden] dump-skin: $name" -ForegroundColor Gray
    # 皮肤加载过程有大量 qWarning 诊断输出，此处丢弃 stderr 只看退出码。
    & $Exe --dump-skin $skin.FullName --out $out 2>$null
    if ($LASTEXITCODE -ne 0) {
        $failed += $name
        Write-Host "  失败（退出码 $LASTEXITCODE）" -ForegroundColor Red
        continue
    }

    Write-Host "[gen-golden] dump-frames: $name" -ForegroundColor Gray
    $skinFrameDir = Join-Path $FrameDir $name
    & $Exe --dump-frames $skin.FullName --outdir $skinFrameDir 2>$null
    if ($LASTEXITCODE -ne 0) {
        $failed += $name
        Write-Host "  失败（退出码 $LASTEXITCODE）" -ForegroundColor Red
        continue
    }
    # masks.json 移到独立目录，帧目录只保留 PNG。
    $maskSrc = Join-Path $skinFrameDir 'masks.json'
    if (Test-Path $maskSrc) {
        Move-Item -Force $maskSrc (Join-Path $MaskDir "$name.json")
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "[gen-golden] $($failed.Count)/$($skins.Count) 个皮肤导出失败：$($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "[gen-golden] 完成：$($skins.Count) 个皮肤的 skinjson/frames/masks 基准已更新" -ForegroundColor Green
