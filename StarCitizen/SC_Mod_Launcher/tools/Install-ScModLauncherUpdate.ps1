param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256,
    [string]$RestartExe,
    [int]$LauncherProcessId = 0
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [Parameter(Mandatory = $true)][string]$ParentPath
    )

    $child = Resolve-FullPath -Path $ChildPath
    $parent = (Resolve-FullPath -Path $ParentPath).TrimEnd('\') + '\'
    if (-not $child.StartsWith($parent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe path outside target root: $child"
    }
}

function Normalize-RelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/').Trim()
    if ($normalized -eq '') {
        throw 'Empty relative path is not allowed.'
    }
    if ($normalized -eq './') {
        return '.'
    }
    $normalized = $normalized.Trim('/')
    if ($normalized -eq '') {
        return '.'
    }
    if ([System.IO.Path]::IsPathRooted($normalized)) {
        throw "Rooted path is not allowed in update manifest: $Path"
    }
    $segments = @($normalized -split '/')
    if ($segments | Where-Object { $_ -eq '..' -or $_ -eq '' }) {
        throw "Unsafe relative path in update manifest: $Path"
    }
    return ($segments -join '/')
}

function ConvertTo-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = Resolve-FullPath -Path $Path
    $fullRoot = (Resolve-FullPath -Path $Root).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside root: $fullPath"
    }
    $relative = $fullPath.Substring($fullRoot.Length).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return '.'
    }
    return $relative.Trim('/')
}

function Test-PathMatchesPattern {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $path = Normalize-RelativePath -Path $RelativePath
    $patternValue = Normalize-RelativePath -Path $Pattern
    return $path -like $patternValue
}

function Test-IsPreservedPath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string[]]$PreservePatterns
    )

    foreach ($pattern in $PreservePatterns) {
        if (Test-PathMatchesPattern -RelativePath $RelativePath -Pattern $pattern) {
            return $true
        }
    }
    return $false
}

function Test-DirectoryContainsPreservedPath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string[]]$PreservePatterns
    )

    $directory = Normalize-RelativePath -Path $RelativePath
    if ($directory -eq '.') {
        return $true
    }

    foreach ($pattern in $PreservePatterns) {
        $cleanPattern = Normalize-RelativePath -Path $pattern
        $basePattern = $cleanPattern -replace '/\*\*$', ''
        if ($basePattern.StartsWith($directory + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ($basePattern -like ($directory + '/*')) {
            return $true
        }
    }
    return $false
}

function Copy-DirectoryMirror {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string[]]$PreservePatterns
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Extracted package root not found: $SourceRoot"
    }
    if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
        throw "Target root not found: $TargetRoot"
    }

    $targetFiles = @(Get-ChildItem -LiteralPath $TargetRoot -File -Recurse -Force)
    foreach ($file in $targetFiles) {
        $relative = ConvertTo-RelativePath -Path $file.FullName -Root $TargetRoot
        if (Test-IsPreservedPath -RelativePath $relative -PreservePatterns $PreservePatterns) {
            continue
        }

        $sourceFile = Join-Path $SourceRoot ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }

    $targetDirectories = @(
        Get-ChildItem -LiteralPath $TargetRoot -Directory -Recurse -Force |
            Sort-Object { $_.FullName.Length } -Descending
    )
    foreach ($directory in $targetDirectories) {
        $relative = ConvertTo-RelativePath -Path $directory.FullName -Root $TargetRoot
        if (Test-IsPreservedPath -RelativePath $relative -PreservePatterns $PreservePatterns) {
            continue
        }
        if (Test-DirectoryContainsPreservedPath -RelativePath $relative -PreservePatterns $PreservePatterns) {
            continue
        }

        $sourceDirectory = Join-Path $SourceRoot ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force
        }
    }

    foreach ($directory in @(Get-ChildItem -LiteralPath $SourceRoot -Directory -Recurse -Force)) {
        $relative = ConvertTo-RelativePath -Path $directory.FullName -Root $SourceRoot
        $targetDirectory = Join-Path $TargetRoot ($relative.Replace('/', '\'))
        New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force)) {
        $relative = ConvertTo-RelativePath -Path $file.FullName -Root $SourceRoot
        $targetFile = Join-Path $TargetRoot ($relative.Replace('/', '\'))
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetFile) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $targetFile -Force
    }
}

function Assert-ManifestFileHashes {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ExtractRoot
    )

    $manifestFiles = @($Manifest.files)
    if ($manifestFiles.Count -eq 0) {
        throw 'Update manifest does not contain file hashes.'
    }

    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    [void]$allowed.Add('update-manifest.json')

    foreach ($entry in $manifestFiles) {
        $relative = Normalize-RelativePath -Path ([string]$entry.path)
        [void]$allowed.Add($relative)
        $filePath = Join-Path $ExtractRoot ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Manifest file is missing from package: $relative"
        }
        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
        if (-not $actualHash.Equals([string]$entry.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Package file hash mismatch: $relative"
        }
        if ([long]$entry.size -ne (Get-Item -LiteralPath $filePath).Length) {
            throw "Package file size mismatch: $relative"
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $ExtractRoot -File -Recurse -Force)) {
        $relative = ConvertTo-RelativePath -Path $file.FullName -Root $ExtractRoot
        if (-not $allowed.Contains($relative)) {
            throw "Package contains file not listed in manifest: $relative"
        }
    }
}

$package = Resolve-FullPath -Path $PackagePath
$target = Resolve-FullPath -Path $TargetRoot

if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
    throw "Package not found: $package"
}
if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    throw "Target launcher folder not found: $target"
}

$actualHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
if (-not $actualHash.Equals($ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "SHA-256 mismatch. Expected $ExpectedSha256, got $actualHash"
}

if ($LauncherProcessId -gt 0) {
    try {
        $process = Get-Process -Id $LauncherProcessId -ErrorAction SilentlyContinue
        if ($process) {
            [void]$process.WaitForExit(15000)
        }
    }
    catch {
    }
}

$updatesRoot = Join-Path $target 'updates'
$backupRoot = Join-Path $updatesRoot 'backups'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $backupRoot "launcher-before-update-$stamp"
$extractDir = Join-Path ([System.IO.Path]::GetTempPath()) "sc-mod-launcher-update-extract-$stamp"

Assert-PathInside -ChildPath $backupDir -ParentPath $target
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

if (Test-Path -LiteralPath $extractDir) {
    Remove-Item -LiteralPath $extractDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

try {
    Expand-Archive -LiteralPath $package -DestinationPath $extractDir -Force

    $manifestPath = Join-Path $extractDir 'update-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'Update package does not contain update-manifest.json.'
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1) {
        throw "Unsupported update manifest schema: $($manifest.schemaVersion)"
    }
    if (-not ([string]$manifest.product).Equals('SC_Mod_Launcher', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected update product: $($manifest.product)"
    }

    $managedPaths = @($manifest.managedPaths | ForEach-Object { Normalize-RelativePath -Path ([string]$_) })
    if ($managedPaths.Count -eq 0) {
        throw 'Update manifest has no managed paths.'
    }

    $preservePatterns = @($manifest.preservePaths | ForEach-Object { Normalize-RelativePath -Path ([string]$_) })
    Assert-ManifestFileHashes -Manifest $manifest -ExtractRoot $extractDir

    robocopy $target $backupDir /E /XD backups updates cache /NJH /NJS /NP | Out-Host
    if ($LASTEXITCODE -gt 7) {
        throw "Backup robocopy failed with exit code $LASTEXITCODE"
    }

    if ($managedPaths -contains '.') {
        Copy-DirectoryMirror -SourceRoot $extractDir -TargetRoot $target -PreservePatterns $preservePatterns
    }
    else {
        foreach ($relative in $managedPaths) {
            $source = Join-Path $extractDir ($relative.Replace('/', '\'))
            $destination = Join-Path $target ($relative.Replace('/', '\'))
            Assert-PathInside -ChildPath $destination -ParentPath $target

            if (Test-Path -LiteralPath $source -PathType Container) {
                New-Item -ItemType Directory -Force -Path $destination | Out-Null
                Copy-DirectoryMirror -SourceRoot $source -TargetRoot $destination -PreservePatterns $preservePatterns
            }
            elseif (Test-Path -LiteralPath $source -PathType Leaf) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
            else {
                throw "Managed path is missing from package: $relative"
            }
        }
    }

    $downloadsRoot = Join-Path $updatesRoot 'downloads'
    if (Test-Path -LiteralPath $downloadsRoot -PathType Container) {
        Remove-Item -LiteralPath $downloadsRoot -Recurse -Force
    }
}
finally {
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
}

if (-not [string]::IsNullOrWhiteSpace($RestartExe)) {
    $restartPath = Resolve-FullPath -Path $RestartExe
    if (Test-Path -LiteralPath $restartPath -PathType Leaf) {
        Start-Process -FilePath $restartPath -WorkingDirectory (Split-Path -Parent $restartPath)
    }
}
