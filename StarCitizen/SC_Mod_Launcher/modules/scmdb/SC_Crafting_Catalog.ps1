# Shared, version-pinned recipe and item identity catalog. Item passports remain Wiki-owned.

function Get-SCCraftingCatalogCachePath {
    param([Parameter(Mandatory = $true)][string]$CacheKey)
    if ($CacheKey -notmatch '^\d+\.\d+\.\d+-live\.\d+$') { throw 'Invalid SCMDB crafting build.' }
    return (Join-Path $PSScriptRoot "cache\crafting-catalog-$CacheKey.json")
}

function Get-SCCraftingItemTypeLabel {
    param($Item)
    $types = @{
        Shield = 'Shield'; QuantumDrive = 'Quantum Drive'; PowerPlant = 'Power Plant'
        Cooler = 'Cooler'; Radar = 'Radar'; WeaponMining = 'Weapon Mining'
        MiningModifier = 'Mining Modifier'; SalvageModifier = 'Salvage Modifier'
        WeaponGun = 'Weapon Gun'; WeaponPersonal = 'FPS Weapon'; WeaponAttachment = 'Weapon Attachment'
        Char_Armor_Helmet = 'Helmet (Armor)'; Char_Armor_Arms = 'Arms (Armor)'
        Char_Armor_Torso = 'Torso (Armor)'; Char_Armor_Legs = 'Legs (Armor)'
        Char_Armor_Backpack = 'Backpack (Armor)'; Char_Armor_Undersuit = 'Undersuit (Armor)'
        Char_Clothing_Torso_1 = 'Jacket'; Char_Clothing_Torso_0 = 'Shirt'
        Char_Clothing_Legs = 'Legs'; Char_Clothing_Feet = 'Shoes'
        Container = 'Container'; DockingCollar = 'Docking Collar'; TractorBeam = 'Tractor Beam'
        SalvageHead = 'Salvage Head'; Misc = 'Misc'; Cargo = 'Cargo'
    }
    $type = [string]$Item.attachType
    if ($types.ContainsKey($type)) { return $types[$type] }
    return 'Unknown'
}

function Get-SCCraftingNameAliases {
    # Verified identity corrections: blueprint tag, Wiki identity and clean RuSC agree.
    return @{
        'cdd236fa-56b9-4913-90cf-be7f4e6ca5a7' = 'Antium Arms Maroon'
        '2487dc3a-6a2e-4071-a165-f140d0c8b20d' = 'Antium Helmet Jet'
    }
}

function Normalize-SCCraftingProductName {
    param([AllowEmptyString()][string]$Name)
    # Repair UTF-8 byte sequences that PS5.1 persisted as Latin-1, including
    # NBSP and curly quotes. Standalone accented letters remain unchanged.
    $fixed = [regex]::Replace($Name, '[\u00C2-\u00DF][\u0080-\u00BF]|[\u00E0-\u00EF][\u0080-\u00BF]{2}|[\u00F0-\u00F4][\u0080-\u00BF]{3}', [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        try { return [System.Text.UTF8Encoding]::new($false,$true).GetString([byte[]]@($match.Value.ToCharArray() | ForEach-Object { [byte][int]$_ })) }
        catch { return $match.Value }
    })
    return $fixed.Replace([string][char]0x00A0, ' ')
}

function ConvertTo-SCCraftingFamilyOptionId {
    param([string]$OptionId)
    $parts = $OptionId -split '\|', 4
    if ($parts.Count -ne 4 -or $parts[0] -notin @('craftFamily','questCraftFamily')) { return $OptionId }
    $bad = [string][char]0x00C2
    $aliases = @{
        ('variant:Arrowhead' + $bad + ' Sniper Rifle') = 'variant:Arrowhead Sniper Rifle'
        ('variant:P8-SC' + $bad + ' SMG') = 'variant:P8-SC SMG'
        ('armor:Lynx' + $bad) = 'armor:Lynx'
        ('armor:Oracle' + $bad) = 'armor:Oracle'
        ('exact:Hellion' + $bad + [char]0x00A0 + 'Scattergun') = 'exact:Hellion Scattergun'
        'exact:F55 Shadowflux LMG' = 'variant:F55 LMG'
        'armor:Monolith-Shadowflux' = 'armor:Monolith'
        'exact:YellowJacket GT-210 Gatling' = 'weapon:GT Gatling'
        'exact:Scorpion GT-215 Gatling' = 'weapon:GT Gatling'
        'exact:Mantis GT-220 Gatling' = 'weapon:GT Gatling'
        'armor:Arden-CL' = 'armor:Arden'
        'armor:Arden-SL' = 'armor:Arden'
        'armor:Aztalan Galena' = 'armor:Aztalan'
        'armor:Aztalan Tamarack' = 'armor:Aztalan'
        'exact:Coda Pistol (Modified)' = 'variant:Coda Pistol'
        'variant:Salvo Esteban Frag Pistol' = 'variant:Salvo Frag Pistol'
    }
    if ($aliases.ContainsKey($parts[3])) { $parts[3] = $aliases[$parts[3]] }
    if ($parts[3] -eq 'exact:Thlilye Laser Gatling' -and $parts[2] -eq 'Баллистика') { $parts[2] = 'Энергетика' }
    if ($parts[3] -in @('exact:BRVS Repeater','exact:CVSA Cannon','exact:Havoc Scattergun','exact:Hellion Scattergun','exact:Predator Scattergun') -and $parts[2] -eq 'Энергетика') { $parts[2] = 'Баллистика' }
    return ($parts -join '|')
}

function Get-SCCraftingCatalogDiagnostics {
    param([Parameter(Mandatory = $true)]$Catalog)
    $items = @{}
    foreach ($item in @($Catalog.itemData.items)) { $items[[string]$item.entityClass] = $true }
    $aliases = Get-SCCraftingNameAliases
    $issues = New-Object System.Collections.Generic.List[object]
    $corrections = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($Catalog.blueprintData.blueprints)) {
        $id = [string]$record.guid
        $missingItem = -not $items.ContainsKey([string]$record.productEntityClass)
        if ($aliases.ContainsKey($id) -and [string]$record.productName -ne [string]$aliases[$id]) {
            $corrections.Add([pscustomobject]@{ blueprintGuid = $id; tag = [string]$record.tag; sourceName = $record.productName; displayName = [string]$aliases[$id]; status = 'corrected'; evidence = 'verified Wiki identity and clean RuSC' })
        }
        $missingName = [string]::IsNullOrWhiteSpace([string]$record.productName) -and -not $aliases.ContainsKey($id)
        if ($missingName -or $missingItem) {
            $issues.Add([pscustomobject]@{ blueprintGuid = $id; tag = [string]$record.tag; productGuid = [string]$record.productEntityClass; missingName = $missingName; missingProductIdentity = $missingItem; status = 'unresolved' })
        }
    }
    return [pscustomobject]@{
        source = 'SCMDB'; gameVersion = [string]$Catalog.cacheKey
        recipeCount = @($Catalog.blueprintData.blueprints).Count
        status = $(if ($issues.Count -gt 0) { 'partial' } else { 'complete' })
        unresolvedCount = $issues.Count
        missingNameCount = @($issues.ToArray() | Where-Object { $_.missingName }).Count
        missingProductIdentityCount = @($issues.ToArray() | Where-Object { $_.missingProductIdentity }).Count
        correctedNameCount = $corrections.Count
        issues = @($issues.ToArray()); nameCorrections = @($corrections.ToArray())
    }
}

function Write-SCCraftingCatalogDiagnostics {
    param([Parameter(Mandatory = $true)]$Diagnostics)
    Write-Host "SCMDB crafting coverage: $($Diagnostics.status.ToUpperInvariant()); $($Diagnostics.recipeCount) recipes; unresolved: $($Diagnostics.unresolvedCount); missing names: $($Diagnostics.missingNameCount); missing product identities: $($Diagnostics.missingProductIdentityCount); corrected names: $($Diagnostics.correctedNameCount)"
    foreach ($issue in @($Diagnostics.issues)) {
        Write-Host "  Unresolved recipe: $($issue.tag); missing name: $($issue.missingName); missing product identity: $($issue.missingProductIdentity); blueprint: $($issue.blueprintGuid)"
    }
}

function ConvertTo-SCCraftingRecipes {
    param([Parameter(Mandatory = $true)]$BlueprintData, [Parameter(Mandatory = $true)]$ItemData)
    $items = @{}
    foreach ($item in @($ItemData.items)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item.entityClass)) { $items[[string]$item.entityClass] = $item }
    }
    $nameAliases = Get-SCCraftingNameAliases
    foreach ($record in @($BlueprintData.blueprints)) {
        $item = $items[[string]$record.productEntityClass]
        $class = [regex]::Replace([string]$record.tag, '(?i)^BP_(?:CRAFT_)?', '')
        $name = Normalize-SCCraftingProductName -Name ([string]$record.productName)
        # Keep unnamed products unresolved; class tags are not player-facing names.
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $null }
        # These established labels match the blueprint tag and clean LIVE keys;
        # SCMDB's resolved product names point to other Antium parts for these records.
        if ($nameAliases.ContainsKey([string]$record.guid)) { $name = $nameAliases[[string]$record.guid] }
        $type = Get-SCCraftingItemTypeLabel -Item $item
        # Unresolved products retain their declared blueprint type without inventing item stats.
        if ($type -eq 'Unknown') {
            $declared = @{ cooler = 'Cooler'; radar = 'Radar'; shield = 'Shield'; powerplant = 'Power Plant'; quantumdrive = 'Quantum Drive' }
            if ($declared.ContainsKey([string]$record.type)) { $type = $declared[[string]$record.type] }
        }
        $ingredients = @{}
        $ingredientOrder = New-Object System.Collections.Generic.List[string]
        $tiers = @($record.tiers)
        foreach ($slot in @($tiers[0].slots)) {
            foreach ($option in @($slot.options)) {
                $ingredientName = if ($option.type -eq 'resource') { [string]$option.resourceName } else { [string]$option.itemName }
                $key = [string]$option.type + '|' + $ingredientName
                if (-not $ingredients.ContainsKey($key)) {
                    $ingredientOrder.Add($key)
                    $ingredients[$key] = [pscustomobject]@{ name = $ingredientName; quantity = [decimal]0; quantity_scu = $null; kind = [string]$option.type; unit = $(if ($option.type -eq 'resource') { 'SCU' } else { 'count' }) }
                }
                $ingredients[$key].quantity += [decimal]$option.quantity
                if ($option.type -eq 'resource') { $ingredients[$key].quantity_scu = $ingredients[$key].quantity }
            }
        }
        [pscustomobject]@{
            uuid = [string]$record.guid; key = [string]$record.tag
            output_class = $class; output_name = $name; productEntityClass = [string]$record.productEntityClass
            output = [pscustomobject]@{ class = $class; name = $name; type = $type; type_label = $type; size = $item.size; grade = $item.grade; componentClass = $item.componentClass; attachSubType = $item.attachSubType; weaponSubtype = [string]$record.subtype }
            ingredients = @($ingredientOrder | ForEach-Object { $ingredients[$_] })
            craft_time_seconds = $tiers[0].craftTimeSeconds; game_version = [string]$BlueprintData.version
            source = 'SCMDB'; tiers = @($tiers)
        }
    }
}

function Assert-SCCraftingSourceData {
    param([Parameter(Mandatory = $true)]$BlueprintData, [Parameter(Mandatory = $true)]$ItemData, [Parameter(Mandatory = $true)][string]$CacheKey)
    if ([string]$BlueprintData.version -ne $CacheKey -or [string]$ItemData.version -ne $CacheKey) { throw 'SCMDB crafting source build mismatch.' }
    if (@($BlueprintData.blueprints).Count -lt 1 -or @($ItemData.items).Count -lt 1) { throw 'SCMDB crafting source is empty.' }
    if ([int]$BlueprintData.meta.totalBlueprints -ne @($BlueprintData.blueprints).Count) { throw 'SCMDB blueprint catalog is incomplete.' }
    if ([int]$ItemData.meta.totalItems -ne @($ItemData.items).Count) { throw 'SCMDB item catalog is incomplete.' }
    $seen = @{}
    foreach ($record in @($BlueprintData.blueprints)) {
        if ([string]$record.guid -notmatch '^[a-fA-F0-9-]{36}$' -or $seen.ContainsKey([string]$record.guid) -or [string]::IsNullOrWhiteSpace([string]$record.tag)) { throw 'SCMDB blueprint identity is invalid or duplicated.' }
        $seen[[string]$record.guid] = $true
        $tiers = @($record.tiers)
        if ($tiers.Count -ne 1) { throw 'SCMDB recipe tiers need an updated hint adapter.' }
        # Current hints flatten the first tier. Reject unsupported choices instead of displaying all alternatives as mandatory ingredients.
        foreach ($tier in $tiers) {
            if ($null -eq $tier.craftTimeSeconds -or [decimal]$tier.craftTimeSeconds -lt 0 -or @($tier.slots).Count -lt 1) { throw 'SCMDB blueprint tier is invalid.' }
            foreach ($slot in @($tier.slots)) {
                if (@($slot.options).Count -ne 1) { throw 'SCMDB recipe alternatives need an updated hint adapter.' }
                foreach ($option in @($slot.options)) {
                    $name = if ($option.type -eq 'resource') { [string]$option.resourceName } else { [string]$option.itemName }
                    if ($option.type -notin @('resource', 'item') -or [string]::IsNullOrWhiteSpace($name) -or $null -eq $option.quantity -or [decimal]$option.quantity -le 0 -or $null -eq $option.minQuality) { throw 'SCMDB recipe ingredient is invalid.' }
                }
            }
        }
    }
    $seenItems = @{}
    foreach ($item in @($ItemData.items)) {
        if ([string]$item.entityClass -notmatch '^[a-fA-F0-9-]{36}$' -or $seenItems.ContainsKey([string]$item.entityClass)) { throw 'SCMDB item identity is invalid or duplicated.' }
        $seenItems[[string]$item.entityClass] = $true
    }
}

function Read-SCCraftingCatalog {
    param([Parameter(Mandatory = $true)][string]$CacheKey)
    $path = Get-SCCraftingCatalogCachePath -CacheKey $CacheKey
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $cache = Get-Content -LiteralPath $path -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($cache.schemaVersion -ne 1 -or [string]$cache.cacheKey -ne $CacheKey -or [string]$cache.source -ne 'SCMDB') { throw 'SCMDB crafting cache identity mismatch.' }
    Assert-SCCraftingSourceData -BlueprintData $cache.blueprintData -ItemData $cache.itemData -CacheKey $CacheKey
    return $cache
}

function Write-SCCraftingCatalog {
    param([Parameter(Mandatory = $true)][string]$CacheKey, [Parameter(Mandatory = $true)]$BlueprintData, [Parameter(Mandatory = $true)]$ItemData)
    Assert-SCCraftingSourceData -BlueprintData $BlueprintData -ItemData $ItemData -CacheKey $CacheKey
    # Only identity/classification fields are retained from crafting_items; Wiki passports own all displayed TTX.
    $identityData = [pscustomobject]@{ version = $CacheKey; meta = [pscustomobject]@{ totalItems = @($ItemData.items).Count }; items = @($ItemData.items | Select-Object entityClass, name, itemType, attachType, attachSubType, cgItemType, size, grade, componentClass, manufacturer, manufacturerCode) }
    $payload = [pscustomobject]@{
        schemaVersion = 1; cacheKey = $CacheKey; gameVersion = $CacheKey; versionMatch = 'exact'; source = 'SCMDB'; createdAt = (Get-Date).ToString('o')
        sourceUrls = @("https://scmdb.net/data/crafting_blueprints-$CacheKey.json", "https://scmdb.net/data/crafting_items-$CacheKey.json")
        blueprintData = $BlueprintData; itemData = $identityData
    }
    $path = Get-SCCraftingCatalogCachePath -CacheKey $CacheKey
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($temp, ($payload | ConvertTo-Json -Depth 80), [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path -PathType Leaf) { [System.IO.File]::Replace($temp, $path, [System.Management.Automation.Language.NullString]::Value) }
        else { [System.IO.File]::Move($temp, $path) }
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    return $path
}

function Invoke-SCCraftingRemoteJson {
    param([string]$Uri, [hashtable]$Headers)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing -TimeoutSec 30
    # JSON is UTF-8 even when the server omits charset. PS5.1 Content defaults
    # to Latin-1 and corrupts names; read the original response bytes instead.
    $json = [System.Text.UTF8Encoding]::new($false, $true).GetString($response.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
    return ($json | ConvertFrom-Json)
}

function Update-SCCraftingCatalog {
    param([Parameter(Mandatory = $true)][string]$CacheKey, [hashtable]$Headers)
    try {
        $blueprints = Invoke-SCCraftingRemoteJson -Uri "https://scmdb.net/data/crafting_blueprints-$CacheKey.json" -Headers $Headers
        $items = Invoke-SCCraftingRemoteJson -Uri "https://scmdb.net/data/crafting_items-$CacheKey.json" -Headers $Headers
        $path = Write-SCCraftingCatalog -CacheKey $CacheKey -BlueprintData $blueprints -ItemData $items
        Write-Host 'Source SCMDB crafting catalogs: OK; exact build'
        return $path
    }
    catch {
        $reason = $_.Exception.Message
        $existing = Read-SCCraftingCatalog -CacheKey $CacheKey
        if ($null -eq $existing) { throw "SCMDB crafting refresh failed with no verified exact-build cache: $reason" }
        Write-Host "Source SCMDB crafting catalogs: FALLBACK; $reason"
        return (Get-SCCraftingCatalogCachePath -CacheKey $CacheKey)
    }
}

function Get-SCCraftingRecipes {
    param([Parameter(Mandatory = $true)][string]$CacheKey)
    $cache = Read-SCCraftingCatalog -CacheKey $CacheKey
    if ($null -eq $cache) { return @() }
    return @(ConvertTo-SCCraftingRecipes -BlueprintData $cache.blueprintData -ItemData $cache.itemData)
}
