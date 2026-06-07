param(
    [string]$Configuration = 'Release',
    [switch]$RunSmokeTest
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$WpfProject = Join-Path $ProjectDir 'src\SCModLauncher\SCModLauncher.csproj'
$OutputDir = Join-Path $ProjectDir 'app'

if (-not (Test-Path -LiteralPath $WpfProject -PathType Leaf)) {
    throw "WPF project not found: $WpfProject"
}

if (Test-Path -LiteralPath $OutputDir -PathType Container) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}

dotnet publish $WpfProject -c $Configuration -o $OutputDir --self-contained false

$exePath = Join-Path $OutputDir 'SCModLauncher.exe'
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "Published launcher not found: $exePath"
}

Write-Host "Published WPF launcher: $exePath"

if ($RunSmokeTest) {
    & (Join-Path $ScriptDir 'Test-WpfLauncher.ps1') -AppPath $exePath
}
