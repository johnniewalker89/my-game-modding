$ErrorActionPreference = 'Stop'

$script:SCLocalizationRelativePath = 'data\Localization\korean_(south_korea)\global.ini'

function Get-SCGlobalIniPath {
    param([string]$LivePath)

    if ([string]::IsNullOrWhiteSpace($LivePath)) {
        return $null
    }

    return (Join-Path $LivePath $script:SCLocalizationRelativePath)
}

function Resolve-SCGlobalIniPath {
    param(
        [string]$LivePath,
        [string]$GlobalIniPath
    )

    if (-not [string]::IsNullOrWhiteSpace($GlobalIniPath)) {
        $resolved = [System.IO.Path]::GetFullPath($GlobalIniPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "global.ini not found: $resolved"
        }
        return $resolved
    }

    if ([string]::IsNullOrWhiteSpace($LivePath)) {
        throw 'LivePath is required.'
    }

    $root = [System.IO.Path]::GetFullPath($LivePath)
    $candidates = @(
        (Join-Path $root $script:SCLocalizationRelativePath),
        (Join-Path (Join-Path $root 'LIVE') $script:SCLocalizationRelativePath)
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    throw "global.ini not found. Expected: <LIVE>\$($script:SCLocalizationRelativePath)"
}

function Test-SCLivePath {
    param([string]$LivePath)

    $globalIni = Get-SCGlobalIniPath -LivePath $LivePath
    return (-not [string]::IsNullOrWhiteSpace($globalIni) -and (Test-Path -LiteralPath $globalIni -PathType Leaf))
}

function Find-SCDefaultLivePath {
    $candidates = @(
        'C:\Games\StarCitizen\LIVE',
        'C:\Program Files\Roberts Space Industries\StarCitizen\LIVE',
        'C:\Program Files (x86)\Roberts Space Industries\StarCitizen\LIVE',
        (Join-Path $env:USERPROFILE 'Games\StarCitizen\LIVE')
    )

    foreach ($candidate in $candidates) {
        if (Test-SCLivePath -LivePath $candidate) {
            return $candidate
        }
    }

    return ''
}

function Get-SCTextEncodingInfo {
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

function Repair-SCEmphasisTags {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

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

function Read-SCLocalizationData {
    param(
        [string]$LivePath,
        [string]$GlobalIniPath
    )

    $globalIni = Resolve-SCGlobalIniPath -LivePath $LivePath -GlobalIniPath $GlobalIniPath
    if (-not (Test-Path -LiteralPath $globalIni -PathType Leaf)) {
        throw "global.ini not found: $globalIni"
    }

    $encodingInfo = Get-SCTextEncodingInfo -Path $globalIni
    $originalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $globalIni).Hash
    $originalSize = (Get-Item -LiteralPath $globalIni).Length
    $lines = [System.IO.File]::ReadAllLines($globalIni, $encodingInfo.Encoding)
    $values = @{}
    $keyLineIndexes = @{}

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -match '^\s*([^=;\[][^=]*)=(.*)$') {
            $key = $Matches[1].Trim()
            $values[$key] = $Matches[2]
            $keyLineIndexes[$key] = $index
        }
    }

    return [pscustomobject]@{
        LivePath = $LivePath
        GlobalIniPath = $globalIni
        EncodingInfo = $encodingInfo
        OriginalSha256 = $originalHash
        OriginalSize = $originalSize
        Lines = $lines
        Values = $values
        KeyLineIndexes = $keyLineIndexes
        LineCount = @($lines).Count
        KeyCount = $values.Count
    }
}

function New-SCEmphasisRepairOperations {
    param([object]$Context)

    $operations = @()
    foreach ($key in @($Context.Values.Keys)) {
        $current = [string]$Context.Values[$key]
        $repaired = Repair-SCEmphasisTags -Value $current
        if ($repaired -ne $current) {
            $operations += [pscustomobject]@{
                ModuleId = 'shared'
                OptionId = 'emTagRepair'
                Key = $key
                Operation = 'replaceValue'
                OriginalValue = $current
                NewValue = $repaired
                OwnedMarkers = @()
            }
            $Context.Values[$key] = $repaired
        }
    }

    return @($operations)
}

function Import-SCModManifests {
    param([string]$ModulesRoot)

    if (-not (Test-Path -LiteralPath $ModulesRoot -PathType Container)) {
        throw "Modules folder not found: $ModulesRoot"
    }

    $manifestFiles = Get-ChildItem -LiteralPath $ModulesRoot -Filter 'manifest.json' -File -Recurse |
        Sort-Object FullName

    $modules = @()
    foreach ($file in $manifestFiles) {
        $manifest = Get-Content -Raw -LiteralPath $file.FullName -Encoding UTF8 | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($manifest.id)) {
            throw "Module manifest has no id: $($file.FullName)"
        }
        if ([string]::IsNullOrWhiteSpace($manifest.script)) {
            throw "Module manifest has no script: $($file.FullName)"
        }
        if ([string]::IsNullOrWhiteSpace($manifest.planFunction)) {
            throw "Module manifest has no planFunction: $($file.FullName)"
        }

        $modulePath = Split-Path -Parent $file.FullName
        $scriptPath = Join-Path $modulePath $manifest.script
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Module script not found: $scriptPath"
        }

        $modules += [pscustomobject]@{
            Id = [string]$manifest.id
            Name = [string]$manifest.name
            Description = [string]$manifest.description
            Version = [string]$manifest.version
            Manifest = $manifest
            ModulePath = $modulePath
            ScriptPath = $scriptPath
        }
    }

    return @($modules)
}

function Get-SCDefaultOptionsForModule {
    param([object]$Module)

    $selected = @()
    foreach ($option in @($Module.Manifest.options)) {
        if ($option.default -eq $true) {
            $selected += [string]$option.id
        }
    }

    return @($selected)
}

function Get-SCSelectedOptionsForModule {
    param(
        [object]$Module,
        [hashtable]$SelectedOptionsByModule
    )

    if ($SelectedOptionsByModule -and $SelectedOptionsByModule.ContainsKey($Module.Id)) {
        return @($SelectedOptionsByModule[$Module.Id])
    }

    return @(Get-SCDefaultOptionsForModule -Module $Module)
}

function Invoke-SCModulePlan {
    param(
        [object]$Module,
        [object]$Context,
        [string[]]$SelectedOptions
    )

    . $Module.ScriptPath
    $command = Get-Command -Name ([string]$Module.Manifest.planFunction) -CommandType Function -ErrorAction Stop
    $result = & $command -Context $Context -SelectedOptions $SelectedOptions

    if ($null -eq $result) {
        return [pscustomobject]@{
            ModuleId = $Module.Id
            Operations = @()
            Warnings = @("Module '$($Module.Id)' returned no patch plan.")
            Metadata = @{}
        }
    }

    return $result
}

function Test-SCPatchConflicts {
    param([object[]]$Operations)

    $conflicts = @()
    $operationsWithKeys = @($Operations | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Key) })

    foreach ($group in ($operationsWithKeys | Group-Object Key)) {
        if ($group.Count -le 1) {
            continue
        }

        $signatures = @($group.Group | ForEach-Object {
            "$($_.Operation)`n$($_.NewValue)"
        } | Sort-Object -Unique)

        $moduleIds = @($group.Group | ForEach-Object { $_.ModuleId } | Sort-Object -Unique)
        if ($signatures.Count -gt 1 -and $moduleIds.Count -gt 1) {
            $conflicts += [pscustomobject]@{
                Key = $group.Name
                Reason = 'Different modules want different changes for the same localization key.'
                Modules = $moduleIds
            }
        }
    }

    $markerClaims = @{}
    foreach ($operation in @($Operations)) {
        foreach ($marker in @($operation.OwnedMarkers)) {
            if ([string]::IsNullOrWhiteSpace($marker)) {
                continue
            }

            if (-not $markerClaims.ContainsKey($marker)) {
                $markerClaims[$marker] = @()
            }
            $markerClaims[$marker] += $operation.ModuleId
        }
    }

    foreach ($marker in $markerClaims.Keys) {
        $owners = @($markerClaims[$marker] | Sort-Object -Unique)
        if ($owners.Count -gt 1) {
            $conflicts += [pscustomobject]@{
                Key = $null
                Reason = "Different modules claim the same cleanup marker: $marker"
                Modules = $owners
            }
        }
    }

    return @($conflicts)
}

function Merge-SCPatchOperations {
    param(
        [object[]]$SharedOperations,
        [object[]]$ModuleOperations
    )

    $moduleKeys = @{}
    foreach ($operation in @($ModuleOperations)) {
        if (-not [string]::IsNullOrWhiteSpace($operation.Key)) {
            $moduleKeys[$operation.Key] = $true
        }
    }

    $merged = @()
    foreach ($operation in @($SharedOperations)) {
        if ([string]::IsNullOrWhiteSpace($operation.Key) -or -not $moduleKeys.ContainsKey($operation.Key)) {
            $merged += $operation
        }
    }

    $merged += @($ModuleOperations)
    return @($merged)
}

function Apply-SCPatchOperationsToLines {
    param(
        [object]$Context,
        [object[]]$Operations
    )

    $newLines = @($Context.Lines)
    $changedKeys = @()

    foreach ($operation in @($Operations)) {
        if ($operation.Operation -ne 'replaceValue') {
            throw "Unsupported patch operation '$($operation.Operation)' for key '$($operation.Key)'."
        }
        if ([string]::IsNullOrWhiteSpace($operation.Key)) {
            throw 'Patch operation key is required.'
        }
        if (-not $Context.KeyLineIndexes.ContainsKey($operation.Key)) {
            throw "Localization key not found: $($operation.Key)"
        }

        $index = [int]$Context.KeyLineIndexes[$operation.Key]
        $line = [string]$newLines[$index]
        if ($line -notmatch '^(\s*[^=;\[][^=]*=)(.*)$') {
            throw "Localization line could not be patched for key: $($operation.Key)"
        }

        $newLine = $Matches[1] + [string]$operation.NewValue
        if ($newLine -ne $line) {
            $newLines[$index] = $newLine
            $changedKeys += $operation.Key
        }
    }

    return [pscustomobject]@{
        Lines = $newLines
        ChangedKeys = @($changedKeys | Sort-Object -Unique)
        ChangedLineCount = @($changedKeys | Sort-Object -Unique).Count
    }
}

function New-SCBackup {
    param(
        [Parameter(Mandatory = $true)][string]$GlobalIniPath,
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [string]$Suffix = 'sc-mod-launcher'
    )

    if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupName = "global.ini.$stamp.$Suffix.bak"
    $backupPath = Join-Path $BackupDirectory $backupName
    Copy-Item -LiteralPath $GlobalIniPath -Destination $backupPath -Force
    Write-SCBackupMetadata -BackupPath $backupPath
    return $backupPath
}

function Get-SCBackupMetadataPath {
    param([Parameter(Mandatory = $true)][string]$BackupPath)

    return "$BackupPath.meta.json"
}

function Get-SCGlobalIniBackupState {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rawMiningMarkers = @(
        'Потенциально добываемые ресурсы (корабль):',
        'Потенциально добываемые ресурсы (наземная техника):',
        'Потенциально добываемые ресурсы (ручная добыча):'
    )
    $launcherMarkers = @(
        'Крафт-подсказка (SCMDB)',
        '<EM4>Доступные чертежи</EM4>'
    )
    $rawFound = New-Object System.Collections.Generic.List[string]
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($marker in $rawMiningMarkers) {
        if (Select-String -LiteralPath $Path -Pattern $marker -SimpleMatch -Quiet) {
            $rawFound.Add($marker)
        }
    }
    foreach ($marker in $launcherMarkers) {
        if (Select-String -LiteralPath $Path -Pattern $marker -SimpleMatch -Quiet) {
            $found.Add($marker)
        }
    }

    return [pscustomobject]@{
        kind = if ($found.Count -gt 0) { 'patched' } elseif ($rawFound.Count -gt 0) { 'clean' } else { 'clean' }
        rawMiningMarkers = @($rawFound.ToArray())
        markers = @($found.ToArray())
    }
}

function Write-SCBackupMetadata {
    param([Parameter(Mandatory = $true)][string]$BackupPath)

    try {
        $state = Get-SCGlobalIniBackupState -Path $BackupPath
        $file = Get-Item -LiteralPath $BackupPath
        $metadata = [pscustomobject]@{
            schemaVersion = 1
            createdAt = (Get-Date).ToString('o')
            fileName = $file.Name
            sha256 = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash
            kind = [string]$state.kind
            rawMiningMarkers = @($state.rawMiningMarkers)
            launcherMarkers = @($state.markers)
        }
        $json = $metadata | ConvertTo-Json -Depth 6
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Get-SCBackupMetadataPath -BackupPath $BackupPath), $json, $encoding)
    }
    catch {
        # Backup itself is the safety artifact; metadata is useful but non-critical.
    }
}

function Write-SCJsonReport {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $reportDir = Split-Path -Parent $ReportPath
    if (-not (Test-Path -LiteralPath $reportDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    }

    $reportJson = $Report | ConvertTo-Json -Depth 12
    $reportEncoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ReportPath, $reportJson, $reportEncoding)
}

function Invoke-SCModPatchPlan {
    param(
        [string]$LivePath,
        [string]$GlobalIniPath,
        [string]$ScriptRoot,
        [hashtable]$SelectedOptionsByModule
    )

    $modulesRoot = Join-Path $ScriptRoot 'modules'
    $modules = Import-SCModManifests -ModulesRoot $modulesRoot
    $context = Read-SCLocalizationData -LivePath $LivePath -GlobalIniPath $GlobalIniPath
    $sharedOperations = @(New-SCEmphasisRepairOperations -Context $context)

    $moduleReports = @()
    $moduleOperations = @()
    $allWarnings = @()

    foreach ($module in $modules) {
        $selectedOptions = @(Get-SCSelectedOptionsForModule -Module $module -SelectedOptionsByModule $SelectedOptionsByModule)
        $plan = Invoke-SCModulePlan -Module $module -Context $context -SelectedOptions $selectedOptions
        $operations = @($plan.Operations)
        $warnings = @($plan.Warnings)

        $moduleOperations += $operations
        $allWarnings += $warnings
        $moduleReports += [pscustomobject]@{
            id = $module.Id
            name = $module.Name
            selectedOptions = $selectedOptions
            operationCount = $operations.Count
            warnings = $warnings
            metadata = $plan.Metadata
        }
    }

    $allOperations = @(Merge-SCPatchOperations -SharedOperations $sharedOperations -ModuleOperations $moduleOperations)
    $conflicts = @(Test-SCPatchConflicts -Operations $allOperations)
    $applyPreview = $null
    if ($conflicts.Count -eq 0) {
        $applyPreview = Apply-SCPatchOperationsToLines -Context $context -Operations $allOperations
    }

    return [pscustomobject]@{
        Context = $context
        Modules = $modules
        ModuleReports = $moduleReports
        SharedOperations = $sharedOperations
        ModuleOperations = $moduleOperations
        Operations = $allOperations
        Conflicts = $conflicts
        Warnings = $allWarnings
        ApplyPreview = $applyPreview
    }
}

function Invoke-SCModPatch {
    param(
        [string]$LivePath,
        [string]$GlobalIniPath,
        [string]$ScriptRoot,
        [hashtable]$SelectedOptionsByModule,
        [string]$ReportDirectory,
        [string]$BackupDirectory,
        [string]$ReportPrefix = 'sc-mod-launcher',
        [switch]$DryRun,
        [switch]$NoBackup
    )

    if ([string]::IsNullOrWhiteSpace($ReportDirectory)) {
        $ReportDirectory = Join-Path $ScriptRoot 'reports'
    }
    if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
        $BackupDirectory = Join-Path $ScriptRoot 'backups'
    }

    $plan = Invoke-SCModPatchPlan -LivePath $LivePath -GlobalIniPath $GlobalIniPath -ScriptRoot $ScriptRoot -SelectedOptionsByModule $SelectedOptionsByModule
    $context = $plan.Context
    $changedLineCount = 0
    $changedKeys = @()
    if ($plan.ApplyPreview) {
        $changedLineCount = [int]$plan.ApplyPreview.ChangedLineCount
        $changedKeys = @($plan.ApplyPreview.ChangedKeys)
    }

    $backupPath = $null
    $newHash = $null
    $writeAttempted = $false
    $writeSucceeded = $false

    if (-not $DryRun -and $plan.Conflicts.Count -eq 0 -and $changedLineCount -gt 0) {
        $writeAttempted = $true
        if (-not $NoBackup) {
            $backupPath = New-SCBackup -GlobalIniPath $context.GlobalIniPath -BackupDirectory $BackupDirectory
        }

        [System.IO.File]::WriteAllLines($context.GlobalIniPath, $plan.ApplyPreview.Lines, $context.EncodingInfo.Encoding)
        $newHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $context.GlobalIniPath).Hash
        $writeSucceeded = $true
    }

    $report = [pscustomobject]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        writeAttempted = $writeAttempted
        writeSucceeded = $writeSucceeded
        livePath = $context.LivePath
        globalIniPath = $context.GlobalIniPath
        encoding = $context.EncodingInfo.Name
        originalSize = $context.OriginalSize
        originalSha256 = $context.OriginalSha256
        newSha256 = $newHash
        backupPath = $backupPath
        lineCount = $context.LineCount
        keyCount = $context.KeyCount
        moduleCount = $plan.Modules.Count
        modules = $plan.ModuleReports
        operationCount = @($plan.Operations).Count
        sharedOperationCount = @($plan.SharedOperations).Count
        moduleOperationCount = @($plan.ModuleOperations).Count
        changedLines = $changedLineCount
        changedKeysSample = @($changedKeys | Select-Object -First 20)
        fixedMalformedEmphasisLines = @($plan.SharedOperations | Where-Object { $_.ModuleId -eq 'shared' -and $_.OptionId -eq 'emTagRepair' }).Count
        fixedMalformedEmphasisKeysSample = @($plan.SharedOperations | Where-Object { $_.ModuleId -eq 'shared' -and $_.OptionId -eq 'emTagRepair' } | ForEach-Object { $_.Key } | Select-Object -First 20)
        conflictCount = $plan.Conflicts.Count
        conflicts = $plan.Conflicts
        warnings = $plan.Warnings
        operations = $plan.Operations
    }

    return [pscustomobject]@{
        Report = $report
        ReportPath = $null
    }
}

function Invoke-SCModDryRun {
    param(
        [string]$LivePath,
        [string]$GlobalIniPath,
        [string]$ScriptRoot,
        [hashtable]$SelectedOptionsByModule,
        [string]$ReportDirectory
    )

    return Invoke-SCModPatch -LivePath $LivePath -GlobalIniPath $GlobalIniPath -ScriptRoot $ScriptRoot -SelectedOptionsByModule $SelectedOptionsByModule -ReportDirectory $ReportDirectory -DryRun
}

function New-SCStagingLiveCopy {
    param(
        [Parameter(Mandatory = $true)][string]$SourceLivePath,
        [Parameter(Mandatory = $true)][string]$StagingRoot
    )

    $sourceGlobalIni = Resolve-SCGlobalIniPath -LivePath $SourceLivePath
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stageDir = Join-Path $StagingRoot "staging-$stamp"
    $stageLivePath = Join-Path $stageDir 'LIVE'
    $stageLocalizationDir = Join-Path $stageLivePath 'data\Localization\korean_(south_korea)'
    $stageGlobalIni = Join-Path $stageLocalizationDir 'global.ini'

    New-Item -ItemType Directory -Force -Path $stageLocalizationDir | Out-Null
    Copy-Item -LiteralPath $sourceGlobalIni -Destination $stageGlobalIni -Force

    return [pscustomobject]@{
        SourceLivePath = [System.IO.Path]::GetFullPath($SourceLivePath)
        SourceGlobalIniPath = $sourceGlobalIni
        StagingDirectory = $stageDir
        StagingLivePath = $stageLivePath
        StagingGlobalIniPath = $stageGlobalIni
    }
}

function Invoke-SCModStagingApply {
    param(
        [string]$LivePath,
        [string]$ScriptRoot,
        [hashtable]$SelectedOptionsByModule,
        [string]$StagingRoot
    )

    if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
        $StagingRoot = Join-Path (Join-Path $ScriptRoot 'reports') 'staging'
    }

    $staging = New-SCStagingLiveCopy -SourceLivePath $LivePath -StagingRoot $StagingRoot
    $reportDir = Join-Path $staging.StagingDirectory 'reports'
    $backupDir = Join-Path $staging.StagingDirectory 'backups'

    $result = Invoke-SCModPatch `
        -LivePath $staging.StagingLivePath `
        -ScriptRoot $ScriptRoot `
        -SelectedOptionsByModule $SelectedOptionsByModule `
        -ReportDirectory $reportDir `
        -BackupDirectory $backupDir `
        -ReportPrefix 'sc-mod-launcher-staging'

    return [pscustomobject]@{
        Report = $result.Report
        ReportPath = $result.ReportPath
        SourceLivePath = $staging.SourceLivePath
        SourceGlobalIniPath = $staging.SourceGlobalIniPath
        StagingDirectory = $staging.StagingDirectory
        StagingLivePath = $staging.StagingLivePath
        StagingGlobalIniPath = $staging.StagingGlobalIniPath
    }
}
