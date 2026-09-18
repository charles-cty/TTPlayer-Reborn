<#
.SYNOPSIS
    Build the Tracy shim and MCP Python bindings in the canonical Windows Profile directory.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $RepoRoot 'build\windows\tracy\profile'
$python = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $python) { throw '找不到 python.exe，无法构建 TracyServerBindings.pyd' }

# Capstone contains test filenames that exceed Git for Windows' legacy path
# limit when fetched below this build tree. Scope long-path support to this process.
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'core.longpaths'
$env:GIT_CONFIG_VALUE_0 = 'true'

$cmakeArgs = @(
    '-S', $RepoRoot,
    '-B', $BuildDir,
    '-G', 'Visual Studio 17 2022',
    '-A', 'x64',
    '-DBUILD_QT_APP=OFF',
    '-DTTPLAYER_TRACY=ON',
    '-DTTPLAYER_TRACY_ONLY=ON',
    '-DTTPLAYER_TRACY_MCP=ON',
    '-DPYBIND11_FINDPYTHON=ON',
    "-DPython_EXECUTABLE=$($python.Source)"
)

Write-Host "[build-tracy-win] cmake $($cmakeArgs -join ' ')"
& cmake.exe @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed: $LASTEXITCODE" }

foreach ($build in @(
    @{ Directory = $BuildDir; Target = 'tttracy' },
    @{ Directory = (Join-Path $BuildDir 'third_party\tracy\python'); Target = 'TracyServerBindings' }
)) {
    Write-Host "[build-tracy-win] cmake --build $($build.Target) (Profile)"
    & cmake.exe --build $build.Directory --config Profile --target $build.Target
    if ($LASTEXITCODE -ne 0) { throw "cmake build $($build.Target) failed: $LASTEXITCODE" }
}

$dll = Join-Path $BuildDir 'tools\tracyshim\Profile\tttracy.dll'
if (-not (Test-Path -LiteralPath $dll)) { throw "未生成 $dll" }
Write-Host "[build-tracy-win] $dll ($((Get-Item -LiteralPath $dll).Length) bytes)"

$bindingFiles = @(Get-ChildItem -LiteralPath (Join-Path $BuildDir 'python') -Filter 'TracyServerBindings*.pyd' -File)
if ($bindingFiles.Count -ne 1) {
    throw "预期生成一个 TracyServerBindings*.pyd，实际为 $($bindingFiles.Count) 个"
}
$bindings = $bindingFiles[0].FullName

$importCode = 'import sys; sys.path.insert(0, sys.argv[1]); import TracyServerBindings; print(TracyServerBindings.__file__)'
& $python.Source -c $importCode (Split-Path -Parent $bindings)
if ($LASTEXITCODE -ne 0) { throw "TracyServerBindings import failed: $LASTEXITCODE" }
Write-Host "[build-tracy-win] $bindings ($((Get-Item -LiteralPath $bindings).Length) bytes)"
