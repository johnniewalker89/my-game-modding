param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$CoreScript = Join-Path $ProjectDir 'shared\SC_Localization_Core.ps1'
. $CoreScript
$MiningModuleScript = Join-Path $ProjectDir 'modules\mining\module.ps1'
. $MiningModuleScript
$QuestModuleScript = Join-Path $ProjectDir 'modules\quest\module.ps1'
. $QuestModuleScript

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
}

function ConvertFrom-TestCodePoints {
    param([int[]]$CodePoints)

    return -join ($CodePoints | ForEach-Object { [char]$_ })
}

function Test-WindowsPowerShellParser {
    param([string]$Root)

    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        return
    }

    $files = @(Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -Recurse -File | ForEach-Object { $_.FullName })
    $parseScript = @'
param([string[]]$Files)

foreach ($file in $Files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        Write-Error ("Windows PowerShell parse failed: " + $file + "`n" + ($errors | Out-String))
        exit 1
    }
}
'@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-windows-ps-parse-" + [guid]::NewGuid().ToString('N') + '.ps1')
    [System.IO.File]::WriteAllText($tempScript, $parseScript, [System.Text.Encoding]::Unicode)
    try {
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $tempScript -Files $files
        if ($LASTEXITCODE -ne 0) {
            throw 'Windows PowerShell parser compatibility check failed.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempScript -PathType Leaf) {
            Remove-Item -LiteralPath $tempScript -Force
        }
    }
}

function Import-TestQuestEngineFunctions {
    param(
        [Parameter(Mandatory = $true)][string]$EngineScript,
        [Parameter(Mandatory = $true)][string[]]$FunctionNames
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($EngineScript, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "Quest engine parser failed: $EngineScript`n$($errors | Out-String)"
    }

    $functions = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $FunctionNames -contains $node.Name
    }, $true)

    foreach ($name in $FunctionNames) {
        $definition = @($functions | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
        if ($definition.Count -eq 0) {
            throw "Quest engine test function not found: $name"
        }

        $body = $definition[0].Body.EndBlock.Extent.Text
        Set-Item -Path "Function:\global:$name" -Value ([scriptblock]::Create($body))
    }
}

Test-WindowsPowerShellParser -Root $ProjectDir

$shipCode = [string][char]0x041A
$groundCode = [string][char]0x0422
$handCode = [string][char]0x041C
$craftHeaderText = ConvertFrom-TestCodePoints -CodePoints @(0x041A, 0x0440, 0x0430, 0x0444, 0x0442, 0x002D, 0x043F, 0x043E, 0x0434, 0x0441, 0x043A, 0x0430, 0x0437, 0x043A, 0x0430)
$legendPrefix = ConvertFrom-TestCodePoints -CodePoints @(0x041B, 0x0435, 0x0433, 0x0435, 0x043D, 0x0434, 0x0430, 0x003A, 0x0020)
$shipLabel = ConvertFrom-TestCodePoints -CodePoints @(0x043A, 0x043E, 0x0440, 0x0430, 0x0431, 0x043B, 0x044C)
$groundLabel = ConvertFrom-TestCodePoints -CodePoints @(0x043D, 0x0430, 0x0437, 0x0435, 0x043C, 0x043D, 0x0430, 0x044F, 0x0020, 0x0442, 0x0435, 0x0445, 0x043D, 0x0438, 0x043A, 0x0430)
$handLabel = ConvertFrom-TestCodePoints -CodePoints @(0x043C, 0x0443, 0x043B, 0x044C, 0x0442, 0x0438, 0x0442, 0x0443, 0x043B)
$craftHeader = "<EM4>$craftHeaderText (SCMDB)</EM4>"
$fullLegend = "$legendPrefix<EM4>[$shipCode]</EM4> $shipLabel, [$groundCode] $groundLabel, [$handCode] $handLabel."
$shipOnlyLegend = "$legendPrefix<EM4>[$shipCode]</EM4> $shipLabel."
$rawShipHeader = 'Потенциально добываемые ресурсы (корабль):'
$rawGroundHeader = 'Потенциально добываемые ресурсы (наземная техника):'
$rawHandHeader = 'Потенциально добываемые ресурсы (ручная добыча):'
$rawCollectableHeader = 'Потенциально собираемые ресурсы:'
$rawCreatureHeader = 'Потенциальные существа:'
$refineryYieldLabel = 'Переработка (UEX)'
$refineryBonusLabel = 'бонусы:'
$refineryPenaltyLabel = 'штрафы:'

$refineryVersionProbe = ConvertTo-SCMiningRefineryYieldCachePayload -CacheKey '4.9.0-live.12232306' -Records @(
    [pscustomobject]@{
        space_station_name = 'Test Refinery'
        outpost_name = ''
        terminal_name = 'Test Refinery Terminal'
        commodity_name = 'Iron (Ore)'
        value_month = 5
    }
)
Assert-True ([string]$refineryVersionProbe.gameVersion -eq '4.9.0-live.12232306') 'Refinery cache metadata should use the active cache key instead of a stale hardcoded game version.'

$highlightedScripTitle = Set-SCQuestTitleHighlight -Value '[С] ОТВЕТНЫЙ УДАР' -Enabled $true -Tag 'EM4'
Assert-True ($highlightedScripTitle -eq '[С] <EM4>ОТВЕТНЫЙ УДАР</EM4>') 'High-value scrip highlight should wrap title text after markers.'
Assert-True ((Set-SCQuestTitleHighlight -Value $highlightedScripTitle -Enabled $true -Tag 'EM4') -eq $highlightedScripTitle) 'High-value scrip highlight should be idempotent.'
Assert-True ((Set-SCQuestTitleHighlight -Value $highlightedScripTitle -Enabled $false -Tag 'EM4') -eq '[С] ОТВЕТНЫЙ УДАР') 'High-value scrip highlight should be removable.'
Assert-True ((Set-SCQuestTitleHighlight -Value '[С] <EM2>ОТВЕТНЫЙ УДАР</EM2>' -Enabled $true -Tag 'EM4') -eq '[С] <EM4>ОТВЕТНЫЙ УДАР</EM4>') 'High-value scrip highlight should migrate old title highlight tags.'
Assert-True ((Set-SCQuestTitleHighlight -Value '<EM4>[А]</EM4> [С] ТАКТИЧЕСКИЙ УДАР' -Enabled $true -Tag 'EM4') -eq '<EM4>[А]</EM4> [С] <EM4>ТАКТИЧЕСКИЙ УДАР</EM4>') 'High-value scrip highlight should preserve styled title markers.'
Assert-True ((Set-SCQuestTitleHighlight -Value '[С] ТАКТИЧЕСКИЙ УДАР [NY:250/PY:8K/ST:8K]' -Enabled $true -Tag 'EM4') -eq '[С] <EM4>ТАКТИЧЕСКИЙ УДАР</EM4> [NY:250/PY:8K/ST:8K]') 'High-value scrip highlight should leave reputation suffix outside the highlight.'
Assert-True ((Set-SCQuestTitleHighlight -Value '[С] <EM4><EM4>ТАКТИЧЕСКИЙ УДАР</EM4> [NY:250/PY:8K/ST:8K]</EM4>' -Enabled $true -Tag 'EM4') -eq '[С] <EM4>ТАКТИЧЕСКИЙ УДАР</EM4> [NY:250/PY:8K/ST:8K]') 'High-value scrip highlight should repair nested highlight around reputation suffix.'
Assert-True ((Set-SCQuestTitleHighlight -Value '[С] <EM4><EM4>ТАКТИЧЕСКИЙ УДАР</EM4> [NY:250/PY:8K/ST:8K]' -Enabled $true -Tag 'EM4') -eq '[С] <EM4>ТАКТИЧЕСКИЙ УДАР</EM4> [NY:250/PY:8K/ST:8K]') 'High-value scrip highlight should repair unbalanced nested highlight left by old title cleanup.'
Assert-True ((Set-SCQuestTitleHighlight -Value '[С] <EM4>ТАКТИЧЕСКИЙ УДАР</EM4> [NY:250/PY:8K/ST:8K]' -Enabled $false -Tag 'EM4') -eq '[С] ТАКТИЧЕСКИЙ УДАР [NY:250/PY:8K/ST:8K]') 'Disabled high-value scrip highlight should keep reputation suffix while removing title highlight.'
Assert-True ((Set-SCQuestTitleHighlight -Value 'ОЧИСТИТЬ МАРШРУТ ОТ ВРАЖДЕБНЫХ СИЛ [100]' -Enabled $true -Tag 'EM4') -eq '<EM4>ОЧИСТИТЬ МАРШРУТ ОТ ВРАЖДЕБНЫХ СИЛ</EM4> [100]') 'Title highlight should treat plain reputation suffix as a suffix, not title text.'

$questEngineRoot = Join-Path $ProjectDir 'modules\quest\engine'
$questEngineScript = Join-Path $questEngineRoot 'SC_Quest_Recipe_Engine.ps1'
Assert-True (Test-Path -LiteralPath (Join-Path $questEngineRoot 'SC_Quest_Recipe_Engine.ps1') -PathType Leaf) 'Quest recipe engine should be packaged.'
Assert-True (Test-Path -LiteralPath (Join-Path $questEngineRoot 'data\blueprint-overrides.ru.json') -PathType Leaf) 'Quest recipe overrides should be packaged.'
Import-TestQuestEngineFunctions -EngineScript $questEngineScript -FunctionNames @(
    'Remove-ReputationTitleMarker',
    'Format-TitleMarkers',
    'Format-ReputationTitleMarker',
    'Format-ReputationTitleAmount',
    'Format-ReputationAmountList',
    'Format-ReputationRankAmount',
    'Format-DisplayName',
    'Format-BlueprintLine',
    'Remove-TitleMarker',
    'Repair-EmphasisTags'
)
$NoReputationIntel = $false
$TitleMarker = '[Ч]'
$AcePilotTitleMarker = '<EM4>[А]</EM4>'
$ScripTitleMarker = '[С]'
Assert-True (Test-SCQuestAllSelectableCategoriesSelected -SelectedCategoryNames (Get-SCQuestSelectableCategoryNames)) 'All quest categories should be detected as full selection.'
Assert-True (-not (Test-SCQuestAllSelectableCategoriesSelected -SelectedCategoryNames @('Корабельные компоненты', 'Корабельные орудия'))) 'Partial quest category selection should not be treated as full selection.'
Assert-True (-not ((Get-SCQuestSelectableCategoryNames) -contains 'Материалы/особое')) 'Materials/special should not be a selectable quest category.'
$questBlockWithHiddenMaterial = "Quest\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n- FR-86 — щит\n\n<EM4>Материалы/особое</EM4>\n- Metamaterial Test #146 — метаматериал"
$questFiltered = Select-SCQuestRewardBlockCategories -Value $questBlockWithHiddenMaterial -SelectedCategoryNames (Get-SCQuestSelectableCategoryNames)
Assert-True ($questFiltered.Contains('FR-86')) 'Quest filtering should keep visible categories.'
Assert-True (-not $questFiltered.Contains('Материалы/особое')) 'Quest filtering should remove hidden materials/special category.'
Assert-True (-not $questFiltered.Contains('Metamaterial Test')) 'Quest filtering should remove test metamaterial recipes.'
$nightFallMergedMiningOptions = Expand-SCMiningCraftFamilyOptionIds -OptionIds @('craftFamily|Корабельные компоненты|Охладители|exact:NightFall')
Assert-True ($nightFallMergedMiningOptions -contains 'craftFamily|Корабельные компоненты|Охладители|component:SnowBlind-NightFall') 'Mining family filters should migrate old NightFall selection to the merged SnowBlind/NightFall family.'
$snowBlindMergedQuestOptions = Get-SCQuestSelectedFamilyOptionIds -SelectedOptions @('questCraftFamily|Корабельные компоненты|Охладители|exact:SnowBlind')
Assert-True ($snowBlindMergedQuestOptions -contains 'questCraftFamily|Корабельные компоненты|Охладители|component:SnowBlind-NightFall') 'Quest family filters should migrate old SnowBlind selection to the merged SnowBlind/NightFall family.'
$questFamilyIndex = Get-SCQuestCraftFamilyIndex
$familyLabels = @{}
foreach ($entry in @($questFamilyIndex.families)) {
    $familyLabels[[string]$entry.label] = $entry
}
foreach ($expectedLabel in @(
    'MIL-A: JS-300/400/500/ QuadraCell/MT/MX',
    'CAP-A: Frontline',
    'CAP-A: Main Powerplant',
    'CIV-A: Abetti/Agrippa/Anysta/Fabian',
    'IND-A: FullSpec/FullSpec-Go/FullSpec-Max',
    'MIL-A: V60-26/ V801-11/12/ V880',
    'STE-A: Cassandra/Pelerous/Prophet'
)) {
    Assert-True ($familyLabels.ContainsKey($expectedLabel)) "Craft family index should expose grouped label: $expectedLabel"
}
$milPowerFamily = $familyLabels['MIL-A: JS-300/400/500/ QuadraCell/MT/MX']
$civPowerFamily = $familyLabels['CIV-A: Lotus/Stellate/TigerLilly/WhiteRose']
$milPowerOptionId = 'questCraftFamily|' + (Get-SCQuestFamilyOptionSuffix -OptionId ([string]$milPowerFamily.optionId))
$civPowerOptionId = 'questCraftFamily|' + (Get-SCQuestFamilyOptionSuffix -OptionId ([string]$civPowerFamily.optionId))
$questPowerFamilyBlock = 'Quest\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n<EM4>Силовые установки:</EM4>\n- JS-300\n- JS-400\n- QuadraCell MX'
$questPowerFamilyKept = Select-SCQuestRewardBlockCategories -Value $questPowerFamilyBlock -SelectedCategoryNames @('Корабельные компоненты') -SelectedFamilyOptionIds @($milPowerOptionId) -FamilyIndex $questFamilyIndex
Assert-True ($questPowerFamilyKept.Contains('JS-300')) 'Selected MIL-A power family should keep JS-300.'
Assert-True ($questPowerFamilyKept.Contains('QuadraCell MX')) 'Selected MIL-A power family should keep QuadraCell MX.'
$questPowerFamilyDropped = Select-SCQuestRewardBlockCategories -Value $questPowerFamilyBlock -SelectedCategoryNames @('Корабельные компоненты') -SelectedFamilyOptionIds @($civPowerOptionId) -FamilyIndex $questFamilyIndex
Assert-True (-not $questPowerFamilyDropped.Contains('JS-300')) 'Neighbor power family should not keep JS-300.'
Assert-True (-not $questPowerFamilyDropped.Contains('QuadraCell MX')) 'Neighbor power family should not keep QuadraCell MX.'
$milQuantumFamily = $familyLabels['MIL-A: TS-2/VK-00/XL-1']
$milQuantumOptionId = 'questCraftFamily|' + (Get-SCQuestFamilyOptionSuffix -OptionId ([string]$milQuantumFamily.optionId))
$questMixedSubcategoryBlock = 'Quest\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n<EM4>Щиты:</EM4>\n- FR-86\n<EM4>Квантовые двигатели:</EM4>\n- TS-2\n- VK-00 — S1, Grade A, Military\n- XL-1'
$questQuantumOnly = Select-SCQuestRewardBlockCategories -Value $questMixedSubcategoryBlock -SelectedCategoryNames @('Корабельные компоненты') -SelectedFamilyOptionIds @($milQuantumOptionId) -FamilyIndex $questFamilyIndex
Assert-True (-not $questQuantumOnly.Contains('Щиты:')) 'Quest family filtering should not leave an empty subcategory heading.'
Assert-True ($questQuantumOnly.Contains('Квантовые двигатели:') -and $questQuantumOnly.Contains('TS-2')) 'Quest family filtering should preserve the selected subcategory and its recipes.'
Assert-True ((Format-BlueprintLine -Name 'VK-00') -eq '- VK-00') 'Quest blueprint lists should show every blueprint in the same name-only format.'
Assert-True ((Remove-TitleMarker -Value '[Ч?] TEST TITLE') -eq 'TEST TITLE') 'Quest engine should remove a mixed blueprint marker before rebuilding title markers.'
Assert-True ((Repair-EmphasisTags -Value 'A</EM4> B <EM4>C</EM4>') -eq 'A B <EM4>C</EM4>') 'Emphasis repair should remove only the unmatched closing tag.'
$frontlineMiningOptions = Expand-SCMiningCraftFamilyOptionIds -OptionIds @('craftFamily|Корабельные компоненты|Квантовые двигатели|exact:Frontline')
Assert-True (@($frontlineMiningOptions | Where-Object { $_ -like '*component:capital-a:frontline' }).Count -gt 0) 'Mining family filters should migrate old Frontline selection to CAP-A.'
$frontlineQuestOptions = Get-SCQuestSelectedFamilyOptionIds -SelectedOptions @('questCraftFamily|Корабельные компоненты|Квантовые двигатели|exact:Frontline')
Assert-True (@($frontlineQuestOptions | Where-Object { $_ -like '*component:capital-a:frontline' }).Count -gt 0) 'Quest family filters should migrate old Frontline selection to CAP-A.'
$radarMiningOptions = Expand-SCMiningCraftFamilyOptionIds -OptionIds @('craftFamily|Корабельные компоненты|Радары|component:V801-series')
Assert-True (@($radarMiningOptions | Where-Object { $_ -like '*component:радары:MIL-A:bexalite+borase+stileron' }).Count -gt 0) 'Mining family filters should migrate old V801 radar selection to MIL-A radars.'
$radarQuestOptions = Get-SCQuestSelectedFamilyOptionIds -SelectedOptions @('questCraftFamily|Корабельные компоненты|Радары|component:FullSpec')
Assert-True (@($radarQuestOptions | Where-Object { $_ -like '*component:радары:IND-A:laranite+riccite+titanium' }).Count -gt 0) 'Quest family filters should migrate old FullSpec radar selection to IND-A radars.'
$miningLocationIndex = (Get-SCMiningLocationInventoryIndex).ByKey
Assert-True ($miningLocationIndex.ContainsKey('Stanton1b_Desc')) 'Mining location index should map Aberdeen to SCMDB mining data.'
$aberdeenShipResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['Stanton1b_Desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
Assert-True ($aberdeenShipResources.Contains('Corundum 29.8%')) 'Aberdeen ship mining resources should come from SCMDB mining data with spawn percentages.'
Assert-True ((Normalize-SCMiningResourceName -Name 'Corundum 29.8%') -eq 'Corundum') 'Mining recipe matching should ignore displayed spawn percentages.'
Assert-True ($miningLocationIndex.ContainsKey('RR_MIC_L5_desc')) 'Mining location index should map MIC-L5 station to a mining profile.'
$micL5ShipResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['RR_MIC_L5_desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
Assert-True ($micL5ShipResources.Contains('Torite 28.5%')) 'MIC-L5 station should receive the Lagrange mining resources with spawn percentages.'
Assert-True ($miningLocationIndex.ContainsKey('Pyro1_desc')) 'Mining location index should map Pyro planets to SCMDB mining data.'
$pyroShipResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['Pyro1_desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
Assert-True ($pyroShipResources.Contains('Iron 32.7%') -and $pyroShipResources.Contains('Copper 32.6%')) 'Pyro planet resources should include SCMDB spawn percentages.'
Assert-True ($miningLocationIndex.ContainsKey('pyro_asteroid_cluster_desc')) 'Mining location index should map Pyro cluster descriptions to PDSA mining data.'
$pyroClusterShipResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['pyro_asteroid_cluster_desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
Assert-True ($pyroClusterShipResources.Contains('Torite 28.5%') -and $pyroClusterShipResources.Contains('Corundum 14.9%')) 'Pyro cluster resources should come from Pyro Deep Space Asteroids.'
Assert-True ($miningLocationIndex.ContainsKey('AsteroidCluster_MiningBase_Desc')) 'Mining location index should map generic mining bases to Aaron Halo data.'
$aaronShipResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['AsteroidCluster_MiningBase_Desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
Assert-True ($aaronShipResources.Contains('Beryl 18%') -and $aaronShipResources.Contains('Quantainium 2%')) 'Mining base resources should include Aaron Halo mining profile.'
Assert-True ($miningLocationIndex.ContainsKey('Pyro_asteroidbeltA_desc')) 'Mining location index should map generic Pyro belt text to combined Pyro belt profiles.'
$pyroBeltShipResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['Pyro_asteroidbeltA_desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
Assert-True ($pyroBeltShipResources.Contains('Silicon 26.7%') -and $pyroBeltShipResources.Contains('Tungsten 28.5%')) 'Combined Pyro belt resources should normalize Raw Silicon and include warm/cool belt materials.'
Assert-True ($miningLocationIndex.ContainsKey('Nyx_RockCracker_Desc')) 'Mining location index should map Nyx breaker stations to mining data.'
$rockCrackerHandResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['Nyx_RockCracker_Desc'].ResourcesByMethod[(Get-SCMiningHandCode)]
Assert-True ($rockCrackerHandResources.Contains('Sadaryx 1%')) 'Breaker station interior should expose Sadaryx hand-mining data.'
Assert-True ($miningLocationIndex.ContainsKey('nyx_transit_Glaciem_gen_desc')) 'Mining location index should map Glaciem transit points to Glaciem Ring data.'
$glaciemTransitResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['nyx_transit_Glaciem_gen_desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
Assert-True ($glaciemTransitResources.Contains('Torite 28.5%') -and $glaciemTransitResources.Contains('Iron 20.8%')) 'Glaciem transit points should expose the Glaciem Ring ship-mining profile.'
$glaciemBeltResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['Nyx_AsteroidBelt1_Desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
$keegerBeltResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['Nyx_AsteroidBelt2_Desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
Assert-True ($glaciemBeltResources.Contains('Iron 20.8%') -and -not $glaciemBeltResources.Contains('Aluminum 20.8%')) 'Glaciem Ring should not be merged with the Keeger Belt profile.'
Assert-True ($keegerBeltResources.Contains('Aluminum 20.8%') -and -not $keegerBeltResources.Contains('Iron 20.8%')) 'Keeger Belt should keep its own mining profile.'
$argusBlueprint = @(Get-SCMiningPlanetCraftBlueprints | Where-Object { [string]$_.output_name -eq 'Argus Helmet' } | Select-Object -First 1)[0]
$argusLookup = New-SCMiningLocalizationLookup -Context ([pscustomobject]@{ Values = @{
    'item_Name_adv_agent_helmet_01' = 'Argus Helmet'
    'item_Desc_adv_agent_helmet_01' = 'Legacy Argus description'
    'item_Desc_vgl_advocacy_lightarmor_helmet_01' = 'Class-matched Argus description'
} })
$argusDescriptionKey = Resolve-SCMiningCraftDescriptionKey -Blueprint $argusBlueprint -Reward $null -Lookup $argusLookup
Assert-True ($argusDescriptionKey -eq 'item_Desc_vgl_advocacy_lightarmor_helmet_01') 'Armor craft hints should prefer the class-matched description over an ambiguous display-name pair.'
$craftFamilyIndex = Get-SCMiningCraftFamilyIndex
$bellatorFamily = @($craftFamilyIndex.families | Where-Object { @($_.names) -contains 'Bellator Jacket' })[0]
Assert-True ($null -ne $bellatorFamily -and @($bellatorFamily.names) -contains 'Spettro Shoes') 'Bellator clothing and Spettro shoes should be grouped into one outfit family.'
$bulHeavyFamily = @($craftFamilyIndex.families | Where-Object { @($_.names) -contains 'BUL-H4 Helmet' })[0]
Assert-True ($null -ne $bulHeavyFamily -and [string]$bulHeavyFamily.subcategory -eq (Get-SCMiningPlanetSubcategorySuperHeavyArmor)) 'BUL-H4 helmet should be classified as super-heavy armor from its output class.'
Assert-True (@($bulHeavyFamily.names) -contains 'H4-PBF Ammo Carrier') 'BUL-H4 helmet and H4-PBF carrier should share one super-heavy armor family.'
Assert-True (@($bulHeavyFamily.names) -contains 'BUL-H4 Armor') 'BUL-H4 armor suit should remain in the same super-heavy family as its helmet and carrier.'
Assert-True (@($craftFamilyIndex.families | Where-Object { [string]$_.familyKey -eq 'armor:BUL-H4' }).Count -eq 1) 'BUL-H4 should produce exactly one family option.'
$vendettaFamily = @($craftFamilyIndex.families | Where-Object { @($_.names) -contains 'Vendetta HMG' })[0]
Assert-True ($null -ne $vendettaFamily -and @($vendettaFamily.names) -contains 'Vendetta "Snow Camo" HMG') 'Vendetta base and Snow Camo blueprints should share one variant family.'
Assert-True ([string]$vendettaFamily.subcategory -eq (Get-SCMiningPlanetSubcategoryHmgs)) 'Vendetta HMG family should be placed under heavy machine guns.'
$bulMiningMigration = Expand-SCMiningCraftFamilyOptionIds -OptionIds @('craftFamily|Броня/одежда|Тяжёлая броня|armor:BUL-H4')
Assert-True ($bulMiningMigration -contains 'craftFamily|Броня/одежда|Сверхтяжёлая броня|armor:BUL-H4') 'Mining filters should migrate the old BUL-H4 heavy-armor path.'
$bulSuitMiningMigration = Expand-SCMiningCraftFamilyOptionIds -OptionIds @('craftFamily|Броня/одежда|Андерсьюты/костюмы|armor:BUL-H4')
Assert-True ($bulSuitMiningMigration -contains 'craftFamily|Броня/одежда|Сверхтяжёлая броня|armor:BUL-H4') 'Mining filters should migrate the old BUL-H4 suit path.'
$vendettaMiningMigration = Expand-SCMiningCraftFamilyOptionIds -OptionIds @('craftFamily|Оружие|Пулемёты|variant:Vendetta HMG')
Assert-True ($vendettaMiningMigration -contains 'craftFamily|Оружие|Тяжёлые пулемёты|variant:Vendetta HMG') 'Mining filters should migrate the old Vendetta machine-gun path.'
$bulQuestMigration = Get-SCQuestSelectedFamilyOptionIds -SelectedOptions @('questCraftFamily|Броня/одежда|Тяжёлая броня|armor:BUL-H4')
Assert-True ($bulQuestMigration -contains 'questCraftFamily|Броня/одежда|Сверхтяжёлая броня|armor:BUL-H4') 'Quest filters should migrate the old BUL-H4 heavy-armor path.'
$bulSuitQuestMigration = Get-SCQuestSelectedFamilyOptionIds -SelectedOptions @('questCraftFamily|Броня/одежда|Андерсьюты/костюмы|armor:BUL-H4')
Assert-True ($bulSuitQuestMigration -contains 'questCraftFamily|Броня/одежда|Сверхтяжёлая броня|armor:BUL-H4') 'Quest filters should migrate the old BUL-H4 suit path.'
$vendettaQuestMigration = Get-SCQuestSelectedFamilyOptionIds -SelectedOptions @('questCraftFamily|Оружие|Пулемёты|variant:Vendetta HMG')
Assert-True ($vendettaQuestMigration -contains 'questCraftFamily|Оружие|Тяжёлые пулемёты|variant:Vendetta HMG') 'Quest filters should migrate the old Vendetta machine-gun path.'
Assert-True ($miningLocationIndex.ContainsKey('RR_HUR_L1_desc')) 'Mining location index should map other Stanton R&R Lagrange stations, not only MIC-L5.'
$hurL1ShipResources = Format-SCMiningResourceEntriesForDisplay -Entries $miningLocationIndex['RR_HUR_L1_desc'].ResourcesByMethod[(Get-SCMiningShipCode)]
Assert-True ($hurL1ShipResources.Contains('Laranite 28.5%') -and $hurL1ShipResources.Contains('Corundum 17.8%')) 'HUR-L1 should receive the Lagrange A mining profile.'
$questCoolerFamilyBlock = "Quest\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n<EM4>Охладители:</EM4>\n- NightFall\n- SnowBlind"
$questCoolerFiltered = Select-SCQuestRewardBlockCategories -Value $questCoolerFamilyBlock -SelectedCategoryNames @('Корабельные компоненты') -SelectedFamilyOptionIds $snowBlindMergedQuestOptions -FamilyIndex $questFamilyIndex
Assert-True ($questCoolerFiltered.Contains('NightFall')) 'Merged cooler family should keep NightFall when old SnowBlind option is selected.'
Assert-True ($questCoolerFiltered.Contains('SnowBlind')) 'Merged cooler family should keep SnowBlind when old SnowBlind option is selected.'
Assert-True ((Get-SCQuestPossibleTitleKeys -DescriptionKey 'Foxwell_destroyprobe_M_desc_001') -contains 'Foxwell_destroyprobe_M_name_001') 'Quest blueprint marker cleanup should link _desc keys to _name keys.'
Assert-True (Test-SCQuestLooksLikeTitleKey -Key 'Foxwell_destroyprobe_M_name_001') 'Quest blueprint marker cleanup should treat _name keys as title-like keys.'
Assert-True ((Remove-SCQuestBlueprintTitleMarker -Value '[Ч] КОНТРАКТ ОРАНЖЕВОГО УРОВНЯ') -eq 'КОНТРАКТ ОРАНЖЕВОГО УРОВНЯ') 'Quest blueprint marker cleanup should remove [CH] marker from name values.'
Assert-True ((Remove-SCQuestBlueprintTitleMarker -Value '[Ч?] КОНТРАКТ ОРАНЖЕВОГО УРОВНЯ') -eq 'КОНТРАКТ ОРАНЖЕВОГО УРОВНЯ') 'Quest blueprint marker cleanup should remove [CH?] marker from name values.'
$mixedCargoTitleValues = @{
    'Covalex_HaulCargo_AToB_title' = '[Ч] РАНГ: ~mission(ReputationRank) - ПРЯМАЯ ГРУЗОПЕРЕВОЗКА ~mission(CargoGradeToken) ГРУЗА'
    'Covalex_HaulCargo_AToB_desc_01' = 'Обычная доставка без чертежей'
    'Covalex_HaulCargo_AtoB_desc_DeliverAll' = "Доставка\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n- XL-1"
}
$mixedCargoTitleMap = @{
    'Covalex_HaulCargo_AToB_title' = @{
        'Covalex_HaulCargo_AtoB_desc_DeliverAll' = $true
    }
}
$mixedMarkerStats = Update-SCQuestBlueprintTitleMarkerVisibility -Values $mixedCargoTitleValues -TitleDescriptionMap $mixedCargoTitleMap -TitleVisibility @{}
Assert-True (-not (Test-SCQuestHasBlueprintTitleMarker -Value $mixedCargoTitleValues['Covalex_HaulCargo_AToB_title'])) 'Quest blueprint marker cleanup should remove exact [CH] from mixed shared cargo titles.'
Assert-True (Test-SCQuestHasMixedBlueprintTitleMarker -Value $mixedCargoTitleValues['Covalex_HaulCargo_AToB_title']) 'Quest blueprint marker cleanup should add [CH?] to mixed shared cargo titles.'
Assert-True ([int]$mixedMarkerStats.Mixed -eq 1) 'Quest blueprint marker cleanup should report mixed shared cargo titles.'
$mixedCargoTitleValues['Covalex_HaulCargo_AToB_title'] = '[Ч] [Ч?] РАНГ: ~mission(ReputationRank) - ПРЯМАЯ ГРУЗОПЕРЕВОЗКА'
$null = Update-SCQuestBlueprintTitleMarkerVisibility -Values $mixedCargoTitleValues -TitleDescriptionMap $mixedCargoTitleMap -TitleVisibility @{}
Assert-True (-not (Test-SCQuestHasBlueprintTitleMarker -Value $mixedCargoTitleValues['Covalex_HaulCargo_AToB_title'])) 'Mixed shared titles should remove a stale exact marker on repeat apply.'
Assert-True (Test-SCQuestHasMixedBlueprintTitleMarker -Value $mixedCargoTitleValues['Covalex_HaulCargo_AToB_title']) 'Mixed shared titles should retain one mixed marker on repeat apply.'
$allRewardCargoTitleValues = @{
    'Covalex_HaulCargo_AToB_title' = '[Ч] РАНГ: ~mission(ReputationRank) - ПРЯМАЯ ГРУЗОПЕРЕВОЗКА ~mission(CargoGradeToken) ГРУЗА'
    'Covalex_HaulCargo_AToB_desc_01' = "Обычная доставка\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n- XL-1"
    'Covalex_HaulCargo_AtoB_desc_DeliverAll' = "Доставка\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n- XL-1"
}
$null = Update-SCQuestBlueprintTitleMarkerVisibility -Values $allRewardCargoTitleValues -TitleDescriptionMap $mixedCargoTitleMap -TitleVisibility @{}
Assert-True (Test-SCQuestHasBlueprintTitleMarker -Value $allRewardCargoTitleValues['Covalex_HaulCargo_AToB_title']) 'Quest blueprint marker cleanup should keep [CH] when all linked cargo descriptions have visible blueprint blocks.'
Assert-True (-not (Test-SCQuestHasMixedBlueprintTitleMarker -Value $allRewardCargoTitleValues['Covalex_HaulCargo_AToB_title'])) 'Quest blueprint marker cleanup should not keep [CH?] when all linked descriptions have visible blueprint blocks.'
$missingMarkerCargoTitleValues = @{
    'Covalex_HaulCargo_AToB_title' = 'РАНГ: ~mission(ReputationRank) - ПРЯМАЯ ГРУЗОПЕРЕВОЗКА ~mission(CargoGradeToken) ГРУЗА'
    'Covalex_HaulCargo_AToB_desc_01' = "Обычная доставка\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n- XL-1"
    'Covalex_HaulCargo_AtoB_desc_DeliverAll' = "Доставка\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n- XL-1"
}
$missingMarkerStats = Update-SCQuestBlueprintTitleMarkerVisibility -Values $missingMarkerCargoTitleValues -TitleDescriptionMap $mixedCargoTitleMap -TitleVisibility @{}
Assert-True (Test-SCQuestHasBlueprintTitleMarker -Value $missingMarkerCargoTitleValues['Covalex_HaulCargo_AToB_title']) 'Quest blueprint marker sync should add [CH] to titles when every linked description has visible blueprint blocks.'
Assert-True ([int]$missingMarkerStats.Added -eq 1) 'Quest blueprint marker sync should report added [CH] markers.'

$passportRecord = [pscustomobject]@{ blockLines = @('DPS 253 | урон 101.2', 'темп 150/мин | скорость 765 м/с') }
$itemWithUtilityBlocks = "Описание предмета\n\n<EM4>Wikelo заказы:</EM4>\n- 2 на Argo ATLS GEO IKTI\n\nКрафт: Titanium | Copper\n\nБазовые ТТХ (Erkul)\nDPS 253 | урон 101.2\nтемп 150/мин | скорость 765 м/с"
$itemPassOne = Set-SCMiningItemPassportBlock -Value $itemWithUtilityBlocks -Record $passportRecord
$itemPassOne = Set-SCMiningItemCraftHint -Value $itemPassOne -Resources @('Titanium', 'Copper')
$itemPassTwo = Set-SCMiningItemPassportBlock -Value $itemPassOne -Record $passportRecord
$itemPassTwo = Set-SCMiningItemCraftHint -Value $itemPassTwo -Resources @('Titanium', 'Copper')
Assert-True ($itemPassTwo -eq $itemPassOne) 'Mining item Wikelo/craft/passport blocks should be idempotent across repeated passes.'
Assert-True (($itemPassOne -split [regex]::Escape('Базовые ТТХ (Erkul)')).Count -eq 2) 'Mining item passport block should appear only once after craft hint normalization.'
$sharedMergeBaseOperation = [pscustomobject]@{
    ModuleId = 'mining'
    OptionId = 'itemPassports'
    Key = 'item_Test_Desc'
    Operation = 'replaceValue'
    OriginalValue = 'Описание'
    NewValue = "Описание\n\n<EM4>Wikelo заказы:</EM4>\n- 1 на тест\n\nКрафт: Titanium | Copper\n\nБазовые ТТХ (Erkul)\nDPS 10"
    OwnedMarkers = @('SC_ITEM_PASSPORT_BLOCK')
}
$sharedMergeWikeloCleanup = [pscustomobject]@{
    ModuleId = 'quest'
    OptionId = 'questRewards'
    Key = 'item_Test_Desc'
    Operation = 'replaceValue'
    OriginalValue = $sharedMergeBaseOperation.NewValue
    NewValue = 'Описание'
    OwnedMarkers = @('SCMDB_WIKELO_ITEM_HINT')
}
$sharedMergeResult = @(Merge-SCComposableModuleOperations -Operations @($sharedMergeBaseOperation, $sharedMergeWikeloCleanup))
Assert-True ($sharedMergeResult.Count -eq 1) 'Shared Wikelo merge should compose mining and quest item operations.'
Assert-True (-not ([string]$sharedMergeResult[0].NewValue).Contains('Wikelo заказы')) 'Shared Wikelo merge should remove only the Wikelo block when quest cleanup is disabled.'
Assert-True (([string]$sharedMergeResult[0].NewValue).Contains('Крафт: Titanium | Copper')) 'Shared Wikelo merge should preserve mining craft hints after Wikelo cleanup.'
Assert-True (([string]$sharedMergeResult[0].NewValue).Contains('Базовые ТТХ (Erkul)')) 'Shared Wikelo merge should preserve Erkul passport hints after Wikelo cleanup.'
$noOpMergeResult = @(Merge-SCPatchOperations -SharedOperations @() -ModuleOperations @([pscustomobject]@{
    ModuleId = 'mining+quest'
    OptionId = 'itemCraftHints+questRewards'
    Key = 'item_NoOp_Desc'
    Operation = 'replaceValue'
    OriginalValue = 'unchanged'
    NewValue = 'unchanged'
    OwnedMarkers = @()
}))
Assert-True ($noOpMergeResult.Count -eq 0) 'Final patch merge should discard composed replace operations that do not change the value.'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-mod-launcher-test-" + [guid]::NewGuid().ToString('N'))
$liveRoot = Join-Path $tempRoot 'LIVE'
$localizationDir = Join-Path $liveRoot 'data\Localization\korean_(south_korea)'
$globalIni = Join-Path $localizationDir 'global.ini'
$reports = Join-Path $tempRoot 'reports'
$backups = Join-Path $tempRoot 'backups'

New-Item -ItemType Directory -Force -Path $localizationDir | Out-Null

$encoding = New-Object System.Text.UTF8Encoding($true)

$reputationTitleLive = Join-Path $tempRoot 'RepTitle\LIVE'
$reputationTitleLoc = Join-Path $reputationTitleLive 'data\Localization\korean_(south_korea)'
$reputationTitleGlobal = Join-Path $reputationTitleLoc 'global.ini'
$reputationTitleReport = Join-Path $tempRoot 'rep-title-report.json'
New-Item -ItemType Directory -Force -Path $reputationTitleLoc | Out-Null
[System.IO.File]::WriteAllLines($reputationTitleGlobal, @(
    'northrock_bounty_fps_title_001=ОХОТА ЗА ГОЛОВАМИ: ~mission(TargetName) (ВЫСОКАЯ ОПАСНОСТЬ)',
    'northrock_bounty_fps_UGF_boss_desc_001=Здравствуйте',
    'northrock_bounty_fps_UGF_boss_nocivs_desc_001=Здравствуйте'
), $encoding)
& $questEngineScript -GlobalIniPath $reputationTitleGlobal -NoBackup -NoCraftIntel -ReportPath $reputationTitleReport | Out-Null
$reputationTitleLine = [System.IO.File]::ReadAllLines($reputationTitleGlobal, $encoding) |
    Where-Object { $_ -like 'northrock_bounty_fps_title_001=*' } |
    Select-Object -First 1
Assert-True ($reputationTitleLine.Contains('[4K/8K]')) 'Shared reputation title should show compact possible amounts instead of generic REP.'
Assert-True (-not $reputationTitleLine.Contains('[РЕП]')) 'Shared reputation title should not fall back to generic REP when possible amounts fit.'
Assert-True ($reputationTitleLine -match 'ОПАСНОСТЬ\) \[4K/8K\]$') 'Shared reputation title marker should be appended after the mission title.'
$oldOrderValue = Remove-ReputationTitleMarker -Value '[4K/8K] [Ч] [А] [С] СТАРЫЙ ПОРЯДОК'
Assert-True ($oldOrderValue -eq '[Ч] [А] [С] СТАРЫЙ ПОРЯДОК') 'Reputation cleanup should remove legacy prefix markers before title markers.'
$newOrderValue = Remove-ReputationTitleMarker -Value '[Ч] [А] [С] НОВЫЙ ПОРЯДОК [4K/8K]'
Assert-True ($newOrderValue -eq '[Ч] [А] [С] НОВЫЙ ПОРЯДОК') 'Reputation cleanup should remove new suffix markers while preserving title markers.'
$styledOldOrderValue = Remove-ReputationTitleMarker -Value '<EM4>[4K/8K]</EM4> <EM4>[Ч]</EM4> [А] [С] СТАРЫЙ ПОРЯДОК'
Assert-True ($styledOldOrderValue -eq '<EM4>[Ч]</EM4> [А] [С] СТАРЫЙ ПОРЯДОК') 'Reputation cleanup should remove styled legacy prefix markers.'
$titleInfoWithAllMarkers = @{
    HasBlueprint = $true
    HasAcePilot = $true
    HasScrip = $true
    ReputationAmounts = @{ '4000' = $true; '8000' = $true }
}
$titleMarkersWithFocus = Format-TitleMarkers -TitleInfo $titleInfoWithAllMarkers
$reputationMarkerWithFocus = Format-ReputationTitleMarker -TitleInfo $titleInfoWithAllMarkers
$titleWithFocusMarkers = "$titleMarkersWithFocus ОХОТА ЗА ГОЛОВАМИ $reputationMarkerWithFocus"
Assert-True ($titleWithFocusMarkers -eq '[Ч] <EM4>[А]</EM4> [С] ОХОТА ЗА ГОЛОВАМИ [4K/8K]') 'Title composition should keep [CH][A][S] before the title and reputation after the title.'
$titleInfoWithBlueprintMarker = @{
    HasBlueprint = $true
    HasAcePilot = $false
    HasScrip = $false
    ReputationAmounts = @{ '4000' = $true }
}
$titleInfoWithoutBlueprintMarker = @{
    HasBlueprint = $false
    HasAcePilot = $false
    HasScrip = $false
    ReputationAmounts = @{ '4000' = $true }
}
$titleWithBlueprintMarker = "$(Format-TitleMarkers -TitleInfo $titleInfoWithBlueprintMarker) ОХОТА ЗА ГОЛОВАМИ $(Format-ReputationTitleMarker -TitleInfo $titleInfoWithBlueprintMarker)"
$titleWithoutBlueprintMarker = "ОХОТА ЗА ГОЛОВАМИ $(Format-ReputationTitleMarker -TitleInfo $titleInfoWithoutBlueprintMarker)"
Assert-True ($titleWithBlueprintMarker -eq '[Ч] ОХОТА ЗА ГОЛОВАМИ [4K]') 'Blueprint title marker should stay before the title when reputation is appended.'
Assert-True ($titleWithoutBlueprintMarker -eq 'ОХОТА ЗА ГОЛОВАМИ [4K]') 'Disabling blueprint title marker should not affect reputation suffix.'

$reputationCargoLive = Join-Path $tempRoot 'RepCargo\LIVE'
$reputationCargoLoc = Join-Path $reputationCargoLive 'data\Localization\korean_(south_korea)'
$reputationCargoGlobal = Join-Path $reputationCargoLoc 'global.ini'
$reputationCargoReport = Join-Path $tempRoot 'rep-cargo-report.json'
New-Item -ItemType Directory -Force -Path $reputationCargoLoc | Out-Null
[System.IO.File]::WriteAllLines($reputationCargoGlobal, @(
    'Covalex_HaulCargo_SingleToMulti_title=РАНГ: ~mission(ReputationRank) - ГРУЗОПЕРЕВОЗКА МАЛОГАБАРИТНОГО ГРУЗА',
    'Covalex_HaulCargo_SingleToMulti_desc_03=Здравствуйте, generic cargo text'
), $encoding)
& $questEngineScript -GlobalIniPath $reputationCargoGlobal -NoBackup -NoCraftIntel -ReportPath $reputationCargoReport | Out-Null
$reputationCargoDescLine = [System.IO.File]::ReadAllLines($reputationCargoGlobal, $encoding) |
    Where-Object { $_ -like 'Covalex_HaulCargo_SingleToMulti_desc_03=*' } |
    Select-Object -First 1
Assert-True ($reputationCargoDescLine.Contains('<EM4>Репутация по вариантам</EM4>:')) 'Generic Covalex cargo descriptions should receive inferred reputation blocks from SCMDB title family.'
Assert-True ($reputationCargoDescLine.Contains('50/500/1K/2K')) 'Generic Covalex cargo reputation block should include SCMDB variant amounts.'
Assert-True ($reputationCargoDescLine.Contains('Здравствуйте, generic cargo text')) 'Inferred cargo reputation block should preserve original description text.'
$reputationCargoTitleLine = [System.IO.File]::ReadAllLines($reputationCargoGlobal, $encoding) |
    Where-Object { $_ -like 'Covalex_HaulCargo_SingleToMulti_title=*' } |
    Select-Object -First 1
Assert-True ($reputationCargoTitleLine.Contains('[РЕП]')) 'Generic Covalex cargo title should keep a reputation marker while linked descriptions carry the exact amounts.'

$reputationRiskLive = Join-Path $tempRoot 'RepRisk\LIVE'
$reputationRiskLoc = Join-Path $reputationRiskLive 'data\Localization\korean_(south_korea)'
$reputationRiskGlobal = Join-Path $reputationRiskLoc 'global.ini'
$reputationRiskReport = Join-Path $tempRoot 'rep-risk-report.json'
New-Item -ItemType Directory -Force -Path $reputationRiskLoc | Out-Null
[System.IO.File]::WriteAllLines($reputationRiskGlobal, @(
    'bhg_bounty_desc_gen_001=Base bounty text'
), $encoding)
& (Join-Path $questEngineRoot 'SC_Quest_Recipe_Engine.ps1') -GlobalIniPath $reputationRiskGlobal -NoBackup -NoCraftIntel -ReportPath $reputationRiskReport | Out-Null
$reputationRiskLine = [System.IO.File]::ReadAllLines($reputationRiskGlobal, $encoding) |
    Where-Object { $_ -like 'bhg_bounty_desc_gen_001=*' } |
    Select-Object -First 1
Assert-True ($reputationRiskLine.Contains('очень низкая 500 / низкая 1K / умеренная 2K / высокая 2K / очень высокая 8K / экстремальная 16K')) 'BHG risk-split reputation block should use Russian risk labels.'
Assert-True (-not $reputationRiskLine.Contains('Low 1K')) 'BHG risk-split reputation block should not use English Low label.'

$reputationToggleLive = Join-Path $tempRoot 'RepToggle\LIVE'
$reputationToggleLoc = Join-Path $reputationToggleLive 'data\Localization\korean_(south_korea)'
$reputationToggleGlobal = Join-Path $reputationToggleLoc 'global.ini'
$reputationToggleReports = Join-Path $tempRoot 'rep-toggle-reports'
$reputationToggleBackups = Join-Path $tempRoot 'rep-toggle-backups'
New-Item -ItemType Directory -Force -Path $reputationToggleLoc | Out-Null
$reputationToggleLines = New-Object System.Collections.Generic.List[string]
$reputationToggleLines.Add('northrock_bounty_fps_title_001=[4K/8K] [Ч] ОХОТА ЗА ГОЛОВАМИ: ~mission(TargetName) (ВЫСОКАЯ ОПАСНОСТЬ)')
$reputationToggleLines.Add('northrock_bounty_fps_UGF_boss_desc_001=Здравствуйте')
$reputationToggleLines.Add('northrock_bounty_fps_UGF_boss_nocivs_desc_001=Здравствуйте')
for ($dummyIndex = 0; $dummyIndex -lt 1001; $dummyIndex++) {
    $reputationToggleLines.Add(("dummy_key_{0:0000}=dummy value" -f $dummyIndex))
}
[System.IO.File]::WriteAllLines($reputationToggleGlobal, $reputationToggleLines, $encoding)
$reputationToggleEnabled = @{ mining = @(); quest = @('reputationHints', 'shipComponents') }
$reputationToggleDisabled = @{ mining = @(); quest = @('shipComponents') }
$reputationToggleApply = Invoke-SCModPatch -LivePath $reputationToggleLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $reputationToggleEnabled -ReportDirectory $reputationToggleReports -BackupDirectory $reputationToggleBackups
Assert-True ($reputationToggleApply.Report.writeSucceeded -eq $true) 'Reputation toggle migration should write fixture file.'
$reputationTogglePatched = [System.IO.File]::ReadAllLines($reputationToggleGlobal, $encoding) |
    Where-Object { $_ -like 'northrock_bounty_fps_title_001=*' } |
    Select-Object -First 1
Assert-True ($reputationTogglePatched -eq 'northrock_bounty_fps_title_001=ОХОТА ЗА ГОЛОВАМИ: ~mission(TargetName) (ВЫСОКАЯ ОПАСНОСТЬ) [4K/8K]') 'Reputation toggle should migrate legacy prefix reputation after the title.'
$reputationToggleRepeat = Invoke-SCModPatch -LivePath $reputationToggleLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $reputationToggleEnabled -ReportDirectory $reputationToggleReports -BackupDirectory $reputationToggleBackups -DryRun
Assert-True ([int]$reputationToggleRepeat.Report.changedLines -eq 0) 'Reputation suffix title marker should be idempotent with [CH].'
$reputationToggleRemove = Invoke-SCModPatch -LivePath $reputationToggleLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $reputationToggleDisabled -ReportDirectory $reputationToggleReports -BackupDirectory $reputationToggleBackups
Assert-True ($reputationToggleRemove.Report.writeSucceeded -eq $true) 'Disabled reputation option should remove suffix reputation marker.'
$reputationToggleRemoved = [System.IO.File]::ReadAllLines($reputationToggleGlobal, $encoding) |
    Where-Object { $_ -like 'northrock_bounty_fps_title_001=*' } |
    Select-Object -First 1
Assert-True ($reputationToggleRemoved -eq 'northrock_bounty_fps_title_001=ОХОТА ЗА ГОЛОВАМИ: ~mission(TargetName) (ВЫСОКАЯ ОПАСНОСТЬ)') 'Disabled reputation option should remove reputation suffix.'
$reputationToggleReapply = Invoke-SCModPatch -LivePath $reputationToggleLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $reputationToggleEnabled -ReportDirectory $reputationToggleReports -BackupDirectory $reputationToggleBackups
Assert-True ($reputationToggleReapply.Report.writeSucceeded -eq $true) 'Re-enabled reputation option should restore suffix reputation marker.'
$reputationToggleRestored = [System.IO.File]::ReadAllLines($reputationToggleGlobal, $encoding) |
    Where-Object { $_ -like 'northrock_bounty_fps_title_001=*' } |
    Select-Object -First 1
Assert-True ($reputationToggleRestored -eq $reputationTogglePatched) 'Re-enabled reputation option should restore the same [CH] title plus reputation suffix.'

$cleanStateIni = Join-Path $tempRoot 'clean-state.ini'
$patchedStateIni = Join-Path $tempRoot 'patched-state.ini'
[System.IO.File]::WriteAllLines($cleanStateIni, @("Mining_Raw_desc=Base text\n\n$rawShipHeader\nIron"), $encoding)
[System.IO.File]::WriteAllLines($patchedStateIni, @("Mining_Patched_desc=Base text\n\n$craftHeader\n<EM4>Корабль</EM4>\nIron"), $encoding)
Write-SCBackupMetadata -BackupPath $cleanStateIni
Write-SCBackupMetadata -BackupPath $patchedStateIni
$cleanStateMetadata = Get-Content -LiteralPath "$cleanStateIni.meta.json" -Encoding UTF8 -Raw | ConvertFrom-Json
$patchedStateMetadata = Get-Content -LiteralPath "$patchedStateIni.meta.json" -Encoding UTF8 -Raw | ConvertFrom-Json
Assert-True ([string]$cleanStateMetadata.kind -eq 'clean') 'Raw SCMDB mining resource file should be marked clean.'
Assert-True ([string]$patchedStateMetadata.kind -eq 'patched') 'Launcher craft hint file should be marked patched.'

$initialLines = @(
    'Broken_Key=<EM4>~mission(Destination|Address)<EM4>',
    'Empty_Key=',
    'Normal_Key=ok',
    "Mining_Test_desc=Base text\n\n$craftHeader\n$fullLegend\n<EM4>Test Category</EM4>\n- Test Recipe: <EM4>[$shipCode]</EM4> Iron | [$groundCode] Beradon | [$handCode] Hadanite",
    "Mining_Raw_desc=Base text\n\n$rawShipHeader\nIron\n$rawGroundHeader\nBeradon\n$rawHandHeader\nHadanite\n$rawCollectableHeader\nFruit"
)
[System.IO.File]::WriteAllLines($globalIni, $initialLines, $encoding)
$initialHash = (Get-FileHash -LiteralPath $globalIni -Algorithm SHA256).Hash

$allQuestOptions = @('shipComponents', 'shipWeapons', 'armorAndClothing', 'fpsWeapons', 'equipmentAndConsumables')
$standardMiningCraftFilters = @('componentClassMilitary', 'componentClassStealth', 'shipWeaponEnergy', 'shipWeaponBallistic', 'armorHeavy', 'armorMedium', 'fpsRifles', 'fpsSniperRifles', 'fpsSmgs', 'fpsLmgs')
$allMethods = @{ mining = @('shipMining', 'groundVehicleMining', 'multitoolMining') + $standardMiningCraftFilters; quest = $allQuestOptions }
$shipOnly = @{ mining = @('shipMining') + $standardMiningCraftFilters; quest = $allQuestOptions }

$dryRun = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $allMethods -ReportDirectory $reports -BackupDirectory $backups -DryRun
Assert-True ($dryRun.Report.dryRun -eq $true) 'Dry-run report should be marked dryRun.'
Assert-True ($dryRun.Report.writeAttempted -eq $false) 'Dry-run must not attempt writes.'
Assert-True ([int]$dryRun.Report.fixedMalformedEmphasisLines -eq 0) 'Dry-run should not run RuSC EM repair from module apply.'
Assert-True ([int]$dryRun.Report.changedLines -eq 2) 'Dry-run should preview only mining fixture changes.'
Assert-True ((Get-FileHash -LiteralPath $globalIni -Algorithm SHA256).Hash -eq $initialHash) 'Dry-run must not change fixture file.'

$apply = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $allMethods -ReportDirectory $reports -BackupDirectory $backups
Assert-True ($apply.Report.dryRun -eq $false) 'Apply report should not be marked dryRun.'
Assert-True ($apply.Report.writeAttempted -eq $true) 'Apply should attempt write when changes exist.'
Assert-True ($apply.Report.writeSucceeded -eq $true) 'Apply should succeed.'
Assert-True ([int]$apply.Report.fixedMalformedEmphasisLines -eq 0) 'Apply should not report RuSC EM repair from module apply.'
Assert-True ([int]$apply.Report.changedLines -eq 2) 'Apply should change only two mining fixture lines.'
Assert-True (-not [string]::IsNullOrWhiteSpace($apply.Report.backupPath)) 'Apply should create backup path.'
Assert-True (Test-Path -LiteralPath $apply.Report.backupPath -PathType Leaf) 'Backup file should exist.'
$applyBackupMetadataPath = "$($apply.Report.backupPath).meta.json"
Assert-True (Test-Path -LiteralPath $applyBackupMetadataPath -PathType Leaf) 'Apply backup metadata should exist.'
$applyBackupMetadata = Get-Content -LiteralPath $applyBackupMetadataPath -Encoding UTF8 -Raw | ConvertFrom-Json
Assert-True ([string]$applyBackupMetadata.kind -eq 'patched') 'Backup made from already patched fixture should be marked patched.'

$patched = [System.IO.File]::ReadAllText($globalIni, $encoding)
Assert-True ($patched.Contains('<EM4>~mission(Destination|Address)<EM4>')) 'Module apply should leave RuSC EM repair to localization install/update.'

$allMethodsDryRun = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $allMethods -ReportDirectory $reports -BackupDirectory $backups -DryRun
Assert-True ([int]$allMethodsDryRun.Report.changedLines -eq 0) 'All mining methods selected should be a no-op after EM repair.'

$shipOnlyDryRun = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $shipOnly -ReportDirectory $reports -BackupDirectory $backups -DryRun
Assert-True ([int]$shipOnlyDryRun.Report.changedLines -eq 1) 'Ship-only mining filter should preview one changed legacy fixture line.'
Assert-True ([int]$shipOnlyDryRun.Report.moduleOperationCount -eq 1) 'Ship-only mining filter should produce one module operation for the legacy fixture.'

$shipOnlyApply = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $shipOnly -ReportDirectory $reports -BackupDirectory $backups
Assert-True ($shipOnlyApply.Report.writeSucceeded -eq $true) 'Ship-only mining apply should write fixture file.'
Assert-True ([int]$shipOnlyApply.Report.changedLines -eq 1) 'Ship-only mining apply should change one legacy fixture line.'
$shipOnlyBackupMetadataPath = "$($shipOnlyApply.Report.backupPath).meta.json"
Assert-True (Test-Path -LiteralPath $shipOnlyBackupMetadataPath -PathType Leaf) 'Patched apply backup metadata should exist.'
$shipOnlyBackupMetadata = Get-Content -LiteralPath $shipOnlyBackupMetadataPath -Encoding UTF8 -Raw | ConvertFrom-Json
Assert-True ([string]$shipOnlyBackupMetadata.kind -eq 'patched') 'Backup made from an already patched file should be marked patched.'

$shipPatched = [System.IO.File]::ReadAllText($globalIni, $encoding)
Assert-True (-not $shipPatched.Contains($legendPrefix)) 'Ship-only mining apply should remove mining legend.'
Assert-True (-not $shipPatched.Contains("[$groundCode] Beradon")) 'Ship-only mining apply should remove ground method fragment.'
Assert-True (-not $shipPatched.Contains("[$handCode] Hadanite")) 'Ship-only mining apply should remove hand method fragment.'
Assert-True ($shipPatched.Contains('Наземная техника')) 'Ship-only raw resource block should keep ground resources as reference.'
Assert-True ($shipPatched.Contains('Мультитул')) 'Ship-only raw resource block should keep hand resources as reference.'

$repeatShipOnly = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $shipOnly -ReportDirectory $reports -BackupDirectory $backups -DryRun
Assert-True ([int]$repeatShipOnly.Report.changedLines -eq 0) 'Ship-only mining filter should be idempotent.'

$allMethodsAfterShipOnly = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $allMethods -ReportDirectory $reports -BackupDirectory $backups -DryRun
Assert-True ([int]$allMethodsAfterShipOnly.Report.changedLines -eq 1) 'All-method mining filter should restore detailed recipes after ship-only filtering.'
Assert-True ([int]$allMethodsAfterShipOnly.Report.moduleOperationCount -eq 1) 'All-method mining filter should produce one restore operation after ship-only filtering.'

$allMethodsRestore = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $allMethods -ReportDirectory $reports -BackupDirectory $backups
Assert-True ($allMethodsRestore.Report.writeSucceeded -eq $true) 'All-method mining filter should write the restored detailed recipe block.'
$allRestored = [System.IO.File]::ReadAllText($globalIni, $encoding)
Assert-True (-not $allRestored.Contains($legendPrefix)) 'All-method restore should keep the new legend-free mining format.'
Assert-True ($allRestored.Contains('Наземная техника')) 'All-method restore should keep ground section.'
Assert-True ($allRestored.Contains('Мультитул')) 'All-method restore should keep hand section.'
Assert-True ($allRestored.Contains('- Demeco LMG: Hadanite')) 'All-method restore should bring back detailed multitool recipes when recipe map is available.'

$refineryLive = Join-Path $tempRoot 'Refinery\LIVE'
$refineryLoc = Join-Path $refineryLive 'data\Localization\korean_(south_korea)'
$refineryGlobalIni = Join-Path $refineryLoc 'global.ini'
$refineryReports = Join-Path $tempRoot 'refinery-reports'
$refineryBackups = Join-Path $tempRoot 'refinery-backups'
New-Item -ItemType Directory -Force -Path $refineryLoc | Out-Null
[System.IO.File]::WriteAllLines($refineryGlobalIni, @(
    'ARC_L1_station=ARC-L1 Wide Forest Station',
    'ARC_L1_station_desc=Located at ArcCorp L1. This description does not repeat the full station name.',
    'RR_CRU_L1=CRU-L1 Ambitious Dream Station',
    'RR_CRU_L1_desc=Rest & Relax Ambitious Dream offers many services and has a refinery deck.',
    'RR_HUR_L1=HUR-L1 Green Glade Station',
    'RR_HUR_L1_desc=Rest & Relax Green Glade offers many services and has a refinery deck.',
    'RR_P2_L4=Checkmate',
    'RR_P2_L4_desc=Checkmate station card.',
    'Pyro_ruinstation,P=Ruin Station',
    'Pyro_ruinstation_desc=Gold Horizon platform above Pyro VI.',
    'text_level_info_description_Levski=Levski in-game location card.',
    'ui_pregame_port_Levski_name=Levski',
    'ui_pregame_port_Levski_desc=Levski pregame location card.',
    'ui_pregame_port_Checkmate_name=Checkmate',
    'ui_pregame_port_Checkmate_desc=Checkmate pregame location card.',
    'ui_pregame_port_Orbituary_name=Orbituary',
    'ui_pregame_port_Orbituary_desc=Orbituary pregame location card.',
    'CleanAir_Levski_desc=This contract mentions Levski but is not a location card.',
    'GoblinG_Crusader_ResourceGathering_Desc=This contract recommends station CRU-L1 Ambitious Dream but is not a location card.',
    'Non_Refinery_desc=Regular station without refinery bonuses.',
    'Eckhart_ShipAmbush_E_desc=Ship ambush contract text.\n'
), $encoding)
$refineryEnabled = @{ mining = @('refineryYieldHints'); quest = @('reputationHints') + $allQuestOptions }
$refineryDisabled = @{ mining = @(); quest = @('reputationHints') + $allQuestOptions }
$refineryApply = Invoke-SCModPatch -LivePath $refineryLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $refineryEnabled -ReportDirectory $refineryReports -BackupDirectory $refineryBackups
Assert-True ($refineryApply.Report.writeSucceeded -eq $true) 'Refinery yield apply should write fixture file.'
Assert-True ([int]$refineryApply.Report.conflictCount -eq 0) 'Refinery yield apply should not conflict with quest reputation hints on unrelated descriptions.'
Assert-True ([int]$refineryApply.Report.changedLines -eq 9) 'Refinery yield apply should change only linked station-card descriptions.'
Assert-True (@($refineryApply.Report.operations | Where-Object { [string]$_.Key -eq 'Eckhart_ShipAmbush_E_desc' }).Count -eq 0) 'Refinery yield apply should not trim or claim unrelated quest descriptions.'
Assert-True (@($refineryApply.Report.operations | Where-Object { [string]$_.Key -eq 'CleanAir_Levski_desc' }).Count -eq 0) 'Refinery yield apply should not claim quest descriptions that merely mention Levski.'
Assert-True (@($refineryApply.Report.operations | Where-Object { [string]$_.Key -eq 'GoblinG_Crusader_ResourceGathering_Desc' }).Count -eq 0) 'Refinery yield apply should not claim quest descriptions that recommend a refinery station.'
$refineryPatched = [System.IO.File]::ReadAllText($refineryGlobalIni, $encoding)
Assert-True ($refineryPatched.Contains($refineryYieldLabel)) 'Refinery yield apply should add UEX refinery label.'
Assert-True ($refineryPatched.Contains("<EM4>$refineryBonusLabel</EM4>")) 'Refinery yield apply should highlight bonuses label.'
Assert-True ($refineryPatched.Contains("<EM4>$refineryPenaltyLabel</EM4>")) 'Refinery yield apply should highlight penalties label.'
Assert-True ($refineryPatched.Contains('Quartz +11%')) 'Refinery yield apply should add ARC-L1 bonus.'
Assert-True ($refineryPatched.Contains('Taranite -6%')) 'Refinery yield apply should add ARC-L1 penalty.'
Assert-True ($refineryPatched.Contains('Beryl +7%')) 'Refinery yield apply should add CRU-L1 bonus.'
Assert-True ($refineryPatched.Contains('Titanium -1%')) 'Refinery yield apply should include CRU-L1 non-top penalty.'
Assert-True ($refineryPatched.Contains('Hephaestanite -2%')) 'Refinery yield apply should include CRU-L1 full material profile.'
Assert-True ($refineryPatched.Contains('Tungsten +4%')) 'Refinery yield apply should add HUR-L1 bonus.'
Assert-True ($refineryPatched.Contains('Bexalite -2%')) 'Refinery yield apply should include HUR-L1 low penalty.'
Assert-True ($refineryPatched.Contains('Aluminum -4%')) 'Refinery yield apply should include HUR-L1 full material profile.'
Assert-True ($refineryPatched.Contains('Iron -5%')) 'Refinery yield apply should include HUR-L1 non-top penalty.'
Assert-True ($refineryPatched.Contains('RR_P2_L4_desc=Checkmate station card.\n\n<EM4>Переработка (UEX)</EM4>\n<EM4>бонусы:</EM4>')) 'Refinery yield apply should add Checkmate bonus block.'
Assert-True ($refineryPatched.Contains('Pyro_ruinstation_desc=Gold Horizon platform above Pyro VI.\n\n<EM4>Переработка (UEX)</EM4>\n<EM4>бонусы:</EM4>')) 'Refinery yield apply should add Ruin Station bonus block.'
Assert-True ($refineryPatched.Contains('text_level_info_description_Levski=Levski in-game location card.\n\n<EM4>Переработка (UEX)</EM4>\n<EM4>бонусы:</EM4>')) 'Refinery yield apply should add Levski in-game location card bonus block.'
Assert-True ($refineryPatched.Contains('ui_pregame_port_Levski_desc=Levski pregame location card.\n\n<EM4>Переработка (UEX)</EM4>\n<EM4>бонусы:</EM4>')) 'Refinery yield apply should add Levski pregame location card bonus block.'
Assert-True ($refineryPatched.Contains('ui_pregame_port_Checkmate_desc=Checkmate pregame location card.\n\n<EM4>Переработка (UEX)</EM4>\n<EM4>бонусы:</EM4>')) 'Refinery yield apply should add Checkmate pregame location card bonus block.'
Assert-True ($refineryPatched.Contains('ui_pregame_port_Orbituary_desc=Orbituary pregame location card.\n\n<EM4>Переработка (UEX)</EM4>\n<EM4>бонусы:</EM4>')) 'Refinery yield apply should add Orbituary pregame location card bonus block.'
Assert-True (-not ($refineryPatched -match 'CleanAir_Levski_desc=.*Переработка \(UEX\)')) 'Refinery yield apply should leave Levski quest text clean.'
Assert-True (-not ($refineryPatched -match 'GoblinG_Crusader_ResourceGathering_Desc=.*Переработка \(UEX\)')) 'Refinery yield apply should leave refinery-recommendation quest text clean.'
Assert-True (-not $refineryPatched.Contains('Non_Refinery_desc=Regular station without refinery bonuses.\n\n')) 'Refinery yield apply should not touch unrelated station description.'

$refineryRepeat = Invoke-SCModPatch -LivePath $refineryLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $refineryEnabled -ReportDirectory $refineryReports -BackupDirectory $refineryBackups -DryRun
Assert-True ([int]$refineryRepeat.Report.changedLines -eq 0) 'Refinery yield apply should be idempotent while enabled.'

$refineryRemove = Invoke-SCModPatch -LivePath $refineryLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $refineryDisabled -ReportDirectory $refineryReports -BackupDirectory $refineryBackups
Assert-True ($refineryRemove.Report.writeSucceeded -eq $true) 'Disabled refinery yield option should write cleanup fixture file.'
Assert-True ([int]$refineryRemove.Report.changedLines -eq 9) 'Disabled refinery yield option should remove station hints.'
$refineryCleaned = [System.IO.File]::ReadAllText($refineryGlobalIni, $encoding)
Assert-True (-not $refineryCleaned.Contains($refineryYieldLabel)) 'Disabled refinery yield option should remove UEX refinery label.'
Assert-True ($refineryCleaned.Contains('ARC_L1_station_desc=Located at ArcCorp L1. This description does not repeat the full station name.')) 'Disabled refinery yield option should preserve base station description.'

$rawOreBuyLabel = 'Скупка сырой руды (UEX, ориентир)'
$rawOreBuyLegacyLabel = 'Торговля (UEX, ориентир)'
$rawOreBuyLive = Join-Path $tempRoot 'RawOreBuy\LIVE'
$rawOreBuyLoc = Join-Path $rawOreBuyLive 'data\Localization\korean_(south_korea)'
$rawOreBuyGlobalIni = Join-Path $rawOreBuyLoc 'global.ini'
$rawOreBuyReports = Join-Path $tempRoot 'raw-ore-buy-reports'
$rawOreBuyBackups = Join-Path $tempRoot 'raw-ore-buy-backups'
New-Item -ItemType Directory -Force -Path $rawOreBuyLoc | Out-Null
[System.IO.File]::WriteAllLines($rawOreBuyGlobalIni, @(
    'RR_CRU_L1=CRU-L1 Ambitious Dream Station',
    'RR_CRU_L1_desc=CRU-L1 test station card.',
    'ui_pregame_port_Levski_name=Levski',
    'ui_pregame_port_Levski_desc=Levski pregame location card.',
    'ui_pregame_port_Area18_name=Area 18',
    'ui_pregame_port_Area18_desc=Area 18 city card.\n\n<EM4>Торговля (UEX, ориентир)</EM4>\n<EM4>Покупают:</EM4> Agricium 10k\n<EM4>Продают:</EM4> Methane 3,03k',
    'ArcCorpMining045,P=ArcCorp Mining Area 045',
    'ArcCorpMining045_desc=ArcCorp Mining Area 045 outpost card.'
), $encoding)
$rawOreBuyEnabled = @{ mining = @('refineryYieldHints', 'rawOreBuyHints'); quest = @('reputationHints') + $allQuestOptions }
$rawOreBuyDisabled = @{ mining = @(); quest = @('reputationHints') + $allQuestOptions }
$rawOreBuyApply = Invoke-SCModPatch -LivePath $rawOreBuyLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $rawOreBuyEnabled -ReportDirectory $rawOreBuyReports -BackupDirectory $rawOreBuyBackups
Assert-True ($rawOreBuyApply.Report.writeSucceeded -eq $true) 'Raw ore buy apply should write fixture file.'
Assert-True ([int]$rawOreBuyApply.Report.conflictCount -eq 0) 'Raw ore buy apply should not conflict with unrelated descriptions.'
Assert-True ([int]$rawOreBuyApply.Report.changedLines -eq 3) 'Raw ore buy apply should change linked station descriptions and clean legacy trade block.'
$rawOreBuyPatched = [System.IO.File]::ReadAllText($rawOreBuyGlobalIni, $encoding)
Assert-True ($rawOreBuyPatched.Contains($rawOreBuyLabel)) 'Raw ore buy apply should add UEX raw ore label.'
Assert-True ($rawOreBuyPatched.Contains('RR_CRU_L1_desc=CRU-L1 test station card.\n\n<EM4>Крафт-подсказка (SCMDB)</EM4>') -and $rawOreBuyPatched.Contains('Titanium 28.5%') -and $rawOreBuyPatched.Contains('<EM4>Переработка (UEX)</EM4>')) 'Raw ore buy apply should patch CRU-L1 station card with Lagrange resources before refinery block.'
Assert-True ($rawOreBuyPatched.Contains('Agricium 1,04k')) 'Raw ore buy apply should add CRU-L1 raw ore buy list.'
Assert-True ($rawOreBuyPatched.Contains('<EM4>Руда:</EM4> Quantainium 6,45k, Taranite 5,53k, Bexalite 5,21k')) 'Raw ore buy list should be sorted by price descending.'
Assert-True ($rawOreBuyPatched.Contains('ui_pregame_port_Levski_desc=Levski pregame location card.\n\n<EM4>Переработка (UEX)</EM4>')) 'Combined refinery/raw ore apply should start Levski card with refinery block.'
Assert-True ($rawOreBuyPatched.Contains('Ice +10%')) 'Combined refinery/raw ore apply should include Levski refinery bonus.'
Assert-True ($rawOreBuyPatched.Contains('<EM4>Скупка сырой руды (UEX, ориентир)</EM4>')) 'Combined refinery/raw ore apply should include raw ore block after refinery block.'
Assert-True ($rawOreBuyPatched.IndexOf('<EM4>Переработка (UEX)</EM4>') -lt $rawOreBuyPatched.IndexOf('<EM4>Скупка сырой руды (UEX, ориентир)</EM4>')) 'Combined refinery/raw ore apply should keep refinery block before raw ore buy block.'
Assert-True ($rawOreBuyPatched.Contains('Agricium 3k')) 'Raw ore buy apply should add Levski raw ore buy list.'
Assert-True ($rawOreBuyPatched.Contains('<EM4>Руда:</EM4> Ouratite 18,3k, Bexalite 5,22k, Taranite 4,81k')) 'Levski raw ore buy list should be sorted by price descending.'
Assert-True (-not $rawOreBuyPatched.Contains($rawOreBuyLegacyLabel)) 'Raw ore buy apply should remove legacy trade label.'
Assert-True (-not $rawOreBuyPatched.Contains('<EM4>Покупают:</EM4>')) 'Raw ore buy apply should not add generic buy list.'
Assert-True (-not $rawOreBuyPatched.Contains('<EM4>Продают:</EM4>')) 'Raw ore buy apply should not add generic sell list.'

$rawOreBuyRepeat = Invoke-SCModPatch -LivePath $rawOreBuyLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $rawOreBuyEnabled -ReportDirectory $rawOreBuyReports -BackupDirectory $rawOreBuyBackups -DryRun
Assert-True ([int]$rawOreBuyRepeat.Report.changedLines -eq 0) 'Raw ore buy apply should be idempotent while enabled.'

$rawOreBuyRemove = Invoke-SCModPatch -LivePath $rawOreBuyLive -ScriptRoot $ProjectDir -SelectedOptionsByModule $rawOreBuyDisabled -ReportDirectory $rawOreBuyReports -BackupDirectory $rawOreBuyBackups
Assert-True ($rawOreBuyRemove.Report.writeSucceeded -eq $true) 'Disabled raw ore buy option should write cleanup fixture file.'
Assert-True ([int]$rawOreBuyRemove.Report.changedLines -eq 2) 'Disabled raw ore buy option should remove refinery and raw ore buy hints.'
$rawOreBuyCleaned = [System.IO.File]::ReadAllText($rawOreBuyGlobalIni, $encoding)
Assert-True (-not $rawOreBuyCleaned.Contains($rawOreBuyLabel)) 'Disabled raw ore buy option should remove UEX raw ore label.'
Assert-True (-not $rawOreBuyCleaned.Contains($refineryYieldLabel)) 'Disabled raw ore buy fixture should also remove refinery label.'

$stageSourceRoot = Join-Path $tempRoot 'StageSource\LIVE'
$stageSourceLoc = Join-Path $stageSourceRoot 'data\Localization\korean_(south_korea)'
$stageSourceGlobalIni = Join-Path $stageSourceLoc 'global.ini'
$stageRoot = Join-Path $tempRoot 'staging-root'
New-Item -ItemType Directory -Force -Path $stageSourceLoc | Out-Null
[System.IO.File]::WriteAllLines($stageSourceGlobalIni, $initialLines, $encoding)
$stageSourceHash = (Get-FileHash -LiteralPath $stageSourceGlobalIni -Algorithm SHA256).Hash

$stagingApply = Invoke-SCModStagingApply -LivePath $stageSourceRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $shipOnly -StagingRoot $stageRoot
Assert-True ($stagingApply.Report.writeSucceeded -eq $true) 'Staging apply should write staging file.'
Assert-True ([int]$stagingApply.Report.changedLines -eq 2) 'Staging apply should change only mining filter and raw mining fixture lines.'
Assert-True (Test-Path -LiteralPath $stagingApply.StagingGlobalIniPath -PathType Leaf) 'Staging global.ini should exist.'
Assert-True (Test-Path -LiteralPath $stagingApply.Report.backupPath -PathType Leaf) 'Staging backup should exist.'
Assert-True ((Get-FileHash -LiteralPath $stageSourceGlobalIni -Algorithm SHA256).Hash -eq $stageSourceHash) 'Staging apply must not change source file.'

$stagingText = [System.IO.File]::ReadAllText($stagingApply.StagingGlobalIniPath, $encoding)
Assert-True ($stagingText.Contains('<EM4>~mission(Destination|Address)<EM4>')) 'Staging apply should leave RuSC EM repair to localization install/update.'
Assert-True (-not $stagingText.Contains($legendPrefix)) 'Staging file should use the new legend-free mining format.'
Assert-True (-not $stagingText.Contains("[$groundCode] Beradon")) 'Staging file should remove ground method fragment.'

$miningModuleScript = Join-Path $ProjectDir 'modules\mining\module.ps1'
. $miningModuleScript

$resourcesByMethod = @{}
foreach ($method in Get-SCMiningMethodOrder) {
    $resourcesByMethod[$method] = New-Object System.Collections.Generic.List[string]
}
$resourcesByMethod[$shipCode].Add('Iron')
$resourcesByMethod[$shipCode].Add('Copper')
$resourcesByMethod[$groundCode].Add('Beradon')
$resourcesByMethod[$handCode].Add('Hadanite')
$methodInventory = [pscustomobject]@{
    ResourcesByMethod = $resourcesByMethod
    CollectableResources = New-Object System.Collections.Generic.List[string]
    CreatureResources = New-Object System.Collections.Generic.List[string]
}
$planetCraftMap = @{
    karna1 = [pscustomobject]@{ Name = 'Karna Rifle'; Category = (Get-SCMiningPlanetCategoryWeapons); Subcategory = (Get-SCMiningPlanetSubcategoryRifles); Family = (Get-SCMiningPlanetRecipeFamily -Name 'Karna Rifle' -Category (Get-SCMiningPlanetCategoryWeapons)); Resources = @('Iron'); ComponentGrade = ''; ComponentClass = '' }
    karna2 = [pscustomobject]@{ Name = 'Karna "Brimstone" Rifle'; Category = (Get-SCMiningPlanetCategoryWeapons); Subcategory = (Get-SCMiningPlanetSubcategoryRifles); Family = (Get-SCMiningPlanetRecipeFamily -Name 'Karna "Brimstone" Rifle' -Category (Get-SCMiningPlanetCategoryWeapons)); Resources = @('Iron'); ComponentGrade = ''; ComponentClass = '' }
    ground = [pscustomobject]@{ Name = 'AD4B Ballistic Gatling'; Category = (Get-SCMiningPlanetCategoryShipWeapons); Subcategory = (Get-SCMiningPlanetSubcategoryBallistics); Family = (Get-SCMiningPlanetRecipeFamily -Name 'AD4B Ballistic Gatling' -Category (Get-SCMiningPlanetCategoryShipWeapons)); Resources = @('Beradon'); ComponentGrade = ''; ComponentClass = '' }
    ground2 = [pscustomobject]@{ Name = 'AD5B Ballistic Gatling'; Category = (Get-SCMiningPlanetCategoryShipWeapons); Subcategory = (Get-SCMiningPlanetSubcategoryBallistics); Family = (Get-SCMiningPlanetRecipeFamily -Name 'AD5B Ballistic Gatling' -Category (Get-SCMiningPlanetCategoryShipWeapons)); Resources = @('Beradon'); ComponentGrade = ''; ComponentClass = '' }
    hand = [pscustomobject]@{ Name = 'P6-LR Sniper Rifle'; Category = (Get-SCMiningPlanetCategoryWeapons); Subcategory = (Get-SCMiningPlanetSubcategorySniperRifles); Family = (Get-SCMiningPlanetRecipeFamily -Name 'P6-LR Sniper Rifle' -Category (Get-SCMiningPlanetCategoryWeapons)); Resources = @('Hadanite'); ComponentGrade = ''; ComponentClass = '' }
    pistol = [pscustomobject]@{ Name = 'Coda Pistol'; Category = (Get-SCMiningPlanetCategoryWeapons); Subcategory = (Get-SCMiningPlanetSubcategoryPistols); Family = (Get-SCMiningPlanetRecipeFamily -Name 'Coda Pistol' -Category (Get-SCMiningPlanetCategoryWeapons)); Resources = @('Iron'); ComponentGrade = ''; ComponentClass = '' }
    testMaterial = [pscustomobject]@{ Name = 'Metamaterial Test #146'; Category = (Get-SCMiningPlanetCategoryMaterials); Subcategory = '__none'; Family = (Get-SCMiningPlanetRecipeFamily -Name 'Metamaterial Test #146' -Category (Get-SCMiningPlanetCategoryMaterials)); Resources = @('Iron'); ComponentGrade = ''; ComponentClass = '' }
    militaryComponent = [pscustomobject]@{ Name = 'FR-86'; Category = (Get-SCMiningPlanetCategoryShipComponents); Subcategory = (Get-SCMiningPlanetSubcategoryShields); Family = (Get-SCMiningPlanetRecipeFamily -Name 'FR-86' -Category (Get-SCMiningPlanetCategoryShipComponents)); Resources = @('Iron'); ComponentGrade = 'A'; ComponentClass = 'Military' }
    industrialComponent = [pscustomobject]@{ Name = 'Palisade'; Category = (Get-SCMiningPlanetCategoryShipComponents); Subcategory = (Get-SCMiningPlanetSubcategoryShields); Family = (Get-SCMiningPlanetRecipeFamily -Name 'Palisade' -Category (Get-SCMiningPlanetCategoryShipComponents)); Resources = @('Iron'); ComponentGrade = 'A'; ComponentClass = 'Industrial' }
}
$standardCraftFilter = Get-SCMiningCraftFilter -SelectedOptions $standardMiningCraftFilters
$emptyCraftFilter = Get-SCMiningCraftFilter -SelectedOptions @()

$methodCombos = @(
    @{ selected = @(); include = @('Фильтр: отключён, способы добычи не выбраны.', 'Корабль', 'Наземная техника', 'Мультитул', 'Copper', 'Iron', 'Beradon', 'Hadanite'); exclude = @('Фильтр: по выбранным галкам крафта; компоненты только Grade A.', 'Karna Rifle', 'AD Ballistic Gatlings', 'P6-LR Sniper Rifle', 'Coda Pistol', 'Palisade') },
    @{ selected = @($shipCode); include = @('Корабль', 'Karna Rifle', 'FR-86'); exclude = @('Наземная техника</EM4>\n<EM4>Корабельные орудия', 'Мультитул</EM4>\n<EM4>Оружие', 'Coda Pistol', 'Palisade') },
    @{ selected = @($groundCode); include = @('Наземная техника', 'AD Ballistic Gatlings'); exclude = @('Корабль</EM4>\n<EM4>Оружие', 'Мультитул</EM4>\n<EM4>Оружие', 'Coda Pistol', 'Palisade') },
    @{ selected = @($handCode); include = @('Мультитул', 'P6-LR Sniper Rifle'); exclude = @('Корабль</EM4>\n<EM4>Оружие', 'Наземная техника</EM4>\n<EM4>Корабельные орудия', 'Coda Pistol', 'Palisade') },
    @{ selected = @($shipCode, $groundCode); include = @('Корабль', 'Karna Rifle', 'Наземная техника', 'AD Ballistic Gatlings'); exclude = @('Мультитул</EM4>\n<EM4>Оружие', 'Coda Pistol', 'Palisade') },
    @{ selected = @($shipCode, $handCode); include = @('Корабль', 'Karna Rifle', 'Мультитул', 'P6-LR Sniper Rifle'); exclude = @('Наземная техника</EM4>\n<EM4>Корабельные орудия', 'Coda Pistol', 'Palisade') },
    @{ selected = @($groundCode, $handCode); include = @('Наземная техника', 'AD Ballistic Gatlings', 'Мультитул', 'P6-LR Sniper Rifle'); exclude = @('Корабль</EM4>\n<EM4>Оружие', 'Coda Pistol', 'Palisade') },
    @{ selected = @($shipCode, $groundCode, $handCode); include = @('Корабль', 'Karna Rifle', 'Наземная техника', 'AD Ballistic Gatlings', 'Мультитул', 'P6-LR Sniper Rifle'); exclude = @('Coda Pistol', 'Palisade') }
)

foreach ($combo in $methodCombos) {
    $block = Format-SCMiningPlanetCraftBlock -Inventory $methodInventory -PlanetCraftMap $planetCraftMap -SelectedMethods $combo.selected -CraftFilter $standardCraftFilter
    $blockText = (($block | ForEach-Object { [string]$_ }) -join '')
    if (@($combo.selected).Count -eq 0) {
        Assert-True ($blockText.Contains('Фильтр: отключён, способы добычи не выбраны.')) 'Planet craft block should mark recipe filter as disabled when no mining methods are selected.'
    }
    else {
        Assert-True ($blockText.Contains('Фильтр: по выбранным галкам крафта; компоненты только Grade A.')) 'Planet craft block should keep only the concise filter intro.'
    }
    Assert-True (-not $blockText.Contains($legendPrefix)) 'Planet craft block should not contain mining legend.'
    Assert-True (-not $blockText.Contains("[$shipCode]")) 'Planet craft block should not contain old ship marker.'
    Assert-True (-not $blockText.Contains('Материалы/особое')) 'Planet craft block should not show hidden materials/special category.'
    Assert-True (-not $blockText.Contains('Metamaterial Test')) 'Planet craft block should not show test metamaterial recipes.'
    if ($shipCode -in $combo.selected) {
        Assert-True ($blockText.Contains('- Karna Rifle: Iron')) 'Karna skins should be grouped into one Karna Rifle line when ship mining is selected.'
        Assert-True ($blockText.Contains('Ресурсы:') -and $blockText.Contains('Copper') -and $blockText.Contains('Iron')) 'Selected ship mining should still show the full raw resource list, not only resources used by filtered recipes.'
    }
    else {
        Assert-True (-not $blockText.Contains('- Karna Rifle: Iron')) 'Unselected ship mining should show only resource reference, not detailed Karna recipe.'
        Assert-True ($blockText.Contains('Copper') -and $blockText.Contains('Iron')) 'Unselected ship mining should keep the full raw resource list.'
    }
    Assert-True (-not $blockText.Contains('Brimstone')) 'Karna skin variant name should not leak into grouped planet recipe output.'
    foreach ($needle in $combo.include) {
        Assert-True ($blockText.Contains($needle)) "Planet craft method combination should include: $needle"
    }
    foreach ($needle in $combo.exclude) {
        Assert-True (-not $blockText.Contains($needle)) "Planet craft method combination should exclude: $needle"
    }
}

$industrialFilter = Get-SCMiningCraftFilter -SelectedOptions @('componentClassIndustrial', 'shipWeaponEnergy', 'shipWeaponBallistic', 'armorHeavy', 'armorMedium', 'fpsRifles', 'fpsSniperRifles', 'fpsSmgs', 'fpsLmgs')
$industrialBlock = Format-SCMiningPlanetCraftBlock -Inventory $methodInventory -PlanetCraftMap $planetCraftMap -SelectedMethods @($shipCode) -CraftFilter $industrialFilter
Assert-True ($industrialBlock.Contains('Palisade')) 'Industrial component filter should include Grade A industrial components when selected.'
Assert-True (-not $industrialBlock.Contains('FR-86')) 'Industrial component filter should exclude military components when military is not selected.'

$pistolFilter = Get-SCMiningCraftFilter -SelectedOptions @('componentClassMilitary', 'componentClassStealth', 'shipWeaponEnergy', 'shipWeaponBallistic', 'armorHeavy', 'armorMedium', 'fpsPistols')
$pistolBlock = Format-SCMiningPlanetCraftBlock -Inventory $methodInventory -PlanetCraftMap $planetCraftMap -SelectedMethods @($shipCode) -CraftFilter $pistolFilter
Assert-True ($pistolBlock.Contains('Coda Pistol')) 'FPS pistol filter should include pistols when selected.'
Assert-True (-not $pistolBlock.Contains('Karna Rifle')) 'FPS pistol filter should exclude rifles when rifles are not selected.'

$noMethodBlock = Format-SCMiningPlanetCraftBlock -Inventory $methodInventory -PlanetCraftMap $planetCraftMap -SelectedMethods @() -CraftFilter $standardCraftFilter
Assert-True ($noMethodBlock.Contains('Copper') -and $noMethodBlock.Contains('Iron')) 'No mining methods selected should still show ship resources as reference.'
Assert-True ($noMethodBlock.Contains('Beradon')) 'No mining methods selected should still show ground resources as reference.'
Assert-True ($noMethodBlock.Contains('Hadanite')) 'No mining methods selected should still show hand resources as reference.'
Assert-True (-not $noMethodBlock.Contains('- Karna Rifle')) 'No mining methods selected should not expand detailed recipes.'

$emptyFilterBlock = Format-SCMiningPlanetCraftBlock -Inventory $methodInventory -PlanetCraftMap $planetCraftMap -SelectedMethods @($shipCode) -CraftFilter $emptyCraftFilter
$emptyFilterText = (($emptyFilterBlock | ForEach-Object { [string]$_ }) -join '')
Assert-True ($emptyFilterText.Contains('Copper') -and $emptyFilterText.Contains('Iron')) 'Empty craft filter should still show raw resources for selected mining methods.'
Assert-True (-not $emptyFilterText.Contains('- Karna Rifle')) 'Empty craft filter should not expand default recipes.'
Assert-True (-not $emptyFilterText.Contains('FR-86')) 'Empty craft filter should not include default military components.'

$craftHintValue = "Pulverizer LMG description\n\n$(Get-SCMiningItemCraftHintLabel) Lindinium | Nepherastatite | Iron"
$craftHintCleaned = Remove-SCMiningItemCraftHint -Value $craftHintValue
Assert-True (-not $craftHintCleaned.Contains((Get-SCMiningItemCraftHintLabel))) 'Disabled item craft option cleanup should remove existing item craft hint lines.'

$corruptInventory = New-SCMiningEmptyResourceInventory
$corruptInventory.ResourcesByMethod[$shipCode].Add('<EM4>Корабельные орудия</EM4>')
$corruptInventory.ResourcesByMethod[$shipCode].Add('<EM4>Энергетика:</EM4>')
Assert-True (-not (Test-SCMiningResourceInventoryUsable -Inventory $corruptInventory)) 'Detailed EM headings must not be accepted as raw mining resources.'
Assert-True (Test-SCMiningCleanResourceSourceValue -Value "Base text\n\n$rawShipHeader\nIron") 'Raw SCMDB resource block should be accepted as clean resource state source.'
Assert-True (-not (Test-SCMiningCleanResourceSourceValue -Value "Base text\n\n$(Get-SCMiningCraftHeader)\n<EM4>Корабль</EM4>\nIron")) 'Patched launcher block should not be accepted as clean resource state source.'

$corruptPlanetValue = "Base text\n\n$(Get-SCMiningCraftHeader)\n$(Get-SCMiningPlanetTextFilters)\n\n<EM4>Корабль</EM4>\n<EM4>Корабельные орудия</EM4>, <EM4>Энергетика:</EM4>"
$restoredPlanetValue = Update-SCMiningCraftBlockMethods -Value $corruptPlanetValue -SelectedMethods @($shipCode) -PlanetCraftMap $planetCraftMap -CraftFilter $standardCraftFilter -Inventory $methodInventory
Assert-True ($restoredPlanetValue.Contains('- Karna Rifle: Iron')) 'Cached raw inventory should restore detailed recipes after a repeated apply.'
Assert-True (-not $restoredPlanetValue.Contains('<EM4>Корабельные орудия</EM4>, <EM4>Энергетика:</EM4>')) 'Repeated apply should not keep EM headings as resource text.'

$lorePlanetValue = "Лорная строка.\n\n$(Get-SCMiningCraftHeader)\n$(Get-SCMiningPlanetTextFilters -SelectedMethods @($shipCode))\n\n<EM4>Корабль</EM4>\nIron"
$strippedPlanetLore = Remove-SCMiningLoreDescriptionPrefix -Value $lorePlanetValue
Assert-True ($strippedPlanetLore.StartsWith((Get-SCMiningCraftHeader))) 'Lore strip should keep the planet craft block as the first text.'
Assert-True (-not $strippedPlanetLore.Contains('Лорная строка')) 'Lore strip should remove lore before a mining craft block.'

$loreRefineryValue = "Станционная реклама.\n\n<EM4>$(Get-SCMiningRefineryYieldHintLabel)</EM4>\n<EM4>$(Get-SCMiningRefineryBonusLabel)</EM4> Iron +8%"
$strippedRefineryLore = Remove-SCMiningLoreDescriptionPrefix -Value $loreRefineryValue
Assert-True ($strippedRefineryLore.StartsWith('<EM4>' + (Get-SCMiningRefineryYieldHintLabel) + '</EM4>')) 'Lore strip should keep refinery hints as the first text.'
Assert-True (-not $strippedRefineryLore.Contains('Станционная реклама')) 'Lore strip should remove lore before a refinery block.'

$plainLoreValue = 'Обычное описание без блоков лаунчера.'
Assert-True ((Remove-SCMiningLoreDescriptionPrefix -Value $plainLoreValue) -eq $plainLoreValue) 'Lore strip should not touch plain descriptions without launcher blocks.'

$stripOperation = [pscustomobject]@{
    ModuleId = 'mining'
    OptionId = 'methodFilter'
    Key = 'Test_desc'
    Operation = 'replaceValue'
    OriginalValue = $lorePlanetValue
    NewValue = $lorePlanetValue
    OwnedMarkers = @('SCMDB_CRAFT_INTEL_BLOCK')
}
$stripPlan = Set-SCMiningLoreDescriptionStripOnOperations -Operations @($stripOperation)
Assert-True ($stripPlan.Metadata.changedDescriptions -eq 1) 'Lore strip operation pass should report one changed description.'
Assert-True ($stripPlan.Operations[0].OptionId.Contains('stripLoreDescriptions')) 'Lore strip operation pass should add the strip option id.'
Assert-True ($stripPlan.Operations[0].OwnedMarkers -contains 'SC_LORE_DESCRIPTION_STRIP') 'Lore strip operation pass should add its owned marker.'

Write-Host 'SC_Mod_Launcher scaffold tests passed.'
Write-Host "Temp root: $tempRoot"
