<#
.SYNOPSIS
    用 lazbuild 命令行构建 pascal/ 下的全部 Lazarus 工程（不依赖 IDE 安装包）。
    路径来自环境变量或 PATH，不写死安装目录：

      LAZARUS_DIR  Lazarus 根目录（含 lazbuild.exe）
      LAZBUILD     可选，lazbuild.exe 的完整路径

.PARAMETER Project
    只构建指定工程（如 ttdump）；缺省全部构建。

.PARAMETER Config
    Debug / Release / Profile / HeapTrc（默认 Debug）。
    Profile = Release 优化 + DWARF。Debug 与 Profile 在 Windows 上跑 cv2pdb 生成 PDB。
    Profile 还会构建 Tracy shim，并把 DLL 与 PDB 部署到产物目录。
    tests 和 ttplayer 会自动增量构建 ttcore，并部署 ttcore.dll 与 SDL2.dll。
    HeapTrc 使用 Debug ttcore 并部署到 HeapTrc 产物目录。

.PARAMETER HeapTrace
    等同于 -Config HeapTrc（保留旧开关）。
    HeapTrc：lazbuild --bm=HeapTrc，-gh + -gl + -dENABLE_HEAPTRC，
    输出到 build\windows\pascal\heaptrc\<proj>_heaptrc.exe。
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
$PascalBuildRoot = Join-Path $RepoRoot 'build\windows\pascal'
. (Join-Path $PSScriptRoot 'WinToolchain.ps1')
. (Join-Path $PSScriptRoot 'Cv2pdb.ps1')

$LazBuild = Get-LazbuildPath
$LazDir   = Get-LazarusDir
Write-Host "[build-pascal] lazbuild=$LazBuild  lazarusdir=$LazDir"

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
$needsTtcore = @($Projects | Where-Object { $_ -in @('tests', 'ttplayer') }).Count -gt 0
$configDir = $Config.ToLowerInvariant()
$runtimeDir = Join-Path $PascalBuildRoot $configDir
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

foreach ($proj in $Projects) {
    $lpi = Join-Path $PascalDir "$proj.lpi"
    if (-not (Test-Path $lpi)) { throw "找不到工程：$lpi" }

    $outDir = Join-Path $PascalBuildRoot "obj\$proj\$configDir\x86_64-win64"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    Write-Host "[build-pascal] $Config 构建工程：$proj (--bm=$Config)" -ForegroundColor Cyan
    $lazArgs = @(
        "--lazarusdir=$LazDir",
        "--bm=$Config",
        "--opt=-FE$runtimeDir",
        "--opt=-FU$outDir",
        $lpi
    )
    & $LazBuild @lazArgs
    if ($LASTEXITCODE -ne 0) { throw "工程构建失败：$proj" }

    if ($Config -in @('Debug', 'Profile')) {
        $exeName = if ($Config -eq 'HeapTrc') { "${proj}_heaptrc.exe" } else { "$proj.exe" }
        $exe = Join-Path $runtimeDir $exeName
        Convert-DwarfToPdb -Binary $exe
    }
}

if ($needsTtcore) {
    $ttcoreConfig = if ($Config -eq 'HeapTrc') { 'Debug' } else { $Config }
    Write-Host "[build-pascal] 增量构建并部署 ttcore ($ttcoreConfig -> $Config)" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'build-ttcore-win.ps1') -Config $ttcoreConfig -DeployConfig $Config
    if ($LASTEXITCODE -ne 0) { throw "ttcore 构建失败：$LASTEXITCODE" }
}

if ($Config -eq 'Profile') {
    $tracyBuildDir = Join-Path $RepoRoot 'build\windows\tracy\profile'
    $tracyDllCandidates = @(
        (Join-Path $tracyBuildDir 'tools\tracyshim\Profile\tttracy.dll'),
        (Join-Path $tracyBuildDir 'tools\tracyshim\tttracy.dll')
    )
    $tracyDll = $tracyDllCandidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    $tracyBindings = @(
        Get-ChildItem -LiteralPath (Join-Path $tracyBuildDir 'python') -Filter 'TracyServerBindings*.pyd' -File -ErrorAction SilentlyContinue
    )

    if ((-not $tracyDll) -or $tracyBindings.Count -ne 1) {
        & (Join-Path $PSScriptRoot 'build-tracy-win.ps1')
        if ($LASTEXITCODE -ne 0) { throw "Tracy 构建失败：$LASTEXITCODE" }
        $tracyDll = $tracyDllCandidates |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        $tracyBindings = @(
            Get-ChildItem -LiteralPath (Join-Path $tracyBuildDir 'python') -Filter 'TracyServerBindings*.pyd' -File -ErrorAction SilentlyContinue
        )
    }
    if (-not $tracyDll) {
        throw "Profile 需要 Tracy DLL，但构建后仍未在 $tracyBuildDir 中找到。"
    }
    if ($tracyBindings.Count -ne 1) {
        throw "Profile 需要一个 TracyServerBindings*.pyd，构建后实际找到 $($tracyBindings.Count) 个。"
    }

    Copy-Item -LiteralPath $tracyDll -Destination $runtimeDir -Force
    Write-Host "[build-pascal] Tracy DLL 已部署到 $runtimeDir" -ForegroundColor Cyan

    $tracyPdb = Join-Path (Split-Path -Parent $tracyDll) 'tttracy.pdb'
    if (Test-Path -LiteralPath $tracyPdb) {
        Copy-Item -LiteralPath $tracyPdb -Destination $runtimeDir -Force
    }
}

Write-Host "[build-pascal] 全部构建完成 ($Config)" -ForegroundColor Green
if ($Config -eq 'HeapTrc') {
    Write-Host '[build-pascal] HeapTrc 产物：build\windows\pascal\heaptrc\*_heaptrc.exe ；报告默认写到同名 .heaptrc' -ForegroundColor Yellow
    Write-Host '[build-pascal] Windows C++ 堆请再开：pwsh tools\pageheap.ps1 -Action Enable build\windows\pascal\heaptrc\tests_heaptrc.exe' -ForegroundColor Yellow
}
