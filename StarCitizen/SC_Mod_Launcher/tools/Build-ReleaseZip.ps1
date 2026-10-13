param(
    [string]$Version = '2.1.9'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$DistDir = Join-Path $ProjectDir 'dist'
$ZipPath = Join-Path $DistDir "SC_Mod_Launcher_$Version.zip"
$StageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-mod-launcher-release-" + [guid]::NewGuid().ToString('N'))
$PackageRoot = Join-Path $StageRoot 'SC_Mod_Launcher'
$SeedSnapshotRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-mod-launcher-release-seeds-" + [guid]::NewGuid().ToString('N'))

$packageItems = @(
    'SC_Mod_Launcher.ps1',
    'SC_Mod_Launcher.exe',
    'LICENSE',
    'LICENSE-SCOPE.md',
    'BRANDING.md',
    'THIRD_PARTY_NOTICES.md',
    'SOURCE.md',
    'README.md',
    'RELEASES.md',
    'docs',
    'shared',
    'modules',
    'tools\Install-ScModLauncherUpdate.ps1',
    'ui',
    'app'
)

$releaseSeedItems = @(
    'backups\global.ini.20261010-012624.starter-clean.bak',
    'backups\global.ini.20261010-012624.starter-clean.bak.meta.json',
    'modules\scmdb\cache\scmdb-4.10.2-live.12881860.json',
    'modules\scmdb\cache\scmdb-4.10.2-live.12881860.json.meta.json',
    'modules\scmdb\cache\crafting-catalog-4.10.2-live.12881860.json',
    'modules\mining\cache\craft-family-index-4.10.2-live.12881860.json',
    'modules\mining\cache\mining-data-4.10.2-live.12881860.json',
    'modules\mining\cache\refinery-yields-4.10.2-live.12881860.json',
    'modules\mining\cache\raw-ore-buy-prices-4.10.2-live.12881860.json',
    'modules\mining\cache\wiki-item-passports-4.10.2-live.12881860.json'
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

function Save-ReleaseSeedSnapshot {
    foreach ($item in $releaseSeedItems) {
        $source = Join-Path $ProjectDir $item
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Release seed item not found: $item"
        }

        $destination = Join-Path $SeedSnapshotRoot $item
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function Restore-ReleaseSeedSnapshot {
    foreach ($item in $releaseSeedItems) {
        $source = Join-Path $SeedSnapshotRoot $item
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Release seed snapshot missing: $item"
        }

        $destination = Join-Path $ProjectDir $item
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
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

function Assert-ReleasePackageContents {
    $seedPaths = @($releaseSeedItems | ForEach-Object { $_.Replace('\', '/') })
    foreach ($file in @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse)) {
        $relative = ConvertTo-PackageRelativePath -Path $file.FullName
        if ($relative -match '(^|/)(reports|dist|config|updates|src|bin|obj|asset-backups|hologram-work)(/|$)' -or $relative -like '*.pdb') {
            throw "Development or user file entered the release: $relative"
        }
        if ($relative -match '(^|/)(cache|backups)/' -and $relative -notin $seedPaths) {
            throw "Unlisted backup or cache entered the release: $relative"
        }
    }
    $starter = Join-Path $PackageRoot $releaseSeedItems[0]
    $metadata = Get-Content -LiteralPath ($starter + '.meta.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($metadata.kind -ne 'clean' -or $metadata.localization.tagName -ne '4.10.2-v128' -or
        (Get-FileHash -LiteralPath $starter -Algorithm SHA256).Hash -ne $metadata.sha256) {
        throw 'Release starter is not the verified clean RuSC v128 backup.'
    }
}

function Update-ReleaseCacheSeeds {
    $refreshStartedUtc = [DateTime]::UtcNow
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $warmupOutput = @(& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProjectDir 'SC_Mod_Launcher.ps1') -LivePath $ProjectDir -WarmCache 2>&1 | ForEach-Object { [string]$_ })
    $warmupExitCode = $LASTEXITCODE
    $warmupOutput | Out-Host
    if ($warmupExitCode -ne 0 -or @($warmupOutput | Where-Object { $_ -match '(?i)\bFALLBACK\b' }).Count -gt 0) {
        throw 'Release requires a fresh successful cache warmup from every source; fallback caches cannot enter a new release.'
    }
    foreach ($item in @($releaseSeedItems | Where-Object { $_ -like 'modules\*\cache\*' })) {
        $seed = Get-Item -LiteralPath (Join-Path $ProjectDir $item) -ErrorAction Stop
        if ($seed.Length -eq 0 -or $seed.LastWriteTimeUtc -lt $refreshStartedUtc.AddSeconds(-2)) {
            throw "Release cache was not refreshed in this run: $item"
        }
    }
}

try {
    & (Join-Path $ScriptDir 'Test-ReleaseCacheFreshness.ps1') | Out-Host
    Update-ReleaseCacheSeeds
    Save-ReleaseSeedSnapshot
    & (Join-Path $ScriptDir 'Test-GameMenuVersion.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Test-CraftingCatalog.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Test-UnnamedCraftRecipes.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Test-CatalogPresentation.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Test-Scaffold.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Test-Sc4102.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Test-UpdateTransport.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Build-WpfLauncher.ps1') | Out-Host
    & (Join-Path $ScriptDir 'Test-WpfLauncher.ps1') | Out-Host
    Restore-ReleaseSeedSnapshot

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

    Assert-ReleasePackageContents

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
    if (Test-Path -LiteralPath $SeedSnapshotRoot) {
        Remove-Item -LiteralPath $SeedSnapshotRoot -Recurse -Force
    }
}
