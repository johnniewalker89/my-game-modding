param(
    [string]$Version = 'v2.2.2'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModDir = Split-Path -Parent $ScriptDir
$DistDir = Join-Path $ModDir 'dist'
$PackageRoot = Join-Path $DistDir "SCMDB_Quest_Recipe_Patcher_$Version"
$ZipPath = "${PackageRoot}.zip"

if (Test-Path -LiteralPath $PackageRoot) {
    Remove-Item -LiteralPath $PackageRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null

$include = @(
    'README.md',
    'RELEASES.md',
    'SCMDB_Quest_Recipe_Patcher.bat',
    'SCMDB_Quest_Recipe_Patcher.ps1',
    'SCMDB_Quest_Recipe_Launcher.ps1',
    'data',
    'cache'
)

foreach ($item in $include) {
    $source = Join-Path $ModDir $item
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $PackageRoot -Recurse -Force
    }
}

if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}

Compress-Archive -Path (Join-Path $PackageRoot '*') -DestinationPath $ZipPath -Force

Write-Host "Release ZIP: $ZipPath"
