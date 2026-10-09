param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'shared\SC_Localization_Core.ps1')
. (Join-Path $root 'modules\mining\module.ps1')
. (Join-Path $root 'modules\quest\module.ps1')
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$data = @'
{"eventScopes":{"collect":{"eventName":"Iasi","category":"Collection","tiers":[{"minPoints":2000},{"minPoints":4000}]},"total":{"eventName":"Iasi","category":null,"tiers":[{"minPoints":4500}]},"other":{"eventName":"CleanAir","category":"Collection"}},"contracts":[{"descriptionLocKey":"shared_desc","completionTags":[{"tag":"collect","count":408,"splitPointsForParty":false},{"tag":"total","count":408,"splitPointsForParty":false},{"tag":"unknown","count":9999}]},{"descriptionKey":"@shared_desc","completionTags":[{"tag":"collect","count":600,"splitPointsForParty":false}]},{"descriptionLocKey":"party_desc","completionTags":[{"tag":"collect","count":500,"splitPointsForParty":true}]},{"descriptionLocKey":"old_desc","completionTags":[{"tag":"other","count":500}]}]}
'@ | ConvertFrom-Json
$map = New-SCQuestEventProgressMap -Data $data
Assert-True ($map.Count -eq 2) 'Only known Iasi scopes are rendered'
$block = Format-SCQuestEventProgressBlock -Rows $map.shared_desc
Assert-True ($block -match '408/600' -and $block -notmatch '1008') 'Shared descriptions keep variants rather than adding points'
Assert-True ($block -match 'Общий зачёт: 408' -and $block -match 'Сбор: 408/600') 'Total and collection are independent tracks'
Assert-True ($block -notmatch 'Репутация' -and $block -notmatch '9999') 'Event points never become faction reputation'
Assert-True ($block -notmatch 'пороги|участник|групп|2000|4000|4500') 'Only awards and tracks are rendered'
$original = 'Исходное описание\n\n<EM4>Репутация</EM4>: 150'
$patched = $block + '\n\n' + $original
Assert-True ((Remove-SCQuestEventProgressBlock -Value $patched) -eq $original) 'Prefix cleanup preserves the original and reputation'
$legacy = $original + '\n\n<EM4>Очки события (RSI Discovery Month)</EM4>:\n- Сбор: 408; пороги этапов: 2000/4000'
Assert-True ((Remove-SCQuestEventProgressBlock -Value $legacy) -eq $original) 'Earlier appended event block is migrated without losing description'
Assert-True ((Remove-SCQuestEventProgressBlock -Value ($legacy + '\n\n<EM4>Другой блок</EM4>: тест')) -eq ($original + '\n\n<EM4>Другой блок</EM4>: тест')) 'Cleanup preserves following unrelated blocks'
$lookup = [pscustomobject]@{ ActualKeyByLower = @{'item_desc_radr_grnp_s02_v80112'='item_Desc_RADR_GRNP_S02_V80112';'item_desc_radr_chco_s02_broadspec'='item_Desc_RADR_CHCO_S02_BroadSpec'} }
Assert-True ((Resolve-SCMiningDirectDescriptionKey -OutputClass 'radr_grnp_s02_vb80112' -Lookup $lookup) -eq 'item_Desc_RADR_GRNP_S02_V80112') 'V801-12 alias maps same size'
Assert-True ((Resolve-SCMiningDirectDescriptionKey -OutputClass 'radr_chco_s02_broadspec_lite' -Lookup $lookup) -eq 'item_Desc_RADR_CHCO_S02_BroadSpec') 'BroadSpec S2 alias maps same size'
Assert-True ($null -eq (Resolve-SCMiningDirectDescriptionKey -OutputClass 'radr_chco_s03_broudspec' -Lookup $lookup)) 'Absent BroadSpec S3 never maps to S2'
$actual = @{'shared_desc,P'='Исходное описание'}
$stats = Set-SCQuestEventProgressHints -Values $actual -Data $data
Assert-True ($stats.descriptions -eq 1 -and $actual['shared_desc,P'] -match '408/600') 'Engine keys resolve actual comma-P localization keys'
$stats = Set-SCQuestEventProgressHints -Values $actual -Data $data
Assert-True ($stats.changed -eq 0) 'Full event patch is idempotent for comma-P keys'
Assert-True ($actual['shared_desc,P'].StartsWith($block + '\n\n')) 'Awards are placed before the existing description'
$expired = @{ 'shared_desc,P'=$actual['shared_desc,P']; 'unrelated_desc'='Другой квест' }
$stats = Set-SCQuestEventProgressHints -Values $expired -Data ([pscustomobject]@{contracts=@();eventScopes=[pscustomobject]@{}})
Assert-True ($stats.enabled -and $stats.descriptions -eq 0 -and $expired['shared_desc,P'] -eq 'Исходное описание' -and $expired['unrelated_desc'] -eq 'Другой квест') 'Ended event removes old prefix without errors or changing unrelated quests'
$absent = @{'unrelated_desc'='Другой квест'}
$stats = Set-SCQuestEventProgressHints -Values $absent -Data $data
Assert-True ($stats.changed -eq 0 -and $absent.Count -eq 1 -and $stats.missingDescriptionKeys.Count -eq 2) 'Removed localization keys are skipped, never recreated'
$missingScopes = @{'shared_desc,P'=$patched}
$stats = Set-SCQuestEventProgressHints -Values $missingScopes -Data ([pscustomobject]@{contracts=@()})
Assert-True ($stats.descriptions -eq 0 -and $missingScopes['shared_desc,P'] -eq $original) 'Absent event scopes are an ordinary no-award case'
$noData = @{'shared_desc,P'=$patched}
$stats = Set-SCQuestEventProgressHints -Values $noData -Data $null
Assert-True ($stats.descriptions -eq 0 -and $noData['shared_desc,P'] -eq $original) 'Null event data does not fail'
$legacyValues = @{'shared_desc,P'=$legacy}
$stats = Set-SCQuestEventProgressHints -Values $legacyValues -Data $data
Assert-True ($legacyValues['shared_desc,P'] -eq $patched) 'Legacy block is replaced by the compact prefix'
$questManifest = Get-Content -LiteralPath (Join-Path $root 'modules\quest\manifest.json') -Encoding UTF8 -Raw | ConvertFrom-Json
Assert-True (@($questManifest.options | Where-Object { $_.id -eq 'eventProgressHints' }).Count -eq 0) 'Automatic event awards have no checkbox option'
$duplicateData = '{"eventScopes":{"transport":{"eventName":"Iasi","category":"Transport"},"total":{"eventName":"Iasi","category":null}},"contracts":[{"descriptionLocKey":"delivery_desc","completionTags":[{"tag":"transport","count":313},{"tag":"total","count":313}]}]}' | ConvertFrom-Json
$duplicateValues = @{'delivery_desc'='Доставить пакет'}
$stats = Set-SCQuestEventProgressHints -Values $duplicateValues -Data $duplicateData
Assert-True ($duplicateValues['delivery_desc'] -eq '<EM4>Очки события (RSI Discovery Month)</EM4>: Транспорт: 313\n\nДоставить пакет') 'Identical total award is omitted from the compact prefix'
$totalOnlyData = '{"eventScopes":{"total":{"eventName":"Iasi","category":null}},"contracts":[{"descriptionLocKey":"total_desc","completionTags":[{"tag":"total","count":99}]}]}' | ConvertFrom-Json
$totalOnlyValues = @{'total_desc'='Описание'}
$stats = Set-SCQuestEventProgressHints -Values $totalOnlyValues -Data $totalOnlyData
Assert-True ($totalOnlyValues['total_desc'] -match 'Общий зачёт: 99') 'Total award is retained when there is no category award'
$scraper = [pscustomobject]@{output_name='Cinch Scraper Module';output=[pscustomobject]@{type_label='Salvage Modifier'}}
Assert-True ((Get-SCMiningPlanetBlueprintCategory -Blueprint $scraper) -eq 'Горное оборудование') 'Scraper rewards are selectable equipment'
Assert-True ((Get-SCMiningPlanetBlueprintSubcategory -Blueprint $scraper -Category 'Горное оборудование') -eq 'Модули утилизации') 'Salvage modules keep their own subcategory'
$inventory = Read-SCMiningResourceInventoryFromValue -Value 'Потенциально добываемые ресурсы (корабль):\nIron'
$first = Update-SCMiningCraftBlockMethods -Value 'Лор\n' -SelectedMethods @('К') -Inventory $inventory -DetailedCraftBlock ''
$second = Update-SCMiningCraftBlockMethods -Value $first -SelectedMethods @('К') -Inventory $inventory -DetailedCraftBlock ''
Assert-True ($first -eq $second) 'Encoded trailing lore newline does not change on repeat apply'

# Execute the real backend fallback functions against a small isolated payload.
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'SC_Mod_Launcher.ps1'), [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'Backend parses on the supported PowerShell runtime'
$names = @('Set-SCJsonProperty','Write-SCJsonCacheFile','Write-SCMiningItemPassportFallbackCache')
foreach ($definition in @($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true) | Where-Object { $names -contains $_.Name })) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:TestPassport = [pscustomobject]@{cacheKey='4.10.0-live.12568521';requestedGameVersion='4.10.0-LIVE.12568521';gameVersion='4.10.0-LIVE.12519617';versionMatch='compatible';createdAt='2026-09-08T12:00:00+03:00';records=@()}
$script:TestCachePath = Join-Path ([System.IO.Path]::GetTempPath()) ('sc-fallback-test-' + [guid]::NewGuid().ToString('N') + '.json')
function Get-SCMiningItemPassportCachePath { param([string]$CacheKey); return $script:TestCachePath }
function Get-SCMiningCachedItemPassports { param([string]$CacheKey); return $script:TestPassport }
try {
    [void](Write-SCMiningItemPassportFallbackCache -CacheKey '4.10.2-live.12881860')
    $script:TestPassport = Get-Content -LiteralPath $script:TestCachePath -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-True ($script:TestPassport.createdAt -eq '2026-09-08T12:00:00+03:00') 'Fallback retains original source timestamp'
    Assert-True ($script:TestPassport.gameVersion -eq '4.10.0-LIVE.12519617' -and $script:TestPassport.requestedGameVersion -eq '4.10.2-LIVE.12881860') 'Requested and actual game versions remain distinct'
    Assert-True ($script:TestPassport.versionMatch -eq 'offline-fallback' -and $script:TestPassport.fallbackCopiedAt) 'Fallback status and copy timestamp are explicit'
    [void](Write-SCMiningItemPassportFallbackCache -CacheKey '4.10.2-live.12881860')
    $again = Get-Content -LiteralPath $script:TestCachePath -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-True ($again.fallbackFromCacheKey -eq '4.10.0-live.12568521') 'Repeated fallback retains original ancestry'
}
finally { if (Test-Path -LiteralPath $script:TestCachePath) { Remove-Item -LiteralPath $script:TestCachePath -Force } }
Write-Host 'SC 4.10.2 targeted regressions: PASS'
