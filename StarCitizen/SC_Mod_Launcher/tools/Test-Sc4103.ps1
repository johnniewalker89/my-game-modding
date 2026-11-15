param(
    [string]$LauncherRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$CacheKey = '4.10.3-live.13165946'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $LauncherRoot 'modules\mining\module.ps1')
. (Join-Path $LauncherRoot 'modules\quest\module.ps1')
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
$recipes = @(Get-SCCraftingRecipes -CacheKey $CacheKey)
$map = New-SCMiningPlanetCraftMap -Blueprints $recipes
$expected = @(
    'Skarnov Rifle Battery (30 cap)', 'Skarnov "Raider Camo" Rifle',
    'M3A Cannon Raider Camo', 'M4A Cannon Raider Camo', 'M5A Cannon Raider Camo',
    'Corbel Arms Raider Camo', 'Corbel Core Raider Camo', 'Corbel Helmet Raider Camo', 'Corbel Legs Raider Camo',
    'Palatino Arms Raider Camo', 'Palatino Core Raider Camo', 'Palatino Helmet Raider Camo', 'Palatino Legs Raider Camo', 'Palatino Backpack Raider Camo',
    'Tailwind Flight Suit Raider Camo', 'Tailwind Helmet Raider Camo'
)
foreach ($name in $expected) {
    $record = @($recipes | Where-Object { $_.output_name -ceq $name })
    Assert-True ($record.Count -eq 1) ('Missing new recipe in source catalog: ' + $name)
    Assert-True ($map.ContainsKey([string]$record[0].uuid) -eq ($name -ne 'Skarnov Rifle Battery (30 cap)')) ('Only ammunition must be excluded from selectable recipes: ' + $name)
}
Assert-True ((New-SCMiningPlanetCraftMap -Blueprints @()).Count -eq 0) 'Empty input must remain empty.'
$battery = @($recipes | Where-Object { $_.output_name -eq 'Skarnov Rifle Battery (30 cap)' })[0]
$single = New-SCMiningPlanetCraftMap -Blueprints @($battery)
Assert-True ($single.Count -eq 0) 'Ammunition must not create a selectable group, including a single battery.'
Assert-True (@($battery.ingredients).Count -eq 2) 'Battery ingredients must not be dropped.'
Assert-True (@($battery.ingredients | Where-Object { $_.name -eq 'Hephaestanite' -and [decimal]$_.quantity_scu -eq [decimal]0.02 }).Count -eq 1) 'Skarnov battery needs 0.02 SCU Hephaestanite.'
Assert-True (@($battery.ingredients | Where-Object { $_.name -eq 'Gold' -and [decimal]$_.quantity_scu -eq [decimal]0.01 }).Count -eq 1) 'Skarnov battery needs 0.01 SCU Gold.'
Assert-True ($null -eq (Get-SCMiningPlanetBlueprintCategory -Blueprint ([pscustomobject]@{ output=[pscustomobject]@{type='Weapon Attachment';attachSubType='Scope'} }))) 'Other attachment types must not silently become ammunition.'
foreach ($number in 3..5) {
    $base = @($recipes | Where-Object { $_.output_name -eq ('M' + $number + 'A Cannon') })[0]
    $skin = @($recipes | Where-Object { $_.output_name -eq ('M' + $number + 'A Cannon Raider Camo') })[0]
    Assert-True (($base.ingredients | ConvertTo-Json -Depth 8 -Compress) -ceq ($skin.ingredients | ConvertTo-Json -Depth 8 -Compress)) 'Merged camo variants must keep identical ingredients and quantities.'
    Assert-True ($map[[string]$skin.uuid].Family.Key -eq $map[[string]$base.uuid].Family.Key) 'M-series camo must reuse the existing family.'
    foreach ($prefix in @('craftFamily', 'questCraftFamily')) {
        $old = $prefix + '|Ship|Energy|exact:M' + $number + 'A Cannon Raider Camo'
        Assert-True ((ConvertTo-SCCraftingFamilyOptionId -OptionId $old) -eq ($prefix + '|Ship|Energy|weapon:MA Cannon')) 'Existing camo choices must migrate for both modules.'
    }
}
$index = Get-SCMiningCraftFamilyIndex
Assert-True ([string]$index.cacheKey -eq $CacheKey) 'Family index must use the tested build.'
foreach ($name in $expected) {
    $expectedCount = if ($name -eq $battery.output_name) { 0 } else { 1 }
    Assert-True (@($index.families | Where-Object { @($_.names) -ccontains $name }).Count -eq $expectedCount) ('Selectable recipe checkbox count: ' + $name)
}
$category = Get-SCMiningPlanetCategoryConsumables
$oldId = 'craftFamily|' + $category + '|Магазины/батареи|battery:Skarnov Rifle'
$questId = $oldId -replace '^craftFamily\|', 'questCraftFamily|'
$oldRow = [pscustomobject]@{ Category=$category; Subcategory='Магазины/батареи'; Family=[pscustomobject]@{Key='battery:Skarnov Rifle'} }
Assert-True (-not (Test-SCMiningIncludePlanetRecipe -Recipe $oldRow -CraftFilter (Get-SCMiningCraftFilter -SelectedOptions @($oldId)))) 'Old saved ammunition choices must not reactivate mining hints.'
Assert-True (@($index.families | Where-Object { $_.category -eq $category }).Count -eq 0) 'Fresh indexes must contain no ammunition section.'
Assert-True (@(Get-SCQuestSelectableCategoryNames) -notcontains $category) 'Consumables must not be selectable by the quest adapter.'
Assert-True (@(Get-SCQuestSelectedCategoryNames -SelectedOptions @('equipmentAndConsumables', $questId)).Count -eq 0) 'Old quest ammunition settings must be ignored.'
Assert-True (@(Get-SCQuestSelectedFamilyOptionIds -SelectedOptions @($questId)).Count -eq 0) 'Old ammunition family IDs must not activate a quest family filter.'
$header = '<EM4>' + (-join ([char[]]@(0x0414,0x043E,0x0441,0x0442,0x0443,0x043F,0x043D,0x044B,0x0435,0x0020,0x0447,0x0435,0x0440,0x0442,0x0435,0x0436,0x0438))) + '</EM4>'
$block = 'Lore\n\n' + $header + '\n<EM4>' + $category + '</EM4>\n- Skarnov Rifle Battery (30 cap)\n- P4-AR Magazine (30 cap)'
$filtered = Select-SCQuestRewardBlockCategories -Value $block -SelectedCategoryNames @($category) -SelectedFamilyOptionIds @($questId) -FamilyIndex $index
Assert-True ($filtered -ceq 'Lore') 'Even an old index and explicit old selection must remove ammunition rewards and preserve lore.'
$none = Select-SCQuestRewardBlockCategories -Value $block -SelectedCategoryNames @() -SelectedFamilyOptionIds @() -FamilyIndex $index
Assert-True ($none -ceq 'Lore') 'Disabling consumables must remove the reward block and preserve lore.'
Write-Host ('SC 4.10.3 recipe regressions PASS; 16 source recipes / 15 selectable; ammunition retired; ' + @($index.families).Count + ' selectable families.')
