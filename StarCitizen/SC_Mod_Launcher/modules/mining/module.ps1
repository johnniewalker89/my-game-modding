. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scmdb\SC_Crafting_Catalog.ps1')

function Get-SCMiningPatchPlan {
    param(
        [object]$Context,
        [string[]]$SelectedOptions
    )

    $selectedMethods = Get-SCMiningSelectedMethods -SelectedOptions $SelectedOptions
    $enableItemCraftHints = $true
    $enableRefineryYieldHints = @($SelectedOptions) -contains 'refineryYieldHints'
    $enableLocationTradeHints = @($SelectedOptions) -contains 'rawOreBuyHints'
    $enableStripLoreDescriptions = @($SelectedOptions) -contains 'stripLoreDescriptions'
    $craftFilter = Get-SCMiningCraftFilter -SelectedOptions $SelectedOptions
    $operations = @()
    $changedPlanetKeys = @()
    $itemCraftWarnings = @()
    $refineryYieldWarnings = @()
    $locationTradeWarnings = @()
    $itemPassportWarnings = @()
    $itemCraftMetadata = @{
        enabled = $enableItemCraftHints
        safeDescriptionKeys = 0
        changedItemDescriptions = 0
        skippedUnmapped = 0
        skippedNoWiki = 0
        skippedConflict = 0
    }
    $refineryYieldMetadata = @{
        enabled = $enableRefineryYieldHints
        source = 'UEX refineries_yields'
        stationCount = 0
        matchedStationDescriptions = 0
        changedStationDescriptions = 0
    }
    $locationTradeMetadata = @{
        enabled = $enableLocationTradeHints
        source = 'UEX terminals + commodities_raw_prices_all'
        locationCount = 0
        matchedLocationDescriptions = 0
        changedLocationDescriptions = 0
    }
    $itemPassportMetadata = @{
        enabled = $true
        source = 'Star Citizen Wiki'
        cacheRecords = 0
        matchedDescriptionKeys = 0
        changedItemDescriptions = 0
        cleanedExistingBlocks = 0
    }
    $stripLoreMetadata = @{
        enabled = $enableStripLoreDescriptions
        changedDescriptions = 0
        changedKeysSample = @()
    }
    $planetBlockCount = 0
    $supplementalSectionCount = 0
    $recipeData = $null
    $planetBlueprints = @()
    $recipeDataWarnings = @()
    $timings = [ordered]@{
        recipeDataMs = 0
        planetDescriptionsMs = 0
        planetCraftMapMs = 0
        planetLocationIndexMs = 0
        planetInventoryCacheMs = 0
        planetDescriptionScanMs = 0
        itemPassportsMs = 0
        itemCraftHintsMs = 0
        refineryHintsMs = 0
        locationTradeHintsMs = 0
        finalizeMs = 0
    }

    Write-Host 'Progress: mining recipe data start'
    $recipeDataStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($selectedMethods.Count -gt 0 -and $Context.KeyCount -ge 1000) {
        try {
            $planetBlueprints = @(Get-SCMiningPlanetCraftBlueprints)
        }
        catch {
            $recipeDataWarnings += "Mining planet recipe cache unavailable: $($_.Exception.Message)"
        }
    }

    if ($enableItemCraftHints) {
        try {
            $recipeData = Get-SCMiningItemCraftRecipeData
            if ($recipeData.CatalogDiagnostics -and $recipeData.CatalogDiagnostics.unresolvedCount -gt 0) {
                $recipeDataWarnings += "SCMDB crafting catalog has $($recipeData.CatalogDiagnostics.unresolvedCount) unresolved records; see metadata.craftingCatalog.issues."
            }
            if ($planetBlueprints.Count -eq 0) {
                $planetBlueprints = @($recipeData.Blueprints)
            }
        }
        catch {
            $recipeDataWarnings += "Mining recipe data unavailable: $($_.Exception.Message)"
        }
    }
    $recipeDataStopwatch.Stop()
    $timings['recipeDataMs'] = $recipeDataStopwatch.ElapsedMilliseconds
    Write-Host 'Progress: mining recipe data done'
    Write-Host "Timing: mining recipe data: $($timings['recipeDataMs']) ms"

    Write-Host 'Progress: mining planet descriptions start'
    $planetDescriptionsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($true) {
        $planetCraftMapStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $planetCraftMap = @{}
        $planetCraftIndex = $null
        if ($planetBlueprints.Count -gt 0) {
            $planetCraftMap = New-SCMiningPlanetCraftMap -Blueprints @($planetBlueprints)
            $planetCraftIndex = New-SCMiningPlanetCraftIndex -PlanetCraftMap $planetCraftMap -CraftFilter $craftFilter
        }
        $planetCraftMapStopwatch.Stop()
        $timings['planetCraftMapMs'] = $planetCraftMapStopwatch.ElapsedMilliseconds

        $planetLocationIndexStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $miningLocationIndex = @{}
        $miningSupplementalIndex = @{}
        try {
            $locationIndex = Get-SCMiningLocationInventoryIndex
            $miningLocationIndex = $locationIndex.ByKey
            if ($null -ne $locationIndex.SupplementalByKey) {
                $miningSupplementalIndex = $locationIndex.SupplementalByKey
            }
            $recipeDataWarnings += @($locationIndex.Warnings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }
        catch {
            $recipeDataWarnings += "Mining location data unavailable: $($_.Exception.Message)"
        }
        $planetLocationIndexStopwatch.Stop()
        $timings['planetLocationIndexMs'] = $planetLocationIndexStopwatch.ElapsedMilliseconds

        $planetInventoryCacheStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $planetInventoryCache = Get-SCMiningPlanetResourceInventoryCache
        $planetInventoryCacheStopwatch.Stop()
        $timings['planetInventoryCacheMs'] = $planetInventoryCacheStopwatch.ElapsedMilliseconds
        $planetInventoryCacheChanged = $false
        $planetCraftBlockCache = @{}
        $planetCraftBlockOptionKey = (@($SelectedOptions | Sort-Object) -join '|')

        $planetDescriptionScanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($key in @($Context.Values.Keys | Sort-Object)) {
            if ($key -notmatch '(?i)_desc(?:,|$)|_description(?:,|$)') {
                continue
            }

            $current = [string]$Context.Values[$key]
            $hasCraftBlock = Test-SCMiningHasCraftBlock -Value $current
            $miningLocationInventory = $null
            $normalizedLocationKey = Get-SCMiningNormalizedIniKey -Key $key
            $retiredLocationDescription = Get-SCMiningRetiredLocationBaseDescription -Key $normalizedLocationKey
            if (-not [string]::IsNullOrWhiteSpace($retiredLocationDescription)) {
                $filtered = Remove-SCMiningRetiredLocationCraftBlock -Value $current -BaseDescription $retiredLocationDescription
                if ($filtered -ne $current) {
                    $operations += [pscustomobject]@{
                        ModuleId = 'mining'
                        OptionId = 'locationCleanup'
                        Key = $key
                        Operation = 'replaceValue'
                        OriginalValue = $current
                        NewValue = $filtered
                        OwnedMarkers = @('SCMDB_CRAFT_INTEL_CLEANUP')
                    }
                    $changedPlanetKeys += $key
                    $planetBlockCount++
                }
                continue
            }
            if ($miningLocationIndex.ContainsKey($normalizedLocationKey)) {
                $miningLocationInventory = $miningLocationIndex[$normalizedLocationKey]
            }
            if (-not $hasCraftBlock -and $null -eq $miningLocationInventory) {
                continue
            }

            $planetBlockCount++
            $inventory = if ($null -ne $miningLocationInventory) { $miningLocationInventory } else { Read-SCMiningResourceInventoryFromValue -Value $current }
            if ($null -eq $miningLocationInventory -and (Test-SCMiningCleanResourceSourceValue -Value $current) -and (Test-SCMiningResourceInventoryUsable -Inventory $inventory)) {
                $planetInventoryCache[$key] = ConvertTo-SCMiningPlanetResourceInventoryCacheRecord -Inventory $inventory
                $planetInventoryCacheChanged = $true
            }
            elseif ($null -eq $miningLocationInventory -and $planetInventoryCache.ContainsKey($key)) {
                $inventory = ConvertFrom-SCMiningPlanetResourceInventoryCacheRecord -Record $planetInventoryCache[$key]
            }
            if (-not (Test-SCMiningResourceInventoryUsable -Inventory $inventory)) {
                continue
            }

            $detailedCraftBlock = $null
            if ($planetCraftMap.Count -gt 0) {
                $cacheKey = $planetCraftBlockOptionKey + '::' + (Get-SCMiningInventorySignature -Inventory $inventory)
                if (-not $planetCraftBlockCache.ContainsKey($cacheKey)) {
                    $planetCraftBlockCache[$cacheKey] = Format-SCMiningPlanetCraftBlock -Inventory $inventory -PlanetCraftMap $planetCraftMap -PlanetCraftIndex $planetCraftIndex -SelectedMethods $selectedMethods -CraftFilter $craftFilter
                }
                $detailedCraftBlock = [string]$planetCraftBlockCache[$cacheKey]
            }

            $additionalLocationBlocks = New-Object System.Collections.Generic.List[string]
            if ($miningSupplementalIndex.ContainsKey($normalizedLocationKey)) {
                foreach ($section in @($miningSupplementalIndex[$normalizedLocationKey])) {
                    $sectionCacheKey = $planetCraftBlockOptionKey + '::section::' + (Get-SCMiningInventorySignature -Inventory $section.Inventory)
                    if (-not $planetCraftBlockCache.ContainsKey($sectionCacheKey)) {
                        $planetCraftBlockCache[$sectionCacheKey] = Format-SCMiningPlanetCraftBlock -Inventory $section.Inventory -PlanetCraftMap $planetCraftMap -PlanetCraftIndex $planetCraftIndex -SelectedMethods $selectedMethods -CraftFilter $craftFilter -BodyOnly
                    }
                    $sectionBody = [string]$planetCraftBlockCache[$sectionCacheKey]
                    if (-not [string]::IsNullOrWhiteSpace($sectionBody)) {
                        $additionalLocationBlocks.Add(([string]$section.Header + '\n\n' + $sectionBody))
                        $supplementalSectionCount++
                    }
                }
            }

            $filtered = Update-SCMiningCraftBlockMethods -Value $current -SelectedMethods $selectedMethods -PlanetCraftMap $planetCraftMap -CraftFilter $craftFilter -Inventory $inventory -DetailedCraftBlock $detailedCraftBlock -AdditionalLocationBlocks @($additionalLocationBlocks.ToArray())
            if ($filtered -ne $current) {
                $operations += [pscustomobject]@{
                    ModuleId = 'mining'
                    OptionId = 'methodFilter'
                    Key = $key
                    Operation = 'replaceValue'
                    OriginalValue = $current
                    NewValue = $filtered
                    OwnedMarkers = @('SCMDB_CRAFT_INTEL_BLOCK')
                }
                $changedPlanetKeys += $key
            }
        }
        $planetDescriptionScanStopwatch.Stop()
        $timings['planetDescriptionScanMs'] = $planetDescriptionScanStopwatch.ElapsedMilliseconds

        if ($planetInventoryCacheChanged) {
            Write-SCMiningPlanetResourceInventoryCache -Cache $planetInventoryCache
        }
    }
    $planetDescriptionsStopwatch.Stop()
    $timings['planetDescriptionsMs'] = $planetDescriptionsStopwatch.ElapsedMilliseconds
    Write-Host 'Progress: mining planet descriptions done'
    Write-Host "Timing: mining planet descriptions: $($timings['planetDescriptionsMs']) ms"
    Write-Host "Timing: mining planet craft map: $($timings['planetCraftMapMs']) ms"
    Write-Host "Timing: mining planet location index: $($timings['planetLocationIndexMs']) ms"
    Write-Host "Timing: mining planet inventory cache: $($timings['planetInventoryCacheMs']) ms"
    Write-Host "Timing: mining planet description scan: $($timings['planetDescriptionScanMs']) ms"

    $workingValues = Copy-SCMiningValueMap -Values $Context.Values
    Apply-SCMiningOperationsToValueMap -Values $workingValues -Operations $operations
    $workingContext = New-SCMiningContextWithValues -Context $Context -Values $workingValues

    Write-Host 'Progress: mining item passports start'
    $itemPassportsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $itemPassportPlan = New-SCMiningItemPassportOperations -Context $Context -Values $workingValues
    $operations += @($itemPassportPlan.Operations)
    $itemPassportWarnings += @($itemPassportPlan.Warnings)
    $itemPassportMetadata = $itemPassportPlan.Metadata
    Apply-SCMiningOperationsToValueMap -Values $workingValues -Operations @($itemPassportPlan.Operations)
    $workingContext = New-SCMiningContextWithValues -Context $Context -Values $workingValues
    $itemPassportsStopwatch.Stop()
    $timings['itemPassportsMs'] = $itemPassportsStopwatch.ElapsedMilliseconds
    Write-Host 'Progress: mining item passports done'
    Write-Host "Timing: mining item passports: $($timings['itemPassportsMs']) ms"

    Write-Host 'Progress: mining item craft hints start'
    $itemCraftHintsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($enableItemCraftHints) {
        $itemPlan = New-SCMiningItemCraftHintOperations -Context $workingContext -RecipeData $recipeData
        $operations += @($itemPlan.Operations)
        $itemCraftWarnings += @($itemPlan.Warnings)
        $itemCraftMetadata = $itemPlan.Metadata
    }
    Apply-SCMiningOperationsToValueMap -Values $workingValues -Operations @($itemPlan.Operations)
    $workingContext = New-SCMiningContextWithValues -Context $Context -Values $workingValues
    $itemCraftHintsStopwatch.Stop()
    $timings['itemCraftHintsMs'] = $itemCraftHintsStopwatch.ElapsedMilliseconds
    Write-Host 'Progress: mining item craft hints done'
    Write-Host "Timing: mining item craft hints: $($timings['itemCraftHintsMs']) ms"

    Write-Host 'Progress: mining refinery hints start'
    $refineryHintsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($enableRefineryYieldHints) {
        $refineryPlan = New-SCMiningRefineryYieldHintOperations -Context $workingContext
        $operations += @($refineryPlan.Operations)
        $refineryYieldWarnings += @($refineryPlan.Warnings)
        $refineryYieldMetadata = $refineryPlan.Metadata
    }
    else {
        $refineryPlan = Remove-SCMiningRefineryYieldHintOperations -Context $workingContext
        $operations += @($refineryPlan.Operations)
        $refineryYieldMetadata = $refineryPlan.Metadata
    }
    Apply-SCMiningOperationsToValueMap -Values $workingValues -Operations @($refineryPlan.Operations)
    $workingContext = New-SCMiningContextWithValues -Context $Context -Values $workingValues
    $refineryHintsStopwatch.Stop()
    $timings['refineryHintsMs'] = $refineryHintsStopwatch.ElapsedMilliseconds
    Write-Host 'Progress: mining refinery hints done'
    Write-Host "Timing: mining refinery hints: $($timings['refineryHintsMs']) ms"

    Write-Host 'Progress: mining location trade hints start'
    $locationTradeHintsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($enableLocationTradeHints) {
        $locationTradePlan = New-SCMiningLocationTradeHintOperations -Context $workingContext
        $operations += @($locationTradePlan.Operations)
        $locationTradeWarnings += @($locationTradePlan.Warnings)
        $locationTradeMetadata = $locationTradePlan.Metadata
    }
    else {
        $locationTradePlan = Remove-SCMiningLocationTradeHintOperations -Context $workingContext
        $operations += @($locationTradePlan.Operations)
        $locationTradeMetadata = $locationTradePlan.Metadata
    }
    Apply-SCMiningOperationsToValueMap -Values $workingValues -Operations @($locationTradePlan.Operations)
    $locationTradeHintsStopwatch.Stop()
    $timings['locationTradeHintsMs'] = $locationTradeHintsStopwatch.ElapsedMilliseconds
    Write-Host 'Progress: mining location trade hints done'
    Write-Host "Timing: mining location trade hints: $($timings['locationTradeHintsMs']) ms"

    Write-Host 'Progress: mining finalize start'
    $finalizeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $operations = Merge-SCMiningReplaceOperations -Operations $operations -BaseValues $Context.Values
    if ($enableStripLoreDescriptions) {
        $stripPlan = Set-SCMiningLoreDescriptionStripOnOperations -Operations @($operations) -Values $workingValues
        $operations = Merge-SCMiningReplaceOperations -Operations @($stripPlan.Operations) -BaseValues $Context.Values
        $stripLoreMetadata = $stripPlan.Metadata
    }
    $finalizeStopwatch.Stop()
    $timings['finalizeMs'] = $finalizeStopwatch.ElapsedMilliseconds
    Write-Host 'Progress: mining finalize done'
    Write-Host "Timing: mining finalize: $($timings['finalizeMs']) ms"

    $metadata = @{
        source = 'SCMDB mining data and crafting recipes, UEX hints and Wiki item passports'
        craftingCatalog = $(if ($recipeData) { $recipeData.CatalogDiagnostics } else { $null })
        selectedOptionCount = @($SelectedOptions).Count
        selectedMethods = @($selectedMethods)
        inspectedKeys = $Context.KeyCount
        planetBlocksFound = $planetBlockCount
        supplementalLocationSections = $supplementalSectionCount
        changedPlanetDescriptions = @($changedPlanetKeys).Count
        changedPlanetKeysSample = @($changedPlanetKeys | Select-Object -First 20)
        itemCraftHints = $itemCraftMetadata
        refineryYieldHints = $refineryYieldMetadata
        locationTradeHints = $locationTradeMetadata
        itemPassports = $itemPassportMetadata
        stripLoreDescriptions = $stripLoreMetadata
        timings = $timings
    }

    return [pscustomobject]@{
        ModuleId = 'mining'
        Operations = @($operations)
        Warnings = @($recipeDataWarnings + $itemCraftWarnings + $refineryYieldWarnings + $locationTradeWarnings + $itemPassportWarnings)
        Metadata = $metadata
    }
}

function Get-SCMiningSelectedMethods {
    param([string[]]$SelectedOptions)

    $methods = @()
    if ('shipMining' -in $SelectedOptions) {
        $methods += (Get-SCMiningShipCode)
    }
    if ('groundVehicleMining' -in $SelectedOptions) {
        $methods += (Get-SCMiningGroundCode)
    }
    if ('multitoolMining' -in $SelectedOptions) {
        $methods += (Get-SCMiningHandCode)
    }

    return @($methods)
}

function New-SCMiningItemCraftHintOperations {
    param(
        [object]$Context,
        [object]$RecipeData
    )

    $metadata = @{
        enabled = $true
        scmdbVersion = $null
        rewardRecords = 0
        blueprints = 0
        recipeSource = $null
        rewardRecipes = 0
        safeDescriptionKeys = 0
        safeRewardRecords = 0
        changedItemDescriptions = 0
        skippedUnmapped = 0
        skippedNoWiki = 0
        skippedNoIngredients = 0
        skippedConflict = 0
        skippedConflictKeys = @()
        skippedUnmappedSamples = @()
    }

    try {
        $recipeData = if ($null -ne $RecipeData) { $RecipeData } else { Get-SCMiningItemCraftRecipeData }
        $metadata.scmdbVersion = $recipeData.ScmdbVersion
        $metadata.rewardRecords = $recipeData.RewardRecords.Count
        $metadata.blueprints = $recipeData.Blueprints.Count
        $metadata.recipeSource = if ($recipeData.Blueprints.Count -gt 0 -and $recipeData.Blueprints[0].source -eq 'SCMDB') { 'SCMDB' } else { 'legacy Wiki' }

        $lookup = New-SCMiningLocalizationLookup -Context $Context
        $mappedByDescriptionKey = @{}
        $skippedUnmapped = New-Object System.Collections.Generic.List[object]
        $skippedNoWiki = 0
        $skippedNoIngredients = 0
        $rewardRecipes = 0

        foreach ($reward in @($recipeData.RewardRecords)) {
            $blueprint = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$reward.blueprintRecord) -and
                $recipeData.BlueprintsByUuid.ContainsKey([string]$reward.blueprintRecord)) {
                $blueprint = $recipeData.BlueprintsByUuid[[string]$reward.blueprintRecord]
            }

            if ($null -eq $blueprint) {
                $skippedNoWiki++
                continue
            }

            $resources = @(Get-SCMiningBlueprintResourceNames -Blueprint $blueprint)
            if ($resources.Count -eq 0) {
                $skippedNoIngredients++
                continue
            }

            $rewardRecipes++
            $descriptionKey = Resolve-SCMiningCraftDescriptionKey -Blueprint $blueprint -Reward $reward -Lookup $lookup
            if ([string]::IsNullOrWhiteSpace($descriptionKey)) {
                $skippedUnmapped.Add([pscustomobject]@{
                    name = Get-SCMiningBlueprintOutputName -Blueprint $blueprint -Reward $reward
                    type = Get-SCMiningBlueprintOutputType -Blueprint $blueprint
                    class = Get-SCMiningBlueprintOutputClass -Blueprint $blueprint -Reward $reward
                })
                continue
            }

            if (-not $mappedByDescriptionKey.ContainsKey($descriptionKey)) {
                $mappedByDescriptionKey[$descriptionKey] = New-Object System.Collections.Generic.List[object]
            }

            $mappedByDescriptionKey[$descriptionKey].Add([pscustomobject]@{
                Blueprint = $blueprint
                Reward = $reward
                DescriptionKey = $descriptionKey
                Resources = @($resources)
                ResourceSignature = Get-SCMiningResourceSignature -Resources $resources
                IsCanonical = Test-SCMiningCanonicalBlueprint -Blueprint $blueprint -Reward $reward
            })
        }

        $operations = @()
        $skippedConflict = 0
        $skippedConflictKeys = New-Object System.Collections.Generic.List[string]
        $safeRewardRecords = 0

        foreach ($descriptionKey in @($mappedByDescriptionKey.Keys | Sort-Object)) {
            $records = @($mappedByDescriptionKey[$descriptionKey].ToArray())
            $signatures = @($records | ForEach-Object { $_.ResourceSignature } | Sort-Object -Unique)
            $chosen = $null

            if ($signatures.Count -eq 1) {
                $chosen = $records[0]
                $safeRewardRecords += $records.Count
            }
            else {
                $canonical = @($records | Where-Object { $_.IsCanonical })
                $canonicalSignatures = @($canonical | ForEach-Object { $_.ResourceSignature } | Sort-Object -Unique)
                if ($canonical.Count -gt 0 -and $canonicalSignatures.Count -eq 1) {
                    $chosen = $canonical[0]
                    $safeRewardRecords += $canonical.Count
                }
                else {
                    $skippedConflict += $records.Count
                    $skippedConflictKeys.Add($descriptionKey)
                    continue
                }
            }

            if (-not $Context.Values.ContainsKey($descriptionKey)) {
                continue
            }

            $current = [string]$Context.Values[$descriptionKey]
            $updated = Set-SCMiningItemCraftHint -Value $current -Resources $chosen.Resources
            if ($updated -ne $current) {
                $operations += [pscustomobject]@{
                    ModuleId = 'mining'
                    OptionId = 'itemCraftHints'
                    Key = $descriptionKey
                    Operation = 'replaceValue'
                    OriginalValue = $current
                    NewValue = $updated
                    OwnedMarkers = @('SC_ITEM_CRAFT_HINT_BLOCK')
                }
            }
        }

        $metadata.rewardRecipes = $rewardRecipes
        $metadata.safeDescriptionKeys = @($mappedByDescriptionKey.Keys).Count - @($skippedConflictKeys).Count
        $metadata.safeRewardRecords = $safeRewardRecords
        $metadata.changedItemDescriptions = @($operations).Count
        $metadata.skippedUnmapped = $skippedUnmapped.Count
        $metadata.skippedNoWiki = $skippedNoWiki
        $metadata.skippedNoIngredients = $skippedNoIngredients
        $metadata.skippedConflict = $skippedConflict
        $metadata.skippedConflictKeys = @($skippedConflictKeys)
        $metadata.skippedUnmappedSamples = @($skippedUnmapped | Select-Object -First 20)

        return [pscustomobject]@{
            Operations = @($operations)
            Warnings = @()
            Metadata = $metadata
        }
    }
    catch {
        $metadata.enabled = $true
        return [pscustomobject]@{
            Operations = @()
            Warnings = @("Item craft hints skipped: $($_.Exception.Message)")
            Metadata = $metadata
        }
    }
}

function Remove-SCMiningItemCraftHintOperations {
    param([object]$Context)

    $operations = @()
    foreach ($key in @($Context.Values.Keys | Sort-Object)) {
        $current = [string]$Context.Values[$key]
        if ($current.IndexOf((Get-SCMiningItemCraftHintLabel), [System.StringComparison]::Ordinal) -lt 0) {
            continue
        }

        $updated = Remove-SCMiningItemCraftHint -Value $current
        if ($updated -ne $current) {
            $operations += [pscustomobject]@{
                ModuleId = 'mining'
                OptionId = 'itemCraftHints'
                Key = $key
                Operation = 'replaceValue'
                OriginalValue = $current
                NewValue = $updated
                OwnedMarkers = @('SC_ITEM_CRAFT_HINT_BLOCK')
            }
        }
    }

    return [pscustomobject]@{
        Operations = @($operations)
        Metadata = @{
            enabled = $false
            removedItemDescriptions = @($operations).Count
            safeDescriptionKeys = 0
            changedItemDescriptions = 0
            skippedUnmapped = 0
            skippedNoWiki = 0
            skippedConflict = 0
        }
    }
}

function New-SCMiningRefineryYieldHintOperations {
    param([object]$Context)

    $metadata = @{
        enabled = $true
        source = ''
        sourceUrl = ''
        gameVersion = ''
        stationCount = 0
        matchedStationDescriptions = 0
        changedStationDescriptions = 0
        changedStationKeysSample = @()
    }

    try {
        $data = Get-SCMiningRefineryYieldData
        $metadata.source = [string]$data.source
        $metadata.sourceUrl = [string]$data.sourceUrl
        $metadata.gameVersion = [string]$data.gameVersion
        $metadata.stationCount = @($data.stations).Count
        $stationMatchEntries = @(
            foreach ($station in @($data.stations)) {
                [pscustomobject]@{
                    Station = $station
                    Candidates = @(Get-SCMiningRefineryYieldStationCandidates -Station $station | Sort-Object { $_.Length } -Descending)
                }
            }
        )

        $operations = @()
        $changedKeys = New-Object System.Collections.Generic.List[string]
        $matchedDescriptions = 0
        foreach ($key in @($Context.Values.Keys | Sort-Object)) {
            if ($key -notmatch '(?i)_desc(?:,|$)|_description(?:,|$)' -and [string]::IsNullOrWhiteSpace((Get-SCMiningRefineryYieldKnownLocationTitle -Key $key -Values $Context.Values))) {
                continue
            }

            $current = [string]$Context.Values[$key]
            $clean = Remove-SCMiningRefineryYieldHint -Value $current
            $station = Find-SCMiningRefineryYieldStation -Key $key -Values $Context.Values -Stations @($data.stations) -StationMatchEntries $stationMatchEntries
            if ($null -eq $station) {
                if ($clean -ne $current) {
                    $operations += [pscustomobject]@{
                        ModuleId = 'mining'
                        OptionId = 'refineryYieldHints'
                        Key = $key
                        Operation = 'replaceValue'
                        OriginalValue = $current
                        NewValue = $clean
                        OwnedMarkers = @('SC_REFINERY_YIELD_HINT_BLOCK')
                    }
                    $changedKeys.Add($key)
                }
                continue
            }

            $matchedDescriptions++
            $updated = Set-SCMiningRefineryYieldHint -Value $clean -Station $station
            if ($updated -ne $current) {
                $operations += [pscustomobject]@{
                    ModuleId = 'mining'
                    OptionId = 'refineryYieldHints'
                    Key = $key
                    Operation = 'replaceValue'
                    OriginalValue = $current
                    NewValue = $updated
                    OwnedMarkers = @('SC_REFINERY_YIELD_HINT_BLOCK')
                }
                $changedKeys.Add($key)
            }
        }

        $metadata.matchedStationDescriptions = $matchedDescriptions
        $metadata.changedStationDescriptions = @($operations).Count
        $metadata.changedStationKeysSample = @($changedKeys | Select-Object -First 20)

        return [pscustomobject]@{
            Operations = @($operations)
            Warnings = @()
            Metadata = $metadata
        }
    }
    catch {
        return [pscustomobject]@{
            Operations = @()
            Warnings = @("Refinery yield hints skipped: $($_.Exception.Message)")
            Metadata = $metadata
        }
    }
}

function Remove-SCMiningRefineryYieldHintOperations {
    param([object]$Context)

    $operations = @()
    foreach ($key in @($Context.Values.Keys | Sort-Object)) {
        $current = [string]$Context.Values[$key]
        if ($current.IndexOf((Get-SCMiningRefineryYieldHintLabel), [System.StringComparison]::Ordinal) -lt 0) {
            continue
        }

        $updated = Remove-SCMiningRefineryYieldHint -Value $current
        if ($updated -ne $current) {
            $operations += [pscustomobject]@{
                ModuleId = 'mining'
                OptionId = 'refineryYieldHints'
                Key = $key
                Operation = 'replaceValue'
                OriginalValue = $current
                NewValue = $updated
                OwnedMarkers = @('SC_REFINERY_YIELD_HINT_BLOCK')
            }
        }
    }

    return [pscustomobject]@{
        Operations = @($operations)
        Metadata = @{
            enabled = $false
            source = 'UEX refineries_yields'
            stationCount = 0
            matchedStationDescriptions = 0
            changedStationDescriptions = @($operations).Count
        }
    }
}

function New-SCMiningLocationTradeHintOperations {
    param([object]$Context)

    $metadata = @{
        enabled = $true
        source = ''
        sourceUrl = ''
        gameVersion = ''
        locationCount = 0
        matchedLocationDescriptions = 0
        changedLocationDescriptions = 0
        changedLocationKeysSample = @()
    }

    try {
        $data = Get-SCMiningLocationTradeData
        $metadata.source = [string]$data.source
        $metadata.sourceUrl = [string]$data.sourceUrl
        $metadata.gameVersion = [string]$data.gameVersion
        $metadata.locationCount = @($data.locations).Count
        $locationMatchEntries = @(
            foreach ($location in @($data.locations)) {
                [pscustomobject]@{
                    Location = $location
                    Candidates = @(Get-SCMiningLocationTradeCandidates -Location $location | Sort-Object { $_.Length } -Descending)
                }
            }
        )

        $operations = @()
        $changedKeys = New-Object System.Collections.Generic.List[string]
        $matchedDescriptions = 0
        foreach ($key in @($Context.Values.Keys | Sort-Object)) {
            if ($key -notmatch '(?i)_desc(?:,|$)|_description(?:,|$)' -and [string]::IsNullOrWhiteSpace((Get-SCMiningLocationTradeKnownLocationTitle -Key $key -Values $Context.Values))) {
                continue
            }

            $current = [string]$Context.Values[$key]
            $clean = Remove-SCMiningLocationTradeHint -Value $current
            $location = Find-SCMiningLocationTradeLocation -Key $key -Values $Context.Values -Locations @($data.locations) -LocationMatchEntries $locationMatchEntries
            if ($null -eq $location) {
                if ($clean -ne $current) {
                    $operations += [pscustomobject]@{
                        ModuleId = 'mining'
                        OptionId = 'rawOreBuyHints'
                        Key = $key
                        Operation = 'replaceValue'
                        OriginalValue = $current
                        NewValue = $clean
                        OwnedMarkers = @('SC_LOCATION_TRADE_HINT_BLOCK')
                    }
                    $changedKeys.Add($key)
                }
                continue
            }

            $matchedDescriptions++
            $updated = Set-SCMiningLocationTradeHint -Value $clean -Location $location
            if ($updated -ne $current) {
                $operations += [pscustomobject]@{
                    ModuleId = 'mining'
                    OptionId = 'rawOreBuyHints'
                    Key = $key
                    Operation = 'replaceValue'
                    OriginalValue = $current
                    NewValue = $updated
                    OwnedMarkers = @('SC_LOCATION_TRADE_HINT_BLOCK')
                }
                $changedKeys.Add($key)
            }
        }

        $metadata.matchedLocationDescriptions = $matchedDescriptions
        $metadata.changedLocationDescriptions = @($operations).Count
        $metadata.changedLocationKeysSample = @($changedKeys | Select-Object -First 20)

        return [pscustomobject]@{
            Operations = @($operations)
            Warnings = @()
            Metadata = $metadata
        }
    }
    catch {
        return [pscustomobject]@{
            Operations = @()
            Warnings = @("Raw ore buy hints skipped: $($_.Exception.Message)")
            Metadata = $metadata
        }
    }
}

function Remove-SCMiningLocationTradeHintOperations {
    param([object]$Context)

    $operations = @()
    foreach ($key in @($Context.Values.Keys | Sort-Object)) {
        $current = [string]$Context.Values[$key]
        $hasCurrentHint = $current.IndexOf((Get-SCMiningLocationTradeHintLabel), [System.StringComparison]::Ordinal) -ge 0
        $hasLegacyHint = $current.IndexOf((Get-SCMiningLocationTradeLegacyHintLabel), [System.StringComparison]::Ordinal) -ge 0
        if (-not $hasCurrentHint -and -not $hasLegacyHint) {
            continue
        }

        $updated = Remove-SCMiningLocationTradeHint -Value $current
        if ($updated -ne $current) {
            $operations += [pscustomobject]@{
                ModuleId = 'mining'
                OptionId = 'rawOreBuyHints'
                Key = $key
                Operation = 'replaceValue'
                OriginalValue = $current
                NewValue = $updated
                OwnedMarkers = @('SC_LOCATION_TRADE_HINT_BLOCK')
            }
        }
    }

    return [pscustomobject]@{
        Operations = @($operations)
        Metadata = @{
            enabled = $false
            source = 'UEX terminals + commodities_raw_prices_all'
            locationCount = 0
            matchedLocationDescriptions = 0
            changedLocationDescriptions = @($operations).Count
        }
    }
}

function New-SCMiningItemPassportOperations {
    param(
        [object]$Context,
        [hashtable]$Values
    )

    $metadata = @{
        enabled = $true
        source = 'Star Citizen Wiki'
        sourceUrl = 'https://api.star-citizen.wiki/'
        gameVersion = ''
        cacheRecords = 0
        matchedDescriptionKeys = 0
        changedItemDescriptions = 0
        cleanedExistingBlocks = 0
        skippedNoPassport = 0
        matchedKeysSample = @()
    }

    try {
        $data = Get-SCMiningItemPassportData
        if ($null -eq $data) {
            return [pscustomobject]@{
                Operations = @()
                Warnings = @('Item passports skipped: Wiki passport cache is missing. Refresh cache before applying.')
                Metadata = $metadata
            }
        }

        $metadata.source = [string]$data.source
        $metadata.sourceUrl = [string]$data.sourceUrl
        $metadata.gameVersion = [string]$data.gameVersion
        $metadata.cacheRecords = @($data.records).Count

        $lookup = New-SCMiningItemPassportLookup -Records @($data.records)
        $operations = @()
        $matchedKeys = New-Object System.Collections.Generic.List[string]
        $cleanedExistingBlocks = 0
        $skippedNoPassport = 0

        foreach ($key in @($Values.Keys | Sort-Object)) {
            $token = Get-SCMiningItemDescriptionToken -Key ([string]$key)
            if ([string]::IsNullOrWhiteSpace($token)) {
                continue
            }

            $current = [string]$Values[$key]
            $clean = Remove-SCMiningItemPassportBlock -Value $current
            if ($clean -ne $current) {
                $cleanedExistingBlocks++
            }

            if (-not $lookup.ContainsKey($token)) {
                if ($clean -ne $current) {
                    $original = [string]$Context.Values[$key]
                    $operations += [pscustomobject]@{
                        ModuleId = 'mining'
                        OptionId = 'itemPassports'
                        Key = $key
                        Operation = 'replaceValue'
                        OriginalValue = $original
                        NewValue = $clean
                        OwnedMarkers = @('SC_ITEM_PASSPORT_BLOCK')
                    }
                }
                $skippedNoPassport++
                continue
            }

            $record = $lookup[$token]
            $updated = Set-SCMiningItemPassportBlock -Value $clean -Record $record
            if ($updated -ne $current -or $updated -ne [string]$Context.Values[$key]) {
                $original = [string]$Context.Values[$key]
                $operations += [pscustomobject]@{
                    ModuleId = 'mining'
                    OptionId = 'itemPassports'
                    Key = $key
                    Operation = 'replaceValue'
                    OriginalValue = $original
                    NewValue = $updated
                    OwnedMarkers = @('SC_ITEM_PASSPORT_BLOCK')
                }
            }

            $matchedKeys.Add([string]$key)
        }

        $metadata.matchedDescriptionKeys = $matchedKeys.Count
        $metadata.changedItemDescriptions = @($operations).Count
        $metadata.cleanedExistingBlocks = $cleanedExistingBlocks
        $metadata.skippedNoPassport = $skippedNoPassport
        $metadata.matchedKeysSample = @($matchedKeys | Select-Object -First 20)

        return [pscustomobject]@{
            Operations = @($operations)
            Warnings = @()
            Metadata = $metadata
        }
    }
    catch {
        return [pscustomobject]@{
            Operations = @()
            Warnings = @("Item passports skipped: $($_.Exception.Message)")
            Metadata = $metadata
        }
    }
}

function Copy-SCMiningValueMap {
    param([hashtable]$Values)

    $copy = @{}
    foreach ($entry in $Values.GetEnumerator()) {
        $copy[[string]$entry.Key] = [string]$entry.Value
    }
    return $copy
}

function New-SCMiningContextWithValues {
    param(
        [object]$Context,
        [hashtable]$Values
    )

    return [pscustomobject]@{
        LivePath = $Context.LivePath
        GlobalIniPath = $Context.GlobalIniPath
        EncodingInfo = $Context.EncodingInfo
        OriginalSha256 = $Context.OriginalSha256
        OriginalSize = $Context.OriginalSize
        Lines = $Context.Lines
        Values = $Values
        KeyLineIndexes = $Context.KeyLineIndexes
        LineCount = $Context.LineCount
        KeyCount = $Context.KeyCount
    }
}

function Apply-SCMiningOperationsToValueMap {
    param(
        [hashtable]$Values,
        [object[]]$Operations
    )

    foreach ($operation in @($Operations)) {
        if ([string]$operation.Operation -ne 'replaceValue') {
            continue
        }

        $Values[[string]$operation.Key] = [string]$operation.NewValue
    }
}

function Merge-SCMiningReplaceOperations {
    param(
        [object[]]$Operations,
        [hashtable]$BaseValues
    )

    $merged = [ordered]@{}
    $passthrough = @()

    foreach ($operation in @($Operations)) {
        if ([string]$operation.Operation -ne 'replaceValue') {
            $passthrough += $operation
            continue
        }

        $key = [string]$operation.Key
        if (-not $merged.Contains($key)) {
            $original = if ($BaseValues.ContainsKey($key)) { [string]$BaseValues[$key] } else { [string]$operation.OriginalValue }
            $merged[$key] = [pscustomobject]@{
                ModuleId = [string]$operation.ModuleId
                OptionIds = New-Object System.Collections.Generic.List[string]
                Key = $key
                Operation = 'replaceValue'
                OriginalValue = $original
                NewValue = [string]$operation.NewValue
                OwnedMarkers = New-Object System.Collections.Generic.List[string]
            }
        }
        else {
            $merged[$key].NewValue = [string]$operation.NewValue
        }

        $optionId = [string]$operation.OptionId
        if (-not [string]::IsNullOrWhiteSpace($optionId) -and -not $merged[$key].OptionIds.Contains($optionId)) {
            $merged[$key].OptionIds.Add($optionId)
        }
        foreach ($marker in @($operation.OwnedMarkers)) {
            $markerText = [string]$marker
            if (-not [string]::IsNullOrWhiteSpace($markerText) -and -not $merged[$key].OwnedMarkers.Contains($markerText)) {
                $merged[$key].OwnedMarkers.Add($markerText)
            }
        }
    }

    $result = @()
    foreach ($entry in $merged.GetEnumerator()) {
        $record = $entry.Value
        if ([string]$record.NewValue -eq [string]$record.OriginalValue) {
            continue
        }

        $result += [pscustomobject]@{
            ModuleId = $record.ModuleId
            OptionId = (($record.OptionIds.ToArray()) -join '+')
            Key = $record.Key
            Operation = $record.Operation
            OriginalValue = $record.OriginalValue
            NewValue = $record.NewValue
            OwnedMarkers = @($record.OwnedMarkers.ToArray())
        }
    }

    return @($passthrough + $result)
}

function Set-SCMiningLoreDescriptionStripOnOperations {
    param(
        [object[]]$Operations,
        [hashtable]$Values
    )

    $result = New-Object System.Collections.Generic.List[object]
    $changedKeys = New-Object System.Collections.Generic.List[string]
    $plannedKeys = @{}

    foreach ($operation in @($Operations)) {
        $plannedKeys[[string]$operation.Key] = $true
        if ([string]$operation.Operation -ne 'replaceValue' -or -not (Test-SCMiningLoreStripTargetOperation -Operation $operation)) {
            $result.Add($operation)
            continue
        }

        $stripped = Remove-SCMiningLoreDescriptionPrefix -Value ([string]$operation.NewValue)
        if ($stripped -eq [string]$operation.NewValue) {
            $result.Add($operation)
            continue
        }

        $result.Add([pscustomobject]@{
            ModuleId = $operation.ModuleId
            OptionId = Add-SCMiningOperationOptionId -OptionId ([string]$operation.OptionId) -AddedOptionId 'stripLoreDescriptions'
            Key = $operation.Key
            Operation = $operation.Operation
            OriginalValue = $operation.OriginalValue
            NewValue = $stripped
            OwnedMarkers = @(Add-SCMiningOwnedMarker -Markers @($operation.OwnedMarkers) -AddedMarker 'SC_LORE_DESCRIPTION_STRIP')
        })
        $changedKeys.Add([string]$operation.Key)
    }

    if ($null -ne $Values) {
        # The hide-lore option must also work when all generated hints are already current.
        $resourceHeaders = @((Get-SCMiningRawResourceHeaderMethods).Keys) + @((Get-SCMiningCraftHeader))
        $refineryLabel = Get-SCMiningRefineryYieldHintLabel
        $tradeLabels = @((Get-SCMiningLocationTradeHintLabel), (Get-SCMiningLocationTradeLegacyHintLabel))
        foreach ($key in @($Values.Keys | Sort-Object)) {
            if ($plannedKeys.ContainsKey([string]$key) -or $key -notmatch '(?i)_desc(?:,|$)|_description(?:,|$)') {
                continue
            }
            $current = [string]$Values[$key]
            $markers = New-Object System.Collections.Generic.List[string]
            foreach ($header in $resourceHeaders) {
                if ($current.IndexOf([string]$header, [System.StringComparison]::Ordinal) -ge 0) {
                    $markers.Add('SCMDB_CRAFT_INTEL_BLOCK')
                    break
                }
            }
            if ($current.IndexOf($refineryLabel, [System.StringComparison]::Ordinal) -ge 0) {
                $markers.Add('SC_REFINERY_YIELD_HINT_BLOCK')
            }
            foreach ($label in $tradeLabels) {
                if ($current.IndexOf([string]$label, [System.StringComparison]::Ordinal) -ge 0) {
                    $markers.Add('SC_LOCATION_TRADE_HINT_BLOCK')
                    break
                }
            }
            if ($markers.Count -eq 0) {
                continue
            }
            $stripped = Remove-SCMiningLoreDescriptionPrefix -Value $current
            if ($stripped -ceq $current) {
                continue
            }
            $markers.Add('SC_LORE_DESCRIPTION_STRIP')
            $result.Add([pscustomobject]@{
                ModuleId = 'mining'
                OptionId = 'stripLoreDescriptions'
                Key = $key
                Operation = 'replaceValue'
                OriginalValue = $current
                NewValue = $stripped
                OwnedMarkers = @($markers.ToArray())
            })
            $changedKeys.Add([string]$key)
        }
    }

    return [pscustomobject]@{
        Operations = @($result.ToArray())
        Metadata = @{
            enabled = $true
            changedDescriptions = $changedKeys.Count
            changedKeysSample = @($changedKeys | Select-Object -First 20)
        }
    }
}

function Test-SCMiningLoreStripTargetOperation {
    param([object]$Operation)

    foreach ($marker in @($Operation.OwnedMarkers)) {
        if ([string]$marker -in @('SCMDB_CRAFT_INTEL_BLOCK', 'SC_REFINERY_YIELD_HINT_BLOCK', 'SC_LOCATION_TRADE_HINT_BLOCK')) {
            return $true
        }
    }

    return $false
}

function Add-SCMiningOperationOptionId {
    param(
        [AllowEmptyString()][string]$OptionId,
        [Parameter(Mandatory = $true)][string]$AddedOptionId
    )

    $parts = @($OptionId -split '\+' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($AddedOptionId -notin $parts) {
        $parts += $AddedOptionId
    }

    return ($parts -join '+')
}

function Add-SCMiningOwnedMarker {
    param(
        [object[]]$Markers,
        [Parameter(Mandatory = $true)][string]$AddedMarker
    )

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($marker in @($Markers)) {
        $text = [string]$marker
        if (-not [string]::IsNullOrWhiteSpace($text) -and -not $result.Contains($text)) {
            $result.Add($text)
        }
    }
    if (-not $result.Contains($AddedMarker)) {
        $result.Add($AddedMarker)
    }

    return @($result.ToArray())
}

function Remove-SCMiningLoreDescriptionPrefix {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [string]$Value
    }

    $indexes = New-Object System.Collections.Generic.List[int]

    $rawIndex = Get-SCMiningRawResourceBlockIndex -Value $Value
    if ($rawIndex -ge 0) {
        $indexes.Add($rawIndex)
    }

    $craftIndex = ([string]$Value).IndexOf((Get-SCMiningCraftHeader), [System.StringComparison]::Ordinal)
    if ($craftIndex -ge 0) {
        $indexes.Add($craftIndex)
    }

    $utilityIndex = Get-SCMiningUtilityHintBlockIndex -Value $Value
    if ($utilityIndex -ge 0) {
        $indexes.Add($utilityIndex)
    }

    if ($indexes.Count -eq 0) {
        return [string]$Value
    }

    $firstIndex = [int]($indexes | Sort-Object | Select-Object -First 1)
    if ($firstIndex -le 0) {
        return (Trim-SCMiningEncodedLeadingBreaks -Value ([string]$Value))
    }

    return (Trim-SCMiningEncodedLeadingBreaks -Value (([string]$Value).Substring($firstIndex)))
}

function Get-SCMiningUtilityHintBlockIndex {
    param([AllowEmptyString()][string]$Value)

    $labels = @(
        (Get-SCMiningRefineryYieldHintLabel),
        (Get-SCMiningLocationTradeHintLabel),
        (Get-SCMiningLocationTradeLegacyHintLabel)
    )
    $labelPattern = (($labels | ForEach-Object { [regex]::Escape([string]$_) + ':?' }) -join '|')
    $pattern = '<EM[1-5]>(?:' + $labelPattern + ')</EM[1-5]>'
    $match = [regex]::Match([string]$Value, $pattern)
    if ($match.Success) {
        return $match.Index
    }

    return -1
}

function Get-SCMiningItemCraftRecipeData {
    $scmdbCache = Read-SCMiningScmdbCache
    $scmdb = $scmdbCache.Data
    $rewardRecords = @(Get-SCMiningScmdbRewardBlueprintRecords -Scmdb $scmdb)
    $blueprints = @(Get-SCMiningCachedCraftingRecipes -CacheKey ([string]$scmdbCache.Version))
    if ($blueprints.Count -eq 0) {
        throw "Mining recipe cache is missing for SCMDB version $($scmdbCache.Version). Refresh cache before applying."
    }
    $blueprintsByUuid = @{}
    $catalog = Read-SCCraftingCatalog -CacheKey ([string]$scmdbCache.Version)
    $diagnostics = if ($null -ne $catalog) { Get-SCCraftingCatalogDiagnostics -Catalog $catalog } else { $null }

    foreach ($blueprint in $blueprints) {
        if (-not [string]::IsNullOrWhiteSpace([string]$blueprint.uuid)) {
            $blueprintsByUuid[[string]$blueprint.uuid] = $blueprint
        }
    }

    return [pscustomobject]@{
        ScmdbVersion = [string]$scmdbCache.Version
        RewardRecords = @($rewardRecords)
        Blueprints = @($blueprints)
        BlueprintsByUuid = $blueprintsByUuid
        CatalogDiagnostics = $diagnostics
    }
}

function Get-SCMiningNormalizedIniKey {
    param([string]$Key)

    return (([string]$Key).Trim() -replace ',.*$', '')
}

function Get-SCMiningPlanetCraftBlueprints {
    $scmdbCache = Read-SCMiningScmdbCache
    $cached = Get-SCMiningCachedCraftingRecipes -CacheKey ([string]$scmdbCache.Version)
    if ($cached.Count -gt 0) {
        return @($cached)
    }

    throw "Mining recipe cache is missing for SCMDB version $($scmdbCache.Version). Refresh cache before applying."
}

function Get-SCMiningCachedMiningData {
    $scmdbCache = Read-SCMiningScmdbCache
    $cachePath = Get-SCMiningMiningDataCachePath -CacheKey ([string]$scmdbCache.Version)
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        throw "Mining data cache is missing for SCMDB version $($scmdbCache.Version). Refresh cache before applying."
    }

    return (Get-Content -Raw -LiteralPath $cachePath | ConvertFrom-Json)
}

function Get-SCMiningMiningDataCachePath {
    param([Parameter(Mandatory = $true)][string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    return (Join-Path $cacheDir ("mining-data-{0}.json" -f (Get-SCMiningSafeCacheKey -CacheKey $CacheKey)))
}

function Get-SCMiningLocationInventoryIndex {
    $data = Get-SCMiningCachedMiningData
    $locationByName = @{}
    $locationByPreset = @{}
    foreach ($location in @($data.locations)) {
        $name = [string]$location.locationName
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $locationByName[$name.ToLowerInvariant()] = $location
        }
        $preset = [string]$location.presetFile
        if (-not [string]::IsNullOrWhiteSpace($preset)) {
            $locationByPreset[$preset] = $location
        }
    }

    $byKey = @{}
    foreach ($pair in (Get-SCMiningLocationKeyMap).GetEnumerator()) {
        $locations = New-Object System.Collections.Generic.List[object]
        foreach ($locationName in @($pair.Value)) {
            $lookupName = ([string]$locationName).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($lookupName) -or -not $locationByName.ContainsKey($lookupName)) {
                continue
            }

            $locations.Add($locationByName[$lookupName])
        }

        if ($locations.Count -eq 0) {
            continue
        }

        $inventory = ConvertTo-SCMiningInventoryFromMiningDataLocations -Locations @($locations.ToArray()) -MiningData $data
        if (Test-SCMiningResourceInventoryUsable -Inventory $inventory) {
            $byKey[(Get-SCMiningNormalizedIniKey -Key ([string]$pair.Key))] = $inventory
        }
    }

    $supplementalByKey = @{}
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($pair in (Get-SCMiningSupplementalLocationMap).GetEnumerator()) {
        $sections = New-Object System.Collections.Generic.List[object]
        foreach ($preset in @($pair.Value)) {
            if (-not $locationByPreset.ContainsKey([string]$preset)) {
                $warnings.Add("Mining asteroid belt profile '$preset' unavailable for $($pair.Key); section omitted.")
                continue
            }
            $inventory = ConvertTo-SCMiningInventoryFromMiningDataLocation -Location $locationByPreset[[string]$preset] -MiningData $data
            if (-not (Test-SCMiningResourceInventoryUsable -Inventory $inventory)) {
                $warnings.Add("Mining asteroid belt profile '$preset' has no usable resources for $($pair.Key); section omitted.")
                continue
            }
            $sections.Add([pscustomobject]@{
                Header = Get-SCMiningAsteroidBeltHeader
                SourcePresetFile = [string]$preset
                Inventory = $inventory
            })
        }
        if ($sections.Count -gt 0) {
            $supplementalByKey[(Get-SCMiningNormalizedIniKey -Key ([string]$pair.Key))] = @($sections.ToArray())
        }
    }

    return [pscustomobject]@{
        ByKey = $byKey
        SupplementalByKey = $supplementalByKey
        Warnings = @($warnings.ToArray())
        SourceVersion = [string]$data.version
    }
}

function Get-SCMiningSupplementalLocationMap {
    # Terminus Ring shares Yela's preset in game data and SCMDB's virtual-location map.
    # Only the main body descriptions inherit it; surface facilities keep their own profile.
    return @{
        'Stanton2c_Desc' = @('hpp_stanton2c_belt')
        'Pyro6_desc' = @('hpp_stanton2c_belt')
    }
}

function Get-SCMiningAsteroidBeltHeader {
    $label = ConvertFrom-SCCodePoints -CodePoints @(0x0410, 0x0441, 0x0442, 0x0435, 0x0440, 0x043E, 0x0438, 0x0434, 0x043D, 0x044B, 0x0439, 0x0020, 0x043F, 0x043E, 0x044F, 0x0441)
    return ('<EM4>' + $label + '</EM4>')
}

function Get-SCMiningRetiredLocationBaseDescription {
    param([string]$Key)

    if ([string]$Key -ne 'nyx_transit_Glaciem_gen_desc') {
        return ''
    }

    $prefix = ConvertFrom-SCCodePoints -CodePoints @(0x0422, 0x0440, 0x0430, 0x043D, 0x0437, 0x0438, 0x0442, 0x043D, 0x0430, 0x044F, 0x0020, 0x0442, 0x043E, 0x0447, 0x043A, 0x0430, 0x0020, 0x0434, 0x043B, 0x044F, 0x0020, 0x043E, 0x0431, 0x043B, 0x0451, 0x0442, 0x0430)
    return ($prefix + ' Glaciem Ring.')
}

function Remove-SCMiningRetiredLocationCraftBlock {
    param(
        [AllowEmptyString()][string]$Value,
        [string]$BaseDescription
    )

    if (-not (Test-SCMiningHasCraftBlock -Value $Value)) {
        return [string]$Value
    }

    $clean = Get-SCMiningBaseDescriptionPrefix -Value $Value
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return [string]$BaseDescription
    }

    return [string]$clean
}

function Get-SCMiningLocationKeyMap {
    $map = @{
        'Stanton1_Desc' = 'Hurston'
        'Stanton1a_Desc' = 'Arial'
        'Stanton1b_Desc' = 'Aberdeen'
        'Stanton1c_Desc' = 'Magda'
        'Stanton1d_Desc' = 'Ita'
        'Stanton2a_Desc' = 'Cellin'
        'Stanton2b_Desc' = 'Daymar'
        'Stanton2c_Desc' = 'Yela'
        'Stanton3a_Desc' = 'Lyria'
        'Stanton3b_Desc' = 'Wala'
        'Stanton4_Desc' = 'microTech'
        'Stanton4a_Desc' = 'Calliope'
        'Stanton4b_Desc' = 'Clio'
        'Stanton4c_Desc' = 'Euterpe'

        'Pyro1_desc' = 'Pyro I'
        'Pyro2_desc' = 'Pyro II (Monox)'
        'Pyro3_desc' = 'Pyro III (Bloom)'
        'Pyro4_desc' = 'Pyro IV'
        'Pyro6_desc' = 'Pyro VI (Terminus)'
        'Pyro5a_Ignis_desc' = 'Pyro V-a (Ignis)'
        'Pyro5b_Vatra_desc' = 'Pyro V-b (Vatra)'
        'Pyro5c_Adir_desc' = 'Pyro V-c (Adir)'
        'Pyro5d_Fairo_desc' = 'Pyro V-d (Fairo)'
        'Pyro5e_Fuego_desc' = 'Pyro V-e (Fuego)'
        'Pyro5f_Vuur_desc' = 'Pyro V-f (Vuur)'

        'asteroidfield_desc_Shared' = @('Asteroid Cluster (Low Yield)', 'Asteroid Cluster (Medium Yield)')
        'AsteroidCluster_MiningBase_Desc' = 'Aaron Halo'
        'Pyro_asteroidbeltA_desc' = @('Pyro Belt (Cool 1)', 'Pyro Belt (Cool 2)', 'Pyro Belt (Warm 1)', 'Pyro Belt (Warm 2)')
        'pyro_asteroid_cluster_desc' = 'Pyro Deep Space Asteroids'
        'AsteroidCluster_Pyro_Desc' = 'Pyro Deep Space Asteroids'
        'AsteroidBase_P3_L4_desc' = 'Pyro Deep Space Asteroids'
        'AsteroidBase_P3_L5_desc' = 'Pyro Deep Space Asteroids'
        'ab_mine_pyro_desc' = 'Pyro Deep Space Asteroids'
        'Nyx_AsteroidBelt1_Desc' = 'Glaciem Ring'
        'Nyx_AsteroidBelt2_Desc' = 'Keeger Belt'
        'Nyx_RockCracker_Desc' = @('Keeger Belt', 'Breaker Stations Interior', 'Breaker Stations Large Geode')
    }

    Add-SCMiningSurfaceLocationKeyMap -Map $map
    Add-SCMiningStantonLagrangeLocationKeyMap -Map $map
    return $map
}

function Add-SCMiningSurfaceLocationKeyMap {
    param([hashtable]$Map)

    $surfaceProfiles = @{
        'Stanton1' = 'Hurston'
        'Stanton1a' = 'Arial'
        'Stanton1b' = 'Aberdeen'
        'Stanton1c' = 'Magda'
        'Stanton1d' = 'Ita'
        'Stanton2a' = 'Cellin'
        'Stanton2b' = 'Daymar'
        'Stanton2c' = 'Yela'
        'Stanton3a' = 'Lyria'
        'Stanton3b' = 'Wala'
        'Stanton4' = 'microTech'
        'Stanton4a' = 'Calliope'
        'Stanton4b' = 'Clio'
        'Stanton4c' = 'Euterpe'
        'Pyro1' = 'Pyro I'
        'Pyro2' = 'Pyro II (Monox)'
        'Pyro3' = 'Pyro III (Bloom)'
        'Pyro4' = 'Pyro IV'
        'Pyro6' = 'Pyro VI (Terminus)'
        'Pyro5a' = 'Pyro V-a (Ignis)'
        'Pyro5b' = 'Pyro V-b (Vatra)'
        'Pyro5c' = 'Pyro V-c (Adir)'
        'Pyro5d' = 'Pyro V-d (Fairo)'
        'Pyro5e' = 'Pyro V-e (Fuego)'
        'Pyro5f' = 'Pyro V-f (Vuur)'
    }

    foreach ($entry in $surfaceProfiles.GetEnumerator()) {
        $prefix = [string]$entry.Key
        $profile = [string]$entry.Value

        foreach ($i in 1..10) {
            $Map[('{0}_ASD_Delving_Facility_{1:000}_desc' -f $prefix, $i)] = $profile
        }

        foreach ($i in 1..6) {
            $Map[('{0}_HurDyn_{1:000}_desc' -f $prefix, $i)] = $profile
        }

        foreach ($i in 1..2) {
            $Map[('{0}_IndyMine_{1:000}_desc' -f $prefix, $i)] = $profile
        }

        $Map[('{0}_Cave_Aband_01_desc' -f $prefix)] = $profile

        foreach ($set in 1..2) {
            foreach ($suffix in @('a', 'b', 'c', 'd')) {
                $Map[('{0}_MiningCompound_drlct_{1:000}_{2}_desc' -f $prefix, $set, $suffix)] = $profile
            }
        }
    }

    $Map['Pyro1_Outpost_col_s_mng_indy_001_desc'] = 'Pyro I'
    $Map['Pyro2_Outpost_col_m_mng_otlw_002_desc'] = 'Pyro II (Monox)'
    $Map['Pyro2_Outpost_col_s_mng_indy_001_desc'] = 'Pyro II (Monox)'
    $Map['Pyro2_Outpost_col_s_mng_otlw_001_desc'] = 'Pyro II (Monox)'
    $Map['Pyro3_Outpost_col_m_mng_indy_001_desc'] = 'Pyro III (Bloom)'
    $Map['Pyro3_Outpost_col_s_mng_otlw_001_desc'] = 'Pyro III (Bloom)'
}

function Add-SCMiningStantonLagrangeLocationKeyMap {
    param([hashtable]$Map)

    $profileByStation = @{
        'HUR-L1' = 'Lagrange A'
        'HUR-L2' = 'Lagrange F'
        'HUR-L3' = 'Lagrange E'
        'HUR-L4' = 'Lagrange A'
        'HUR-L5' = 'Lagrange C'
        'CRU-L1' = 'Lagrange E'
        'CRU-L2' = 'Lagrange E'
        'CRU-L3' = 'Lagrange C'
        'CRU-L4' = 'Lagrange B'
        'CRU-L5' = 'Lagrange D'
        'ARC-L1' = 'Lagrange F'
        'ARC-L2' = 'Lagrange F'
        'ARC-L3' = 'Lagrange D'
        'ARC-L4' = 'Lagrange F'
        'ARC-L5' = 'Lagrange B'
        'MIC-L1' = 'Lagrange C'
        'MIC-L2' = 'Lagrange C'
        'MIC-L3' = 'Lagrange B'
        'MIC-L4' = 'Lagrange D'
        'MIC-L5' = 'Lagrange C'
    }

    $systemPrefixes = @{
        'HUR' = 'Stanton1'
        'CRU' = 'Stanton2'
        'ARC' = 'Stanton3'
        'MIC' = 'Stanton4'
    }

    foreach ($station in @($profileByStation.Keys)) {
        $profile = $profileByStation[$station]
        $parts = $station -split '-L'
        $systemCode = $parts[0]
        $point = [int]$parts[1]
        $prefix = $systemPrefixes[$systemCode]
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            continue
        }

        $Map[('{0}_L{1}_desc' -f $prefix, $point)] = $profile
        foreach ($i in 1..4) {
            $Map[('{0}_L{1}_{2:00}_desc' -f $prefix, $point, $i)] = $profile
        }
        $Map[('RR_{0}_L{1}_desc' -f $systemCode, $point)] = $profile
    }
}

function ConvertTo-SCMiningInventoryFromMiningDataLocations {
    param(
        [Parameter(Mandatory = $true)][object[]]$Locations,
        [Parameter(Mandatory = $true)]$MiningData
    )

    $merged = New-SCMiningEmptyResourceInventory
    foreach ($location in @($Locations)) {
        $inventory = ConvertTo-SCMiningInventoryFromMiningDataLocation -Location $location -MiningData $MiningData
        foreach ($method in Get-SCMiningMethodOrder) {
            foreach ($entry in Expand-SCMiningResourceEntries -Entries $inventory.ResourcesByMethod[$method]) {
                $merged.ResourcesByMethod[$method].Add($entry)
            }
        }
        foreach ($entry in Expand-SCMiningResourceEntries -Entries $inventory.CollectableResources) {
            $merged.CollectableResources.Add($entry)
        }
        foreach ($entry in Expand-SCMiningResourceEntries -Entries $inventory.CreatureResources) {
            $merged.CreatureResources.Add($entry)
        }
    }

    return Normalize-SCMiningResourceInventory -Inventory $merged
}

function ConvertTo-SCMiningInventoryFromMiningDataLocation {
    param(
        [Parameter(Mandatory = $true)]$Location,
        [Parameter(Mandatory = $true)]$MiningData
    )

    $inventory = New-SCMiningEmptyResourceInventory
    $methodByGroup = @{
        SpaceShip_Mineables = (Get-SCMiningShipCode)
        GroundVehicle_Mineables = (Get-SCMiningGroundCode)
        FPS_Mineables = (Get-SCMiningHandCode)
    }

    foreach ($group in @($Location.groups)) {
        $groupName = [string]$group.groupName
        if (-not $methodByGroup.ContainsKey($groupName)) {
            continue
        }

        $method = $methodByGroup[$groupName]
        foreach ($deposit in @($group.deposits | Sort-Object -Property @{ Expression = { -[double]$_.relativeProbability } }, @{ Expression = { [int]$_.flatIndex } })) {
            $composition = $MiningData.compositions.PSObject.Properties[[string]$deposit.compositionGuid].Value
            if ($null -eq $composition) {
                continue
            }

            $name = Get-SCMiningDisplayMaterialName -Name ([string]$composition.name)
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            $inventory.ResourcesByMethod[$method].Add(("{0} {1}%" -f $name, (Format-SCMiningSpawnPercent -Value ([double]$deposit.relativeProbability))))
        }
    }

    return Normalize-SCMiningResourceInventory -Inventory $inventory
}

function Get-SCMiningDisplayMaterialName {
    param([AllowEmptyString()][string]$Name)

    $clean = ([string]$Name).Trim()
    $clean = $clean -replace '\s*\((?:Raw|Ore|R)\)\s*$', ''
    if ($clean -eq 'Raw Ice') {
        return 'Ice'
    }
    if ($clean -eq 'Raw Silicon') {
        return 'Silicon'
    }
    if ($clean -eq 'Aluminium') {
        return 'Aluminum'
    }

    return $clean
}

function Format-SCMiningSpawnPercent {
    param([double]$Value)

    return (([math]::Round($Value, 1)).ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture))
}

function Invoke-SCMiningRemoteJson {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Referer
    )

    try {
        return (Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 120)
    }
    catch {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            $userAgent = if ($Headers -and $Headers.ContainsKey('User-Agent')) {
                [string]$Headers['User-Agent']
            }
            else {
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36'
            }

            $curlArgs = @(
                '-L', '--silent', '--show-error', '--fail',
                '--max-time', '120',
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
            if (-not [string]::IsNullOrWhiteSpace($Referer)) {
                $curlArgs += @('-e', $Referer)
            }
            $curlArgs += $Uri

            $curlOutput = @(& curl.exe @curlArgs 2>&1)
            $curlExitCode = $LASTEXITCODE
            $json = $curlOutput -join [Environment]::NewLine
            if ($curlExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
                return ($json | ConvertFrom-Json)
            }
        }

        throw
    }
}

function Invoke-SCMiningScmdbJson {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    return (Invoke-SCMiningRemoteJson -Uri $Uri -Headers $Headers -Referer 'https://scmdb.net/')
}

function Get-SCMiningScmdbCacheDirectory {
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'scmdb\cache')
}

function Read-SCMiningScmdbCache {
    $cacheDir = Get-SCMiningScmdbCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        throw 'SCMDB cache is missing. Refresh cache before applying.'
    }

    $cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'scmdb-*.json' -File |
        Where-Object { $_.Name -notlike '*.meta.json' -and $_.Name -match '(?i)-live\.' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $cacheFile) {
        throw 'SCMDB cache is missing. Refresh cache before applying.'
    }

    $payload = Get-Content -LiteralPath $cacheFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$payload.version) -or $null -eq $payload.data) {
        throw "SCMDB cache is invalid: $($cacheFile.FullName)"
    }

    return [pscustomobject]@{
        Path = [string]$cacheFile.FullName
        Version = [string]$payload.version
        Data = $payload.data
    }
}

function Get-SCMiningCachedCraftingRecipes {
    param([string]$CacheKey)
    $catalog = Read-SCCraftingCatalog -CacheKey $CacheKey
    if ($null -ne $catalog) {
        return @(ConvertTo-SCCraftingRecipes -BlueprintData $catalog.blueprintData -ItemData $catalog.itemData)
    }
    # Legacy cache is read only for compatibility; refresh always uses SCMDB.
    return @(Get-SCMiningCachedWikiBlueprints -CacheKey $CacheKey)
}

function Get-SCMiningRecipeCachePath {
    param([string]$CacheKey)
    $primary = Get-SCCraftingCatalogCachePath -CacheKey $CacheKey
    if (Test-Path -LiteralPath $primary -PathType Leaf) { return $primary }
    return (Get-SCMiningWikiBlueprintCachePath -CacheKey $CacheKey)
}

function Get-SCMiningCachedWikiBlueprints {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return @()
    }

    if (-not [string]::IsNullOrWhiteSpace($CacheKey)) {
        $path = Get-SCMiningWikiBlueprintCachePath -CacheKey $CacheKey
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $cacheFile = Get-Item -LiteralPath $path
        }
        else {
            $cacheFile = $null
        }
    }
    else {
        $cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'wiki-blueprints-*.json' -File |
            Where-Object { $_.Name -match '(?i)-live\.' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }
    if ($null -eq $cacheFile) {
        return @()
    }

    try {
        $cache = Get-Content -LiteralPath $cacheFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($cache.PSObject.Properties['data']) {
            return @($cache.data)
        }
    }
    catch {
    }

    return @()
}

function Get-SCMiningCacheDirectory {
    return (Join-Path $PSScriptRoot 'cache')
}

function Get-SCMiningItemPassportData {
    $scmdbCache = Read-SCMiningScmdbCache
    return (Get-SCMiningCachedItemPassports -CacheKey ([string]$scmdbCache.Version))
}

function Get-SCMiningCachedItemPassports {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($CacheKey)) {
        $cacheFile = $null
        foreach ($path in @(
            (Get-SCMiningItemPassportCachePath -CacheKey $CacheKey),
            (Get-SCMiningLegacyItemPassportCachePath -CacheKey $CacheKey)
        )) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $cacheFile = Get-Item -LiteralPath $path
                break
            }
        }
    }
    else {
        $cacheFile = Get-ChildItem -LiteralPath $cacheDir -File |
            Where-Object { $_.Name -match '^(?:wiki|erkul)-item-passports-.*\.json$' } |
            Where-Object { $_.Name -match '(?i)-live\.' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    if ($null -eq $cacheFile) {
        return $null
    }

    try {
        $cache = Get-Content -LiteralPath $cacheFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($cache.PSObject.Properties['records']) {
            return $cache
        }
    }
    catch {
    }

    return $null
}

function Get-SCMiningItemPassportCachePath {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    return (Join-Path $cacheDir ("wiki-item-passports-{0}.json" -f (Get-SCMiningSafeCacheKey -CacheKey $CacheKey)))
}

function Get-SCMiningLegacyItemPassportCachePath {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    return (Join-Path $cacheDir ("erkul-item-passports-{0}.json" -f (Get-SCMiningSafeCacheKey -CacheKey $CacheKey)))
}

function Write-SCMiningItemPassportCache {
    param(
        [string]$CacheKey,
        [hashtable]$Headers
    )

    $wikiVersions = Get-SCMiningWikiGameVersions -Headers $Headers
    $wikiVersion = Resolve-SCMiningWikiGameVersion -CacheKey $CacheKey -Versions $wikiVersions
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($endpoint in Get-SCMiningWikiPassportEndpoints) {
        $page = 1
        $lastPage = 1
        do {
            $result = Invoke-SCMiningWikiItemPage -Type ([string]$endpoint.Type) -Page $page -WikiVersion ([string]$wikiVersion.Code) -Headers $Headers
            foreach ($item in @($result.data)) {
                $record = ConvertTo-SCMiningWikiItemPassportRecord -Entry $item -Kind ([string]$endpoint.Kind)
                if ($null -ne $record) {
                    $records.Add($record)
                }
            }

            if ($null -ne $result.meta -and $null -ne $result.meta.last_page) {
                $lastPage = [Math]::Max(1, [int]$result.meta.last_page)
            }
            $page++
        } while ($page -le $lastPage)
    }

    if ($records.Count -eq 0) {
        throw 'Star Citizen Wiki returned no item passport records.'
    }

    $payload = [pscustomobject]@{
        schemaVersion = 3
        source = 'Star Citizen Wiki'
        sourceUrl = 'https://api.star-citizen.wiki/'
        backendUrl = 'https://api.star-citizen.wiki/api/items'
        cacheKey = [string]$CacheKey
        requestedGameVersion = [string]$wikiVersion.RequestedCode
        gameVersion = [string]$wikiVersion.Code
        versionMatch = [string]$wikiVersion.Match
        createdAt = (Get-Date).ToString('o')
        records = @($records.ToArray() | Sort-Object kind, displayName, localName)
    }

    $cachePath = Get-SCMiningItemPassportCachePath -CacheKey $CacheKey
    $cacheDir = Split-Path -Parent $cachePath
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    }

    $json = $payload | ConvertTo-Json -Depth 12
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cachePath, $json, $encoding)
    return $cachePath
}

function Get-SCMiningWikiPassportEndpoints {
    return @(
        [pscustomobject]@{ Kind = 'weapon'; Type = 'WeaponGun' },
        [pscustomobject]@{ Kind = 'shield'; Type = 'Shield' },
        [pscustomobject]@{ Kind = 'powerPlant'; Type = 'PowerPlant' },
        [pscustomobject]@{ Kind = 'cooler'; Type = 'Cooler' },
        [pscustomobject]@{ Kind = 'qdrive'; Type = 'QuantumDrive' },
        [pscustomobject]@{ Kind = 'emp'; Type = 'EMP' },
        [pscustomobject]@{ Kind = 'qed'; Type = 'QuantumInterdictionGenerator' }
    )
}

function ConvertTo-SCMiningWikiGameVersion {
    param([string]$CacheKey)

    return ([string]$CacheKey -replace '(?i)-live\.', '-LIVE.')
}

function Get-SCMiningWikiGameVersions {
    param([hashtable]$Headers)

    return (Invoke-SCMiningRemoteJson -Uri 'https://api.star-citizen.wiki/api/game-versions?page%5Bsize%5D=100&page%5Bnumber%5D=1' -Headers $Headers -Referer 'https://api.star-citizen.wiki/')
}

function Get-SCMiningWikiGameVersionParts {
    param([string]$Version)

    $match = [regex]::Match(([string]$Version).Trim(), '^(?<branch>\d+\.\d+\.\d+)-(?<channel>[^.]+)\.(?<build>\d+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }

    return [pscustomobject]@{
        Branch = [string]$match.Groups['branch'].Value
        Channel = [string]$match.Groups['channel'].Value
        Build = [long]$match.Groups['build'].Value
    }
}

function Resolve-SCMiningWikiGameVersion {
    param(
        [Parameter(Mandatory = $true)][string]$CacheKey,
        [Parameter(Mandatory = $true)][object]$Versions
    )

    $requestedCode = ConvertTo-SCMiningWikiGameVersion -CacheKey $CacheKey
    $requestedParts = Get-SCMiningWikiGameVersionParts -Version $requestedCode
    if ($null -eq $requestedParts) {
        throw "Cannot resolve Wiki game version for invalid SCMDB cache key: $CacheKey"
    }

    $entries = if ($null -ne $Versions -and $null -ne $Versions.PSObject.Properties['data']) {
        @($Versions.data)
    }
    else {
        @($Versions)
    }

    $available = @($entries | ForEach-Object {
        $code = [string]$_.code
        $parts = Get-SCMiningWikiGameVersionParts -Version $code
        if ($null -ne $parts) {
            [pscustomobject]@{
                Code = $code
                Branch = [string]$parts.Branch
                Channel = [string]$parts.Channel
                Build = [long]$parts.Build
            }
        }
    })

    $exact = $available | Where-Object { [string]$_.Code -eq $requestedCode } | Select-Object -First 1
    if ($null -ne $exact) {
        return [pscustomobject]@{
            RequestedCode = $requestedCode
            Code = [string]$exact.Code
            Match = 'exact'
        }
    }

    $compatible = $available |
        Where-Object {
            [string]$_.Branch -eq [string]$requestedParts.Branch -and
            [string]$_.Channel -eq [string]$requestedParts.Channel
        } |
        Sort-Object -Property @{ Expression = { [long]$_.Build }; Descending = $true } |
        Select-Object -First 1
    if ($null -eq $compatible) {
        throw "Star Citizen Wiki has no LIVE item data for SCMDB branch $($requestedParts.Branch)."
    }

    return [pscustomobject]@{
        RequestedCode = $requestedCode
        Code = [string]$compatible.Code
        Match = 'compatible'
    }
}

function Invoke-SCMiningWikiItemPage {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][int]$Page,
        [Parameter(Mandatory = $true)][string]$WikiVersion,
        [hashtable]$Headers
    )

    $version = [uri]::EscapeDataString($WikiVersion)
    $encodedType = [uri]::EscapeDataString($Type)
    $uri = "https://api.star-citizen.wiki/api/items?filter%5Btype%5D=$encodedType&page%5Bsize%5D=100&page%5Bnumber%5D=$Page&version=$version"
    return (Invoke-SCMiningRemoteJson -Uri $uri -Headers $Headers -Referer 'https://api.star-citizen.wiki/')
}

function ConvertTo-SCMiningWikiItemPassportRecord {
    param(
        [object]$Entry,
        [string]$Kind
    )

    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace([string]$Entry.class_name)) {
        return $null
    }

    $lines = @(Format-SCMiningWikiItemPassportLines -Entry $Entry -Kind $Kind)
    if ($lines.Count -eq 0) {
        return $null
    }

    $localName = [string]$Entry.class_name
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($localName, ($localName -replace '(?i)_scitem$', ''))) {
        $token = ConvertTo-SCMiningItemPassportToken -Value $candidate
        if (-not [string]::IsNullOrWhiteSpace($token) -and -not $tokens.Contains($token)) {
            $tokens.Add($token)
        }
    }

    return [pscustomobject]@{
        kind = [string]$Kind
        localName = $localName
        displayName = [string]$Entry.name
        shortName = ''
        tokens = @($tokens.ToArray())
        blockLines = @($lines)
    }
}

function Format-SCMiningWikiItemPassportLines {
    param(
        [object]$Entry,
        [string]$Kind
    )

    if ($Kind -eq 'weapon') {
        return @(Format-SCMiningWikiWeaponPassportLines -Entry $Entry)
    }
    if ($Kind -eq 'shield') {
        return @(Format-SCMiningWikiComponentPassportLines -Entry $Entry -PrimaryLabel 'прочность' -PrimaryValuePath 'shield.max_shield_health' -SecondaryLabel 'реген' -SecondaryValuePath 'shield.max_shield_regen' -SecondarySuffix '/с')
    }
    if ($Kind -eq 'powerPlant') {
        return @(Format-SCMiningWikiComponentPassportLines -Entry $Entry -PrimaryLabel 'энергия' -PrimaryValuePath 'power_plant.power_segment_generation' -SecondaryLabel 'HP' -SecondaryValuePath 'durability.health')
    }
    if ($Kind -eq 'cooler') {
        return @(Format-SCMiningWikiComponentPassportLines -Entry $Entry -PrimaryLabel 'охлаждение' -PrimaryValuePath 'cooler.coolant_segment_generation' -SecondaryLabel 'IR' -SecondaryValuePath 'emission.ir')
    }
    if ($Kind -eq 'qdrive') {
        return @(Format-SCMiningWikiQuantumDrivePassportLines -Entry $Entry)
    }
    if ($Kind -eq 'emp') {
        return @(Format-SCMiningWikiEmpPassportLines -Entry $Entry)
    }
    if ($Kind -eq 'qed') {
        return @(Format-SCMiningWikiQedPassportLines -Entry $Entry)
    }

    return @()
}

function Format-SCMiningWikiWeaponPassportLines {
    param([object]$Entry)

    $damage = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'vehicle_weapon.damage.alpha_total')
    if ($damage -le 0) {
        $damage = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'vehicle_weapon.damage_per_shot')
    }
    $fireRate = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'vehicle_weapon.rpm')
    $dps = if ($damage -gt 0 -and $fireRate -gt 0) { $damage * $fireRate / 60.0 } else { 0 }
    $projectileSpeed = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'ammunition.speed')
    $penetration = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'ammunition.penetration.base_distance')
    $ammo = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'vehicle_weapon.capacity')
    $capacitor = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'vehicle_weapon.capacitor.max_ammo_load')

    $line1 = @()
    if ($dps -gt 0) { $line1 += 'DPS ' + (Format-SCMiningNumber -Value $dps) }
    if ($damage -gt 0) { $line1 += 'урон ' + (Format-SCMiningNumber -Value $damage) }

    $line2 = @()
    if ($fireRate -gt 0) { $line2 += 'темп ' + (Format-SCMiningNumber -Value $fireRate) + '/мин' }
    if ($projectileSpeed -gt 0) { $line2 += 'скорость ' + (Format-SCMiningNumber -Value $projectileSpeed) + ' м/с' }
    if ($penetration -gt 0) { $line2 += 'пробитие ' + (Format-SCMiningNumber -Value $penetration) + ' м' }
    if ($ammo -gt 0) { $line2 += 'боекомплект ' + (Format-SCMiningNumber -Value $ammo) }
    elseif ($capacitor -gt 0) { $line2 += 'конденсатор ' + (Format-SCMiningNumber -Value $capacitor) }

    return @(($line1 -join ' | '), ($line2 -join ' | ')) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Format-SCMiningWikiComponentPassportLines {
    param(
        [object]$Entry,
        [string]$PrimaryLabel,
        [string]$PrimaryValuePath,
        [string]$SecondaryLabel,
        [string]$SecondaryValuePath,
        [string]$SecondarySuffix = ''
    )

    $stats = @()
    $primary = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path $PrimaryValuePath)
    if ($primary -gt 0) { $stats += $PrimaryLabel + ' ' + (Format-SCMiningCompactNumber -Value $primary) }
    $secondary = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path $SecondaryValuePath)
    if ($secondary -gt 0) { $stats += $SecondaryLabel + ' ' + (Format-SCMiningCompactNumber -Value $secondary) + $SecondarySuffix }
    $em = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'emission.em_max')
    if ($em -gt 0) { $stats += 'EM ' + (Format-SCMiningCompactNumber -Value $em) }
    return @($stats -join ' | ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Format-SCMiningWikiQuantumDrivePassportLines {
    param([object]$Entry)

    $stats = @()
    $speed = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'quantum_drive.standard_jump.drive_speed')
    if ($speed -gt 0) { $stats += 'скорость ' + (Format-SCMiningCompactNumber -Value ($speed / 1000.0)) + ' км/с' }
    $spool = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'quantum_drive.standard_jump.spool_up_time')
    if ($spool -gt 0) { $stats += 'разгон ' + (Format-SCMiningNumber -Value $spool) + ' с' }
    $cooldown = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'quantum_drive.standard_jump.cooldown_time')
    if ($cooldown -gt 0) { $stats += 'откат ' + (Format-SCMiningNumber -Value $cooldown) + ' с' }
    $fuel = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'quantum_drive.quantum_fuel_requirement')
    if ($fuel -gt 0) { $stats += 'топливо ' + (Format-SCMiningNumber -Value $fuel) }
    return @($stats -join ' | ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Format-SCMiningWikiEmpPassportLines {
    param([object]$Entry)

    $stats = @()
    $damage = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'emp.distortion_damage')
    if ($damage -gt 0) { $stats += 'дисторшн ' + (Format-SCMiningCompactNumber -Value $damage) }
    $radius = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'emp.emp_radius')
    if ($radius -gt 0) { $stats += 'радиус ' + (Format-SCMiningCompactNumber -Value $radius) + ' м' }
    $charge = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'emp.charge_duration')
    if ($charge -gt 0) { $stats += 'заряд ' + (Format-SCMiningNumber -Value $charge) + ' с' }
    $cooldown = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'emp.cooldown_duration')
    if ($cooldown -gt 0) { $stats += 'откат ' + (Format-SCMiningNumber -Value $cooldown) + ' с' }
    return @($stats -join ' | ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Format-SCMiningWikiQedPassportLines {
    param([object]$Entry)

    $stats = @()
    $jammer = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'quantum_interdiction_generator.jammer_range')
    if ($jammer -gt 0) { $stats += 'подавление ' + (Format-SCMiningCompactNumber -Value $jammer) + ' м' }
    $interdiction = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'quantum_interdiction_generator.pulse.green_zone_check_range')
    if ($interdiction -gt 0) { $stats += 'перехват ' + (Format-SCMiningCompactNumber -Value $interdiction) + ' м' }
    $charge = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'quantum_interdiction_generator.charge_duration')
    if ($charge -gt 0) { $stats += 'заряд ' + (Format-SCMiningNumber -Value $charge) + ' с' }
    $discharge = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $Entry -Path 'quantum_interdiction_generator.discharge_duration')
    if ($discharge -gt 0) { $stats += 'разряд ' + (Format-SCMiningNumber -Value $discharge) + ' с' }
    return @($stats -join ' | ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function ConvertTo-SCMiningItemPassportRecord {
    param(
        [object]$Entry,
        [string]$Kind
    )

    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace([string]$Entry.localName) -or $null -eq $Entry.data) {
        return $null
    }

    $lines = @(Format-SCMiningItemPassportLines -Entry $Entry -Kind $Kind)
    if ($lines.Count -eq 0) {
        return $null
    }

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @([string]$Entry.localName, ([string]$Entry.localName -replace '(?i)_scitem$', ''))) {
        $token = ConvertTo-SCMiningItemPassportToken -Value $candidate
        if (-not [string]::IsNullOrWhiteSpace($token) -and -not $tokens.Contains($token)) {
            $tokens.Add($token)
        }
    }

    return [pscustomobject]@{
        kind = [string]$Kind
        localName = [string]$Entry.localName
        displayName = [string]$Entry.data.name
        shortName = [string]$Entry.data.shortName
        tokens = @($tokens.ToArray())
        blockLines = @($lines)
    }
}

function Format-SCMiningItemPassportLines {
    param(
        [object]$Entry,
        [string]$Kind
    )

    if ($Kind -eq 'weapon') {
        return @(Format-SCMiningWeaponPassportLines -Entry $Entry)
    }
    if ($Kind -eq 'shield') {
        return @(Format-SCMiningComponentPassportLines -Entry $Entry -TypeLabel 'щит' -PrimaryLabel 'прочность' -PrimaryValuePath 'shield.maxShieldHealth' -SecondaryLabel 'реген' -SecondaryValuePath 'shield.maxShieldRegen' -SecondarySuffix '/с')
    }
    if ($Kind -eq 'powerPlant') {
        return @(Format-SCMiningComponentPassportLines -Entry $Entry -TypeLabel 'энергоустановка' -PrimaryLabel 'энергия' -PrimaryValuePath 'resource.online.generation.powerSegment' -SecondaryLabel 'HP' -SecondaryValuePath 'health.hp')
    }
    if ($Kind -eq 'cooler') {
        return @(Format-SCMiningComponentPassportLines -Entry $Entry -TypeLabel 'охладитель' -PrimaryLabel 'охлаждение' -PrimaryValuePath 'resource.online.generation.cooling' -SecondaryLabel 'IR' -SecondaryValuePath 'resource.online.signatureParams.ir.nominalSignature')
    }
    if ($Kind -eq 'qdrive') {
        return @(Format-SCMiningQuantumDrivePassportLines -Entry $Entry)
    }
    if ($Kind -eq 'emp') {
        return @(Format-SCMiningEmpPassportLines -Entry $Entry)
    }
    if ($Kind -eq 'qed') {
        return @(Format-SCMiningQedPassportLines -Entry $Entry)
    }

    return @()
}

function Format-SCMiningWeaponPassportLines {
    param([object]$Entry)

    $data = $Entry.data
    $damage = Get-SCMiningWeaponDamage -Entry $Entry
    $fireRate = Get-SCMiningWeaponFireRate -Entry $Entry
    $dps = if ($damage -gt 0 -and $fireRate -gt 0) { $damage * $fireRate / 60.0 } else { 0 }
    $projectileSpeed = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'ammo.data.speed')
    $ammo = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'ammoContainer.maxAmmoCount')
    $capacitor = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'weapon.regen.maxAmmoLoad')

    $line1 = @()
    if ($dps -gt 0) {
        $line1 += 'DPS ' + (Format-SCMiningNumber -Value $dps)
    }
    if ($damage -gt 0) {
        $line1 += 'урон ' + (Format-SCMiningNumber -Value $damage)
    }

    $line2 = @()
    if ($fireRate -gt 0) {
        $line2 += 'темп ' + (Format-SCMiningNumber -Value $fireRate) + '/мин'
    }
    if ($projectileSpeed -gt 0) {
        $line2 += 'скорость ' + (Format-SCMiningNumber -Value $projectileSpeed) + ' м/с'
    }
    $penetration = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'ammo.data.penetration.basePenetrationDistance')
    if ($penetration -gt 0) {
        $line2 += 'пробитие ' + (Format-SCMiningNumber -Value $penetration) + ' м'
    }
    if ($ammo -gt 0) {
        $line2 += 'боекомплект ' + (Format-SCMiningNumber -Value $ammo)
    }
    elseif ($capacitor -gt 0) {
        $line2 += 'конденсатор ' + (Format-SCMiningNumber -Value $capacitor)
    }

    return @(
        ($line1 -join ' | '),
        ($line2 -join ' | ')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Format-SCMiningComponentPassportLines {
    param(
        [object]$Entry,
        [string]$TypeLabel,
        [string]$PrimaryLabel,
        [string]$PrimaryValuePath,
        [string]$SecondaryLabel,
        [string]$SecondaryValuePath,
        [string]$SecondarySuffix = ''
    )

    $data = $Entry.data
    $stats = @()
    $primary = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path $PrimaryValuePath)
    if ($primary -gt 0) {
        $stats += $PrimaryLabel + ' ' + (Format-SCMiningCompactNumber -Value $primary)
    }
    $secondary = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path $SecondaryValuePath)
    if ($secondary -gt 0) {
        $stats += $SecondaryLabel + ' ' + (Format-SCMiningCompactNumber -Value $secondary) + $SecondarySuffix
    }
    $em = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'resource.online.signatureParams.em.nominalSignature')
    if ($em -gt 0) {
        $stats += 'EM ' + (Format-SCMiningCompactNumber -Value $em)
    }

    return @($stats -join ' | ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Format-SCMiningQuantumDrivePassportLines {
    param([object]$Entry)

    $data = $Entry.data
    $stats = @()
    $driveSpeed = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'qdrive.params.driveSpeed')
    if ($driveSpeed -gt 0) {
        $stats += 'скорость ' + (Format-SCMiningCompactNumber -Value ($driveSpeed / 1000.0)) + ' км/с'
    }
    $spool = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'qdrive.params.spoolUpTime')
    if ($spool -gt 0) {
        $stats += 'разгон ' + (Format-SCMiningNumber -Value $spool) + ' с'
    }
    $cooldown = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'qdrive.params.cooldownTime')
    if ($cooldown -gt 0) {
        $stats += 'откат ' + (Format-SCMiningNumber -Value $cooldown) + ' с'
    }
    $fuel = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'qdrive.quantumFuelRequirement')
    if ($fuel -gt 0) {
        $stats += 'топливо ' + (Format-SCMiningNumber -Value $fuel)
    }

    return @($stats -join ' | ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Format-SCMiningEmpPassportLines {
    param([object]$Entry)

    $data = $Entry.data
    $stats = @()
    $damage = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'emp.distortionDamage')
    if ($damage -gt 0) {
        $stats += 'дисторшн ' + (Format-SCMiningCompactNumber -Value $damage)
    }
    $radius = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'emp.empRadius')
    if ($radius -gt 0) {
        $stats += 'радиус ' + (Format-SCMiningCompactNumber -Value $radius) + ' м'
    }
    $charge = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'emp.chargeTime')
    if ($charge -gt 0) {
        $stats += 'заряд ' + (Format-SCMiningNumber -Value $charge) + ' с'
    }
    $cooldown = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'emp.cooldownTime')
    if ($cooldown -gt 0) {
        $stats += 'откат ' + (Format-SCMiningNumber -Value $cooldown) + ' с'
    }

    return @($stats -join ' | ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Format-SCMiningQedPassportLines {
    param([object]$Entry)

    $data = $Entry.data
    $stats = @()
    $jammer = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'jammer.jammerRange')
    if ($jammer -gt 0) {
        $stats += 'подавление ' + (Format-SCMiningCompactNumber -Value $jammer) + ' м'
    }
    $interdiction = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'interdiction.greenZoneCheckRange')
    if ($interdiction -gt 0) {
        $stats += 'перехват ' + (Format-SCMiningCompactNumber -Value $interdiction) + ' м'
    }
    $charge = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'interdiction.chargeTimeSecs')
    if ($charge -gt 0) {
        $stats += 'заряд ' + (Format-SCMiningNumber -Value $charge) + ' с'
    }
    $discharge = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $data -Path 'interdiction.dischargeTimeSecs')
    if ($discharge -gt 0) {
        $stats += 'разряд ' + (Format-SCMiningNumber -Value $discharge) + ' с'
    }

    return @($stats -join ' | ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function New-SCMiningItemPassportLookup {
    param([object[]]$Records)

    $lookup = @{}
    foreach ($record in @($Records)) {
        foreach ($token in @($record.tokens)) {
            $tokenText = [string]$token
            if (-not [string]::IsNullOrWhiteSpace($tokenText) -and -not $lookup.ContainsKey($tokenText)) {
                $lookup[$tokenText] = $record
            }
        }
    }
    return $lookup
}

function Get-SCMiningItemDescriptionToken {
    param([string]$Key)

    $clean = ([string]$Key).Trim()
    $clean = [regex]::Replace($clean, ',P$', '', 'IgnoreCase')
    $match = [regex]::Match($clean, '^item_Desc_?(.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return ''
    }

    return (ConvertTo-SCMiningItemPassportToken -Value ([string]$match.Groups[1].Value))
}

function ConvertTo-SCMiningItemPassportToken {
    param([AllowEmptyString()][string]$Value)

    $clean = ([string]$Value).Trim()
    $clean = [regex]::Replace($clean, '(?i)_scitem$', '')
    return ([regex]::Replace($clean.ToLowerInvariant(), '[^a-z0-9]', ''))
}

function Set-SCMiningItemPassportBlock {
    param(
        [AllowEmptyString()][string]$Value,
        [object]$Record
    )

    $clean = Remove-SCMiningItemPassportBlock -Value $Value
    $blockLines = @($Record.blockLines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($blockLines.Count -eq 0) {
        return $clean
    }

    $block = (Get-SCMiningItemPassportLabel) + '\n' + (($blockLines | ForEach-Object { [string]$_ }) -join '\n')
    $craftLine = Get-SCMiningExistingItemCraftHintLine -Value $clean
    $wikeloBlock = Get-SCMiningWikeloItemHintBlock -Value $clean
    $base = Trim-SCMiningEncodedTrailingBreaks -Value (Remove-SCMiningWikeloItemHintBlock -Value (Remove-SCMiningItemCraftHint -Value $clean))

    $sections = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($base)) {
        $sections.Add($base)
    }
    if (-not [string]::IsNullOrWhiteSpace($wikeloBlock)) {
        $sections.Add($wikeloBlock)
    }
    if (-not [string]::IsNullOrWhiteSpace($craftLine)) {
        $sections.Add($craftLine)
    }
    $sections.Add($block)

    return (($sections.ToArray()) -join '\n\n').TrimEnd()
}

function Remove-SCMiningItemPassportBlock {
    param([AllowEmptyString()][string]$Value)

    $labelPattern = '(?:' + [regex]::Escape((Get-SCMiningLegacyItemPassportLabel)) + '|' + [regex]::Escape((Get-SCMiningOlderItemPassportLabel)) + '|' + [regex]::Escape((Get-SCMiningItemPassportLabel)) + ')'
    $pattern = '(?:\\n){0,2}(?:<EM[1-5]>)?' + $labelPattern + '(?:</EM[1-5]>)?(?:\\n(?!\\n)[^\\]*){0,4}'
    $source = [string]$Value
    $clean = [regex]::Replace($source, $pattern, '')
    if ($clean -eq $source) {
        return $source
    }

    return (Trim-SCMiningEncodedTrailingBreaks -Value $clean)
}

function Get-SCMiningItemPassportLabel {
    return 'Базовые ТТХ'
}

function Get-SCMiningLegacyItemPassportLabel {
    return 'Базовые ТТХ (Erkul)'
}

function Get-SCMiningOlderItemPassportLabel {
    return 'ТТХ (Erkul)'
}

function Get-SCMiningExistingItemCraftHintLine {
    param([AllowEmptyString()][string]$Value)

    $labelPattern = [regex]::Escape((Get-SCMiningItemCraftHintLabel))
    $pattern = '(?:<EM[1-5]>)?' + $labelPattern + '(?:</EM[1-5]>)?\s*[^\\]*(?=$|\\n)'
    $match = [regex]::Match([string]$Value, $pattern)
    if (-not $match.Success) {
        return ''
    }

    return ([string]$match.Value).Trim()
}

function Get-SCMiningPropertyValue {
    param(
        [object]$Object,
        [string]$Path
    )

    $current = $Object
    foreach ($part in ([string]$Path -split '\.')) {
        if ($null -eq $current) {
            return $null
        }

        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) {
            return $null
        }

        $current = $property.Value
    }

    return $current
}

function ConvertTo-SCMiningArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return @($Value)
    }
    return @($Value)
}

function Get-SCMiningNumber {
    param($Value)

    if ($null -eq $Value) {
        return 0.0
    }

    $number = 0.0
    $text = ([string]$Value).Trim()
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    if ([double]::TryParse($text, [ref]$number)) {
        return $number
    }

    return 0.0
}

function Format-SCMiningSize {
    param($Value)

    $number = Get-SCMiningNumber -Value $Value
    if ($number -lt 0) {
        return ''
    }

    return 'S' + (Format-SCMiningNumber -Value $number)
}

function Format-SCMiningNumber {
    param([double]$Value)

    $absValue = [Math]::Abs($Value)
    if ($absValue -gt 0 -and $absValue -lt 1) {
        return $Value.ToString('0.#####', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ([Math]::Abs($Value - [Math]::Round($Value)) -lt 0.05) {
        return ([Math]::Round($Value)).ToString('0', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return $Value.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-SCMiningCompactNumber {
    param([double]$Value)

    if ([Math]::Abs($Value) -ge 1000000) {
        return (Format-SCMiningNumber -Value ($Value / 1000000.0)) + 'M'
    }
    if ([Math]::Abs($Value) -ge 1000) {
        return (Format-SCMiningNumber -Value ($Value / 1000.0)) + 'K'
    }

    return (Format-SCMiningNumber -Value $Value)
}

function Get-SCMiningWeaponDamage {
    param([object]$Entry)

    $damage = Get-SCMiningPropertyValue -Object $Entry.data -Path 'ammo.data.damage'
    if ($null -eq $damage) {
        return 0.0
    }

    $sum = 0.0
    foreach ($property in @($damage.PSObject.Properties)) {
        if ([string]$property.Name -match '^damage') {
            $sum += Get-SCMiningNumber -Value $property.Value
        }
    }

    $pelletCount = 1.0
    $damageMultiplier = 1.0
    $fireActions = @(ConvertTo-SCMiningArray (Get-SCMiningPropertyValue -Object $Entry.data -Path 'weapon.fireActions'))
    foreach ($action in $fireActions) {
        $rate = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $action -Path 'fireRate')
        if ($rate -le 0) {
            continue
        }

        $actionPellets = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $action -Path 'pelletCount')
        if ($actionPellets -gt 0) {
            $pelletCount = $actionPellets
        }
        $actionMultiplier = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $action -Path 'damageMultiplier')
        if ($actionMultiplier -gt 0) {
            $damageMultiplier = $actionMultiplier
        }

        break
    }

    return ($sum * $pelletCount * $damageMultiplier)
}

function Get-SCMiningWeaponFireRate {
    param([object]$Entry)

    $fireActions = @(ConvertTo-SCMiningArray (Get-SCMiningPropertyValue -Object $Entry.data -Path 'weapon.fireActions'))
    $maximum = 0.0
    foreach ($action in $fireActions) {
        $rate = Get-SCMiningNumber -Value (Get-SCMiningPropertyValue -Object $action -Path 'fireRate')
        if ($rate -gt $maximum) {
            $maximum = $rate
        }
    }

    return $maximum
}

function ConvertTo-SCMiningWeaponGroupLabel {
    param([AllowEmptyString()][string]$Group)

    $key = ([string]$Group).Trim().ToLowerInvariant()
    $map = @{
        'laser repeater' = 'лазерный повторитель'
        'laser cannon' = 'лазерная автопушка'
        'laser scattergun' = 'лазерный дробовик'
        'laser beam' = 'лазерный луч'
        'ballistic repeater' = 'баллистический повторитель'
        'ballistic cannon' = 'баллистическая автопушка'
        'ballistic gatling' = 'баллистический гатлинг'
        'ballistic scattergun' = 'баллистический дробовик'
        'distortion repeater' = 'дисторшн-повторитель'
        'distortion cannon' = 'дисторшн-автопушка'
        'distortion scattergun' = 'дисторшн-дробовик'
        'mass driver' = 'ускоритель массы'
        'tachyon cannon' = 'тахионная автопушка'
    }

    if ($map.ContainsKey($key)) {
        return $map[$key]
    }

    return ([string]$Group).Trim()
}

function ConvertTo-SCMiningComponentClassLabel {
    param([AllowEmptyString()][string]$Class)

    $key = ([string]$Class).Trim().ToLowerInvariant()
    $map = @{
        'civilian' = 'гражданский'
        'competition' = 'соревновательный'
        'industrial' = 'промышленный'
        'military' = 'военный'
        'stealth' = 'стелс'
    }

    if ($map.ContainsKey($key)) {
        return $map[$key]
    }

    return ([string]$Class).Trim()
}

function ConvertTo-SCMiningComponentClassCode {
    param([AllowEmptyString()][string]$Class)

    $key = ([string]$Class).Trim().ToLowerInvariant()
    $map = @{
        'civilian' = 'CIV'
        'competition' = 'COM'
        'industrial' = 'IND'
        'military' = 'MIL'
        'stealth' = 'STE'
    }

    if ($map.ContainsKey($key)) {
        return $map[$key]
    }

    return ''
}

function Get-SCMiningComponentResourceFamilyKey {
    param([string[]]$Resources)

    $parts = @(
        @($Resources) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object {
                $clean = ([string]$_).Trim().ToLowerInvariant()
                [regex]::Replace($clean, '[^a-z0-9]+', '-').Trim('-')
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )

    return ($parts -join '+')
}

function Get-SCMiningSafeCacheKey {
    param([string]$CacheKey)

    return [regex]::Replace([string]$CacheKey, '[^A-Za-z0-9._-]', '_')
}

function Get-SCMiningCraftFamilyIndexCachePath {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    return (Join-Path $cacheDir ("craft-family-index-{0}.json" -f (Get-SCMiningSafeCacheKey -CacheKey $CacheKey)))
}

function New-SCMiningCraftFamilyOptionId {
    param([object]$Recipe)

    return ('craftFamily|{0}|{1}|{2}' -f [string]$Recipe.Category, [string]$Recipe.Subcategory, [string]$Recipe.Family.Key)
}

function Write-SCMiningCraftFamilyIndexCache {
    param(
        [string]$CacheKey,
        [object[]]$Blueprints
    )

    $planetCraftMap = New-SCMiningPlanetCraftMap -Blueprints @($Blueprints)
    $groups = @{}

    foreach ($recipe in @($planetCraftMap.Values)) {
        if ($recipe.Category -eq (Get-SCMiningPlanetCategoryShipComponents) -and ([string]$recipe.ComponentGrade) -ne 'A') {
            continue
        }

        $optionId = New-SCMiningCraftFamilyOptionId -Recipe $recipe
        if (-not $groups.ContainsKey($optionId)) {
            $groups[$optionId] = [pscustomobject]@{
                optionId = $optionId
                category = [string]$recipe.Category
                subcategory = [string]$recipe.Subcategory
                familyKey = [string]$recipe.Family.Key
                familyType = [string]$recipe.Family.Family
                label = [string]$recipe.Family.Label
                sortLabel = [string]$recipe.Family.Label
                defaultSelected = $false
                names = New-Object System.Collections.Generic.List[string]
                resources = @{}
                tokens = New-Object System.Collections.Generic.List[object]
            }
        }

        $groups[$optionId].names.Add([string]$recipe.Name)
        if ($null -ne $recipe.Family.Token) {
            $groups[$optionId].tokens.Add($recipe.Family.Token)
        }
        foreach ($resource in @($recipe.Resources)) {
            $groups[$optionId].resources[[string]$resource] = $true
        }
    }

    $families = @(foreach ($group in @($groups.Values)) {
        $displayGroup = [pscustomobject]@{
            Label = [string]$group.label
            Family = [string]$group.familyType
            Names = @($group.names.ToArray())
            Tokens = @($group.tokens.ToArray())
        }
        [pscustomobject]@{
            optionId = [string]$group.optionId
            category = [string]$group.category
            subcategory = [string]$group.subcategory
            familyKey = [string]$group.familyKey
            label = (Format-SCMiningPlanetRecipeFamilyLabel -Group $displayGroup)
            sortLabel = [string]$group.sortLabel
            defaultSelected = [bool]$group.defaultSelected
            names = @($group.names.ToArray() | Sort-Object -Unique)
            resources = @($group.resources.Keys | Sort-Object -Unique)
        }
    }

    )
    $families += @(Get-SCMiningQuestOnlyRewardFamilies -CacheKey $CacheKey -ExistingFamilies $families)
    $payload = [pscustomobject]@{
        cacheKey = [string]$CacheKey
        createdAt = (Get-Date).ToString('o')
        shipComponentGradeFilter = 'A' 
        families = @(
            $families |
                Sort-Object `
                    @{ Expression = { [array]::IndexOf((Get-SCMiningPlanetCategoryOrder), [string]$_.category) } },
                    @{ Expression = { Get-SCMiningPlanetSubcategoryRank -Category ([string]$_.category) -Subcategory ([string]$_.subcategory) } },
                    label
        )
    }

    $cachePath = Get-SCMiningCraftFamilyIndexCachePath -CacheKey $CacheKey
    $cacheDir = Split-Path -Parent $cachePath
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    }

    $json = $payload | ConvertTo-Json -Depth 10
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cachePath, $json, $encoding)
    return $cachePath
}

function Get-SCMiningQuestOnlyRewardFamilies {
    param([string]$CacheKey, [object[]]$ExistingFamilies)

    $path = Join-Path $PSScriptRoot 'data\quest-reward-families.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $scmdb = Read-SCMiningScmdbCache
    if ($null -eq $scmdb -or $scmdb.Version -ne $CacheKey) { return @() }
    $rewards = @(Get-SCMiningScmdbRewardBlueprintRecords -Scmdb $scmdb.Data)
    $knownNames = @{}
    foreach ($entry in @($ExistingFamilies)) {
        foreach ($name in @($entry.names)) { $knownNames[[string]$name] = $true }
    }
    $definitions = Get-Content -LiteralPath $path -Encoding UTF8 -Raw | ConvertFrom-Json
    foreach ($definition in @($definitions)) {
        $names = @($rewards | Where-Object { @($definition.blueprintRecords) -contains [string]$_.blueprintRecord -and -not $knownNames.ContainsKey([string]$_.name) } | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
        if ($names.Count -eq 0) { continue }
        [pscustomobject]@{
            optionId = 'craftFamily|' + [string]$definition.category + '|' + [string]$definition.subcategory + '|' + [string]$definition.familyKey
            category = [string]$definition.category
            subcategory = [string]$definition.subcategory
            familyKey = [string]$definition.familyKey
            label = [string]$definition.label
            sortLabel = [string]$definition.label
            defaultSelected = $false
            names = @($names)
            resources = @()
            questOnly = $true
        }
    }
}

function New-SCMiningPlanetCraftMap {
    param([object[]]$Blueprints)

    $result = @{}
    $itemLookup = Get-SCMiningCachedItemInfoLookup
    foreach ($blueprint in @($Blueprints)) {
        $name = Get-SCMiningBlueprintOutputName -Blueprint $blueprint -Reward $null
        $unresolvedName = [string]::IsNullOrWhiteSpace($name)
        if ($unresolvedName) { $name = Get-SCMiningUnnamedRecipeLabel -Blueprint $blueprint }
        if ([string]::IsNullOrWhiteSpace($name) -or (Test-SCMiningIgnoredCraftName -Name $name)) {
            continue
        }

        $resources = @(Get-SCMiningBlueprintResourceNames -Blueprint $blueprint | ForEach-Object { Normalize-SCMiningResourceName -Name $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($resources.Count -eq 0) {
            continue
        }

        $category = Get-SCMiningPlanetBlueprintCategory -Blueprint $blueprint
        if ([string]::IsNullOrWhiteSpace($category)) {
            continue
        }

        $subcategory = Get-SCMiningPlanetBlueprintSubcategory -Blueprint $blueprint -Category $category
        $componentGrade = Get-SCMiningBlueprintOutputGrade -Blueprint $blueprint -ItemLookup $itemLookup
        $componentClass = Get-SCMiningBlueprintOutputComponentClass -Blueprint $blueprint -ItemLookup $itemLookup
        $key = if (-not [string]::IsNullOrWhiteSpace([string]$blueprint.uuid)) { [string]$blueprint.uuid } else { [string]$blueprint.key }
        $family = Get-SCMiningPlanetRecipeFamily -Name $name -Category $category -Subcategory $subcategory -Resources @($resources) -ComponentGrade $componentGrade -ComponentClass $componentClass
        if (Test-SCMiningUnlocalizedRecipeIdentity -Blueprint $blueprint) {
            # Preserve the choice even if the source later supplies an official name.
            $family = [pscustomobject]@{ Key = ('component:record:' + $key); Label = $name; Family = 'exact'; Token = $null }
        }
        $result[$key] = [pscustomobject]@{
            Name = $name
            Category = $category
            Subcategory = $subcategory
            Family = $family
            UnresolvedName = $unresolvedName
            Resources = @($resources)
            ComponentGrade = $componentGrade
            ComponentClass = $componentClass
        }
    }

    return $result
}

function Test-SCMiningUnlocalizedRecipeIdentity {
    param([object]$Blueprint)
    # Exact identities with product cards but absent native/RuSC localization.
    # Pioneer is excluded: it has no product identity or verified grade.
    return ($Blueprint.source -eq 'SCMDB' -and [string]$Blueprint.uuid -in @(
        '3c10e4f9-a125-4171-acfc-b9b51c5b19e1',
        '8a4f43a8-5f3d-4557-9756-01e1e77fbc2c',
        '7ab8c5b1-2b1c-4388-8931-ad2aefa812e3',
        'c0226b4d-3829-487c-8bf0-7d47f36ae867'
    ))
}

function Get-SCMiningUnnamedRecipeLabel {
    param([object]$Blueprint)
    if (-not (Test-SCMiningUnlocalizedRecipeIdentity -Blueprint $Blueprint)) { return $null }
    $type = Get-SCMiningBlueprintOutputType -Blueprint $Blueprint
    $labels = @{ Cooler = 'Охладитель'; Radar = 'Радар' }
    if (-not $labels.ContainsKey($type) -or [int]$Blueprint.output.size -le 0) { return $null }
    $class = (Get-SCMiningBlueprintOutputClass -Blueprint $Blueprint -Reward $null) -replace '(?i)_SCItem$', ''
    if ($class -notmatch '(?i)^(?:COOL|RADR)_[A-Z0-9]+_S0*(\d+)_(.+)$') { return $null }
    if ([int]$Matches[1] -ne [int]$Blueprint.output.size) { return $null }
    $descriptor = $Matches[2] -replace '_', ' '
    return ('{0} S{1} ({2}; без игрового имени)' -f $labels[$type], [int]$Blueprint.output.size, $descriptor)
}

function Test-SCMiningIgnoredCraftName {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }

    $clean = ([string]$Name).Trim()
    return ($clean -match '^<=\s*PLACEHOLDER\s*=>$' -or $clean -match '(?i)\bplaceholder\b')
}

function New-SCMiningPlanetCraftIndex {
    param(
        [hashtable]$PlanetCraftMap,
        [object]$CraftFilter
    )

    $byResource = @{}
    foreach ($entry in $PlanetCraftMap.GetEnumerator()) {
        $recipe = $entry.Value
        if (-not (Test-SCMiningIncludePlanetRecipe -Recipe $recipe -CraftFilter $CraftFilter)) {
            continue
        }
        foreach ($resource in @($recipe.Resources)) {
            $resourceKey = [string]$resource
            if ([string]::IsNullOrWhiteSpace($resourceKey)) {
                continue
            }
            if (-not $byResource.ContainsKey($resourceKey)) {
                $byResource[$resourceKey] = New-Object System.Collections.Generic.List[object]
            }
            $byResource[$resourceKey].Add([pscustomobject]@{
                RecipeKey = [string]$entry.Key
                Recipe = $recipe
            })
        }
    }

    return [pscustomobject]@{
        ByResource = $byResource
    }
}

function Format-SCMiningPlanetCraftBlock {
    param(
        [object]$Inventory,
        [hashtable]$PlanetCraftMap,
        [AllowNull()][object]$PlanetCraftIndex,
        [string[]]$SelectedMethods,
        [object]$CraftFilter,
        [switch]$BodyOnly
    )

    if ($null -eq $Inventory -or (-not $BodyOnly -and ($null -eq $PlanetCraftMap -or $PlanetCraftMap.Count -eq 0))) {
        return ''
    }

    $body = New-Object System.Collections.Generic.List[string]
    foreach ($method in Get-SCMiningMethodOrder) {
        $methodResources = @(Expand-SCMiningResourceEntries -Entries $Inventory.ResourcesByMethod[$method] | ForEach-Object { Normalize-SCMiningResourceName -Name $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($methodResources.Count -eq 0) {
            continue
        }

        if ($body.Count -gt 0) {
            $body.Add('')
        }
        $body.Add('<EM4>' + (Get-SCMiningReferenceLabel -Method $method) + '</EM4>')
        $resourceText = Format-SCMiningResourceEntriesForDisplay -Entries $Inventory.ResourcesByMethod[$method]

        if ($method -in $SelectedMethods -and $null -ne $PlanetCraftMap -and $PlanetCraftMap.Count -gt 0) {
            $methodLines = @(Format-SCMiningPlanetMethodRecipeLines -Method $method -Inventory $Inventory -PlanetCraftMap $PlanetCraftMap -PlanetCraftIndex $PlanetCraftIndex -CraftFilter $CraftFilter)
            if ($methodLines.Count -gt 0) {
                $body.Add((Get-SCMiningResourceListLabel) + ' ' + $resourceText)
                $body.Add('')
                foreach ($line in $methodLines) {
                    $body.Add($line)
                }
                continue
            }
        }

        $body.Add($resourceText)
    }

    if ($body.Count -eq 0) {
        return ''
    }

    if ($BodyOnly) {
        return (($body.ToArray()) -join '\n').TrimEnd()
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-SCMiningCraftHeader))
    $lines.Add((Get-SCMiningPlanetTextFilters -SelectedMethods $SelectedMethods))
    $lines.Add('')
    foreach ($line in $body) {
        $lines.Add($line)
    }

    return (($lines.ToArray()) -join '\n').TrimEnd()
}

function Format-SCMiningPlanetMethodRecipeLines {
    param(
        [string]$Method,
        [object]$Inventory,
        [hashtable]$PlanetCraftMap,
        [AllowNull()][object]$PlanetCraftIndex,
        [object]$CraftFilter
    )

    $methodResources = @{}
    foreach ($resource in @(Expand-SCMiningResourceEntries -Entries $Inventory.ResourcesByMethod[$Method])) {
        $normalized = Normalize-SCMiningResourceName -Name $resource
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $methodResources[$normalized] = $true
        }
    }
    if ($methodResources.Count -eq 0) {
        return @()
    }

    $candidateRecipes = $PlanetCraftMap
    if ($null -ne $PlanetCraftIndex -and $null -ne $PlanetCraftIndex.ByResource) {
        $candidateRecipes = @{}
        foreach ($resource in $methodResources.Keys) {
            $resourceKey = [string]$resource
            if (-not $PlanetCraftIndex.ByResource.ContainsKey($resourceKey)) {
                continue
            }
            foreach ($indexedRecipe in $PlanetCraftIndex.ByResource[$resourceKey].ToArray()) {
                $candidateRecipes[[string]$indexedRecipe.RecipeKey] = $indexedRecipe.Recipe
            }
        }
    }

    $body = New-Object System.Collections.Generic.List[string]
    foreach ($category in Get-SCMiningPlanetCategoryOrder) {
        $categoryRecipes = @($candidateRecipes.Values | Where-Object { $_.Category -eq $category } | Sort-Object Name)
        if ($categoryRecipes.Count -eq 0) {
            continue
        }

        $groupMap = @{}
        foreach ($recipe in $categoryRecipes) {
            if ($null -eq $PlanetCraftIndex -and -not (Test-SCMiningIncludePlanetRecipe -Recipe $recipe -CraftFilter $CraftFilter)) {
                continue
            }

            $resources = New-Object System.Collections.Generic.List[string]
            foreach ($resource in @($recipe.Resources)) {
                if ($methodResources.ContainsKey($resource)) {
                    $resources.Add($resource)
                }
            }

            if ($resources.Count -eq 0) {
                continue
            }

            $family = $recipe.Family
            $groupKey = "$($recipe.Category)|$($recipe.Subcategory)|$($family.Key)"
            if (-not $groupMap.ContainsKey($groupKey)) {
                $groupMap[$groupKey] = [pscustomobject]@{
                    Label = $family.Label
                    Family = $family.Family
                    SortLabel = $family.Label
                    Subcategory = $recipe.Subcategory
                    Resources = @{}
                    Tokens = New-Object System.Collections.Generic.List[object]
                    Names = New-Object System.Collections.Generic.List[string]
                }
            }

            foreach ($resource in @($resources | Sort-Object -Unique)) {
                $groupMap[$groupKey].Resources[$resource] = $true
            }
            $groupMap[$groupKey].Names.Add([string]$recipe.Name)
            if ($null -ne $family.Token) {
                $groupMap[$groupKey].Tokens.Add($family.Token)
            }
        }

        if ($groupMap.Count -eq 0) {
            continue
        }

        $body.Add('<EM4>' + $category + '</EM4>')
        $subgroups = @($groupMap.Values | Group-Object -Property Subcategory | Sort-Object { Get-SCMiningPlanetSubcategoryRank -Category $category -Subcategory ([string]$_.Name) }, Name)
        foreach ($subgroup in $subgroups) {
            $subcategory = if ([string]::IsNullOrWhiteSpace([string]$subgroup.Name)) { Get-SCMiningPlanetTextOther } else { [string]$subgroup.Name }
            if ($subcategory -ne '__none') {
                $body.Add('<EM4>' + $subcategory + ':</EM4>')
            }

            foreach ($group in @($subgroup.Group | Sort-Object SortLabel)) {
                $label = Format-SCMiningPlanetRecipeFamilyLabel -Group $group
                $resourceText = ((@($group.Resources.Keys) | Sort-Object -Unique) -join ', ')
                $body.Add("- ${label}: $resourceText")
            }
        }
        $body.Add('')
    }

    while ($body.Count -gt 0 -and [string]::IsNullOrWhiteSpace($body[$body.Count - 1])) {
        $body.RemoveAt($body.Count - 1)
    }

    if ($body.Count -eq 0) {
        return @()
    }

    return @($body.ToArray())
}

function New-SCMiningResourceMethodLookup {
    param([object]$Inventory)

    $lookup = @{}
    foreach ($method in Get-SCMiningMethodOrder) {
        foreach ($resource in Expand-SCMiningResourceEntries -Entries $Inventory.ResourcesByMethod[$method]) {
            $normalized = Normalize-SCMiningResourceName -Name $resource
            if ([string]::IsNullOrWhiteSpace($normalized)) {
                continue
            }
            if (-not $lookup.ContainsKey($normalized)) {
                $lookup[$normalized] = @{}
            }
            $lookup[$normalized][$method] = $true
        }
    }

    return $lookup
}

function Normalize-SCMiningResourceName {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $clean = (($Name -replace '\\n', ' ') -replace '\s+\d+(?:[\.,]\d+)?%$', '' -replace '\s*\([^)]*\)\s*$', '').Trim()
    $aliases = @{
        'Alumium' = 'Aluminum'
        'Aluminium' = 'Aluminum'
        'Raw Ice' = 'Ice'
        'Raw Silicon' = 'Silicon'
    }
    if ($aliases.ContainsKey($clean)) {
        return $aliases[$clean]
    }

    return $clean
}

function Format-SCMiningResourceEntriesForDisplay {
    param($Entries)

    $seen = @{}
    $display = New-Object System.Collections.Generic.List[string]
    foreach ($entry in Expand-SCMiningResourceEntries -Entries $Entries) {
        $normalized = Normalize-SCMiningResourceName -Name $entry
        if ([string]::IsNullOrWhiteSpace($normalized) -or $seen.ContainsKey($normalized)) {
            continue
        }

        $seen[$normalized] = $true
        $display.Add(([string]$entry).Trim())
    }

    return (($display.ToArray()) -join ', ')
}

function Get-SCMiningInventorySignature {
    param([object]$Inventory)

    if ($null -eq $Inventory) {
        return ''
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($method in Get-SCMiningMethodOrder) {
        $entries = @(Expand-SCMiningResourceEntries -Entries $Inventory.ResourcesByMethod[$method] | Sort-Object)
        $parts.Add($method + '=' + ($entries -join ','))
    }
    $parts.Add('collect=' + (@(Expand-SCMiningResourceEntries -Entries $Inventory.CollectableResources | Sort-Object) -join ','))
    $parts.Add('creature=' + (@(Expand-SCMiningResourceEntries -Entries $Inventory.CreatureResources | Sort-Object) -join ','))

    return ($parts.ToArray() -join ';')
}

function Get-SCMiningPlanetCategoryOrder {
    return @(
        (Get-SCMiningPlanetCategoryShipComponents),
        (Get-SCMiningPlanetCategoryShipWeapons),
        (Get-SCMiningPlanetCategoryMiningEquipment),
        (Get-SCMiningPlanetCategoryArmor),
        (Get-SCMiningPlanetCategoryWeapons)
    )
}

function Get-SCMiningPlanetBlueprintCategory {
    param([object]$Blueprint)

    $type = Get-SCMiningBlueprintOutputType -Blueprint $Blueprint
    if ($type -in @('Shield', 'Quantum Drive', 'Power Plant', 'Cooler', 'Radar')) {
        return (Get-SCMiningPlanetCategoryShipComponents)
    }
    if ($type -eq 'Weapon Mining') {
        return (Get-SCMiningPlanetCategoryMiningEquipment)
    }
    if ($type -in @('Mining Modifier', 'Salvage Modifier') -or ($type -eq 'Container' -and (Get-SCMiningBlueprintOutputName -Blueprint $Blueprint -Reward $null) -match '(?i)\bOre\s+Pod$')) {
        return (Get-SCMiningPlanetCategoryMiningEquipment)
    }
    if ($type -eq 'Weapon Gun') {
        return (Get-SCMiningPlanetCategoryShipWeapons)
    }
    if ($type -match '\(Armor\)$' -or $type -eq 'Undersuit (Armor)' -or $type -eq 'Backpack (Armor)') {
        return (Get-SCMiningPlanetCategoryArmor)
    }
    if ($type -in @('Jacket', 'Shirt', 'Legs', 'Shoes', 'Clothing')) {
        return (Get-SCMiningPlanetCategoryArmor)
    }
    if ($type -eq 'FPS Weapon') {
        return (Get-SCMiningPlanetCategoryWeapons)
    }
    return $null
}

function Get-SCMiningPlanetBlueprintSubcategory {
    param(
        [object]$Blueprint,
        [string]$Category
    )

    $type = Get-SCMiningBlueprintOutputType -Blueprint $Blueprint
    $name = Get-SCMiningBlueprintOutputName -Blueprint $Blueprint -Reward $null
    $outputClass = Get-SCMiningBlueprintOutputClass -Blueprint $Blueprint -Reward $null
    if ($Category -eq (Get-SCMiningPlanetCategoryShipComponents)) {
        $map = @{
            'Shield' = (Get-SCMiningPlanetSubcategoryShields)
            'Quantum Drive' = (Get-SCMiningPlanetSubcategoryQuantumDrives)
            'Power Plant' = (Get-SCMiningPlanetSubcategoryPowerPlants)
            'Cooler' = (Get-SCMiningPlanetSubcategoryCoolers)
            'Radar' = (Get-SCMiningPlanetSubcategoryRadars)
        }
        if ($map.ContainsKey($type)) { return $map[$type] }
        return (Get-SCMiningPlanetTextOther)
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryShipWeapons)) {
        if ($name -match '(?i)mass driver|sledge|strife') { return (Get-SCMiningPlanetSubcategoryHybrid) }
        # SCMDB's laser subtype takes precedence over the generic Gatling name.
        # The name check also keeps legacy recipe inputs in the correct category.
        if ([string]$Blueprint.output.weaponSubtype -eq 'laser' -or $name -match '(?i)\blaser\b') { return (Get-SCMiningPlanetSubcategoryEnergy) }
        if ([string]$Blueprint.output.weaponSubtype -eq 'ballistic') { return (Get-SCMiningPlanetSubcategoryBallistics) }
        if ($name -match '(?i)ballistic|gatling|deadbolt|c-788|tarantula|tigerstrike|sword|draugar|mantis|revenant|scorpion|sw16br') { return (Get-SCMiningPlanetSubcategoryBallistics) }
        return (Get-SCMiningPlanetSubcategoryEnergy)
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryMiningEquipment)) {
        if ($type -eq 'Weapon Mining') { return (Get-SCMiningPlanetSubcategoryMiningLasers) }
        if ($type -eq 'Mining Modifier') { return (Get-SCMiningPlanetSubcategoryMiningModules) }
        if ($type -eq 'Salvage Modifier') { return 'Модули утилизации' }
        if ($type -eq 'Container') { return (Get-SCMiningPlanetSubcategoryOrePods) }
        return (Get-SCMiningPlanetTextOther)
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryArmor)) {
        if ($outputClass -match '(?i)(?:^|_)superheavy(?:_|$)') {
            return (Get-SCMiningPlanetSubcategorySuperHeavyArmor)
        }
        if ($type -eq 'Helmet (Armor)' -or $type -eq 'Torso (Armor)' -or $type -eq 'Arms (Armor)' -or $type -eq 'Legs (Armor)' -or $type -eq 'Backpack (Armor)') {
            if ($outputClass -match '(?i)(?:^|_)heavy(?:_|$)') { return (Get-SCMiningPlanetSubcategoryHeavyArmor) }
            if ($outputClass -match '(?i)(?:^|_)medium(?:_|$)') { return (Get-SCMiningPlanetSubcategoryMediumArmor) }
            if ($outputClass -match '(?i)(?:^|_)light(?:_|$)') { return (Get-SCMiningPlanetSubcategoryLightArmor) }
            if ($name -match '(?i)heavy|morozov|citadel|adp|antium|pembroke|overlord|palatino|stirling|defiance|dust devil|manticore|fortifier|balor') { return (Get-SCMiningPlanetSubcategoryHeavyArmor) }
            if ($name -match '(?i)medium|orc|artimex|aril|inquisitor|testudo|strata|aves|dustup|g-2|morningstar') { return (Get-SCMiningPlanetSubcategoryMediumArmor) }
            return (Get-SCMiningPlanetSubcategoryLightArmor)
        }
        if ($type -eq 'Undersuit (Armor)') { return (Get-SCMiningPlanetSubcategoryUndersuits) }
        if ($type -in @('Jacket', 'Shirt', 'Legs', 'Shoes', 'Clothing')) { return (Get-SCMiningPlanetSubcategoryUndersuits) }
        return (Get-SCMiningPlanetTextOther)
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryWeapons)) {
        if ($name -match '(?i)sniper|arrowhead|a03|p6-lr|scalpel|atzkav|zenith') { return (Get-SCMiningPlanetSubcategorySniperRifles) }
        if ($name -match '(?i)\bsmg\b|custodian|lumin|p8-sc|ripper|c54') { return (Get-SCMiningPlanetSubcategorySmgs) }
        if ($name -match '(?i)\bhmg\b') { return (Get-SCMiningPlanetSubcategoryHmgs) }
        if ($name -match '(?i)\blmg\b|f55|fs-9|fresnel|pulverizer') { return (Get-SCMiningPlanetSubcategoryLmgs) }
        if ($name -match '(?i)pistol|salvo|coda|lh86|s-38|pulse') { return (Get-SCMiningPlanetSubcategoryPistols) }
        if ($name -match '(?i)shotgun|br-2|ravager|devastator') { return (Get-SCMiningPlanetSubcategoryShotguns) }
        return (Get-SCMiningPlanetSubcategoryRifles)
    }

    return '__none'
}

function Get-SCMiningPlanetSubcategoryRank {
    param(
        [string]$Category,
        [string]$Subcategory
    )

    $orders = @{
        (Get-SCMiningPlanetCategoryShipComponents) = @((Get-SCMiningPlanetSubcategoryShields), (Get-SCMiningPlanetSubcategoryQuantumDrives), (Get-SCMiningPlanetSubcategoryPowerPlants), (Get-SCMiningPlanetSubcategoryCoolers), (Get-SCMiningPlanetSubcategoryRadars), (Get-SCMiningPlanetTextOther))
        (Get-SCMiningPlanetCategoryShipWeapons) = @((Get-SCMiningPlanetSubcategoryEnergy), (Get-SCMiningPlanetSubcategoryBallistics), (Get-SCMiningPlanetSubcategoryHybrid), (Get-SCMiningPlanetSubcategoryMiningLasers), (Get-SCMiningPlanetTextOther))
        (Get-SCMiningPlanetCategoryMiningEquipment) = @((Get-SCMiningPlanetSubcategoryMiningLasers), (Get-SCMiningPlanetSubcategoryMiningModules), 'Модули утилизации', (Get-SCMiningPlanetSubcategoryOrePods), (Get-SCMiningPlanetTextOther))
        (Get-SCMiningPlanetCategoryArmor) = @((Get-SCMiningPlanetSubcategorySuperHeavyArmor), (Get-SCMiningPlanetSubcategoryHeavyArmor), (Get-SCMiningPlanetSubcategoryMediumArmor), (Get-SCMiningPlanetSubcategoryLightArmor), (Get-SCMiningPlanetSubcategoryUndersuits), (Get-SCMiningPlanetTextOther))
        (Get-SCMiningPlanetCategoryWeapons) = @((Get-SCMiningPlanetSubcategoryRifles), (Get-SCMiningPlanetSubcategorySniperRifles), (Get-SCMiningPlanetSubcategorySmgs), (Get-SCMiningPlanetSubcategoryLmgs), (Get-SCMiningPlanetSubcategoryHmgs), (Get-SCMiningPlanetSubcategoryPistols), (Get-SCMiningPlanetSubcategoryShotguns), (Get-SCMiningPlanetTextOther))
    }
    if (-not $orders.ContainsKey($Category)) {
        return 999
    }

    $index = [array]::IndexOf($orders[$Category], $Subcategory)
    if ($index -lt 0) { return 999 }
    return $index
}

function Get-SCMiningAllCraftFilterOptionIds {
    return @(
        'componentClassMilitary',
        'componentClassStealth',
        'componentClassCompetition',
        'componentClassCivilian',
        'componentClassIndustrial',
        'shipWeaponEnergy',
        'shipWeaponBallistic',
        'shipWeaponHybrid',
        'shipWeaponMiningLaser',
        'armorSuperHeavy',
        'armorHeavy',
        'armorMedium',
        'armorLight',
        'armorSuits',
        'fpsRifles',
        'fpsSniperRifles',
        'fpsSmgs',
        'fpsLmgs',
        'fpsHmgs',
        'fpsPistols',
        'fpsShotguns'
    )
}

function New-SCMiningStringSet {
    param([string[]]$Values)

    $set = @{}
    foreach ($value in @($Values)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $set[[string]$value] = $true
        }
    }
    return $set
}

function Test-SCMiningSetContains {
    param(
        [hashtable]$Set,
        [AllowEmptyString()][string]$Value
    )

    return ($null -ne $Set -and $Set.ContainsKey([string]$Value))
}

function Get-SCMiningCraftFamilyIndex {
    $cacheFile = $null
    try {
        $scmdb = Read-SCMiningScmdbCache
        $expectedPath = Get-SCMiningCraftFamilyIndexCachePath -CacheKey ([string]$scmdb.Version)
        if (Test-Path -LiteralPath $expectedPath -PathType Leaf) {
            $cacheFile = Get-Item -LiteralPath $expectedPath
        }
    }
    catch {
        $cacheFile = $null
    }

    if ($null -eq $cacheFile) {
        $cacheDir = Get-SCMiningCacheDirectory
        $cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'craft-family-index-*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)-live\.' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    if ($null -eq $cacheFile) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $cacheFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-SCMiningLegacyCraftFamilyKeysForName {
    param(
        [AllowEmptyString()][string]$Name,
        [AllowEmptyString()][string]$Category
    )

    $label = ([string]$Name).Trim()
    $keys = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($label)) {
        $keys.Add("exact:$label")
    }

    if ($Category -eq (Get-SCMiningPlanetCategoryShipComponents)) {
        if ($label -match '^FR-(66|76|86)$') { $keys.Add('component:FR-series') }
        if ($label -match '^FullSpec(?:-(Go|Max))?$') { $keys.Add('component:FullSpec') }
        if ($label -match '^(SnowBlind|NightFall)$') { $keys.Add('component:SnowBlind-NightFall') }
        if ($label -match '^QuadraCell(?:\s+(MT|MX))?$') { $keys.Add('component:QuadraCell') }
        if ($label -match '^(LumaCore|LuxCore)$') { $keys.Add('component:LumaCore-LuxCore') }
        if ($label -match '^([567])(CA|MA|SA)\s+''[^'']+''$') { $keys.Add("component:$($Matches[1])-series") }
        if ($label -match '^JS-\d+$') { $keys.Add('component:JS-series') }
        if ($label -match '^V801-\d+$') { $keys.Add('component:V801-series') }
        if ($label -match '^(.+?)(?:\s+(EX|SL|XL|Pro))$') { $keys.Add("component:$($Matches[1].Trim())") }
        if ($label -match '^(.+?)-(Go|Max|Lite)$') { $keys.Add("component:$($Matches[1].Trim())") }
    }

    return @($keys.ToArray() | Sort-Object -Unique)
}

function New-SCMiningCraftFamilyOptionMigrationMap {
    param([object]$FamilyIndex)

    $map = @{}
    if ($null -eq $FamilyIndex -or $null -eq $FamilyIndex.families) {
        return $map
    }

    foreach ($entry in @($FamilyIndex.families)) {
        $targetOptionId = [string]$entry.optionId
        if ([string]::IsNullOrWhiteSpace($targetOptionId)) {
            continue
        }

        foreach ($name in @($entry.names)) {
            foreach ($legacyKey in @(Get-SCMiningLegacyCraftFamilyKeysForName -Name ([string]$name) -Category ([string]$entry.category))) {
                $legacyOptionId = 'craftFamily|{0}|{1}|{2}' -f [string]$entry.category, [string]$entry.subcategory, [string]$legacyKey
                if (-not $map.ContainsKey($legacyOptionId)) {
                    $map[$legacyOptionId] = New-Object System.Collections.Generic.List[string]
                }
                if (-not $map[$legacyOptionId].Contains($targetOptionId)) {
                    $map[$legacyOptionId].Add($targetOptionId)
                }
            }
        }
    }

    return $map
}

function Expand-SCMiningCraftFamilyOptionIds {
    param([string[]]$OptionIds)

    $expanded = New-Object System.Collections.Generic.List[string]
    $migrationMap = New-SCMiningCraftFamilyOptionMigrationMap -FamilyIndex (Get-SCMiningCraftFamilyIndex)
    foreach ($optionId in @($OptionIds)) {
        $value = ConvertTo-SCCraftingFamilyOptionId -OptionId ([string]$optionId)
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $expanded.Add($value)
        if ($value -in @(
            'craftFamily|Корабельные компоненты|Охладители|exact:NightFall',
            'craftFamily|Корабельные компоненты|Охладители|exact:SnowBlind'
        )) {
            $expanded.Add('craftFamily|Корабельные компоненты|Охладители|component:SnowBlind-NightFall')
        }
        if ($value -eq 'craftFamily|Броня/одежда|Тяжёлая броня|armor:BUL-H4') {
            $expanded.Add('craftFamily|Броня/одежда|Сверхтяжёлая броня|armor:BUL-H4')
        }
        if ($value -eq 'craftFamily|Броня/одежда|Андерсьюты/костюмы|armor:BUL-H4') {
            $expanded.Add('craftFamily|Броня/одежда|Сверхтяжёлая броня|armor:BUL-H4')
        }
        if ($value -eq 'craftFamily|Оружие|Пулемёты|variant:Vendetta HMG') {
            $expanded.Add('craftFamily|Оружие|Тяжёлые пулемёты|variant:Vendetta HMG')
        }
        if ($value.StartsWith('craftFamily|Добывающие лазеры|Добывающие лазеры|', [System.StringComparison]::OrdinalIgnoreCase)) {
            $expanded.Add(($value -replace '^craftFamily\|Добывающие лазеры\|', 'craftFamily|Горное оборудование|'))
        }
        if ($migrationMap.ContainsKey($value)) {
            foreach ($targetOptionId in @($migrationMap[$value].ToArray())) {
                $expanded.Add([string]$targetOptionId)
            }
        }
    }

    return @($expanded.ToArray() | Sort-Object -Unique)
}

function Get-SCMiningCraftFilter {
    param([string[]]$SelectedOptions)

    $selected = @($SelectedOptions | ForEach-Object { [string]$_ })
    $familyOptionIds = @(Expand-SCMiningCraftFamilyOptionIds -OptionIds @($selected | Where-Object { ([string]$_).StartsWith('craftFamily|', [System.StringComparison]::OrdinalIgnoreCase) }))
    $componentClasses = New-Object System.Collections.Generic.List[string]
    $componentMap = @{
        componentClassMilitary = 'Military'
        componentClassStealth = 'Stealth'
        componentClassCompetition = 'Competition'
        componentClassCivilian = 'Civilian'
        componentClassIndustrial = 'Industrial'
    }
    foreach ($entry in $componentMap.GetEnumerator()) {
        if ($selected -contains $entry.Key) { $componentClasses.Add([string]$entry.Value) }
    }

    $shipWeaponSubcategories = New-Object System.Collections.Generic.List[string]
    $miningLaserSubcategories = New-Object System.Collections.Generic.List[string]
    $shipWeaponMap = @{
        shipWeaponEnergy = (Get-SCMiningPlanetSubcategoryEnergy)
        shipWeaponBallistic = (Get-SCMiningPlanetSubcategoryBallistics)
        shipWeaponHybrid = (Get-SCMiningPlanetSubcategoryHybrid)
    }
    foreach ($entry in $shipWeaponMap.GetEnumerator()) {
        if ($selected -contains $entry.Key) { $shipWeaponSubcategories.Add([string]$entry.Value) }
    }
    if ($selected -contains 'shipWeaponMiningLaser') {
        $miningLaserSubcategories.Add((Get-SCMiningPlanetSubcategoryMiningLasers))
    }

    $armorSubcategories = New-Object System.Collections.Generic.List[string]
    $armorMap = @{
        armorSuperHeavy = (Get-SCMiningPlanetSubcategorySuperHeavyArmor)
        armorHeavy = (Get-SCMiningPlanetSubcategoryHeavyArmor)
        armorMedium = (Get-SCMiningPlanetSubcategoryMediumArmor)
        armorLight = (Get-SCMiningPlanetSubcategoryLightArmor)
        armorSuits = (Get-SCMiningPlanetSubcategoryUndersuits)
    }
    foreach ($entry in $armorMap.GetEnumerator()) {
        if ($selected -contains $entry.Key) { $armorSubcategories.Add([string]$entry.Value) }
    }

    $fpsWeaponSubcategories = New-Object System.Collections.Generic.List[string]
    $fpsWeaponMap = @{
        fpsRifles = (Get-SCMiningPlanetSubcategoryRifles)
        fpsSniperRifles = (Get-SCMiningPlanetSubcategorySniperRifles)
        fpsSmgs = (Get-SCMiningPlanetSubcategorySmgs)
        fpsLmgs = (Get-SCMiningPlanetSubcategoryLmgs)
        fpsHmgs = (Get-SCMiningPlanetSubcategoryHmgs)
        fpsPistols = (Get-SCMiningPlanetSubcategoryPistols)
        fpsShotguns = (Get-SCMiningPlanetSubcategoryShotguns)
    }
    foreach ($entry in $fpsWeaponMap.GetEnumerator()) {
        if ($selected -contains $entry.Key) { $fpsWeaponSubcategories.Add([string]$entry.Value) }
    }

    return [pscustomobject]@{
        ComponentClasses = New-SCMiningStringSet -Values @($componentClasses.ToArray())
        ShipWeaponSubcategories = New-SCMiningStringSet -Values @($shipWeaponSubcategories.ToArray())
        MiningLaserSubcategories = New-SCMiningStringSet -Values @($miningLaserSubcategories.ToArray())
        ArmorSubcategories = New-SCMiningStringSet -Values @($armorSubcategories.ToArray())
        FpsWeaponSubcategories = New-SCMiningStringSet -Values @($fpsWeaponSubcategories.ToArray())
        HasFamilyOptions = ($familyOptionIds.Count -gt 0)
        FamilyOptionIds = New-SCMiningStringSet -Values @($familyOptionIds)
    }
}

function Test-SCMiningIncludePlanetRecipe {
    param(
        [object]$Recipe,
        [object]$CraftFilter
    )

    if ($null -eq $CraftFilter) {
        $CraftFilter = Get-SCMiningCraftFilter -SelectedOptions @()
    }

    if ($CraftFilter.HasFamilyOptions) {
        if ($Recipe.Category -eq (Get-SCMiningPlanetCategoryShipComponents) -and ([string]$Recipe.ComponentGrade) -ne 'A') {
            return $false
        }

        return (Test-SCMiningSetContains -Set $CraftFilter.FamilyOptionIds -Value (New-SCMiningCraftFamilyOptionId -Recipe $Recipe))
    }

    if ($Recipe.Category -eq (Get-SCMiningPlanetCategoryShipComponents)) {
        if (([string]$Recipe.ComponentGrade) -ne 'A') {
            return $false
        }

        return (Test-SCMiningSetContains -Set $CraftFilter.ComponentClasses -Value (([string]$Recipe.ComponentClass).Trim()))
    }

    if ($Recipe.Category -eq (Get-SCMiningPlanetCategoryShipWeapons)) {
        return (Test-SCMiningSetContains -Set $CraftFilter.ShipWeaponSubcategories -Value ([string]$Recipe.Subcategory))
    }

    if ($Recipe.Category -eq (Get-SCMiningPlanetCategoryMiningLasers)) {
        return (Test-SCMiningSetContains -Set $CraftFilter.MiningLaserSubcategories -Value ([string]$Recipe.Subcategory))
    }

    if ($Recipe.Category -eq (Get-SCMiningPlanetCategoryArmor)) {
        return (Test-SCMiningSetContains -Set $CraftFilter.ArmorSubcategories -Value ([string]$Recipe.Subcategory))
    }

    if ($Recipe.Category -eq (Get-SCMiningPlanetCategoryWeapons)) {
        return (Test-SCMiningSetContains -Set $CraftFilter.FpsWeaponSubcategories -Value ([string]$Recipe.Subcategory))
    }

    return $false
}

function Test-SCMiningGradeAStealthOrMilitaryComponent {
    param([object]$Recipe)

    if (([string]$Recipe.ComponentGrade) -ne 'A') {
        return $false
    }

    $componentClass = ([string]$Recipe.ComponentClass).Trim()
    if ($componentClass -in @('Military', 'Stealth')) {
        return $true
    }

    return Test-SCMiningKnownHighValueShipComponent -Name ([string]$Recipe.Name)
}

function Test-SCMiningKnownHighValueShipComponent {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $patterns = @(
        '^FR-86$',
        '^TS-2$',
        '^VK-00$',
        '^XL-1$',
        '^Spectre$',
        '^Spicule$',
        '^Eclipse$',
        '^JS-300$',
        '^JS-400$',
        '^QuadraCell MX$',
        '^Avalanche$',
        '^Blizzard$',
        '^Glacier$',
        '^NightFall$',
        '^SnowBlind$',
        '^V60-26$',
        '^V801-11$',
        '^V801-12$',
        '^V880$',
        '^Mirage$',
        '^Umbra$'
    )

    foreach ($pattern in $patterns) {
        if ($Name -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-SCMiningPlanetRecipeFamily {
    param(
        [string]$Name,
        [string]$Category,
        [string]$Subcategory,
        [string[]]$Resources,
        [string]$ComponentGrade,
        [string]$ComponentClass
    )

    $label = ([string]$Name).Trim()
    if ($label -match '^Monolith(?: Armor)? (Arms|Core|Helmet|Legs|Backpack)(?: Shadowflux)?$') {
        return [pscustomobject]@{ Key = 'armor:Monolith'; Label = 'Monolith'; Family = 'armor'; Token = $null }
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryArmor) -and $label -match '^Arden-(?:CL|SL)\s+(?:Backpack|Arms|Core|Helmet|Legs)$') {
        return [pscustomobject]@{ Key = 'armor:Arden'; Label = 'Arden'; Family = 'armor'; Token = $null }
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryArmor) -and $label -match '^Aztalan(?: Galena| Tamarack)?\s+(?:Arms|Core|Helmet|Legs)$') {
        return [pscustomobject]@{ Key = 'armor:Aztalan'; Label = 'Aztalan'; Family = 'armor'; Token = $null }
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryArmor)) {
        if ($label -match '^(?:BUL-H4\s+(?:Armor|Helmet)|H4-PBF\s+Ammo\s+Carrier)(?:\s+Snow\s+Camo)?$') {
            return [pscustomobject]@{ Key = 'armor:BUL-H4'; Label = 'BUL-H4 / H4-PBF'; Family = 'armor'; Token = $null }
        }
        if ($label -match '^(?:Bellator\s+(?:Jacket|Shirt and Waistcoat|Trousers)|Spettro\s+Shoes)$') {
            return [pscustomobject]@{ Key = 'armor:Bellator-Spettro'; Label = 'Bellator / Spettro'; Family = 'armor'; Token = $null }
        }
        if ($label -match '^Aves(?:\s+(Shrike|Talon))?\s+(Arms|Core|Helmet|Legs)\b') {
            return [pscustomobject]@{ Key = 'armor:Aves'; Label = 'Aves / Aves Shrike / Aves Talon'; Family = 'armor-variant-set'; Token = $null }
        }
        if ($label -match '^ADP(?:-mk4)?\s+(Arms|Core|Helmet|Legs)\b') {
            return [pscustomobject]@{ Key = 'armor:ADP'; Label = 'ADP / ADP-mk4'; Family = 'armor-variant-set'; Token = $null }
        }

        $base = $label
        $base = $base -replace '\s*\([^)]*\)', ''
        $base = $base -replace '\s+["“]Rucksack["”](?=\s+Backpack\b)', ''
        $base = $base -replace '\b(Arms|Core|Helmet|Legs|Backpack)\b.*$', ''
        $base = $base -replace '\b(Exploration Suit|Flight Suit|Undersuit|Suit)\b.*$', ''
        $base = $base.Trim()
        if (-not [string]::IsNullOrWhiteSpace($base) -and $base -ne $label) {
            return [pscustomobject]@{ Key = "armor:$base"; Label = $base; Family = 'armor'; Token = $null }
        }
    }

    if ($label -match '^Attrition-(\d+)\s+Repeater$') {
        return [pscustomobject]@{ Key = 'weapon:Attrition Repeater'; Label = 'Attrition Repeaters'; Family = 'numbered'; Token = [int]$Matches[1] }
    }
    if ($label -match '^CF-(\d+)\s+.+\s+Repeater$') {
        return [pscustomobject]@{ Key = 'weapon:CF Repeater'; Label = 'CF Repeaters'; Family = 'number-list'; Token = [int]$Matches[1] }
    }
    if ($label -match '^Deadbolt\s+([IVXLCDM]+)\s+Cannon$') {
        return [pscustomobject]@{ Key = 'weapon:Deadbolt Cannon'; Label = 'Deadbolt Cannons'; Family = 'roman'; Token = $Matches[1] }
    }
    if ($label -match '^Lightstrike\s+([IVXLCDM]+)\s+Cannon$') {
        return [pscustomobject]@{ Key = 'weapon:Lightstrike Cannon'; Label = 'Lightstrike Cannons'; Family = 'roman'; Token = $Matches[1] }
    }
    if ($label -match '^Omnisky\s+([IVXLCDM]+)\s+') {
        return [pscustomobject]@{ Key = 'weapon:Omnisky'; Label = 'Omnisky'; Family = 'roman'; Token = $Matches[1] }
    }
    if ($label -match '^Sledge\s+([IVXLCDM]+)\s+Mass Driver Cannon$') {
        return [pscustomobject]@{ Key = 'weapon:Sledge Mass Driver Cannon'; Label = 'Sledge Mass Driver Cannons'; Family = 'roman'; Token = $Matches[1] }
    }
    if ($label -match '^Singe\s+Cannon\s+\(S(\d+)\)$') {
        return [pscustomobject]@{ Key = 'weapon:Singe Cannon'; Label = 'Singe Cannons'; Family = 'size'; Token = [int]$Matches[1] }
    }
    if ($label -match '^Suckerpunch(?:-(L|XL))?\s+Cannon$') {
        $token = 1
        if ($Matches[1] -eq 'L') { $token = 2 }
        elseif ($Matches[1] -eq 'XL') { $token = 3 }
        return [pscustomobject]@{ Key = 'weapon:Suckerpunch Cannon'; Label = 'Suckerpunch Cannons'; Family = 'size'; Token = $token }
    }
    if ($label -match '^SW16BR(\d+)\s+.+\s+Repeater$') {
        return [pscustomobject]@{ Key = 'weapon:SW16BR Repeater'; Label = 'SW16BR Repeaters'; Family = 'numbered'; Token = [int]$Matches[1] }
    }
    if ($label -match '^Arbor\s+(MH(?:V|[12]))\s+Mining Laser$') {
        return [pscustomobject]@{ Key = 'weapon:Arbor Mining Laser'; Label = 'Arbor'; Family = 'mining-laser-list'; Token = $Matches[1] }
    }
    if ($label -match '^Lancet\s+MH([12])\s+Mining Laser$') {
        return [pscustomobject]@{ Key = 'weapon:Lancet Mining Laser'; Label = 'Lancet MH1/MH2 Mining Lasers'; Family = 'variant'; Token = $null }
    }
    if ($label -match '^Tarantula\s+GT-870\s+Mark\s+(\d+)\s+Cannon$') {
        return [pscustomobject]@{ Key = 'weapon:Tarantula GT-870 Cannon'; Label = 'Tarantula GT-870 Cannons Mk'; Family = 'numbered'; Token = [int]$Matches[1] }
    }
    if ($label -match '^(\d+)-Series\s+(Longsword|Broadsword|Greatsword)\s+Cannon$') {
        return [pscustomobject]@{ Key = 'weapon:Sword Series Cannon'; Label = 'Sword-series Cannons'; Family = 'number-list'; Token = [int]$Matches[1] }
    }
    if ($label -match '^M(\d+)A\s+Cannon$') {
        return [pscustomobject]@{ Key = 'weapon:MA Cannon'; Label = 'M-series Cannons'; Family = 'suffix-list'; Token = "$($Matches[1])A" }
    }
    if ($label -match '^AD(\d+)B\s+Ballistic Gatling$') {
        return [pscustomobject]@{ Key = 'weapon:AD Ballistic Gatling'; Label = 'AD Ballistic Gatlings'; Family = 'suffix-list'; Token = "$($Matches[1])B" }
    }
    if ($label -match '^(?:YellowJacket|Scorpion|Mantis)\s+GT-(210|215|220)\s+Gatling$') {
        return [pscustomobject]@{ Key = 'weapon:GT Gatling'; Label = 'GT Gatlings'; Family = 'number-list'; Token = [int]$Matches[1] }
    }
    if ($label -match '^(.+?)-(\d+)\s+(Repeater|Scattergun|Cannon)$') {
        $base = $Matches[1].Trim()
        $kind = $Matches[3].Trim()
        return [pscustomobject]@{ Key = "weapon:$base $kind"; Label = "$base ${kind}s"; Family = 'numbered'; Token = [int]$Matches[2] }
    }
    if ($label -match '^DR Model-XJ(\d+)\s+Repeater$') {
        return [pscustomobject]@{ Key = 'weapon:DR Model-XJ Repeater'; Label = 'DR Model-XJ Repeaters'; Family = 'numbered'; Token = [int]$Matches[1] }
    }
    if ($label -match '^FL-(\d+)\s+Cannon$') {
        return [pscustomobject]@{ Key = 'weapon:FL Cannon'; Label = 'FL Cannons'; Family = 'number-list'; Token = [int]$Matches[1] }
    }
    if ($label -match '^(Hofstede|Klein)-S(\d+)\s+Mining Laser$') {
        return [pscustomobject]@{ Key = "weapon:$($Matches[1]) Mining Laser"; Label = $Matches[1]; Family = 'mining-laser-list'; Token = [int]$Matches[2] }
    }
    if ($label -match '^(Helix|Impact)\s+([IVXLCDM]+)\s+Mining Laser$') {
        return [pscustomobject]@{ Key = "weapon:$($Matches[1]) Mining Laser"; Label = $Matches[1]; Family = 'mining-laser-list'; Token = $Matches[2] }
    }
    if ($label -match '^S0+\s+(Helix|Hofstede)$') {
        $base = $Matches[1]
        return [pscustomobject]@{ Key = "weapon:$base Mining Laser"; Label = $base; Family = 'mining-laser-list'; Token = ($label -replace "\s+$base$", '') }
    }

    if ($Category -eq (Get-SCMiningPlanetCategoryShipComponents)) {
        if ($label -match '^(Exotherm|Frontline|Holdstrong|Main Powerplant)$') {
            $safeLabel = [regex]::Replace($label.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
            return [pscustomobject]@{
                Key = "component:capital-a:$safeLabel"
                Label = 'CAP-A'
                Family = 'component-class-resource'
                Token = $null
            }
        }

        $componentGradeClean = ([string]$ComponentGrade).Trim().ToUpperInvariant()
        $componentClassCode = ConvertTo-SCMiningComponentClassCode -Class $ComponentClass
        $resourceKey = Get-SCMiningComponentResourceFamilyKey -Resources @($Resources)
        if ($componentGradeClean -eq 'A' -and -not [string]::IsNullOrWhiteSpace($componentClassCode) -and -not [string]::IsNullOrWhiteSpace($resourceKey)) {
            $safeSubcategory = [regex]::Replace(([string]$Subcategory).Trim().ToLowerInvariant(), '[^\p{L}\p{Nd}]+', '-').Trim('-')
            return [pscustomobject]@{
                Key = "component:$($safeSubcategory):$componentClassCode-$($componentGradeClean):$resourceKey"
                Label = "$componentClassCode-$componentGradeClean"
                Family = 'component-class-resource'
                Token = $null
            }
        }

        if ($label -match '^FR-(66|76|86)$') {
            return [pscustomobject]@{ Key = 'component:FR-series'; Label = 'FR'; Family = 'hyphen-number-list'; Token = [int]$Matches[1] }
        }
        if ($label -match '^FullSpec(?:-(Go|Max))?$') {
            $token = if ([string]::IsNullOrWhiteSpace([string]$Matches[1])) { 'FullSpec' } else { "FullSpec-$($Matches[1])" }
            return [pscustomobject]@{ Key = 'component:FullSpec'; Label = 'FullSpec'; Family = 'name-list'; Token = $token }
        }
        if ($label -match '^(SnowBlind|NightFall)$') {
            return [pscustomobject]@{ Key = 'component:SnowBlind-NightFall'; Label = 'SnowBlind / NightFall'; Family = 'variant'; Token = $null }
        }
        if ($label -match '^QuadraCell(?:\s+(MT|MX))?$') {
            return [pscustomobject]@{ Key = 'component:QuadraCell'; Label = 'QuadraCell / MT / MX'; Family = 'variant'; Token = $null }
        }
        if ($label -match '^(LumaCore|LuxCore)$') {
            return [pscustomobject]@{ Key = 'component:LumaCore-LuxCore'; Label = 'LumaCore / LuxCore'; Family = 'variant'; Token = $null }
        }
        if ($label -match '^([567])(CA|MA|SA)\s+''[^'']+''$') {
            $series = $Matches[1]
            return [pscustomobject]@{ Key = "component:$series-series"; Label = "${series}CA/${series}MA/${series}SA"; Family = 'variant'; Token = $null }
        }
        if ($label -match '^JS-\d+$') {
            return [pscustomobject]@{ Key = 'component:JS-series'; Label = 'JS-300/400/500'; Family = 'variant'; Token = $null }
        }
        if ($label -match '^V801-\d+$') {
            return [pscustomobject]@{ Key = 'component:V801-series'; Label = 'V801-11/12'; Family = 'variant'; Token = $null }
        }
        if ($label -match '^(.+?)(?:\s+(EX|SL|XL|Pro))$') {
            $base = $Matches[1].Trim()
            return [pscustomobject]@{ Key = "component:$base"; Label = "$base variants"; Family = 'variant'; Token = $null }
        }
        if ($label -match '^(.+?)-(Go|Max|Lite)$') {
            $base = $Matches[1].Trim()
            return [pscustomobject]@{ Key = "component:$base"; Label = "$base variants"; Family = 'variant'; Token = $null }
        }
    }

    if ($label -match '^Pulse\s+(Laser\s+)?Pistol$' -or $label -match '^Pulse\s+"[^"]+"\s+Pistol$') {
        return [pscustomobject]@{ Key = 'weapon:Pulse Pistol'; Label = 'Pulse / Pulse Laser Pistol'; Family = 'variant'; Token = $null }
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryWeapons) -and $label -eq 'Coda Pistol (Modified)') {
        return [pscustomobject]@{ Key = 'variant:Coda Pistol'; Label = 'Coda Pistol variants'; Family = 'variant'; Token = $null }
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryWeapons) -and $label -eq 'Salvo Esteban Frag Pistol') {
        return [pscustomobject]@{ Key = 'variant:Salvo Frag Pistol'; Label = 'Salvo Frag Pistol variants'; Family = 'variant'; Token = $null }
    }
    if ($label -match '^(.+?)\s+"[^"]+"\s+(.+)$') {
        $base = ($Matches[1] + ' ' + $Matches[2]).Trim()
        return [pscustomobject]@{ Key = "variant:$base"; Label = "$base variants"; Family = 'variant'; Token = $null }
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryWeapons) -and $label -match '^(.+?)\s+(Energy Assault Rifle|Laser Sniper Rifle|Laser Shotgun|Sniper Rifle|Twin Shotgun|Energy LMG|Pistol|SMG|Rifle|Shotgun|Crossbow|LMG|HMG)$') {
        return [pscustomobject]@{ Key = "variant:$label"; Label = "$label variants"; Family = 'variant'; Token = $null }
    }
    if ($label -match '^(Abrade|Cinch|Trawler)\s+Scraper Module$') {
        return [pscustomobject]@{ Key = 'equipment:Scraper Modules'; Label = 'Abrade/Cinch/Trawler Scraper Modules'; Family = 'variant'; Token = $null }
    }
    if ($label -match '^(.+?)\s+Battery\s+\([^)]+\)$') {
        $base = $Matches[1].Trim()
        return [pscustomobject]@{ Key = "battery:$base"; Label = "$base batteries"; Family = 'variant'; Token = $null }
    }
    if ($label -match '^(.+?)\s+Magazine\s+\([^)]+\)$') {
        $base = $Matches[1].Trim()
        return [pscustomobject]@{ Key = "magazine:$base"; Label = "$base magazines"; Family = 'variant'; Token = $null }
    }

    return [pscustomobject]@{ Key = "exact:$label"; Label = $label; Family = 'exact'; Token = $null }
}

function Get-SCMiningCompactRecipeDisplayName {
    param([AllowEmptyString()][string]$Name)

    $clean = ([string]$Name).Trim()
    $clean = [regex]::Replace($clean, "\s+'[^']+'\s*$", '')
    return $clean
}

function Get-SCMiningCompactRecipeNamePart {
    param([AllowEmptyString()][string]$Name)

    $clean = Get-SCMiningCompactRecipeDisplayName -Name $Name
    if ($clean -match '^(.+?)-([A-Za-z]?\d+)$') {
        return [pscustomobject]@{ Base = $Matches[1]; Suffix = $Matches[2]; Sort = $clean }
    }
    if ($clean -match '^(.+?)\s+(MT|MX|EX|SL|XL|Pro|Go|Max|Lite)$') {
        return [pscustomobject]@{ Base = $Matches[1].Trim(); Suffix = $Matches[2]; Sort = $clean }
    }

    return [pscustomobject]@{ Base = $clean; Suffix = ''; Sort = $clean }
}

function Format-SCMiningCompactRecipeNameList {
    param([string[]]$Names)

    $cleanNames = @(
        @($Names) |
            ForEach-Object { Get-SCMiningCompactRecipeDisplayName -Name ([string]$_) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    if ($cleanNames.Count -eq 0) {
        return ''
    }

    $partsByBase = @{}
    foreach ($name in @($cleanNames)) {
        $part = Get-SCMiningCompactRecipeNamePart -Name $name
        if ([string]::IsNullOrWhiteSpace([string]$part.Base)) {
            continue
        }

        $base = [string]$part.Base
        if (-not $partsByBase.ContainsKey($base)) {
            $partsByBase[$base] = [pscustomobject]@{
                Base = $base
                Sort = [string]$part.Sort
                Suffixes = New-Object System.Collections.Generic.List[string]
                Exact = $false
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$part.Suffix)) {
            $partsByBase[$base].Exact = $true
        }
        else {
            $partsByBase[$base].Suffixes.Add([string]$part.Suffix)
        }
    }

    $allExact = $true
    $hasCompactedGroup = $false
    foreach ($entry in @($partsByBase.Values)) {
        if (-not $entry.Exact -or $entry.Suffixes.Count -gt 0) {
            $allExact = $false
        }
        if ($entry.Suffixes.Count -gt 1 -or ($entry.Exact -and $entry.Suffixes.Count -gt 0)) {
            $hasCompactedGroup = $true
        }
    }

    $groups = foreach ($entry in @($partsByBase.Values)) {
        $suffixes = @($entry.Suffixes.ToArray() | Sort-Object -Unique)
        if ($entry.Exact -and $suffixes.Count -gt 0) {
            [pscustomobject]@{ Label = ([string]$entry.Base) + '/' + ($suffixes -join '/'); Sort = [string]$entry.Sort }
        }
        elseif ($suffixes.Count -gt 1) {
            [pscustomobject]@{ Label = ([string]$entry.Base) + '-' + ($suffixes -join '/'); Sort = [string]$entry.Sort }
        }
        elseif ($suffixes.Count -eq 1) {
            [pscustomobject]@{ Label = ([string]$entry.Base) + '-' + $suffixes[0]; Sort = [string]$entry.Sort }
        }
        else {
            [pscustomobject]@{ Label = [string]$entry.Base; Sort = [string]$entry.Sort }
        }
    }

    if ($allExact) {
        return (($groups | Sort-Object Sort | ForEach-Object { [string]$_.Label }) -join '/')
    }

    $separator = '/'
    if ($hasCompactedGroup) {
        $separator = '/ '
    }

    return (($groups | Sort-Object Sort | ForEach-Object { [string]$_.Label }) -join $separator)
}

function Format-SCMiningPlanetRecipeFamilyLabel {
    param([object]$Group)

    if ($Group.Family -eq 'component-class-resource') {
        $names = Format-SCMiningCompactRecipeNameList -Names @($Group.Names)
        if (-not [string]::IsNullOrWhiteSpace($names)) {
            return "$($Group.Label): $names"
        }
    }

    if ($Group.Names.Count -le 1 -or $Group.Family -eq 'exact') {
        return [string]$Group.Names[0]
    }

    if ($Group.Family -eq 'armor') {
        return "$($Group.Label) set"
    }

    if ($Group.Family -eq 'armor-variant-set') {
        return "$($Group.Label) set"
    }

    if ($Group.Family -in @('numbered', 'number-list')) {
        $span = Format-SCMiningNumberSpan -Values $Group.Tokens
        if ($span) {
            return "$($Group.Label) $span"
        }
    }

    if ($Group.Family -eq 'roman') {
        $span = Format-SCMiningRomanSpan -Values $Group.Tokens
        if ($span) {
            return "$($Group.Label) $span"
        }
    }

    if ($Group.Family -eq 'size') {
        $span = Format-SCMiningNumberSpan -Values $Group.Tokens
        if ($span) {
            if ($span -match '^(\d+)-(\d+)$') {
                return "$($Group.Label) S$($Matches[1])-S$($Matches[2])"
            }
            return "$($Group.Label) S$span"
        }
    }

    if ($Group.Family -eq 'suffix-list') {
        $tokens = @($Group.Tokens | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if ($tokens.Count -gt 0) {
            return "$($Group.Label) " + ($tokens -join '/')
        }
    }

    if ($Group.Family -eq 'hyphen-number-list') {
        $tokens = @($Group.Tokens | ForEach-Object { [string]$_ } | Sort-Object { [int]$_ } -Unique)
        if ($tokens.Count -gt 0) {
            return "$($Group.Label)-" + ($tokens -join '/').Replace('/', "/$($Group.Label)-")
        }
    }

    if ($Group.Family -eq 'name-list') {
        $tokens = @($Group.Tokens | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if ($tokens.Count -gt 0) {
            return ($tokens -join '/')
        }
    }

    if ($Group.Family -eq 'mining-laser-list') {
        $tokens = @($Group.Tokens | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if ($tokens.Count -gt 0) {
            return "$($Group.Label) " + ($tokens -join '/') + ' Mining Lasers'
        }
    }

    return ([string]$Group.Label) -replace '\s+variants$', ''
}

function Format-SCMiningNumberSpan {
    param([object[]]$Values)

    $items = @(
        $Values |
            ForEach-Object {
                if ($_ -is [int]) {
                    [pscustomobject]@{ Label = [string]$_; Value = [int]$_ }
                }
                elseif ([string]$_ -match '^\d+$') {
                    [pscustomobject]@{ Label = [string]$_; Value = [int]$_ }
                }
            } |
            Sort-Object Value -Unique
    )

    if ($items.Count -eq 0) {
        return ''
    }
    if ($items.Count -eq 1) {
        return $items[0].Label
    }

    $isSequential = $items.Count -gt 2
    if ($isSequential) {
        for ($i = 1; $i -lt $items.Count; $i++) {
            if ($items[$i].Value -ne ($items[$i - 1].Value + 1)) {
                $isSequential = $false
                break
            }
        }
    }

    if ($isSequential) {
        return "$($items[0].Label)-$($items[$items.Count - 1].Label)"
    }

    return (($items | ForEach-Object { $_.Label }) -join '/')
}

function Format-SCMiningRomanSpan {
    param([object[]]$Values)

    $items = @(
        $Values |
            ForEach-Object {
                $label = [string]$_
                $value = Convert-SCMiningRomanToInt -Value $label
                if ($value -gt 0) {
                    [pscustomobject]@{ Label = $label; Value = $value }
                }
            } |
            Sort-Object Value -Unique
    )

    if ($items.Count -eq 0) {
        return ''
    }
    if ($items.Count -eq 1) {
        return $items[0].Label
    }

    $isSequential = $items.Count -gt 2
    if ($isSequential) {
        for ($i = 1; $i -lt $items.Count; $i++) {
            if ($items[$i].Value -ne ($items[$i - 1].Value + 1)) {
                $isSequential = $false
                break
            }
        }
    }

    if ($isSequential) {
        return "$($items[0].Label)-$($items[$items.Count - 1].Label)"
    }

    return (($items | ForEach-Object { $_.Label }) -join '/')
}

function Convert-SCMiningRomanToInt {
    param([AllowEmptyString()][string]$Value)

    $map = @{ I = 1; V = 5; X = 10; L = 50; C = 100; D = 500; M = 1000 }
    $text = ([string]$Value).ToUpperInvariant()
    $total = 0
    $previous = 0
    for ($i = $text.Length - 1; $i -ge 0; $i--) {
        $char = [string]$text[$i]
        if (-not $map.ContainsKey($char)) {
            return 0
        }
        $current = [int]$map[$char]
        if ($current -lt $previous) {
            $total -= $current
        }
        else {
            $total += $current
            $previous = $current
        }
    }

    return $total
}

function Format-SCMiningLegacyPlanetRecipeFamilyLabel {
    param([object]$Group)

    $tokens = @($Group.Tokens | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if ($tokens.Count -eq 0) {
        return [string]$Group.Label
    }

    $label = [string]$Group.Label
    if ($label.EndsWith('-')) {
        return ($label + ($tokens -join '/')).Trim()
    }

    return ($label + ' ' + ($tokens -join '/')).Trim()
}

function Get-SCMiningScmdbRewardBlueprintRecords {
    param([object]$Scmdb)

    $recordsById = @{}
    foreach ($poolProperty in @($Scmdb.blueprintPools.PSObject.Properties)) {
        $pool = $poolProperty.Value
        foreach ($entry in @($pool.blueprints)) {
            $blueprintRecord = [string]$entry.blueprintRecord
            if ([string]::IsNullOrWhiteSpace($blueprintRecord)) {
                continue
            }

            if (-not $recordsById.ContainsKey($blueprintRecord)) {
                $recordsById[$blueprintRecord] = [pscustomobject]@{
                    blueprintRecord = $blueprintRecord
                    name = [string]$entry.name
                    entityClass = [string]$entry.entityClass
                    poolName = [string]$pool.name
                    source = [string]$pool.source
                }
            }
        }
    }

    return @($recordsById.Values)
}

function Get-SCMiningWikiBlueprints {
    param(
        [hashtable]$Headers,
        [string]$CacheKey,
        [switch]$ForceRefresh
    )

    $cachePath = Get-SCMiningWikiBlueprintCachePath -CacheKey $CacheKey
    if (-not $ForceRefresh -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        try {
            $cached = Get-Content -LiteralPath $cachePath -Encoding UTF8 -Raw | ConvertFrom-Json
            if ($cached.cacheKey -eq $CacheKey -and @($cached.data).Count -gt 0) {
                return @($cached.data)
            }
        }
        catch {
            Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        }
    }

    $first = Invoke-SCMiningRemoteJson -Uri 'https://api.star-citizen.wiki/api/blueprints?page%5Bsize%5D=100&page%5Bnumber%5D=1' -Headers $Headers -Referer 'https://star-citizen.wiki/'
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($first.data)) {
        $all.Add($item)
    }

    $lastPage = [int]$first.meta.last_page
    for ($page = 2; $page -le $lastPage; $page++) {
        $result = Invoke-SCMiningRemoteJson -Uri ("https://api.star-citizen.wiki/api/blueprints?page%5Bsize%5D=100&page%5Bnumber%5D={0}" -f $page) -Headers $Headers -Referer 'https://star-citizen.wiki/'
        foreach ($item in @($result.data)) {
            $all.Add($item)
        }
    }

    $blueprints = $all.ToArray()
    Write-SCMiningWikiBlueprintCache -CachePath $cachePath -CacheKey $CacheKey -Blueprints $blueprints
    return $blueprints
}

function Get-SCMiningWikiBlueprintCachePath {
    param([string]$CacheKey)

    $safeKey = Get-SCMiningSafeCacheKey -CacheKey $CacheKey
    $cacheDir = Join-Path $PSScriptRoot 'cache'
    return (Join-Path $cacheDir "wiki-blueprints-$safeKey.json")
}

function Write-SCMiningWikiBlueprintCache {
    param(
        [string]$CachePath,
        [string]$CacheKey,
        [object[]]$Blueprints
    )

    $cacheDir = Split-Path -Parent $CachePath
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    }

    $sourceVersions = @($Blueprints | ForEach-Object { [string]$_.game_version } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $requestedVersion = ConvertTo-SCMiningWikiGameVersion -CacheKey $CacheKey
    $match = if ($sourceVersions.Count -eq 1 -and $sourceVersions[0] -eq $requestedVersion) { 'exact' } else { 'source-lag' }
    $payload = [pscustomobject]@{
        cacheKey = $CacheKey
        requestedGameVersion = $requestedVersion
        gameVersion = ($sourceVersions -join ', ')
        sourceGameVersions = @($sourceVersions)
        versionMatch = $match
        source = 'Star Citizen Wiki'
        createdAt = (Get-Date).ToString('o')
        data = @($Blueprints)
    }
    $json = $payload | ConvertTo-Json -Depth 12
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($CachePath, $json, $encoding)
}

function New-SCMiningLocalizationLookup {
    param([object]$Context)

    $actualKeyByLower = @{}
    $keysByValue = @{}

    foreach ($key in @($Context.Values.Keys)) {
        $actualKeyByLower[[string]$key.ToLowerInvariant()] = [string]$key
        $value = [string]$Context.Values[$key]
        if (-not $keysByValue.ContainsKey($value)) {
            $keysByValue[$value] = New-Object System.Collections.Generic.List[string]
        }
        $keysByValue[$value].Add([string]$key)
    }

    return [pscustomobject]@{
        ActualKeyByLower = $actualKeyByLower
        KeysByValue = $keysByValue
    }
}

function Resolve-SCMiningCraftDescriptionKey {
    param(
        [object]$Blueprint,
        [object]$Reward,
        [object]$Lookup
    )

    $outputClass = Get-SCMiningBlueprintOutputClass -Blueprint $Blueprint -Reward $Reward
    $outputName = Get-SCMiningBlueprintOutputName -Blueprint $Blueprint -Reward $Reward
    $outputType = Get-SCMiningBlueprintOutputType -Blueprint $Blueprint

    $direct = Resolve-SCMiningDirectDescriptionKey -OutputClass $outputClass -Lookup $Lookup
    if ($direct) {
        return $direct
    }

    $armorFamily = Resolve-SCMiningArmorFamilyDescriptionKey -OutputClass $outputClass -OutputType $outputType -Lookup $Lookup
    if ($armorFamily) {
        return $armorFamily
    }

    return Resolve-SCMiningNamePairDescriptionKey -OutputName $outputName -Lookup $Lookup
}

function Resolve-SCMiningDirectDescriptionKey {
    param(
        [string]$OutputClass,
        [object]$Lookup
    )

    if ([string]::IsNullOrWhiteSpace($OutputClass)) {
        return $null
    }

    $verifiedAliases = @{
        'radr_grnp_s02_vb80112' = 'item_Desc_RADR_GRNP_S02_V80112'
        'radr_chco_s02_broadspec_lite' = 'item_Desc_RADR_CHCO_S02_BroadSpec'
    }
    if ($verifiedAliases.ContainsKey($OutputClass)) {
        $actual = Get-SCMiningActualKey -Lookup $Lookup -Candidate $verifiedAliases[$OutputClass]
        if ($actual) { return $actual }
    }
    $stripped = [regex]::Replace($OutputClass, '(?i)_SCItem$', '')
    $variants = @($OutputClass, $stripped) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($variant in $variants) {
        foreach ($suffix in @('_Desc', '_Desc,P')) {
            foreach ($candidate in @(($variant + $suffix), ('item_' + $variant + $suffix))) {
                $actual = Get-SCMiningActualKey -Lookup $Lookup -Candidate $candidate
                if ($actual) {
                    return $actual
                }
            }
        }
        foreach ($prefix in @('item_Desc', 'item_Desc_')) {
            foreach ($suffix in @('', ',P')) {
                $actual = Get-SCMiningActualKey -Lookup $Lookup -Candidate ($prefix + $variant + $suffix)
                if ($actual) {
                    return $actual
                }
            }
        }
    }

    return $null
}

function Resolve-SCMiningNamePairDescriptionKey {
    param(
        [string]$OutputName,
        [object]$Lookup
    )

    if ([string]::IsNullOrWhiteSpace($OutputName) -or -not $Lookup.KeysByValue.ContainsKey($OutputName)) {
        return $null
    }

    foreach ($nameKey in @($Lookup.KeysByValue[$OutputName] | Sort-Object)) {
        $candidates = New-Object System.Collections.Generic.List[string]
        if ($nameKey -match '(.+)_Name$') {
            $base = $Matches[1]
            foreach ($suffix in @('_Desc', '_Desc,P', '_desc', '_desc,P')) {
                $candidates.Add($base + $suffix)
            }
        }
        if ($nameKey.StartsWith('item_Name')) {
            $candidates.Add('item_Desc' + $nameKey.Substring('item_Name'.Length))
        }
        if ($nameKey.StartsWith('item_Name_')) {
            $candidates.Add('item_Desc_' + $nameKey.Substring('item_Name_'.Length))
        }
        if ($nameKey.StartsWith('item_Mining') -and -not $nameKey.EndsWith('_Desc')) {
            $candidates.Add($nameKey + '_Desc')
        }
        if ($nameKey.StartsWith('item_NameMining_Head')) {
            $candidates.Add('item_descMining_Head' + $nameKey.Substring('item_NameMining_Head'.Length))
        }
        if ($nameKey -match '^item_NameGRIN_TractorBeam_002_S\d_UT1$') {
            $candidates.Add('item_DescGRIN_TractorBeam_002_shared_UT1')
        }

        foreach ($candidate in $candidates) {
            foreach ($suffix in @('', ',P')) {
                $actual = Get-SCMiningActualKey -Lookup $Lookup -Candidate ($candidate + $suffix)
                if ($actual) {
                    return $actual
                }
            }
        }
    }

    return $null
}

function Resolve-SCMiningArmorFamilyDescriptionKey {
    param(
        [string]$OutputClass,
        [string]$OutputType,
        [object]$Lookup
    )

    if ([string]::IsNullOrWhiteSpace($OutputClass) -or $OutputType -notmatch 'Armor') {
        return $null
    }

    $clean = [regex]::Replace($OutputClass, '(?i)_SCItem$', '')
    foreach ($candidate in @(Get-SCMiningArmorFamilyDescriptionCandidates -OutputClass $clean)) {
        $actual = Get-SCMiningActualKey -Lookup $Lookup -Candidate $candidate
        if ($actual) {
            return $actual
        }
    }

    $parts = @($clean -split '_')
    for ($count = $parts.Count - 1; $count -ge 4; $count--) {
        $base = ($parts | Select-Object -First $count) -join '_'
        foreach ($candidate in @("item_Desc_$base", "item_Desc$base", "item_Desc_$base,P", "item_Desc$base,P")) {
            $actual = Get-SCMiningActualKey -Lookup $Lookup -Candidate $candidate
            if ($actual) {
                return $actual
            }
        }
    }

    return $null
}

function Get-SCMiningArmorFamilyDescriptionCandidates {
    param([string]$OutputClass)

    if ([string]::IsNullOrWhiteSpace($OutputClass)) {
        return @()
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $part = Get-SCMiningArmorPart -OutputClass $OutputClass

    if ($OutputClass -match '^cds_legacy_armor_heavy_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_cds_legacy_heavy_armor_01') }
            'core' { $candidates.Add('item_Desc_cds_legacy_heavy_armor_01_core') }
            'helmet' { $candidates.Add('item_Desc_cds_legacy_heavy_armor_01_helmet') }
            'legs' { $candidates.Add('item_Desc_cds_legacy_heavy_armor_01_legs') }
        }
    }
    elseif ($OutputClass -match '^cds_armor_heavy_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_cds_heavy_armor_01_Shared') }
            'core' { $candidates.Add('item_Desc_cds_heavy_armor_01_core') }
            'helmet' { $candidates.Add('item_Desc_cds_heavy_armor_01_Shared') }
            'legs' { $candidates.Add('item_Desc_cds_heavy_armor_01_legs') }
        }
    }
    elseif ($OutputClass -match '^cds_legacy_armor_medium_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_cds_legacy_medium_armor_01') }
            'core' { $candidates.Add('item_Desc_cds_legacy_medium_armor_01_core') }
            'helmet' { $candidates.Add('item_Desc_cds_legacy_medium_armor_01_helmet') }
            'legs' { $candidates.Add('item_Desc_cds_legacy_medium_armor_01_legs') }
        }
    }
    elseif ($OutputClass -match '^cds_armor_medium_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_cds_medium_armor_01_Shared') }
            'core' { $candidates.Add('item_Desc_cds_medium_armor_01_core') }
            'helmet' { $candidates.Add('item_Desc_cds_medium_armor_02_helmet') }
            'legs' { $candidates.Add('item_Desc_cds_medium_armor_01_legs') }
        }
    }
    elseif ($OutputClass -match '^outlaw_legacy_armor_heavy_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_outlaw_legacy_heavy_armor') }
            'core' { $candidates.Add('item_Desc_outlaw_legacy_heavy_armor_core') }
            'helmet' { $candidates.Add('item_Desc_outlaw_legacy_heavy_armor_helmet') }
            'legs' { $candidates.Add('item_Desc_outlaw_legacy_heavy_armor_legs') }
        }
    }
    elseif ($OutputClass -match '^outlaw_legacy_armor_medium_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_outlaw_legacy_medium_armor') }
            'core' { $candidates.Add('item_Desc_outlaw_legacy_medium_armor_core') }
            'helmet' { $candidates.Add('item_Desc_outlaw_legacy_medium_armor_helmet') }
            'legs' { $candidates.Add('item_Desc_outlaw_legacy_medium_armor_legs') }
        }
    }
    elseif ($OutputClass -match '^outlaw_legacy_armor_light_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_outlaw_legacy_light_armor') }
            'core' { $candidates.Add('item_Desc_outlaw_legacy_light_armor_core') }
            'helmet' { $candidates.Add('item_Desc_outlaw_legacy_light_armor_helmet') }
            'legs' { $candidates.Add('item_Desc_outlaw_legacy_light_armor_legs') }
        }
    }
    elseif ($OutputClass -match '^srvl_armor_heavy_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_srvl_heavy_armor_01_Shared') }
            'core' { $candidates.Add('item_Desc_srvl_heavy_core_01') }
            'helmet' { $candidates.Add('item_Desc_srvl_heavy_helmet_01') }
            'legs' { $candidates.Add('item_Desc_srvl_heavy_armor_01_legs') }
        }
    }
    elseif ($OutputClass -match '^vgl_armor_light_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_vgl_advocacy_lightarmor_Shared') }
            'core' { $candidates.Add('item_Desc_vgl_armor_light_core_01_01_Shared') }
            'helmet' { $candidates.Add('item_Desc_vgl_advocacy_lightarmor_helmet_01') }
            'legs' { $candidates.Add('item_Desc_vgl_advocacy_lightarmor_legs_01') }
        }
    }
    elseif ($OutputClass -match '^slaver_armor_light_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_slaver_armor_light_01_Shared') }
            'core' { $candidates.Add('item_Desc_slaver_armor_light_01_core') }
            'helmet' { $candidates.Add('item_Desc_slaver_armor_light_01_Shared') }
            'legs' { $candidates.Add('item_Desc_slaver_armor_light_01_legs') }
        }
    }
    elseif ($OutputClass -match '^slaver_armor_medium_(arms|core|helmet|legs)_01_01_') {
        switch ($part) {
            'arms' { $candidates.Add('item_Desc_slaver_armor_medium_01_Shared') }
            'core' { $candidates.Add('item_Desc_slaver_armor_medium_01_core') }
            'helmet' { $candidates.Add('item_Desc_slaver_armor_medium_01_Shared') }
            'legs' { $candidates.Add('item_Desc_slaver_armor_medium_01_legs') }
        }
    }
    elseif ($OutputClass -match '^gys_jacket_01_01_') {
        $candidates.Add('item_Desc_gys_jacket_01')
    }
    elseif ($OutputClass -match '^gys_pants_01_01_') {
        $candidates.Add('item_Desc_gys_pants_01')
    }

    return @($candidates)
}

function Get-SCMiningArmorPart {
    param([string]$OutputClass)

    if ($OutputClass -match '(^|_)(arms|core|helmet|legs)(_|$)') {
        return $Matches[2].ToLowerInvariant()
    }

    return $null
}

function Get-SCMiningActualKey {
    param(
        [object]$Lookup,
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    $lower = $Candidate.ToLowerInvariant()
    if ($Lookup.ActualKeyByLower.ContainsKey($lower)) {
        return [string]$Lookup.ActualKeyByLower[$lower]
    }

    return $null
}

function Get-SCMiningBlueprintResourceNames {
    param([object]$Blueprint)

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($ingredient in @($Blueprint.ingredients)) {
        $name = [string]$ingredient.name
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $names.Contains($name)) {
            $names.Add($name)
        }
    }

    return @($names)
}

function Get-SCMiningResourceSignature {
    param([string[]]$Resources)

    return (@($Resources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ' | ')
}

function Get-SCMiningBlueprintOutputClass {
    param(
        [object]$Blueprint,
        [object]$Reward
    )

    $override = Get-SCMiningBlueprintOutputOverride -Blueprint $Blueprint
    if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override.Class)) {
        return [string]$override.Class
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Blueprint.output_class)) {
        return [string]$Blueprint.output_class
    }
    if ($null -ne $Blueprint.output -and -not [string]::IsNullOrWhiteSpace([string]$Blueprint.output.class)) {
        return [string]$Blueprint.output.class
    }

    return [string]$Reward.entityClass
}

function Repair-SCMiningBlueprintText {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [string]$Value
    }

    $badLeftQuote = -join @([char]0x0432, [char]0x0402, [char]0x045A)
    $badRightQuote = -join @([char]0x0432, [char]0x0402, [char]0x045C)
    $badApostrophe = -join @([char]0x0432, [char]0x0402, [char]0x2122)
    $badDash = -join @([char]0x0432, [char]0x0402, [char]0x201C)

    return ([string]$Value).
        Replace($badLeftQuote, [string][char]0x201C).
        Replace($badRightQuote, [string][char]0x201D).
        Replace($badApostrophe, [string][char]0x2019).
        Replace($badDash, '-')
}

function Get-SCMiningBlueprintOutputName {
    param(
        [object]$Blueprint,
        [object]$Reward
    )

    $override = Get-SCMiningBlueprintOutputOverride -Blueprint $Blueprint
    if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override.Name)) {
        return Repair-SCMiningBlueprintText -Value ([string]$override.Name)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Blueprint.output_name)) {
        return Repair-SCMiningBlueprintText -Value ([string]$Blueprint.output_name)
    }
    if ($null -ne $Blueprint.output -and -not [string]::IsNullOrWhiteSpace([string]$Blueprint.output.name)) {
        return Repair-SCMiningBlueprintText -Value ([string]$Blueprint.output.name)
    }

    return Repair-SCMiningBlueprintText -Value ([string]$Reward.name)
}

function Get-SCMiningBlueprintOutputType {
    param([object]$Blueprint)

    $override = Get-SCMiningBlueprintOutputOverride -Blueprint $Blueprint
    if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override.Type)) {
        return [string]$override.Type
    }

    if ($null -ne $Blueprint.output -and -not [string]::IsNullOrWhiteSpace([string]$Blueprint.output.type_label)) {
        return [string]$Blueprint.output.type_label
    }
    if ($null -ne $Blueprint.output -and -not [string]::IsNullOrWhiteSpace([string]$Blueprint.output.type)) {
        return [string]$Blueprint.output.type
    }

    return 'Unknown'
}

function Get-SCMiningCachedItemInfoLookup {
    $cachePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'quest\engine\cache\wiki-items-cache.json'
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        return @{}
    }

    try {
        $items = Get-Content -LiteralPath $cachePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        return @{}
    }

    $lookup = @{}
    foreach ($property in @($items.PSObject.Properties)) {
        $name = ([string]$property.Name).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $lookup[$name.ToLowerInvariant()] = $property.Value
        }
    }
    return $lookup
}

function Get-SCMiningCachedItemInfo {
    param(
        [object]$Blueprint,
        [hashtable]$ItemLookup
    )

    if ($null -eq $ItemLookup -or $ItemLookup.Count -eq 0) {
        return $null
    }

    $name = Get-SCMiningBlueprintOutputName -Blueprint $Blueprint -Reward $null
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    $key = ([string]$name).Trim().ToLowerInvariant()
    if ($ItemLookup.ContainsKey($key)) {
        return $ItemLookup[$key]
    }

    return $null
}

function Normalize-SCMiningComponentGrade {
    param([AllowEmptyString()][string]$Grade)

    $cleanGrade = ''
    if (-not [string]::IsNullOrWhiteSpace($Grade)) {
        $cleanGrade = ([string]$Grade).Trim().ToUpperInvariant()
    }

    $map = @{
        '1' = 'A'
        '2' = 'B'
        '3' = 'C'
        '4' = 'D'
    }
    if ($map.ContainsKey($cleanGrade)) {
        return $map[$cleanGrade]
    }

    return $cleanGrade
}

function Get-SCMiningBlueprintOutputGrade {
    param(
        [object]$Blueprint,
        [hashtable]$ItemLookup
    )

    $override = Get-SCMiningBlueprintOutputOverride -Blueprint $Blueprint
    if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override.Grade)) {
        return (Normalize-SCMiningComponentGrade -Grade ([string]$override.Grade))
    }

    if ([string]$Blueprint.source -eq 'SCMDB') { return (Normalize-SCMiningComponentGrade -Grade ([string]$Blueprint.output.grade)) }
    $item = Get-SCMiningCachedItemInfo -Blueprint $Blueprint -ItemLookup $ItemLookup
    if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.grade)) {
        return (Normalize-SCMiningComponentGrade -Grade ([string]$item.grade))
    }

    if ($null -ne $Blueprint.output -and -not [string]::IsNullOrWhiteSpace([string]$Blueprint.output.grade)) {
        return (Normalize-SCMiningComponentGrade -Grade ([string]$Blueprint.output.grade))
    }

    return ''
}

function Get-SCMiningBlueprintOutputComponentClass {
    param(
        [object]$Blueprint,
        [hashtable]$ItemLookup
    )

    $override = Get-SCMiningBlueprintOutputOverride -Blueprint $Blueprint
    if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override.ComponentClass)) {
        return ([string]$override.ComponentClass).Trim()
    }

    $name = Get-SCMiningBlueprintOutputName -Blueprint $Blueprint -Reward $null
    $class = Get-SCMiningBlueprintOutputClass -Blueprint $Blueprint -Reward $null

    switch -Regex ($name) {
        '^(Frontline|Holdstrong|Main Powerplant)$' { return '' }
        '^(JS-300|JS-400|JS-500|QuadraCell|QuadraCell MT|QuadraCell MX|VK-00|XL-1|TS-2|FR-66|FR-76|FR-86|Avalanche|Blizzard|Glacier)$' { return 'Military' }
        '^(LumaCore|LuxCore)$' { return 'Competition' }
        '^(Breton|Genoa|Durango|Ultra-Flow|Snowpack|Chill-Max|Algid|Palisade|Rampart|Parapet|Glacis|RS-Barrier)$' { return 'Industrial' }
        '^(Lotus|TigerLilly|Stellate|WhiteRose|Atlas|Hemera|Erebos|Allegro|Tepilo|Gelid|Aufeis|Draug|Elsen|Kragen|Serac|[567](CA|MA|SA)\s+''[^'']+'')$' { return 'Civilian' }
        '^(Slipstream|Eclipse|SnowBlind|NightFall|Spectre|Spicule|Mirage|Umbra)$' { return 'Stealth' }
        '^(Abetti|Agrippa|Anysta|Fabian)$' { return 'Civilian' }
        '^(Cassandra|Pelerous|Prophet)$' { return 'Stealth' }
        '^(FullSpec|FullSpec-Go|FullSpec-Max)$' { return 'Industrial' }
        '^(V60-26|V801-11|V801-12|V880)$' { return 'Military' }
    }

    if ([string]$Blueprint.source -eq 'SCMDB' -and [string]$Blueprint.output.componentClass -in @('Military', 'Stealth', 'Competition', 'Civilian', 'Industrial')) { return [string]$Blueprint.output.componentClass }
    $item = Get-SCMiningCachedItemInfo -Blueprint $Blueprint -ItemLookup $ItemLookup
    if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.class)) {
        return ([string]$item.class).Trim()
    }

    if ($name -match '^(Mirage|Umbra|Spectre|Spicule|Eclipse|SnowBlind)$') {
        return 'Stealth'
    }
    if ($name -match '^(FR-86|TS-2|VK-00|XL-1|JS-300|JS-400|QuadraCell MX|Avalanche|Blizzard|Glacier|V60-26|V801-11|V801-12|V880)$') {
        return 'Military'
    }

    if ($class -match '^(shld_asas|powr_acom|cool_jokr)') {
        return 'Stealth'
    }
    if ($class -match '^(shld_godi|qdrv_wetk|powr_amrs|cool_aegs|radr_grnp)') {
        return 'Military'
    }

    return ''
}

function Get-SCMiningBlueprintOutputOverride {
    param([object]$Blueprint)

    $key = [string]$Blueprint.key
    if ([string]::IsNullOrWhiteSpace($key)) {
        return $null
    }

    # Star Citizen Wiki occasionally links a blueprint key to the wrong output item.
    # Keep these corrections narrow and verified against live localization and item data caches.
    switch -Regex ($key) {
        '^BP_CRAFT_COOL_TYDT_S02_HeatSink_SCItem$' {
            return [pscustomobject]@{
                Name = 'HeatSink'
                Class = 'cool_tydt_s02_heatsink_scitem'
                Type = 'Cooler'
                Grade = 'C'
                ComponentClass = 'Stealth'
            }
        }
        '^BP_CRAFT_COOL_TYDT_S02_IceBox_SCItem$' {
            return [pscustomobject]@{
                Name = 'IceBox'
                Class = 'cool_tydt_s02_icebox_scitem'
                Type = 'Cooler'
                Grade = 'B'
                ComponentClass = 'Stealth'
            }
        }
        '^BP_CRAFT_COOL_TYDT_S02_NightFall_SCItem$' {
            return [pscustomobject]@{
                Name = 'NightFall'
                Class = 'cool_tydt_s02_nightfall_scitem'
                Type = 'Cooler'
                Grade = 'A'
                ComponentClass = 'Stealth'
            }
        }
        '^BP_CRAFT_POWR_AMRS_S03_JS500_SCItem$' {
            return [pscustomobject]@{
                Name = 'JS-500'
                Class = 'powr_amrs_s03_js500_scitem'
                Type = 'Power Plant'
                Grade = 'A'
                ComponentClass = 'Military'
            }
        }
        '^BP_CRAFT_POWR_JUST_S01_Endurance_SCItem$' {
            return [pscustomobject]@{
                Name = 'Endurance'
                Class = 'powr_just_s01_endurance_scitem'
                Type = 'Power Plant'
                Grade = 'B'
                ComponentClass = 'Industrial'
            }
        }
        '^BP_CRAFT_POWR_SASU_S01_WhiteRose_SCItem$' {
            return [pscustomobject]@{
                Name = 'WhiteRose'
                Class = 'powr_sasu_s01_whiterose_scitem'
                Type = 'Power Plant'
                Grade = 'A'
                ComponentClass = 'Civilian'
            }
        }
        '^BP_CRAFT_POWR_SASU_S02_DayBreak_SCItem$' {
            return [pscustomobject]@{
                Name = 'DayBreak'
                Class = 'powr_sasu_s02_daybreak_scitem'
                Type = 'Power Plant'
                Grade = 'C'
                ComponentClass = 'Civilian'
            }
        }
        '^BP_CRAFT_QDRV_JUST_S01_Goliath_SCItem$' {
            return [pscustomobject]@{
                Name = 'Goliath'
                Class = 'qdrv_just_s01_goliath_scitem'
                Type = 'Quantum Drive'
                Grade = 'C'
                ComponentClass = 'Industrial'
            }
        }
        '^BP_CRAFT_QDRV_WETK_S01_Beacon_SCItem$' {
            return [pscustomobject]@{
                Name = 'Beacon'
                Class = 'qdrv_wetk_s01_beacon_scitem'
                Type = 'Quantum Drive'
                Grade = 'C'
                ComponentClass = 'Military'
            }
        }
        '^BP_CRAFT_RADR_WLOP_S00_Denning$' {
            return [pscustomobject]@{
                Name = 'Denning'
                Class = 'radr_wlop_s00_denning'
                Type = 'Radar'
                Grade = 'C'
                ComponentClass = 'Civilian'
            }
        }
        '^BP_CRAFT_RADR_WLOP_S00_Fabian$' {
            return [pscustomobject]@{
                Name = 'Fabian'
                Class = 'radr_wlop_s00_fabian'
                Type = 'Radar'
                Grade = 'A'
                ComponentClass = 'Civilian'
            }
        }
        '^BP_CRAFT_RADR_WLOP_S00_Vogel$' {
            return [pscustomobject]@{
                Name = 'Vogel'
                Class = 'radr_wlop_s00_vogel'
                Type = 'Radar'
                Grade = 'B'
                ComponentClass = 'Civilian'
            }
        }
        '^BP_CRAFT_SHLD_SECO_S03_ARMOR_SCItem$' {
            return [pscustomobject]@{
                Name = 'ARMOR'
                Class = 'shld_seco_s03_armor_scitem'
                Type = 'Shield'
                Grade = 'B'
                ComponentClass = 'Civilian'
            }
        }
    }

    return $null
}

function Test-SCMiningCanonicalBlueprint {
    param(
        [object]$Blueprint,
        [object]$Reward
    )

    $key = [regex]::Replace([string]$Blueprint.key, '(?i)^BP_CRAFT_', '')
    $outputClass = Get-SCMiningBlueprintOutputClass -Blueprint $Blueprint -Reward $Reward
    return ((ConvertTo-SCMiningCanonicalToken -Value $key) -eq (ConvertTo-SCMiningCanonicalToken -Value $outputClass))
}

function ConvertTo-SCMiningCanonicalToken {
    param([AllowEmptyString()][string]$Value)

    return ([regex]::Replace(([string]$Value).ToLowerInvariant(), '[^a-z0-9]', ''))
}

function Set-SCMiningItemCraftHint {
    param(
        [AllowEmptyString()][string]$Value,
        [string[]]$Resources
    )

    $clean = Remove-SCMiningItemCraftHint -Value $Value
    $wikeloBlock = Get-SCMiningWikeloItemHintBlock -Value $clean
    $passportBlock = Get-SCMiningItemPassportBlock -Value $clean
    $base = Trim-SCMiningEncodedTrailingBreaks -Value (Remove-SCMiningItemPassportBlock -Value (Remove-SCMiningWikeloItemHintBlock -Value $clean))
    $resourceText = (@($Resources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ')
    if ([string]::IsNullOrWhiteSpace($resourceText)) {
        return $base
    }

    $sections = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($base)) {
        $sections.Add($base)
    }
    if (-not [string]::IsNullOrWhiteSpace($wikeloBlock)) {
        $sections.Add($wikeloBlock)
    }
    $sections.Add((Get-SCMiningItemCraftHintLine -ResourcesText $resourceText))
    if (-not [string]::IsNullOrWhiteSpace($passportBlock)) {
        $sections.Add($passportBlock)
    }

    return (($sections.ToArray()) -join '\n\n').TrimEnd()
}

function Get-SCMiningItemPassportBlock {
    param([AllowEmptyString()][string]$Value)

    $labelPattern = '(?:' + [regex]::Escape((Get-SCMiningLegacyItemPassportLabel)) + '|' + [regex]::Escape((Get-SCMiningOlderItemPassportLabel)) + '|' + [regex]::Escape((Get-SCMiningItemPassportLabel)) + ')'
    $pattern = '(?s)(?<block>\\n\\n(?:<EM[1-5]>)?' + $labelPattern + '(?:</EM[1-5]>)?(?:\\n(?!\\n).*){0,4})(?=\\n\\n|$)'
    $match = [regex]::Match([string]$Value, $pattern)
    if (-not $match.Success) {
        return ''
    }

    return (Trim-SCMiningEncodedLeadingBreaks -Value ([string]$match.Groups['block'].Value))
}

function Get-SCMiningWikeloItemHintBlock {
    param([AllowEmptyString()][string]$Value)

    $stopLabels = @(
        [regex]::Escape((Get-SCMiningItemCraftHintLabel)),
        [regex]::Escape((Get-SCMiningItemPassportLabel)),
        [regex]::Escape((Get-SCMiningLegacyItemPassportLabel)),
        [regex]::Escape((Get-SCMiningOlderItemPassportLabel))
    ) -join '|'
    $pattern = '(?s)(?<block>\\n\\n<EM\d>Wikelo(?:-| )заказы:?</EM\d>.*?)(?=\\n\\n(?:<EM[1-5]>)?(?:' + $stopLabels + ')|$)'
    $match = [regex]::Match([string]$Value, $pattern)
    if (-not $match.Success) {
        return ''
    }

    return (Trim-SCMiningEncodedLeadingBreaks -Value ([string]$match.Groups['block'].Value))
}

function Remove-SCMiningWikeloItemHintBlock {
    param([AllowEmptyString()][string]$Value)

    $stopLabels = @(
        [regex]::Escape((Get-SCMiningItemCraftHintLabel)),
        [regex]::Escape((Get-SCMiningItemPassportLabel)),
        [regex]::Escape((Get-SCMiningLegacyItemPassportLabel)),
        [regex]::Escape((Get-SCMiningOlderItemPassportLabel))
    ) -join '|'
    $pattern = '\\n\\n<EM\d>Wikelo(?:-| )заказы:?</EM\d>.*?(?=\\n\\n(?:<EM[1-5]>)?(?:' + $stopLabels + ')|$)'
    return [regex]::Replace([string]$Value, $pattern, '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

function Remove-SCMiningItemCraftHint {
    param([AllowEmptyString()][string]$Value)

    $labelPattern = [regex]::Escape((Get-SCMiningItemCraftHintLabel))
    $pattern = '(?:\\n){0,2}(?:<EM[1-5]>)?' + $labelPattern + '(?:</EM[1-5]>)?\s*[^\\]*(?=$|\\n)'
    $clean = [regex]::Replace([string]$Value, $pattern, '')
    return (Trim-SCMiningEncodedTrailingBreaks -Value $clean)
}

function Get-SCMiningItemCraftHintLine {
    param([string]$ResourcesText)

    return (Get-SCMiningItemCraftHintLabel) + ' ' + $ResourcesText
}

function Get-SCMiningItemCraftHintLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041A, 0x0440, 0x0430, 0x0444, 0x0442, 0x003A))
}

function Get-SCMiningRefineryYieldData {
    $scmdbCache = Read-SCMiningScmdbCache
    $cached = Get-SCMiningCachedRefineryYields -CacheKey ([string]$scmdbCache.Version)
    if ($null -eq $cached) {
        throw "Mining refinery yields cache is missing for SCMDB version $($scmdbCache.Version). Refresh cache before applying."
    }

    return $cached
}

function Get-SCMiningCachedRefineryYields {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($CacheKey)) {
        $path = Get-SCMiningRefineryYieldCachePath -CacheKey $CacheKey
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $cacheFile = Get-Item -LiteralPath $path
        }
        else {
            $cacheFile = $null
        }
    }
    else {
        $cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'refinery-yields-*.json' -File |
            Where-Object { $_.Name -match '(?i)-live\.' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    if ($null -eq $cacheFile) {
        return $null
    }

    try {
        $cache = Get-Content -LiteralPath $cacheFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($cache.PSObject.Properties['stations'] -and @($cache.stations).Count -gt 0) {
            return $cache
        }
    }
    catch {
    }

    return $null
}

function Get-SCMiningRefineryYieldCachePath {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    return (Join-Path $cacheDir ("refinery-yields-{0}.json" -f (Get-SCMiningSafeCacheKey -CacheKey $CacheKey)))
}

function Get-SCMiningRefineryYields {
    param(
        [hashtable]$Headers,
        [string]$CacheKey,
        [switch]$ForceRefresh
    )

    $cachePath = Get-SCMiningRefineryYieldCachePath -CacheKey $CacheKey
    if (-not $ForceRefresh -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        $cached = Get-SCMiningCachedRefineryYields -CacheKey $CacheKey
        if ($null -ne $cached) {
            return $cached
        }

        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    }

    $raw = Invoke-SCMiningScmdbJson -Uri 'https://api.uexcorp.uk/2.0/refineries_yields' -Headers $Headers
    $records = @($raw.data)
    if ($records.Count -eq 0) {
        throw 'UEX refineries_yields returned no data.'
    }

    $payload = ConvertTo-SCMiningRefineryYieldCachePayload -CacheKey $CacheKey -Records $records
    Write-SCMiningRefineryYieldCache -CachePath $cachePath -Payload $payload
    return $payload
}

function ConvertTo-SCMiningRefineryYieldCachePayload {
    param(
        [string]$CacheKey,
        [object[]]$Records
    )

    $stations = @()
    foreach ($group in ($Records | Group-Object {
        if (-not [string]::IsNullOrWhiteSpace([string]$_.space_station_name)) {
            [string]$_.space_station_name
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$_.outpost_name)) {
            [string]$_.outpost_name
        }
        else {
            [string]$_.terminal_name
        }
    })) {
        if ([string]::IsNullOrWhiteSpace([string]$group.Name)) {
            continue
        }

        $entries = @(
            $group.Group |
                ForEach-Object {
                    [pscustomobject]@{
                        material = ([regex]::Replace([string]$_.commodity_name, '\s+\((Ore|Raw)\)$', ''))
                        value = [int]$_.value_month
                    }
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.material) -and [int]$_.value -ne 0 }
        )

        $yields = @($entries | Sort-Object @{ Expression = { [int]$_.value }; Descending = $true }, material)
        $best = @($entries | Where-Object { [int]$_.value -gt 0 } | Sort-Object @{ Expression = { [int]$_.value }; Descending = $true }, material)
        $penalties = @($entries | Where-Object { [int]$_.value -lt 0 } | Sort-Object @{ Expression = { [int]$_.value }; Ascending = $true }, material)

        $stations += [pscustomobject]@{
            name = [string]$group.Name
            aliases = @(Get-SCMiningRefineryYieldAliases -StationName ([string]$group.Name))
            yields = @($yields)
            best = @($best)
            penalties = @($penalties)
        }
    }

    return [pscustomobject]@{
        cacheKey = [string]$CacheKey
        createdAt = (Get-Date).ToString('o')
        source = 'UEX refineries_yields'
        sourceUrl = 'https://uexcorp.space/mining/refineries'
        apiUrl = 'https://api.uexcorp.uk/2.0/refineries_yields'
        gameVersion = [string]$CacheKey
        values = 'value_month'
        records = @($Records).Count
        stations = @($stations | Sort-Object name)
    }
}

function Get-SCMiningRefineryYieldAliases {
    param([string]$StationName)

    $aliases = @()
    if ($StationName -match '^(ARC|CRU|HUR|MIC)-L\d\b') {
        $aliases += $Matches[0]
    }
    if ($StationName -eq 'Checkmate Station') {
        $aliases += 'Checkmate'
        $aliases += 'Checkmate Refinery'
    }
    if ($StationName -match '^(?<name>.+ Gateway) \([^)]+\)$') {
        $aliases += $Matches['name']
    }
    if ($StationName -eq 'Ruin Station') {
        $aliases += 'Ruin Station Refinery'
    }
    if ($StationName -eq 'Refinement Center - Levski') {
        $aliases += 'Levski'
    }

    return @($aliases | Sort-Object -Unique)
}

function Write-SCMiningRefineryYieldCache {
    param(
        [string]$CachePath,
        [object]$Payload
    )

    $cacheDir = Split-Path -Parent $CachePath
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    }

    $json = $Payload | ConvertTo-Json -Depth 10
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($CachePath, $json, $encoding)
}

function Get-SCMiningLocationTradeData {
    $scmdbCache = Read-SCMiningScmdbCache
    $cached = Get-SCMiningCachedLocationTrade -CacheKey ([string]$scmdbCache.Version)
    if ($null -eq $cached) {
        throw "Mining raw ore buy price cache is missing for SCMDB version $($scmdbCache.Version). Refresh cache before applying."
    }

    return $cached
}

function Get-SCMiningCachedLocationTrade {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($CacheKey)) {
        $path = Get-SCMiningLocationTradeCachePath -CacheKey $CacheKey
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $cacheFile = Get-Item -LiteralPath $path
        }
        else {
            $legacyPath = Get-SCMiningLocationTradeLegacyCachePath -CacheKey $CacheKey
            if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
                $cacheFile = Get-Item -LiteralPath $legacyPath
            }
            else {
                $cacheFile = $null
            }
        }
    }
    else {
        $cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'raw-ore-buy-prices-*.json' -File |
            Where-Object { $_.Name -match '(?i)-live\.' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $cacheFile) {
            $cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'location-trade-*.json' -File |
                Where-Object { $_.Name -match '(?i)-live\.' } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
        }
    }

    if ($null -eq $cacheFile) {
        return $null
    }

    try {
        $cache = Get-Content -LiteralPath $cacheFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($cache.PSObject.Properties['locations'] -and @($cache.locations).Count -gt 0) {
            return $cache
        }
    }
    catch {
    }

    return $null
}

function Get-SCMiningLocationTradeCachePath {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    return (Join-Path $cacheDir ("raw-ore-buy-prices-{0}.json" -f (Get-SCMiningSafeCacheKey -CacheKey $CacheKey)))
}

function Get-SCMiningLocationTradeLegacyCachePath {
    param([string]$CacheKey)

    $cacheDir = Get-SCMiningCacheDirectory
    return (Join-Path $cacheDir ("location-trade-{0}.json" -f (Get-SCMiningSafeCacheKey -CacheKey $CacheKey)))
}

function Get-SCMiningLocationTradePrices {
    param(
        [hashtable]$Headers,
        [string]$CacheKey,
        [switch]$ForceRefresh
    )

    $cachePath = Get-SCMiningLocationTradeCachePath -CacheKey $CacheKey
    if (-not $ForceRefresh -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        $cached = Get-SCMiningCachedLocationTrade -CacheKey $CacheKey
        if ($null -ne $cached) {
            return $cached
        }

        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    }

    $terminalsRaw = Invoke-SCMiningScmdbJson -Uri 'https://api.uexcorp.uk/2.0/terminals' -Headers $Headers
    $rawPricesRaw = Invoke-SCMiningScmdbJson -Uri 'https://api.uexcorp.uk/2.0/commodities_raw_prices_all' -Headers $Headers

    $terminals = @($terminalsRaw.data)
    $rawPrices = @($rawPricesRaw.data)
    if ($terminals.Count -eq 0 -or $rawPrices.Count -eq 0) {
        throw 'UEX raw ore endpoints returned no data.'
    }

    $payload = ConvertTo-SCMiningLocationTradeCachePayload -CacheKey $CacheKey -Terminals $terminals -RawPrices $rawPrices
    Write-SCMiningLocationTradeCache -CachePath $cachePath -Payload $payload
    return $payload
}

function ConvertTo-SCMiningLocationTradeCachePayload {
    param(
        [string]$CacheKey,
        [object[]]$Terminals,
        [object[]]$RawPrices
    )

    $terminalById = @{}
    foreach ($terminal in @($Terminals)) {
        $id = [string]$terminal.id
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $terminalById[$id] = $terminal
        }
    }

    $locationMap = @{}
    foreach ($record in @($RawPrices)) {
        $terminal = $terminalById[[string]$record.id_terminal]
        if ($null -eq $terminal -or [string]$terminal.type -ne 'commodity_raw') {
            continue
        }

        $locationName = Get-SCMiningLocationTradeTerminalDisplayName -Terminal $terminal -Fallback ([string]$record.terminal_name)
        if ([string]::IsNullOrWhiteSpace($locationName) -or [int]$record.price_sell -le 0) {
            continue
        }

        Add-SCMiningLocationTradeRecord -LocationMap $locationMap -LocationName $locationName -Terminal $terminal -Kind 'rawBuys' -Commodity ([string]$record.commodity_name) -Price ([int]$record.price_sell)
    }

    $locations = @()
    foreach ($entry in @($locationMap.GetEnumerator() | Sort-Object Name)) {
        $value = $entry.Value
        $rawBuys = @(Merge-SCMiningLocationTradeEntries -Entries @($value.rawBuys) -PreferHighPrice)
        if ($rawBuys.Count -eq 0) {
            continue
        }

        $locations += [pscustomobject]@{
            name = [string]$value.name
            aliases = @($value.aliases | Sort-Object -Unique)
            rawBuys = @($rawBuys)
        }
    }

    return [pscustomobject]@{
        cacheKey = [string]$CacheKey
        createdAt = (Get-Date).ToString('o')
        source = 'UEX terminals + commodities_raw_prices_all'
        sourceUrl = 'https://uexcorp.space/api/documentation'
        apiUrls = @(
            'https://api.uexcorp.uk/2.0/terminals',
            'https://api.uexcorp.uk/2.0/commodities_raw_prices_all'
        )
        gameVersion = [string]$CacheKey
        values = 'price_sell terminal buys raw ore from player'
        terminalRecords = @($Terminals).Count
        rawPriceRecords = @($RawPrices).Count
        locations = @($locations)
    }
}

function Get-SCMiningLocationTradeTerminalDisplayName {
    param(
        [object]$Terminal,
        [string]$Fallback
    )

    foreach ($field in @('displayname', 'space_station_name', 'outpost_name', 'city_name', 'name')) {
        $value = [string]$Terminal.$field
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return [string]$Fallback
}

function Add-SCMiningLocationTradeRecord {
    param(
        [hashtable]$LocationMap,
        [string]$LocationName,
        [object]$Terminal,
        [string]$Kind,
        [string]$Commodity,
        [int]$Price
    )

    if ([string]::IsNullOrWhiteSpace($LocationName) -or [string]::IsNullOrWhiteSpace($Commodity) -or $Price -le 0) {
        return
    }

    if (-not $LocationMap.ContainsKey($LocationName)) {
        $LocationMap[$LocationName] = [pscustomobject]@{
            name = $LocationName
            aliases = @()
            rawBuys = @()
        }
    }

    $location = $LocationMap[$LocationName]
    $aliases = @($location.aliases + @(Get-SCMiningLocationTradeAliases -LocationName $LocationName -Terminal $Terminal) | Sort-Object -Unique)
    $location.aliases = @($aliases)
    $entry = [pscustomobject]@{
        commodity = [regex]::Replace($Commodity, '\s+\((Ore|Raw)\)$', '')
        price = $Price
    }
    $location.$Kind = @($location.$Kind + $entry)
}

function Merge-SCMiningLocationTradeEntries {
    param(
        [object[]]$Entries,
        [switch]$PreferHighPrice
    )

    $result = @()
    foreach ($group in (@($Entries) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.commodity) -and [int]$_.price -gt 0 } | Group-Object commodity)) {
        if ($PreferHighPrice) {
            $entry = @($group.Group | Sort-Object @{ Expression = { [int]$_.price }; Descending = $true } | Select-Object -First 1)[0]
        }
        else {
            $entry = @($group.Group | Sort-Object @{ Expression = { [int]$_.price }; Descending = $false } | Select-Object -First 1)[0]
        }

        $result += [pscustomobject]@{
            commodity = [string]$entry.commodity
            price = [int]$entry.price
        }
    }

    if ($PreferHighPrice) {
        return @($result | Sort-Object @{ Expression = { -[int]$_.price } }, commodity)
    }

    return @($result | Sort-Object commodity)
}

function Get-SCMiningLocationTradeAliases {
    param(
        [string]$LocationName,
        [object]$Terminal
    )

    $aliases = @()
    if ($LocationName -match '^(ARC|CRU|HUR|MIC)-L\d\b') {
        $aliases += $Matches[0]
    }
    if ($LocationName -match '^(?<name>.+ Gateway) \([^)]+\)$') {
        $aliases += $Matches['name']
    }
    foreach ($field in @('nickname', 'space_station_name', 'outpost_name', 'city_name')) {
        $value = [string]$Terminal.$field
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $aliases += $value
        }
    }

    return @($aliases | Sort-Object -Unique)
}

function Write-SCMiningLocationTradeCache {
    param(
        [string]$CachePath,
        [object]$Payload
    )

    $cacheDir = Split-Path -Parent $CachePath
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    }

    $json = $Payload | ConvertTo-Json -Depth 10
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($CachePath, $json, $encoding)
}

function Find-SCMiningRefineryYieldStation {
    param(
        [string]$Key,
        [hashtable]$Values,
        [object[]]$Stations,
        [object[]]$StationMatchEntries
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return $null
    }

    $relatedValues = @(Get-SCMiningRefineryYieldRelatedTitleValues -Key $Key -Values $Values)
    if ($relatedValues.Count -eq 0) {
        return $null
    }

    $matchEntries = @($StationMatchEntries)
    if ($matchEntries.Count -eq 0) {
        $matchEntries = @(
            foreach ($station in @($Stations)) {
                [pscustomobject]@{
                    Station = $station
                    Candidates = @(Get-SCMiningRefineryYieldStationCandidates -Station $station | Sort-Object { $_.Length } -Descending)
                }
            }
        )
    }

    foreach ($matchEntry in $matchEntries) {
        $station = $matchEntry.Station
        if (-not (Test-SCMiningRefineryYieldKeyQualifier -Key $Key -StationName ([string]$station.name))) {
            continue
        }

        foreach ($candidate in @($matchEntry.Candidates)) {
            if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.Length -lt 5) {
                continue
            }
            if (-not (Test-SCMiningRefineryYieldCandidateKeyScope -Key $Key -Candidate $candidate)) {
                continue
            }

            foreach ($value in $relatedValues) {
                if ($value.IndexOf($candidate, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    return $station
                }
            }
        }
    }

    return $null
}

function Get-SCMiningRefineryYieldStationCandidates {
    param([object]$Station)

    $candidates = New-Object System.Collections.Generic.List[string]
    $stationName = [string]$Station.name
    if (-not [string]::IsNullOrWhiteSpace($stationName)) {
        $candidates.Add($stationName)
        if ($stationName -eq 'Checkmate Station') {
            $candidates.Add('Checkmate')
        }
        if ($stationName -match '^(?<name>.+ Gateway) \([^)]+\)$') {
            $candidates.Add($Matches['name'])
        }
    }
    foreach ($alias in @($Station.aliases)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$alias)) {
            $candidates.Add([string]$alias)
        }
    }

    return @($candidates.ToArray() | Sort-Object -Unique)
}

function Get-SCMiningRefineryYieldRelatedTitleValues {
    param(
        [string]$Key,
        [hashtable]$Values
    )

    $knownLocationTitle = Get-SCMiningRefineryYieldKnownLocationTitle -Key $Key -Values $Values
    if (-not [string]::IsNullOrWhiteSpace($knownLocationTitle)) {
        return @($knownLocationTitle)
    }

    $baseKey = Get-SCMiningRefineryYieldBaseKey -Key $Key
    if ([string]::IsNullOrWhiteSpace($baseKey)) {
        return @()
    }

    $candidateKeys = @(
        $baseKey,
        "$baseKey,P",
        "$baseKey,PU"
    )
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($candidateKey in $candidateKeys) {
        if ($Values.ContainsKey($candidateKey)) {
            $value = [string]$Values[$candidateKey]
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $result.Add($value)
            }
        }
    }

    return @($result.ToArray())
}

function Get-SCMiningRefineryYieldKnownLocationTitle {
    param(
        [string]$Key,
        [hashtable]$Values
    )

    $cleanKey = ([string]$Key -replace ',.*$', '')
    if ($cleanKey -eq 'text_level_info_description_Levski') {
        return 'Levski'
    }
    if ($cleanKey -match '^(?<base>ui_pregame_port_.+)_desc$') {
        $nameKey = $Matches['base'] + '_name'
        if ($Values.ContainsKey($nameKey)) {
            return [string]$Values[$nameKey]
        }
    }

    return ''
}

function Get-SCMiningRefineryYieldBaseKey {
    param([string]$Key)

    $cleanKey = ([string]$Key -replace ',.*$', '')
    if ($cleanKey -match '(?i)^(?<base>.+?)_(?:desc|description)$') {
        return $Matches['base']
    }

    return ''
}

function Test-SCMiningRefineryYieldKeyQualifier {
    param(
        [string]$Key,
        [string]$StationName
    )

    if ($StationName -notmatch '\((?<system>[^)]+)\)$') {
        return $true
    }

    $system = $Matches['system']
    return $Key.StartsWith($system + '_', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SCMiningRefineryYieldCandidateKeyScope {
    param(
        [string]$Key,
        [string]$Candidate
    )

    if ($Candidate -match '^(ARC|CRU|HUR|MIC)-L\d$') {
        return $Key.StartsWith('RR_', [System.StringComparison]::OrdinalIgnoreCase)
    }

    return $true
}

function Set-SCMiningRefineryYieldHint {
    param(
        [AllowEmptyString()][string]$Value,
        [object]$Station
    )

    $clean = Remove-SCMiningRefineryYieldHint -Value $Value
    $line = Get-SCMiningRefineryYieldHintLine -Station $Station
    if ([string]::IsNullOrWhiteSpace($line)) {
        return $clean
    }

    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $line
    }

    return ($clean.TrimEnd() + '\n\n' + $line).TrimEnd()
}

function Remove-SCMiningRefineryYieldHint {
    param([AllowEmptyString()][string]$Value)

    $labelPattern = [regex]::Escape((Get-SCMiningRefineryYieldHintLabel)) + ':?'
    $linePattern = '<EM[1-5]>' + $labelPattern + '</EM[1-5]>\s*[^\\]*(?=$|\\n)'
    $blockPattern = '(?:\\n){0,2}' + $linePattern + '(?:\\n<EM[1-5]>(?:' + [regex]::Escape((Get-SCMiningRefineryBonusLabel)) + '|' + [regex]::Escape((Get-SCMiningRefineryPenaltyLabel)) + ')</EM[1-5]>\s*[^\\]*(?=$|\\n)){0,2}'
    $pattern = $blockPattern
    if (-not [regex]::IsMatch([string]$Value, $pattern)) {
        return [string]$Value
    }

    $clean = [regex]::Replace([string]$Value, $pattern, '')
    return (Trim-SCMiningEncodedTrailingBreaks -Value $clean)
}

function Get-SCMiningRefineryYieldHintLine {
    param([object]$Station)

    $stationYields = @()
    if ($Station.PSObject.Properties['yields']) {
        $stationYields = @($Station.yields)
    }

    if ($stationYields.Count -gt 0) {
        $bestEntries = @($stationYields | Where-Object { [int]$_.value -gt 0 } | Sort-Object @{ Expression = { [int]$_.value }; Descending = $true }, material)
        $penaltyEntries = @($stationYields | Where-Object { [int]$_.value -lt 0 } | Sort-Object @{ Expression = { [int]$_.value }; Ascending = $true }, material)
    }
    else {
        $bestEntries = @($Station.best)
        $penaltyEntries = @($Station.penalties)
    }

    $best = @(Format-SCMiningRefineryYieldParts -Entries @($bestEntries) -Positive)
    $penalties = @(Format-SCMiningRefineryYieldParts -Entries @($penaltyEntries))
    if ($best.Count -eq 0 -and $penalties.Count -eq 0) {
        return ''
    }

    $segments = New-Object System.Collections.Generic.List[string]
    if ($best.Count -gt 0) {
        $segments.Add('<EM4>' + (Get-SCMiningRefineryBonusLabel) + '</EM4> ' + ($best -join ', '))
    }
    if ($penalties.Count -gt 0) {
        $segments.Add('<EM4>' + (Get-SCMiningRefineryPenaltyLabel) + '</EM4> ' + ($penalties -join ', '))
    }

    return '<EM4>' + (Get-SCMiningRefineryYieldHintLabel) + '</EM4>' + '\n' + ($segments.ToArray() -join '\n')
}

function Format-SCMiningRefineryYieldParts {
    param(
        [object[]]$Entries,
        [switch]$Positive
    )

    $parts = @()
    foreach ($entry in @($Entries)) {
        $material = [string]$entry.material
        $value = [int]$entry.value
        if ([string]::IsNullOrWhiteSpace($material) -or $value -eq 0) {
            continue
        }

        if ($Positive) {
            $parts += ('{0} +{1}%' -f $material, [Math]::Abs($value))
        }
        else {
            $parts += ('{0} -{1}%' -f $material, [Math]::Abs($value))
        }
    }

    return @($parts)
}

function Find-SCMiningLocationTradeLocation {
    param(
        [string]$Key,
        [hashtable]$Values,
        [object[]]$Locations,
        [object[]]$LocationMatchEntries
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return $null
    }

    $relatedValues = @(Get-SCMiningLocationTradeRelatedTitleValues -Key $Key -Values $Values)
    if ($relatedValues.Count -eq 0) {
        return $null
    }

    $matchEntries = @($LocationMatchEntries)
    if ($matchEntries.Count -eq 0) {
        $matchEntries = @(
            foreach ($location in @($Locations)) {
                [pscustomobject]@{
                    Location = $location
                    Candidates = @(Get-SCMiningLocationTradeCandidates -Location $location | Sort-Object { $_.Length } -Descending)
                }
            }
        )
    }

    foreach ($matchEntry in $matchEntries) {
        $location = $matchEntry.Location
        foreach ($candidate in @($matchEntry.Candidates)) {
            if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.Length -lt 4) {
                continue
            }
            if (-not (Test-SCMiningLocationTradeCandidateKeyScope -Key $Key -Candidate $candidate)) {
                continue
            }

            foreach ($value in $relatedValues) {
                if ($value.IndexOf($candidate, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    return $location
                }
            }
        }
    }

    return $null
}

function Get-SCMiningLocationTradeCandidates {
    param([object]$Location)

    $candidates = New-Object System.Collections.Generic.List[string]
    $locationName = [string]$Location.name
    if (-not [string]::IsNullOrWhiteSpace($locationName)) {
        $candidates.Add($locationName)
        if ($locationName -match '^(?<name>.+ Gateway) \([^)]+\)$') {
            $candidates.Add($Matches['name'])
        }
    }
    foreach ($alias in @($Location.aliases)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$alias)) {
            $candidates.Add([string]$alias)
        }
    }

    return @($candidates.ToArray() | Sort-Object -Unique)
}

function Get-SCMiningLocationTradeRelatedTitleValues {
    param(
        [string]$Key,
        [hashtable]$Values
    )

    $knownLocationTitle = Get-SCMiningLocationTradeKnownLocationTitle -Key $Key -Values $Values
    if (-not [string]::IsNullOrWhiteSpace($knownLocationTitle)) {
        return @($knownLocationTitle)
    }

    $baseKey = Get-SCMiningRefineryYieldBaseKey -Key $Key
    if ([string]::IsNullOrWhiteSpace($baseKey)) {
        return @()
    }

    $candidateKeys = @(
        $baseKey,
        "$baseKey,P",
        "$baseKey,PU",
        "$baseKey" + '_name'
    )
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($candidateKey in $candidateKeys) {
        if ($Values.ContainsKey($candidateKey)) {
            $value = [string]$Values[$candidateKey]
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $result.Add($value)
            }
        }
    }

    return @($result.ToArray())
}

function Get-SCMiningLocationTradeKnownLocationTitle {
    param(
        [string]$Key,
        [hashtable]$Values
    )

    return (Get-SCMiningRefineryYieldKnownLocationTitle -Key $Key -Values $Values)
}

function Test-SCMiningLocationTradeCandidateKeyScope {
    param(
        [string]$Key,
        [string]$Candidate
    )

    if ($Candidate -match '^(ARC|CRU|HUR|MIC)-L\d$') {
        return $Key.StartsWith('RR_', [System.StringComparison]::OrdinalIgnoreCase)
    }

    return $true
}

function Set-SCMiningLocationTradeHint {
    param(
        [AllowEmptyString()][string]$Value,
        [object]$Location
    )

    $clean = Remove-SCMiningLocationTradeHint -Value $Value
    $line = Get-SCMiningLocationTradeHintLine -Location $Location
    if ([string]::IsNullOrWhiteSpace($line)) {
        return $clean
    }

    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $line
    }

    return ($clean.TrimEnd() + '\n\n' + $line).TrimEnd()
}

function Remove-SCMiningLocationTradeHint {
    param([AllowEmptyString()][string]$Value)

    $labelPattern = '(?:' + [regex]::Escape((Get-SCMiningLocationTradeHintLabel)) + '|' + [regex]::Escape((Get-SCMiningLocationTradeLegacyHintLabel)) + '):?'
    $linePattern = '<EM[1-5]>' + $labelPattern + '</EM[1-5]>\s*[^\\]*(?=$|\\n)'
    $categoryPattern = '<EM[1-5]>(?:' +
        [regex]::Escape((Get-SCMiningLocationTradeBuysLabel)) + '|' +
        [regex]::Escape((Get-SCMiningLocationTradeSellsLabel)) + '|' +
        [regex]::Escape((Get-SCMiningLocationTradeRawBuysLabel)) +
        ')</EM[1-5]>\s*[^\\]*(?=$|\\n)'
    $blockPattern = '(?:\\n){0,2}' + $linePattern + '(?:\\n' + $categoryPattern + '){0,3}'
    if (-not [regex]::IsMatch([string]$Value, $blockPattern)) {
        return [string]$Value
    }

    $clean = [regex]::Replace([string]$Value, $blockPattern, '')
    return (Trim-SCMiningEncodedTrailingBreaks -Value $clean)
}

function Get-SCMiningLocationTradeHintLine {
    param([object]$Location)

    $rawBuys = @(Format-SCMiningLocationTradeParts -Entries @($Location.rawBuys))
    if ($rawBuys.Count -eq 0) {
        return ''
    }

    $segments = New-Object System.Collections.Generic.List[string]
    if ($rawBuys.Count -gt 0) {
        $segments.Add('<EM4>' + (Get-SCMiningLocationTradeRawBuysLabel) + '</EM4> ' + ($rawBuys -join ', '))
    }

    return '<EM4>' + (Get-SCMiningLocationTradeHintLabel) + '</EM4>' + '\n' + ($segments.ToArray() -join '\n')
}

function Format-SCMiningLocationTradeParts {
    param([object[]]$Entries)

    $parts = @()
    $sortedEntries = @($Entries) | Sort-Object @{ Expression = { -[int]$_.price } }, commodity
    foreach ($entry in @($sortedEntries)) {
        $commodity = [string]$entry.commodity
        $price = [int]$entry.price
        if ([string]::IsNullOrWhiteSpace($commodity) -or $price -le 0) {
            continue
        }

        $parts += ('{0} {1}' -f $commodity, (Format-SCMiningLocationTradePrice -Price $price))
    }

    return @($parts)
}

function Format-SCMiningLocationTradePrice {
    param([int]$Price)

    if ($Price -ge 1000000) {
        return ('{0:0.#}m' -f ($Price / 1000000.0))
    }
    if ($Price -ge 10000) {
        return ('{0:0.#}k' -f ($Price / 1000.0))
    }
    if ($Price -ge 1000) {
        return ('{0:0.##}k' -f ($Price / 1000.0))
    }

    return [string]$Price
}

function Get-SCMiningRefineryYieldHintLabel {
    return ((ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x0435, 0x0440, 0x0435, 0x0440, 0x0430, 0x0431, 0x043E, 0x0442, 0x043A, 0x0430)) + ' (UEX)')
}

function Get-SCMiningLocationTradeHintLabel {
    return ((ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x043A, 0x0443, 0x043F, 0x043A, 0x0430, 0x0020, 0x0441, 0x044B, 0x0440, 0x043E, 0x0439, 0x0020, 0x0440, 0x0443, 0x0434, 0x044B)) + ' (UEX, ' + (ConvertFrom-SCCodePoints -CodePoints @(0x043E, 0x0440, 0x0438, 0x0435, 0x043D, 0x0442, 0x0438, 0x0440)) + ')')
}

function Get-SCMiningLocationTradeLegacyHintLabel {
    return ((ConvertFrom-SCCodePoints -CodePoints @(0x0422, 0x043E, 0x0440, 0x0433, 0x043E, 0x0432, 0x043B, 0x044F)) + ' (UEX, ' + (ConvertFrom-SCCodePoints -CodePoints @(0x043E, 0x0440, 0x0438, 0x0435, 0x043D, 0x0442, 0x0438, 0x0440)) + ')')
}

function Get-SCMiningLocationTradeBuysLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x043E, 0x043A, 0x0443, 0x043F, 0x0430, 0x044E, 0x0442, 0x003A))
}

function Get-SCMiningLocationTradeSellsLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x0440, 0x043E, 0x0434, 0x0430, 0x044E, 0x0442, 0x003A))
}

function Get-SCMiningLocationTradeRawBuysLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0420, 0x0443, 0x0434, 0x0430, 0x003A))
}

function Get-SCMiningRefineryBonusLabel {
    return ((ConvertFrom-SCCodePoints -CodePoints @(0x0431, 0x043E, 0x043D, 0x0443, 0x0441, 0x044B)) + ':')
}

function Get-SCMiningRefineryPenaltyLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0448, 0x0442, 0x0440, 0x0430, 0x0444, 0x044B, 0x003A))
}

function Get-SCMiningResourceListLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0420, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B, 0x003A))
}

function Format-SCMiningMethodMarker {
    param([Parameter(Mandatory = $true)][string]$Method)

    if ($Method -eq (Get-SCMiningShipCode)) {
        return '<EM4>[' + (Get-SCMiningShipCode) + ']</EM4>'
    }

    return "[$Method]"
}

function Format-SCMiningLegendLine {
    param([string[]]$SelectedMethods)

    $labels = @{
        (Get-SCMiningShipCode) = (Get-SCMiningShipLabel)
        (Get-SCMiningGroundCode) = (Get-SCMiningGroundLabel)
        (Get-SCMiningHandCode) = (Get-SCMiningHandLabel)
    }

    $parts = @()
    foreach ($method in (Get-SCMiningMethodOrder)) {
        if ($method -in $SelectedMethods) {
            $parts += ((Format-SCMiningMethodMarker -Method $method) + ' ' + $labels[$method])
        }
    }

    return (Get-SCMiningLegendPrefix) + ($parts -join ', ') + '.'
}

function Split-SCMiningMethodParts {
    param([Parameter(Mandatory = $true)][string]$Text)

    $ship = [regex]::Escape((Format-SCMiningMethodMarker -Method (Get-SCMiningShipCode)))
    $ground = [regex]::Escape((Format-SCMiningMethodMarker -Method (Get-SCMiningGroundCode)))
    $hand = [regex]::Escape((Format-SCMiningMethodMarker -Method (Get-SCMiningHandCode)))
    $pattern = "($ship|$ground|$hand)\s*([^|]+)"
    $matches = [regex]::Matches($Text, $pattern)
    $parts = @()

    foreach ($match in $matches) {
        $marker = [string]$match.Groups[1].Value
        $resources = ([string]$match.Groups[2].Value).Trim()
        $method = $null
        if ($marker -eq (Format-SCMiningMethodMarker -Method (Get-SCMiningShipCode))) { $method = (Get-SCMiningShipCode) }
        elseif ($marker -eq (Format-SCMiningMethodMarker -Method (Get-SCMiningGroundCode))) { $method = (Get-SCMiningGroundCode) }
        elseif ($marker -eq (Format-SCMiningMethodMarker -Method (Get-SCMiningHandCode))) { $method = (Get-SCMiningHandCode) }

        if ($method) {
            $parts += [pscustomobject]@{
                Method = $method
                Text = ((Format-SCMiningMethodMarker -Method $method) + ' ' + $resources)
            }
        }
    }

    return @($parts)
}

function Update-SCMiningRecipeLine {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [string[]]$SelectedMethods
    )

    if ($Line -notmatch '^-\s+(.+?):\s+(.+)$') {
        return $Line
    }

    $label = $Matches[1]
    $methodsText = $Matches[2]
    $parts = @(
        Split-SCMiningMethodParts -Text $methodsText |
            Where-Object { $_.Method -in $SelectedMethods }
    )

    if ($parts.Count -eq 0) {
        return $null
    }

    return "- ${label}: " + ((@($parts | ForEach-Object { $_.Text })) -join ' | ')
}

function Compress-SCMiningCraftBlockHeadings {
    param([string[]]$Lines)

    $result = New-Object System.Collections.Generic.List[string]
    $pendingHeadings = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ($line -match '^<EM4>.+</EM4>$') {
            if ($pendingHeadings.Count -gt 0 -and
                $pendingHeadings[$pendingHeadings.Count - 1] -match ':</EM4>$' -and
                $line -match ':</EM4>$') {
                $pendingHeadings.RemoveAt($pendingHeadings.Count - 1)
            }
            $pendingHeadings.Add($line)
            continue
        }

        if ($line -match '^- ') {
            foreach ($heading in $pendingHeadings) {
                $result.Add($heading)
            }
            $pendingHeadings.Clear()
            $result.Add($line)
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
                $result.Add($line)
            }
            $pendingHeadings.Clear()
            continue
        }

        foreach ($heading in $pendingHeadings) {
            $result.Add($heading)
        }
        $pendingHeadings.Clear()
        $result.Add($line)
    }

    while ($result.Count -gt 0 -and [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
        $result.RemoveAt($result.Count - 1)
    }

    return @($result)
}

function Add-SCMiningCraftIntroGap {
    param([string[]]$Lines)

    $result = New-Object System.Collections.Generic.List[string]
    $introDone = $false
    $legendPrefix = Get-SCMiningLegendPrefix
    $filterPrefix = Get-SCMiningFilterPrefix
    foreach ($line in $Lines) {
        if (-not $introDone -and
            $result.Count -gt 0 -and
            $line -match '^<EM4>.+</EM4>$' -and
            ($result[$result.Count - 1].StartsWith($legendPrefix) -or $result[$result.Count - 1].StartsWith($filterPrefix))) {
            $result.Add('')
            $introDone = $true
        }

        $result.Add($line)
    }

    return @($result)
}

function Update-SCMiningCraftBlockMethods {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [string[]]$SelectedMethods,
        [hashtable]$PlanetCraftMap,
        [object]$CraftFilter,
        [object]$Inventory,
        [AllowNull()][string]$DetailedCraftBlock,
        [string[]]$AdditionalLocationBlocks = @()
    )

    $inventory = if ($null -ne $Inventory) { $Inventory } else { Read-SCMiningResourceInventoryFromValue -Value $Value }
    $detailedBlock = ''
    if ($PSBoundParameters.ContainsKey('DetailedCraftBlock')) {
        $detailedBlock = [string]$DetailedCraftBlock
    }
    elseif ($PlanetCraftMap -and $PlanetCraftMap.Count -gt 0) {
        $detailedBlock = Format-SCMiningPlanetCraftBlock -Inventory $inventory -PlanetCraftMap $PlanetCraftMap -SelectedMethods $SelectedMethods -CraftFilter $CraftFilter
    }
    else {
        $detailedBlock = Get-SCMiningFilteredDetailedCraftBlock -Value $Value -SelectedMethods $SelectedMethods
    }

    $basePrefix = Get-SCMiningBaseDescriptionPrefix -Value $Value
    $ownedBlock = Format-SCMiningOwnedResourceBlock -ResourcesByMethod $inventory.ResourcesByMethod -CollectableResources $inventory.CollectableResources -CreatureResources $inventory.CreatureResources -SelectedMethods $SelectedMethods -DetailedCraftBlock $detailedBlock
    $additionalBlocks = @($AdditionalLocationBlocks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($additionalBlocks.Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($ownedBlock)) {
            $ownedBlock = (Get-SCMiningCraftHeader) + '\n' + (Get-SCMiningPlanetTextFilters -SelectedMethods $SelectedMethods)
        }
        $ownedBlock += '\n\n' + ($additionalBlocks -join '\n\n')
    }
    if ([string]::IsNullOrWhiteSpace($ownedBlock)) {
        return $basePrefix.TrimEnd()
    }

    return ((Trim-SCMiningEncodedTrailingBreaks -Value $basePrefix) + '\n\n' + $ownedBlock).TrimEnd()
}

function Get-SCMiningFilteredDetailedCraftBlock {
    param(
        [AllowEmptyString()][string]$Value,
        [string[]]$SelectedMethods
    )

    $markerIndex = $Value.IndexOf((Get-SCMiningCraftHeader))
    if ($markerIndex -lt 0) {
        return ''
    }

    $lines = @($Value.Substring($markerIndex) -split '\\n')
    if (Test-SCMiningOwnedResourceBlockLines -Lines $lines) {
        return ''
    }

    $updated = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $trimmedLine = ([string]$line).Trim()
        if ($trimmedLine -eq (Get-SCMiningAsteroidBeltHeader)) {
            break
        }
        if (-not [string]::IsNullOrWhiteSpace($trimmedLine)) {
            if ($null -ne (Get-SCMiningReferenceKindFromLine -Line $trimmedLine)) {
                break
            }
        }

        if ($line.StartsWith((Get-SCMiningLegendPrefix))) {
            continue
        }

        if ($line -match '^- ') {
            $recipeLine = Update-SCMiningRecipeLine -Line $line -SelectedMethods $SelectedMethods
            if ($null -ne $recipeLine) {
                $updated.Add($recipeLine)
            }
            continue
        }

        $updated.Add($line)
    }

    $compressed = Compress-SCMiningCraftBlockHeadings -Lines @($updated)
    return ((Add-SCMiningCraftIntroGap -Lines @($compressed)) -join '\n').TrimEnd()
}

function Get-SCMiningBaseDescriptionPrefix {
    param([AllowEmptyString()][string]$Value)

    $indexes = @()
    $rawIndex = Get-SCMiningRawResourceBlockIndex -Value $Value
    if ($rawIndex -ge 0) {
        $indexes += $rawIndex
    }

    $craftIndex = $Value.IndexOf((Get-SCMiningCraftHeader))
    if ($craftIndex -ge 0) {
        $indexes += $craftIndex
    }

    if ($indexes.Count -eq 0) {
        return [string]$Value
    }

    return Trim-SCMiningEncodedTrailingBreaks -Value ($Value.Substring(0, [int]($indexes | Sort-Object | Select-Object -First 1)))
}

function Read-SCMiningResourceInventoryFromValue {
    param([AllowEmptyString()][string]$Value)

    $rawIndex = Get-SCMiningRawResourceBlockIndex -Value $Value
    if ($rawIndex -ge 0) {
        return Read-SCMiningRawResourceBlockInventory -Value ($Value.Substring($rawIndex))
    }

    $markerIndex = $Value.IndexOf((Get-SCMiningCraftHeader))
    if ($markerIndex -ge 0) {
        return Read-SCMiningOwnedResourceBlockInventory -Lines @($Value.Substring($markerIndex) -split '\\n')
    }

    return New-SCMiningEmptyResourceInventory
}

function Get-SCMiningPlanetResourceInventoryCachePath {
    $cacheDir = Join-Path $PSScriptRoot 'cache'
    return (Join-Path $cacheDir 'planet-resource-inventory-cache.json')
}

function Get-SCMiningPlanetResourceInventoryCache {
    $cache = @{}
    $cachePath = Get-SCMiningPlanetResourceInventoryCachePath
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try {
            $data = Get-Content -LiteralPath $cachePath -Encoding UTF8 -Raw | ConvertFrom-Json
            foreach ($property in @($data.planets.PSObject.Properties)) {
                $cache[[string]$property.Name] = $property.Value
            }
        }
        catch {
            $cache = @{}
        }
    }

    if ($cache.Count -eq 0) {
        Merge-SCMiningPlanetResourceInventoryCacheFromBackups -Cache $cache
        if ($cache.Count -gt 0) {
            Write-SCMiningPlanetResourceInventoryCache -Cache $cache
        }
    }

    return $cache
}

function Merge-SCMiningPlanetResourceInventoryCacheFromBackups {
    param([hashtable]$Cache)

    $launcherRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $backupDir = Join-Path $launcherRoot 'backups'
    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
        return
    }

    $backupFiles = @(Get-SCMiningCleanResourceBackupCandidates -BackupDir $backupDir)
    foreach ($file in $backupFiles) {
        try {
            foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
                $idx = ([string]$line).IndexOf('=')
                if ($idx -le 0) {
                    continue
                }

                $key = ([string]$line).Substring(0, $idx)
                if ($Cache.ContainsKey($key)) {
                    continue
                }
                if ($key -notmatch '(?i)_desc(?:,|$)|_description(?:,|$)') {
                    continue
                }

                $value = ([string]$line).Substring($idx + 1)
                if (-not (Test-SCMiningCleanResourceSourceValue -Value $value)) {
                    continue
                }

                $inventory = Read-SCMiningResourceInventoryFromValue -Value $value
                if (Test-SCMiningResourceInventoryUsable -Inventory $inventory) {
                    $Cache[$key] = ConvertTo-SCMiningPlanetResourceInventoryCacheRecord -Inventory $inventory
                }
            }
        }
        catch {
            continue
        }
    }
}

function Get-SCMiningCleanResourceBackupCandidates {
    param([string]$BackupDir)

    $allBackups = @(Get-ChildItem -LiteralPath $BackupDir -Filter 'global.ini*.bak' -File | Sort-Object LastWriteTime -Descending)
    $latestClean = @(
        $allBackups |
            Where-Object { (Get-SCMiningBackupMetadataKind -BackupFile $_) -eq 'clean' } |
            Select-Object -First 1
    )
    if ($latestClean.Count -gt 0) {
        return @($latestClean)
    }

    return @(
        $allBackups |
            Where-Object { (Get-SCMiningBackupMetadataKind -BackupFile $_) -ne 'patched' } |
            Select-Object -First 20
    )
}

function Get-SCMiningBackupMetadataKind {
    param([System.IO.FileInfo]$BackupFile)

    $metadataPath = "$($BackupFile.FullName).meta.json"
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return 'unknown'
    }

    try {
        $metadata = Get-Content -LiteralPath $metadataPath -Encoding UTF8 -Raw | ConvertFrom-Json
        if ([string]$metadata.kind -in @('clean', 'patched')) {
            return [string]$metadata.kind
        }
    }
    catch {
        return 'unknown'
    }

    return 'unknown'
}

function Test-SCMiningCleanResourceSourceValue {
    param([AllowEmptyString()][string]$Value)

    return ((Get-SCMiningRawResourceBlockIndex -Value $Value) -ge 0 -and $Value.IndexOf((Get-SCMiningCraftHeader)) -lt 0)
}

function Write-SCMiningPlanetResourceInventoryCache {
    param([hashtable]$Cache)

    $cachePath = Get-SCMiningPlanetResourceInventoryCachePath
    $cacheDir = Split-Path -Parent $cachePath
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    }

    $planets = [ordered]@{}
    foreach ($key in @($Cache.Keys | Sort-Object)) {
        $planets[[string]$key] = $Cache[$key]
    }

    $payload = [pscustomobject]@{
        updatedAt = (Get-Date).ToString('o')
        planets = $planets
    }
    $json = $payload | ConvertTo-Json -Depth 10
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cachePath, $json, $encoding)
}

function ConvertTo-SCMiningPlanetResourceInventoryCacheRecord {
    param([object]$Inventory)

    $methods = [ordered]@{}
    foreach ($method in Get-SCMiningMethodOrder) {
        $methods[$method] = @(Expand-SCMiningResourceEntries -Entries $Inventory.ResourcesByMethod[$method] | Sort-Object -Unique)
    }

    return [pscustomobject]@{
        methods = $methods
        collectable = @(Expand-SCMiningResourceEntries -Entries $Inventory.CollectableResources | Sort-Object -Unique)
        creature = @(Expand-SCMiningResourceEntries -Entries $Inventory.CreatureResources | Sort-Object -Unique)
    }
}

function ConvertFrom-SCMiningPlanetResourceInventoryCacheRecord {
    param([object]$Record)

    $inventory = New-SCMiningEmptyResourceInventory
    foreach ($method in Get-SCMiningMethodOrder) {
        if ($null -ne $Record.methods -and $null -ne $Record.methods.$method) {
            foreach ($resource in @($Record.methods.$method)) {
                $inventory.ResourcesByMethod[$method].Add([string]$resource)
            }
        }
    }
    foreach ($resource in @($Record.collectable)) {
        $inventory.CollectableResources.Add([string]$resource)
    }
    foreach ($creature in @($Record.creature)) {
        $inventory.CreatureResources.Add([string]$creature)
    }

    return Normalize-SCMiningResourceInventory -Inventory $inventory
}

function Test-SCMiningResourceInventoryUsable {
    param([object]$Inventory)

    if (-not (Test-SCMiningInventoryHasResources -Inventory $Inventory)) {
        return $false
    }

    foreach ($method in Get-SCMiningMethodOrder) {
        foreach ($entry in @($Inventory.ResourcesByMethod[$method])) {
            if ([string]$entry -match '<EM[1-5]>|</EM[1-5]>') {
                return $false
            }
        }
    }

    return $true
}

function Test-SCMiningInventoryHasResources {
    param([object]$Inventory)

    if ($null -eq $Inventory) {
        return $false
    }

    foreach ($method in Get-SCMiningMethodOrder) {
        if ($Inventory.ResourcesByMethod.ContainsKey($method) -and @($Inventory.ResourcesByMethod[$method]).Count -gt 0) {
            return $true
        }
    }

    return (@($Inventory.CollectableResources).Count -gt 0 -or @($Inventory.CreatureResources).Count -gt 0)
}

function New-SCMiningEmptyResourceInventory {
    $resourcesByMethod = @{}
    foreach ($method in Get-SCMiningMethodOrder) {
        $resourcesByMethod[$method] = New-Object System.Collections.Generic.List[string]
    }

    return [pscustomobject]@{
        ResourcesByMethod = $resourcesByMethod
        CollectableResources = New-Object System.Collections.Generic.List[string]
        CreatureResources = New-Object System.Collections.Generic.List[string]
    }
}

function Format-SCMiningRawResourceSections {
    param([object]$Inventory)

    $lines = New-Object System.Collections.Generic.List[string]
    $headers = Get-SCMiningRawResourceMethodHeaders
    foreach ($method in Get-SCMiningMethodOrder) {
        $resources = @(Expand-SCMiningResourceEntries -Entries $Inventory.ResourcesByMethod[$method])
        if ($resources.Count -eq 0) {
            continue
        }

        if ($lines.Count -gt 0) {
            $lines.Add('')
        }
        $lines.Add($headers[$method])
        foreach ($resource in @($resources | Sort-Object -Unique)) {
            $lines.Add($resource)
        }
    }

    $collectables = @(Expand-SCMiningResourceEntries -Entries $Inventory.CollectableResources | Sort-Object -Unique)
    if ($collectables.Count -gt 0) {
        if ($lines.Count -gt 0) {
            $lines.Add('')
        }
        $lines.Add((Get-SCMiningRawCollectableHeader))
        foreach ($resource in $collectables) {
            $lines.Add($resource)
        }
    }

    $creatures = @(Expand-SCMiningResourceEntries -Entries $Inventory.CreatureResources | Sort-Object -Unique)
    if ($creatures.Count -gt 0) {
        if ($lines.Count -gt 0) {
            $lines.Add('')
        }
        $lines.Add((Get-SCMiningRawCreatureHeader))
        foreach ($creature in $creatures) {
            $lines.Add($creature)
        }
    }

    return (($lines.ToArray()) -join '\n').TrimEnd()
}

function Update-SCMiningLegacyCraftBlockMethods {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [int]$MarkerIndex,
        [string[]]$SelectedMethods
    )

    $markerIndex = $MarkerIndex
    if ($markerIndex -lt 0) {
        return $Value
    }

    $prefix = Trim-SCMiningEncodedTrailingBreaks -Value ($Value.Substring(0, $markerIndex))
    $block = $Value.Substring($markerIndex)
    $lines = @($block -split '\\n')

    if (Test-SCMiningOwnedResourceBlockLines -Lines $lines) {
        $inventory = Read-SCMiningOwnedResourceBlockInventory -Lines $lines
        $ownedBlock = Format-SCMiningOwnedResourceBlock -ResourcesByMethod $inventory.ResourcesByMethod -CollectableResources $inventory.CollectableResources -SelectedMethods $SelectedMethods
        if ([string]::IsNullOrWhiteSpace($ownedBlock)) {
            return $prefix.TrimEnd()
        }

        return ($prefix.TrimEnd() + '\n\n' + $ownedBlock).TrimEnd()
    }

    $updated = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if ($line.StartsWith((Get-SCMiningLegendPrefix))) {
            continue
        }

        if ($line -match '^- ') {
            $recipeLine = Update-SCMiningRecipeLine -Line $line -SelectedMethods $SelectedMethods
            if ($null -ne $recipeLine) {
                $updated.Add($recipeLine)
            }
            continue
        }

        $updated.Add($line)
    }

    $compressed = Compress-SCMiningCraftBlockHeadings -Lines @($updated)
    return $prefix + '\n\n' + (($compressed -join '\n').TrimEnd())
}

function Update-SCMiningRawResourceBlockMethods {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [string[]]$SelectedMethods
    )

    $markerIndex = Get-SCMiningRawResourceBlockIndex -Value $Value
    if ($markerIndex -lt 0) {
        return $Value
    }

    $headerMethods = Get-SCMiningRawResourceHeaderMethods
    $stopHeaders = Get-SCMiningRawResourceStopHeaders
    $prefix = Trim-SCMiningEncodedTrailingBreaks -Value ($Value.Substring(0, $markerIndex))
    $block = $Value.Substring($markerIndex)
    $lines = @($block -split '\\n')
    $resourcesByMethod = @{}
    foreach ($method in Get-SCMiningMethodOrder) {
        $resourcesByMethod[$method] = New-Object System.Collections.Generic.List[string]
    }

    $collectableResources = New-Object System.Collections.Generic.List[string]
    $currentMethod = $null
    $insideCollectableSection = $false

    foreach ($line in $lines) {
        $trimmed = ([string]$line).Trim()
        if ($insideCollectableSection) {
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $collectableResources.Add($trimmed)
            }
            continue
        }

        if ($headerMethods.ContainsKey($trimmed)) {
            $currentMethod = $headerMethods[$trimmed]
            continue
        }

        if ($stopHeaders.ContainsKey($trimmed)) {
            $currentMethod = $null
            $insideCollectableSection = $true
            continue
        }

        if ($null -ne $currentMethod) {
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $resourcesByMethod[$currentMethod].Add($trimmed)
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $collectableResources.Add($trimmed)
        }
    }

    $ownedBlock = Format-SCMiningOwnedResourceBlock -ResourcesByMethod $resourcesByMethod -CollectableResources $collectableResources -SelectedMethods $SelectedMethods
    if ([string]::IsNullOrWhiteSpace($ownedBlock)) {
        return $prefix.TrimEnd()
    }

    return ($prefix.TrimEnd() + '\n\n' + $ownedBlock).TrimEnd()
}

function Read-SCMiningRawResourceBlockInventory {
    param([AllowEmptyString()][string]$Value)

    $headerMethods = Get-SCMiningRawResourceHeaderMethods
    $stopHeaders = Get-SCMiningRawResourceStopHeaders
    $lines = @([string]$Value -split '\\n')
    $inventory = New-SCMiningEmptyResourceInventory
    $currentMethod = $null
    $currentReference = $null

    foreach ($line in $lines) {
        $trimmed = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        if ($trimmed -eq (Get-SCMiningCraftHeader) -or $trimmed -eq (Get-SCMiningAsteroidBeltHeader)) {
            break
        }

        if ($headerMethods.ContainsKey($trimmed)) {
            $currentMethod = $headerMethods[$trimmed]
            $currentReference = $null
            continue
        }

        if ($stopHeaders.ContainsKey($trimmed)) {
            $currentMethod = $null
            $currentReference = [string]$stopHeaders[$trimmed]
            continue
        }

        if ($null -ne $currentMethod) {
            $inventory.ResourcesByMethod[$currentMethod].Add($trimmed)
            continue
        }

        if ($currentReference -eq '__collectable') {
            $inventory.CollectableResources.Add($trimmed)
            continue
        }

        if ($currentReference -eq '__creature') {
            $inventory.CreatureResources.Add($trimmed)
        }
    }

    return Normalize-SCMiningResourceInventory -Inventory $inventory
}

function Trim-SCMiningEncodedTrailingBreaks {
    param([AllowEmptyString()][string]$Value)

    return [regex]::Replace([string]$Value, '(?:\s|\\n)+$', '')
}

function Trim-SCMiningEncodedLeadingBreaks {
    param([AllowEmptyString()][string]$Value)

    return [regex]::Replace([string]$Value, '^(?:\s|\\n)+', '')
}

function Format-SCMiningOwnedResourceBlock {
    param(
        [hashtable]$ResourcesByMethod,
        [System.Collections.Generic.List[string]]$CollectableResources,
        [System.Collections.Generic.List[string]]$CreatureResources,
        [string[]]$SelectedMethods,
        [AllowEmptyString()][string]$DetailedCraftBlock
    )

    $referenceSections = New-Object System.Collections.Generic.List[string]
    $hasDetailedCraftBlock = -not [string]::IsNullOrWhiteSpace($DetailedCraftBlock)

    if (-not $hasDetailedCraftBlock) {
        foreach ($method in Get-SCMiningMethodOrder) {
            $resources = @($ResourcesByMethod[$method] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if ($resources.Count -eq 0) {
                continue
            }

            $resourceText = (($resources | Sort-Object -Unique) -join ', ')
            $referenceSections.Add('')
            $referenceSections.Add('<EM4>' + (Get-SCMiningReferenceLabel -Method $method) + '</EM4>')
            $referenceSections.Add($resourceText)
        }
    }

    $collectableList = @(Expand-SCMiningResourceEntries -Entries $CollectableResources | Sort-Object -Unique)
    if ($collectableList.Count -gt 0) {
        $referenceSections.Add('')
        $referenceSections.Add('<EM4>' + (Get-SCMiningCollectableReferenceLabel) + '</EM4>')
        $referenceSections.Add(($collectableList -join ', '))
    }

    $creatureList = @(Expand-SCMiningResourceEntries -Entries $CreatureResources | Sort-Object -Unique)
    if ($creatureList.Count -gt 0) {
        $referenceSections.Add('')
        $referenceSections.Add('<EM4>' + (Get-SCMiningCreatureReferenceLabel) + '</EM4>')
        $referenceSections.Add(($creatureList -join ', '))
    }

    if (-not $hasDetailedCraftBlock -and $referenceSections.Count -eq 0) {
        return ''
    }

    $lines = New-Object System.Collections.Generic.List[string]
    if ($hasDetailedCraftBlock) {
        foreach ($line in @($DetailedCraftBlock -split '\\n')) {
            $lines.Add($line)
        }
    }
    else {
        $lines.Add((Get-SCMiningCraftHeader))
    }

    foreach ($line in $referenceSections) {
        $lines.Add($line)
    }

    return (($lines.ToArray()) -join '\n').TrimEnd()
}

function Test-SCMiningOwnedResourceBlockLines {
    param([string[]]$Lines)

    $detailedPrefix = '<EM4>' + (Get-SCMiningDetailedBaseLabel)
    $referenceLabels = @{}
    foreach ($method in Get-SCMiningMethodOrder) {
        $referenceLabels['<EM4>' + (Get-SCMiningReferenceLabel -Method $method) + '</EM4>'] = $true
        $referenceLabels['<EM4>' + (Get-SCMiningLegacyReferenceLabel -Method $method) + '</EM4>'] = $true
    }
    $referenceLabels['<EM4>' + (Get-SCMiningCollectableReferenceLabel) + '</EM4>'] = $true
    $referenceLabels['<EM4>' + (Get-SCMiningLegacyCollectableReferenceLabel) + '</EM4>'] = $true
    $referenceLabels['<EM4>' + (Get-SCMiningCreatureReferenceLabel) + '</EM4>'] = $true
    $hasReferenceLabel = $false
    $hasRecipeLine = $false

    foreach ($line in $Lines) {
        $trimmed = ([string]$line).Trim()
        if ($trimmed.StartsWith($detailedPrefix)) {
            return $true
        }
        if ($referenceLabels.ContainsKey($trimmed)) {
            $hasReferenceLabel = $true
            continue
        }
        if ($trimmed -match '^- ') {
            $hasRecipeLine = $true
        }
    }

    return ($hasReferenceLabel -and -not $hasRecipeLine)
}

function Read-SCMiningOwnedResourceBlockInventory {
    param([string[]]$Lines)

    $resourcesByMethod = @{}
    foreach ($method in Get-SCMiningMethodOrder) {
        $resourcesByMethod[$method] = New-Object System.Collections.Generic.List[string]
    }
    $collectableResources = New-Object System.Collections.Generic.List[string]
    $creatureResources = New-Object System.Collections.Generic.List[string]
    $currentReference = $null

    foreach ($line in $Lines) {
        $trimmed = ([string]$line).Trim()
        if ($trimmed -eq (Get-SCMiningAsteroidBeltHeader)) {
            break
        }
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $referenceKind = Get-SCMiningReferenceKindFromLine -Line $trimmed
        if ($null -ne $referenceKind) {
            $currentReference = $referenceKind
            continue
        }

        if ($trimmed -match '^-\s+.+?:\s+(.+)$') {
            $currentReference = $null
            foreach ($part in (Split-SCMiningMethodParts -Text $Matches[1])) {
                $resourceText = [string]$part.Text
                $marker = Format-SCMiningMethodMarker -Method $part.Method
                if ($resourceText.StartsWith($marker)) {
                    $resourceText = $resourceText.Substring($marker.Length).Trim()
                }
                Add-SCMiningResourceList -Target $resourcesByMethod[$part.Method] -Text $resourceText
            }
            continue
        }

        if ($currentReference -eq '__collectable') {
            Add-SCMiningResourceList -Target $collectableResources -Text $trimmed
            continue
        }

        if ($currentReference -eq '__creature') {
            Add-SCMiningResourceList -Target $creatureResources -Text $trimmed
            continue
        }

        if ($null -ne $currentReference -and $resourcesByMethod.ContainsKey($currentReference)) {
            Add-SCMiningResourceList -Target $resourcesByMethod[$currentReference] -Text $trimmed
        }
    }

    return Normalize-SCMiningResourceInventory -Inventory ([pscustomobject]@{
        ResourcesByMethod = $resourcesByMethod
        CollectableResources = $collectableResources
        CreatureResources = $creatureResources
    })
}

function Get-SCMiningReferenceKindFromLine {
    param([Parameter(Mandatory = $true)][string]$Line)

    foreach ($method in Get-SCMiningMethodOrder) {
        if ($Line -eq ('<EM4>' + (Get-SCMiningReferenceLabel -Method $method) + '</EM4>')) {
            return $method
        }
        if ($Line -eq ('<EM4>' + (Get-SCMiningLegacyReferenceLabel -Method $method) + '</EM4>')) {
            return $method
        }
    }

    if ($Line -eq ('<EM4>' + (Get-SCMiningCollectableReferenceLabel) + '</EM4>')) {
        return '__collectable'
    }

    if ($Line -eq ('<EM4>' + (Get-SCMiningLegacyCollectableReferenceLabel) + '</EM4>')) {
        return '__collectable'
    }

    if ($Line -eq ('<EM4>' + (Get-SCMiningCreatureReferenceLabel) + '</EM4>')) {
        return '__creature'
    }

    return $null
}

function Add-SCMiningResourceList {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [AllowEmptyString()][string]$Text
    )

    $trimmed = ([string]$Text).Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        $Target.Add($trimmed)
    }
}

function Normalize-SCMiningResourceInventory {
    param([object]$Inventory)

    $normalized = New-SCMiningEmptyResourceInventory
    foreach ($method in Get-SCMiningMethodOrder) {
        foreach ($entry in Expand-SCMiningResourceEntries -Entries $Inventory.ResourcesByMethod[$method]) {
            $normalized.ResourcesByMethod[$method].Add($entry)
        }
    }

    foreach ($entry in Expand-SCMiningResourceEntries -Entries $Inventory.CollectableResources) {
        if ($entry -eq (Get-SCMiningRawCreatureHeader)) {
            continue
        }
        if (Test-SCMiningKnownCreatureName -Name $entry) {
            $normalized.CreatureResources.Add($entry)
        }
        else {
            $normalized.CollectableResources.Add($entry)
        }
    }

    foreach ($entry in Expand-SCMiningResourceEntries -Entries $Inventory.CreatureResources) {
        if ($entry -ne (Get-SCMiningRawCreatureHeader)) {
            $normalized.CreatureResources.Add($entry)
        }
    }

    return $normalized
}

function Expand-SCMiningResourceEntries {
    param($Entries)

    $expanded = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Entries)) {
        foreach ($part in ([string]$entry -split ',')) {
            $trimmed = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $expanded.Add($trimmed)
            }
        }
    }

    return @($expanded)
}

function Test-SCMiningKnownCreatureName {
    param([AllowEmptyString()][string]$Name)

    $normalized = ([string]$Name).Trim()
    return @('Juvenile Valakkar', 'Kopion', 'Marok', 'Quasigrazer') -contains $normalized
}

function Test-SCMiningHasCraftBlock {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    if ($Value.IndexOf((Get-SCMiningCraftHeader)) -ge 0) {
        return $true
    }

    return ((Get-SCMiningRawResourceBlockIndex -Value $Value) -ge 0)
}

function Get-SCMiningRawResourceBlockIndex {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return -1
    }

    $indexes = @()
    foreach ($header in (Get-SCMiningRawResourceHeaderMethods).Keys) {
        $index = $Value.IndexOf($header)
        if ($index -ge 0) {
            $indexes += $index
        }
    }

    if ($indexes.Count -eq 0) {
        return -1
    }

    return [int]($indexes | Sort-Object | Select-Object -First 1)
}

function Get-SCMiningRawResourceHeaderMethods {
    $headers = Get-SCMiningRawResourceMethodHeaders

    return @{
        $headers[(Get-SCMiningShipCode)] = Get-SCMiningShipCode
        $headers[(Get-SCMiningGroundCode)] = Get-SCMiningGroundCode
        $headers[(Get-SCMiningHandCode)] = Get-SCMiningHandCode
    }
}

function Get-SCMiningRawResourceMethodHeaders {
    $shipHeader = ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x043E, 0x0442, 0x0435, 0x043D, 0x0446, 0x0438, 0x0430, 0x043B, 0x044C, 0x043D, 0x043E, 0x0020, 0x0434, 0x043E, 0x0431, 0x044B, 0x0432, 0x0430, 0x0435, 0x043C, 0x044B, 0x0435, 0x0020, 0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B, 0x0020, 0x0028, 0x043A, 0x043E, 0x0440, 0x0430, 0x0431, 0x043B, 0x044C, 0x0029, 0x003A)
    $groundHeader = ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x043E, 0x0442, 0x0435, 0x043D, 0x0446, 0x0438, 0x0430, 0x043B, 0x044C, 0x043D, 0x043E, 0x0020, 0x0434, 0x043E, 0x0431, 0x044B, 0x0432, 0x0430, 0x0435, 0x043C, 0x044B, 0x0435, 0x0020, 0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B, 0x0020, 0x0028, 0x043D, 0x0430, 0x0437, 0x0435, 0x043C, 0x043D, 0x0430, 0x044F, 0x0020, 0x0442, 0x0435, 0x0445, 0x043D, 0x0438, 0x043A, 0x0430, 0x0029, 0x003A)
    $handHeader = ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x043E, 0x0442, 0x0435, 0x043D, 0x0446, 0x0438, 0x0430, 0x043B, 0x044C, 0x043D, 0x043E, 0x0020, 0x0434, 0x043E, 0x0431, 0x044B, 0x0432, 0x0430, 0x0435, 0x043C, 0x044B, 0x0435, 0x0020, 0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B, 0x0020, 0x0028, 0x0440, 0x0443, 0x0447, 0x043D, 0x0430, 0x044F, 0x0020, 0x0434, 0x043E, 0x0431, 0x044B, 0x0447, 0x0430, 0x0029, 0x003A)

    return @{
        (Get-SCMiningShipCode) = $shipHeader
        (Get-SCMiningGroundCode) = $groundHeader
        (Get-SCMiningHandCode) = $handHeader
    }
}

function Get-SCMiningRawResourceStopHeaders {
    return @{
        (Get-SCMiningRawCollectableHeader) = '__collectable'
        (Get-SCMiningRawCreatureHeader) = '__creature'
    }
}

function Get-SCMiningRawCollectableHeader {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x043E, 0x0442, 0x0435, 0x043D, 0x0446, 0x0438, 0x0430, 0x043B, 0x044C, 0x043D, 0x043E, 0x0020, 0x0441, 0x043E, 0x0431, 0x0438, 0x0440, 0x0430, 0x0435, 0x043C, 0x044B, 0x0435, 0x0020, 0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B, 0x003A))
}

function Get-SCMiningRawCreatureHeader {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x043E, 0x0442, 0x0435, 0x043D, 0x0446, 0x0438, 0x0430, 0x043B, 0x044C, 0x043D, 0x044B, 0x0435, 0x0020, 0x0441, 0x0443, 0x0449, 0x0435, 0x0441, 0x0442, 0x0432, 0x0430, 0x003A))
}

function ConvertFrom-SCCodePoints {
    param([int[]]$CodePoints)

    return -join ($CodePoints | ForEach-Object { [char]$_ })
}

function Get-SCMiningShipCode {
    return [string][char]0x041A
}

function Get-SCMiningGroundCode {
    return [string][char]0x0422
}

function Get-SCMiningHandCode {
    return [string][char]0x041C
}

function Get-SCMiningMethodOrder {
    return @((Get-SCMiningShipCode), (Get-SCMiningGroundCode), (Get-SCMiningHandCode))
}

function Get-SCMiningCraftHeader {
    $label = ConvertFrom-SCCodePoints -CodePoints @(0x041A, 0x0440, 0x0430, 0x0444, 0x0442, 0x002D, 0x043F, 0x043E, 0x0434, 0x0441, 0x043A, 0x0430, 0x0437, 0x043A, 0x0430)
    return "<EM4>$label (SCMDB)</EM4>"
}

function Get-SCMiningLegendPrefix {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041B, 0x0435, 0x0433, 0x0435, 0x043D, 0x0434, 0x0430, 0x003A, 0x0020))
}

function Get-SCMiningFilterPrefix {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0424, 0x0438, 0x043B, 0x044C, 0x0442, 0x0440, 0x003A))
}

function Get-SCMiningResourceCategoryLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0414, 0x043E, 0x0431, 0x044B, 0x0432, 0x0430, 0x0435, 0x043C, 0x044B, 0x0435, 0x0020, 0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B))
}

function Get-SCMiningDetailedLabel {
    param([string[]]$SelectedMethods)

    $label = Get-SCMiningDetailedBaseLabel
    $methodLabels = @{
        (Get-SCMiningShipCode) = Get-SCMiningShipLabel
        (Get-SCMiningGroundCode) = Get-SCMiningGroundLabel
        (Get-SCMiningHandCode) = Get-SCMiningHandLabel
    }

    $selectedLabels = @()
    foreach ($method in Get-SCMiningMethodOrder) {
        if ($method -in $SelectedMethods) {
            $selectedLabels += $methodLabels[$method]
        }
    }

    if ($selectedLabels.Count -eq 0) {
        return $label
    }

    return $label + ': ' + ($selectedLabels -join ', ')
}

function Get-SCMiningDetailedBaseLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x043E, 0x0434, 0x0440, 0x043E, 0x0431, 0x043D, 0x043E))
}

function Get-SCMiningResourceLineLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0420, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B))
}

function Get-SCMiningReferenceLabel {
    param([Parameter(Mandatory = $true)][string]$Method)

    if ($Method -eq (Get-SCMiningShipCode)) {
        return (ConvertFrom-SCCodePoints -CodePoints @(0x041A, 0x043E, 0x0440, 0x0430, 0x0431, 0x043B, 0x044C))
    }
    if ($Method -eq (Get-SCMiningGroundCode)) {
        return (ConvertFrom-SCCodePoints -CodePoints @(0x041D, 0x0430, 0x0437, 0x0435, 0x043C, 0x043D, 0x0430, 0x044F, 0x0020, 0x0442, 0x0435, 0x0445, 0x043D, 0x0438, 0x043A, 0x0430))
    }

    return (ConvertFrom-SCCodePoints -CodePoints @(0x041C, 0x0443, 0x043B, 0x044C, 0x0442, 0x0438, 0x0442, 0x0443, 0x043B))
}

function Get-SCMiningCollectableReferenceLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x043E, 0x0431, 0x0438, 0x0440, 0x0430, 0x0435, 0x043C, 0x044B, 0x0435, 0x0020, 0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B))
}

function Get-SCMiningCreatureReferenceLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x0443, 0x0449, 0x0435, 0x0441, 0x0442, 0x0432, 0x0430))
}

function Get-SCMiningLegacyReferenceLabel {
    param([Parameter(Mandatory = $true)][string]$Method)

    if ($Method -eq (Get-SCMiningShipCode)) {
        return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x043F, 0x0440, 0x0430, 0x0432, 0x043E, 0x0447, 0x043D, 0x043E, 0x003A, 0x0020, 0x043A, 0x043E, 0x0440, 0x0430, 0x0431, 0x043B, 0x044C))
    }
    if ($Method -eq (Get-SCMiningGroundCode)) {
        return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x043F, 0x0440, 0x0430, 0x0432, 0x043E, 0x0447, 0x043D, 0x043E, 0x003A, 0x0020, 0x043D, 0x0430, 0x0437, 0x0435, 0x043C, 0x043D, 0x0430, 0x044F, 0x0020, 0x0442, 0x0435, 0x0445, 0x043D, 0x0438, 0x043A, 0x0430))
    }

    return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x043F, 0x0440, 0x0430, 0x0432, 0x043E, 0x0447, 0x043D, 0x043E, 0x003A, 0x0020, 0x043C, 0x0443, 0x043B, 0x044C, 0x0442, 0x0438, 0x0442, 0x0443, 0x043B))
}

function Get-SCMiningLegacyCollectableReferenceLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x043F, 0x0440, 0x0430, 0x0432, 0x043E, 0x0447, 0x043D, 0x043E, 0x003A, 0x0020, 0x0441, 0x043E, 0x0431, 0x0438, 0x0440, 0x0430, 0x0435, 0x043C, 0x044B, 0x0435, 0x0020, 0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B))
}

function Get-SCMiningShipLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x043A, 0x043E, 0x0440, 0x0430, 0x0431, 0x043B, 0x044C))
}

function Get-SCMiningGroundLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x043D, 0x0430, 0x0437, 0x0435, 0x043C, 0x043D, 0x0430, 0x044F, 0x0020, 0x0442, 0x0435, 0x0445, 0x043D, 0x0438, 0x043A, 0x0430))
}

function Get-SCMiningHandLabel {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x043C, 0x0443, 0x043B, 0x044C, 0x0442, 0x0438, 0x0442, 0x0443, 0x043B))
}

function Get-SCMiningPlanetTextOther {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x0440, 0x043E, 0x0447, 0x0435, 0x0435))
}

function Get-SCMiningPlanetTextShownRecipes {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x043E, 0x043A, 0x0430, 0x0437, 0x0430, 0x043D, 0x044B, 0x0020, 0x0440, 0x0435, 0x0446, 0x0435, 0x043F, 0x0442, 0x044B, 0x002C, 0x0020, 0x0434, 0x043B, 0x044F, 0x0020, 0x043A, 0x043E, 0x0442, 0x043E, 0x0440, 0x044B, 0x0445, 0x0020, 0x0437, 0x0434, 0x0435, 0x0441, 0x044C, 0x0020, 0x0434, 0x043E, 0x0431, 0x044B, 0x0432, 0x0430, 0x0435, 0x0442, 0x0441, 0x044F, 0x0020, 0x0445, 0x043E, 0x0442, 0x044F, 0x0020, 0x0431, 0x044B, 0x0020, 0x043E, 0x0434, 0x0438, 0x043D, 0x0020, 0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x002E))
}

function Get-SCMiningPlanetTextPartialRecipe {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x042D, 0x0442, 0x043E, 0x0020, 0x043D, 0x0435, 0x0020, 0x043F, 0x043E, 0x043B, 0x043D, 0x044B, 0x0439, 0x0020, 0x0440, 0x0435, 0x0446, 0x0435, 0x043F, 0x0442, 0x0020, 0x002D, 0x0020, 0x0442, 0x043E, 0x043B, 0x044C, 0x043A, 0x043E, 0x0020, 0x0440, 0x0435, 0x0441, 0x0443, 0x0440, 0x0441, 0x044B, 0x0020, 0x044D, 0x0442, 0x043E, 0x0439, 0x0020, 0x043B, 0x043E, 0x043A, 0x0430, 0x0446, 0x0438, 0x0438, 0x002E))
}

function Get-SCMiningPlanetTextFilters {
    param([string[]]$SelectedMethods)

    if (@($SelectedMethods).Count -eq 0) {
        return (ConvertFrom-SCCodePoints -CodePoints @(0x0424, 0x0438, 0x043B, 0x044C, 0x0442, 0x0440, 0x003A, 0x0020, 0x043E, 0x0442, 0x043A, 0x043B, 0x044E, 0x0447, 0x0451, 0x043D, 0x002C, 0x0020, 0x0441, 0x043F, 0x043E, 0x0441, 0x043E, 0x0431, 0x044B, 0x0020, 0x0434, 0x043E, 0x0431, 0x044B, 0x0447, 0x0438, 0x0020, 0x043D, 0x0435, 0x0020, 0x0432, 0x044B, 0x0431, 0x0440, 0x0430, 0x043D, 0x044B, 0x002E))
    }

    return (ConvertFrom-SCCodePoints -CodePoints @(0x0424, 0x0438, 0x043B, 0x044C, 0x0442, 0x0440, 0x003A, 0x0020, 0x043F, 0x043E, 0x0020, 0x0432, 0x044B, 0x0431, 0x0440, 0x0430, 0x043D, 0x043D, 0x044B, 0x043C, 0x0020, 0x0433, 0x0430, 0x043B, 0x043A, 0x0430, 0x043C, 0x0020, 0x043A, 0x0440, 0x0430, 0x0444, 0x0442, 0x0430, 0x003B, 0x0020, 0x043A, 0x043E, 0x043C, 0x043F, 0x043E, 0x043D, 0x0435, 0x043D, 0x0442, 0x044B, 0x0020, 0x0442, 0x043E, 0x043B, 0x044C, 0x043A, 0x043E, 0x0020, 0x0047, 0x0072, 0x0061, 0x0064, 0x0065, 0x0020, 0x0041, 0x002E))
}

function Get-SCMiningPlanetCategoryShipComponents {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041A, 0x043E, 0x0440, 0x0430, 0x0431, 0x0435, 0x043B, 0x044C, 0x043D, 0x044B, 0x0435, 0x0020, 0x043A, 0x043E, 0x043C, 0x043F, 0x043E, 0x043D, 0x0435, 0x043D, 0x0442, 0x044B))
}

function Get-SCMiningPlanetCategoryShipWeapons {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041A, 0x043E, 0x0440, 0x0430, 0x0431, 0x0435, 0x043B, 0x044C, 0x043D, 0x044B, 0x0435, 0x0020, 0x043E, 0x0440, 0x0443, 0x0434, 0x0438, 0x044F))
}

function Get-SCMiningPlanetCategoryMiningLasers {
    return (Get-SCMiningPlanetSubcategoryMiningLasers)
}

function Get-SCMiningPlanetCategoryMiningEquipment {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0413, 0x043E, 0x0440, 0x043D, 0x043E, 0x0435, 0x0020, 0x043E, 0x0431, 0x043E, 0x0440, 0x0443, 0x0434, 0x043E, 0x0432, 0x0430, 0x043D, 0x0438, 0x0435))
}

function Get-SCMiningPlanetCategoryArmor {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0411, 0x0440, 0x043E, 0x043D, 0x044F, 0x002F, 0x043E, 0x0434, 0x0435, 0x0436, 0x0434, 0x0430))
}

function Get-SCMiningPlanetCategoryWeapons {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041E, 0x0440, 0x0443, 0x0436, 0x0438, 0x0435))
}

function Get-SCMiningPlanetCategoryMaterials {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041C, 0x0430, 0x0442, 0x0435, 0x0440, 0x0438, 0x0430, 0x043B, 0x044B, 0x002F, 0x043E, 0x0441, 0x043E, 0x0431, 0x043E, 0x0435))
}

function Get-SCMiningPlanetSubcategoryShields {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0429, 0x0438, 0x0442, 0x044B))
}

function Get-SCMiningPlanetSubcategoryQuantumDrives {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041A, 0x0432, 0x0430, 0x043D, 0x0442, 0x043E, 0x0432, 0x044B, 0x0435, 0x0020, 0x0434, 0x0432, 0x0438, 0x0433, 0x0430, 0x0442, 0x0435, 0x043B, 0x0438))
}

function Get-SCMiningPlanetSubcategoryPowerPlants {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x0438, 0x043B, 0x043E, 0x0432, 0x044B, 0x0435, 0x0020, 0x0443, 0x0441, 0x0442, 0x0430, 0x043D, 0x043E, 0x0432, 0x043A, 0x0438))
}

function Get-SCMiningPlanetSubcategoryCoolers {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041E, 0x0445, 0x043B, 0x0430, 0x0434, 0x0438, 0x0442, 0x0435, 0x043B, 0x0438))
}

function Get-SCMiningPlanetSubcategoryRadars {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0420, 0x0430, 0x0434, 0x0430, 0x0440, 0x044B))
}

function Get-SCMiningPlanetSubcategoryMiningLasers {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0414, 0x043E, 0x0431, 0x044B, 0x0432, 0x0430, 0x044E, 0x0449, 0x0438, 0x0435, 0x0020, 0x043B, 0x0430, 0x0437, 0x0435, 0x0440, 0x044B))
}

function Get-SCMiningPlanetSubcategoryMiningModules {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041C, 0x043E, 0x0434, 0x0443, 0x043B, 0x0438, 0x0020, 0x0434, 0x043E, 0x0431, 0x044B, 0x0447, 0x0438))
}

function Get-SCMiningPlanetSubcategoryOrePods {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0420, 0x0443, 0x0434, 0x043D, 0x044B, 0x0435, 0x0020, 0x043A, 0x043E, 0x043D, 0x0442, 0x0435, 0x0439, 0x043D, 0x0435, 0x0440, 0x044B))
}

function Get-SCMiningPlanetSubcategoryBallistics {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0411, 0x0430, 0x043B, 0x043B, 0x0438, 0x0441, 0x0442, 0x0438, 0x043A, 0x0430))
}

function Get-SCMiningPlanetSubcategoryHybrid {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0413, 0x0438, 0x0431, 0x0440, 0x0438, 0x0434))
}

function Get-SCMiningPlanetSubcategoryEnergy {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x042D, 0x043D, 0x0435, 0x0440, 0x0433, 0x0435, 0x0442, 0x0438, 0x043A, 0x0430))
}

function Get-SCMiningPlanetSubcategoryHeavyArmor {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0422, 0x044F, 0x0436, 0x0451, 0x043B, 0x0430, 0x044F, 0x0020, 0x0431, 0x0440, 0x043E, 0x043D, 0x044F))
}

function Get-SCMiningPlanetSubcategorySuperHeavyArmor {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x0432, 0x0435, 0x0440, 0x0445, 0x0442, 0x044F, 0x0436, 0x0451, 0x043B, 0x0430, 0x044F, 0x0020, 0x0431, 0x0440, 0x043E, 0x043D, 0x044F))
}

function Get-SCMiningPlanetSubcategoryMediumArmor {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x0440, 0x0435, 0x0434, 0x043D, 0x044F, 0x044F, 0x0020, 0x0431, 0x0440, 0x043E, 0x043D, 0x044F))
}

function Get-SCMiningPlanetSubcategoryLightArmor {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041B, 0x0451, 0x0433, 0x043A, 0x0430, 0x044F, 0x0020, 0x0431, 0x0440, 0x043E, 0x043D, 0x044F))
}

function Get-SCMiningPlanetSubcategoryUndersuits {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0410, 0x043D, 0x0434, 0x0435, 0x0440, 0x0441, 0x044C, 0x044E, 0x0442, 0x044B, 0x002F, 0x043A, 0x043E, 0x0441, 0x0442, 0x044E, 0x043C, 0x044B))
}

function Get-SCMiningPlanetSubcategorySniperRifles {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0421, 0x043D, 0x0430, 0x0439, 0x043F, 0x0435, 0x0440, 0x0441, 0x043A, 0x0438, 0x0435, 0x0020, 0x0432, 0x0438, 0x043D, 0x0442, 0x043E, 0x0432, 0x043A, 0x0438))
}

function Get-SCMiningPlanetSubcategorySmgs {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x0438, 0x0441, 0x0442, 0x043E, 0x043B, 0x0435, 0x0442, 0x044B, 0x002D, 0x043F, 0x0443, 0x043B, 0x0435, 0x043C, 0x0451, 0x0442, 0x044B))
}

function Get-SCMiningPlanetSubcategoryLmgs {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x0443, 0x043B, 0x0435, 0x043C, 0x0451, 0x0442, 0x044B))
}

function Get-SCMiningPlanetSubcategoryHmgs {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0422, 0x044F, 0x0436, 0x0451, 0x043B, 0x044B, 0x0435, 0x0020, 0x043F, 0x0443, 0x043B, 0x0435, 0x043C, 0x0451, 0x0442, 0x044B))
}

function Get-SCMiningPlanetSubcategoryPistols {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x0438, 0x0441, 0x0442, 0x043E, 0x043B, 0x0435, 0x0442, 0x044B))
}

function Get-SCMiningPlanetSubcategoryShotguns {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0414, 0x0440, 0x043E, 0x0431, 0x043E, 0x0432, 0x0438, 0x043A, 0x0438))
}

function Get-SCMiningPlanetSubcategoryRifles {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0412, 0x0438, 0x043D, 0x0442, 0x043E, 0x0432, 0x043A, 0x0438))
}
