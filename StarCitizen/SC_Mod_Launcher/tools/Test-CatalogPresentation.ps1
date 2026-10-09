param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'modules\mining\module.ps1')
. (Join-Path $root 'modules\quest\module.ps1')
function Assert-True {param([bool]$Condition,[string]$Message);if(-not $Condition){throw "ASSERT FAILED: $Message"}}
$recipes=@(Get-SCCraftingRecipes -CacheKey '4.10.2-live.12881860')
$map=New-SCMiningPlanetCraftMap -Blueprints $recipes
$expectedCounts=@{'armor:Arden'=5;'armor:Aztalan'=12;'variant:Coda Pistol'=5;'variant:Salvo Frag Pistol'=2}
foreach($key in $expectedCounts.Keys) {
    $rows=@($map.Values | Where-Object {$_.Family.Key -eq $key})
    Assert-True ($rows.Count -eq $expectedCounts[$key]) ('Merged variants must retain every recipe: '+$key)
    Assert-True (@($rows | ForEach-Object { ($_.Resources | Sort-Object) -join '|' } | Sort-Object -Unique).Count -eq 1) ('Merged family must have equal resource sets: '+$key)
}
foreach($name in @('BRVS Repeater','CVSA Cannon','Havoc Scattergun','Hellion Scattergun','Predator Scattergun')) {
    $row=@($map.Values | Where-Object {$_.Name -eq $name})[0]
    Assert-True ($row.Subcategory -eq (Get-SCMiningPlanetSubcategoryBallistics)) 'Declared ballistic subtype takes precedence over an ambiguous name.'
}
foreach($name in @('Sledge I Mass Driver Cannon','Strife Mass Driver Cannon')) {
    $row=@($map.Values | Where-Object {$_.Name -eq $name})[0]
    Assert-True ($row.Subcategory -eq (Get-SCMiningPlanetSubcategoryHybrid)) 'Mass driver policy stays hybrid.'
}
$laser = @($map.Values | Where-Object { $_.Name -eq 'Thlilye Laser Gatling' })[0]
Assert-True ($laser.Subcategory -eq (Get-SCMiningPlanetSubcategoryEnergy)) 'Laser Gatling belongs to energy weapons, not ballistics.'
foreach ($prefix in @('craftFamily','questCraftFamily')) {
    $old = $prefix+'|Корабельные орудия|Баллистика|exact:Thlilye Laser Gatling'
    $expected = $prefix+'|Корабельные орудия|Энергетика|exact:Thlilye Laser Gatling'
    Assert-True ((ConvertTo-SCCraftingFamilyOptionId -OptionId $old) -eq $expected) 'Moving the laser weapon must retain the old selected choice.'
}
$gatlings = @($map.Values | Where-Object { $_.Family.Key -eq 'weapon:GT Gatling' })
Assert-True ($gatlings.Count -eq 3) 'GT-210/215/220 must be one family.'
Assert-True (@($gatlings | ForEach-Object { ($_.Resources | Sort-Object) -join '|' } | Sort-Object -Unique).Count -eq 1) 'Merged GT Gatlings have the same resources.'
foreach($prefix in @('craftFamily','questCraftFamily')) {
    foreach($name in @('YellowJacket GT-210 Gatling','Scorpion GT-215 Gatling','Mantis GT-220 Gatling')) {
        $old=$prefix+'|Корабельные орудия|Баллистика|exact:'+$name
        Assert-True ((ConvertTo-SCCraftingFamilyOptionId -OptionId $old) -eq ($prefix+'|Корабельные орудия|Баллистика|weapon:GT Gatling')) 'Every old size selection must keep the merged family selected.'
    }
}
Assert-True (@($recipes | Where-Object {([string]$_.output_name).Contains([string][char]0x00C2)}).Count -eq 0) 'Every active recipe name must be free of the reported mojibake.'
$catalog=Read-SCCraftingCatalog -CacheKey '4.10.2-live.12881860'
$broken=$catalog.blueprintData | ConvertTo-Json -Depth 80 | ConvertFrom-Json
foreach($record in $broken.blueprints) { if($record.productName) { $record.productName=[System.Text.Encoding]::GetEncoding(28591).GetString([System.Text.Encoding]::UTF8.GetBytes($record.productName)) } }
$repaired=@(ConvertTo-SCCraftingRecipes -BlueprintData $broken -ItemData $catalog.itemData)
Assert-True (($recipes.output_name | ConvertTo-Json -Compress) -ceq ($repaired.output_name | ConvertTo-Json -Compress)) 'Already corrupted offline catalogs must produce identical repaired names without a network refresh.'
foreach($base in @('Arrowhead Sniper Rifle','P8-SC SMG','F55 LMG')) {
    $rows=@($map.Values | Where-Object {$_.Family.Key -eq ('variant:'+$base)})
    Assert-True ($rows.Count -gt 1) 'All skins must participate in the common family.'
    Assert-True (@($rows | ForEach-Object {($_.Resources | Sort-Object) -join '|'} | Sort-Object -Unique).Count -eq 1) 'The merged weapon skins must share their resource set.'
}
$monolith=@($map.Values | Where-Object {$_.Family.Key -eq 'armor:Monolith'})
Assert-True ($monolith.Count -eq 10) 'Both Monolith skins retain all five equipment parts.'
foreach($shadow in @($monolith | Where-Object {$_.Name -match ' Shadowflux$'})) {
    $baseName=$shadow.Name -replace ' Shadowflux$',''
    $ordinary=@($monolith | Where-Object {$_.Name -eq $baseName})[0]
    Assert-True (($ordinary.Resources -join '|') -eq ($shadow.Resources -join '|')) 'Only equivalent Monolith resource sets merge.'
}
$bad=[string][char]0x00C2
$keys=@{
    ('variant:Arrowhead'+$bad+' Sniper Rifle')='variant:Arrowhead Sniper Rifle'
    ('variant:P8-SC'+$bad+' SMG')='variant:P8-SC SMG'
    ('armor:Lynx'+$bad)='armor:Lynx'
    ('armor:Oracle'+$bad)='armor:Oracle'
    ('exact:Hellion'+$bad+[char]0x00A0+'Scattergun')='exact:Hellion Scattergun'
    'exact:F55 Shadowflux LMG'='variant:F55 LMG'
    'armor:Monolith-Shadowflux'='armor:Monolith'
    'armor:Arden-CL'='armor:Arden'
    'armor:Arden-SL'='armor:Arden'
    'armor:Aztalan Galena'='armor:Aztalan'
    'armor:Aztalan Tamarack'='armor:Aztalan'
    'exact:Coda Pistol (Modified)'='variant:Coda Pistol'
    'variant:Salvo Esteban Frag Pistol'='variant:Salvo Frag Pistol'
}
foreach($key in $keys.Keys) {
    $mining='craftFamily|Category|Subcategory|'+$key
    $quest='questCraftFamily|Category|Subcategory|'+$key
    Assert-True (@(Expand-SCMiningCraftFamilyOptionIds -OptionIds @($mining)) -contains ('craftFamily|Category|Subcategory|'+$keys[$key])) 'CLI mining retains old selected choices.'
    Assert-True (@(Get-SCQuestSelectedFamilyOptionIds -SelectedOptions @($quest)) -contains ('questCraftFamily|Category|Subcategory|'+$keys[$key])) 'CLI quest retains old selected choices.'
}
Assert-True ((Normalize-SCCraftingProductName -Name 'Â legitimate accent') -eq 'Â legitimate accent') 'Standalone accented characters must not be stripped.'
foreach($prefix in @('craftFamily','questCraftFamily')) {
    foreach($key in @('exact:BRVS Repeater','exact:CVSA Cannon','exact:Havoc Scattergun','exact:Hellion Scattergun','exact:Predator Scattergun')) {
        $old=$prefix+'|Корабельные орудия|Энергетика|'+$key
        Assert-True ((ConvertTo-SCCraftingFamilyOptionId -OptionId $old) -eq ($prefix+'|Корабельные орудия|Баллистика|'+$key)) 'Moved ballistic choices survive in both modules.'
    }
}
$families=(Get-SCQuestCraftFamilyIndex).families
$all=@($families | ForEach-Object { [string]$_.optionId -replace '^craftFamily\|','questCraftFamily|' })
$tiny=Get-SCQuestPatchPlan -Context ([pscustomobject]@{KeyCount=1}) -SelectedOptions $all
Assert-True ($tiny.Metadata.selectedRecipeFamilies -eq $families.Count) 'Report counts active families once, excluding compatibility aliases.'
function Invoke-WebRequest {
    param($Uri,$Headers,[switch]$UseBasicParsing,$TimeoutSec)
    $text='{"name":"Arrowhead'+[char]0x00A0+'Voyager — проверка"}'
    $bytes=[System.Text.Encoding]::UTF8.GetBytes($text)
    return [pscustomobject]@{Content=[System.Text.Encoding]::GetEncoding(28591).GetString($bytes);RawContentStream=[System.IO.MemoryStream]::new($bytes)}
}
$decoded=Invoke-SCCraftingRemoteJson -Uri 'https://fixture.invalid/catalog.json' -Headers @{}
Assert-True ($decoded.name -ceq ('Arrowhead'+[char]0x00A0+'Voyager — проверка')) 'The real HTTP consumer must decode raw JSON bytes as UTF-8 on PS5.1.'
$tokens=$null; $parseErrors=$null
$engineAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'modules\quest\engine\SC_Quest_Recipe_Engine.ps1'),[ref]$tokens,[ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Quest engine parses on PS5.'
$engineFunctions=@('New-ScmdbEnrichmentMap','ConvertTo-RussianItemType','Get-ShipWeaponSubcategory')
foreach($definition in @($engineAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object {$engineFunctions -contains $_.Name})) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$rawHellion='Hellion'+[char]0x00C2+[char]0x00A0+'Scattergun'
$hellionBlueprint=@($catalog.blueprintData.blueprints | Where-Object {(Normalize-SCCraftingProductName -Name $_.productName) -eq 'Hellion Scattergun'})[0]
$script:CatalogPresentationMission=[pscustomobject]@{blueprintPools=[pscustomobject]@{fixture=[pscustomobject]@{blueprints=@([pscustomobject]@{name=$rawHellion;blueprintRecord=$hellionBlueprint.guid})}}}
function Get-CurrentScmdbCacheVersion { return '4.10.2-live.12881860' }
function Get-ScmdbData { return [pscustomobject]@{Data=$script:CatalogPresentationMission} }
$familyMap=@{'Hellion Scattergun'=[pscustomobject]@{category='Корабельные орудия';subcategory='Баллистика';type='разбросное орудие'}}
$enrichment=New-ScmdbEnrichmentMap -Names @($rawHellion) -FamilyMap $familyMap
Assert-True ($enrichment.ContainsKey($rawHellion) -and $enrichment[$rawHellion].subcategory -eq 'Баллистика') 'A raw mission name retains its identity and uses the normalized family category.'
Assert-True ((Get-ShipWeaponSubcategory -Name $rawHellion -CraftInfo $enrichment[$rawHellion]) -eq 'Баллистика') 'Quest description grouping honors the confirmed family category.'
Write-Host 'PASS: entire recipe catalog, shared resource families, persisted choices, quest categories and PS5 UTF-8 transport'
