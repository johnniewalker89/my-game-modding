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
$script:NetworkTimeoutSec = 120
$script:ProbeTimeoutSec = 120
$script:SourceCheckTimeoutSec = 15

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
            if ($module.metadata.itemPassports -and $module.metadata.itemPassports.enabled) {
                $passports = $module.metadata.itemPassports
                $lines += "  Item passports: $($passports.matchedDescriptionKeys) matched descriptions; changed: $($passports.changedItemDescriptions); cache records: $($passports.cacheRecords)"
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

function Test-SCScmdbLiveVersion {
    param($Version)

    return ([string]$Version.version -match '(?i)-live\.' -or [string]$Version.file -match '(?i)-live\.')
}

function Select-SCScmdbLiveVersion {
    param($Versions)

    return @($Versions | Where-Object { Test-SCScmdbLiveVersion -Version $_ }) | Select-Object -First 1
}

function Get-SCLatestScmdbCachePath {
    $cacheDir = Get-SCScmdbCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return $null
    }

    $latest = Get-ChildItem -LiteralPath $cacheDir -Filter 'scmdb-*.json' -File |
        Where-Object { $_.Name -notlike '*.meta.json' -and $_.Name -match '(?i)-live\.' } |
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
        [hashtable]$Headers,
        [int]$TimeoutSec = $script:NetworkTimeoutSec,
        [switch]$Quiet
    )

    try {
        $result = Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec $TimeoutSec
        if (-not $Quiet) {
            Write-Host "Source ${Name}: OK"
        }
        return $result
    }
    catch {
        $primaryError = $_.Exception.Message
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            try {
                $userAgent = if ($Headers -and $Headers.ContainsKey('User-Agent')) {
                    [string]$Headers['User-Agent']
                }
                else {
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36'
                }

                $curlArgs = @(
                    '-L', '--silent', '--show-error', '--fail',
                    '--max-time', ([string]$TimeoutSec),
                    '-A', $userAgent
                )
                if ($Headers) {
                    foreach ($key in @($Headers.Keys)) {
                        if ([string]$key -eq 'User-Agent') {
                            continue
                        }
                        $curlArgs += @('-H', ('{0}: {1}' -f $key, $Headers[$key]))
                    }
                }
                if (-not ($Headers -and $Headers.ContainsKey('Accept'))) {
                    $curlArgs += @('-H', 'Accept: application/json,text/plain,*/*')
                }
                if ($Headers -and $Headers.ContainsKey('Referer')) {
                    $curlArgs += @('-e', ([string]$Headers['Referer']))
                }

                $curlArgs += $Uri
                $json = & curl.exe @curlArgs
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
                    if (-not $Quiet) {
                        Write-Host "Source ${Name}: OK"
                    }
                    return ($json | ConvertFrom-Json)
                }
            }
            catch {
            }
        }

        if (-not $Quiet) {
            Write-Host "Source ${Name}: FAIL; $primaryError"
        }
        return $null
    }
}

function Test-SCRemoteFileAvailable {
    param(
        [string]$Name,
        [string]$Uri,
        [hashtable]$Headers,
        [int]$TimeoutSec = $script:ProbeTimeoutSec
    )

    try {
        [void](Invoke-WebRequest -Uri $Uri -Method Head -Headers $Headers -TimeoutSec $TimeoutSec -UseBasicParsing)
        Write-Host "Source ${Name}: OK"
        return $true
    }
    catch {
        $primaryError = $_.Exception.Message
        try {
            $rangeHeaders = @{}
            foreach ($key in @($Headers.Keys)) {
                $rangeHeaders[$key] = $Headers[$key]
            }
            $rangeHeaders['Range'] = 'bytes=0-0'
            [void](Invoke-WebRequest -Uri $Uri -Method Get -Headers $rangeHeaders -TimeoutSec $TimeoutSec -UseBasicParsing)
            Write-Host "Source ${Name}: OK"
            return $true
        }
        catch {
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                try {
                    $userAgent = if ($Headers -and $Headers.ContainsKey('User-Agent')) {
                        [string]$Headers['User-Agent']
                    }
                    else {
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36'
                    }

                    $curlArgs = @(
                        '-L', '--silent', '--show-error', '--fail',
                        '--max-time', ([string]$TimeoutSec),
                        '-r', '0-0',
                        '-o', 'NUL',
                        '-A', $userAgent
                    )
                    if ($Headers) {
                        foreach ($key in @($Headers.Keys)) {
                            if ([string]$key -eq 'User-Agent') {
                                continue
                            }
                            $curlArgs += @('-H', ('{0}: {1}' -f $key, $Headers[$key]))
                        }
                    }
                    $curlArgs += $Uri

                    & curl.exe @curlArgs | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "Source ${Name}: OK"
                        return $true
                    }
                }
                catch {
                }
            }

            Write-Host "Source ${Name}: FAIL; $primaryError"
            return $false
        }
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
        [pscustomobject]@{ Name = 'mining data'; Path = Get-SCMiningMiningDataCachePath -CacheKey ([string]$scmdbCache.Version) },
        [pscustomobject]@{ Name = 'mining refinery yields'; Path = Get-SCMiningRefineryYieldCachePath -CacheKey ([string]$scmdbCache.Version) },
        [pscustomobject]@{ Name = 'mining raw ore buy prices'; Path = Get-SCMiningLocationTradeCachePath -CacheKey ([string]$scmdbCache.Version) },
        [pscustomobject]@{ Name = 'mining item passports'; Path = Get-SCMiningItemPassportCachePath -CacheKey ([string]$scmdbCache.Version) },
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

function Write-SCFallbackCacheLine {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Reason
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Write-Host "Cache ${Name}: FALLBACK; reason: $Reason; file: $(Get-SCRelativeOrName -Path $Path); path: $Path"
    }
    else {
        Write-Host "Cache ${Name}: FAIL; fallback cache file was not created; reason: $Reason; path: $Path"
    }
}

function Set-SCJsonProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
        return
    }

    Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
}

function Write-SCJsonCacheFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Payload,
        [int]$Depth = 12
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $json = $Payload | ConvertTo-Json -Depth $Depth
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

function Write-SCMiningRefineryYieldFallbackCache {
    param([string]$CacheKey)

    $targetPath = Get-SCMiningRefineryYieldCachePath -CacheKey $CacheKey
    $fallback = Get-SCMiningCachedRefineryYields -CacheKey $CacheKey
    if ($null -eq $fallback) {
        $fallback = Get-SCMiningCachedRefineryYields
    }
    if ($null -eq $fallback) {
        return $null
    }

    $sourceKey = [string]$fallback.cacheKey
    Set-SCJsonProperty -Object $fallback -Name 'fallbackFromCacheKey' -Value $sourceKey
    Set-SCJsonProperty -Object $fallback -Name 'cacheKey' -Value ([string]$CacheKey)
    Set-SCJsonProperty -Object $fallback -Name 'createdAt' -Value ((Get-Date).ToString('o'))
    Write-SCMiningRefineryYieldCache -CachePath $targetPath -Payload $fallback
    return $targetPath
}

function Write-SCMiningLocationTradeFallbackCache {
    param([string]$CacheKey)

    $targetPath = Get-SCMiningLocationTradeCachePath -CacheKey $CacheKey
    $fallback = Get-SCMiningCachedLocationTrade -CacheKey $CacheKey
    if ($null -eq $fallback) {
        $fallback = Get-SCMiningCachedLocationTrade
    }
    if ($null -eq $fallback) {
        return $null
    }

    $sourceKey = [string]$fallback.cacheKey
    Set-SCJsonProperty -Object $fallback -Name 'fallbackFromCacheKey' -Value $sourceKey
    Set-SCJsonProperty -Object $fallback -Name 'cacheKey' -Value ([string]$CacheKey)
    Set-SCJsonProperty -Object $fallback -Name 'createdAt' -Value ((Get-Date).ToString('o'))
    Write-SCMiningLocationTradeCache -CachePath $targetPath -Payload $fallback
    return $targetPath
}

function Write-SCMiningItemPassportFallbackCache {
    param([string]$CacheKey)

    $targetPath = Get-SCMiningItemPassportCachePath -CacheKey $CacheKey
    $fallback = Get-SCMiningCachedItemPassports -CacheKey $CacheKey
    if ($null -eq $fallback) {
        $fallback = Get-SCMiningCachedItemPassports
    }
    if ($null -eq $fallback) {
        return $null
    }

    $sourceKey = [string]$fallback.cacheKey
    Set-SCJsonProperty -Object $fallback -Name 'fallbackFromCacheKey' -Value $sourceKey
    Set-SCJsonProperty -Object $fallback -Name 'cacheKey' -Value ([string]$CacheKey)
    Set-SCJsonProperty -Object $fallback -Name 'createdAt' -Value ((Get-Date).ToString('o'))
    Write-SCJsonCacheFile -Path $targetPath -Payload $fallback -Depth 12
    return $targetPath
}

function Get-SCModuleNamesText {
    return (($script:Modules | ForEach-Object { [string]$_.Manifest.name }) -join '; ')
}

function Write-ConsoleRemoteSourceSummary {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'SC-Mod-Launcher/1.0 preflight' }

    $versions = Get-SCRemoteJson -Name 'SCMDB index' -Uri 'https://scmdb.net/data/game-versions.json' -Headers $headers -TimeoutSec $script:SourceCheckTimeoutSec
    if ($versions -and @($versions).Count -gt 0) {
        $version = Select-SCScmdbLiveVersion -Versions $versions
        if (-not [string]::IsNullOrWhiteSpace([string]$version.file)) {
            [void](Test-SCRemoteFileAvailable -Name 'SCMDB data' -Uri ("https://scmdb.net/data/{0}" -f $version.file) -Headers $headers -TimeoutSec $script:SourceCheckTimeoutSec)
        }
        else {
            Write-Host 'Source SCMDB data: FAIL; SCMDB index did not include LIVE data file.'
        }
    }
    else {
        Write-Host 'Source SCMDB data: FAIL; SCMDB index unavailable.'
    }

    [void](Test-SCWikiBlueprintSource -Headers $headers)
    [void](Test-SCWikiItemsSource -Headers $headers)
    [void](Test-SCRefineryYieldsSource -Headers $headers)
    [void](Test-SCLocationTradeSource -Headers $headers)
    [void](Test-SCErkulItemPassportSource -Headers $headers)
}

function Test-SCWikiBlueprintSource {
    param([hashtable]$Headers)

    $result = Get-SCRemoteJson -Name 'Wiki blueprints' -Uri 'https://api.star-citizen.wiki/api/blueprints?page%5Bsize%5D=1&page%5Bnumber%5D=1' -Headers $Headers -TimeoutSec $script:SourceCheckTimeoutSec
    return ($null -ne $result)
}

function Test-SCWikiItemsSource {
    param([hashtable]$Headers)

    $result = Get-SCRemoteJson -Name 'Wiki items' -Uri 'https://api.star-citizen.wiki/api/items?page%5Bsize%5D=1&page%5Bnumber%5D=1' -Headers $Headers -TimeoutSec $script:SourceCheckTimeoutSec
    return ($null -ne $result)
}

function Test-SCRefineryYieldsSource {
    param([hashtable]$Headers)

    try {
        $result = Get-SCRemoteJson -Name 'UEX refinery yields' -Uri 'https://api.uexcorp.uk/2.0/refineries_yields' -Headers $Headers -TimeoutSec $script:SourceCheckTimeoutSec
        if ($null -eq $result) {
            return $false
        }
        if (@($result.data).Count -eq 0) {
            throw 'empty response'
        }

        return $true
    }
    catch {
        Write-Host "Source UEX refinery yields: FAIL; $($_.Exception.Message)"
        return $false
    }
}

function Test-SCLocationTradeSource {
    param([hashtable]$Headers)

    try {
        $terminals = Get-SCRemoteJson -Name 'UEX terminals' -Uri 'https://api.uexcorp.uk/2.0/terminals' -Headers $Headers -TimeoutSec $script:SourceCheckTimeoutSec -Quiet
        $rawPrices = Get-SCRemoteJson -Name 'UEX raw ore prices' -Uri 'https://api.uexcorp.uk/2.0/commodities_raw_prices_all' -Headers $Headers -TimeoutSec $script:SourceCheckTimeoutSec -Quiet
        if ($null -eq $terminals -or $null -eq $rawPrices) {
            throw 'one of raw ore endpoints is unavailable'
        }
        if (@($terminals.data).Count -eq 0 -or @($rawPrices.data).Count -eq 0) {
            throw 'empty response'
        }

        Write-Host 'Source UEX raw ore buy prices: OK'
        return $true
    }
    catch {
        Write-Host "Source UEX raw ore buy prices: FAIL; $($_.Exception.Message)"
        return $false
    }
}

function Test-SCErkulItemPassportSource {
    param([hashtable]$Headers)

    try {
        $requestHeaders = @{}
        foreach ($key in @($Headers.Keys)) {
            $requestHeaders[$key] = $Headers[$key]
        }
        $requestHeaders['Accept'] = 'application/json,text/plain,*/*'
        $requestHeaders['Origin'] = 'https://www.erkul.games'
        $requestHeaders['Referer'] = 'https://www.erkul.games/'
        $result = Get-SCRemoteJson -Name 'Erkul item passports' -Uri 'https://server.erkul.games/live/weapons' -Headers $requestHeaders -TimeoutSec $script:SourceCheckTimeoutSec
        if ($null -eq $result) {
            return $false
        }
        if (@($result).Count -eq 0) {
            throw 'empty response'
        }

        return $true
    }
    catch {
        Write-Host "Source Erkul item passports: FAIL; $($_.Exception.Message)"
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
            $miningDataPath = Get-SCMiningMiningDataCachePath -CacheKey ([string]$scmdbCache.Version)
            Write-SCCacheStatusLine -Name 'mining data' -Path $miningDataPath
            $refineryYieldPath = Get-SCMiningRefineryYieldCachePath -CacheKey ([string]$scmdbCache.Version)
            Write-SCCacheStatusLine -Name 'mining refinery yields' -Path $refineryYieldPath
            $locationTradePath = Get-SCMiningLocationTradeCachePath -CacheKey ([string]$scmdbCache.Version)
            Write-SCCacheStatusLine -Name 'mining raw ore buy prices' -Path $locationTradePath
            $itemPassportPath = Get-SCMiningItemPassportCachePath -CacheKey ([string]$scmdbCache.Version)
            Write-SCCacheStatusLine -Name 'mining item passports' -Path $itemPassportPath
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

    $version = Select-SCScmdbLiveVersion -Versions $versions
    if ($null -eq $version) {
        throw 'SCMDB version index returned no LIVE version.'
    }

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

    $miningDataUri = "https://scmdb.net/data/mining_data-$($version.version).json"
    $miningData = Get-SCRemoteJson -Name 'SCMDB mining data' -Uri $miningDataUri -Headers $headers
    if ($null -eq $miningData -or $null -eq $miningData.locations -or @($miningData.locations).Count -eq 0) {
        throw 'SCMDB mining data returned no locations.'
    }
    $miningDataPath = Get-SCMiningMiningDataCachePath -CacheKey ([string]$version.version)
    $miningDataDir = Split-Path -Parent $miningDataPath
    if (-not (Test-Path -LiteralPath $miningDataDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $miningDataDir | Out-Null
    }
    $miningDataJson = $miningData | ConvertTo-Json -Depth 80
    [System.IO.File]::WriteAllText($miningDataPath, $miningDataJson, [System.Text.UTF8Encoding]::new($false))
    Write-Host "SCMDB mining locations: $(@($miningData.locations).Count)"
    Write-SCRefreshedCacheLine -Name 'mining data' -Path $miningDataPath

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

    $refineryYieldPath = Get-SCMiningRefineryYieldCachePath -CacheKey ([string]$version.version)
    try {
        $refineryYields = Get-SCMiningRefineryYields -Headers $headers -CacheKey ([string]$version.version) -ForceRefresh
        Write-Host 'Source UEX refinery yields: OK'
        Write-Host "UEX refinery stations: $(@($refineryYields.stations).Count)"
        Write-SCRefreshedCacheLine -Name 'mining refinery yields' -Path $refineryYieldPath
    }
    catch {
        $reason = $_.Exception.Message
        Write-Host "Source UEX refinery yields: FALLBACK; $reason"
        $fallbackPath = Write-SCMiningRefineryYieldFallbackCache -CacheKey ([string]$version.version)
        if ([string]::IsNullOrWhiteSpace($fallbackPath)) {
            throw "UEX refinery yields source is unavailable and no fallback cache exists: $reason"
        }

        Write-SCFallbackCacheLine -Name 'mining refinery yields' -Path $fallbackPath -Reason 'source unavailable'
    }

    $locationTradePath = Get-SCMiningLocationTradeCachePath -CacheKey ([string]$version.version)
    try {
        $locationTrade = Get-SCMiningLocationTradePrices -Headers $headers -CacheKey ([string]$version.version) -ForceRefresh
        Write-Host 'Source UEX raw ore buy prices: OK'
        Write-Host "UEX raw ore buy locations: $(@($locationTrade.locations).Count)"
        Write-SCRefreshedCacheLine -Name 'mining raw ore buy prices' -Path $locationTradePath
    }
    catch {
        $reason = $_.Exception.Message
        Write-Host "Source UEX raw ore buy prices: FALLBACK; $reason"
        $fallbackPath = Write-SCMiningLocationTradeFallbackCache -CacheKey ([string]$version.version)
        if ([string]::IsNullOrWhiteSpace($fallbackPath)) {
            throw "UEX raw ore buy price source is unavailable and no fallback cache exists: $reason"
        }

        Write-SCFallbackCacheLine -Name 'mining raw ore buy prices' -Path $fallbackPath -Reason 'source unavailable'
    }

    $itemPassportPath = Get-SCMiningItemPassportCachePath -CacheKey ([string]$version.version)
    try {
        $itemPassportPath = Write-SCMiningItemPassportCache -CacheKey ([string]$version.version) -Headers $headers
        Write-Host 'Source Erkul item passports: OK'
        $itemPassportCache = Get-Content -LiteralPath $itemPassportPath -Encoding UTF8 -Raw | ConvertFrom-Json
        Write-Host "Erkul item passports: $(@($itemPassportCache.records).Count)"
        Write-SCRefreshedCacheLine -Name 'mining item passports' -Path $itemPassportPath
    }
    catch {
        $reason = $_.Exception.Message
        Write-Host "Source Erkul item passports: FALLBACK; $reason"
        $fallbackPath = Write-SCMiningItemPassportFallbackCache -CacheKey ([string]$version.version)
        if ([string]::IsNullOrWhiteSpace($fallbackPath)) {
            throw "Erkul item passport source is unavailable and no fallback cache exists: $reason"
        }

        Write-SCFallbackCacheLine -Name 'mining item passports' -Path $fallbackPath -Reason 'source unavailable'
    }
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
