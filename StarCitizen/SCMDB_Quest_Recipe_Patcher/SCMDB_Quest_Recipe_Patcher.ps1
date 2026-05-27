param(
    [Parameter(Position = 0)]
    [string]$LivePath,

    [string]$GlobalIniPath,

    [switch]$DryRun,

    [switch]$NoBackup,

    [switch]$RestoreLatestBackup,

    [switch]$NoWikiEnrichment,

    [switch]$NoCraftIntel,

    [switch]$NoCache,

    [switch]$KeepExistingBlueprintBlocks,

    [string]$TitleMarker = '[Ч]',

    [string]$ReportPath,

    [string]$OverridesPath,

    [string]$WikiCachePath,

    [string]$BlueprintCachePath
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScmdbBaseUrl = 'https://scmdb.net/data'
$WikiApiBaseUrl = 'https://api.star-citizen.wiki/api'
$LocalizationRelativePath = 'data\Localization\korean_(south_korea)\global.ini'

$CategoryOrder = @(
    'Корабельные компоненты',
    'Корабельные орудия',
    'Броня/одежда',
    'Оружие',
    'Снаряжение/расходники',
    'Материалы/особое',
    'Не распознано'
)

$ArmorSubcategoryOrder = @(
    'Тяжёлая броня',
    'Средняя броня',
    'Лёгкая броня',
    'Андерсьюты/костюмы',
    'Прочее'
)

$FpsWeaponSubcategoryOrder = @(
    'Винтовки',
    'Снайперские винтовки',
    'Пистолеты',
    'Пистолеты-пулемёты',
    'Дробовики',
    'Пулемёты',
    'Арбалеты',
    'Прочее'
)

$ShipComponentSubcategoryOrder = @(
    'Щиты',
    'Квантовые двигатели',
    'Силовые установки',
    'Охладители',
    'Радары',
    'Топливные форсунки',
    'Прочее'
)

$ShipWeaponSubcategoryOrder = @(
    'Энергетика',
    'Баллистика',
    'Гибрид',
    'Добывающие лазеры',
    'Прочее'
)

$SubcategoryEmphasisTag = 'EM4'
$ShipMiningMethodTag = 'EM4'
$AcePilotTitleMarker = '<EM4>[А]</EM4>'
$ScripTitleMarker = '[С]'

if (-not $OverridesPath) {
    $OverridesPath = Join-Path $ScriptDir 'data\blueprint-overrides.ru.json'
}

if (-not $WikiCachePath) {
    $WikiCachePath = Join-Path $ScriptDir 'cache\wiki-items-cache.json'
}

if (-not $BlueprintCachePath) {
    $BlueprintCachePath = Join-Path $ScriptDir 'cache\wiki-blueprints-cache.json'
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

function Remove-CraftIntelBlock {
    param([Parameter(Mandatory = $true)][string]$Value)

    return [regex]::Replace(
        $Value,
        '\\n\\n<EM\d>Крафт-подсказка \(SCMDB\)</EM\d>.*$',
        '',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
}

function Repair-EmphasisTags {
    param([Parameter(Mandatory = $true)][string]$Value)

    $repaired = $Value

    for ($tagNumber = 1; $tagNumber -le 5; $tagNumber++) {
        $tag = "EM$tagNumber"
        $repaired = [regex]::Replace(
            $repaired,
            "<$tag>(~mission\([^)]+\))<$tag>",
            "<$tag>`$1</$tag>"
        )
    }

    $repaired = [regex]::Replace(
        $repaired,
        '</EM([1-5])(?=[\s\.,;:!?\)]|\\n|$)',
        '</EM$1>'
    )

    return $repaired
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
        '^\s*<EM\d>\[А\]</EM\d>\s*',
        '^\s*<EM\d>\[С\]</EM\d>\s*',
        '^\s*\[BP\]\s*',
        '^\s*\[Ч\]\s*',
        '^\s*\[ЧЕРТ\]\s*',
        '^\s*\[ЧЕРТЕЖ\]\s*',
        '^\s*\[ЧЕРТЁЖ\]\s*',
        '^\s*\[Чертежи\]\*?\s*',
        '^\s*\[А\]\s*',
        '^\s*\[С\]\s*'
    )

    do {
        $before = $clean
        foreach ($pattern in $patterns) {
            $clean = [regex]::Replace($clean, $pattern, '')
        }
    }
    while ($clean -ne $before)

    return $clean
}

function Format-TitleMarkers {
    param($TitleInfo)

    $markers = New-Object System.Collections.Generic.List[string]

    if ($TitleInfo.HasBlueprint -and -not [string]::IsNullOrWhiteSpace($TitleMarker)) {
        $markers.Add($TitleMarker)
    }

    if ($TitleInfo.HasAcePilot) {
        $markers.Add($AcePilotTitleMarker)
    }

    if ($TitleInfo.HasScrip) {
        $markers.Add($ScripTitleMarker)
    }

    return (($markers | ForEach-Object { [string]$_ }) -join ' ')
}

function Get-ScmdbData {
    Write-Host 'Downloading SCMDB version index...'
    $versions = @(ConvertTo-Array (Invoke-RestMethod -Uri "$ScmdbBaseUrl/game-versions.json" -UseBasicParsing))
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

function Get-ContractLocKey {
    param(
        $Contract,
        [string]$LocKeyProperty,
        [string]$FallbackKeyProperty
    )

    $locKey = $Contract.$LocKeyProperty
    if (-not $locKey -and $Contract.$FallbackKeyProperty) {
        $locKey = ([string]$Contract.$FallbackKeyProperty -replace '^@', '')
    }

    if ([string]::IsNullOrWhiteSpace([string]$locKey)) {
        return $null
    }

    return [string]$locKey
}

function Test-AcePilotContract {
    param($Contract)

    $json = $Contract | ConvertTo-Json -Depth 80 -Compress
    return ($json -match '"role"\s*:\s*"AcePilot"' -or $json -match 'AcePilot_')
}

function Test-ScripRewardName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return (@('MG Scrip', 'Council Scrip') -contains $Name.Trim())
}

function Test-ScripRewardContract {
    param($Contract)

    foreach ($reward in (ConvertTo-Array $Contract.itemRewards)) {
        if (Test-ScripRewardName -Name ([string]$reward.name)) {
            return $true
        }
    }

    return $false
}

function New-RewardMap {
    param([Parameter(Mandatory = $true)]$Scmdb)

    $data = $Scmdb.Data
    $contracts = @()
    $contracts += @(ConvertTo-Array $data.contracts)
    $contracts += @(ConvertTo-Array $data.legacyContracts)

    $descriptionMap = @{}
    $titleMap = @{}
    $rewardContractCount = 0

    foreach ($contract in $contracts) {
        $titleKey = Get-ContractLocKey -Contract $contract -LocKeyProperty 'titleLocKey' -FallbackKeyProperty 'titleKey'
        $rewards = @(ConvertTo-Array $contract.blueprintRewards)
        $hasBlueprintRewards = $rewards.Count -gt 0
        $hasAcePilot = Test-AcePilotContract -Contract $contract
        $hasScripReward = Test-ScripRewardContract -Contract $contract

        if (
            -not [string]::IsNullOrWhiteSpace($titleKey) -and
            ($hasBlueprintRewards -or $hasAcePilot -or $hasScripReward)
        ) {
            if (-not $titleMap.ContainsKey($titleKey)) {
                $titleMap[$titleKey] = @{
                    Key = $titleKey
                    HasBlueprint = $false
                    HasAcePilot = $false
                    HasScrip = $false
                    Contracts = @{}
                }
            }

            $titleEntry = $titleMap[$titleKey]
            $titleEntry.HasBlueprint = [bool]($titleEntry.HasBlueprint -or $hasBlueprintRewards)
            $titleEntry.HasAcePilot = [bool]($titleEntry.HasAcePilot -or $hasAcePilot)
            $titleEntry.HasScrip = [bool]($titleEntry.HasScrip -or $hasScripReward)
            $debugNameForTitle = if ($contract.debugName) { [string]$contract.debugName } else { '<unknown>' }
            $titleEntry.Contracts[$debugNameForTitle] = $true
        }

        if ($rewards.Count -eq 0) {
            continue
        }

        $rewardContractCount++

        $descKey = Get-ContractLocKey -Contract $contract -LocKeyProperty 'descriptionLocKey' -FallbackKeyProperty 'descriptionKey'
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
        'Neutron Cannon' = 'нейтронная пушка'
        'Tachyon Cannon' = 'тахионная пушка'
        'Mass Driver Cannon' = 'масс-драйвер'
        'Laser Repeater' = 'лазерный повторитель'
        'Ballistic Repeater' = 'баллистический повторитель'
        'Distortion Repeater' = 'дисторсионный повторитель'
        'Ballistic Gatling' = 'баллистический гатлинг'
        'Distortion Cannon' = 'дисторсионная пушка'
        'Scattergun' = 'разбросное орудие'
        'Mining Laser' = 'добывающий лазер'
        'Scraper Module' = 'скребковый модуль'
        'Fuel Nozzle' = 'топливная форсунка'
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

    if ($itemType -match 'Shield|Quantum Drive|Power Plant|Cooler|Radar|Fuel Nozzle' -or $type -match 'Shield|QuantumDrive|PowerPlant|Cooler|Radar|FuelNozzle') {
        return 'Корабельные компоненты'
    }

    if ($itemType -match 'Cannon|Repeater|Gatling|Scattergun|Missile|Bomb|Mining Laser|Mass Driver' -or $type -match 'WeaponGun|Missile|Bomb|WeaponMining') {
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
        blueprintUuid = if ($Item.blueprint -and $Item.blueprint.uuid) { [string]$Item.blueprint.uuid } else { $null }
        blueprintLink = if ($Item.blueprint -and $Item.blueprint.link) { [string]$Item.blueprint.link } else { $null }
        isCraftable = [bool]$Item.is_craftable
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
            blueprintUuid = $null
            blueprintLink = $null
            isCraftable = $false
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
        blueprintUuid = $null
        blueprintLink = $null
        isCraftable = $false
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
            blueprintUuid = $Base.blueprintUuid
            blueprintLink = $Base.blueprintLink
            isCraftable = $Base.isCraftable
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
            blueprintUuid = $null
            blueprintLink = $null
            isCraftable = $false
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

            if (-not $cached.PSObject.Properties['blueprintUuid']) {
                $namesForWiki.Add($name)
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

function Format-Quantity {
    param($Ingredient)

    if ($null -ne $Ingredient.quantity_scu) {
        $value = [decimal]$Ingredient.quantity_scu
        return ($value.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture) + ' SCU')
    }

    if ($null -ne $Ingredient.quantity) {
        return ([string]$Ingredient.quantity + ' шт.')
    }

    return $null
}

function Format-SubcategoryLabel {
    param([Parameter(Mandatory = $true)][string]$Label)

    return "<$SubcategoryEmphasisTag>${Label}</$SubcategoryEmphasisTag>"
}

function Format-ShipMiningMethodLabel {
    return "<$ShipMiningMethodTag>[К]</$ShipMiningMethodTag>"
}

function ConvertTo-MinutesLabel {
    param([int]$Seconds)

    if ($Seconds -le 0) {
        return $null
    }

    $minutes = [Math]::Round($Seconds / 60, 1)
    return ($minutes.ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture) + ' мин')
}

function ConvertTo-IngredientSummary {
    param($Ingredient)

    return [pscustomobject]@{
        name = [string]$Ingredient.name
        kind = [string]$Ingredient.kind
        quantity = Format-Quantity -Ingredient $Ingredient
    }
}

function Get-WikiBlueprintByUuid {
    param(
        [Parameter(Mandatory = $true)][string]$Uuid,
        [Parameter(Mandatory = $true)][hashtable]$Cache
    )

    if (-not $NoCache -and $Cache.ContainsKey($Uuid)) {
        return $Cache[$Uuid]
    }

    if ($NoWikiEnrichment) {
        return [pscustomobject]@{
            found = $false
            source = 'disabled'
        }
    }

    try {
        $response = Invoke-RestMethod -Uri "$WikiApiBaseUrl/blueprints/$Uuid" -UseBasicParsing -TimeoutSec 30
        $blueprint = $response.data
        $ingredients = New-Object System.Collections.Generic.List[object]
        foreach ($ingredient in (ConvertTo-Array $blueprint.ingredients)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$ingredient.name)) {
                $ingredients.Add((ConvertTo-IngredientSummary -Ingredient $ingredient))
            }
        }

        $summary = [pscustomobject]@{
            found = $true
            source = 'wiki'
            uuid = [string]$blueprint.uuid
            outputName = [string]$blueprint.output_name
            craftTime = ConvertTo-MinutesLabel -Seconds ([int]$blueprint.craft_time_seconds)
            ingredientCount = [int]$blueprint.ingredient_count
            ingredients = $ingredients.ToArray()
        }

        if (-not $NoCache) {
            $Cache[$Uuid] = $summary
        }

        return $summary
    }
    catch {
        Write-Warning "Wiki blueprint lookup failed for ${Uuid}: $($_.Exception.Message)"
        $miss = [pscustomobject]@{
            found = $false
            source = 'wiki-miss'
        }
        if (-not $NoCache) {
            $Cache[$Uuid] = $miss
        }
        return $miss
    }
}

function New-BlueprintCraftMap {
    param(
        [string[]]$Names,
        [hashtable]$EnrichmentMap
    )

    $result = @{}
    if ($NoCraftIntel -or $NoWikiEnrichment) {
        return $result
    }

    $cache = if ($NoCache) { @{} } else { Read-JsonHashtable -Path $BlueprintCachePath }
    $craftableNames = @(
        $Names |
            Where-Object {
                $EnrichmentMap.ContainsKey($_) -and
                -not [string]::IsNullOrWhiteSpace([string]$EnrichmentMap[$_].blueprintUuid)
            } |
            Sort-Object -Unique
    )

    if ($craftableNames.Count -gt 0) {
        Write-Host "Loading Star Citizen Wiki recipe data for $($craftableNames.Count) blueprint recipes..."
    }

    $craftableIndex = 0
    foreach ($name in $craftableNames) {
        $craftableIndex++
        if ($craftableNames.Count -ge 20 -and ($craftableIndex -eq 1 -or $craftableIndex % 25 -eq 0 -or $craftableIndex -eq $craftableNames.Count)) {
            Write-Host "Wiki recipe progress: $craftableIndex/$($craftableNames.Count)"
        }

        $info = $EnrichmentMap[$name]
        $blueprint = $null
        $blueprintUuids = @(
            ([string]$info.blueprintUuid -split '\s+') |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        foreach ($blueprintUuid in $blueprintUuids) {
            $candidate = Get-WikiBlueprintByUuid -Uuid $blueprintUuid -Cache $cache
            if ($candidate.found -and @($candidate.ingredients).Count -gt 0) {
                $blueprint = $candidate
                break
            }
        }

        if ($blueprint.found -and @($blueprint.ingredients).Count -gt 0) {
            $result[$name] = [pscustomobject]@{
                name = $name
                category = if ($info.category) { [string]$info.category } else { 'Не распознано' }
                type = $info.type
                slot = $info.slot
                size = $info.size
                grade = $info.grade
                class = $info.class
                craftTime = $blueprint.craftTime
                ingredients = @($blueprint.ingredients)
            }
        }
    }

    if (-not $NoCache) {
        Write-JsonHashtable -Path $BlueprintCachePath -Value $cache
    }

    return $result
}

function Normalize-ResourceName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $clean = (($Name -replace '\\n', ' ') -replace '\s*\([^)]*\)\s*$', '').Trim()
    $aliases = @{
        'Alumium' = 'Aluminum'
        'Aluminium' = 'Aluminum'
        'Hephasestanite' = 'Hephaestanite'
        'Hephestanite' = 'Hephaestanite'
        'Beryls' = 'Beryl'
        'Beradom' = 'Beradon'
        'Borэйс' = 'Borase'
        'Борэйс' = 'Borase'
    }

    if ($aliases.ContainsKey($clean)) {
        return $aliases[$clean]
    }

    return $clean
}

function Get-MethodLabel {
    param([string]$Method)

    if ($Method -eq 'К') { return 'корабль' }
    if ($Method -eq 'Т') { return 'наземная техника' }
    if ($Method -eq 'М') { return 'мультитул' }
    return 'неизвестно'
}

function Get-ResourceMethodsFromDescription {
    param([Parameter(Mandatory = $true)][string]$Value)

    $result = @{}
    $method = $null
    foreach ($part in ($Value -split '\\n')) {
        $line = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match 'Потенциально добываемые ресурсы\s*\(корабль\)') {
            $method = 'К'
            continue
        }
        if ($line -match 'Потенциально добываемые ресурсы\s*\(наземная техника\)') {
            $method = 'Т'
            continue
        }
        if ($line -match 'Потенциально добываемые ресурсы\s*\(ручная добыча\)') {
            $method = 'М'
            continue
        }
        if ($line -match '^Потенциально ') {
            $method = $null
            continue
        }

        if (-not $method) {
            continue
        }

        $resource = Normalize-ResourceName -Name $line
        if ([string]::IsNullOrWhiteSpace($resource)) {
            continue
        }

        if (-not $result.ContainsKey($resource)) {
            $result[$resource] = @{}
        }
        $result[$resource][$method] = $true
    }

    return $result
}

function New-LineValueMap {
    param([string[]]$Lines)

    $map = @{}
    foreach ($line in $Lines) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }

        $key = Get-NormalizedIniKey -LineKey ($line.Substring(0, $separator))
        if (-not $map.ContainsKey($key)) {
            $map[$key] = $line.Substring($separator + 1)
        }
    }

    return $map
}

function Get-DescriptionBaseKey {
    param([string]$Key)

    return ($Key -replace '(?i)_desc$', '' -replace '(?i)_description$', '')
}

function Get-LocationDisplayName {
    param(
        [string]$DescriptionKey,
        [hashtable]$LineValues
    )

    $baseKey = Get-DescriptionBaseKey -Key $DescriptionKey
    if ($LineValues.ContainsKey($baseKey)) {
        return [string]$LineValues[$baseKey]
    }

    return $baseKey
}

function New-ResourceLocationMap {
    param(
        [string[]]$Lines,
        [hashtable]$LineValues
    )

    $map = @{}
    foreach ($line in $Lines) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }

        $rawKey = $line.Substring(0, $separator)
        $key = Get-NormalizedIniKey -LineKey $rawKey
        if ($key -notmatch '(?i)_desc$') {
            continue
        }

        $value = $line.Substring($separator + 1)
        if ($value -notmatch 'Потенциально добываемые ресурсы') {
            continue
        }

        $location = (Format-DisplayName -Name (Get-LocationDisplayName -DescriptionKey $key -LineValues $LineValues)).Trim()
        $resources = Get-ResourceMethodsFromDescription -Value $value
        foreach ($resource in $resources.Keys) {
            if (-not $map.ContainsKey($resource)) {
                $map[$resource] = @{
                    'К' = @{}
                    'Т' = @{}
                    'М' = @{}
                }
            }

            foreach ($method in $resources[$resource].Keys) {
                $map[$resource][$method][$location] = $true
            }
        }
    }

    return $map
}

function New-ResourceRecipeMap {
    param([hashtable]$BlueprintCraftMap)

    $map = @{}
    foreach ($entry in $BlueprintCraftMap.GetEnumerator()) {
        $recipeName = [string]$entry.Key
        foreach ($ingredient in @($entry.Value.ingredients)) {
            $resource = Normalize-ResourceName -Name ([string]$ingredient.name)
            if ([string]::IsNullOrWhiteSpace($resource)) {
                continue
            }

            if (-not $map.ContainsKey($resource)) {
                $map[$resource] = @{}
            }
            $map[$resource][$recipeName] = $true
        }
    }

    return $map
}

function Format-LocationHint {
    param(
        [string]$Resource,
        [hashtable]$ResourceLocationMap
    )

    $resource = Normalize-ResourceName -Name $Resource
    if (-not $ResourceLocationMap.ContainsKey($resource)) {
        return '[?] места см. в справочнике добычи'
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($method in @('К', 'Т', 'М')) {
        $locations = @($ResourceLocationMap[$resource][$method].Keys | Sort-Object)
        if ($locations.Count -eq 0) {
            continue
        }

        $shown = @($locations | Select-Object -First 5)
        $suffix = if ($locations.Count -gt 5) { ' +' + ($locations.Count - 5) } else { '' }
        $parts.Add("[$method] " + ($shown -join ', ') + $suffix)
    }

    if ($parts.Count -eq 0) {
        return '[?] места см. в справочнике добычи'
    }

    return ($parts -join '; ')
}

function Format-RecipeHeader {
    param(
        [string]$Name,
        $CraftInfo
    )

    $details = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$CraftInfo.type)) {
        $details.Add((ConvertTo-RussianItemType -Value ([string]$CraftInfo.type)))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$CraftInfo.slot)) {
        $details.Add([string]$CraftInfo.slot)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$CraftInfo.size)) {
        $details.Add("S$($CraftInfo.size)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$CraftInfo.grade)) {
        $details.Add("Grade $($CraftInfo.grade)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$CraftInfo.class)) {
        $details.Add([string]$CraftInfo.class)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$CraftInfo.craftTime)) {
        $details.Add([string]$CraftInfo.craftTime)
    }

    if ($details.Count -eq 0) {
        return (Format-DisplayName -Name $Name)
    }

    return (Format-DisplayName -Name $Name) + ' — ' + ($details -join ', ')
}

function Format-CraftGuide {
    param(
        [hashtable]$BlueprintCraftMap,
        [hashtable]$ResourceLocationMap
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('КРАФТОВЫЙ СПРАВОЧНИК SCMDB')
    $lines.Add('')
    $lines.Add('Как читать: [К] корабль | [Т] наземная техника | [М] мультитул.')
    $lines.Add('Количество ресурсов указано по данным Star Citizen Wiki API. Места добычи берутся из описаний планет и лун.')
    $lines.Add('')

    foreach ($category in $CategoryOrder) {
        $recipes = @(
            $BlueprintCraftMap.GetEnumerator() |
                Where-Object { $_.Value.category -eq $category } |
                Sort-Object Key
        )
        if ($recipes.Count -eq 0) {
            continue
        }

        $lines.Add("<EM4>$category</EM4>")
        foreach ($recipe in $recipes) {
            $name = [string]$recipe.Key
            $craftInfo = $recipe.Value
            $lines.Add((Format-RecipeHeader -Name $name -CraftInfo $craftInfo))
            foreach ($ingredient in @($craftInfo.ingredients)) {
                $quantity = if ($ingredient.quantity) { ' ' + [string]$ingredient.quantity } else { '' }
                $hint = Format-LocationHint -Resource ([string]$ingredient.name) -ResourceLocationMap $ResourceLocationMap
                $lines.Add("- $($ingredient.name)$quantity — $hint")
            }
            $lines.Add('')
        }
    }

    return ($lines -join '\n').TrimEnd()
}

function ConvertFrom-RomanNumeral {
    param([string]$Value)

    $roman = ([string]$Value).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($roman) -or $roman -notmatch '^[IVXLCDM]+$') {
        return $null
    }

    $map = @{
        'I' = 1
        'V' = 5
        'X' = 10
        'L' = 50
        'C' = 100
        'D' = 500
        'M' = 1000
    }
    $total = 0
    $previous = 0
    for ($i = $roman.Length - 1; $i -ge 0; $i--) {
        $current = $map[[string]$roman[$i]]
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

function Format-NumberSpan {
    param([object[]]$Values)

    $numbers = @($Values | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    if ($numbers.Count -eq 0) {
        return $null
    }

    $isSequential = $numbers.Count -gt 2
    if ($isSequential) {
        for ($i = 1; $i -lt $numbers.Count; $i++) {
            if ($numbers[$i] -ne ($numbers[$i - 1] + 1)) {
                $isSequential = $false
                break
            }
        }
    }

    if ($isSequential) {
        return "$($numbers[0])-$($numbers[$numbers.Count - 1])"
    }

    return ($numbers -join '/')
}

function Format-RomanSpan {
    param([string[]]$Values)

    $items = @(
        $Values |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object {
                [pscustomobject]@{
                    label = $_.ToUpperInvariant()
                    value = ConvertFrom-RomanNumeral -Value $_
                }
            } |
            Where-Object { $null -ne $_.value } |
            Sort-Object value -Unique
    )

    if ($items.Count -eq 0) {
        return $null
    }

    $isSequential = $items.Count -gt 2
    if ($isSequential) {
        for ($i = 1; $i -lt $items.Count; $i++) {
            if ($items[$i].value -ne ($items[$i - 1].value + 1)) {
                $isSequential = $false
                break
            }
        }
    }

    if ($isSequential) {
        return "$($items[0].label)-$($items[$items.Count - 1].label)"
    }

    return (($items | ForEach-Object { $_.label }) -join '/')
}

function Get-PlanetRecipeFamily {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Category
    )

    $displayName = (Format-DisplayName -Name $Name).Trim()

    if ($Category -eq 'Броня/одежда') {
        $base = $displayName
        $base = $base -replace '\s*\([^)]*\)', ''
        $base = $base -replace '\b(Arms|Core|Helmet|Legs|Backpack)\b.*$', ''
        $base = $base -replace '\b(Exploration Suit|Flight Suit|Undersuit|Suit)\b.*$', ''
        $base = $base.Trim()
        if (-not [string]::IsNullOrWhiteSpace($base) -and $base -ne $displayName) {
            return [pscustomobject]@{
                key = "armor:$base"
                label = $base
                family = 'armor'
                token = $null
                original = $displayName
            }
        }
    }

    if ($displayName -match '^Attrition-(\d+)\s+Repeater$') {
        return [pscustomobject]@{
            key = 'weapon:Attrition Repeater'
            label = 'Attrition Repeaters'
            family = 'numbered'
            token = [int]$Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^CF-(\d+)\s+.+\s+Repeater$') {
        return [pscustomobject]@{
            key = 'weapon:CF Repeater'
            label = 'CF Repeaters'
            family = 'number-list'
            token = [int]$Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^Deadbolt\s+([IVXLCDM]+)\s+Cannon$') {
        return [pscustomobject]@{
            key = 'weapon:Deadbolt Cannon'
            label = 'Deadbolt Cannons'
            family = 'roman'
            token = $Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^Lightstrike\s+([IVXLCDM]+)\s+Cannon$') {
        return [pscustomobject]@{
            key = 'weapon:Lightstrike Cannon'
            label = 'Lightstrike Cannons'
            family = 'roman'
            token = $Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^Omnisky\s+([IVXLCDM]+)\s+') {
        return [pscustomobject]@{
            key = 'weapon:Omnisky'
            label = 'Omnisky'
            family = 'roman'
            token = $Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^Sledge\s+([IVXLCDM]+)\s+Mass Driver Cannon$') {
        return [pscustomobject]@{
            key = 'weapon:Sledge Mass Driver Cannon'
            label = 'Sledge Mass Driver Cannons'
            family = 'roman'
            token = $Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^Singe\s+Cannon\s+\(S(\d+)\)$') {
        return [pscustomobject]@{
            key = 'weapon:Singe Cannon'
            label = 'Singe Cannons'
            family = 'size'
            token = [int]$Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^Suckerpunch(?:-(L|XL))?\s+Cannon$') {
        $token = 1
        if ($Matches[1] -eq 'L') {
            $token = 2
        }
        elseif ($Matches[1] -eq 'XL') {
            $token = 3
        }
        return [pscustomobject]@{
            key = 'weapon:Suckerpunch Cannon'
            label = 'Suckerpunch Cannons'
            family = 'size'
            token = $token
            original = $displayName
        }
    }

    if ($displayName -match '^SW16BR(\d+)\s+[\"“”][^\"“”]+[\"“”]\s+Repeater$') {
        return [pscustomobject]@{
            key = 'weapon:SW16BR Repeater'
            label = 'SW16BR Repeaters'
            family = 'numbered'
            token = [int]$Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^Arbor\s+MH(2|V)\s+Mining Laser$') {
        return [pscustomobject]@{
            key = 'weapon:Arbor Mining Laser'
            label = 'Arbor MH2/MHV Mining Lasers'
            family = 'variant'
            token = $null
            original = $displayName
        }
    }

    if ($displayName -match '^Lancet\s+MH([12])\s+Mining Laser$') {
        return [pscustomobject]@{
            key = 'weapon:Lancet Mining Laser'
            label = 'Lancet MH1/MH2 Mining Lasers'
            family = 'variant'
            token = $null
            original = $displayName
        }
    }

    if ($displayName -match '^Tarantula\s+GT-870\s+Mark\s+(\d+)\s+Cannon$') {
        return [pscustomobject]@{
            key = 'weapon:Tarantula GT-870 Cannon'
            label = 'Tarantula GT-870 Cannons Mk'
            family = 'numbered'
            token = [int]$Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^(\d+)-Series\s+(Longsword|Broadsword|Greatsword)\s+Cannon$') {
        return [pscustomobject]@{
            key = 'weapon:Sword Series Cannon'
            label = 'Sword-series Cannons'
            family = 'number-list'
            token = [int]$Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^M(\d+)A\s+Cannon$') {
        return [pscustomobject]@{
            key = 'weapon:MA Cannon'
            label = 'M-series Cannons'
            family = 'suffix-list'
            token = "$($Matches[1])A"
            original = $displayName
        }
    }

    if ($displayName -match '^AD(\d+)B\s+Ballistic Gatling$') {
        return [pscustomobject]@{
            key = 'weapon:AD Ballistic Gatling'
            label = 'AD Ballistic Gatlings'
            family = 'suffix-list'
            token = "$($Matches[1])B"
            original = $displayName
        }
    }

    if ($displayName -match '^(.+?)-(\d+)\s+(Repeater|Scattergun|Cannon)$') {
        $base = $Matches[1].Trim()
        $kind = $Matches[3].Trim()
        return [pscustomobject]@{
            key = "weapon:$base $kind"
            label = "$base ${kind}s"
            family = 'numbered'
            token = [int]$Matches[2]
            original = $displayName
        }
    }

    if ($displayName -match '^DR Model-XJ(\d+)\s+Repeater$') {
        return [pscustomobject]@{
            key = 'weapon:DR Model-XJ Repeater'
            label = 'DR Model-XJ Repeaters'
            family = 'numbered'
            token = [int]$Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^FL-(\d+)\s+Cannon$') {
        return [pscustomobject]@{
            key = 'weapon:FL Cannon'
            label = 'FL Cannons'
            family = 'number-list'
            token = [int]$Matches[1]
            original = $displayName
        }
    }

    if ($displayName -match '^(Hofstede|Klein)-S(\d+)\s+Mining Laser$') {
        $base = $Matches[1]
        return [pscustomobject]@{
            key = "weapon:$base Mining Laser"
            label = $base
            family = 'mining-laser-list'
            token = [int]$Matches[2]
            original = $displayName
        }
    }

    if ($displayName -match '^(Helix|Impact)\s+([IVXLCDM]+)\s+Mining Laser$') {
        $base = $Matches[1]
        return [pscustomobject]@{
            key = "weapon:$base Mining Laser"
            label = $base
            family = 'mining-laser-list'
            token = $Matches[2]
            original = $displayName
        }
    }

    if ($displayName -match '^S0+\s+(Helix|Hofstede)$') {
        $base = $Matches[1]
        return [pscustomobject]@{
            key = "weapon:$base Mining Laser"
            label = $base
            family = 'mining-laser-list'
            token = ($displayName -replace "\s+$base$", '')
            original = $displayName
        }
    }

    if ($Category -eq 'Корабельные компоненты') {
        if ($displayName -match '^([567])(CA|MA|SA)\s+''[^'']+''$') {
            $series = $Matches[1]
            return [pscustomobject]@{
                key = "component:$series-series"
                label = "${series}CA/${series}MA/${series}SA"
                family = 'variant'
                token = $null
                original = $displayName
            }
        }

        if ($displayName -match '^JS-\d+$') {
            return [pscustomobject]@{
                key = 'component:JS-series'
                label = 'JS-300/400'
                family = 'variant'
                token = $null
                original = $displayName
            }
        }

        if ($displayName -match '^V801-\d+$') {
            return [pscustomobject]@{
                key = 'component:V801-series'
                label = 'V801-11/12'
                family = 'variant'
                token = $null
                original = $displayName
            }
        }

        $componentVariantBases = @(
            'BroadSpec',
            'Cryo-Star',
            'Frost-Star',
            'FullForce',
            'FullSpec',
            'IonSurge',
            'SparkJet',
            'Surveyor',
            'Winter-Star'
        )

        if ($componentVariantBases -contains $displayName) {
            return [pscustomobject]@{
                key = "component:$displayName"
                label = "$displayName variants"
                family = 'variant'
                token = $null
                original = $displayName
            }
        }

        if ($displayName -match '^(.+?)(?:\s+(EX|SL|XL|Pro))$') {
            $base = $Matches[1].Trim()
            return [pscustomobject]@{
                key = "component:$base"
                label = "$base variants"
                family = 'variant'
                token = $null
                original = $displayName
            }
        }

        if ($displayName -match '^(.+?)-(Go|Max|Lite)$') {
            $base = $Matches[1].Trim()
            return [pscustomobject]@{
                key = "component:$base"
                label = "$base variants"
                family = 'variant'
                token = $null
                original = $displayName
            }
        }
    }

    if ($displayName -match '^Pulse\s+(Laser\s+)?Pistol$') {
        return [pscustomobject]@{
            key = 'weapon:Pulse Pistol'
            label = 'Pulse / Pulse Laser Pistol'
            family = 'variant'
            token = $null
            original = $displayName
        }
    }

    if ($displayName -match '^Pulse\s+"[^"]+"\s+Pistol$') {
        return [pscustomobject]@{
            key = 'weapon:Pulse Pistol'
            label = 'Pulse / Pulse Laser Pistol'
            family = 'variant'
            token = $null
            original = $displayName
        }
    }

    if ($displayName -match '^(.+?)\s+"[^"]+"\s+(.+)$') {
        $base = ($Matches[1] + ' ' + $Matches[2]).Trim()
        return [pscustomobject]@{
            key = "variant:$base"
            label = "$base variants"
            family = 'variant'
            token = $null
            original = $displayName
        }
    }

    if ($Category -eq 'Оружие' -and $displayName -match '^(.+?)\s+(Energy Assault Rifle|Laser Sniper Rifle|Laser Shotgun|Sniper Rifle|Twin Shotgun|Energy LMG|Pistol|SMG|Rifle|Shotgun|Crossbow|LMG)$') {
        return [pscustomobject]@{
            key = "variant:$displayName"
            label = "$displayName variants"
            family = 'variant'
            token = $null
            original = $displayName
        }
    }

    if ($displayName -match '^(Abrade|Cinch|Trawler)\s+Scraper Module$') {
        return [pscustomobject]@{
            key = 'equipment:Scraper Modules'
            label = 'Abrade/Cinch/Trawler Scraper Modules'
            family = 'variant'
            token = $null
            original = $displayName
        }
    }

    if ($displayName -match '^(.+?)\s+Battery\s+\([^)]+\)$') {
        $base = $Matches[1].Trim()
        return [pscustomobject]@{
            key = "battery:$base"
            label = "$base batteries"
            family = 'variant'
            token = $null
            original = $displayName
        }
    }

    if ($displayName -match '^(.+?)\s+Magazine\s+\([^)]+\)$') {
        $base = $Matches[1].Trim()
        return [pscustomobject]@{
            key = "magazine:$base"
            label = "$base magazines"
            family = 'variant'
            token = $null
            original = $displayName
        }
    }

    return [pscustomobject]@{
        key = "exact:$displayName"
        label = $displayName
        family = 'exact'
        token = $null
        original = $displayName
    }
}

function Format-PlanetRecipeFamilyLabel {
    param($Group)

    if ($Group.names.Count -le 1 -or $Group.family -eq 'exact') {
        return [string]$Group.names[0]
    }

    if ($Group.family -eq 'armor') {
        return "$($Group.label) set"
    }

    if ($Group.family -eq 'numbered') {
        $span = Format-NumberSpan -Values $Group.tokens
        if ($span) {
            return "$($Group.label) $span"
        }
    }

    if ($Group.family -eq 'number-list') {
        $span = Format-NumberSpan -Values $Group.tokens
        if ($span) {
            return "$($Group.label) $span"
        }
    }

    if ($Group.family -eq 'roman') {
        $span = Format-RomanSpan -Values $Group.tokens
        if ($span) {
            return "$($Group.label) $span"
        }
    }

    if ($Group.family -eq 'size') {
        $span = Format-NumberSpan -Values $Group.tokens
        if ($span) {
            if ($span -match '^(\d+)-(\d+)$') {
                return "$($Group.label) S$($Matches[1])-S$($Matches[2])"
            }
            return "$($Group.label) S$span"
        }
    }

    if ($Group.family -eq 'suffix-list') {
        $tokens = @($Group.tokens | Sort-Object -Unique)
        if ($tokens.Count -gt 0) {
            return "$($Group.label) " + ($tokens -join '/')
        }
    }

    if ($Group.family -eq 'mining-laser-list') {
        $tokens = @(
            $Group.tokens |
                ForEach-Object { [string]$_ } |
                Sort-Object -Unique
        )
        if ($tokens.Count -gt 0) {
            return "$($Group.label) " + ($tokens -join '/') + ' Mining Lasers'
        }
    }

    return ([string]$Group.label) -replace '\s+variants$', ''
}

function Get-ShipComponentSubcategory {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $CraftInfo
    )

    $displayName = (Format-DisplayName -Name $Name).Trim()
    $type = if ($CraftInfo -and $CraftInfo.type) { [string]$CraftInfo.type } else { '' }

    if ($type -match 'щит' -or $displayName -match '(?i)\b(Shield|5CA|5MA|5SA|6CA|6MA|6SA|7CA|7MA|7SA|FR-|BLOC|GUARD|HAVEN|HEX|INK|PIN|RPEL|STOP|WEB|Palisade|Rampart|Umbra|Mirage|Veil)\b') {
        return 'Щиты'
    }

    if ($type -match 'квантовый' -or $displayName -match '(?i)\b(Quantum|VK-00|XL-1|TS-2|Spectre|Spicule|Siren|Yeager|Zephyr|Colossus|Huracan|Bolt|Balandin|Agni)\b') {
        return 'Квантовые двигатели'
    }

    if ($type -match 'силовая установка' -or $displayName -match '(?i)\b(Power|JS-|FullForce|IonSurge|SparkJet|DuraJet|DeltaMax|DynaFlux|ZapJet|Fulgur|Bolide|Eclipse|Slipstream)\b') {
        return 'Силовые установки'
    }

    if ($type -match 'охладитель' -or $displayName -match '(?i)\b(Cooler|Cryo-Star|Frost-Star|Winter-Star|Cold|Frost|Glacier|Gelid|Avalanche|Permafrost|SnowBlind|WhiteOut|Tempest|Aufeis)\b') {
        return 'Охладители'
    }

    if ($type -match 'радар' -or $displayName -match '(?i)\b(Radar|BroadSpec|FullSpec|Surveyor|V801|V880|V60|Tige|Sens|Vigilance)\b') {
        return 'Радары'
    }

    if ($type -match 'топливная форсунка' -or $displayName -match '(?i)\b(Fuel Nozzle)\b') {
        return 'Топливные форсунки'
    }

    return 'Прочее'
}

function Get-ShipComponentSubcategoryRank {
    param([string]$Subcategory)

    $index = [array]::IndexOf($ShipComponentSubcategoryOrder, $Subcategory)
    if ($index -lt 0) {
        return 999
    }

    return $index
}

function Get-ArmorSubcategory {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $CraftInfo
    )

    $displayName = (Format-DisplayName -Name $Name).Trim()
    $type = if ($CraftInfo -and $CraftInfo.type) { [string]$CraftInfo.type } else { '' }

    if ($type -match 'тяж') {
        return 'Тяжёлая броня'
    }

    if ($type -match 'сред') {
        return 'Средняя броня'
    }

    if ($type -match 'л[её]г') {
        return 'Лёгкая броня'
    }

    if ($type -match 'нижний костюм|Undersuit' -or $displayName -match '(?i)\b(Undersuit|Flight Suit|Racing|Novikov|Pembroke|Stirling|Testudo|Tailwind|BlackFire|BlueFlame|WhiteHot)\b') {
        return 'Андерсьюты/костюмы'
    }

    return 'Прочее'
}

function Get-ArmorSubcategoryRank {
    param([string]$Subcategory)

    $index = [array]::IndexOf($ArmorSubcategoryOrder, $Subcategory)
    if ($index -lt 0) {
        return 999
    }

    return $index
}

function Get-FpsWeaponSubcategory {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $CraftInfo
    )

    $displayName = (Format-DisplayName -Name $Name).Trim()
    $type = if ($CraftInfo -and $CraftInfo.type) { [string]$CraftInfo.type } else { '' }

    if ($type -match 'снайпер' -or $displayName -match '(?i)\b(Sniper Rifle|Arrowhead|Atzkav|Scalpel|Zenith|P6-LR|A03)\b') {
        return 'Снайперские винтовки'
    }

    if ($type -match 'винтовка' -or $displayName -match '(?i)\b(Rifle|Energy Assault Rifle|Gallant|Karna|Killshot|P8-AR|Parallax|S71)\b') {
        return 'Винтовки'
    }

    if ($type -match 'пистолет-пулем' -or $displayName -match '(?i)\b(SMG|C54|Custodian|Lumin|P8-SC|Quartz|Ripper)\b') {
        return 'Пистолеты-пулемёты'
    }

    if ($type -match 'пистолет' -or $displayName -match '(?i)\b(Pistol|Arclight|Coda|LH86|Pulse|Tripledown|Yubarev)\b') {
        return 'Пистолеты'
    }

    if ($type -match 'дробовик' -or $displayName -match '(?i)\b(Shotgun|BR-2|Deadrig|Devastator|Prism|R97|Ravager)\b') {
        return 'Дробовики'
    }

    if ($type -match 'пулем' -or $displayName -match '(?i)\b(LMG|F55|Fresnel|FS-9|Pulverizer)\b') {
        return 'Пулемёты'
    }

    if ($type -match 'Crossbow|арбалет' -or $displayName -match '(?i)\b(Crossbow|Novian)\b') {
        return 'Арбалеты'
    }

    return 'Прочее'
}

function Get-FpsWeaponSubcategoryRank {
    param([string]$Subcategory)

    $index = [array]::IndexOf($FpsWeaponSubcategoryOrder, $Subcategory)
    if ($index -lt 0) {
        return 999
    }

    return $index
}

function Get-ShipWeaponSubcategory {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $CraftInfo
    )

    $displayName = (Format-DisplayName -Name $Name).Trim()
    $type = if ($CraftInfo -and $CraftInfo.type) { [string]$CraftInfo.type } else { '' }

    if ($type -match 'добывающий лазер|Mining Laser' -or $displayName -match '(?i)\b(Mining Laser|Helix|Hofstede|Klein|Lancet|Arbor|Pitman|Lawson|S0 Helix|S00 Hofstede)\b') {
        return 'Добывающие лазеры'
    }

    if ($type -match 'Mass Driver' -or $displayName -match '(?i)\b(Mass Driver|Sledge|Strife)\b') {
        return 'Гибрид'
    }

    if ($type -match 'баллист' -or $type -match 'Ballistic' -or $displayName -match '(?i)\b(Deadbolt|Tarantula|C-788|Greatsword|Broadsword|Longsword|AD[456]B|Draugar|Mantis|Revenant|Scorpion|Tigerstrike|YellowJacket|SW16BR)\b') {
        return 'Баллистика'
    }

    if ($type -match 'лазер|нейтрон|тахион|дисторсион|разброс' -or $type -match 'Laser|Neutron|Tachyon|Distortion|Scattergun' -or $displayName -match '(?i)\b(Attrition|CF-|FL-|Lightstrike|M[3-8]A|Omnisky|Quarreler|DR Model|Suckerpunch|Dominance|Havoc|Hellion|Predator|NN-|Singe)\b') {
        return 'Энергетика'
    }

    return 'Прочее'
}

function Get-ShipWeaponSubcategoryRank {
    param([string]$Subcategory)

    $index = [array]::IndexOf($ShipWeaponSubcategoryOrder, $Subcategory)
    if ($index -lt 0) {
        return 999
    }

    return $index
}

function Get-BlueprintSubcategory {
    param(
        [string]$Category,
        [string]$Name,
        $CraftInfo
    )

    if ($Category -eq 'Корабельные компоненты') {
        return Get-ShipComponentSubcategory -Name $Name -CraftInfo $CraftInfo
    }

    if ($Category -eq 'Корабельные орудия') {
        return Get-ShipWeaponSubcategory -Name $Name -CraftInfo $CraftInfo
    }

    if ($Category -eq 'Броня/одежда') {
        return Get-ArmorSubcategory -Name $Name -CraftInfo $CraftInfo
    }

    if ($Category -eq 'Оружие') {
        return Get-FpsWeaponSubcategory -Name $Name -CraftInfo $CraftInfo
    }

    return $null
}

function Get-BlueprintSubcategoryRank {
    param(
        [string]$Category,
        [string]$Subcategory
    )

    if ($Category -eq 'Корабельные компоненты') {
        return Get-ShipComponentSubcategoryRank -Subcategory $Subcategory
    }

    if ($Category -eq 'Корабельные орудия') {
        return Get-ShipWeaponSubcategoryRank -Subcategory $Subcategory
    }

    if ($Category -eq 'Броня/одежда') {
        return Get-ArmorSubcategoryRank -Subcategory $Subcategory
    }

    if ($Category -eq 'Оружие') {
        return Get-FpsWeaponSubcategoryRank -Subcategory $Subcategory
    }

    return 999
}

function Test-UseBlueprintSubcategories {
    param([string]$Category)

    return $Category -in @('Корабельные компоненты', 'Корабельные орудия', 'Броня/одежда', 'Оружие')
}

function Test-IncludePlanetRecipe {
    param(
        [string]$Name,
        [string]$Category,
        $CraftInfo
    )

    if ($Category -eq 'Снаряжение/расходники') {
        return $false
    }

    if ($Category -eq 'Оружие') {
        $fpsWeaponSubcategory = Get-FpsWeaponSubcategory -Name $Name -CraftInfo $CraftInfo
        return $fpsWeaponSubcategory -notin @('Пистолеты', 'Дробовики')
    }

    if ($Category -ne 'Корабельные компоненты') {
        return $true
    }

    $componentClass = ([string]$CraftInfo.class).Trim()
    return ([string]$CraftInfo.grade) -eq 'A' -and $componentClass -in @('Military', 'Stealth')
}

function Format-PlanetCraftBlock {
    param(
        [hashtable]$ResourceMethods,
        [hashtable]$BlueprintCraftMap
    )

    $lines = New-Object System.Collections.Generic.List[string]

    foreach ($category in $CategoryOrder) {
        $groupMap = @{}
        $recipes = @(
            $BlueprintCraftMap.GetEnumerator() |
                Where-Object { $_.Value.category -eq $category } |
                Sort-Object Key
        )

        foreach ($recipe in $recipes) {
            if (-not (Test-IncludePlanetRecipe -Name ([string]$recipe.Key) -Category $category -CraftInfo $recipe.Value)) {
                continue
            }

            $methodResources = @{
                'К' = @{}
                'Т' = @{}
                'М' = @{}
            }

            foreach ($ingredient in @($recipe.Value.ingredients)) {
                $resource = Normalize-ResourceName -Name ([string]$ingredient.name)
                if ([string]::IsNullOrWhiteSpace($resource) -or -not $ResourceMethods.ContainsKey($resource)) {
                    continue
                }

                foreach ($method in @('К', 'Т', 'М')) {
                    if ($ResourceMethods[$resource].ContainsKey($method)) {
                        $methodResources[$method][$resource] = $true
                    }
                }
            }

            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($method in @('К', 'Т', 'М')) {
                $resources = @($methodResources[$method].Keys | Sort-Object)
                if ($resources.Count -gt 0) {
                    $methodLabel = if ($method -eq 'К') { Format-ShipMiningMethodLabel } else { "[$method]" }
                    $parts.Add("$methodLabel " + ($resources -join ', '))
                }
            }

            if ($parts.Count -gt 0) {
                $family = Get-PlanetRecipeFamily -Name ([string]$recipe.Key) -Category $category
                $recipeDisplayName = (Format-DisplayName -Name ([string]$recipe.Key)).Trim()
                if ($recipeDisplayName -match '^Pulse\s+(Laser\s+)?Pistol$') {
                    $family = [pscustomobject]@{
                        key = 'weapon:Pulse Pistol'
                        label = 'Pulse / Pulse Laser Pistol'
                        family = 'variant'
                        token = $null
                        original = $recipeDisplayName
                    }
                }

                $resourceText = $parts -join ' | '
                $groupKey = "$($family.key)|$resourceText"
                if (-not $groupMap.ContainsKey($groupKey)) {
                    $groupMap[$groupKey] = [pscustomobject]@{
                        label = $family.label
                        family = $family.family
                        armorSubcategory = if ($category -eq 'Броня/одежда') { Get-ArmorSubcategory -Name ([string]$recipe.Key) -CraftInfo $recipe.Value } else { $null }
                        fpsWeaponSubcategory = if ($category -eq 'Оружие') { Get-FpsWeaponSubcategory -Name ([string]$recipe.Key) -CraftInfo $recipe.Value } else { $null }
                        subcategory = if ($category -eq 'Корабельные компоненты') { Get-ShipComponentSubcategory -Name ([string]$recipe.Key) -CraftInfo $recipe.Value } else { $null }
                        weaponSubcategory = if ($category -eq 'Корабельные орудия') { Get-ShipWeaponSubcategory -Name ([string]$recipe.Key) -CraftInfo $recipe.Value } else { $null }
                        resourceText = $resourceText
                        names = New-Object System.Collections.Generic.List[string]
                        tokens = New-Object System.Collections.Generic.List[object]
                    }
                }

                $groupMap[$groupKey].names.Add([string]$family.original)
                if ($null -ne $family.token) {
                    $groupMap[$groupKey].tokens.Add($family.token)
                }
            }
        }

        if ($groupMap.Count -gt 0) {
            $lines.Add("<EM4>$category</EM4>")
            if ($category -eq 'Корабельные компоненты') {
                $subgroups = @(
                    $groupMap.Values |
                        Group-Object -Property subcategory |
                        Sort-Object { Get-ShipComponentSubcategoryRank -Subcategory ([string]$_.Name) }, Name
                )

                foreach ($subgroup in $subgroups) {
                    $subcategory = if ([string]::IsNullOrWhiteSpace([string]$subgroup.Name)) { 'Прочее' } else { [string]$subgroup.Name }
                    $lines.Add((Format-SubcategoryLabel -Label "${subcategory}:"))
                    $groups = @($subgroup.Group | Sort-Object { Format-PlanetRecipeFamilyLabel -Group $_ })
                    foreach ($group in $groups) {
                        $label = Format-PlanetRecipeFamilyLabel -Group $group
                        $lines.Add("- ${label}: $($group.resourceText)")
                    }
                }
            }
            elseif ($category -eq 'Корабельные орудия') {
                $subgroups = @(
                    $groupMap.Values |
                        Group-Object -Property weaponSubcategory |
                        Sort-Object { Get-ShipWeaponSubcategoryRank -Subcategory ([string]$_.Name) }, Name
                )

                foreach ($subgroup in $subgroups) {
                    $subcategory = if ([string]::IsNullOrWhiteSpace([string]$subgroup.Name)) { 'Прочее' } else { [string]$subgroup.Name }
                    $lines.Add((Format-SubcategoryLabel -Label "${subcategory}:"))
                    $groups = @($subgroup.Group | Sort-Object { Format-PlanetRecipeFamilyLabel -Group $_ })
                    foreach ($group in $groups) {
                        $label = Format-PlanetRecipeFamilyLabel -Group $group
                        $lines.Add("- ${label}: $($group.resourceText)")
                    }
                }
            }
            elseif ($category -eq 'Броня/одежда') {
                $subgroups = @(
                    $groupMap.Values |
                        Group-Object -Property armorSubcategory |
                        Sort-Object { Get-ArmorSubcategoryRank -Subcategory ([string]$_.Name) }, Name
                )

                foreach ($subgroup in $subgroups) {
                    $subcategory = if ([string]::IsNullOrWhiteSpace([string]$subgroup.Name)) { 'Прочее' } else { [string]$subgroup.Name }
                    $lines.Add((Format-SubcategoryLabel -Label "${subcategory}:"))
                    $groups = @($subgroup.Group | Sort-Object { Format-PlanetRecipeFamilyLabel -Group $_ })
                    foreach ($group in $groups) {
                        $label = Format-PlanetRecipeFamilyLabel -Group $group
                        $lines.Add("- ${label}: $($group.resourceText)")
                    }
                }
            }
            elseif ($category -eq 'Оружие') {
                $subgroups = @(
                    $groupMap.Values |
                        Group-Object -Property fpsWeaponSubcategory |
                        Sort-Object { Get-FpsWeaponSubcategoryRank -Subcategory ([string]$_.Name) }, Name
                )

                foreach ($subgroup in $subgroups) {
                    $subcategory = if ([string]::IsNullOrWhiteSpace([string]$subgroup.Name)) { 'Прочее' } else { [string]$subgroup.Name }
                    $lines.Add((Format-SubcategoryLabel -Label "${subcategory}:"))
                    $groups = @($subgroup.Group | Sort-Object { Format-PlanetRecipeFamilyLabel -Group $_ })
                    foreach ($group in $groups) {
                        $label = Format-PlanetRecipeFamilyLabel -Group $group
                        $lines.Add("- ${label}: $($group.resourceText)")
                    }
                }
            }
            else {
                $groups = @($groupMap.Values | Sort-Object { Format-PlanetRecipeFamilyLabel -Group $_ })
                foreach ($group in $groups) {
                    $label = Format-PlanetRecipeFamilyLabel -Group $group
                    $lines.Add("- ${label}: $($group.resourceText)")
                }
            }
            $lines.Add('')
        }
    }

    if ($lines.Count -eq 0) {
        return $null
    }

    $block = New-Object System.Collections.Generic.List[string]
    $block.Add('<EM4>Крафт-подсказка (SCMDB)</EM4>')
    $block.Add('Показаны рецепты, для которых здесь добывается хотя бы один ресурс.')
    $block.Add('Это не полный рецепт — только ресурсы этой локации.')
    $shipMiningLabel = Format-ShipMiningMethodLabel
    $block.Add("Легенда: $shipMiningLabel корабль, [Т] наземная техника, [М] мультитул.")
    $block.Add('Фильтры: компоненты только Grade A Military/Stealth; FPS-оружие без пистолетов и дробовиков.')
    foreach ($line in $lines) {
        $block.Add($line)
    }

    return ($block -join '\n').TrimEnd()
}

function Format-BlueprintLine {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$OmitType
    )

    $info = $script:BlueprintEnrichment[$Name]
    if ($null -eq $info -or -not $info.found) {
        return "- $(Format-DisplayName -Name $Name)"
    }

    $details = New-Object System.Collections.Generic.List[string]
    if (-not $OmitType -and -not [string]::IsNullOrWhiteSpace($info.type)) {
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
        $blockLines.Add("<EM4>$category</EM4>")
        if (Test-UseBlueprintSubcategories -Category $category) {
            $subcategoryGroups = @{}
            foreach ($name in ($groups[$category] | Sort-Object)) {
                $info = $script:BlueprintEnrichment[$name]
                $subcategory = Get-BlueprintSubcategory -Category $category -Name $name -CraftInfo $info
                if ([string]::IsNullOrWhiteSpace($subcategory)) {
                    $subcategory = 'Прочее'
                }
                if (-not $subcategoryGroups.ContainsKey($subcategory)) {
                    $subcategoryGroups[$subcategory] = New-Object System.Collections.Generic.List[string]
                }
                $subcategoryGroups[$subcategory].Add($name)
            }

            foreach ($subcategory in ($subcategoryGroups.Keys | Sort-Object { Get-BlueprintSubcategoryRank -Category $category -Subcategory $_ }, { $_ })) {
                $blockLines.Add((Format-SubcategoryLabel -Label "${subcategory}:"))
                $omitType = $category -in @('Корабельные компоненты', 'Броня/одежда', 'Оружие')
                foreach ($name in ($subcategoryGroups[$subcategory] | Sort-Object)) {
                    $blockLines.Add((Format-BlueprintLine -Name $name -OmitType:$omitType))
                }
            }
        }
        else {
            foreach ($name in ($groups[$category] | Sort-Object)) {
                $blockLines.Add((Format-BlueprintLine -Name $name))
            }
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
$lineValues = New-LineValueMap -Lines $lines
$resourceLocationMap = New-ResourceLocationMap -Lines $lines -LineValues $lineValues
$blueprintCraftMap = New-BlueprintCraftMap -Names $uniqueBlueprintNames -EnrichmentMap $script:BlueprintEnrichment

$changedLines = 0
$changedDescriptionLines = 0
$changedTitleLines = 0
$changedPlanetDescriptionLines = 0
$changedCraftGuideLines = 0
$cleanedExistingBlocks = 0
$cleanedExistingCraftIntelBlocks = 0
$fixedMalformedEmphasisLines = 0
$missingDescriptionKeys = New-Object System.Collections.Generic.List[string]
$missingTitleKeys = New-Object System.Collections.Generic.List[string]
$modifiedDescriptionKeys = New-Object System.Collections.Generic.List[string]
$modifiedTitleKeys = New-Object System.Collections.Generic.List[string]
$modifiedPlanetKeys = New-Object System.Collections.Generic.List[string]
$fixedMalformedEmphasisKeys = New-Object System.Collections.Generic.List[string]
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

    if (-not $NoCraftIntel) {
        if ($key -match '(?i)_desc$' -and $currentValue -match 'Потенциально добываемые ресурсы') {
            $cleanCraftValue = Remove-CraftIntelBlock -Value $currentValue
            if ($cleanCraftValue -ne $currentValue) {
                $cleanedExistingCraftIntelBlocks++
            }

            $repairedCraftValue = Repair-EmphasisTags -Value $cleanCraftValue
            if ($repairedCraftValue -ne $cleanCraftValue) {
                $fixedMalformedEmphasisLines++
                $fixedMalformedEmphasisKeys.Add($key)
                $cleanCraftValue = $repairedCraftValue
            }

            $resourceMethods = Get-ResourceMethodsFromDescription -Value $cleanCraftValue
            $craftBlock = Format-PlanetCraftBlock -ResourceMethods $resourceMethods -BlueprintCraftMap $blueprintCraftMap
            if (-not [string]::IsNullOrWhiteSpace($craftBlock)) {
                $newValue = $cleanCraftValue + '\n\n' + $craftBlock
                if ($newValue -ne $currentValue) {
                    $lines[$i] = $rawKey + '=' + $newValue
                    $changedLines++
                    $changedPlanetDescriptionLines++
                    $modifiedPlanetKeys.Add($key)
                    $currentValue = $newValue
                }
            }
        }
    }

    if ($descriptionRewardMap.ContainsKey($key)) {
        $seenDescriptionKeys[$key] = $true
        $cleanValue = Remove-BlueprintBlock -Value $currentValue
        if ($cleanValue -ne $currentValue) {
            $cleanedExistingBlocks++
        }

        $repairedValue = Repair-EmphasisTags -Value $cleanValue
        if ($repairedValue -ne $cleanValue) {
            $fixedMalformedEmphasisLines++
            $fixedMalformedEmphasisKeys.Add($key)
            $cleanValue = $repairedValue
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
        $titleInfo = $titleRewardMap[$key]
        $cleanTitle = Remove-TitleMarker -Value $currentValue
        $titleMarkers = Format-TitleMarkers -TitleInfo $titleInfo
        $newTitle = if ([string]::IsNullOrWhiteSpace($titleMarkers)) { $cleanTitle } else { "$titleMarkers $cleanTitle" }

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
    craftIntelEnabled = -not [bool]$NoCraftIntel
    blueprintRecipesMatched = $blueprintCraftMap.Keys.Count
    resourceLocationEntries = $resourceLocationMap.Keys.Count
    titleMarker = $TitleMarker
    acePilotTitleMarker = $AcePilotTitleMarker
    scripTitleMarker = $ScripTitleMarker
    scmdbRewardDescriptionKeys = $descriptionRewardMap.Keys.Count
    scmdbRewardTitleKeys = $titleRewardMap.Keys.Count
    titleKeysWithBlueprintMarker = @($titleRewardMap.Values | Where-Object { $_.HasBlueprint }).Count
    titleKeysWithAcePilotMarker = @($titleRewardMap.Values | Where-Object { $_.HasAcePilot }).Count
    titleKeysWithScripMarker = @($titleRewardMap.Values | Where-Object { $_.HasScrip }).Count
    matchedDescriptionKeys = $seenDescriptionKeys.Keys.Count
    matchedTitleKeys = $seenTitleKeys.Keys.Count
    changedLines = $changedLines
    changedDescriptionLines = $changedDescriptionLines
    changedTitleLines = $changedTitleLines
    changedPlanetDescriptionLines = $changedPlanetDescriptionLines
    changedCraftGuideLines = $changedCraftGuideLines
    cleanedExistingBlocks = $cleanedExistingBlocks
    cleanedExistingCraftIntelBlocks = $cleanedExistingCraftIntelBlocks
    fixedMalformedEmphasisLines = $fixedMalformedEmphasisLines
    conflictingSharedDescriptionKeys = $conflictKeys.Count
    missingDescriptionKeys = $missingDescriptionKeys.Count
    missingTitleKeys = $missingTitleKeys.Count
    wikiMatched = $enrichmentStats.wikiMatched
    overrideMatched = $enrichmentStats.overrideMatched
    patternMatched = $enrichmentStats.patternMatched
    unknownBlueprints = $enrichmentStats.unknownBlueprints
    modifiedDescriptionKeysSample = @($modifiedDescriptionKeys | Select-Object -First 20)
    modifiedTitleKeysSample = @($modifiedTitleKeys | Select-Object -First 20)
    modifiedPlanetKeysSample = @($modifiedPlanetKeys | Select-Object -First 20)
    fixedMalformedEmphasisKeysSample = @($fixedMalformedEmphasisKeys | Select-Object -First 20)
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
    Write-Host "Blueprint recipes: $($blueprintCraftMap.Keys.Count)"
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
    Write-Host "Blueprint recipes: $($blueprintCraftMap.Keys.Count)"
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
Write-Host "Blueprint recipes: $($blueprintCraftMap.Keys.Count)"
Write-Host "New SHA256: $newHash"
Write-Host "Report: $ReportPath"
