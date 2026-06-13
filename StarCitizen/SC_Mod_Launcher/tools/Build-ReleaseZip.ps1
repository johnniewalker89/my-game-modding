param(
    [string]$Version = '2.0.0'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$DistDir = Join-Path $ProjectDir 'dist'
$ZipPath = Join-Path $DistDir "SC_Mod_Launcher_$Version.zip"
$StageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-mod-launcher-release-" + [guid]::NewGuid().ToString('N'))
$PackageRoot = Join-Path $StageRoot 'SC_Mod_Launcher'

$packageItems = @(
    'SC_Mod_Launcher.ps1',
    'SC_Mod_Launcher.exe',
    'README.md',
    'RELEASES.md',
    'shared',
    'modules',
    'tools\Install-ScModLauncherUpdate.ps1',
    'ui',
    'app'
)

$releaseSeedItems = @(
    'backups\global.ini.20260608-230029.starter-clean.bak',
    'backups\global.ini.20260608-230029.starter-clean.bak.meta.json',
    'modules\scmdb\cache\scmdb-4.8.1-live.11952564.json',
    'modules\scmdb\cache\scmdb-4.8.1-live.11952564.json.meta.json',
    'modules\mining\cache\wiki-blueprints-4.8.1-live.11952564.json',
    'modules\mining\cache\craft-family-index-4.8.1-live.11952564.json',
    'modules\quest\engine\cache\wiki-items-cache.json',
    'modules\quest\engine\cache\wiki-items-cache.json.meta.json'
)

$managedPaths = @('.')
$preservePaths = @(
    'backups',
    'backups/**',
    'config',
    'config/**',
    'updates/backups',
    'updates/backups/**'
)

function Copy-PackageItem {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $source = Join-Path $ProjectDir $RelativePath
    $destination = Join-Path $PackageRoot $RelativePath

    if (-not (Test-Path -LiteralPath $source)) {
        throw "Package item not found: $RelativePath"
    }

    if (Test-Path -LiteralPath $source -PathType Container) {
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        $robocopyArgs = @(
            $source,
            $destination,
            '/MIR',
            '/XD',
            'backups',
            'cache',
            'reports',
            'dist',
            'updates',
            'bin',
            'obj',
            'asset-backups',
            'hologram-work',
            '/XF',
            '*.pdb',
            '/NJH',
            '/NJS',
            '/NP'
        )
        robocopy @robocopyArgs | Out-Host
        if ($LASTEXITCODE -gt 7) {
            throw "robocopy failed while staging $RelativePath with exit code $LASTEXITCODE"
        }
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Copy-ReleaseSeedItem {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $source = Join-Path $ProjectDir $RelativePath
    $destination = Join-Path $PackageRoot $RelativePath

    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Release seed item not found: $RelativePath"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

function ConvertTo-PackageRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside package stage: $fullPath"
    }

    return $fullPath.Substring($root.Length).Replace('\', '/')
}

try {
    & (Join-Path $ScriptDir 'Test-Scaffold.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Build-WpfLauncher.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Test-WpfLauncher.ps1') | Out-Host

    if (Test-Path -LiteralPath $StageRoot) {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null

    foreach ($item in $packageItems) {
        Copy-PackageItem -RelativePath $item
    }

    foreach ($item in $releaseSeedItems) {
        Copy-ReleaseSeedItem -RelativePath $item
    }

    $files = @(
        Get-ChildItem -LiteralPath $PackageRoot -File -Recurse |
            Sort-Object FullName |
            ForEach-Object {
                [pscustomobject]@{
                    path = ConvertTo-PackageRelativePath -Path $_.FullName
                    size = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                }
            }
    )

    $manifest = [ordered]@{
        schemaVersion = 1
        product = 'SC_Mod_Launcher'
        version = $Version
        createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        managedPaths = $managedPaths
        preservePaths = $preservePaths
        files = $files
    }

    $manifestPath = Join-Path $PackageRoot 'update-manifest.json'
    $manifestJson = $manifest | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.UTF8Encoding]::new($false))

    if (-not (Test-Path -LiteralPath $DistDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
    }

    if (Test-Path -LiteralPath $ZipPath -PathType Leaf) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    $stageItems = Get-ChildItem -LiteralPath $StageRoot -Force
    Compress-Archive -LiteralPath $stageItems.FullName -DestinationPath $ZipPath -Force
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash

    & (Join-Path $ScriptDir 'Test-UpdateInstaller.ps1') -PackagePath $ZipPath | Out-Host

    Write-Host "Built: $ZipPath"
    Write-Host "Version: $Version"
    Write-Host "Files: $(@($files).Count)"
    Write-Host "SHA-256: $hash"
}
finally {
    if (Test-Path -LiteralPath $StageRoot) {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force
    }
}
