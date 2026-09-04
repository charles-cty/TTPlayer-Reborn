<#
.SYNOPSIS
    用 lazbuild 命令行构建 pascal/ 下的全部 Lazarus 工程（不依赖 IDE 安装包）。

.PARAMETER Project
    只构建指定工程（如 ttdump）；缺省全部构建。

.PARAMETER Config
    Debug / Release / Profile / HeapTrc（默认 Debug）。
    Profile = Release 优化 + DWARF。Debug 与 Profile 在 Windows 上跑 cv2pdb 生成 PDB。

.PARAMETER HeapTrace
    等同于 -Config HeapTrc（保留旧开关）。
    HeapTrc：lazbuild --bm=HeapTrc，-gh + -gl + -dENABLE_HEAPTRC，
    输出到 bin\<proj>_heaptrc.exe。
    Windows 上 C++/CRT 堆（ttcore.dll）另需 tools/pageheap.ps1。
#>
[CmdletBinding()]
param(
    [string]$Project = '',
    [ValidateSet('Debug', 'Release', 'Profile', 'HeapTrc')]
    [string]$Config = 'Debug',
    [switch]$HeapTrace
)

$ErrorActionPreference = 'Stop'

if ($HeapTrace) { $Config = 'HeapTrc' }

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$PascalDir = Join-Path $RepoRoot 'pascal'
$LazBuild  = 'C:\lazarus\lazbuild.exe'
$LazDir    = 'C:\lazarus'

if (-not (Test-Path $LazBuild)) { throw "找不到 lazbuild：$LazBuild" }

. (Join-Path $PSScriptRoot 'Cv2pdb.ps1')

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

    $outDir = Join-Path $PascalDir "lib\$proj"
    if ($Config -eq 'HeapTrc') {
        $outDir = Join-Path $PascalDir "lib\${proj}_heaptrc"
    } else {
        $outDir = Join-Path $PascalDir "lib\$proj\$Config"
    }
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

    Write-Host "[build-pascal] $Config 构建工程：$proj (--bm=$Config)" -ForegroundColor Cyan
    & $LazBuild --lazarusdir=$LazDir --bm=$Config $lpi
    if ($LASTEXITCODE -ne 0) { throw "工程构建失败：$proj" }

    if ($Config -in @('Debug', 'Profile')) {
        $exeName = if ($Config -eq 'HeapTrc') { "${proj}_heaptrc.exe" } else { "$proj.exe" }
        $exe = Join-Path $PascalDir "bin\$exeName"
        Convert-DwarfToPdb -Binary $exe
    }
}

Write-Host "[build-pascal] 全部构建完成 ($Config)" -ForegroundColor Green
if ($Config -eq 'HeapTrc') {
    Write-Host '[build-pascal] HeapTrc 产物：pascal\bin\*_heaptrc.exe ；报告默认写到同名 .heaptrc' -ForegroundColor Yellow
    Write-Host '[build-pascal] Windows C++ 堆请再开：pwsh tools\pageheap.ps1 -Action Enable tests_heaptrc.exe' -ForegroundColor Yellow
}
