param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'modules\mining\module.ps1')
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
$recipes = @(Get-SCCraftingRecipes -CacheKey '4.10.2-live.12881860')
$map = New-SCMiningPlanetCraftMap -Blueprints $recipes
$gradeA = @('3c10e4f9-a125-4171-acfc-b9b51c5b19e1', '8a4f43a8-5f3d-4557-9756-01e1e77fbc2c', 'c0226b4d-3829-487c-8bf0-7d47f36ae867')
$lephari = '7ab8c5b1-2b1c-4388-8931-ad2aefa812e3'
$pioneer = 'd7f3ad24-fca7-4393-b026-f55675cfe820'
$method = Get-SCMiningShipCode
foreach ($id in $gradeA) {
    $recipe = $map[$id]
    Assert-True ($null -ne $recipe -and $recipe.UnresolvedName -and $recipe.ComponentGrade -eq 'A') 'Only verified grade-A identities become selectable.'
    Assert-True ($recipe.Name -match 'без игрового имени') 'Provisional labels must identify the missing official name.'
    $choice = New-SCMiningCraftFamilyOptionId -Recipe $recipe
    $filter = Get-SCMiningCraftFilter -SelectedOptions @($choice)
    $index = New-SCMiningPlanetCraftIndex -PlanetCraftMap $map -CraftFilter $filter
    $inventory = [pscustomobject]@{ ResourcesByMethod = @{ $method = @($recipe.Resources) } }
    $text = Format-SCMiningPlanetCraftBlock -Inventory $inventory -PlanetCraftMap $map -PlanetCraftIndex $index -SelectedMethods @($method) -CraftFilter $filter
    Assert-True ($text.Contains($recipe.Name)) 'Selecting each new family must produce its recipe in actual resource text.'
    $fixed = @($recipes | Where-Object { $_.uuid -eq $id })[0] | ConvertTo-Json -Depth 80 | ConvertFrom-Json
    $fixed.output_name = 'Verified upstream name'
    $fixedMap = New-SCMiningPlanetCraftMap -Blueprints @($fixed)
    Assert-True ((New-SCMiningCraftFamilyOptionId -Recipe $fixedMap[$id]) -eq $choice) 'Upstream name repair must preserve saved choices.'
    Assert-True ($fixedMap[$id].Name -eq 'Verified upstream name' -and -not $fixedMap[$id].UnresolvedName) 'An upstream name must automatically replace the provisional label.'
}
Assert-True ($map[$lephari].ComponentGrade -eq 'C') 'Lephari remains grade C.'
$filter = Get-SCMiningCraftFilter -SelectedOptions @((New-SCMiningCraftFamilyOptionId -Recipe $map[$lephari]))
Assert-True (-not (Test-SCMiningIncludePlanetRecipe -Recipe $map[$lephari] -CraftFilter $filter)) 'Existing grade-A scope must exclude Lephari even when explicitly requested.'
Assert-True (-not $map.ContainsKey($pioneer)) 'Pioneer with no verified product card or grade must stay unresolved.'
$invalid = @($recipes | Where-Object { $_.uuid -eq $gradeA[0] })[0] | ConvertTo-Json -Depth 80 | ConvertFrom-Json
$invalid.output.size = 99
Assert-True ([string]::IsNullOrWhiteSpace((Get-SCMiningUnnamedRecipeLabel -Blueprint $invalid))) 'Contradictory identity data must not receive an invented label.'
$invalid.uuid = '00000000-0000-0000-0000-000000000000'
Assert-True ([string]::IsNullOrWhiteSpace((Get-SCMiningUnnamedRecipeLabel -Blueprint $invalid))) 'Unknown records must never receive guessed labels.'
Assert-True (@($recipes | Where-Object { $_.uuid -in ($gradeA + @($lephari, $pioneer)) -and -not [string]::IsNullOrWhiteSpace($_.output_name) }).Count -eq 0) 'Resource labels must not masquerade as official product names in item descriptions.'
Write-Host 'PASS: unnamed recipe selection, real resource text, grade policy, stable choice identity and no fabricated item names'
