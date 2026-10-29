param([Parameter(Mandatory = $true)][string]$WorkRoot)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'shared\SC_Localization_Core.ps1')
. (Join-Path $root 'modules\mining\module.ps1')
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

# The caller supplies a disposable folder; no installed game or source settings are used.
$workPath = [System.IO.Path]::GetFullPath($WorkRoot)
[void][System.IO.Directory]::CreateDirectory($workPath)
$fixturePath = Join-Path $workPath 'global.ini'
$fixtureLines = @(
    'Stanton2c_Desc,P=Yela lore',
    'Pyro6_desc=Terminus lore',
    'Stanton2c_ASD_Delving_Facility_001_desc=Yela facility lore',
    'Pyro6_ASD_Delving_Facility_001_desc=Terminus facility lore',
    'unrelated_desc=Unrelated description'
)
[System.IO.File]::WriteAllLines($fixturePath, $fixtureLines, (New-Object System.Text.UTF8Encoding($true)))
$context = Read-SCLocalizationData -LivePath $workPath -GlobalIniPath $fixturePath
$fixtureData = Get-SCMiningCachedMiningData
$originalDataFunction = (Get-Command Get-SCMiningCachedMiningData).ScriptBlock
$originalMapFunction = (Get-Command Get-SCMiningSupplementalLocationMap).ScriptBlock
# Do not learn/write the persistent legacy inventory cache during a regression test.
function Get-SCMiningPlanetResourceInventoryCache { return @{} }
function Write-SCMiningPlanetResourceInventoryCache { throw 'Unexpected persistent inventory cache write' }

$families = Get-SCMiningCraftFamilyIndex
$familyOptions = @($families.families | Where-Object { $_.label -in @('Manticore Helmet', 'Thlilye Laser Gatling') } | ForEach-Object { $_.optionId })
Assert-True ($familyOptions.Count -eq 2) 'Real demo craft families are present'
$options = @('shipMining') + $familyOptions
$header = Get-SCMiningAsteroidBeltHeader
function Get-TestValues {
    param($InputContext, [string[]]$Options)
    $plan = Get-SCMiningPatchPlan -Context $InputContext -SelectedOptions $Options
    $values = Copy-SCMiningValueMap -Values $InputContext.Values
    Apply-SCMiningOperationsToValueMap -Values $values -Operations @($plan.Operations)
    return [pscustomobject]@{ Plan = $plan; Values = $values }
}

$locationIndex = Get-SCMiningLocationInventoryIndex
Assert-True ($locationIndex.SupplementalByKey.Count -eq 2) 'Only the two main bodies receive belts'
Assert-True ($locationIndex.SupplementalByKey['Stanton2c_Desc'][0].SourcePresetFile -eq 'hpp_stanton2c_belt') 'Yela belt resolves its real preset'
Assert-True ($locationIndex.SupplementalByKey['Pyro6_desc'][0].SourcePresetFile -eq 'hpp_stanton2c_belt') 'Terminus shares the same real preset'
Assert-True (-not $locationIndex.SupplementalByKey.ContainsKey('Stanton2c_ASD_Delving_Facility_001_desc')) 'Surface facilities do not inherit an orbital belt'

$first = Get-TestValues -InputContext $context -Options $options
Assert-True ($first.Plan.Metadata.supplementalLocationSections -eq 2) 'Two separate belt sections are reported'
Assert-True (@($first.Plan.Operations | Group-Object Key | Where-Object { $_.Count -gt 1 }).Count -eq 0) 'Each key receives one merged operation'
$yela = [string]$first.Values['Stanton2c_Desc,P']
$terminus = [string]$first.Values['Pyro6_desc']
$ringIndex = $yela.IndexOf($header)
Assert-True ($ringIndex -gt 0 -and ([regex]::Matches($yela, [regex]::Escape($header))).Count -eq 1) 'Comma-P Yela receives exactly one belt section at the end'
$surface = $yela.Substring(0, $ringIndex)
$ring = $yela.Substring($ringIndex)
Assert-True ($surface.Contains('Taranite 18%') -and -not $surface.Contains('Ouratite')) 'Yela surface resources remain separate'
Assert-True ($surface.Contains('Manticore Helmet') -and -not $surface.Contains('Thlilye Laser Gatling')) 'Surface craft hints follow surface resources and selected methods'
Assert-True ($ring.Contains('Titanium 28.5%') -and $ring.Contains('Ouratite 10%') -and -not $ring.Contains('Taranite')) 'Belt resources use its own real profile'
Assert-True ($ring.Contains('Thlilye Laser Gatling: Iron, Ouratite') -and -not $ring.Contains('Manticore')) 'Belt craft hints use the same family filter and only local resources'
Assert-True ($terminus.Substring($terminus.IndexOf($header)) -eq $ring) 'Both rings render identical data with the same filters'
Assert-True (([regex]::Matches($yela, [regex]::Escape((Get-SCMiningCraftHeader)))).Count -eq 1) 'The common header and filter are not duplicated for the belt'
Assert-True (-not $first.Values['Stanton2c_ASD_Delving_Facility_001_desc'].Contains($header)) 'Yela facility text has no orbital belt'
Assert-True (-not $first.Values['Pyro6_ASD_Delving_Facility_001_desc'].Contains($header)) 'Terminus facility text has no orbital belt'
Assert-True ($first.Values.unrelated_desc -eq $context.Values.unrelated_desc) 'Unrelated descriptions remain exact'

$repeatContext = New-SCMiningContextWithValues -Context $context -Values $first.Values
$repeat = Get-TestValues -InputContext $repeatContext -Options $options
Assert-True ($repeat.Plan.Operations.Count -eq 0) 'Repeated application produces no operations'
$parsed = Read-SCMiningResourceInventoryFromValue -Value $yela
Assert-True ((Format-SCMiningResourceEntriesForDisplay -Entries $parsed.ResourcesByMethod[(Get-SCMiningShipCode)]) -notmatch 'Ouratite|Iron|Titanium') 'Reading a composite description cannot move belt ores to the surface'
Assert-True (-not (Get-SCMiningFilteredDetailedCraftBlock -Value $yela -SelectedMethods @((Get-SCMiningShipCode)) ).Contains($header)) 'Legacy detailed-block reading stops at the supplemental section'

$onlyArmor = @('shipMining') + @($familyOptions | Where-Object { $_ -like '*Manticore*' })
$filtered = Get-TestValues -InputContext $repeatContext -Options $onlyArmor
Assert-True ($filtered.Values['Stanton2c_Desc,P'].Contains('Manticore Helmet') -and -not $filtered.Values['Stanton2c_Desc,P'].Contains('Thlilye Laser Gatling')) 'Changing craft families updates both sections without changing resources'
$noMethods = Get-TestValues -InputContext $context -Options $familyOptions
Assert-True ($noMethods.Values['Stanton2c_Desc,P'].Contains('Ouratite 10%') -and -not $noMethods.Values['Stanton2c_Desc,P'].Contains('Thlilye Laser Gatling')) 'No selected mining methods keeps reference resources without craft recipes'
$stripOptions = $options + @('stripLoreDescriptions')
$stripped = Get-TestValues -InputContext $context -Options $stripOptions
Assert-True (-not $stripped.Values['Stanton2c_Desc,P'].Contains('Yela lore') -and $stripped.Values['Stanton2c_Desc,P'].Contains($header)) 'Hide lore preserves both owned sections'
$strippedContext = New-SCMiningContextWithValues -Context $context -Values $stripped.Values
Assert-True ((Get-TestValues -InputContext $strippedContext -Options $stripOptions).Plan.Operations.Count -eq 0) 'Hide-lore repeat is also a no-op'

# A missing profile never borrows a planet or another belt and never contaminates fallback parsing.
try {
    $script:RingTestData = $fixtureData | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $script:RingTestData.locations = @($script:RingTestData.locations | Where-Object { $_.presetFile -ne 'hpp_stanton2c_belt' })
    function Get-SCMiningCachedMiningData { return $script:RingTestData }
    $missing = Get-TestValues -InputContext $repeatContext -Options $options
    Assert-True (-not $missing.Values['Stanton2c_Desc,P'].Contains($header) -and -not $missing.Values['Stanton2c_Desc,P'].Contains('Ouratite')) 'Missing belt is omitted, never merged into the surface'
    Assert-True (@($missing.Plan.Warnings | Where-Object { $_ -like '*asteroid belt profile*unavailable*' }).Count -eq 2) 'Missing shared profile is explicitly diagnosed for both descriptions'
    function Get-SCMiningCachedMiningData { throw 'Intentional missing mining cache fixture' }
    $fallback = Get-TestValues -InputContext $repeatContext -Options $options
    Assert-True ($fallback.Values['Stanton2c_Desc,P'] -ceq $first.Values['Stanton2c_Desc,P']) 'An untrusted legacy inventory preserves the old description when the entire mining cache is unavailable'
    Assert-True (-not $fallback.Values['Pyro6_desc'].Contains('Ouratite') -and -not $fallback.Values['Pyro6_desc'].Contains($header) -and $fallback.Values['Pyro6_desc'].Contains('Riccite')) 'Usable primary-only fallback never absorbs belt ores or invents a missing belt profile'
}
finally { Set-Item -Path Function:\Get-SCMiningCachedMiningData -Value $originalDataFunction }

# Zero/one/multiple section collection shapes go through the actual public plan.
try {
    function Get-SCMiningSupplementalLocationMap { return @{} }
    $zero = Get-TestValues -InputContext $repeatContext -Options $options
    Assert-True (-not $zero.Values['Stanton2c_Desc,P'].Contains($header)) 'Zero configured sections removes an old supplemental tail cleanly'
    function Get-SCMiningSupplementalLocationMap { return @{ 'Stanton2c_Desc' = @('hpp_stanton2c_belt', 'hpp_aaronhalo') } }
    $many = Get-TestValues -InputContext $context -Options $options
    Assert-True (([regex]::Matches($many.Values['Stanton2c_Desc,P'], [regex]::Escape($header))).Count -eq 2) 'Multiple supplemental profiles retain separate sections'
    $manyContext = New-SCMiningContextWithValues -Context $context -Values $many.Values
    Assert-True ((Get-TestValues -InputContext $manyContext -Options $options).Plan.Operations.Count -eq 0) 'Multiple-section repeat does not duplicate sections'
}
finally { Set-Item -Path Function:\Get-SCMiningSupplementalLocationMap -Value $originalMapFunction }

# The baseline generator without the new optional parameter remains backward compatible.
$surfaceInventory = $locationIndex.ByKey['Stanton2c_Desc']
$legacy = Update-SCMiningCraftBlockMethods -Value 'Legacy lore' -Inventory $surfaceInventory -DetailedCraftBlock ''
Assert-True (-not $legacy.Contains($header) -and $legacy.StartsWith('Legacy lore')) 'Existing callers without supplemental blocks keep their old behavior'
$rawBeltBody = Format-SCMiningPlanetCraftBlock -Inventory $locationIndex.SupplementalByKey['Stanton2c_Desc'][0].Inventory -PlanetCraftMap @{} -SelectedMethods @() -BodyOnly
Assert-True ($rawBeltBody.Contains('Ouratite 10%') -and -not $rawBeltBody.Contains((Get-SCMiningCraftHeader))) 'A belt without available recipes still renders its reference resources without a duplicate common header'
Write-Host 'Planet asteroid belt sections: PASS'
