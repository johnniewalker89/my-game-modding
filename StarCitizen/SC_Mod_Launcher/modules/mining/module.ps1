function Get-SCMiningPatchPlan {
    param(
        [object]$Context,
        [string[]]$SelectedOptions
    )

    $selectedMethods = Get-SCMiningSelectedMethods -SelectedOptions $SelectedOptions
    $enableItemCraftHints = @($SelectedOptions) -contains 'itemCraftHints'
    $craftFilter = Get-SCMiningCraftFilter -SelectedOptions $SelectedOptions
    $operations = @()
    $changedPlanetKeys = @()
    $itemCraftWarnings = @()
    $itemCraftMetadata = @{
        enabled = $enableItemCraftHints
        safeDescriptionKeys = 0
        changedItemDescriptions = 0
        skippedUnmapped = 0
        skippedNoWiki = 0
        skippedConflict = 0
    }
    $planetBlockCount = 0
    $recipeData = $null
    $planetBlueprints = @()
    $recipeDataWarnings = @()

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
            if ($planetBlueprints.Count -eq 0) {
                $planetBlueprints = @($recipeData.WikiBlueprints)
            }
        }
        catch {
            $recipeDataWarnings += "Mining recipe data unavailable: $($_.Exception.Message)"
        }
    }

    if ($true) {
        $planetCraftMap = @{}
        if ($planetBlueprints.Count -gt 0) {
            $planetCraftMap = New-SCMiningPlanetCraftMap -Blueprints @($planetBlueprints)
        }
        $planetInventoryCache = Get-SCMiningPlanetResourceInventoryCache
        $planetInventoryCacheChanged = $false

        foreach ($key in @($Context.Values.Keys | Sort-Object)) {
            if ($key -notmatch '(?i)_desc(?:,|$)|_description(?:,|$)') {
                continue
            }

            $current = [string]$Context.Values[$key]
            if (-not (Test-SCMiningHasCraftBlock -Value $current)) {
                continue
            }

            $planetBlockCount++
            $inventory = Read-SCMiningResourceInventoryFromValue -Value $current
            if ((Test-SCMiningCleanResourceSourceValue -Value $current) -and (Test-SCMiningResourceInventoryUsable -Inventory $inventory)) {
                $planetInventoryCache[$key] = ConvertTo-SCMiningPlanetResourceInventoryCacheRecord -Inventory $inventory
                $planetInventoryCacheChanged = $true
            }
            elseif ($planetInventoryCache.ContainsKey($key)) {
                $inventory = ConvertFrom-SCMiningPlanetResourceInventoryCacheRecord -Record $planetInventoryCache[$key]
            }

            $filtered = Update-SCMiningCraftBlockMethods -Value $current -SelectedMethods $selectedMethods -PlanetCraftMap $planetCraftMap -CraftFilter $craftFilter -Inventory $inventory
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

        if ($planetInventoryCacheChanged) {
            Write-SCMiningPlanetResourceInventoryCache -Cache $planetInventoryCache
        }
    }

    if ($enableItemCraftHints) {
        $itemPlan = New-SCMiningItemCraftHintOperations -Context $Context -RecipeData $recipeData
        $operations += @($itemPlan.Operations)
        $itemCraftWarnings += @($itemPlan.Warnings)
        $itemCraftMetadata = $itemPlan.Metadata
    }
    else {
        $itemPlan = Remove-SCMiningItemCraftHintOperations -Context $Context
        $operations += @($itemPlan.Operations)
        $itemCraftMetadata = $itemPlan.Metadata
    }

    $metadata = @{
        source = 'existing SCMDB planet craft blocks + SCMDB/Wiki item craft hints'
        selectedOptionCount = @($SelectedOptions).Count
        selectedMethods = @($selectedMethods)
        inspectedKeys = $Context.KeyCount
        planetBlocksFound = $planetBlockCount
        changedPlanetDescriptions = @($changedPlanetKeys).Count
        changedPlanetKeysSample = @($changedPlanetKeys | Select-Object -First 20)
        itemCraftHints = $itemCraftMetadata
    }

    return [pscustomobject]@{
        ModuleId = 'mining'
        Operations = @($operations)
        Warnings = @($recipeDataWarnings + $itemCraftWarnings)
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
        wikiBlueprints = 0
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
        $metadata.wikiBlueprints = $recipeData.WikiBlueprints.Count

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

function Get-SCMiningItemCraftRecipeData {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'SC_Mod_Launcher/1.0 item-craft-hints' }

    $versions = @(Invoke-SCMiningScmdbJson -Uri 'https://scmdb.net/data/game-versions.json' -Headers $headers)
    if ($versions.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$versions[0].file)) {
        throw 'SCMDB game version index returned no data.'
    }

    $version = $versions[0]
    $scmdb = Invoke-SCMiningScmdbJson -Uri ("https://scmdb.net/data/{0}" -f $version.file) -Headers $headers
    $rewardRecords = @(Get-SCMiningScmdbRewardBlueprintRecords -Scmdb $scmdb)
    $wikiBlueprints = @(Get-SCMiningWikiBlueprints -Headers $headers -CacheKey ([string]$version.version))
    $blueprintsByUuid = @{}

    foreach ($blueprint in $wikiBlueprints) {
        if (-not [string]::IsNullOrWhiteSpace([string]$blueprint.uuid)) {
            $blueprintsByUuid[[string]$blueprint.uuid] = $blueprint
        }
    }

    return [pscustomobject]@{
        ScmdbVersion = [string]$version.version
        RewardRecords = @($rewardRecords)
        WikiBlueprints = @($wikiBlueprints)
        BlueprintsByUuid = $blueprintsByUuid
    }
}

function Get-SCMiningPlanetCraftBlueprints {
    $cached = Get-SCMiningCachedWikiBlueprints
    if ($cached.Count -gt 0) {
        return @($cached)
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'SC_Mod_Launcher/1.0 planet-craft-cache' }
    $versions = @(Invoke-SCMiningScmdbJson -Uri 'https://scmdb.net/data/game-versions.json' -Headers $headers)
    if ($versions.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$versions[0].version)) {
        throw 'SCMDB game version index returned no cache key.'
    }

    return @(Get-SCMiningWikiBlueprints -Headers $headers -CacheKey ([string]$versions[0].version))
}

function Invoke-SCMiningScmdbJson {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    try {
        return (Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 20)
    }
    catch {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            $json = & curl.exe -L --silent --show-error --fail --max-time 40 `
                -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36' `
                -H 'Accept: application/json,text/plain,*/*' `
                -e 'https://scmdb.net/' `
                $Uri
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
                return ($json | ConvertFrom-Json)
            }
        }

        throw
    }
}

function Get-SCMiningCachedWikiBlueprints {
    $cacheDir = Get-SCMiningCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return @()
    }

    $cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'wiki-blueprints-*.json' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
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

    $families = foreach ($group in @($groups.Values)) {
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

    $payload = [pscustomobject]@{
        cacheKey = [string]$CacheKey
        createdAt = (Get-Date).ToString('o')
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

function New-SCMiningPlanetCraftMap {
    param([object[]]$Blueprints)

    $result = @{}
    $itemLookup = Get-SCMiningCachedItemInfoLookup
    foreach ($blueprint in @($Blueprints)) {
        $name = Get-SCMiningBlueprintOutputName -Blueprint $blueprint -Reward $null
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

        $key = if (-not [string]::IsNullOrWhiteSpace([string]$blueprint.uuid)) { [string]$blueprint.uuid } else { [string]$blueprint.key }
        $result[$key] = [pscustomobject]@{
            Name = $name
            Category = $category
            Subcategory = Get-SCMiningPlanetBlueprintSubcategory -Blueprint $blueprint -Category $category
            Family = Get-SCMiningPlanetRecipeFamily -Name $name -Category $category
            Resources = @($resources)
            ComponentGrade = Get-SCMiningBlueprintOutputGrade -Blueprint $blueprint -ItemLookup $itemLookup
            ComponentClass = Get-SCMiningBlueprintOutputComponentClass -Blueprint $blueprint -ItemLookup $itemLookup
        }
    }

    return $result
}

function Test-SCMiningIgnoredCraftName {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }

    $clean = ([string]$Name).Trim()
    return ($clean -match '^<=\s*PLACEHOLDER\s*=>$' -or $clean -match '(?i)\bplaceholder\b')
}

function Format-SCMiningPlanetCraftBlock {
    param(
        [object]$Inventory,
        [hashtable]$PlanetCraftMap,
        [string[]]$SelectedMethods,
        [object]$CraftFilter
    )

    if ($null -eq $Inventory -or $null -eq $PlanetCraftMap -or $PlanetCraftMap.Count -eq 0) {
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
        $resourceText = ($methodResources -join ', ')

        if ($method -in $SelectedMethods) {
            $methodLines = @(Format-SCMiningPlanetMethodRecipeLines -Method $method -Inventory $Inventory -PlanetCraftMap $PlanetCraftMap -CraftFilter $CraftFilter)
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

    $body = New-Object System.Collections.Generic.List[string]
    foreach ($category in Get-SCMiningPlanetCategoryOrder) {
        $categoryRecipes = @($PlanetCraftMap.Values | Where-Object { $_.Category -eq $category } | Sort-Object Name)
        if ($categoryRecipes.Count -eq 0) {
            continue
        }

        $groupMap = @{}
        foreach ($recipe in $categoryRecipes) {
            if (-not (Test-SCMiningIncludePlanetRecipe -Recipe $recipe -CraftFilter $CraftFilter)) {
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

    $clean = (($Name -replace '\\n', ' ') -replace '\s*\([^)]*\)\s*$', '').Trim()
    $aliases = @{
        'Alumium' = 'Aluminum'
    }
    if ($aliases.ContainsKey($clean)) {
        return $aliases[$clean]
    }

    return $clean
}

function Get-SCMiningPlanetCategoryOrder {
    return @(
        (Get-SCMiningPlanetCategoryShipComponents),
        (Get-SCMiningPlanetCategoryShipWeapons),
        (Get-SCMiningPlanetCategoryMiningLasers),
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
        return (Get-SCMiningPlanetCategoryMiningLasers)
    }
    if ($type -eq 'Weapon Gun') {
        return (Get-SCMiningPlanetCategoryShipWeapons)
    }
    if ($type -match '\(Armor\)$' -or $type -eq 'Undersuit (Armor)' -or $type -eq 'Backpack (Armor)') {
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
        if ($name -match '(?i)ballistic|gatling|deadbolt|c-788|tarantula|tigerstrike|sword|draugar|mantis|revenant|scorpion|sw16br') { return (Get-SCMiningPlanetSubcategoryBallistics) }
        if ($name -match '(?i)mass driver|sledge|strife') { return (Get-SCMiningPlanetSubcategoryHybrid) }
        return (Get-SCMiningPlanetSubcategoryEnergy)
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryMiningLasers)) {
        return (Get-SCMiningPlanetSubcategoryMiningLasers)
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryArmor)) {
        if ($type -eq 'Helmet (Armor)' -or $type -eq 'Torso (Armor)' -or $type -eq 'Arms (Armor)' -or $type -eq 'Legs (Armor)' -or $type -eq 'Backpack (Armor)') {
            if ($name -match '(?i)heavy|morozov|citadel|adp|antium|pembroke|overlord|palatino|stirling|defiance|dust devil|manticore|fortifier|balor') { return (Get-SCMiningPlanetSubcategoryHeavyArmor) }
            if ($name -match '(?i)medium|orc|artimex|aril|inquisitor|testudo|strata|aves|dustup|g-2|morningstar') { return (Get-SCMiningPlanetSubcategoryMediumArmor) }
            return (Get-SCMiningPlanetSubcategoryLightArmor)
        }
        if ($type -eq 'Undersuit (Armor)') { return (Get-SCMiningPlanetSubcategoryUndersuits) }
        return (Get-SCMiningPlanetTextOther)
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryWeapons)) {
        if ($name -match '(?i)sniper|arrowhead|a03|p6-lr|scalpel|atzkav|zenith') { return (Get-SCMiningPlanetSubcategorySniperRifles) }
        if ($name -match '(?i)\bsmg\b|custodian|lumin|p8-sc|ripper|c54') { return (Get-SCMiningPlanetSubcategorySmgs) }
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
        (Get-SCMiningPlanetCategoryMiningLasers) = @((Get-SCMiningPlanetSubcategoryMiningLasers), (Get-SCMiningPlanetTextOther))
        (Get-SCMiningPlanetCategoryArmor) = @((Get-SCMiningPlanetSubcategoryHeavyArmor), (Get-SCMiningPlanetSubcategoryMediumArmor), (Get-SCMiningPlanetSubcategoryLightArmor), (Get-SCMiningPlanetSubcategoryUndersuits), (Get-SCMiningPlanetTextOther))
        (Get-SCMiningPlanetCategoryWeapons) = @((Get-SCMiningPlanetSubcategoryRifles), (Get-SCMiningPlanetSubcategorySniperRifles), (Get-SCMiningPlanetSubcategorySmgs), (Get-SCMiningPlanetSubcategoryLmgs), (Get-SCMiningPlanetSubcategoryPistols), (Get-SCMiningPlanetSubcategoryShotguns), (Get-SCMiningPlanetTextOther))
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
        'armorHeavy',
        'armorMedium',
        'armorLight',
        'armorSuits',
        'fpsRifles',
        'fpsSniperRifles',
        'fpsSmgs',
        'fpsLmgs',
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

function Get-SCMiningCraftFilter {
    param([string[]]$SelectedOptions)

    $selected = @($SelectedOptions | ForEach-Object { [string]$_ })
    $familyOptionIds = @($selected | Where-Object { ([string]$_).StartsWith('craftFamily|', [System.StringComparison]::OrdinalIgnoreCase) })
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
        [string]$Category
    )

    $label = ([string]$Name).Trim()
    if ($Category -eq (Get-SCMiningPlanetCategoryArmor)) {
        if ($label -match '^Aves(?:\s+(Shrike|Talon))?\s+(Arms|Core|Helmet|Legs)\b') {
            return [pscustomobject]@{ Key = 'armor:Aves'; Label = 'Aves / Aves Shrike / Aves Talon'; Family = 'armor-variant-set'; Token = $null }
        }
        if ($label -match '^ADP(?:-mk4)?\s+(Arms|Core|Helmet|Legs)\b') {
            return [pscustomobject]@{ Key = 'armor:ADP'; Label = 'ADP / ADP-mk4'; Family = 'armor-variant-set'; Token = $null }
        }

        $base = $label
        $base = $base -replace '\s*\([^)]*\)', ''
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
    if ($label -match '^SW16BR(\d+)\s+["“][^"”]+["”]\s+Repeater$') {
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
        if ($label -match '^FR-(66|76|86)$') {
            return [pscustomobject]@{ Key = 'component:FR-series'; Label = 'FR'; Family = 'hyphen-number-list'; Token = [int]$Matches[1] }
        }
        if ($label -match '^FullSpec(?:-(Go|Max))?$') {
            $token = if ([string]::IsNullOrWhiteSpace([string]$Matches[1])) { 'FullSpec' } else { "FullSpec-$($Matches[1])" }
            return [pscustomobject]@{ Key = 'component:FullSpec'; Label = 'FullSpec'; Family = 'name-list'; Token = $token }
        }
        if ($label -match '^([567])(CA|MA|SA)\s+''[^'']+''$') {
            $series = $Matches[1]
            return [pscustomobject]@{ Key = "component:$series-series"; Label = "${series}CA/${series}MA/${series}SA"; Family = 'variant'; Token = $null }
        }
        if ($label -match '^JS-\d+$') {
            return [pscustomobject]@{ Key = 'component:JS-series'; Label = 'JS-300/400'; Family = 'variant'; Token = $null }
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
    if ($label -match '^(.+?)\s+"[^"]+"\s+(.+)$') {
        $base = ($Matches[1] + ' ' + $Matches[2]).Trim()
        return [pscustomobject]@{ Key = "variant:$base"; Label = "$base variants"; Family = 'variant'; Token = $null }
    }
    if ($Category -eq (Get-SCMiningPlanetCategoryWeapons) -and $label -match '^(.+?)\s+(Energy Assault Rifle|Laser Sniper Rifle|Laser Shotgun|Sniper Rifle|Twin Shotgun|Energy LMG|Pistol|SMG|Rifle|Shotgun|Crossbow|LMG)$') {
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

function Format-SCMiningPlanetRecipeFamilyLabel {
    param([object]$Group)

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

    $first = Invoke-RestMethod -Uri 'https://api.star-citizen.wiki/api/blueprints?page%5Bsize%5D=100&page%5Bnumber%5D=1' -Headers $Headers
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($first.data)) {
        $all.Add($item)
    }

    $lastPage = [int]$first.meta.last_page
    for ($page = 2; $page -le $lastPage; $page++) {
        $result = Invoke-RestMethod -Uri ("https://api.star-citizen.wiki/api/blueprints?page%5Bsize%5D=100&page%5Bnumber%5D={0}" -f $page) -Headers $Headers
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

    $payload = [pscustomobject]@{
        cacheKey = $CacheKey
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

    $byName = Resolve-SCMiningNamePairDescriptionKey -OutputName $outputName -Lookup $Lookup
    if ($byName) {
        return $byName
    }

    return Resolve-SCMiningArmorFamilyDescriptionKey -OutputClass $outputClass -OutputType $outputType -Lookup $Lookup
}

function Resolve-SCMiningDirectDescriptionKey {
    param(
        [string]$OutputClass,
        [object]$Lookup
    )

    if ([string]::IsNullOrWhiteSpace($OutputClass)) {
        return $null
    }

    $stripped = [regex]::Replace($OutputClass, '(?i)_SCItem$', '')
    $variants = @($OutputClass, $stripped) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($variant in $variants) {
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

    foreach ($nameKey in @($Lookup.KeysByValue[$OutputName])) {
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

    if (-not [string]::IsNullOrWhiteSpace([string]$Blueprint.output_class)) {
        return [string]$Blueprint.output_class
    }
    if ($null -ne $Blueprint.output -and -not [string]::IsNullOrWhiteSpace([string]$Blueprint.output.class)) {
        return [string]$Blueprint.output.class
    }

    return [string]$Reward.entityClass
}

function Get-SCMiningBlueprintOutputName {
    param(
        [object]$Blueprint,
        [object]$Reward
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Blueprint.output_name)) {
        return [string]$Blueprint.output_name
    }
    if ($null -ne $Blueprint.output -and -not [string]::IsNullOrWhiteSpace([string]$Blueprint.output.name)) {
        return [string]$Blueprint.output.name
    }

    return [string]$Reward.name
}

function Get-SCMiningBlueprintOutputType {
    param([object]$Blueprint)

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

    $item = Get-SCMiningCachedItemInfo -Blueprint $Blueprint -ItemLookup $ItemLookup
    if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.class)) {
        return ([string]$item.class).Trim()
    }

    $name = Get-SCMiningBlueprintOutputName -Blueprint $Blueprint -Reward $null
    $class = Get-SCMiningBlueprintOutputClass -Blueprint $Blueprint -Reward $null

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
    $resourceText = (@($Resources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ')
    if ([string]::IsNullOrWhiteSpace($resourceText)) {
        return $clean
    }

    if ([string]::IsNullOrWhiteSpace($clean)) {
        return (Get-SCMiningItemCraftHintLine -ResourcesText $resourceText)
    }

    return ($clean.TrimEnd() + '\n\n' + (Get-SCMiningItemCraftHintLine -ResourcesText $resourceText)).TrimEnd()
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
        [object]$Inventory
    )

    $inventory = if ($null -ne $Inventory) { $Inventory } else { Read-SCMiningResourceInventoryFromValue -Value $Value }
    $detailedBlock = ''
    if ($PlanetCraftMap -and $PlanetCraftMap.Count -gt 0) {
        $detailedBlock = Format-SCMiningPlanetCraftBlock -Inventory $inventory -PlanetCraftMap $PlanetCraftMap -SelectedMethods $SelectedMethods -CraftFilter $CraftFilter
    }
    else {
        $detailedBlock = Get-SCMiningFilteredDetailedCraftBlock -Value $Value -SelectedMethods $SelectedMethods
    }

    $basePrefix = Get-SCMiningBaseDescriptionPrefix -Value $Value
    $ownedBlock = Format-SCMiningOwnedResourceBlock -ResourcesByMethod $inventory.ResourcesByMethod -CollectableResources $inventory.CollectableResources -CreatureResources $inventory.CreatureResources -SelectedMethods $SelectedMethods -DetailedCraftBlock $detailedBlock
    if ([string]::IsNullOrWhiteSpace($ownedBlock)) {
        return $basePrefix.TrimEnd()
    }

    return ($basePrefix.TrimEnd() + '\n\n' + $ownedBlock).TrimEnd()
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
        if ($trimmed -eq (Get-SCMiningCraftHeader)) {
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

function Get-SCMiningPlanetSubcategoryPistols {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x041F, 0x0438, 0x0441, 0x0442, 0x043E, 0x043B, 0x0435, 0x0442, 0x044B))
}

function Get-SCMiningPlanetSubcategoryShotguns {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0414, 0x0440, 0x043E, 0x0431, 0x043E, 0x0432, 0x0438, 0x043A, 0x0438))
}

function Get-SCMiningPlanetSubcategoryRifles {
    return (ConvertFrom-SCCodePoints -CodePoints @(0x0412, 0x0438, 0x043D, 0x0442, 0x043E, 0x0432, 0x043A, 0x0438))
}
