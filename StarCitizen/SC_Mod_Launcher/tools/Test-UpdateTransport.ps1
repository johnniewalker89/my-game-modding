$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$TestProject = Join-Path $ProjectDir 'src\SCModLauncher.TransportTests\SCModLauncher.TransportTests.csproj'

dotnet run --project $TestProject -c Release
if ($LASTEXITCODE -ne 0) {
    throw "Update transport tests failed with exit code $LASTEXITCODE"
}
