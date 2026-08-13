<#
.SYNOPSIS
    Layer 1 解析差分测试：Pascal 版 ttdump 输出 vs Qt 版 golden skinjson。

.DESCRIPTION
    对每个皮肤运行 pascal\bin\ttdump.exe，将输出与 tests\golden\skinjson\ 中的
    Qt 基准做结构化 JSON 比较（键序/缩进无关），失败时打印字段级差异路径。
#>
[CmdletBinding()]
param(
    # 只测指定皮肤名（不含扩展名），缺省全部。
    [string]$Skin = ''
)

$ErrorActionPreference = 'Stop'

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$TtDump    = Join-Path $RepoRoot 'pascal\bin\ttdump.exe'
$SkinDir   = Join-Path $RepoRoot 'Skin'
$GoldenDir = Join-Path $RepoRoot 'tests\golden\skinjson'
$OutDir    = Join-Path $RepoRoot 'tests\artifacts\layer1'

if (-not (Test-Path $TtDump)) { throw "找不到 ttdump.exe，请先运行 tools\build-pascal.ps1" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# 递归比较两个 JSON 值，返回差异路径列表。
function Compare-Json($Expected, $Actual, [string]$Path, [ref]$Diffs) {
    if ($null -eq $Expected -and $null -eq $Actual) { return }
    if ($null -eq $Expected -or $null -eq $Actual) {
        $Diffs.Value += "${Path}: 期望 $(ConvertTo-Json $Expected -Compress -Depth 3) 实际 $(ConvertTo-Json $Actual -Compress -Depth 3)"
        return
    }
    if ($Expected -is [System.Management.Automation.PSCustomObject]) {
        if ($Actual -isnot [System.Management.Automation.PSCustomObject]) {
            $Diffs.Value += "${Path}: 类型不一致（期望对象）"
            return
        }
        $ekeys = @($Expected.PSObject.Properties.Name)
        $akeys = @($Actual.PSObject.Properties.Name)
        foreach ($k in ($ekeys + $akeys | Sort-Object -Unique)) {
            if ($k -notin $ekeys) { $Diffs.Value += "${Path}.${k}: 多余字段"; continue }
            if ($k -notin $akeys) { $Diffs.Value += "${Path}.${k}: 缺失字段"; continue }
            Compare-Json $Expected.$k $Actual.$k "${Path}.${k}" $Diffs
        }
        return
    }
    if ($Expected -is [System.Array]) {
        if ($Actual -isnot [System.Array]) {
            $Diffs.Value += "${Path}: 类型不一致（期望数组）"
            return
        }
        if ($Expected.Count -ne $Actual.Count) {
            $Diffs.Value += "${Path}: 数组长度期望 $($Expected.Count) 实际 $($Actual.Count)"
            return
        }
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            Compare-Json $Expected[$i] $Actual[$i] "${Path}[$i]" $Diffs
        }
        return
    }
    if ("$Expected" -cne "$Actual") {
        $Diffs.Value += "${Path}: 期望 '$Expected' 实际 '$Actual'"
    }
}

$goldens = Get-ChildItem -Path $GoldenDir -Filter '*.json' | Sort-Object Name
if ($Skin) { $goldens = $goldens | Where-Object { $_.BaseName -eq $Skin } }
if ($goldens.Count -eq 0) { throw '没有可比对的 golden 文件' }

$passCount = 0
$failList = @()
foreach ($golden in $goldens) {
    $name = $golden.BaseName
    $sknPath = Join-Path $SkinDir "$name.skn"
    if (-not (Test-Path $sknPath)) {
        Write-Host "[layer1] 跳过 $name（找不到 .skn）" -ForegroundColor Yellow
        continue
    }

    $actualPath = Join-Path $OutDir "$name.json"
    & $TtDump $sknPath $actualPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[layer1] FAIL $name（ttdump 退出码 $LASTEXITCODE）" -ForegroundColor Red
        $failList += $name
        continue
    }

    $expected = Get-Content $golden.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $actual   = Get-Content $actualPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $diffs = @()
    Compare-Json $expected $actual '$' ([ref]$diffs)
    if ($diffs.Count -eq 0) {
        Write-Host "[layer1] PASS $name" -ForegroundColor Green
        $passCount++
    } else {
        Write-Host "[layer1] FAIL $name（$($diffs.Count) 处差异）" -ForegroundColor Red
        $diffs | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
        if ($diffs.Count -gt 20) { Write-Host "    ...（其余 $($diffs.Count - 20) 处省略）" -ForegroundColor DarkYellow }
        $failList += $name
    }
}

Write-Host ''
if ($failList.Count -gt 0) {
    Write-Host "[layer1] $passCount 通过，$($failList.Count) 失败：$($failList -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "[layer1] 全部 $passCount 个皮肤通过" -ForegroundColor Green
