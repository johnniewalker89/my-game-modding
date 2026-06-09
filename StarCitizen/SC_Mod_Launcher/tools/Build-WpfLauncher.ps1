param(
    [string]$Configuration = 'Release',
    [switch]$RunSmokeTest
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$WpfProject = Join-Path $ProjectDir 'src\SCModLauncher\SCModLauncher.csproj'
$RootLauncherProject = Join-Path $ProjectDir 'src\SCModLauncherRoot\SCModLauncherRoot.csproj'
$OutputDir = Join-Path $ProjectDir 'app'
$RootLauncherOutputDir = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-mod-launcher-root-" + [guid]::NewGuid().ToString('N'))
$RootLauncherExe = Join-Path $ProjectDir 'SC_Mod_Launcher.exe'

if (-not (Test-Path -LiteralPath $WpfProject -PathType Leaf)) {
    throw "WPF project not found: $WpfProject"
}

if (-not (Test-Path -LiteralPath $RootLauncherProject -PathType Leaf)) {
    throw "Root launcher project not found: $RootLauncherProject"
}

if (Test-Path -LiteralPath $OutputDir -PathType Container) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}

dotnet publish $WpfProject -c $Configuration -o $OutputDir --self-contained false
if ($LASTEXITCODE -ne 0) {
    throw "WPF launcher publish failed with exit code $LASTEXITCODE"
}

$exePath = Join-Path $OutputDir 'SCModLauncher.exe'
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "Published launcher not found: $exePath"
}

Write-Host "Published WPF launcher: $exePath"

try {
    dotnet publish $RootLauncherProject -c $Configuration -o $RootLauncherOutputDir --self-contained false /p:PublishSingleFile=true /p:DebugType=none /p:DebugSymbols=false
    if ($LASTEXITCODE -ne 0) {
        throw "Root launcher publish failed with exit code $LASTEXITCODE"
    }

    $publishedRootLauncher = Join-Path $RootLauncherOutputDir 'SC_Mod_Launcher.exe'
    if (-not (Test-Path -LiteralPath $publishedRootLauncher -PathType Leaf)) {
        throw "Published root launcher not found: $publishedRootLauncher"
    }

    Copy-Item -LiteralPath $publishedRootLauncher -Destination $RootLauncherExe -Force
    Write-Host "Published root launcher: $RootLauncherExe"
}
finally {
    if (Test-Path -LiteralPath $RootLauncherOutputDir) {
        Remove-Item -LiteralPath $RootLauncherOutputDir -Recurse -Force
    }
}

if ($RunSmokeTest) {
    & (Join-Path $ScriptDir 'Test-WpfLauncher.ps1') -AppPath $exePath
}
