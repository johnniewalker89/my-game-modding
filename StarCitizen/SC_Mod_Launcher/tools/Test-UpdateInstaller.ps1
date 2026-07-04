param(
    [Parameter(Mandatory = $true)][string]$PackagePath
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Installer = Join-Path $ScriptDir 'Install-ScModLauncherUpdate.ps1'
$ReleaseCacheBuild = '4.8.3-live.12122953'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
}

$package = [System.IO.Path]::GetFullPath($PackagePath)
Assert-True (Test-Path -LiteralPath $package -PathType Leaf) "Package should exist: $package"

$hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-update-installer-test-" + [guid]::NewGuid().ToString('N'))
$target = Join-Path $tempRoot 'SC_Mod_Launcher'

try {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $seedExtract = Join-Path $tempRoot 'seed-package'
    New-Item -ItemType Directory -Force -Path $seedExtract | Out-Null
    Expand-Archive -LiteralPath $package -DestinationPath $seedExtract -Force
    $seedRoot = if (Test-Path -LiteralPath (Join-Path $seedExtract 'SC_Mod_Launcher\update-manifest.json') -PathType Leaf) {
        Join-Path $seedExtract 'SC_Mod_Launcher'
    }
    else {
        $seedExtract
    }
    Get-ChildItem -LiteralPath $seedRoot -Force | Copy-Item -Destination $target -Recurse -Force

    $directories = @(
        'backups',
        'config',
        'modules\mining\cache',
        'modules\quest\engine\cache',
        'updates\backups\launcher-before-update-old',
        'updates\downloads',
        'dist',
        'src\SCModLauncher\bin',
        'modules\removed_module\cache'
    )
    foreach ($relative in $directories) {
        New-Item -ItemType Directory -Force -Path (Join-Path $target $relative) | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $target 'backups\global.ini.keep.bak') -Value 'backup' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'config\launcher-state.json') -Value '{"width":1190,"height":760,"livePath":"C:\\Games\\StarCitizen\\LIVE"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'modules\mining\cache\wiki.keep.json') -Value 'mining-cache' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'modules\quest\engine\cache\wiki-items-cache.json') -Value 'quest-cache' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'modules\quest\engine\cache\wiki-items-cache.old.json') -Value 'old-quest-cache' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'updates\backups\launcher-before-update-old\keep.txt') -Value 'update-backup' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'updates\downloads\old.zip') -Value 'download' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'dist\old.zip') -Value 'dist' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'src\SCModLauncher\bin\old.dll') -Value 'bin' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'tools\Build-ReleaseZip.ps1') -Value 'dev-build-tool' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'tools\Test-Scaffold.ps1') -Value 'dev-test-tool' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'app\SCModLauncher.pdb') -Value 'debug-symbols' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'SC_Mod_Launcher.bat') -Value 'old launcher bat' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'SC_Mod_Launcher_WPF.bat') -Value 'old launcher' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'modules\removed_module\cache\old.json') -Value 'old-cache' -Encoding UTF8

    & $Installer -PackagePath $package -TargetRoot $target -ExpectedSha256 $hash

    Assert-True (Test-Path -LiteralPath (Join-Path $target 'app\SCModLauncher.exe') -PathType Leaf) 'Updated app should exist.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'SC_Mod_Launcher.exe') -PathType Leaf) 'Root launcher should exist.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'tools\Install-ScModLauncherUpdate.ps1') -PathType Leaf) 'Update helper should exist.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'update-manifest.json') -PathType Leaf) 'Installed manifest should exist.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'backups\global.ini.keep.bak') -PathType Leaf) 'User backups should be preserved.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'config\launcher-state.json') -PathType Leaf) 'Launcher local state should be preserved.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'backups\global.ini.20260618-180558.starter-clean.bak') -PathType Leaf) 'Starter clean backup should be installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'backups\global.ini.20260618-180558.starter-clean.bak.meta.json') -PathType Leaf) 'Starter clean backup metadata should be installed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'modules\mining\cache\wiki.keep.json') -PathType Leaf)) 'Old mining cache should be replaced by release cache.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target "modules\mining\cache\wiki-blueprints-$ReleaseCacheBuild.json") -PathType Leaf) 'Seed mining blueprints cache should be installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target "modules\mining\cache\craft-family-index-$ReleaseCacheBuild.json") -PathType Leaf) 'Seed mining recipe family cache should be installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target "modules\mining\cache\refinery-yields-$ReleaseCacheBuild.json") -PathType Leaf) 'Seed refinery cache should be installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target "modules\mining\cache\erkul-item-passports-$ReleaseCacheBuild.json") -PathType Leaf) 'Seed item passport cache should be installed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'modules\quest\engine\cache\wiki-items-cache.old.json') -PathType Leaf)) 'Old quest cache leftovers should be removed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'modules\quest\engine\cache\wiki-items-cache.json') -PathType Leaf) 'Seed quest items cache should be installed.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $target 'modules\quest\engine\cache\wiki-items-cache.json') -Encoding UTF8 -Raw) -ne 'quest-cache') 'Seed quest items cache should replace old cache content.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'modules\quest\engine\cache\wiki-items-cache.json.meta.json') -PathType Leaf) 'Seed quest items cache metadata should be installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'updates\backups\launcher-before-update-old\keep.txt') -PathType Leaf) 'Update backups should be preserved.'
    Assert-True ((Get-ChildItem -LiteralPath (Join-Path $target 'updates\backups') -Directory | Measure-Object).Count -ge 2) 'Installer should create a before-update backup.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'SC_Mod_Launcher.bat'))) 'Old root launcher bat should be removed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'SC_Mod_Launcher_WPF.bat'))) 'Old launcher bat should be removed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'dist'))) 'Old dist folder should be removed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'src\SCModLauncher\bin'))) 'Old build bin folder should be removed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'updates\downloads'))) 'Downloaded update packages should be cleaned after install.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'modules\removed_module'))) 'Removed module leftovers should be deleted.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'tools\Build-ReleaseZip.ps1'))) 'Dev build tool should not remain in player install.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'tools\Test-Scaffold.ps1'))) 'Dev test tool should not remain in player install.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'app\SCModLauncher.pdb'))) 'Debug symbols should not remain in player install.'

    Write-Host 'SC_Mod_Launcher update installer test passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
