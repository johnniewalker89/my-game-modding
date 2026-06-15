param(
    [string]$LivePath,
    [string]$SelectedOptionsJson,
    [switch]$Preflight,
    [switch]$CachePreflight,
    [switch]$WarmCache,
    [switch]$DryRun,
    [switch]$StagingApply,
    [switch]$ApplyLive
)

$ErrorActionPreference = 'Stop'

$script:ConsoleUtf8Encoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $script:ConsoleUtf8Encoding
$OutputEncoding = $script:ConsoleUtf8Encoding

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$CoreScript = Join-Path $ScriptRoot 'shared\SC_Localization_Core.ps1'
. $CoreScript

$script:Modules = @(Import-SCModManifests -ModulesRoot (Join-Path $ScriptRoot 'modules'))

function Read-SelectedOptionsJson {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Selected options JSON not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw
    $data = $raw | ConvertFrom-Json
    $selected = @{}

    foreach ($property in @($data.PSObject.Properties)) {
        $selected[$property.Name] = @($property.Value | ForEach-Object { [string]$_ })
    }

    return $selected
}

function Get-OptionNameMap {
    $map = @{}

    foreach ($module in $script:Modules) {
        foreach ($option in @($module.Manifest.options)) {
            $map["$($module.Id)|$($option.id)"] = [string]$option.name
        }
    }

    return $map
}

function Format-SelectedOptionNames {
    param([object]$ModuleReport)

    $optionNameMap = Get-OptionNameMap
    $names = @()
    $craftFamilyCount = 0
    foreach ($optionId in @($ModuleReport.selectedOptions)) {
        if ([string]$optionId -like 'craftFamily|*' -or [string]$optionId -like 'questCraftFamily|*') {
            $craftFamilyCount++
            continue
        }

        $key = "$($ModuleReport.id)|$optionId"
        if ($optionNameMap.ContainsKey($key)) {
            $names += $optionNameMap[$key]
        }
        else {
            $names += [string]$optionId
        }
    }
    if ($craftFamilyCount -gt 0) {
        $familyFilterLabel = -join ([char[]]@(0x0421, 0x0435, 0x043C, 0x0435, 0x0439, 0x0441, 0x0442, 0x0432, 0x0430, 0x0020, 0x0440, 0x0435, 0x0446, 0x0435, 0x043F, 0x0442, 0x043E, 0x0432))
        $names += "${familyFilterLabel}: $craftFamilyCount"
    }

    if ($names.Count -eq 0) {
        return 'none'
    }

    return ($names -join ', ')
}

function Get-ModuleSummaryLines {
    param([object]$Report)

    $lines = @()
    foreach ($module in @($Report.modules)) {
        $optionNames = Format-SelectedOptionNames -ModuleReport $module
        $lines += "Module $($module.name): $optionNames"

        if ($module.id -eq 'mining') {
            $lines += "  Planet descriptions: $($module.metadata.changedPlanetDescriptions) changed of $($module.metadata.planetBlocksFound) with SCMDB hints"
            if ($module.metadata.itemCraftHints -and $module.metadata.itemCraftHints.enabled) {
                $craft = $module.metadata.itemCraftHints
                $lines += "  Item craft hints: $($craft.changedItemDescriptions) changed of $($craft.safeDescriptionKeys) safe; skipped unmapped: $($craft.skippedUnmapped), no wiki: $($craft.skippedNoWiki), conflicts: $($craft.skippedConflict)"
            }
            if ($module.metadata.refineryYieldHints -and $module.metadata.refineryYieldHints.enabled) {
                $refinery = $module.metadata.refineryYieldHints
                $lines += "  Refinery yield hints: $($refinery.changedStationDescriptions) changed of $($refinery.matchedStationDescriptions) matched station descriptions; stations: $($refinery.stationCount)"
            }
        }
        elseif ($module.id -eq 'quest') {
            $lines += "  Quest descriptions: $($module.metadata.changedDescriptionLines) changed; kept blocks: $($module.metadata.keptDescriptionBlocks), filtered blocks: $($module.metadata.filteredDescriptionBlocks)"
            $lines += "  Quest titles: $($module.metadata.changedTitleLines) changed"
            if ($module.metadata.wikeloItemHints -and $module.metadata.wikeloItemHints.enabled) {
                $wikelo = $module.metadata.wikeloItemHints
                $updatedLabel = -join ([char[]]@(0x043F, 0x043E, 0x0434, 0x0441, 0x043A, 0x0430, 0x0437, 0x043A, 0x0438, 0x0020, 0x0430, 0x043A, 0x0442, 0x0443, 0x0430, 0x043B, 0x0438, 0x0437, 0x0438, 0x0440, 0x043E, 0x0432, 0x0430, 0x043D, 0x044B))
                $ofLabel = -join ([char[]]@(0x0438, 0x0437))
                $itemsLabel = -join ([char[]]@(0x043F, 0x0440, 0x0435, 0x0434, 0x043C, 0x0435, 0x0442, 0x043E, 0x0432))
                $resourcesLabel = -join ([char[]]@(0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B))
                $unmappedLabel = -join ([char[]]@(0x0431, 0x0435, 0x0437, 0x0020, 0x0441, 0x0432, 0x044F, 0x0437, 0x0438))
                $lines += "  Wikelo item hints: ${updatedLabel}: $($wikelo.changedItemDescriptions) ${ofLabel} $($wikelo.targetDescriptionKeys) ${itemsLabel}; ${resourcesLabel}: $($wikelo.mappedResources)/$($wikelo.resourceCount), ${unmappedLabel}: $($wikelo.unmappedResources)"
            }
        }
        else {
            $lines += "  Operations: $($module.operationCount)"
        }

        foreach ($warning in @($module.warnings)) {
            $lines += "  Warning: $warning"
        }
    }

    return @($lines)
}

function Write-ConsoleDryRunSummary {
    param([object]$Result)

    $report = $Result.Report
    Write-Host "SC Mod Launcher dry-run"
    Write-Host "LIVE: $($report.livePath)"
    Write-Host "global.ini keys: $($report.keyCount)"
    Write-Host "Modules: $($report.moduleCount)"
    Write-Host "Operations: $($report.operationCount)"
    Write-Host "Changed lines: $($report.changedLines)"
    Write-Host "Fixed EM lines: $($report.fixedMalformedEmphasisLines)"
    Write-Host "Conflicts: $($report.conflictCount)"
    Write-Host "Report: $($Result.ReportPath)"
    foreach ($line in (Get-ModuleSummaryLines -Report $report)) {
        Write-Host $line
    }
}

function Write-ConsoleStagingSummary {
    param([object]$Result)

    $report = $Result.Report
    Write-Host "SC Mod Launcher staging apply"
    Write-Host "Source LIVE: $($Result.SourceLivePath)"
    Write-Host "Staging LIVE: $($Result.StagingLivePath)"
    Write-Host "Staging global.ini: $($Result.StagingGlobalIniPath)"
    Write-Host "Modules: $($report.moduleCount)"
    Write-Host "Operations: $($report.operationCount)"
    Write-Host "Changed lines: $($report.changedLines)"
    Write-Host "Fixed EM lines: $($report.fixedMalformedEmphasisLines)"
    Write-Host "Conflicts: $($report.conflictCount)"
    Write-Host "Write succeeded: $($report.writeSucceeded)"
    Write-Host "Report: $($Result.ReportPath)"
    foreach ($line in (Get-ModuleSummaryLines -Report $report)) {
        Write-Host $line
    }
}

function Write-ConsoleLiveApplySummary {
    param([object]$Result)

    $report = $Result.Report
    Write-Host "SC Mod Launcher LIVE apply"
    Write-Host "LIVE: $($report.livePath)"
    Write-Host "Modules: $($report.moduleCount)"
    Write-Host "Operations: $($report.operationCount)"
    Write-Host "Changed lines: $($report.changedLines)"
    Write-Host "Fixed EM lines: $($report.fixedMalformedEmphasisLines)"
    Write-Host "Conflicts: $($report.conflictCount)"
    Write-Host "Write succeeded: $($report.writeSucceeded)"
    if (-not [string]::IsNullOrWhiteSpace($report.backupPath)) {
        Write-Host "Backup: $($report.backupPath)"
    }
    Write-Host "Report: $($Result.ReportPath)"
    foreach ($line in (Get-ModuleSummaryLines -Report $report)) {
        Write-Host $line
    }
}

function Get-SCRelativeOrName {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    try {
        $root = [System.IO.Path]::GetFullPath($ScriptRoot).TrimEnd('\') + '\'
        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Substring($root.Length)
        }
    }
    catch {
    }

    return (Split-Path -Leaf $Path)
}

function Get-SCScmdbCacheDirectory {
    return (Join-Path $ScriptRoot 'modules\scmdb\cache')
}

function Get-SCSafeCacheKey {
    param([string]$CacheKey)

    return [regex]::Replace([string]$CacheKey, '[^A-Za-z0-9._-]', '_')
}

function Get-SCScmdbCachePath {
    param([string]$Version)

    return (Join-Path (Get-SCScmdbCacheDirectory) ("scmdb-{0}.json" -f (Get-SCSafeCacheKey -CacheKey $Version)))
}

function Get-SCLatestScmdbCachePath {
    $cacheDir = Get-SCScmdbCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return $null
    }

    $latest = Get-ChildItem -LiteralPath $cacheDir -Filter 'scmdb-*.json' -File |
        Where-Object { $_.Name -notlike '*.meta.json' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        return $null
    }

    return [string]$latest.FullName
}

function Read-SCScmdbCache {
    $path = Get-SCLatestScmdbCachePath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $payload = Get-Content -LiteralPath $path -Encoding UTF8 -Raw | ConvertFrom-Json
    return [pscustomobject]@{
        Path = $path
        Version = [string]$payload.version
        File = [string]$payload.file
        CreatedAt = $payload.createdAt
        Data = $payload.data
    }
}

function Write-SCScmdbCache {
    param(
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)]$Data
    )

    if ([string]::IsNullOrWhiteSpace([string]$Version.version) -or [string]::IsNullOrWhiteSpace([string]$Version.file)) {
        throw 'SCMDB version entry is incomplete.'
    }

    $cacheDir = Get-SCScmdbCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    }

    $path = Get-SCScmdbCachePath -Version ([string]$Version.version)
    $payload = [ordered]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToString('o')
        version = [string]$Version.version
        file = [string]$Version.file
        data = $Data
    }
    $json = $payload | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    Write-SCCacheTimestampMetadata -Path $path
    return $path
}

function Format-SCCacheAge {
    param([object]$Timestamp)

    if ($null -eq $Timestamp) {
        return 'unknown'
    }

    $stamp = [datetime]$Timestamp
    $span = (Get-Date) - $stamp
    if ($span.TotalSeconds -lt 0) {
        $span = [timespan]::Zero
    }

    $days = [int][math]::Floor($span.TotalDays)
    $hours = $span.Hours
    $minutes = $span.Minutes

    if ($days -gt 0) {
        return "${days}d ${hours}h"
    }
    if ($hours -gt 0) {
        return "${hours}h ${minutes}m"
    }

    return "${minutes}m"
}

function Get-SCCacheTimestamp {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $metadataPath = "$Path.meta.json"
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadataRaw = Get-Content -LiteralPath $metadataPath -Encoding UTF8 -Raw
            $metadata = $metadataRaw | ConvertFrom-Json
            if ($metadata.PSObject.Properties['createdAt'] -and -not [string]::IsNullOrWhiteSpace([string]$metadata.createdAt)) {
                if ($metadata.createdAt -is [datetime]) {
                    return [datetime]$metadata.createdAt
                }
                return [datetime]::Parse([string]$metadata.createdAt, $null, [Globalization.DateTimeStyles]::RoundtripKind)
            }
        }
        catch {
        }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw
        $json = $raw | ConvertFrom-Json
        if ($json.PSObject.Properties['createdAt'] -and -not [string]::IsNullOrWhiteSpace([string]$json.createdAt)) {
            if ($json.createdAt -is [datetime]) {
                return [datetime]$json.createdAt
            }
            return [datetime]::Parse([string]$json.createdAt, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        }
    }
    catch {
    }

    return (Get-Item -LiteralPath $Path).LastWriteTime
}

function Write-SCCacheTimestampMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [datetime]$CreatedAt = (Get-Date)
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $metadata = [ordered]@{
        schemaVersion = 1
        fileName = Split-Path -Leaf $Path
        createdAt = $CreatedAt.ToString('o')
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    $json = $metadata | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText("$Path.meta.json", $json, [System.Text.UTF8Encoding]::new($false))
}

function Write-SCCacheStatusLine {
    param(
        [string]$Name,
        [string]$Path,
        [int]$StaleDays = 7
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "Cache ${Name}: MISSING"
        return
    }

    $timestamp = Get-SCCacheTimestamp -Path $Path
    $age = Format-SCCacheAge -Timestamp $timestamp
    $isStale = $false
    if ($timestamp) {
        $isStale = ((Get-Date) - $timestamp).TotalDays -ge $StaleDays
    }

    $state = if ($isStale) { 'STALE' } else { 'HIT' }
    Write-Host "Cache ${Name}: $state; age: $age; file: $(Get-SCRelativeOrName -Path $Path); path: $Path"
}

function Get-SCRemoteJson {
    param(
        [string]$Name,
        [string]$Uri,
        [hashtable]$Headers
    )

    try {
        $result = Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 12
        Write-Host "Source ${Name}: OK"
        return $result
    }
    catch {
        if ($Uri -match '^https://scmdb\.net/' -and (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
            try {
                $json = & curl.exe -L --silent --show-error --fail --max-time 30 `
                    -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36' `
                    -H 'Accept: application/json,text/plain,*/*' `
                    -e 'https://scmdb.net/' `
                    $Uri
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
                    Write-Host "Source ${Name}: OK"
                    return ($json | ConvertFrom-Json)
                }
            }
            catch {
            }
        }

        Write-Host "Source ${Name}: FAIL; $($_.Exception.Message)"
        return $null
    }
}

function Get-SCMiningModuleScriptPath {
    $module = @($script:Modules | Where-Object { $_.Id -eq 'mining' } | Select-Object -First 1)
    if ($module.Count -eq 0) {
        throw 'Mining module not found.'
    }

    return [string]$module[0].ScriptPath
}

function Get-SCModuleById {
    param([string]$Id)

    $module = @($script:Modules | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
    if ($module.Count -eq 0) {
        throw "Module not found: $Id"
    }

    return $module[0]
}

function Get-SCQuestCachePaths {
    return @(
        (Join-Path $ScriptRoot 'modules\quest\engine\cache\wiki-items-cache.json')
    )
}

function Assert-SCLocalCachesAvailable {
    $scmdbCache = Read-SCScmdbCache
    if ($null -eq $scmdbCache -or [string]::IsNullOrWhiteSpace([string]$scmdbCache.Version)) {
        throw 'CACHE PREFLIGHT FAILED: SCMDB cache is missing. Refresh cache before applying to LIVE.'
    }

    . (Get-SCMiningModuleScriptPath)
    $required = @(
        [pscustomobject]@{ Name = 'mining blueprints'; Path = Get-SCMiningWikiBlueprintCachePath -CacheKey ([string]$scmdbCache.Version) },
        [pscustomobject]@{ Name = 'mining recipe families'; Path = Get-SCMiningCraftFamilyIndexCachePath -CacheKey ([string]$scmdbCache.Version) },
        [pscustomobject]@{ Name = 'mining refinery yields'; Path = Get-SCMiningRefineryYieldCachePath -CacheKey ([string]$scmdbCache.Version) },
        [pscustomobject]@{ Name = 'quest items'; Path = (Join-Path $ScriptRoot 'modules\quest\engine\cache\wiki-items-cache.json') }
    )

    foreach ($item in $required) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            throw "CACHE PREFLIGHT FAILED: $($item.Name) cache is missing. Refresh cache before applying to LIVE."
        }
    }
}

function Reset-SCCacheFile {
    param([string]$Path)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Write-SCRefreshedCacheLine {
    param(
        [string]$Name,
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Write-Host "Cache ${Name}: REFRESHED; file: $(Get-SCRelativeOrName -Path $Path); path: $Path"
    }
    else {
        Write-Host "Cache ${Name}: FAIL; cache file was not created; path: $Path"
    }
}

function Get-SCModuleNamesText {
    return (($script:Modules | ForEach-Object { [string]$_.Manifest.name }) -join '; ')
}

function Write-ConsoleRemoteSourceSummary {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'SC-Mod-Launcher/1.0 preflight' }

    $versions = Get-SCRemoteJson -Name 'SCMDB index' -Uri 'https://scmdb.net/data/game-versions.json' -Headers $headers
    if ($versions -and @($versions).Count -gt 0) {
        $version = @($versions)[0]
        if (-not [string]::IsNullOrWhiteSpace([string]$version.file)) {
            [void](Get-SCRemoteJson -Name 'SCMDB data' -Uri ("https://scmdb.net/data/{0}" -f $version.file) -Headers $headers)
        }
        else {
            Write-Host 'Source SCMDB data: FAIL; SCMDB index did not include data file.'
        }
    }
    else {
        Write-Host 'Source SCMDB data: FAIL; SCMDB index unavailable.'
    }

    [void](Test-SCWikiBlueprintSource -Headers $headers)
    [void](Test-SCWikiItemsSource -Headers $headers)
    [void](Test-SCRefineryYieldsSource -Headers $headers)
}

function Test-SCWikiBlueprintSource {
    param([hashtable]$Headers)

    try {
        [void](Invoke-RestMethod -Uri 'https://api.star-citizen.wiki/api/blueprints?page%5Bsize%5D=1&page%5Bnumber%5D=1' -Headers $Headers -TimeoutSec 12)
        Write-Host 'Source Wiki blueprints: OK'
        return $true
    }
    catch {
        Write-Host "Source Wiki blueprints: FAIL; $($_.Exception.Message)"
        return $false
    }
}

function Test-SCWikiItemsSource {
    param([hashtable]$Headers)

    try {
        [void](Invoke-RestMethod -Uri 'https://api.star-citizen.wiki/api/items?page%5Bsize%5D=1&page%5Bnumber%5D=1' -Headers $Headers -TimeoutSec 12)
        Write-Host 'Source Wiki items: OK'
        return $true
    }
    catch {
        Write-Host "Source Wiki items: FAIL; $($_.Exception.Message)"
        return $false
    }
}

function Test-SCRefineryYieldsSource {
    param([hashtable]$Headers)

    try {
        $result = Invoke-RestMethod -Uri 'https://api.uexcorp.uk/2.0/refineries_yields' -Headers $Headers -TimeoutSec 12
        if (@($result.data).Count -eq 0) {
            throw 'empty response'
        }

        Write-Host 'Source UEX refinery yields: OK'
        return $true
    }
    catch {
        Write-Host "Source UEX refinery yields: FAIL; $($_.Exception.Message)"
        return $false
    }
}

function Write-ConsolePreflightSummary {
    param(
        [string]$LivePath,
        [switch]$CheckSources
    )

    Write-Host 'SC Mod Launcher preflight'
    Write-Host "LIVE: $LivePath"
    Write-Host "global.ini: $(if (Test-Path -LiteralPath (Get-SCGlobalIniPath -LivePath $LivePath) -PathType Leaf) { 'OK' } else { 'MISSING' })"
    Write-Host "Modules: $($script:Modules.Count)"
    Write-Host "Module names: $(Get-SCModuleNamesText)"

    if ($CheckSources) {
        Write-ConsoleRemoteSourceSummary
    }

    $scmdbCache = Read-SCScmdbCache
    if ($null -eq $scmdbCache) {
        Write-Host 'SCMDB version: MISSING'
        Write-SCCacheStatusLine -Name 'scmdb data' -Path (Join-Path (Get-SCScmdbCacheDirectory) 'scmdb-missing.json')
    }
    else {
        Write-Host "SCMDB version: $($scmdbCache.Version)"
        Write-SCCacheStatusLine -Name 'scmdb data' -Path $scmdbCache.Path
    }

    try {
        . (Get-SCMiningModuleScriptPath)
        if ($scmdbCache -and -not [string]::IsNullOrWhiteSpace([string]$scmdbCache.Version)) {
            $miningCachePath = Get-SCMiningWikiBlueprintCachePath -CacheKey ([string]$scmdbCache.Version)
            Write-SCCacheStatusLine -Name 'mining blueprints' -Path $miningCachePath
            $familyIndexPath = Get-SCMiningCraftFamilyIndexCachePath -CacheKey ([string]$scmdbCache.Version)
            Write-SCCacheStatusLine -Name 'mining recipe families' -Path $familyIndexPath
            $refineryYieldPath = Get-SCMiningRefineryYieldCachePath -CacheKey ([string]$scmdbCache.Version)
            Write-SCCacheStatusLine -Name 'mining refinery yields' -Path $refineryYieldPath
        }
    }
    catch {
        Write-Host "Cache mining module: FAIL; $($_.Exception.Message)"
    }

    Write-SCCacheStatusLine -Name 'quest items' -Path (Join-Path $ScriptRoot 'modules\quest\engine\cache\wiki-items-cache.json')
    Write-Host 'Advice: refresh cache when important cache is MISSING or older than 7 days.'
}

function Write-ConsoleWarmCacheSummary {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'SC-Mod-Launcher/1.0 cache-warmup' }
    Write-Host 'SC Mod Launcher cache warmup'

    $versions = Get-SCRemoteJson -Name 'SCMDB index' -Uri 'https://scmdb.net/data/game-versions.json' -Headers $headers
    if (-not $versions -or @($versions).Count -eq 0) {
        throw 'SCMDB version index returned no data.'
    }

    $version = @($versions)[0]
    Write-Host "SCMDB version: $($version.version)"
    $scmdbData = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$version.file)) {
        $scmdbData = Get-SCRemoteJson -Name 'SCMDB data' -Uri ("https://scmdb.net/data/{0}" -f $version.file) -Headers $headers
    }
    if ($null -eq $scmdbData) {
        throw 'SCMDB data returned no data.'
    }
    $scmdbCachePath = Write-SCScmdbCache -Version $version -Data $scmdbData
    Write-SCRefreshedCacheLine -Name 'scmdb data' -Path $scmdbCachePath

    . (Get-SCMiningModuleScriptPath)
    if (-not (Test-SCWikiBlueprintSource -Headers $headers)) {
        throw 'Wiki blueprints source is unavailable.'
    }

    $blueprints = @(Get-SCMiningWikiBlueprints -Headers $headers -CacheKey ([string]$version.version) -ForceRefresh)
    $cachePath = Get-SCMiningWikiBlueprintCachePath -CacheKey ([string]$version.version)
    Write-Host "Wiki blueprints: $($blueprints.Count)"
    Write-SCRefreshedCacheLine -Name 'mining blueprints' -Path $cachePath

    foreach ($questCachePath in Get-SCQuestCachePaths) {
        Reset-SCCacheFile -Path $questCachePath
    }

    if (-not (Test-SCWikiItemsSource -Headers $headers)) {
        throw 'Wiki items source is unavailable.'
    }

    $questItemsCachePath = Join-Path $ScriptRoot 'modules\quest\engine\cache\wiki-items-cache.json'
    $questEngineScript = Join-Path $ScriptRoot 'modules\quest\engine\SC_Quest_Recipe_Engine.ps1'
    $questReportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-quest-cache-warmup-" + [guid]::NewGuid().ToString('N') + ".json")
    $questEngineArgs = @{
        GlobalIniPath = Resolve-SCGlobalIniPath -LivePath $LivePath
        NoBackup = $true
        NoCraftIntel = $true
        CacheOnly = $true
        ReportPath = $questReportPath
        OverridesPath = Join-Path $ScriptRoot 'modules\quest\engine\data\blueprint-overrides.ru.json'
        WikiCachePath = $questItemsCachePath
    }
    & $questEngineScript @questEngineArgs | ForEach-Object { Write-Host ([string]$_) }
    Write-SCCacheTimestampMetadata -Path $questItemsCachePath
    Write-SCRefreshedCacheLine -Name 'quest items' -Path $questItemsCachePath

    $familyIndexPath = Write-SCMiningCraftFamilyIndexCache -CacheKey ([string]$version.version) -Blueprints @($blueprints)
    Write-SCRefreshedCacheLine -Name 'mining recipe families' -Path $familyIndexPath

    if (-not (Test-SCRefineryYieldsSource -Headers $headers)) {
        throw 'UEX refinery yields source is unavailable.'
    }

    $refineryYields = Get-SCMiningRefineryYields -Headers $headers -CacheKey ([string]$version.version) -ForceRefresh
    $refineryYieldPath = Get-SCMiningRefineryYieldCachePath -CacheKey ([string]$version.version)
    Write-Host "UEX refinery stations: $(@($refineryYields.stations).Count)"
    Write-SCRefreshedCacheLine -Name 'mining refinery yields' -Path $refineryYieldPath
}

function Write-ConsoleUsage {
    Write-Host 'SC Mod Launcher backend/CLI'
    Write-Host ''
    Write-Host 'Main user launcher:'
    Write-Host '  SC_Mod_Launcher.exe'
    Write-Host ''
    Write-Host 'CLI modes:'
    Write-Host '  .\SC_Mod_Launcher.ps1 -LivePath "C:\Games\StarCitizen\LIVE" -Preflight'
    Write-Host '  .\SC_Mod_Launcher.ps1 -LivePath "C:\Games\StarCitizen\LIVE" -CachePreflight'
    Write-Host '  .\SC_Mod_Launcher.ps1 -LivePath "C:\Games\StarCitizen\LIVE" -WarmCache'
    Write-Host '  .\SC_Mod_Launcher.ps1 -LivePath "C:\Games\StarCitizen\LIVE" -DryRun'
    Write-Host '  .\SC_Mod_Launcher.ps1 -LivePath "C:\Games\StarCitizen\LIVE" -ApplyLive'
}

if ([string]::IsNullOrWhiteSpace($LivePath)) {
    $LivePath = Find-SCDefaultLivePath
}

if ($Preflight) {
    Write-ConsolePreflightSummary -LivePath $LivePath -CheckSources
    exit 0
}

if ($CachePreflight) {
    Write-ConsolePreflightSummary -LivePath $LivePath
    exit 0
}

if ($WarmCache) {
    Write-ConsoleWarmCacheSummary
    exit 0
}

if ($DryRun) {
    $selected = Read-SelectedOptionsJson -Path $SelectedOptionsJson
    Assert-SCLocalCachesAvailable
    $result = Invoke-SCModDryRun -LivePath $LivePath -ScriptRoot $ScriptRoot -SelectedOptionsByModule $selected
    Write-ConsoleDryRunSummary -Result $result
    exit 0
}

if ($StagingApply) {
    $selected = Read-SelectedOptionsJson -Path $SelectedOptionsJson
    Assert-SCLocalCachesAvailable
    $result = Invoke-SCModStagingApply -LivePath $LivePath -ScriptRoot $ScriptRoot -SelectedOptionsByModule $selected
    Write-ConsoleStagingSummary -Result $result
    exit 0
}

if ($ApplyLive) {
    $selected = Read-SelectedOptionsJson -Path $SelectedOptionsJson
    Write-Host 'Progress: apply cache'
    Assert-SCLocalCachesAvailable
    Write-Host 'Progress: apply plan'
    $result = Invoke-SCModPatch -LivePath $LivePath -ScriptRoot $ScriptRoot -SelectedOptionsByModule $selected
    Write-ConsoleLiveApplySummary -Result $result
    exit 0
}

Write-ConsoleUsage
exit 1
