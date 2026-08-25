<#
.SYNOPSIS
    用 lazbuild 命令行构建 pascal/ 下的全部 Lazarus 工程（不依赖 IDE 安装包）。

.PARAMETER Project
    只构建指定工程（如 ttdump）；缺省全部构建。

.PARAMETER HeapTrace
    HeapTrc 调试构建（Linux / Windows 相同设施）：lazbuild --bm=HeapTrc，
    为每个工程打开 -gh（Pascal 堆追踪）+ -gl + -dENABLE_HEAPTRC，
    输出到 bin\<proj>_heaptrc.exe，单元输出与 Default 隔离。
    运行时默认把 heaptrc 报告写到同目录 <exe>.heaptrc；可用 HEAPTRACEFILE 覆盖。
    HEAPTRC_KEEP_RELEASED=1 时不复用已释放块，UAF 会变成确定性 Invalid pointer。
    Windows 上 C++/CRT 堆（ttcore.dll）另需 tools/pageheap.ps1（GFlags 完整 PageHeap）。
    注意：-gh 会使程序明显变慢，仅用于调试，不用于发布。
#>
[CmdletBinding()]
param(
    [string]$Project = '',
    [switch]$HeapTrace
)

$ErrorActionPreference = 'Stop'

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$PascalDir = Join-Path $RepoRoot 'pascal'
$LazBuild  = 'C:\lazarus\lazbuild.exe'
$LazDir    = 'C:\lazarus'

if (-not (Test-Path $LazBuild)) { throw "找不到 lazbuild：$LazBuild" }

# vendor 包只需注册一次（lazbuild 会记录到本地包链接），重复执行无害。
$Packages = @(
    (Join-Path $PascalDir 'vendor\bgrabitmap\bgrabitmap\bgrabitmappack4nolcl.lpk'),
    (Join-Path $PascalDir 'vendor\bgrabitmap\bgrabitmap\bgrabitmappack.lpk')
)
foreach ($pkg in $Packages) {
    if (-not (Test-Path $pkg)) { throw "找不到 BGRABitmap 包（submodule 未初始化？）：$pkg" }
    Write-Host "[build-pascal] 注册/编译包：$(Split-Path -Leaf $pkg)" -ForegroundColor Cyan
    & $LazBuild --lazarusdir=$LazDir --add-package-link $pkg | Out-Null
    & $LazBuild --lazarusdir=$LazDir $pkg
    if ($LASTEXITCODE -ne 0) { throw "包构建失败：$pkg" }
}

# 工程列表（按依赖顺序）
$Projects = @('ttdump', 'skinpreview', 'tests', 'ttplayer')
if ($Project) { $Projects = @($Project) }

foreach ($proj in $Projects) {
    $lpi = Join-Path $PascalDir "$proj.lpi"
    if (-not (Test-Path $lpi)) { throw "找不到工程：$lpi" }

    if ($HeapTrace) {
        $outDir = Join-Path $PascalDir "lib\${proj}_heaptrc"
        if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
        Write-Host "[build-pascal] HeapTrc 构建工程：$proj (--bm=HeapTrc)" -ForegroundColor Yellow
        & $LazBuild --lazarusdir=$LazDir --bm=HeapTrc $lpi
    } else {
        Write-Host "[build-pascal] 构建工程：$proj" -ForegroundColor Cyan
        & $LazBuild --lazarusdir=$LazDir $lpi
    }
    if ($LASTEXITCODE -ne 0) { throw "工程构建失败：$proj" }
}

Write-Host '[build-pascal] 全部构建完成' -ForegroundColor Green
if ($HeapTrace) {
    Write-Host '[build-pascal] HeapTrc 产物：pascal\bin\*_heaptrc.exe ；报告默认写到同名 .heaptrc' -ForegroundColor Yellow
    Write-Host '[build-pascal] Windows C++ 堆请再开：pwsh tools\pageheap.ps1 -Action Enable tests_heaptrc.exe' -ForegroundColor Yellow
}
