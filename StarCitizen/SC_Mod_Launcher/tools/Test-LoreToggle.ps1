param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'shared\SC_Localization_Core.ps1')
. (Join-Path $root 'modules\mining\module.ps1')
function Assert-True { param([bool]$Condition,[string]$Message); if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
$craftBody = (Get-SCMiningCraftHeader) + '\nFilter\n\n<EM4>Ship</EM4>\nTitanium 28.5%\n\n' + (Get-SCMiningAsteroidBeltHeader) + '\n\n<EM4>Ship</EM4>\nOuratite 10%'
$refineryBody = '<EM4>' + (Get-SCMiningRefineryYieldHintLabel) + '</EM4>: Iron +3%'
$tradeBody = '<EM4>' + (Get-SCMiningLocationTradeHintLabel) + '</EM4>: Iron 100'
$values = @{
    'Stanton2c_Desc,P' = 'Original Yela lore\n\n' + $craftBody
    'Pyro6_desc' = 'Original Terminus lore\n\n' + $craftBody
    'station_refinery_desc' = 'Refinery lore\n\n' + $refineryBody
    'station_trade_description' = 'Trade lore\n\n' + $tradeBody
    'already_hidden_desc' = $craftBody
    'unrelated_desc' = 'Unrelated lore and text'
    'unrelated_title' = 'Title\n\n' + $craftBody
}
$strip = Set-SCMiningLoreDescriptionStripOnOperations -Operations @() -Values $values
Assert-True ($strip.Operations.Count -eq 4 -and $strip.Metadata.changedDescriptions -eq 4) 'Hide-lore creates operations even when all hint generators have no changes'
Assert-True (@(Test-SCPatchConflicts -Operations @($strip.Operations)).Count -eq 0) 'One strip operation per eligible description'
foreach ($operation in $strip.Operations) {
    Assert-True ($operation.OriginalValue -ceq $values[$operation.Key]) 'Original value is the actual input for a new strip operation'
    $expected = if ($operation.Key -like 'station_refinery*') {$refineryBody} elseif ($operation.Key -like 'station_trade*') {$tradeBody} else {$craftBody}
    Assert-True ($operation.NewValue -ceq $expected) 'Only the lore prefix is removed; hints and the complete asteroid section remain exact'
}
$hiddenValues = Copy-SCMiningValueMap -Values $values
Apply-SCMiningOperationsToValueMap -Values $hiddenValues -Operations $strip.Operations
$again = Set-SCMiningLoreDescriptionStripOnOperations -Operations @() -Values $hiddenValues
Assert-True ($again.Operations.Count -eq 0 -and $again.Metadata.changedDescriptions -eq 0) 'Repeated hide-lore produces no operations'
Assert-True ($hiddenValues.unrelated_desc -eq $values.unrelated_desc -and $hiddenValues.unrelated_title -eq $values.unrelated_title) 'Descriptions without owned blocks and title keys remain unchanged'

$planned = [pscustomobject]@{ModuleId='mining';OptionId='methodFilter';Key='Stanton2c_Desc,P';Operation='replaceValue';OriginalValue='Old input';NewValue=$values['Stanton2c_Desc,P'];OwnedMarkers=@('SCMDB_CRAFT_INTEL_BLOCK')}
$mixed = Set-SCMiningLoreDescriptionStripOnOperations -Operations @($planned) -Values $values
Assert-True ($mixed.Operations.Count -eq 4 -and @($mixed.Operations | Where-Object {$_.Key -eq 'Stanton2c_Desc,P'}).Count -eq 1) 'Already planned descriptions are stripped in place without duplicate operations'
$existing = @($mixed.Operations | Where-Object {$_.Key -eq 'Stanton2c_Desc,P'})[0]
Assert-True ($existing.OriginalValue -eq 'Old input' -and $existing.OptionId -eq 'methodFilter+stripLoreDescriptions' -and $existing.NewValue -ceq $craftBody) 'Existing operation identity and original input are preserved'
$compat = Set-SCMiningLoreDescriptionStripOnOperations -Operations @($planned)
Assert-True ($compat.Operations.Count -eq 1 -and $compat.Operations[0].NewValue -ceq $craftBody) 'Old callers without Values retain their behavior'
$cleanup = [pscustomobject]@{ModuleId='mining';OptionId='locationCleanup';Key='retired_desc';Operation='replaceValue';OriginalValue=$craftBody;NewValue='Restored navigation lore';OwnedMarkers=@('SCMDB_CRAFT_INTEL_CLEANUP')}
$cleanupPlan = Set-SCMiningLoreDescriptionStripOnOperations -Operations @($cleanup) -Values @{'retired_desc'='Restored navigation lore'}
Assert-True ($cleanupPlan.Operations.Count -eq 1 -and $cleanupPlan.Operations[0].NewValue -eq 'Restored navigation lore') 'Retired-location cleanup keeps its navigation text'
Write-Host 'Hide-lore toggle: PASS'
