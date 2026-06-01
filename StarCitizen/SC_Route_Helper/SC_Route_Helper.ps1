param(
    [ValidateSet('CheckGame', 'Start', 'Stop', 'AnalyzeLog', 'CreateBat', 'ShowCandidates')]
    [string]$Action = 'CheckGame',

    [string]$LivePath,
    [string]$LogPath,
    [string]$SourceBatPath
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateDir = Join-Path $ScriptDir 'state'
$ReportsDir = Join-Path $ScriptDir 'reports'
$EvidenceDir = Join-Path $ScriptDir 'evidence'
$DataDir = Join-Path $ScriptDir 'data'
$SessionStatePath = Join-Path $StateDir 'active-session.json'
$CandidatesPath = Join-Path $DataDir 'candidates.json'
$HelperIpsetPath = Join-Path $DataDir 'ipset-starcitizen.txt'

function Ensure-Dirs {
    foreach ($path in @($StateDir, $ReportsDir, $EvidenceDir, $DataDir)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
}

function ConvertTo-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 12
    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $DefaultValue
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $DefaultValue
    }

    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $DefaultValue
    }

    return ($raw | ConvertFrom-Json)
}

function Resolve-LogPath {
    param(
        [string]$InputLivePath,
        [string]$InputLogPath
    )

    if ($InputLogPath) {
        $resolved = [System.IO.Path]::GetFullPath($InputLogPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Game.log не найден: $resolved"
        }
        return $resolved
    }

    if (-not $InputLivePath) {
        throw 'Не указан путь StarCitizen\LIVE.'
    }

    $live = [System.IO.Path]::GetFullPath($InputLivePath)
    $candidates = @(
        (Join-Path $live 'Game.log'),
        (Join-Path (Join-Path $live 'LIVE') 'Game.log')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    throw "Game.log не найден. Выберите папку StarCitizen\LIVE."
}

function Test-ReadableFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $stream.Dispose()
}

function Read-TextRange {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$Offset,
        [long]$Length
    )

    if ($Length -le 0) {
        return ''
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] $Length
        $total = 0
        while ($total -lt $Length) {
            $read = $stream.Read($buffer, $total, [int][Math]::Min(65536, $Length - $total))
            if ($read -le 0) {
                break
            }
            $total += $read
        }

        if ($total -lt $Length) {
            $short = New-Object byte[] $total
            [Array]::Copy($buffer, $short, $total)
            $buffer = $short
        }

        $utf8 = New-Object System.Text.UTF8Encoding($false, $false)
        return $utf8.GetString($buffer)
    }
    finally {
        $stream.Dispose()
    }
}

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

function Get-LineTimestamp {
    param([string]$Line)

    if ($Line -match '^<([^>]+)>') {
        return $Matches[1]
    }

    return $null
}

function Test-PublicIpv4 {
    param([string]$Ip)

    if ($Ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        return $false
    }

    $parts = $Ip.Split('.') | ForEach-Object { [int]$_ }
    foreach ($part in $parts) {
        if ($part -lt 0 -or $part -gt 255) {
            return $false
        }
    }

    if ($parts[0] -eq 10) { return $false }
    if ($parts[0] -eq 127) { return $false }
    if ($parts[0] -eq 169 -and $parts[1] -eq 254) { return $false }
    if ($parts[0] -eq 172 -and $parts[1] -ge 16 -and $parts[1] -le 31) { return $false }
    if ($parts[0] -eq 192 -and $parts[1] -eq 168) { return $false }
    if ($parts[0] -ge 224) { return $false }

    return $true
}

function New-Endpoint {
    param(
        [string]$Ip,
        [string]$Port,
        [string]$Source,
        [string]$Timestamp
    )

    if (-not (Test-PublicIpv4 -Ip $Ip)) {
        return $null
    }

    return [pscustomobject]@{
        ip = $Ip
        port = [int]$Port
        source = $Source
        timestamp = $Timestamp
    }
}

function Parse-ScLogText {
    param(
        [AllowEmptyString()][string]$Text,
        [string]$SessionId,
        [string]$EvidencePath
    )

    $lines = $Text -split "\r?\n"
    $lastEndpoint = $null
    $connectionEvents = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $candidates = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $timestamp = Get-LineTimestamp -Line $line

        if ($line -match '<Join PU> address\[(?<ip>(?:\d{1,3}\.){3}\d{1,3})\] port\[(?<port>\d+)\]') {
            $lastEndpoint = New-Endpoint -Ip $Matches.ip -Port $Matches.port -Source 'Join PU' -Timestamp $timestamp
            if ($lastEndpoint) { $connectionEvents.Add($lastEndpoint) }
            continue
        }

        if ($line -match 'Connecting (?<ip>(?:\d{1,3}\.){3}\d{1,3}):(?<port>\d+)') {
            $lastEndpoint = New-Endpoint -Ip $Matches.ip -Port $Matches.port -Source 'Session Manager' -Timestamp $timestamp
            if ($lastEndpoint) { $connectionEvents.Add($lastEndpoint) }
            continue
        }

        if ($line -match 'Connection requested to: (?<ip>(?:\d{1,3}\.){3}\d{1,3}):(?<port>\d+)') {
            $lastEndpoint = New-Endpoint -Ip $Matches.ip -Port $Matches.port -Source 'Nub ConnectTo' -Timestamp $timestamp
            if ($lastEndpoint) { $connectionEvents.Add($lastEndpoint) }
            continue
        }

        if ($line -match 'remoteAddr=(?<ip>(?:\d{1,3}\.){3}\d{1,3}):(?<port>\d+)') {
            $endpoint = New-Endpoint -Ip $Matches.ip -Port $Matches.port -Source 'remoteAddr' -Timestamp $timestamp
            if ($endpoint) {
                $lastEndpoint = $endpoint
                if ($line -match '<Channel (Created|Connection Complete)>') {
                    $connectionEvents.Add($endpoint)
                }
            }
        }

        if ($line -match '<Channel Process Disconnection>.*cause=(?<cause>\d+).*remoteAddr=(?<ip>(?:\d{1,3}\.){3}\d{1,3}):(?<port>\d+)') {
            $cause = [int]$Matches.cause
            $ip = [string]$Matches.ip
            $port = [int]$Matches.port
            $reason = ''
            if ($line -match 'reason="(?<reason>[^"]*)"') {
                $reason = $Matches.reason
            }

            $error = [pscustomobject]@{
                errorCode = $cause
                kind = 'Channel Process Disconnection'
                ip = $ip
                port = $port
                timestamp = $timestamp
                reason = $reason
                lineNumber = $i + 1
            }
            $errors.Add($error)

            if ($cause -eq 30000 -and $reason -match 'InactivityTimerCallback' -and (Test-PublicIpv4 -Ip $ip)) {
                $candidates.Add([pscustomobject]@{
                    ip = $ip
                    cidr = "$ip/32"
                    port = $port
                    errorCode = 30000
                    confidence = 'high'
                    timestamp = $timestamp
                    reason = $reason
                    sessionId = $SessionId
                    evidencePath = $EvidencePath
                    source = 'Game.log Channel Process Disconnection'
                })
            }
            continue
        }

        if ($line -match '<Error Popup Opened> errorCode=(?<code>\d+)') {
            $ip = $null
            $port = $null
            if ($lastEndpoint) {
                $ip = $lastEndpoint.ip
                $port = $lastEndpoint.port
            }

            $errors.Add([pscustomobject]@{
                errorCode = [int]$Matches.code
                kind = 'Error Popup Opened'
                ip = $ip
                port = $port
                timestamp = $timestamp
                reason = ''
                lineNumber = $i + 1
            })
        }
    }

    $uniqueCandidates = @(
        $candidates |
            Sort-Object cidr, port, timestamp -Unique
    )

    return [pscustomobject]@{
        lineCount = $lines.Count
        connectionEvents = @($connectionEvents.ToArray())
        errors = @($errors.ToArray())
        candidates = @($uniqueCandidates)
    }
}

function Read-CandidateStore {
    $default = [pscustomobject]@{
        version = 1
        updatedAt = $null
        entries = @()
    }

    $store = Read-JsonFile -Path $CandidatesPath -DefaultValue $default
    if (-not $store.PSObject.Properties['entries']) {
        $store | Add-Member -NotePropertyName entries -NotePropertyValue @()
    }
    return $store
}

function Save-CandidateStore {
    param($Store)

    $Store.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    ConvertTo-JsonFile -Value $Store -Path $CandidatesPath

    $ipsetLines = @(
        ConvertTo-Array $Store.entries |
            Sort-Object cidr |
            ForEach-Object { $_.cidr }
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($HelperIpsetPath, [string[]]$ipsetLines, $encoding)
}

function Merge-Candidates {
    param(
        [Parameter(Mandatory = $true)]$ParseResult
    )

    $store = Read-CandidateStore
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in ConvertTo-Array $store.entries) {
        $entries.Add($entry)
    }

    $added = 0
    foreach ($candidate in ConvertTo-Array $ParseResult.candidates) {
        $existing = $entries | Where-Object { $_.cidr -eq $candidate.cidr } | Select-Object -First 1
        $sourceRecord = [pscustomobject]@{
            sessionId = $candidate.sessionId
            evidencePath = $candidate.evidencePath
            timestamp = $candidate.timestamp
            errorCode = $candidate.errorCode
            port = $candidate.port
            reason = $candidate.reason
        }

        if ($existing) {
            $existing.lastSeenAt = $candidate.timestamp
            $sources = New-Object System.Collections.Generic.List[object]
            foreach ($source in ConvertTo-Array $existing.sources) {
                $sources.Add($source)
            }
            $already = $sources | Where-Object {
                $_.sessionId -eq $sourceRecord.sessionId -and
                $_.timestamp -eq $sourceRecord.timestamp -and
                $_.port -eq $sourceRecord.port
            } | Select-Object -First 1
            if (-not $already) {
                $sources.Add($sourceRecord)
            }
            $existing.sources = @($sources.ToArray())
        }
        else {
            $entries.Add([pscustomobject]@{
                cidr = $candidate.cidr
                ip = $candidate.ip
                confidence = $candidate.confidence
                firstSeenAt = $candidate.timestamp
                lastSeenAt = $candidate.timestamp
                sources = @($sourceRecord)
            })
            $added++
        }
    }

    $store.entries = @($entries.ToArray() | Sort-Object cidr)
    Save-CandidateStore -Store $store

    return [pscustomobject]@{
        added = $added
        total = @(ConvertTo-Array $store.entries).Count
        storePath = $CandidatesPath
        helperIpsetPath = $HelperIpsetPath
    }
}

function Write-SessionReport {
    param(
        [Parameter(Mandatory = $true)]$ParseResult,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [string]$SourceLogPath,
        [long]$StartOffset,
        [long]$EndOffset,
        [bool]$LogWasReset
    )

    $report = [pscustomobject]@{
        sessionId = $SessionId
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
        sourceLogPath = $SourceLogPath
        startOffset = $StartOffset
        endOffset = $EndOffset
        logWasReset = $LogWasReset
        lineCount = $ParseResult.lineCount
        connectionEvents = $ParseResult.connectionEvents
        errors = $ParseResult.errors
        candidates = $ParseResult.candidates
    }

    $reportPath = Join-Path $SessionDir 'report.json'
    ConvertTo-JsonFile -Value $report -Path $reportPath

    $summaryPath = Join-Path $SessionDir 'README.md'
    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add("# SC Route Helper Evidence $SessionId")
    $summary.Add('')
    $summary.Add(('- Source log: `{0}`' -f $SourceLogPath))
    $summary.Add("- Lines analyzed: $($ParseResult.lineCount)")
    $summary.Add("- Errors found: $(@(ConvertTo-Array $ParseResult.errors).Count)")
    $summary.Add("- High-confidence candidates: $(@(ConvertTo-Array $ParseResult.candidates).Count)")
    if ($LogWasReset) {
        $summary.Add("- Note: Game.log looked rotated/reset after recording start; analyzed from byte 0.")
    }
    $summary.Add('')
    $summary.Add("## Candidates")
    foreach ($candidate in ConvertTo-Array $ParseResult.candidates) {
        $summary.Add(('- `{0}` from `{1}:{2}`, error `{3}`' -f $candidate.cidr, $candidate.ip, $candidate.port, $candidate.errorCode))
    }
    if (@(ConvertTo-Array $ParseResult.candidates).Count -eq 0) {
        $summary.Add("- No high-confidence 30000 candidates found.")
    }
    $summary.Add('')
    $summary.Add("## Errors")
    foreach ($error in ConvertTo-Array $ParseResult.errors) {
        $summary.Add(('- `{0}` {1} `{2}:{3}` {4}' -f $error.errorCode, $error.kind, $error.ip, $error.port, $error.timestamp))
    }

    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($summaryPath, [string[]]$summary, $encoding)

    return $reportPath
}

function Invoke-CheckGame {
    $resolvedLog = Resolve-LogPath -InputLivePath $LivePath -InputLogPath $LogPath
    Test-ReadableFile -Path $resolvedLog
    $item = Get-Item -LiteralPath $resolvedLog
    Write-Host "OK: Game.log найден и читается."
    Write-Host "Log: $resolvedLog"
    Write-Host "Size: $($item.Length) bytes"
    Write-Host "Last write: $($item.LastWriteTime)"
}

function Invoke-Start {
    Ensure-Dirs
    $resolvedLog = Resolve-LogPath -InputLivePath $LivePath -InputLogPath $LogPath
    Test-ReadableFile -Path $resolvedLog
    $item = Get-Item -LiteralPath $resolvedLog

    $state = [pscustomobject]@{
        sessionId = Get-Date -Format 'yyyyMMdd-HHmmss'
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        livePath = $LivePath
        logPath = $resolvedLog
        startOffset = [long]$item.Length
        startLastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
    }

    ConvertTo-JsonFile -Value $state -Path $SessionStatePath
    Write-Host "Запись начата."
    Write-Host "Session: $($state.sessionId)"
    Write-Host "Log: $resolvedLog"
    Write-Host "Start offset: $($state.startOffset)"
    Write-Host "Теперь запустите Star Citizen и воспроизведите ошибку."
}

function Invoke-Stop {
    Ensure-Dirs
    if (-not (Test-Path -LiteralPath $SessionStatePath -PathType Leaf)) {
        throw 'Активная запись не найдена. Сначала нажмите "Начать запись".'
    }

    $state = Read-JsonFile -Path $SessionStatePath -DefaultValue $null
    if (-not $state) {
        throw 'Не удалось прочитать active-session.json.'
    }

    $resolvedLog = Resolve-LogPath -InputLivePath $LivePath -InputLogPath $state.logPath
    Test-ReadableFile -Path $resolvedLog
    $item = Get-Item -LiteralPath $resolvedLog

    $startOffset = [long]$state.startOffset
    $logWasReset = $false
    if ([long]$item.Length -lt $startOffset) {
        $startOffset = 0
        $logWasReset = $true
    }

    $endOffset = [long]$item.Length
    $length = $endOffset - $startOffset
    $segment = Read-TextRange -Path $resolvedLog -Offset $startOffset -Length $length

    $sessionId = [string]$state.sessionId
    $sessionDir = Join-Path $EvidenceDir "sc-route-session-$sessionId"
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

    $segmentPath = Join-Path $sessionDir 'Game.segment.log'
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($segmentPath, $segment, $encoding)

    $parseResult = Parse-ScLogText -Text $segment -SessionId $sessionId -EvidencePath $sessionDir
    $mergeResult = Merge-Candidates -ParseResult $parseResult
    $reportPath = Write-SessionReport -ParseResult $parseResult -SessionId $sessionId -SessionDir $sessionDir -SourceLogPath $resolvedLog -StartOffset $startOffset -EndOffset $endOffset -LogWasReset $logWasReset

    Remove-Item -LiteralPath $SessionStatePath -Force

    Write-Host "Запись остановлена."
    Write-Host "Evidence: $sessionDir"
    Write-Host "Segment: $segmentPath"
    Write-Host "Report: $reportPath"
    Write-Host "Errors found: $(@(ConvertTo-Array $parseResult.errors).Count)"
    Write-Host "High-confidence candidates in session: $(@(ConvertTo-Array $parseResult.candidates).Count)"
    Write-Host "New candidates added: $($mergeResult.added)"
    Write-Host "Total candidates: $($mergeResult.total)"
    Write-Host "Helper ipset: $($mergeResult.helperIpsetPath)"
}

function Invoke-AnalyzeLog {
    Ensure-Dirs
    $resolvedLog = Resolve-LogPath -InputLivePath $LivePath -InputLogPath $LogPath
    Test-ReadableFile -Path $resolvedLog
    $item = Get-Item -LiteralPath $resolvedLog
    $text = Read-TextRange -Path $resolvedLog -Offset 0 -Length ([long]$item.Length)
    $sessionId = 'manual-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $sessionDir = Join-Path $EvidenceDir "sc-route-session-$sessionId"
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

    $copyPath = Join-Path $sessionDir 'Game.full.log'
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($copyPath, $text, $encoding)

    $parseResult = Parse-ScLogText -Text $text -SessionId $sessionId -EvidencePath $sessionDir
    $mergeResult = Merge-Candidates -ParseResult $parseResult
    $reportPath = Write-SessionReport -ParseResult $parseResult -SessionId $sessionId -SessionDir $sessionDir -SourceLogPath $resolvedLog -StartOffset 0 -EndOffset ([long]$item.Length) -LogWasReset $false

    Write-Host "Analyze complete."
    Write-Host "Evidence: $sessionDir"
    Write-Host "Report: $reportPath"
    Write-Host "High-confidence candidates in log: $(@(ConvertTo-Array $parseResult.candidates).Count)"
    Write-Host "New candidates added: $($mergeResult.added)"
    Write-Host "Total candidates: $($mergeResult.total)"
}

function Get-BatEncoding {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return New-Object System.Text.UTF8Encoding($true)
    }
    return New-Object System.Text.UTF8Encoding($false)
}

function Invoke-CreateBat {
    Ensure-Dirs
    if ([string]::IsNullOrWhiteSpace($SourceBatPath)) {
        throw 'Не выбран исходный zapret .bat.'
    }

    $sourceBat = [System.IO.Path]::GetFullPath($SourceBatPath)
    if (-not (Test-Path -LiteralPath $sourceBat -PathType Leaf)) {
        throw "Исходный bat не найден: $sourceBat"
    }
    if ([System.IO.Path]::GetExtension($sourceBat).ToLowerInvariant() -ne '.bat') {
        throw 'Выберите именно .bat файл.'
    }

    $store = Read-CandidateStore
    $cidrs = @(
        ConvertTo-Array $store.entries |
            Sort-Object cidr |
            ForEach-Object { $_.cidr }
    )
    if ($cidrs.Count -eq 0) {
        throw 'Список IP пуст. Сначала остановите запись после 30000 или проанализируйте сохраненный Game.log.'
    }

    $batDir = Split-Path -Parent $sourceBat
    $listsDir = Join-Path $batDir 'lists'
    New-Item -ItemType Directory -Force -Path $listsDir | Out-Null

    $targetIpset = Join-Path $listsDir 'ipset-starcitizen.txt'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($targetIpset, [string[]]$cidrs, $utf8NoBom)

    $encoding = Get-BatEncoding -Path $sourceBat
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($sourceBat, $encoding)) {
        $lines.Add($line)
    }

    if (-not ($lines | Where-Object { $_ -match 'SC_Route_Helper generated block' })) {
        $listsIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'set "LISTS=.*lists') {
                $listsIndex = $i
                break
            }
        }
        if ($listsIndex -ge 0) {
            $lines.Insert($listsIndex + 1, 'set "SC_IPSET=%LISTS%ipset-starcitizen.txt"')
            $lines.Insert($listsIndex + 2, 'set "SC_UDP=1024-65535"')
        }
        else {
            $lines.Insert(0, 'set "SC_IPSET=%~dp0lists\ipset-starcitizen.txt"')
            $lines.Insert(1, 'set "SC_UDP=1024-65535"')
        }

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '--wf-udp=' -and $lines[$i] -notmatch '%SC_UDP%') {
                $lines[$i] = $lines[$i] -replace '%GameFilterUDP%', '%GameFilterUDP%,%SC_UDP%'
                break
            }
        }

        $lastCommandIndex = -1
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if (-not [string]::IsNullOrWhiteSpace($lines[$i])) {
                $lastCommandIndex = $i
                break
            }
        }
        if ($lastCommandIndex -lt 0) {
            throw 'Исходный bat пустой.'
        }
        if ($lines[$lastCommandIndex].TrimEnd() -notmatch '\^$') {
            $lines[$lastCommandIndex] = $lines[$lastCommandIndex].TrimEnd() + ' --new ^'
        }

        $lines.Add(':: SC_Route_Helper generated block')
        $lines.Add('--filter-udp=%SC_UDP% --ipset="%SC_IPSET%" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=12 --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-cutoff=n2')
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $sourceName = [System.IO.Path]::GetFileNameWithoutExtension($sourceBat)
    $targetBat = Join-Path $batDir "$sourceName`_SC_$stamp.bat"
    [System.IO.File]::WriteAllLines($targetBat, [string[]]$lines, $encoding)

    Write-Host "Bat создан."
    Write-Host "Source bat: $sourceBat"
    Write-Host "New bat: $targetBat"
    Write-Host "Zapret ipset: $targetIpset"
    Write-Host "IP count: $($cidrs.Count)"
}

function Invoke-ShowCandidates {
    Ensure-Dirs
    $store = Read-CandidateStore
    $entries = @(ConvertTo-Array $store.entries | Sort-Object cidr)
    Write-Host "Candidates: $($entries.Count)"
    foreach ($entry in $entries) {
        Write-Host "$($entry.cidr) $($entry.confidence) first=$($entry.firstSeenAt) last=$($entry.lastSeenAt)"
    }
    Write-Host "Store: $CandidatesPath"
    Write-Host "Helper ipset: $HelperIpsetPath"
}

switch ($Action) {
    'CheckGame' { Invoke-CheckGame }
    'Start' { Invoke-Start }
    'Stop' { Invoke-Stop }
    'AnalyzeLog' { Invoke-AnalyzeLog }
    'CreateBat' { Invoke-CreateBat }
    'ShowCandidates' { Invoke-ShowCandidates }
}
