param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$CoreScript = Join-Path $ProjectDir 'shared\SC_Localization_Core.ps1'
. $CoreScript
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

$highlightedScripTitle = Set-SCQuestTitleHighlight -Value '[С] ОТВЕТНЫЙ УДАР' -Enabled $true -Tag 'EM4'
Assert-True ($highlightedScripTitle -eq '[С] <EM4>ОТВЕТНЫЙ УДАР</EM4>') 'High-value scrip highlight should wrap title text after markers.'
Assert-True ((Set-SCQuestTitleHighlight -Value $highlightedScripTitle -Enabled $true -Tag 'EM4') -eq $highlightedScripTitle) 'High-value scrip highlight should be idempotent.'
Assert-True ((Set-SCQuestTitleHighlight -Value $highlightedScripTitle -Enabled $false -Tag 'EM4') -eq '[С] ОТВЕТНЫЙ УДАР') 'High-value scrip highlight should be removable.'
Assert-True ((Set-SCQuestTitleHighlight -Value '[С] <EM2>ОТВЕТНЫЙ УДАР</EM2>' -Enabled $true -Tag 'EM4') -eq '[С] <EM4>ОТВЕТНЫЙ УДАР</EM4>') 'High-value scrip highlight should migrate old title highlight tags.'
Assert-True ((Set-SCQuestTitleHighlight -Value '<EM4>[А]</EM4> [С] ТАКТИЧЕСКИЙ УДАР' -Enabled $true -Tag 'EM4') -eq '<EM4>[А]</EM4> [С] <EM4>ТАКТИЧЕСКИЙ УДАР</EM4>') 'High-value scrip highlight should preserve styled title markers.'

$questEngineRoot = Join-Path $ProjectDir 'modules\quest\engine'
Assert-True (Test-Path -LiteralPath (Join-Path $questEngineRoot 'SC_Quest_Recipe_Engine.ps1') -PathType Leaf) 'Quest recipe engine should be packaged.'
Assert-True (Test-Path -LiteralPath (Join-Path $questEngineRoot 'data\blueprint-overrides.ru.json') -PathType Leaf) 'Quest recipe overrides should be packaged.'
Assert-True (Test-SCQuestAllSelectableCategoriesSelected -SelectedCategoryNames (Get-SCQuestSelectableCategoryNames)) 'All quest categories should be detected as full selection.'
Assert-True (-not (Test-SCQuestAllSelectableCategoriesSelected -SelectedCategoryNames @('Корабельные компоненты', 'Корабельные орудия'))) 'Partial quest category selection should not be treated as full selection.'
Assert-True (-not ((Get-SCQuestSelectableCategoryNames) -contains 'Материалы/особое')) 'Materials/special should not be a selectable quest category.'
$questBlockWithHiddenMaterial = "Quest\n\n<EM4>Доступные чертежи</EM4>\n<EM4>Корабельные компоненты</EM4>\n- FR-86 — щит\n\n<EM4>Материалы/особое</EM4>\n- Metamaterial Test #146 — метаматериал"
$questFiltered = Select-SCQuestRewardBlockCategories -Value $questBlockWithHiddenMaterial -SelectedCategoryNames (Get-SCQuestSelectableCategoryNames)
Assert-True ($questFiltered.Contains('FR-86')) 'Quest filtering should keep visible categories.'
Assert-True (-not $questFiltered.Contains('Материалы/особое')) 'Quest filtering should remove hidden materials/special category.'
Assert-True (-not $questFiltered.Contains('Metamaterial Test')) 'Quest filtering should remove test metamaterial recipes.'
Assert-True ((Get-SCQuestPossibleTitleKeys -DescriptionKey 'Foxwell_destroyprobe_M_desc_001') -contains 'Foxwell_destroyprobe_M_name_001') 'Quest blueprint marker cleanup should link _desc keys to _name keys.'
Assert-True (Test-SCQuestLooksLikeTitleKey -Key 'Foxwell_destroyprobe_M_name_001') 'Quest blueprint marker cleanup should treat _name keys as title-like keys.'
Assert-True ((Remove-SCQuestBlueprintTitleMarker -Value '[Ч] КОНТРАКТ ОРАНЖЕВОГО УРОВНЯ') -eq 'КОНТРАКТ ОРАНЖЕВОГО УРОВНЯ') 'Quest blueprint marker cleanup should remove [CH] marker from name values.'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-mod-launcher-test-" + [guid]::NewGuid().ToString('N'))
$liveRoot = Join-Path $tempRoot 'LIVE'
$localizationDir = Join-Path $liveRoot 'data\Localization\korean_(south_korea)'
$globalIni = Join-Path $localizationDir 'global.ini'
$reports = Join-Path $tempRoot 'reports'
$backups = Join-Path $tempRoot 'backups'

New-Item -ItemType Directory -Force -Path $localizationDir | Out-Null

$encoding = New-Object System.Text.UTF8Encoding($true)
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
$defaultMiningCraftFilters = @('componentClassMilitary', 'componentClassStealth', 'shipWeaponEnergy', 'shipWeaponBallistic', 'armorHeavy', 'armorMedium', 'fpsRifles', 'fpsSniperRifles', 'fpsSmgs', 'fpsLmgs')
$allMethods = @{ mining = @('shipMining', 'groundVehicleMining', 'multitoolMining') + $defaultMiningCraftFilters; quest = $allQuestOptions }
$shipOnly = @{ mining = @('shipMining') + $defaultMiningCraftFilters; quest = $allQuestOptions }

$dryRun = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $allMethods -ReportDirectory $reports -BackupDirectory $backups -DryRun
Assert-True ($dryRun.Report.dryRun -eq $true) 'Dry-run report should be marked dryRun.'
Assert-True ($dryRun.Report.writeAttempted -eq $false) 'Dry-run must not attempt writes.'
Assert-True ([int]$dryRun.Report.fixedMalformedEmphasisLines -eq 1) 'Dry-run should detect one malformed EM line.'
Assert-True ([int]$dryRun.Report.changedLines -eq 3) 'Dry-run should preview EM repair plus two mining fixture changes.'
Assert-True ((Get-FileHash -LiteralPath $globalIni -Algorithm SHA256).Hash -eq $initialHash) 'Dry-run must not change fixture file.'

$apply = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $allMethods -ReportDirectory $reports -BackupDirectory $backups
Assert-True ($apply.Report.dryRun -eq $false) 'Apply report should not be marked dryRun.'
Assert-True ($apply.Report.writeAttempted -eq $true) 'Apply should attempt write when changes exist.'
Assert-True ($apply.Report.writeSucceeded -eq $true) 'Apply should succeed.'
Assert-True ([int]$apply.Report.fixedMalformedEmphasisLines -eq 1) 'Apply should report one malformed EM line.'
Assert-True ([int]$apply.Report.changedLines -eq 3) 'Apply should change EM repair plus two mining fixture lines.'
Assert-True (-not [string]::IsNullOrWhiteSpace($apply.Report.backupPath)) 'Apply should create backup path.'
Assert-True (Test-Path -LiteralPath $apply.Report.backupPath -PathType Leaf) 'Backup file should exist.'
$applyBackupMetadataPath = "$($apply.Report.backupPath).meta.json"
Assert-True (Test-Path -LiteralPath $applyBackupMetadataPath -PathType Leaf) 'Apply backup metadata should exist.'
$applyBackupMetadata = Get-Content -LiteralPath $applyBackupMetadataPath -Encoding UTF8 -Raw | ConvertFrom-Json
Assert-True ([string]$applyBackupMetadata.kind -eq 'patched') 'Backup made from already patched fixture should be marked patched.'

$patched = [System.IO.File]::ReadAllText($globalIni, $encoding)
Assert-True ($patched.Contains('<EM4>~mission(Destination|Address)</EM4>')) 'Patched file should contain repaired EM tag.'

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
Assert-True ([int]$allMethodsAfterShipOnly.Report.changedLines -eq 0) 'All-method legacy fallback should be idempotent without a recipe map.'
Assert-True ([int]$allMethodsAfterShipOnly.Report.moduleOperationCount -eq 0) 'All-method legacy fallback should produce no operations without a recipe map.'

$allMethodsRestore = Invoke-SCModPatch -LivePath $liveRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $allMethods -ReportDirectory $reports -BackupDirectory $backups
Assert-True ($allMethodsRestore.Report.writeAttempted -eq $false) 'All-method legacy fallback should not write when already idempotent.'
$allRestored = [System.IO.File]::ReadAllText($globalIni, $encoding)
Assert-True (-not $allRestored.Contains($legendPrefix)) 'All-method restore should keep the new legend-free mining format.'
Assert-True ($allRestored.Contains('Наземная техника')) 'All-method restore should keep ground section.'
Assert-True ($allRestored.Contains('Мультитул')) 'All-method restore should keep hand section.'

$stageSourceRoot = Join-Path $tempRoot 'StageSource\LIVE'
$stageSourceLoc = Join-Path $stageSourceRoot 'data\Localization\korean_(south_korea)'
$stageSourceGlobalIni = Join-Path $stageSourceLoc 'global.ini'
$stageRoot = Join-Path $tempRoot 'staging-root'
New-Item -ItemType Directory -Force -Path $stageSourceLoc | Out-Null
[System.IO.File]::WriteAllLines($stageSourceGlobalIni, $initialLines, $encoding)
$stageSourceHash = (Get-FileHash -LiteralPath $stageSourceGlobalIni -Algorithm SHA256).Hash

$stagingApply = Invoke-SCModStagingApply -LivePath $stageSourceRoot -ScriptRoot $ProjectDir -SelectedOptionsByModule $shipOnly -StagingRoot $stageRoot
Assert-True ($stagingApply.Report.writeSucceeded -eq $true) 'Staging apply should write staging file.'
Assert-True ([int]$stagingApply.Report.changedLines -eq 3) 'Staging apply should change EM repair, mining filter, and raw mining fixture lines.'
Assert-True (Test-Path -LiteralPath $stagingApply.StagingGlobalIniPath -PathType Leaf) 'Staging global.ini should exist.'
Assert-True (Test-Path -LiteralPath $stagingApply.Report.backupPath -PathType Leaf) 'Staging backup should exist.'
Assert-True ((Get-FileHash -LiteralPath $stageSourceGlobalIni -Algorithm SHA256).Hash -eq $stageSourceHash) 'Staging apply must not change source file.'

$stagingText = [System.IO.File]::ReadAllText($stagingApply.StagingGlobalIniPath, $encoding)
Assert-True ($stagingText.Contains('<EM4>~mission(Destination|Address)</EM4>')) 'Staging file should contain repaired EM tag.'
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
$defaultCraftFilter = Get-SCMiningCraftFilter -SelectedOptions $defaultMiningCraftFilters

$methodCombos = @(
    @{ selected = @(); include = @('Фильтр: отключён, способы добычи не выбраны.', 'Корабль', 'Наземная техника', 'Мультитул', 'Copper, Iron', 'Beradon', 'Hadanite'); exclude = @('Фильтр: по выбранным галкам крафта; компоненты только Grade A.', 'Karna Rifle', 'AD Ballistic Gatlings', 'P6-LR Sniper Rifle', 'Coda Pistol', 'Palisade') },
    @{ selected = @($shipCode); include = @('Корабль', 'Karna Rifle', 'FR-86'); exclude = @('Наземная техника</EM4>\n<EM4>Корабельные орудия', 'Мультитул</EM4>\n<EM4>Оружие', 'Coda Pistol', 'Palisade') },
    @{ selected = @($groundCode); include = @('Наземная техника', 'AD Ballistic Gatlings'); exclude = @('Корабль</EM4>\n<EM4>Оружие', 'Мультитул</EM4>\n<EM4>Оружие', 'Coda Pistol', 'Palisade') },
    @{ selected = @($handCode); include = @('Мультитул', 'P6-LR Sniper Rifle'); exclude = @('Корабль</EM4>\n<EM4>Оружие', 'Наземная техника</EM4>\n<EM4>Корабельные орудия', 'Coda Pistol', 'Palisade') },
    @{ selected = @($shipCode, $groundCode); include = @('Корабль', 'Karna Rifle', 'Наземная техника', 'AD Ballistic Gatlings'); exclude = @('Мультитул</EM4>\n<EM4>Оружие', 'Coda Pistol', 'Palisade') },
    @{ selected = @($shipCode, $handCode); include = @('Корабль', 'Karna Rifle', 'Мультитул', 'P6-LR Sniper Rifle'); exclude = @('Наземная техника</EM4>\n<EM4>Корабельные орудия', 'Coda Pistol', 'Palisade') },
    @{ selected = @($groundCode, $handCode); include = @('Наземная техника', 'AD Ballistic Gatlings', 'Мультитул', 'P6-LR Sniper Rifle'); exclude = @('Корабль</EM4>\n<EM4>Оружие', 'Coda Pistol', 'Palisade') },
    @{ selected = @($shipCode, $groundCode, $handCode); include = @('Корабль', 'Karna Rifle', 'Наземная техника', 'AD Ballistic Gatlings', 'Мультитул', 'P6-LR Sniper Rifle'); exclude = @('Coda Pistol', 'Palisade') }
)

foreach ($combo in $methodCombos) {
    $block = Format-SCMiningPlanetCraftBlock -Inventory $methodInventory -PlanetCraftMap $planetCraftMap -SelectedMethods $combo.selected -CraftFilter $defaultCraftFilter
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
        Assert-True ($blockText.Contains('Ресурсы: Copper, Iron')) 'Selected ship mining should still show the full raw resource list, not only resources used by filtered recipes.'
    }
    else {
        Assert-True (-not $blockText.Contains('- Karna Rifle: Iron')) 'Unselected ship mining should show only resource reference, not detailed Karna recipe.'
        Assert-True ($blockText.Contains('Copper, Iron')) 'Unselected ship mining should keep the full raw resource list.'
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

$noMethodBlock = Format-SCMiningPlanetCraftBlock -Inventory $methodInventory -PlanetCraftMap $planetCraftMap -SelectedMethods @() -CraftFilter $defaultCraftFilter
Assert-True ($noMethodBlock.Contains('Copper, Iron')) 'No mining methods selected should still show ship resources as reference.'
Assert-True ($noMethodBlock.Contains('Beradon')) 'No mining methods selected should still show ground resources as reference.'
Assert-True ($noMethodBlock.Contains('Hadanite')) 'No mining methods selected should still show hand resources as reference.'
Assert-True (-not $noMethodBlock.Contains('- Karna Rifle')) 'No mining methods selected should not expand detailed recipes.'

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
$restoredPlanetValue = Update-SCMiningCraftBlockMethods -Value $corruptPlanetValue -SelectedMethods @($shipCode) -PlanetCraftMap $planetCraftMap -CraftFilter $defaultCraftFilter -Inventory $methodInventory
Assert-True ($restoredPlanetValue.Contains('- Karna Rifle: Iron')) 'Cached raw inventory should restore detailed recipes after a repeated apply.'
Assert-True (-not $restoredPlanetValue.Contains('<EM4>Корабельные орудия</EM4>, <EM4>Энергетика:</EM4>')) 'Repeated apply should not keep EM headings as resource text.'

Write-Host 'SC_Mod_Launcher scaffold tests passed.'
Write-Host "Temp root: $tempRoot"
