function Get-SCQuestPatchPlan {
    param(
        [object]$Context,
        [string[]]$SelectedOptions
    )

    $selectedCategoryNames = @(Get-SCQuestSelectedCategoryNames -SelectedOptions $SelectedOptions)
    $selectedFamilyOptionIds = @(Get-SCQuestSelectedFamilyOptionIds -SelectedOptions $SelectedOptions)
    $familyIndex = Get-SCQuestCraftFamilyIndex
    $allSelectableCategoriesSelected = Test-SCQuestAllSelectableCategoriesSelected -SelectedCategoryNames $selectedCategoryNames
    $enableHighValueScripHighlights = @($SelectedOptions) -contains 'highValueScripHighlights'
    $enableWikeloItemHints = @($SelectedOptions) -contains 'wikeloItemHints'
    $enableReputationHints = @($SelectedOptions) -contains 'reputationHints'
    $metadata = @{
        source = 'SC Quest Recipe Engine'
        selectedOptionCount = @($SelectedOptions).Count
        selectedBlueprintCategories = @($selectedCategoryNames)
        selectedRecipeFamilies = @($selectedFamilyOptionIds).Count
        highValueScripHighlightsEnabled = $enableHighValueScripHighlights
        wikeloItemHintsEnabled = $enableWikeloItemHints
        reputationHintsEnabled = $enableReputationHints
        blueprintMarkerPolicy = 'Title marker [CH] is kept only when the contract has visible selected blueprint categories.'
        specialMarkerPolicy = 'Ace pilot [A] and scrip [S] markers are always kept when reported by SCMDB; high-value scrip title highlighting is optional.'
        inspectedKeys = $Context.KeyCount
        engine = $null
        engineExitCode = $null
        generatedDescriptionBlocks = 0
        keptDescriptionBlocks = 0
        filteredDescriptionBlocks = 0
        highValueScripHighlightConfigured = 0
        highValueScripHighlightFound = 0
        highValueScripHighlightChanged = 0
        wikeloItemHints = $null
        changedDescriptionLines = 0
        changedTitleLines = 0
        allSelectableCategoriesSelected = $allSelectableCategoriesSelected
    }

    if ($Context.KeyCount -lt 1000) {
        $metadata.engine = 'skipped-small-fixture'
        return [pscustomobject]@{
            ModuleId = 'quest'
            Operations = @()
            Warnings = @('Quest module skipped SCMDB recipe pass for a small test fixture.')
            Metadata = $metadata
        }
    }

    Write-Host 'Progress: quest engine start'
    $engine = Invoke-SCQuestRecipeEngine -Context $Context -EnableReputationHints:$enableReputationHints
    Write-Host 'Progress: quest engine done'
    $metadata.engine = $engine.EnginePath
    $metadata.engineExitCode = $engine.ExitCode

    if ($engine.ExitCode -ne 0) {
        return [pscustomobject]@{
            ModuleId = 'quest'
            Operations = @()
            Warnings = @("Quest module engine failed with exit code $($engine.ExitCode). $($engine.Error)")
            Metadata = $metadata
        }
    }

    $originalValues = ConvertTo-SCQuestLineValueMap -Lines $Context.Lines
    $patchedValues = ConvertTo-SCQuestLineValueMap -Lines $engine.PatchedLines
    $titleVisibility = @{}
    $descriptionTitleMap = ConvertTo-SCQuestDescriptionTitleMap -TitleDescriptionMap $engine.Report.titleDescriptionMap
    $descriptionStats = @{
        generated = 0
        kept = 0
        filtered = 0
    }

    Write-Host 'Progress: quest filter start'
    foreach ($key in @($patchedValues.Keys)) {
        $value = [string]$patchedValues[$key]
        if (-not (Test-SCQuestHasRewardBlock -Value $value)) {
            continue
        }

        $descriptionStats.generated++
        $filteredValue = Select-SCQuestRewardBlockCategories -Value $value -SelectedCategoryNames $selectedCategoryNames -SelectedFamilyOptionIds $selectedFamilyOptionIds -FamilyIndex $familyIndex
        $patchedValues[$key] = Remove-SCQuestVisibleScmdbBranding -Value $filteredValue

        $hasVisibleRewardBlock = Test-SCQuestHasRewardBlock -Value $filteredValue
        foreach ($titleKey in Get-SCQuestLinkedTitleKeys -DescriptionKey $key -DescriptionTitleMap $descriptionTitleMap) {
            Add-SCQuestTitleVisibility -VisibilityMap $titleVisibility -TitleKey $titleKey -HasVisibleRewardBlock $hasVisibleRewardBlock
        }

        if ($hasVisibleRewardBlock) {
            $descriptionStats.kept++
        }
        else {
            $descriptionStats.filtered++
        }
    }

    if (-not $allSelectableCategoriesSelected) {
        foreach ($key in @($patchedValues.Keys)) {
            $value = [string]$patchedValues[$key]
            if (-not (Test-SCQuestLooksLikeTitleKey -Key $key)) {
                continue
            }

            $removeBlueprintMarker = $false
            $normalizedKey = Get-SCQuestNormalizedIniKey -Key $key
            if ($titleVisibility.ContainsKey($normalizedKey)) {
                $removeBlueprintMarker = ([int]$titleVisibility[$normalizedKey].Total -gt 0 -and [int]$titleVisibility[$normalizedKey].Visible -eq 0)
            }

            if ($removeBlueprintMarker) {
                $patchedValues[$key] = Remove-SCQuestBlueprintTitleMarker -Value $value
            }
        }
    }

    Write-Host 'Progress: quest filter done'
    Write-Host 'Progress: quest extras start'
    $highlightConfig = Get-SCQuestHighValueScripHighlightConfig
    $highlightStats = Set-SCQuestHighValueScripTitleHighlights -Values $patchedValues -Config $highlightConfig -Enable:$enableHighValueScripHighlights
    $wikeloHintStats = Set-SCQuestWikeloItemHints -Values $patchedValues -Enable:$enableWikeloItemHints
    Write-Host 'Progress: quest extras done'

    $operations = @()
    $changedDescriptionLines = 0
    $changedTitleLines = 0
    $changedWikeloHintLines = 0

    Write-Host 'Progress: quest diff start'
    foreach ($key in @($patchedValues.Keys | Sort-Object)) {
        if (-not $originalValues.ContainsKey($key)) {
            continue
        }

        $original = [string]$originalValues[$key]
        $newValue = [string]$patchedValues[$key]
        if ($newValue -eq $original) {
            continue
        }

        if ((Test-SCQuestHasRewardBlock -Value $original) -or (Test-SCQuestHasRewardBlock -Value $newValue)) {
            $changedDescriptionLines++
        }
        elseif ((Test-SCQuestHasWikeloItemHintBlock -Value $original) -or (Test-SCQuestHasWikeloItemHintBlock -Value $newValue)) {
            $changedWikeloHintLines++
        }
        elseif (Test-SCQuestLooksLikeTitleKey -Key $key) {
            $changedTitleLines++
        }

        $ownedMarkers = @('SCMDB_QUEST_REWARD_BLOCK', 'SCMDB_QUEST_TITLE_MARKERS')
        if ((Test-SCQuestHasWikeloItemHintBlock -Value $original) -or (Test-SCQuestHasWikeloItemHintBlock -Value $newValue)) {
            $ownedMarkers += 'SCMDB_WIKELO_ITEM_HINT'
        }

        $operations += [pscustomobject]@{
            ModuleId = 'quest'
            OptionId = 'questRewards'
            Key = $key
            Operation = 'replaceValue'
            OriginalValue = $original
            NewValue = $newValue
            OwnedMarkers = $ownedMarkers
        }
    }
    Write-Host 'Progress: quest diff done'

    $metadata.generatedDescriptionBlocks = $descriptionStats.generated
    $metadata.keptDescriptionBlocks = $descriptionStats.kept
    $metadata.filteredDescriptionBlocks = $descriptionStats.filtered
    $metadata.mappedTitleKeys = @($titleVisibility.Keys).Count
    $metadata.titleDescriptionLinks = @($descriptionTitleMap.Keys).Count
    $metadata.highValueScripHighlightConfigured = $highlightStats.Configured
    $metadata.highValueScripHighlightFound = $highlightStats.Found
    $metadata.highValueScripHighlightChanged = $highlightStats.Changed
    $metadata.highValueScripHighlightTag = $highlightConfig.Tag
    $metadata.wikeloItemHints = $wikeloHintStats
    $metadata.removedBlueprintTitleMarkers = @($patchedValues.Keys | Where-Object {
        $normalizedKey = Get-SCQuestNormalizedIniKey -Key $_
        (Test-SCQuestLooksLikeTitleKey -Key $_) -and
        $titleVisibility.ContainsKey($normalizedKey) -and
        [int]$titleVisibility[$normalizedKey].Total -gt 0 -and
        [int]$titleVisibility[$normalizedKey].Visible -eq 0
    }).Count
    $metadata.changedDescriptionLines = $changedDescriptionLines
    $metadata.changedWikeloHintLines = $changedWikeloHintLines
    $metadata.changedTitleLines = $changedTitleLines
    $metadata.engineReportPath = $engine.ReportPath
    $metadata.engineOutputSample = @($engine.OutputLines | Select-Object -First 20)

    return [pscustomobject]@{
        ModuleId = 'quest'
        Operations = @($operations)
        Warnings = @()
        Metadata = $metadata
    }
}

function Invoke-SCQuestRecipeEngine {
    param(
        [object]$Context,
        [switch]$EnableReputationHints
    )

    $moduleRoot = $PSScriptRoot
    $engineRoot = Join-Path $moduleRoot 'engine'
    $engineScript = Join-Path $engineRoot 'SC_Quest_Recipe_Engine.ps1'

    if (-not (Test-Path -LiteralPath $engineScript -PathType Leaf)) {
        throw "SC quest recipe engine not found: $engineScript"
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-quest-module-" + [guid]::NewGuid().ToString('N'))
    $tempLive = Join-Path $tempRoot 'LIVE'
    $tempLoc = Join-Path $tempLive 'data\Localization\korean_(south_korea)'
    $tempGlobal = Join-Path $tempLoc 'global.ini'
    $tempReport = Join-Path $tempRoot 'quest-engine-report.json'

    New-Item -ItemType Directory -Force -Path $tempLoc | Out-Null
    [System.IO.File]::WriteAllLines($tempGlobal, @($Context.Lines), $Context.EncodingInfo.Encoding)

    $arguments = @{
        GlobalIniPath = $tempGlobal
        NoBackup = $true
        NoCraftIntel = $true
        ReportPath = $tempReport
        OverridesPath = Join-Path $engineRoot 'data\blueprint-overrides.ru.json'
        WikiCachePath = Join-Path $engineRoot 'cache\wiki-items-cache.json'
    }
    if (-not $EnableReputationHints) {
        $arguments.NoReputationIntel = $true
    }

    $engineOutput = @()
    $exitCode = 0
    try {
        $engineOutput = @(& $engineScript @arguments 2>&1 | ForEach-Object { [string]$_ })
    }
    catch {
        $exitCode = 1
        $engineOutput += [string]$_
    }

    $patchedLines = @()
    if (Test-Path -LiteralPath $tempGlobal -PathType Leaf) {
        $patchedLines = [System.IO.File]::ReadAllLines($tempGlobal, $Context.EncodingInfo.Encoding)
    }

    $report = $null
    if (Test-Path -LiteralPath $tempReport -PathType Leaf) {
        $report = Get-Content -LiteralPath $tempReport -Raw | ConvertFrom-Json
    }

    return [pscustomobject]@{
        EnginePath = $engineScript
        TempRoot = $tempRoot
        ReportPath = $tempReport
        ExitCode = $exitCode
        Output = ($engineOutput -join [Environment]::NewLine)
        OutputLines = @($engineOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Error = if ($exitCode -eq 0) { '' } else { ($engineOutput -join [Environment]::NewLine) }
        PatchedLines = @($patchedLines)
        Report = $report
    }
}

function ConvertTo-SCQuestLineValueMap {
    param([string[]]$Lines)

    $values = @{}
    foreach ($line in @($Lines)) {
        if ($line -match '^\s*([^=;\[][^=]*)=(.*)$') {
            $key = ([string]$Matches[1]).Trim()
            $values[$key] = [string]$Matches[2]
        }
    }

    return $values
}

function Get-SCQuestHighValueScripHighlightConfig {
    $path = Join-Path $PSScriptRoot 'data\high-value-scrip-contracts.json'
    $empty = [pscustomobject]@{
        Tag = 'EM2'
        Keys = @{}
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $empty
    }

    $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $tag = if ($json.styleTag -match '^EM[1-5]$') { [string]$json.styleTag } else { 'EM2' }
    $keys = @{}
    foreach ($contract in @($json.contracts)) {
        if ($null -eq $contract -or [string]::IsNullOrWhiteSpace([string]$contract.titleKey)) {
            continue
        }

        $keys[(Get-SCQuestNormalizedIniKey -Key ([string]$contract.titleKey))] = $true
    }

    return [pscustomobject]@{
        Tag = $tag
        Keys = $keys
    }
}

function Set-SCQuestHighValueScripTitleHighlights {
    param(
        [hashtable]$Values,
        [object]$Config,
        [bool]$Enable = $true
    )

    $configured = @($Config.Keys.Keys).Count
    $found = 0
    $changed = 0

    foreach ($key in @($Values.Keys)) {
        if (-not (Test-SCQuestLooksLikeTitleKey -Key $key)) {
            continue
        }

        $normalizedKey = Get-SCQuestNormalizedIniKey -Key $key
        if (-not $Config.Keys.ContainsKey($normalizedKey)) {
            continue
        }

        $found++
        $current = [string]$Values[$key]
        $updated = Set-SCQuestTitleHighlight -Value $current -Enabled $Enable -Tag $Config.Tag
        if ($updated -ne $current) {
            $Values[$key] = $updated
            $changed++
        }
    }

    return [pscustomobject]@{
        Configured = $configured
        Found = $found
        Changed = $changed
    }
}

function Set-SCQuestTitleHighlight {
    param(
        [AllowEmptyString()][string]$Value,
        [bool]$Enabled,
        [string]$Tag = 'EM2'
    )

    if ($Tag -notmatch '^EM[1-5]$') {
        $Tag = 'EM2'
    }

    $prefix = ''
    $title = [string]$Value
    $markerPattern = '^\s*((?:<EM[1-5]>\[[^\]]+\]</EM[1-5]>|\[[^\]]+\])\s*)'
    while ($title -match $markerPattern) {
        $prefix += $Matches[1]
        $title = $title.Substring($Matches[0].Length)
    }

    $title = Remove-SCQuestTitleHighlight -Value $title -Tag $Tag
    if ([string]::IsNullOrWhiteSpace($title)) {
        return $prefix.TrimEnd()
    }

    if ($Enabled) {
        return $prefix + "<$Tag>$title</$Tag>"
    }

    return $prefix + $title
}

function Remove-SCQuestTitleHighlight {
    param(
        [AllowEmptyString()][string]$Value,
        [string]$Tag = 'EM2'
    )

    $clean = [string]$Value
    $pattern = '^\s*<EM[1-5]>(.*?)</EM[1-5]>\s*$'
    do {
        $before = $clean
        $clean = [regex]::Replace($clean, $pattern, '$1')
    }
    while ($clean -ne $before)

    return $clean
}

function Remove-SCQuestVisibleScmdbBranding {
    param([AllowEmptyString()][string]$Value)

    return [regex]::Replace(
        [string]$Value,
        '<EM(?<tag>[1-5])>(?<title>Доступные чертежи|Возможные чертежи) \(SCMDB\)</EM\k<tag>>',
        '<EM${tag}>${title}</EM${tag}>')
}

function Test-SCQuestHasWikeloItemHintBlock {
    param([AllowEmptyString()][string]$Value)

    return ([string]$Value -match '\\n\\n<EM\d>Wikelo(?:-| )заказы:?</EM\d>')
}

function Remove-SCQuestWikeloItemHintBlock {
    param([AllowEmptyString()][string]$Value)

    return [regex]::Replace(
        [string]$Value,
        '\\n\\n<EM\d>Wikelo(?:-| )заказы:?</EM\d>.*$',
        '',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

function ConvertTo-SCQuestArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return $Value
    }

    return @($Value)
}

function Get-SCQuestPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Invoke-SCQuestScmdbJson {
    param([Parameter(Mandatory = $true)][string]$Uri)

    try {
        return (Invoke-RestMethod -Uri $Uri -UseBasicParsing -TimeoutSec 20)
    }
    catch {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            $json = & curl.exe -L --silent --show-error --fail --max-time 40 `
                -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36' `
                -H 'Accept: application/json,text/plain,*/*' `
                -e 'https://scmdb.net/' `
                $Uri
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
                return ($json | ConvertFrom-Json)
            }
        }

        throw
    }
}

function Get-SCQuestScmdbData {
    $cacheDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scmdb\cache'
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        throw 'SCMDB cache is missing. Refresh cache before applying.'
    }

    $cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'scmdb-*.json' -File |
        Where-Object { $_.Name -notlike '*.meta.json' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $cacheFile) {
        throw 'SCMDB cache is missing. Refresh cache before applying.'
    }

    $payload = Get-Content -LiteralPath $cacheFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$payload.version) -or $null -eq $payload.data) {
        throw "SCMDB cache is invalid: $($cacheFile.FullName)"
    }

    return [pscustomobject]@{
        Version = [string]$payload.version
        Data = $payload.data
    }
}

function Get-SCQuestCleanWikeloShipName {
    param([AllowEmptyString()][string]$Name)

    $ship = (([string]$Name) -replace '\s+', ' ').Trim()
    $ship = [regex]::Replace($ship, '\s+Wikelo\s+(?:War|Work|Sneak|Savior|Speedy)?\s*Special\s*$', '', 'IgnoreCase').Trim()
    $ship = [regex]::Replace($ship, '\s+Wikelo\s+Special\s*$', '', 'IgnoreCase').Trim()
    $ship = [regex]::Replace($ship, '\s+Wikelo\s*$', '', 'IgnoreCase').Trim()

    return $ship
}

function Get-SCQuestWikeloOrderAmountLabel {
    param($Order)

    $min = Get-SCQuestPropertyValue -Object $Order -Name 'minAmount'
    $max = Get-SCQuestPropertyValue -Object $Order -Name 'maxAmount'
    $minValue = 0
    $maxValue = 0
    $hasMin = $null -ne $min -and [int]::TryParse([string]$min, [ref]$minValue)
    $hasMax = $null -ne $max -and [int]::TryParse([string]$max, [ref]$maxValue)
    if ($hasMin -and $minValue -le 0) {
        $hasMin = $false
    }
    if ($hasMax -and $maxValue -le 0) {
        $hasMax = $false
    }

    if ($hasMin -and $hasMax) {
        if ($minValue -eq $maxValue) {
            return [string]$minValue
        }

        return "$minValue-$maxValue"
    }

    if ($hasMin) {
        return [string]$minValue
    }

    if ($hasMax) {
        return [string]$maxValue
    }

    return ''
}

function New-SCQuestWikeloResourceShipMap {
    $scmdb = Get-SCQuestScmdbData
    $data = $scmdb.Data
    $contracts = @()
    $contracts += @(ConvertTo-SCQuestArray $data.contracts)
    $contracts += @(ConvertTo-SCQuestArray (Get-SCQuestPropertyValue -Object $data -Name 'legacyContracts'))

    $resources = @{}
    foreach ($contract in $contracts) {
        if ([string]$contract.debugName -notmatch 'TheCollector') {
            continue
        }

        $vehicleRewards = @(
            ConvertTo-SCQuestArray $contract.itemRewards |
                Where-Object { [string]$_.itemType -eq 'vehicle' -and -not [string]::IsNullOrWhiteSpace([string]$_.name) }
        )
        $orders = @(ConvertTo-SCQuestArray $contract.haulingOrders)
        if ($vehicleRewards.Count -eq 0 -or $orders.Count -eq 0) {
            continue
        }

        $ships = @(
            $vehicleRewards |
                ForEach-Object { Get-SCQuestCleanWikeloShipName -Name ([string]$_.name) } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        if ($ships.Count -eq 0) {
            continue
        }

        foreach ($order in $orders) {
            $resourceId = [string]$order.resource
            if ([string]::IsNullOrWhiteSpace($resourceId)) {
                continue
            }

            $resourcePool = Get-SCQuestPropertyValue -Object $data.resourcePools -Name $resourceId
            $resourceName = if ($resourcePool -and -not [string]::IsNullOrWhiteSpace([string]$resourcePool.name)) {
                [string]$resourcePool.name
            }
            else {
                $resourceId
            }
            if ($resourceName -eq 'Wikelo Favor') {
                continue
            }
            $amountLabel = Get-SCQuestWikeloOrderAmountLabel -Order $order

            if (-not $resources.ContainsKey($resourceName)) {
                $resources[$resourceName] = @{
                    Name = $resourceName
                    Ships = @{}
                    ResourceIds = @{}
                }
            }

            $resources[$resourceName].ResourceIds[$resourceId] = $true
            foreach ($ship in $ships) {
                if (-not $resources[$resourceName].Ships.ContainsKey($ship)) {
                    $resources[$resourceName].Ships[$ship] = $amountLabel
                }
                elseif (-not [string]::IsNullOrWhiteSpace($amountLabel) -and [string]$resources[$resourceName].Ships[$ship] -ne $amountLabel) {
                    $knownAmounts = @(
                        ([string]$resources[$resourceName].Ships[$ship]).Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
                        $amountLabel
                    ) | Sort-Object -Unique
                    $resources[$resourceName].Ships[$ship] = ($knownAmounts -join '/')
                }
            }
        }
    }

    return [pscustomobject]@{
        Version = $scmdb.Version
        Resources = $resources
    }
}

function Get-SCQuestWikeloDescriptionCandidates {
    param([Parameter(Mandatory = $true)][string]$NameKey)

    $candidates = New-Object System.Collections.Generic.List[string]
    function Add-Candidate([string]$Key) {
        if (-not [string]::IsNullOrWhiteSpace($Key)) {
            $candidates.Add($Key)
        }
    }

    function Add-ReplacedCandidate([string]$Pattern, [string]$Replacement) {
        $candidate = $NameKey -replace $Pattern, $Replacement
        if ($candidate -ne $NameKey) {
            Add-Candidate $candidate
        }
    }

    Add-ReplacedCandidate '_Name' '_Desc'
    Add-ReplacedCandidate '_name' '_desc'
    Add-ReplacedCandidate 'item_Name' 'item_Desc'
    Add-ReplacedCandidate 'item_name' 'item_desc'
    Add-ReplacedCandidate 'item_NameCarryable' 'item_DescCarryable'
    Add-ReplacedCandidate 'item_Name_Carryable' 'item_Desc_Carryable'
    Add-ReplacedCandidate 'vehicle_Name' 'vehicle_Desc'
    Add-Candidate ($NameKey + '_desc')
    Add-Candidate ($NameKey + '_des')

    if ($NameKey -match '^items_commodities_(.+)$') {
        Add-Candidate ($NameKey + '_desc')
        Add-Candidate ($NameKey + '_des')
        if ($NameKey -match 'valakkarfang_.*irradiated') {
            Add-Candidate 'items_commodities_valakkarfang_irradiated_desc'
        }
        elseif ($NameKey -match 'valakkarfang') {
            Add-Candidate 'items_commodities_valakkarfang_desc'
        }

        if ($NameKey -match 'valakkarpearl_.*irradiated') {
            Add-Candidate 'items_commodities_valakkarpearl_irradiated_desc'
        }
    }

    return @($candidates.ToArray() | Sort-Object -Unique)
}

function Resolve-SCQuestWikeloDescriptionKeys {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceName,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Values.GetEnumerator()) {
        $value = (([string]$entry.Value) -replace 'Â ', ' ' -replace [string][char]0x00A0, ' ').Trim()
        if ($value -ne $ResourceName) {
            continue
        }

        foreach ($candidate in Get-SCQuestWikeloDescriptionCandidates -NameKey ([string]$entry.Key)) {
            if ($Values.ContainsKey($candidate)) {
                $keys.Add($candidate)
            }
        }
    }

    return @($keys.ToArray() | Sort-Object -Unique)
}

function Format-SCQuestWikeloItemHintBlock {
    param([object[]]$Entries)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<EM4>Wikelo заказы:</EM4>')

    foreach ($entry in @($Entries | Sort-Object Name)) {
        $ships = @($entry.Ships | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) })
        if ($ships.Count -eq 0) {
            continue
        }

        foreach ($ship in @($ships | Sort-Object Name)) {
            $amount = [string]$ship.Amount
            if ([string]::IsNullOrWhiteSpace($amount)) {
                $lines.Add("- $($ship.Name)")
            }
            else {
                $lines.Add("- $amount на $($ship.Name)")
            }
        }
    }

    if ($lines.Count -le 1) {
        return ''
    }

    return ($lines.ToArray() -join '\n')
}

function Set-SCQuestWikeloItemHints {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [bool]$Enable = $true
    )

    $cleaned = 0
    foreach ($key in @($Values.Keys)) {
        $current = [string]$Values[$key]
        $clean = Remove-SCQuestWikeloItemHintBlock -Value $current
        if ($clean -ne $current) {
            $Values[$key] = $clean
            $cleaned++
        }
    }

    $stats = [ordered]@{
        enabled = [bool]$Enable
        scmdbVersion = ''
        resourceCount = 0
        mappedResources = 0
        unmappedResources = 0
        targetDescriptionKeys = 0
        changedItemDescriptions = 0
        cleanedExistingBlocks = $cleaned
        unmappedResourceSample = @()
    }

    if (-not $Enable) {
        return [pscustomobject]$stats
    }

    $wikelo = New-SCQuestWikeloResourceShipMap
    $stats.scmdbVersion = [string]$wikelo.Version
    $stats.resourceCount = @($wikelo.Resources.Keys).Count

    $targets = @{}
    $unmapped = New-Object System.Collections.Generic.List[string]
    foreach ($resourceName in @($wikelo.Resources.Keys | Sort-Object)) {
        $descriptionKeys = @(Resolve-SCQuestWikeloDescriptionKeys -ResourceName ([string]$resourceName) -Values $Values)
        if ($descriptionKeys.Count -eq 0) {
            $unmapped.Add([string]$resourceName)
            continue
        }

        $stats.mappedResources++
        $entry = [pscustomobject]@{
            Name = [string]$resourceName
            Ships = @(
                foreach ($shipName in @($wikelo.Resources[$resourceName].Ships.Keys | Sort-Object)) {
                    [pscustomobject]@{
                        Name = [string]$shipName
                        Amount = [string]$wikelo.Resources[$resourceName].Ships[$shipName]
                    }
                }
            )
        }

        foreach ($descriptionKey in $descriptionKeys) {
            if (-not $targets.ContainsKey($descriptionKey)) {
                $targets[$descriptionKey] = New-Object System.Collections.Generic.List[object]
            }
            $targets[$descriptionKey].Add($entry)
        }
    }

    foreach ($target in $targets.GetEnumerator()) {
        $key = [string]$target.Key
        $block = Format-SCQuestWikeloItemHintBlock -Entries @($target.Value)
        if ([string]::IsNullOrWhiteSpace($block)) {
            continue
        }

        $current = ([string]$Values[$key]).TrimEnd()
        $updated = $current + '\n\n' + $block
        if ($updated -ne [string]$Values[$key]) {
            $Values[$key] = $updated
            $stats.changedItemDescriptions++
        }
    }

    $stats.unmappedResources = $unmapped.Count
    $stats.targetDescriptionKeys = $targets.Keys.Count
    $stats.unmappedResourceSample = @($unmapped | Select-Object -First 20)

    return [pscustomobject]$stats
}

function Get-SCQuestSelectedCategoryNames {
    param([string[]]$SelectedOptions)

    $map = @{
        shipComponents = 'Корабельные компоненты'
        shipWeapons = 'Корабельные орудия'
        miningLasers = 'Добывающие лазеры'
        armorAndClothing = 'Броня/одежда'
        fpsWeapons = 'Оружие'
        equipmentAndConsumables = 'Снаряжение/расходники'
    }

    $names = @()
    foreach ($option in @('shipComponents', 'shipWeapons', 'miningLasers', 'armorAndClothing', 'fpsWeapons', 'equipmentAndConsumables')) {
        if ($SelectedOptions -contains $option) {
            $names += $map[$option]
        }
    }

    foreach ($optionId in @(Get-SCQuestSelectedFamilyOptionIds -SelectedOptions $SelectedOptions)) {
        $parts = ([string]$optionId).Split('|')
        if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
            $names += [string]$parts[1]
        }
    }

    return @($names | Sort-Object -Unique)
}

function Get-SCQuestSelectedFamilyOptionIds {
    param([string[]]$SelectedOptions)

    return @(
        @($SelectedOptions) |
            ForEach-Object { [string]$_ } |
            Where-Object { $_.StartsWith('questCraftFamily|', [System.StringComparison]::OrdinalIgnoreCase) }
    )
}

function Get-SCQuestCraftFamilyIndex {
    $cacheDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'mining\cache'
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return $null
    }

    $cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'craft-family-index-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $cacheFile) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $cacheFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-SCQuestFamilyOptionSuffix {
    param([AllowEmptyString()][string]$OptionId)

    $value = [string]$OptionId
    $separator = $value.IndexOf('|')
    if ($separator -lt 0) {
        return $value
    }

    return $value.Substring($separator + 1)
}

function Normalize-SCQuestRecipeName {
    param([AllowEmptyString()][string]$Name)

    return (([string]$Name) -replace 'Â ', ' ' -replace [string][char]0x00A0, ' ' -replace '\s+', ' ').Trim()
}

function New-SCQuestFamilyLookup {
    param([object]$FamilyIndex)

    $lookup = @{}
    if ($null -eq $FamilyIndex -or $null -eq $FamilyIndex.families) {
        return $lookup
    }

    foreach ($entry in @($FamilyIndex.families)) {
        $sourceOptionId = [string]$entry.optionId
        if ([string]::IsNullOrWhiteSpace($sourceOptionId)) {
            continue
        }

        $questOptionId = 'questCraftFamily|' + (Get-SCQuestFamilyOptionSuffix -OptionId $sourceOptionId)
        foreach ($name in @($entry.names)) {
            $normalized = Normalize-SCQuestRecipeName -Name ([string]$name)
            if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                $lookup[$normalized] = $questOptionId
            }
        }

        $label = Normalize-SCQuestRecipeName -Name ([string]$entry.label)
        if (-not [string]::IsNullOrWhiteSpace($label) -and -not $lookup.ContainsKey($label)) {
            $lookup[$label] = $questOptionId
        }
    }

    return $lookup
}

function Get-SCQuestRecipeNameFromRewardLine {
    param([AllowEmptyString()][string]$Line)

    $lineText = [string]$Line
    if ($lineText -notmatch '^\s*-\s*(.+)$') {
        return $null
    }

    $name = [string]$Matches[1]
    $dashIndex = $name.IndexOf(' — ')
    if ($dashIndex -ge 0) {
        $name = $name.Substring(0, $dashIndex)
    }

    return (Normalize-SCQuestRecipeName -Name $name)
}

function Get-SCQuestKnownCategoryNames {
    return @(
        'Корабельные компоненты',
        'Корабельные орудия',
        'Добывающие лазеры',
        'Броня/одежда',
        'Оружие',
        'Снаряжение/расходники',
        'Материалы/особое',
        'Не распознано'
    )
}

function Get-SCQuestSelectableCategoryNames {
    return @(
        'Корабельные компоненты',
        'Корабельные орудия',
        'Добывающие лазеры',
        'Броня/одежда',
        'Оружие',
        'Снаряжение/расходники'
    )
}

function Test-SCQuestAllSelectableCategoriesSelected {
    param([string[]]$SelectedCategoryNames)

    $selected = @{}
    foreach ($name in @($SelectedCategoryNames)) {
        $selected[$name] = $true
    }

    foreach ($name in Get-SCQuestSelectableCategoryNames) {
        if (-not $selected.ContainsKey($name)) {
            return $false
        }
    }

    return $true
}

function Test-SCQuestHasRewardBlock {
    param([AllowEmptyString()][string]$Value)

    return ($Value -match '\\n\\n<EM\d>(Доступные чертежи|Возможные чертежи)(?: \(SCMDB\))?</EM\d>')
}

function Select-SCQuestRewardBlockCategories {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [string[]]$SelectedCategoryNames,
        [string[]]$SelectedFamilyOptionIds,
        [object]$FamilyIndex
    )

    $match = [regex]::Match(
        $Value,
        '(?s)^(?<prefix>.*?)(?<block>\\n\\n<EM\d>(?:Доступные чертежи|Возможные чертежи)(?: \(SCMDB\))?</EM\d>.*)$'
    )

    if (-not $match.Success) {
        return $Value
    }

    $selected = @{}
    foreach ($name in @($SelectedCategoryNames)) {
        $selected[$name] = $true
    }

    $selectedFamilies = @{}
    foreach ($optionId in @($SelectedFamilyOptionIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$optionId)) {
            $selectedFamilies[[string]$optionId] = $true
        }
    }
    $useFamilyFilter = ($selectedFamilies.Count -gt 0)
    $familyLookup = if ($useFamilyFilter) { New-SCQuestFamilyLookup -FamilyIndex $FamilyIndex } else { @{} }

    $known = @{}
    foreach ($name in Get-SCQuestKnownCategoryNames) {
        $known[$name] = $true
    }

    $prefix = [string]$match.Groups['prefix'].Value
    $block = [string]$match.Groups['block'].Value
    $blockBody = [regex]::Replace($block, '^\\n\\n', '')
    $lines = @($blockBody -split '\\n')
    if ($lines.Count -eq 0) {
        return $Value
    }

    $header = $lines[0]
    $kept = New-Object System.Collections.Generic.List[string]
    $includeCurrentCategory = $false
    $keptItemCount = 0
    $currentCategory = $null
    $categoryItemCounts = [ordered]@{}
    $categoryBuffer = New-Object System.Collections.Generic.List[string]
    $pendingCategoryLines = New-Object System.Collections.Generic.List[string]
    $categoryBulletCount = 0

    function Flush-SCQuestCategoryBuffer {
        if ($categoryBuffer -and $categoryBulletCount -gt 0) {
            if ($kept.Count -gt 0) {
                $kept.Add('')
            }
            foreach ($bufferLine in $categoryBuffer) {
                $kept.Add([string]$bufferLine)
            }
        }
    }

    for ($index = 1; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $headingMatch = [regex]::Match($line, '^<EM\d>(.+?)</EM\d>$')
        if ($headingMatch.Success -and $known.ContainsKey([string]$headingMatch.Groups[1].Value)) {
            Flush-SCQuestCategoryBuffer
            $category = [string]$headingMatch.Groups[1].Value
            $includeCurrentCategory = $selected.ContainsKey($category)
            $currentCategory = if ($includeCurrentCategory) { $category } else { $null }
            $categoryBuffer = New-Object System.Collections.Generic.List[string]
            $pendingCategoryLines = New-Object System.Collections.Generic.List[string]
            $categoryBulletCount = 0
            if ($includeCurrentCategory) {
                if (-not $categoryItemCounts.Contains($category)) {
                    $categoryItemCounts[$category] = 0
                }
                $categoryBuffer.Add($line)
            }
            continue
        }

        if ($includeCurrentCategory) {
            if ($line -match '^- ') {
                $recipeName = Get-SCQuestRecipeNameFromRewardLine -Line $line
                if ($useFamilyFilter) {
                    if ([string]::IsNullOrWhiteSpace($recipeName) -or -not $familyLookup.ContainsKey($recipeName)) {
                        continue
                    }

                    $familyOptionId = [string]$familyLookup[$recipeName]
                    if (-not $selectedFamilies.ContainsKey($familyOptionId)) {
                        continue
                    }
                }

                foreach ($pendingLine in $pendingCategoryLines) {
                    $categoryBuffer.Add([string]$pendingLine)
                }
                $pendingCategoryLines.Clear()
                $categoryBuffer.Add($line)
                $categoryBulletCount++
                $keptItemCount++
                if ($currentCategory) {
                    $categoryItemCounts[$currentCategory] = [int]$categoryItemCounts[$currentCategory] + 1
                }
            }
            else {
                $pendingCategoryLines.Add($line)
            }
        }
    }

    Flush-SCQuestCategoryBuffer

    if ($keptItemCount -eq 0) {
        return $prefix.TrimEnd()
    }

    $summary = Format-SCQuestRewardSummaryLine -CategoryItemCounts $categoryItemCounts
    $body = if ([string]::IsNullOrWhiteSpace($summary)) {
        $header + '\n\n' + (($kept.ToArray()) -join '\n').TrimEnd()
    }
    else {
        $header + '\n' + $summary + '\n\n' + (($kept.ToArray()) -join '\n').TrimEnd()
    }

    return $prefix.TrimEnd() + '\n\n' + $body
}

function Get-SCQuestPossibleTitleKeys {
    param([string]$DescriptionKey)

    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in @('_Desc_', '_desc_', '_DESC_')) {
        if ($DescriptionKey.Contains($pattern)) {
            $keys.Add($DescriptionKey.Replace($pattern, $pattern.Replace('Desc', 'Title').Replace('desc', 'title').Replace('DESC', 'TITLE')))
            $keys.Add($DescriptionKey.Replace($pattern, $pattern.Replace('Desc', 'name').Replace('desc', 'name').Replace('DESC', 'name')))
        }
    }

    if ($DescriptionKey -match '(?i)_Desc$') {
        $keys.Add(([regex]::Replace($DescriptionKey, '_Desc$', '_Title', 'IgnoreCase')))
        $keys.Add(([regex]::Replace($DescriptionKey, '_Desc$', '_name', 'IgnoreCase')))
    }
    if ($DescriptionKey -match '(?i)Description') {
        $keys.Add(([regex]::Replace($DescriptionKey, 'Description', 'Title', 'IgnoreCase')))
        $keys.Add(([regex]::Replace($DescriptionKey, 'Description', 'name', 'IgnoreCase')))
    }

    return @($keys.ToArray() | Sort-Object -Unique)
}

function Get-SCQuestNormalizedIniKey {
    param([string]$Key)

    return (([string]$Key).Trim() -replace ',.*$', '')
}

function Add-SCQuestTitleVisibility {
    param(
        [hashtable]$VisibilityMap,
        [string]$TitleKey,
        [bool]$HasVisibleRewardBlock
    )

    $normalizedTitleKey = Get-SCQuestNormalizedIniKey -Key $TitleKey
    if ([string]::IsNullOrWhiteSpace($normalizedTitleKey)) {
        return
    }

    if (-not $VisibilityMap.ContainsKey($normalizedTitleKey)) {
        $VisibilityMap[$normalizedTitleKey] = @{
            Total = 0
            Visible = 0
        }
    }

    $VisibilityMap[$normalizedTitleKey].Total++
    if ($HasVisibleRewardBlock) {
        $VisibilityMap[$normalizedTitleKey].Visible++
    }
}

function ConvertTo-SCQuestDescriptionTitleMap {
    param($TitleDescriptionMap)

    $descriptionTitleMap = @{}
    if ($null -eq $TitleDescriptionMap) {
        return $descriptionTitleMap
    }

    foreach ($property in @($TitleDescriptionMap.PSObject.Properties)) {
        $titleKey = Get-SCQuestNormalizedIniKey -Key ([string]$property.Name)
        foreach ($descriptionKey in @($property.Value)) {
            $normalizedDescriptionKey = Get-SCQuestNormalizedIniKey -Key ([string]$descriptionKey)
            if ([string]::IsNullOrWhiteSpace($normalizedDescriptionKey)) {
                continue
            }

            if (-not $descriptionTitleMap.ContainsKey($normalizedDescriptionKey)) {
                $descriptionTitleMap[$normalizedDescriptionKey] = @{}
            }
            $descriptionTitleMap[$normalizedDescriptionKey][$titleKey] = $true
        }
    }

    return $descriptionTitleMap
}

function Get-SCQuestLinkedTitleKeys {
    param(
        [string]$DescriptionKey,
        [hashtable]$DescriptionTitleMap
    )

    $keys = @{}
    $normalizedDescriptionKey = Get-SCQuestNormalizedIniKey -Key $DescriptionKey
    if ($DescriptionTitleMap.ContainsKey($normalizedDescriptionKey)) {
        foreach ($titleKey in $DescriptionTitleMap[$normalizedDescriptionKey].Keys) {
            $keys[$titleKey] = $true
        }
    }

    foreach ($titleKey in Get-SCQuestPossibleTitleKeys -DescriptionKey $DescriptionKey) {
        $keys[(Get-SCQuestNormalizedIniKey -Key $titleKey)] = $true
    }

    foreach ($titleKey in Get-SCQuestPossibleTitleKeys -DescriptionKey $normalizedDescriptionKey) {
        $keys[(Get-SCQuestNormalizedIniKey -Key $titleKey)] = $true
    }

    return @($keys.Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Test-SCQuestLooksLikeTitleKey {
    param([string]$Key)

    return ($Key -match '(?i)(^|_)(title|name)(_|$)')
}

function Format-SCQuestRewardSummaryLine {
    param([System.Collections.Specialized.OrderedDictionary]$CategoryItemCounts)

    if ($null -eq $CategoryItemCounts -or $CategoryItemCounts.Count -eq 0) {
        return ''
    }

    $total = 0
    $parts = @()
    foreach ($key in $CategoryItemCounts.Keys) {
        $count = [int]$CategoryItemCounts[$key]
        if ($count -le 0) {
            continue
        }

        $total += $count
        $parts += ("${key}: $count")
    }

    if ($total -le 0) {
        return ''
    }

    return 'Всего: ' + $total + ' | ' + ($parts -join ' | ')
}

function Remove-SCQuestBlueprintTitleMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Value
    )

    $updated = $Value
    do {
        $before = $updated
        $updated = [regex]::Replace($updated, '^\s*<EM\d>\[Ч\]</EM\d>\s*', '')
        $updated = [regex]::Replace($updated, '^\s*\[Ч\]\s*', '')
        $updated = [regex]::Replace($updated, '^((?:(?:<EM\d>)?\[(?!Ч\])[^]]+\](?:</EM\d>)?\s*)*)(?:<EM\d>)?\[Ч\](?:</EM\d>)?\s*', '$1')
    }
    while ($updated -ne $before)

    return $updated
}
