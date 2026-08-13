<#
.SYNOPSIS
    用 lazbuild 命令行构建 pascal/ 下的全部 Lazarus 工程（不依赖 IDE 安装包）。
#>
[CmdletBinding()]
param(
    # 只构建指定工程（如 ttdump）；缺省全部构建。
    [string]$Project = ''
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
$Projects = @('ttdump', 'skinpreview', 'tests')
if ($Project) { $Projects = @($Project) }

foreach ($proj in $Projects) {
    $lpi = Join-Path $PascalDir "$proj.lpi"
    if (-not (Test-Path $lpi)) { throw "找不到工程：$lpi" }
    Write-Host "[build-pascal] 构建工程：$proj" -ForegroundColor Cyan
    & $LazBuild --lazarusdir=$LazDir $lpi
    if ($LASTEXITCODE -ne 0) { throw "工程构建失败：$proj" }
}

Write-Host '[build-pascal] 全部构建完成' -ForegroundColor Green
