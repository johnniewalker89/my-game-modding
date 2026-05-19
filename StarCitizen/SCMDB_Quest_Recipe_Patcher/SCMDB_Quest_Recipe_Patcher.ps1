param(
    [Parameter(Position = 0)]
    [string]$LivePath,

    [string]$GlobalIniPath,

    [switch]$DryRun,

    [switch]$NoBackup,

    [switch]$RestoreLatestBackup,

    [switch]$NoWikiEnrichment,

    [switch]$NoCache,

    [switch]$KeepExistingBlueprintBlocks,

    [string]$TitleMarker = '[ЧЕРТЁЖ]',

    [string]$ReportPath,

    [string]$OverridesPath,

    [string]$WikiCachePath
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScmdbBaseUrl = 'https://scmdb.net/data'
$WikiApiBaseUrl = 'https://api.star-citizen.wiki/api'
$LocalizationRelativePath = 'data\Localization\korean_(south_korea)\global.ini'

$CategoryOrder = @(
    'Броня/одежда',
    'Оружие',
    'Корабельные компоненты',
    'Корабельные орудия',
    'Снаряжение/расходники',
    'Материалы/особое',
    'Не распознано'
)

if (-not $OverridesPath) {
    $OverridesPath = Join-Path $ScriptDir 'data\blueprint-overrides.ru.json'
}

if (-not $WikiCachePath) {
    $WikiCachePath = Join-Path $ScriptDir 'cache\wiki-items-cache.json'
}

function ConvertTo-Array {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return $Value
    }

    return @($Value)
}

function ConvertTo-Hashtable {
    param($Value)

    $result = @{}
    if ($null -eq $Value) {
        return $result
    }

    foreach ($property in $Value.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }

    return $result
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Resolve-GlobalIniPath {
    param(
        [string]$InputLivePath,
        [string]$InputGlobalIniPath
    )

    if ($InputGlobalIniPath) {
        $resolved = [System.IO.Path]::GetFullPath($InputGlobalIniPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "global.ini not found: $resolved"
        }
        return $resolved
    }

    if (-not $InputLivePath) {
        $InputLivePath = Read-Host 'Enter path to StarCitizen\LIVE'
    }

    $root = [System.IO.Path]::GetFullPath($InputLivePath)
    $candidates = @(
        (Join-Path $root $LocalizationRelativePath),
        (Join-Path (Join-Path $root 'LIVE') $LocalizationRelativePath)
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    throw "global.ini not found. Expected: <LIVE>\$LocalizationRelativePath"
}

function Get-TextEncodingInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [pscustomobject]@{
            Encoding = New-Object System.Text.UTF8Encoding($true)
            Name = 'UTF-8 BOM'
        }
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [pscustomobject]@{
            Encoding = [System.Text.Encoding]::Unicode
            Name = 'UTF-16 LE'
        }
    }

    return [pscustomobject]@{
        Encoding = New-Object System.Text.UTF8Encoding($false)
        Name = 'UTF-8'
    }
}

function Get-NormalizedIniKey {
    param([Parameter(Mandatory = $true)][string]$LineKey)

    return ($LineKey.Trim() -replace ',.*$', '')
}

function Remove-BlueprintBlock {
    param([Parameter(Mandatory = $true)][string]$Value)

    $clean = $Value
    $generatedPatterns = @(
        '\\n\\n<EM\d>Доступные чертежи \(SCMDB\)</EM\d>.*$',
        '\\n\\n<EM\d>Возможные чертежи \(SCMDB\)</EM\d>.*$'
    )

    foreach ($pattern in $generatedPatterns) {
        $clean = [regex]::Replace($clean, $pattern, '')
    }

    if (-not $KeepExistingBlueprintBlocks) {
        $legacyPattern = '\\n\\n<EM\d>(Доступные чертежи|Potential Blueprints)(?:\s*\([^<]*\))?\s*</EM\d>.*$'
        $clean = [regex]::Replace($clean, $legacyPattern, '')
    }

    return $clean
}

function Remove-TitleMarker {
    param([Parameter(Mandatory = $true)][string]$Value)

    $clean = $Value
    $patterns = @(
        '^\s*<EM\d>\[BP\]</EM\d>\s*',
        '^\s*<EM\d>\[Ч\]</EM\d>\s*',
        '^\s*<EM\d>\[ЧЕРТ\]</EM\d>\s*',
        '^\s*<EM\d>\[ЧЕРТЕЖ\]</EM\d>\s*',
        '^\s*<EM\d>\[ЧЕРТЁЖ\]</EM\d>\s*',
        '^\s*<EM\d>\[Чертежи\]\*?</EM\d>\s*',
        '^\s*\[BP\]\s*',
        '^\s*\[Ч\]\s*',
        '^\s*\[ЧЕРТ\]\s*',
        '^\s*\[ЧЕРТЕЖ\]\s*',
        '^\s*\[ЧЕРТЁЖ\]\s*',
        '^\s*\[Чертежи\]\*?\s*'
    )

    foreach ($pattern in $patterns) {
        $clean = [regex]::Replace($clean, $pattern, '')
    }

    return $clean
}

function Get-ScmdbData {
    Write-Host 'Downloading SCMDB version index...'
    $versions = ConvertTo-Array (Invoke-RestMethod -Uri "$ScmdbBaseUrl/game-versions.json" -UseBasicParsing)
    if ($versions.Count -eq 0) {
        throw 'SCMDB version index is empty.'
    }

    $activeVersion = $versions[0]
    $version = $activeVersion.version
    $file = $activeVersion.file

    if (-not $version -or -not $file) {
        throw 'SCMDB version index does not contain version/file fields.'
    }

    Write-Host "Downloading SCMDB game data: $version..."
    $data = Invoke-RestMethod -Uri "$ScmdbBaseUrl/$file" -UseBasicParsing

    return [pscustomobject]@{
        Version = $version
        File = $file
        Data = $data
    }
}

function Add-NameToPool {
    param(
        [Parameter(Mandatory = $true)]$PoolEntry,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    if (-not $PoolEntry.Names.ContainsKey($Name)) {
        $PoolEntry.Names[$Name] = $true
    }
}

function New-RewardMap {
    param([Parameter(Mandatory = $true)]$Scmdb)

    $data = $Scmdb.Data
    $contracts = @()
    $contracts += ConvertTo-Array $data.contracts
    $contracts += ConvertTo-Array $data.legacyContracts

    $descriptionMap = @{}
    $titleMap = @{}
    $rewardContractCount = 0

    foreach ($contract in $contracts) {
        $rewards = ConvertTo-Array $contract.blueprintRewards
        if ($rewards.Count -eq 0) {
            continue
        }

        $rewardContractCount++

        $descKey = $contract.descriptionLocKey
        if (-not $descKey -and $contract.descriptionKey) {
            $descKey = ($contract.descriptionKey -replace '^@', '')
        }

        $titleKey = $contract.titleLocKey
        if (-not $titleKey -and $contract.titleKey) {
            $titleKey = ($contract.titleKey -replace '^@', '')
        }

        if (-not [string]::IsNullOrWhiteSpace($titleKey)) {
            $titleMap[$titleKey] = $true
        }

        if ([string]::IsNullOrWhiteSpace($descKey)) {
            continue
        }

        if (-not $descriptionMap.ContainsKey($descKey)) {
            $descriptionMap[$descKey] = @{
                Key = $descKey
                Contracts = @{}
                Pools = @{}
                RewardSignatures = @{}
            }
        }

        $group = $descriptionMap[$descKey]
        $debugName = if ($contract.debugName) { $contract.debugName } else { '<unknown>' }
        $group.Contracts[$debugName] = $true

        $signatureParts = New-Object System.Collections.Generic.List[string]

        foreach ($reward in $rewards) {
            $poolId = [string]$reward.blueprintPool
            if ([string]::IsNullOrWhiteSpace($poolId)) {
                continue
            }

            $pool = Get-PropertyValue -Object $data.blueprintPools -Name $poolId
            if ($null -eq $pool) {
                continue
            }

            $trigger = if ($reward.trigger) { [string]$reward.trigger } else { 'complete' }
            $chance = if ($null -ne $reward.chance) { [decimal]$reward.chance } else { [decimal]1 }
            $poolName = if ($reward.poolName) { [string]$reward.poolName } elseif ($pool.name) { [string]$pool.name } else { $poolId }
            $poolKey = "$trigger|$chance|$poolId"

            if (-not $group.Pools.ContainsKey($poolKey)) {
                $group.Pools[$poolKey] = @{
                    PoolId = $poolId
                    PoolName = $poolName
                    Trigger = $trigger
                    Chance = $chance
                    Names = @{}
                }
            }

            $poolEntry = $group.Pools[$poolKey]
            $namesForSignature = New-Object System.Collections.Generic.List[string]

            foreach ($blueprint in (ConvertTo-Array $pool.blueprints)) {
                $name = [string]$blueprint.name
                Add-NameToPool -PoolEntry $poolEntry -Name $name
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $namesForSignature.Add($name)
                }
            }

            $signatureNames = ($namesForSignature | Sort-Object -Unique) -join '|'
            $signatureParts.Add("$trigger|$chance|$poolId|$signatureNames")
        }

        $signature = ($signatureParts | Sort-Object) -join '||'
        if (-not $group.RewardSignatures.ContainsKey($signature)) {
            $group.RewardSignatures[$signature] = $true
        }
    }

    return [pscustomobject]@{
        DescriptionMap = $descriptionMap
        TitleMap = $titleMap
        TotalContracts = $contracts.Count
        RewardContracts = $rewardContractCount
    }
}

function Get-UniqueBlueprintNames {
    param([Parameter(Mandatory = $true)]$DescriptionMap)

    $names = @{}
    foreach ($group in $DescriptionMap.Values) {
        foreach ($poolEntry in $group.Pools.Values) {
            foreach ($name in $poolEntry.Names.Keys) {
                $names[$name] = $true
            }
        }
    }

    return @($names.Keys | Sort-Object)
}

function Get-DescriptionDataValue {
    param(
        $Item,
        [string]$Name
    )

    foreach ($entry in (ConvertTo-Array $Item.description_data)) {
        if ($entry.name -eq $Name) {
            return [string]$entry.value
        }
    }

    return $null
}

function ConvertTo-RussianItemType {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $map = @{
        'Quantum Drive' = 'квантовый двигатель'
        'Shield Generator' = 'щит'
        'Shield' = 'щит'
        'Power Plant' = 'силовая установка'
        'Cooler' = 'охладитель'
        'Radar' = 'радар'
        'Laser Cannon' = 'лазерная пушка'
        'Ballistic Cannon' = 'баллистическая пушка'
        'Laser Repeater' = 'лазерный повторитель'
        'Ballistic Gatling' = 'баллистический гатлинг'
        'Distortion Cannon' = 'дисторсионная пушка'
        'Scattergun' = 'разбросное орудие'
        'Mining Laser' = 'добывающий лазер'
        'Scraper Module' = 'скребковый модуль'
        'Missile' = 'ракета'
        'Bomb' = 'бомба'
        'Sniper Rifle' = 'снайперская винтовка'
        'Rifle' = 'винтовка'
        'Pistol' = 'пистолет'
        'Shotgun' = 'дробовик'
        'LMG' = 'пулемёт'
        'SMG' = 'пистолет-пулемёт'
        'Battery' = 'аккумулятор'
        'Magazine' = 'магазин'
        'Ammo' = 'боеприпасы'
        'Heavy Armor' = 'тяжёлая броня'
        'Medium Armor' = 'средняя броня'
        'Light Armor' = 'лёгкая броня'
        'Undersuit' = 'нижний костюм'
    }

    if ($map.ContainsKey($Value)) {
        return $map[$Value]
    }

    foreach ($key in $map.Keys) {
        if ($Value -match [regex]::Escape($key)) {
            return $map[$key]
        }
    }

    return $Value
}

function Format-DisplayName {
    param([Parameter(Mandatory = $true)][string]$Name)

    return ($Name -replace 'Â ', ' ' -replace [string][char]0x00A0, ' ')
}

function ConvertTo-ArmorSlot {
    param($Item)

    $name = [string]$Item.name
    $type = [string]$Item.type
    $label = [string]$Item.classification_label

    if ($name -match '(?i)\bHelmet\b') { return 'шлем' }
    if ($name -match '(?i)\bCore\b') { return 'корпус' }
    if ($name -match '(?i)\bArms\b') { return 'руки' }
    if ($name -match '(?i)\bLegs\b') { return 'ноги' }
    if ($name -match '(?i)\bBackpack\b') { return 'рюкзак' }

    if ($type -match 'Helmet' -or $label -match 'Helmet') { return 'шлем' }
    if ($type -match 'Torso' -or $label -match 'Torso') { return 'корпус' }
    if ($type -match 'Arms' -or $label -match 'Arms') { return 'руки' }
    if ($type -match 'Legs' -or $label -match 'Legs') { return 'ноги' }
    if ($type -match 'Backpack' -or $label -match 'Backpack') { return 'рюкзак' }

    return $null
}

function Get-CategoryFromWikiItem {
    param($Item)

    $itemType = Get-DescriptionDataValue -Item $Item -Name 'Item Type'
    $classification = [string]$Item.classification_label
    $type = [string]$Item.type
    $name = [string]$Item.name

    if ($name -match '(?i)\b(Magazine|Battery|Ammo)\b' -or $itemType -match 'Magazine|Battery|Ammo|Attachment|Module') {
        return 'Снаряжение/расходники'
    }

    if ($type -match '^Char_' -or $itemType -match 'Armor|Undersuit|Clothing') {
        return 'Броня/одежда'
    }

    if ($type -eq 'WeaponPersonal' -or $classification -match 'Weapon' -or $itemType -match 'Rifle|Pistol|Shotgun|SMG|LMG|Sniper') {
        return 'Оружие'
    }

    if ($itemType -match 'Shield|Quantum Drive|Power Plant|Cooler|Radar' -or $type -match 'Shield|QuantumDrive|PowerPlant|Cooler|Radar') {
        return 'Корабельные компоненты'
    }

    if ($itemType -match 'Cannon|Repeater|Gatling|Scattergun|Missile|Bomb|Mining Laser' -or $type -match 'WeaponGun|Missile|Bomb|WeaponMining') {
        return 'Корабельные орудия'
    }

    return 'Не распознано'
}

function New-EnrichmentFromWikiItem {
    param($Item)

    $itemType = Get-DescriptionDataValue -Item $Item -Name 'Item Type'
    $manufacturer = Get-DescriptionDataValue -Item $Item -Name 'Manufacturer'
    $size = Get-DescriptionDataValue -Item $Item -Name 'Size'
    $grade = Get-DescriptionDataValue -Item $Item -Name 'Grade'
    $class = Get-DescriptionDataValue -Item $Item -Name 'Class'

    if ([string]::IsNullOrWhiteSpace($size) -and $null -ne $Item.size) {
        $size = [string]$Item.size
    }

    $category = Get-CategoryFromWikiItem -Item $Item
    $typeRu = ConvertTo-RussianItemType -Value $itemType
    if (-not $typeRu) {
        $typeRu = ConvertTo-RussianItemType -Value ([string]$Item.classification_label)
    }

    $slot = ConvertTo-ArmorSlot -Item $Item
    $name = [string]$Item.name

    if ($category -eq 'Снаряжение/расходники') {
        if ($name -match '(?i)\bMagazine\b') { $typeRu = 'магазин' }
        elseif ($name -match '(?i)\bBattery\b') { $typeRu = 'аккумулятор' }
        elseif ($name -match '(?i)\bAmmo\b') { $typeRu = 'боеприпасы' }
    }
    elseif ($category -eq 'Броня/одежда') {
        if ([string]$Item.sub_type -eq 'Heavy') { $typeRu = 'тяжёлая броня' }
        elseif ([string]$Item.sub_type -eq 'Medium') { $typeRu = 'средняя броня' }
        elseif ([string]$Item.sub_type -eq 'Light') { $typeRu = 'лёгкая броня' }
        elseif (-not $typeRu -or $typeRu -notmatch 'броня|костюм') { $typeRu = 'броня' }
    }

    return [pscustomobject]@{
        found = $true
        source = 'wiki'
        category = $category
        type = $typeRu
        slot = $slot
        size = $size
        grade = $grade
        class = $class
        manufacturer = $manufacturer
    }
}

function Get-PatternEnrichment {
    param([Parameter(Mandatory = $true)][string]$Name)

    $category = 'Не распознано'
    $type = $null
    $slot = $null

    if ($Name -match '(?i)\b(Helmet)\b') { $category = 'Броня/одежда'; $type = 'броня'; $slot = 'шлем' }
    elseif ($Name -match '(?i)\b(Core)\b') { $category = 'Броня/одежда'; $type = 'броня'; $slot = 'корпус' }
    elseif ($Name -match '(?i)\b(Arms)\b') { $category = 'Броня/одежда'; $type = 'броня'; $slot = 'руки' }
    elseif ($Name -match '(?i)\b(Legs)\b') { $category = 'Броня/одежда'; $type = 'броня'; $slot = 'ноги' }
    elseif ($Name -match '(?i)\b(Suit|Undersuit)\b') { $category = 'Броня/одежда'; $type = 'нижний костюм' }
    elseif ($Name -match '(?i)\b(Sniper Rifle)\b') { $category = 'Оружие'; $type = 'снайперская винтовка' }
    elseif ($Name -match '(?i)\b(Pistol)\b') { $category = 'Оружие'; $type = 'пистолет' }
    elseif ($Name -match '(?i)\b(Shotgun)\b') { $category = 'Оружие'; $type = 'дробовик' }
    elseif ($Name -match '(?i)\b(LMG)\b') { $category = 'Оружие'; $type = 'пулемёт' }
    elseif ($Name -match '(?i)\b(SMG)\b') { $category = 'Оружие'; $type = 'пистолет-пулемёт' }
    elseif ($Name -match '(?i)\b(Rifle)\b') { $category = 'Оружие'; $type = 'винтовка' }
    elseif ($Name -match '(?i)\b(Cannon|Repeater|Gatling|Scattergun|Missile|Torpedo)\b') { $category = 'Корабельные орудия'; $type = 'корабельное орудие' }
    elseif ($Name -match '(?i)\b(Shield|Cooler|Power|Quantum|Radar)\b') { $category = 'Корабельные компоненты'; $type = 'корабельный компонент' }
    elseif ($Name -match '(?i)\b(Magazine|Ammo|Battery|MedPen|Medgun|Multi-Tool|Tool|Module|Attachment|Scope|Barrel|Suppressor)\b') { $category = 'Снаряжение/расходники'; $type = 'снаряжение' }

    if ($category -eq 'Не распознано') {
        return [pscustomobject]@{
            found = $false
            source = 'unknown'
            category = $category
            type = $null
            slot = $null
            size = $null
            grade = $null
            class = $null
            manufacturer = $null
        }
    }

    return [pscustomobject]@{
        found = $true
        source = 'pattern'
        category = $category
        type = $type
        slot = $slot
        size = $null
        grade = $null
        class = $null
        manufacturer = $null
    }
}

function Read-JsonHashtable {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{}
    }

    $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($json)) {
        return @{}
    }

    return ConvertTo-Hashtable ($json | ConvertFrom-Json)
}

function Write-JsonHashtable {
    param(
        [string]$Path,
        [hashtable]$Value
    )

    $dir = Split-Path -Parent $Path
    if ($dir) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 10
    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

function Get-WikiItemsByName {
    param([string[]]$Names)

    $itemsByName = @{}
    if ($NoWikiEnrichment -or $Names.Count -eq 0) {
        return $itemsByName
    }

    $chunkSize = 5
    for ($offset = 0; $offset -lt $Names.Count; $offset += $chunkSize) {
        $chunk = @($Names[$offset..([Math]::Min($offset + $chunkSize - 1, $Names.Count - 1))])
        $query = ($chunk | ForEach-Object { 'filter[name][]=' + [System.Uri]::EscapeDataString($_) }) -join '&'
        $uri = "$WikiApiBaseUrl/items?$query&page[size]=100"

        try {
            $response = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
            foreach ($item in (ConvertTo-Array $response.data)) {
                if ($item.name -and -not $itemsByName.ContainsKey([string]$item.name)) {
                    $itemsByName[[string]$item.name] = $item
                }
            }
        }
        catch {
            Write-Warning "Wiki API lookup failed for chunk starting at ${offset}: $($_.Exception.Message)"
        }
    }

    return $itemsByName
}

function Merge-OverrideEnrichment {
    param(
        $Base,
        $Override
    )

    $merged = if ($Base) {
        [ordered]@{
            found = $true
            source = $Base.source
            category = $Base.category
            type = $Base.type
            slot = $Base.slot
            size = $Base.size
            grade = $Base.grade
            class = $Base.class
            manufacturer = $Base.manufacturer
        }
    }
    else {
        [ordered]@{
            found = $true
            source = 'override'
            category = 'Не распознано'
            type = $null
            slot = $null
            size = $null
            grade = $null
            class = $null
            manufacturer = $null
        }
    }

    foreach ($property in $Override.PSObject.Properties) {
        $merged[$property.Name] = $property.Value
    }

    $merged['found'] = $true
    $merged['source'] = 'override'

    return [pscustomobject]$merged
}

function New-EnrichmentMap {
    param([string[]]$Names)

    $cache = if ($NoCache) { @{} } else { Read-JsonHashtable -Path $WikiCachePath }
    $overrides = Read-JsonHashtable -Path $OverridesPath
    $result = @{}
    $namesForWiki = New-Object System.Collections.Generic.List[string]

    foreach ($name in $Names) {
        if (-not $NoCache -and $cache.ContainsKey($name)) {
            $cached = $cache[$name]
            if ($cached.found) {
                $result[$name] = $cached
            }
            else {
                $result[$name] = $cached
            }
        }
        else {
            $namesForWiki.Add($name)
        }
    }

    if ($namesForWiki.Count -gt 0 -and -not $NoWikiEnrichment) {
        Write-Host "Querying Star Citizen Wiki API for $($namesForWiki.Count) blueprint names..."
        $wikiItems = Get-WikiItemsByName -Names @($namesForWiki)
        foreach ($name in $namesForWiki) {
            if ($wikiItems.ContainsKey($name)) {
                $enrichment = New-EnrichmentFromWikiItem -Item $wikiItems[$name]
                $result[$name] = $enrichment
                if (-not $NoCache) {
                    $cache[$name] = $enrichment
                }
            }
            elseif (-not $NoCache) {
                $cache[$name] = [pscustomobject]@{
                    found = $false
                    source = 'wiki-miss'
                }
            }
        }
    }

    foreach ($name in $Names) {
        if ($overrides.ContainsKey($name)) {
            $base = if ($result.ContainsKey($name)) { $result[$name] } else { $null }
            $result[$name] = Merge-OverrideEnrichment -Base $base -Override $overrides[$name]
        }
    }

    foreach ($name in $Names) {
        if (-not $result.ContainsKey($name)) {
            $result[$name] = Get-PatternEnrichment -Name $name
        }
        elseif (-not $result[$name].found) {
            $result[$name] = Get-PatternEnrichment -Name $name
        }
    }

    if (-not $NoCache) {
        Write-JsonHashtable -Path $WikiCachePath -Value $cache
    }

    return $result
}

function Format-BlueprintLine {
    param([Parameter(Mandatory = $true)][string]$Name)

    $info = $script:BlueprintEnrichment[$Name]
    if ($null -eq $info -or -not $info.found) {
        return "- $(Format-DisplayName -Name $Name)"
    }

    $details = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($info.type)) {
        $details.Add((ConvertTo-RussianItemType -Value ([string]$info.type)))
    }
    if (-not [string]::IsNullOrWhiteSpace($info.slot)) {
        $details.Add([string]$info.slot)
    }
    $includeShipStats = $info.category -eq 'Корабельные компоненты' -or $info.category -eq 'Корабельные орудия'

    if ($includeShipStats -and -not [string]::IsNullOrWhiteSpace($info.size)) {
        $details.Add("S$($info.size)")
    }
    if ($includeShipStats -and -not [string]::IsNullOrWhiteSpace($info.grade)) {
        $details.Add("Grade $($info.grade)")
    }
    if ($includeShipStats -and -not [string]::IsNullOrWhiteSpace($info.class)) {
        $details.Add([string]$info.class)
    }

    if ($details.Count -eq 0) {
        return "- $(Format-DisplayName -Name $Name)"
    }

    return "- $(Format-DisplayName -Name $Name) — " + ($details -join ', ')
}

function Format-RewardBlock {
    param([Parameter(Mandatory = $true)]$Group)

    $hasConflictingRewards = $Group.RewardSignatures.Count -gt 1
    $header = if ($hasConflictingRewards) { 'Возможные чертежи (SCMDB)' } else { 'Доступные чертежи (SCMDB)' }

    $blockLines = New-Object System.Collections.Generic.List[string]
    $blockLines.Add("<EM4>$header</EM4>")

    if ($hasConflictingRewards) {
        $blockLines.Add('<EM2>Описание используется несколькими вариантами миссии; список объединён.</EM2>')
    }

    $allNames = @{}
    foreach ($poolEntry in $Group.Pools.Values) {
        foreach ($name in $poolEntry.Names.Keys) {
            $allNames[$name] = $true
        }
    }

    $groups = @{}
    foreach ($category in $CategoryOrder) {
        $groups[$category] = New-Object System.Collections.Generic.List[string]
    }

    foreach ($name in ($allNames.Keys | Sort-Object)) {
        $info = $script:BlueprintEnrichment[$name]
        $category = if ($info -and $info.category) { [string]$info.category } else { 'Не распознано' }
        if (-not $groups.ContainsKey($category)) {
            $groups[$category] = New-Object System.Collections.Generic.List[string]
        }
        $groups[$category].Add($name)
    }

    $summaryParts = New-Object System.Collections.Generic.List[string]
    foreach ($category in $CategoryOrder) {
        if ($groups.ContainsKey($category) -and $groups[$category].Count -gt 0) {
            $summaryParts.Add("${category}: $($groups[$category].Count)")
        }
    }
    if ($summaryParts.Count -gt 1) {
        $blockLines.Add('Всего: ' + $allNames.Keys.Count + ' | ' + ($summaryParts -join ' | '))
    }

    foreach ($category in $CategoryOrder) {
        if (-not $groups.ContainsKey($category) -or $groups[$category].Count -eq 0) {
            continue
        }

        $blockLines.Add('')
        $blockLines.Add("${category}:")
        foreach ($name in ($groups[$category] | Sort-Object)) {
            $blockLines.Add((Format-BlueprintLine -Name $name))
        }
    }

    return ($blockLines -join '\n')
}

function Get-EnrichmentStats {
    param([hashtable]$Map)

    $wiki = 0
    $override = 0
    $pattern = 0
    $unknown = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $Map.GetEnumerator()) {
        $info = $entry.Value
        if ($info.source -eq 'wiki') { $wiki++ }
        elseif ($info.source -eq 'override') { $override++ }
        elseif ($info.source -eq 'pattern') { $pattern++ }

        if (-not $info.found -or $info.category -eq 'Не распознано') {
            $unknown.Add([string]$entry.Key)
        }
    }

    return [pscustomobject]@{
        wikiMatched = $wiki
        overrideMatched = $override
        patternMatched = $pattern
        unknownBlueprints = @($unknown | Sort-Object)
    }
}

function Restore-LatestBackup {
    param([Parameter(Mandatory = $true)][string]$TargetGlobalIni)

    $backupDir = Join-Path $ScriptDir 'backups'
    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
        throw "Backup directory not found: $backupDir"
    }

    $latest = Get-ChildItem -LiteralPath $backupDir -Filter 'global.ini.*.scmdb-recipes.bak' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No SCMDB recipe backups found in: $backupDir"
    }

    if (-not $NoBackup) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $preRestoreBackup = Join-Path $backupDir "global.ini.$stamp.before-restore.bak"
        Copy-Item -LiteralPath $TargetGlobalIni -Destination $preRestoreBackup -Force
        Write-Host "Current file backup created: $preRestoreBackup"
    }

    Copy-Item -LiteralPath $latest.FullName -Destination $TargetGlobalIni -Force
    Write-Host "Restored latest backup: $($latest.FullName)"
}

$globalPath = Resolve-GlobalIniPath -InputLivePath $LivePath -InputGlobalIniPath $GlobalIniPath

if ($RestoreLatestBackup) {
    Restore-LatestBackup -TargetGlobalIni $globalPath
    exit 0
}

$encodingInfo = Get-TextEncodingInfo -Path $globalPath
$originalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $globalPath).Hash
$originalSize = (Get-Item -LiteralPath $globalPath).Length

Write-Host "global.ini: $globalPath"
Write-Host "Encoding: $($encodingInfo.Name)"

$scmdb = Get-ScmdbData
$rewardInfo = New-RewardMap -Scmdb $scmdb
$descriptionRewardMap = $rewardInfo.DescriptionMap
$titleRewardMap = $rewardInfo.TitleMap
$uniqueBlueprintNames = Get-UniqueBlueprintNames -DescriptionMap $descriptionRewardMap
$script:BlueprintEnrichment = New-EnrichmentMap -Names $uniqueBlueprintNames
$enrichmentStats = Get-EnrichmentStats -Map $script:BlueprintEnrichment

$lines = [System.IO.File]::ReadAllLines($globalPath, $encodingInfo.Encoding)
$changedLines = 0
$changedDescriptionLines = 0
$changedTitleLines = 0
$cleanedExistingBlocks = 0
$missingDescriptionKeys = New-Object System.Collections.Generic.List[string]
$missingTitleKeys = New-Object System.Collections.Generic.List[string]
$modifiedDescriptionKeys = New-Object System.Collections.Generic.List[string]
$modifiedTitleKeys = New-Object System.Collections.Generic.List[string]
$conflictKeys = New-Object System.Collections.Generic.List[string]
$seenDescriptionKeys = @{}
$seenTitleKeys = @{}

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $separator = $line.IndexOf('=')
    if ($separator -le 0) {
        continue
    }

    $rawKey = $line.Substring(0, $separator)
    $key = Get-NormalizedIniKey -LineKey $rawKey
    $currentValue = $line.Substring($separator + 1)

    if ($descriptionRewardMap.ContainsKey($key)) {
        $seenDescriptionKeys[$key] = $true
        $cleanValue = Remove-BlueprintBlock -Value $currentValue
        if ($cleanValue -ne $currentValue) {
            $cleanedExistingBlocks++
        }

        $group = $descriptionRewardMap[$key]
        if ($group.RewardSignatures.Count -gt 1) {
            $conflictKeys.Add($key)
        }

        $block = Format-RewardBlock -Group $group
        $newValue = $cleanValue + '\n\n' + $block

        if ($newValue -ne $currentValue) {
            $lines[$i] = $rawKey + '=' + $newValue
            $changedLines++
            $changedDescriptionLines++
            $modifiedDescriptionKeys.Add($key)
            $currentValue = $newValue
        }
    }

    if ($titleRewardMap.ContainsKey($key)) {
        $seenTitleKeys[$key] = $true
        $cleanTitle = Remove-TitleMarker -Value $currentValue
        $newTitle = $cleanTitle
        if (-not [string]::IsNullOrWhiteSpace($TitleMarker)) {
            $newTitle = "$TitleMarker $cleanTitle"
        }

        if ($newTitle -ne $currentValue) {
            $lines[$i] = $rawKey + '=' + $newTitle
            $changedLines++
            $changedTitleLines++
            $modifiedTitleKeys.Add($key)
        }
    }
}

foreach ($key in $descriptionRewardMap.Keys) {
    if (-not $seenDescriptionKeys.ContainsKey($key)) {
        $missingDescriptionKeys.Add($key)
    }
}

foreach ($key in $titleRewardMap.Keys) {
    if (-not $seenTitleKeys.ContainsKey($key)) {
        $missingTitleKeys.Add($key)
    }
}

if (-not $ReportPath) {
    $reportDir = Join-Path $ScriptDir 'reports'
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ReportPath = Join-Path $reportDir "scmdb-recipe-patch-$stamp.json"
}

$report = [pscustomobject]@{
    dryRun = [bool]$DryRun
    scmdbVersion = $scmdb.Version
    globalIniPath = $globalPath
    encoding = $encodingInfo.Name
    originalSize = $originalSize
    originalSha256 = $originalHash
    totalLines = $lines.Count
    scmdbContracts = $rewardInfo.TotalContracts
    scmdbRewardContracts = $rewardInfo.RewardContracts
    uniqueBlueprintNames = $uniqueBlueprintNames.Count
    titleMarker = $TitleMarker
    scmdbRewardDescriptionKeys = $descriptionRewardMap.Keys.Count
    scmdbRewardTitleKeys = $titleRewardMap.Keys.Count
    matchedDescriptionKeys = $seenDescriptionKeys.Keys.Count
    matchedTitleKeys = $seenTitleKeys.Keys.Count
    changedLines = $changedLines
    changedDescriptionLines = $changedDescriptionLines
    changedTitleLines = $changedTitleLines
    cleanedExistingBlocks = $cleanedExistingBlocks
    conflictingSharedDescriptionKeys = $conflictKeys.Count
    missingDescriptionKeys = $missingDescriptionKeys.Count
    missingTitleKeys = $missingTitleKeys.Count
    wikiMatched = $enrichmentStats.wikiMatched
    overrideMatched = $enrichmentStats.overrideMatched
    patternMatched = $enrichmentStats.patternMatched
    unknownBlueprints = $enrichmentStats.unknownBlueprints
    modifiedDescriptionKeysSample = @($modifiedDescriptionKeys | Select-Object -First 20)
    modifiedTitleKeysSample = @($modifiedTitleKeys | Select-Object -First 20)
    conflictKeysSample = @($conflictKeys | Select-Object -First 20)
    missingDescriptionKeysSample = @($missingDescriptionKeys | Select-Object -First 20)
    missingTitleKeysSample = @($missingTitleKeys | Select-Object -First 20)
}

$reportJson = $report | ConvertTo-Json -Depth 8
$reportEncoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($ReportPath, $reportJson, $reportEncoding)

if ($changedLines -eq 0) {
    Write-Host 'No modifications were necessary.'
    Write-Host "SCMDB version: $($scmdb.Version)"
    Write-Host "Wiki matched: $($enrichmentStats.wikiMatched)"
    Write-Host "Override matched: $($enrichmentStats.overrideMatched)"
    Write-Host "Pattern matched: $($enrichmentStats.patternMatched)"
    Write-Host "Unknown blueprints: $($enrichmentStats.unknownBlueprints.Count)"
    Write-Host "Report: $ReportPath"
    exit 0
}

if ($DryRun) {
    Write-Host 'Dry run complete. No game files were modified.'
    Write-Host "Would modify lines: $changedLines"
    Write-Host "SCMDB version: $($scmdb.Version)"
    Write-Host "Wiki matched: $($enrichmentStats.wikiMatched)"
    Write-Host "Override matched: $($enrichmentStats.overrideMatched)"
    Write-Host "Pattern matched: $($enrichmentStats.patternMatched)"
    Write-Host "Unknown blueprints: $($enrichmentStats.unknownBlueprints.Count)"
    Write-Host "Report: $ReportPath"
    exit 0
}

if (-not $NoBackup) {
    $backupDir = Join-Path $ScriptDir 'backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupName = 'global.ini.' + $stamp + '.scmdb-recipes.bak'
    $backupPath = Join-Path $backupDir $backupName
    Copy-Item -LiteralPath $globalPath -Destination $backupPath -Force
    Write-Host "Backup created: $backupPath"
}

[System.IO.File]::WriteAllLines($globalPath, $lines, $encodingInfo.Encoding)
$newHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $globalPath).Hash

Write-Host "Patched lines: $changedLines"
Write-Host "SCMDB version: $($scmdb.Version)"
Write-Host "Wiki matched: $($enrichmentStats.wikiMatched)"
Write-Host "Override matched: $($enrichmentStats.overrideMatched)"
Write-Host "Pattern matched: $($enrichmentStats.patternMatched)"
Write-Host "Unknown blueprints: $($enrichmentStats.unknownBlueprints.Count)"
Write-Host "New SHA256: $newHash"
Write-Host "Report: $ReportPath"
