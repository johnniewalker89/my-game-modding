param(
    [string]$Version = 'v0.1.0'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModDir = Split-Path -Parent $ScriptDir
$DistDir = Join-Path $ModDir 'dist'
$PackageRoot = Join-Path $DistDir "SC_Route_Helper_$Version"
$ZipPath = "${PackageRoot}.zip"

if (Test-Path -LiteralPath $PackageRoot) {
    Remove-Item -LiteralPath $PackageRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null

$include = @(
    'README.md',
    'RELEASES.md',
    'SC_Route_Helper.bat',
    'SC_Route_Helper.ps1',
    'SC_Route_Helper_Launcher.ps1'
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
