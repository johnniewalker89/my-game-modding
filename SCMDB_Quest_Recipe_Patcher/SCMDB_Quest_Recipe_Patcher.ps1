param(
    [Parameter(Position = 0)]
    [string]$LivePath,

    [string]$GlobalIniPath,

    [switch]$DryRun,

    [switch]$NoBackup,

    [switch]$KeepExistingBlueprintBlocks,

    [string]$TitleMarker = '[ЧЕРТЁЖ]',

    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScmdbBaseUrl = 'https://scmdb.net/data'
$LocalizationRelativePath = 'data\Localization\korean_(south_korea)\global.ini'

function ConvertTo-Array {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return $Value
    }

    return @($Value)
}

function Get-PropertyValue {
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

function Resolve-GlobalIniPath {
    param(
        [string]$InputLivePath,
        [string]$InputGlobalIniPath
    )

    if ($InputGlobalIniPath) {
        $resolved = [System.IO.Path]::GetFullPath($InputGlobalIniPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "global.ini not found: $resolved"
        }
        return $resolved
    }

    if (-not $InputLivePath) {
        $InputLivePath = Read-Host 'Enter path to StarCitizen\LIVE'
    }

    $root = [System.IO.Path]::GetFullPath($InputLivePath)
    $candidates = @(
        (Join-Path $root $LocalizationRelativePath),
        (Join-Path (Join-Path $root 'LIVE') $LocalizationRelativePath)
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    throw "global.ini not found. Expected: <LIVE>\$LocalizationRelativePath"
}

function Get-TextEncodingInfo {
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

function Get-NormalizedIniKey {
    param([Parameter(Mandatory = $true)][string]$LineKey)

    return ($LineKey.Trim() -replace ',.*$', '')
}

function Remove-BlueprintBlock {
    param([Parameter(Mandatory = $true)][string]$Value)

    $clean = $Value

    $generatedPatterns = @(
        '\\n\\n<EM\d>Доступные чертежи \(SCMDB\)</EM\d>.*$',
        '\\n\\n<EM\d>Возможные чертежи \(SCMDB\)</EM\d>.*$'
    )

    foreach ($pattern in $generatedPatterns) {
        $clean = [regex]::Replace($clean, $pattern, '')
    }

    if (-not $KeepExistingBlueprintBlocks) {
        $legacyPattern = '\\n\\n<EM\d>(Доступные чертежи|Potential Blueprints)(?:\s*\([^<]*\))?\s*</EM\d>.*$'
        $clean = [regex]::Replace($clean, $legacyPattern, '')
    }

    return $clean
}

function Remove-TitleMarker {
    param([Parameter(Mandatory = $true)][string]$Value)

    $clean = $Value
    $patterns = @(
        '^\s*<EM\d>\[BP\]</EM\d>\s*',
        '^\s*<EM\d>\[Ч\]</EM\d>\s*',
        '^\s*<EM\d>\[ЧЕРТ\]</EM\d>\s*',
        '^\s*<EM\d>\[ЧЕРТЕЖ\]</EM\d>\s*',
        '^\s*<EM\d>\[ЧЕРТЁЖ\]</EM\d>\s*',
        '^\s*<EM\d>\[Чертежи\]\*?</EM\d>\s*',
        '^\s*\[BP\]\s*',
        '^\s*\[Ч\]\s*',
        '^\s*\[ЧЕРТ\]\s*',
        '^\s*\[ЧЕРТЕЖ\]\s*',
        '^\s*\[ЧЕРТЁЖ\]\s*',
        '^\s*\[Чертежи\]\*?\s*'
    )

    foreach ($pattern in $patterns) {
        $clean = [regex]::Replace($clean, $pattern, '')
    }

    return $clean
}

function Get-SafeFileNamePart {
    param([Parameter(Mandatory = $true)][string]$Value)

    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-ScmdbData {
    Write-Host 'Downloading SCMDB version index...'
    $versions = ConvertTo-Array (Invoke-RestMethod -Uri "$ScmdbBaseUrl/game-versions.json" -UseBasicParsing)
    if ($versions.Count -eq 0) {
        throw 'SCMDB version index is empty.'
    }

    $activeVersion = $versions[0]
    $version = $activeVersion.version
    $file = $activeVersion.file

    if (-not $version -or -not $file) {
        throw 'SCMDB version index does not contain version/file fields.'
    }

    Write-Host "Downloading SCMDB game data: $version..."
    $data = Invoke-RestMethod -Uri "$ScmdbBaseUrl/$file" -UseBasicParsing

    return [pscustomobject]@{
        Version = $version
        File = $file
        Data = $data
    }
}

function Add-NameToPool {
    param(
        [Parameter(Mandatory = $true)]$PoolEntry,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    if (-not $PoolEntry.Names.ContainsKey($Name)) {
        $PoolEntry.Names[$Name] = $true
    }
}

function New-RewardMap {
    param([Parameter(Mandatory = $true)]$Scmdb)

    $data = $Scmdb.Data
    $contracts = @()
    $contracts += ConvertTo-Array $data.contracts
    $contracts += ConvertTo-Array $data.legacyContracts

    $descriptionMap = @{}
    $titleMap = @{}
    $rewardContractCount = 0

    foreach ($contract in $contracts) {
        $rewards = ConvertTo-Array $contract.blueprintRewards
        if ($rewards.Count -eq 0) {
            continue
        }

        $rewardContractCount++

        $descKey = $contract.descriptionLocKey
        if (-not $descKey -and $contract.descriptionKey) {
            $descKey = ($contract.descriptionKey -replace '^@', '')
        }

        $titleKey = $contract.titleLocKey
        if (-not $titleKey -and $contract.titleKey) {
            $titleKey = ($contract.titleKey -replace '^@', '')
        }

        if (-not [string]::IsNullOrWhiteSpace($titleKey)) {
            $titleMap[$titleKey] = $true
        }

        if ([string]::IsNullOrWhiteSpace($descKey)) {
            continue
        }

        if (-not $descriptionMap.ContainsKey($descKey)) {
            $descriptionMap[$descKey] = @{
                Key = $descKey
                Contracts = @{}
                Pools = @{}
                RewardSignatures = @{}
            }
        }

        $group = $descriptionMap[$descKey]
        $debugName = if ($contract.debugName) { $contract.debugName } else { '<unknown>' }
        $group.Contracts[$debugName] = $true

        $signatureParts = New-Object System.Collections.Generic.List[string]

        foreach ($reward in $rewards) {
            $poolId = [string]$reward.blueprintPool
            if ([string]::IsNullOrWhiteSpace($poolId)) {
                continue
            }

            $pool = Get-PropertyValue -Object $data.blueprintPools -Name $poolId
            if ($null -eq $pool) {
                continue
            }

            $trigger = if ($reward.trigger) { [string]$reward.trigger } else { 'complete' }
            $chance = if ($null -ne $reward.chance) { [decimal]$reward.chance } else { [decimal]1 }
            $poolName = if ($reward.poolName) { [string]$reward.poolName } elseif ($pool.name) { [string]$pool.name } else { $poolId }
            $poolKey = "$trigger|$chance|$poolId"

            if (-not $group.Pools.ContainsKey($poolKey)) {
                $group.Pools[$poolKey] = @{
                    PoolId = $poolId
                    PoolName = $poolName
                    Trigger = $trigger
                    Chance = $chance
                    Names = @{}
                }
            }

            $poolEntry = $group.Pools[$poolKey]
            $namesForSignature = New-Object System.Collections.Generic.List[string]

            foreach ($blueprint in (ConvertTo-Array $pool.blueprints)) {
                $name = [string]$blueprint.name
                Add-NameToPool -PoolEntry $poolEntry -Name $name
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $namesForSignature.Add($name)
                }
            }

            $signatureNames = ($namesForSignature | Sort-Object -Unique) -join '|'
            $signatureParts.Add("$trigger|$chance|$poolId|$signatureNames")
        }

        $signature = ($signatureParts | Sort-Object) -join '||'
        if (-not $group.RewardSignatures.ContainsKey($signature)) {
            $group.RewardSignatures[$signature] = $true
        }
    }

    return [pscustomobject]@{
        DescriptionMap = $descriptionMap
        TitleMap = $titleMap
        TotalContracts = $contracts.Count
        RewardContracts = $rewardContractCount
    }
}

function Format-RewardBlock {
    param([Parameter(Mandatory = $true)]$Group)

    $hasConflictingRewards = $Group.RewardSignatures.Count -gt 1
    $header = if ($hasConflictingRewards) { 'Возможные чертежи (SCMDB)' } else { 'Доступные чертежи (SCMDB)' }

    $blockLines = New-Object System.Collections.Generic.List[string]
    $blockLines.Add("<EM4>$header</EM4>")

    if ($hasConflictingRewards) {
        $blockLines.Add('<EM2>Описание используется несколькими вариантами миссии; список объединён.</EM2>')
    }

    $allNames = @{}
    foreach ($poolEntry in $Group.Pools.Values) {
        foreach ($name in $poolEntry.Names.Keys) {
            $allNames[$name] = $true
        }
    }

    foreach ($name in ($allNames.Keys | Sort-Object)) {
        $blockLines.Add("- $name")
    }

    return ($blockLines -join '\n')
}

$globalPath = Resolve-GlobalIniPath -InputLivePath $LivePath -InputGlobalIniPath $GlobalIniPath
$encodingInfo = Get-TextEncodingInfo -Path $globalPath
$originalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $globalPath).Hash
$originalSize = (Get-Item -LiteralPath $globalPath).Length

Write-Host "global.ini: $globalPath"
Write-Host "Encoding: $($encodingInfo.Name)"

$scmdb = Get-ScmdbData
$rewardInfo = New-RewardMap -Scmdb $scmdb
$descriptionRewardMap = $rewardInfo.DescriptionMap
$titleRewardMap = $rewardInfo.TitleMap

$lines = [System.IO.File]::ReadAllLines($globalPath, $encodingInfo.Encoding)
$changedLines = 0
$changedDescriptionLines = 0
$changedTitleLines = 0
$cleanedExistingBlocks = 0
$missingDescriptionKeys = New-Object System.Collections.Generic.List[string]
$missingTitleKeys = New-Object System.Collections.Generic.List[string]
$modifiedDescriptionKeys = New-Object System.Collections.Generic.List[string]
$modifiedTitleKeys = New-Object System.Collections.Generic.List[string]
$conflictKeys = New-Object System.Collections.Generic.List[string]
$seenDescriptionKeys = @{}
$seenTitleKeys = @{}

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $separator = $line.IndexOf('=')
    if ($separator -le 0) {
        continue
    }

    $rawKey = $line.Substring(0, $separator)
    $key = Get-NormalizedIniKey -LineKey $rawKey

    $currentValue = $line.Substring($separator + 1)

    if ($descriptionRewardMap.ContainsKey($key)) {
        $seenDescriptionKeys[$key] = $true
        $cleanValue = Remove-BlueprintBlock -Value $currentValue
        if ($cleanValue -ne $currentValue) {
            $cleanedExistingBlocks++
        }

        $group = $descriptionRewardMap[$key]
        if ($group.RewardSignatures.Count -gt 1) {
            $conflictKeys.Add($key)
        }

        $block = Format-RewardBlock -Group $group
        $newValue = $cleanValue + '\n\n' + $block

        if ($newValue -ne $currentValue) {
            $lines[$i] = $rawKey + '=' + $newValue
            $changedLines++
            $changedDescriptionLines++
            $modifiedDescriptionKeys.Add($key)
            $currentValue = $newValue
        }
    }

    if ($titleRewardMap.ContainsKey($key)) {
        $seenTitleKeys[$key] = $true
        $cleanTitle = Remove-TitleMarker -Value $currentValue
        $newTitle = $cleanTitle
        if (-not [string]::IsNullOrWhiteSpace($TitleMarker)) {
            $newTitle = "$TitleMarker $cleanTitle"
        }

        if ($newTitle -ne $currentValue) {
            $lines[$i] = $rawKey + '=' + $newTitle
            $changedLines++
            $changedTitleLines++
            $modifiedTitleKeys.Add($key)
        }
    }
}

foreach ($key in $descriptionRewardMap.Keys) {
    if (-not $seenDescriptionKeys.ContainsKey($key)) {
        $missingDescriptionKeys.Add($key)
    }
}

foreach ($key in $titleRewardMap.Keys) {
    if (-not $seenTitleKeys.ContainsKey($key)) {
        $missingTitleKeys.Add($key)
    }
}

if (-not $ReportPath) {
    $reportDir = Join-Path $ScriptDir 'reports'
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ReportPath = Join-Path $reportDir "scmdb-recipe-patch-$stamp.json"
}

$report = [pscustomobject]@{
    dryRun = [bool]$DryRun
    scmdbVersion = $scmdb.Version
    globalIniPath = $globalPath
    encoding = $encodingInfo.Name
    originalSize = $originalSize
    originalSha256 = $originalHash
    totalLines = $lines.Count
    scmdbContracts = $rewardInfo.TotalContracts
    scmdbRewardContracts = $rewardInfo.RewardContracts
    titleMarker = $TitleMarker
    scmdbRewardDescriptionKeys = $descriptionRewardMap.Keys.Count
    scmdbRewardTitleKeys = $titleRewardMap.Keys.Count
    matchedDescriptionKeys = $seenDescriptionKeys.Keys.Count
    matchedTitleKeys = $seenTitleKeys.Keys.Count
    changedLines = $changedLines
    changedDescriptionLines = $changedDescriptionLines
    changedTitleLines = $changedTitleLines
    cleanedExistingBlocks = $cleanedExistingBlocks
    conflictingSharedDescriptionKeys = $conflictKeys.Count
    missingDescriptionKeys = $missingDescriptionKeys.Count
    missingTitleKeys = $missingTitleKeys.Count
    modifiedDescriptionKeysSample = @($modifiedDescriptionKeys | Select-Object -First 20)
    modifiedTitleKeysSample = @($modifiedTitleKeys | Select-Object -First 20)
    conflictKeysSample = @($conflictKeys | Select-Object -First 20)
    missingDescriptionKeysSample = @($missingDescriptionKeys | Select-Object -First 20)
    missingTitleKeysSample = @($missingTitleKeys | Select-Object -First 20)
}

$reportJson = $report | ConvertTo-Json -Depth 5
$reportEncoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($ReportPath, $reportJson, $reportEncoding)

if ($changedLines -eq 0) {
    Write-Host 'No modifications were necessary.'
    Write-Host "Report: $ReportPath"
    exit 0
}

if ($DryRun) {
    Write-Host 'Dry run complete. No game files were modified.'
    Write-Host "Would modify lines: $changedLines"
    Write-Host "Report: $ReportPath"
    exit 0
}

if (-not $NoBackup) {
    $backupDir = Join-Path $ScriptDir 'backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupName = 'global.ini.' + $stamp + '.scmdb-recipes.bak'
    $backupPath = Join-Path $backupDir $backupName
    Copy-Item -LiteralPath $globalPath -Destination $backupPath -Force
    Write-Host "Backup created: $backupPath"
}

[System.IO.File]::WriteAllLines($globalPath, $lines, $encodingInfo.Encoding)
$newHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $globalPath).Hash

Write-Host "Patched lines: $changedLines"
Write-Host "SCMDB version: $($scmdb.Version)"
Write-Host "New SHA256: $newHash"
Write-Host "Report: $ReportPath"
