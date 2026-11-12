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
    Assert-True ($record.Count -eq 1 -and $map.ContainsKey([string]$record[0].uuid)) ('Missing new recipe in selectable catalog: ' + $name)
}
Assert-True ((New-SCMiningPlanetCraftMap -Blueprints @()).Count -eq 0) 'Empty input must remain empty.'
$battery = @($recipes | Where-Object { $_.output_name -eq 'Skarnov Rifle Battery (30 cap)' })[0]
$single = New-SCMiningPlanetCraftMap -Blueprints @($battery)
$row = $single[[string]$battery.uuid]
Assert-True ($single.Count -eq 1 -and $row.Category -eq (Get-SCMiningPlanetCategoryConsumables)) 'A single battery must reach the consumables category.'
Assert-True ($row.Subcategory -eq (Get-SCMiningPlanetSubcategoryMagazines)) 'Magazine/battery subcategory must be explicit.'
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
    Assert-True (@($index.families | Where-Object { @($_.names) -ccontains $name }).Count -eq 1) ('New recipe must have exactly one checkbox: ' + $name)
}
$family = @($index.families | Where-Object { @($_.names) -contains $battery.output_name })[0]
Assert-True (-not $family.defaultSelected) 'New ammunition choices must be opt-in.'
$filter = Get-SCMiningCraftFilter -SelectedOptions @([string]$family.optionId)
Assert-True (Test-SCMiningIncludePlanetRecipe -Recipe $row -CraftFilter $filter) 'Selecting the battery must include its mining recipe.'
Assert-True (-not (Test-SCMiningIncludePlanetRecipe -Recipe $row -CraftFilter (Get-SCMiningCraftFilter -SelectedOptions @()))) 'Unselected ammunition must stay disabled.'
$questId = [string]$family.optionId -replace '^craftFamily\|', 'questCraftFamily|'
$category = Get-SCMiningPlanetCategoryConsumables
Assert-True (@(Get-SCQuestSelectableCategoryNames) -contains $category) 'Consumables must be selectable by the quest adapter.'
Assert-True (@(Get-SCQuestSelectedCategoryNames -SelectedOptions @($questId)) -contains $category) 'Quest selection must use the engine consumables category.'
$header = '<EM4>' + (-join ([char[]]@(0x0414,0x043E,0x0441,0x0442,0x0443,0x043F,0x043D,0x044B,0x0435,0x0020,0x0447,0x0435,0x0440,0x0442,0x0435,0x0436,0x0438))) + '</EM4>'
$block = 'Lore\n\n' + $header + '\n<EM4>' + $category + '</EM4>\n- Skarnov Rifle Battery (30 cap)\n- P4-AR Magazine (30 cap)'
$filtered = Select-SCQuestRewardBlockCategories -Value $block -SelectedCategoryNames @($category) -SelectedFamilyOptionIds @($questId) -FamilyIndex $index
Assert-True ($filtered.Contains('Skarnov Rifle Battery (30 cap)') -and -not $filtered.Contains('P4-AR Magazine')) 'Quest reward filtering must keep only the selected battery.'
$none = Select-SCQuestRewardBlockCategories -Value $block -SelectedCategoryNames @() -SelectedFamilyOptionIds @() -FamilyIndex $index
Assert-True ($none -ceq 'Lore') 'Disabling consumables must remove the reward block and preserve lore.'
Write-Host ('SC 4.10.3 recipe regressions PASS; 16 new recipes; ' + @($index.families).Count + ' selectable families.')
