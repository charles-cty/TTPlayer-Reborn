<#
.SYNOPSIS
    Locate or fetch cv2pdb64.exe, and convert MinGW/FPC DWARF in a PE to a PDB.

.DESCRIPTION
    GitHub rainers/cv2pdb v0.54. Used on Windows Debug and Profile binaries.
    Needs Visual Studio mspdb140.dll (vswhere locates VS 2022).
#>
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:Cv2pdbVersion = '0.54'
$script:Cv2pdbUrl = 'https://github.com/rainers/cv2pdb/releases/download/v0.54/cv2pdb-0.54.zip'
$script:Cv2pdbSha256 = 'b2fc075b0b57fbf6d989bf380d91ba443bec0110b6a3e5a8d4b95a078903e02c'

function Get-Cv2pdbCacheDir {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Join-Path $repoRoot 'tools\.cache\cv2pdb'
}

function Get-Cv2pdbPath {
    if ($env:CV2PDB -and (Test-Path -LiteralPath $env:CV2PDB)) {
        return $env:CV2PDB
    }
    $named = Get-Command cv2pdb64.exe -ErrorAction SilentlyContinue
    if ($named) { return $named.Source }
    $named = Get-Command cv2pdb.exe -ErrorAction SilentlyContinue
    if ($named) { return $named.Source }
    $cache = Join-Path (Get-Cv2pdbCacheDir) 'cv2pdb64.exe'
    if (Test-Path -LiteralPath $cache) { return $cache }
    return $null
}

function Install-Cv2pdb {
    $destDir = Get-Cv2pdbCacheDir
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $zip = Join-Path $env:TEMP "cv2pdb-$($script:Cv2pdbVersion).zip"
    Write-Host "[cv2pdb] downloading $($script:Cv2pdbUrl)"
    Invoke-WebRequest -Uri $script:Cv2pdbUrl -OutFile $zip -UseBasicParsing
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $script:Cv2pdbSha256) {
        throw "cv2pdb zip hash mismatch: $hash (want $($script:Cv2pdbSha256))"
    }
    $extract = Join-Path $env:TEMP "cv2pdb-$($script:Cv2pdbVersion)-extract"
    if (Test-Path -LiteralPath $extract) {
        Remove-Item -LiteralPath $extract -Recurse -Force
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract
    $found = Get-ChildItem -LiteralPath $extract -Recurse -Filter 'cv2pdb64.exe' |
        Select-Object -First 1
    if (-not $found) {
        throw "cv2pdb zip did not contain cv2pdb64.exe"
    }
    Copy-Item -LiteralPath $found.FullName -Destination (Join-Path $destDir 'cv2pdb64.exe') -Force
    $exe32 = Get-ChildItem -LiteralPath $extract -Recurse -Filter 'cv2pdb.exe' | Select-Object -First 1
    if ($exe32) {
        Copy-Item -LiteralPath $exe32.FullName -Destination (Join-Path $destDir 'cv2pdb.exe') -Force
    }
    Write-Host "[cv2pdb] installed $(Join-Path $destDir 'cv2pdb64.exe')"
    Join-Path $destDir 'cv2pdb64.exe'
}

function Get-Cv2pdbExecutable {
    $path = Get-Cv2pdbPath
    if (-not $path) {
        $path = Install-Cv2pdb
    }
    if (-not (Test-Path -LiteralPath $path)) {
        throw "cv2pdb not found: $path"
    }
    $path
}

function Convert-DwarfToPdb {
    param(
        [Parameter(Mandatory)][string]$Binary,
        [switch]$Cpp
    )
    if (-not (Test-Path -LiteralPath $Binary)) {
        throw "Convert-DwarfToPdb: missing $Binary"
    }
    $cv = Get-Cv2pdbExecutable
    $dir = Split-Path -Parent $Binary
    $base = [IO.Path]::GetFileNameWithoutExtension($Binary)
    $pdb = Join-Path $dir "$base.pdb"
    # cv2pdb 0.54: <exe> [new-exe] [pdb]. -p is embedded-pdb, not output path.
    $argv = @('-n', $Binary, $Binary, $pdb)
    if ($Cpp) { $argv = @('-C') + $argv }
    Write-Host "[cv2pdb] $cv $($argv -join ' ')"
    $savedPath = $env:PATH
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $vs = & $vswhere -latest -products * -property installationPath
        if ($vs) {
            $ide = Join-Path $vs 'Common7\IDE'
            if (Test-Path -LiteralPath $ide) {
                $env:PATH = "$ide;$savedPath"
            }
        }
    }
    try {
        Push-Location -LiteralPath $dir
        & $cv @argv
        if ($LASTEXITCODE -ne 0) {
            throw "cv2pdb failed ($LASTEXITCODE) for $Binary"
        }
    } finally {
        Pop-Location
        $env:PATH = $savedPath
    }
    if (-not (Test-Path -LiteralPath $pdb)) {
        throw "cv2pdb produced no PDB: $pdb"
    }
    Write-Host "[cv2pdb] $pdb ($((Get-Item -LiteralPath $pdb).Length) bytes)"
}
