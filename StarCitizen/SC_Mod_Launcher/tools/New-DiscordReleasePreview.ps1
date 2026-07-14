[CmdletBinding()]
param(
    [string]$Repo = 'johnniewalker89/my-game-modding',
    [string]$Tag = '',
    [string]$ReleaseJsonPath = '',
    [string]$PhrasesPath = (Join-Path $PSScriptRoot 'discord-release-phrases.json'),
    [int]$TemplateIndex = -1,
    [ValidateSet('Text', 'DiscordEmbedJson')]
    [string]$Format = 'Text',
    [string]$OutFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StableIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [int]$Modulo
    )

    if ($Modulo -le 0) {
        throw 'Modulo must be positive.'
    }

    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Value))
    $number = [BitConverter]::ToUInt32($hash, 0)
    return [int]($number % [uint32]$Modulo)
}

function Convert-MarkdownForDiscord {
    param([string]$Body)

    $text = ($Body -replace "`r`n", "`n").Trim()
    $installIndex = $text.IndexOf("`n## Установка")
    if ($installIndex -ge 0) {
        $text = $text.Substring(0, $installIndex).Trim()
    }
    $checkIndex = $text.IndexOf("`n## Проверка")
    if ($checkIndex -ge 0) {
        $text = $text.Substring(0, $checkIndex).Trim()
    }
    $text = $text -replace '(?m)^##\s+Что нового\b.*\n?', ''
    $text = $text -replace '(?m)^##\s+', '**'
    $text = $text -replace '(?m)^(\*\*.+)$', '$1**'
    return $text.Trim()
}

if (-not (Test-Path -LiteralPath $PhrasesPath -PathType Leaf)) {
    throw "Phrases file not found: $PhrasesPath"
}

$phrases = Get-Content -LiteralPath $PhrasesPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($ReleaseJsonPath) {
    if (-not (Test-Path -LiteralPath $ReleaseJsonPath -PathType Leaf)) {
        throw "Release JSON not found: $ReleaseJsonPath"
    }
    $release = Get-Content -LiteralPath $ReleaseJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $args = @('release', 'view', '--repo', $Repo, '--json', 'name,tagName,body,url,assets,publishedAt')
    if ($Tag) {
        $args = @('release', 'view', $Tag, '--repo', $Repo, '--json', 'name,tagName,body,url,assets,publishedAt')
    }
    $release = (& gh @args) | ConvertFrom-Json
}

$openers = @($phrases.openers)
$closers = @($phrases.closers)
if ($openers.Count -eq 0 -or $closers.Count -eq 0) {
    throw 'Phrases file must contain non-empty openers and closers arrays.'
}

$seed = if ($release.tagName) { [string]$release.tagName } else { [string]$release.name }
$index = if ($TemplateIndex -ge 0) {
    $TemplateIndex % [Math]::Min($openers.Count, $closers.Count)
} else {
    Get-StableIndex -Value $seed -Modulo ([Math]::Min($openers.Count, $closers.Count))
}

$role = [string]$phrases.roleMention
$opener = ([string]$openers[$index]).Replace('{role}', $role)
$closer = [string]$closers[$index]
$body = Convert-MarkdownForDiscord -Body ([string]$release.body)
$releaseLead = "Смотрите, что JOHNNIE нам [подвез]($($release.url)):"
$assetLines = @()
foreach ($asset in @($release.assets)) {
    if ($asset.name -like 'SC_Mod_Launcher_*.zip') {
        $assetLines += "[$($asset.name)]($($asset.url))"
    }
}

$assetBlock = if ($assetLines.Count -gt 0) {
    $assetText = $assetLines[0]
    "Если уже пользуешься лаунчером — просто жми ``Обновить``.`nЕсли заходишь впервые — скачай $assetText, извлеки папку ``SC_Mod_Launcher`` и запускай ``SC_Mod_Launcher.exe``."
} else {
    ''
}

$messageParts = @(
    $opener,
    $releaseLead,
    $body
)
if ($assetBlock) {
    $messageParts += $assetBlock
}
$messageParts += $closer

$message = ($messageParts | Where-Object { $_ -and $_.Trim() }) -join "`n`n"
$embedDescription = $message

$embedPayload = [ordered]@{
    content = ''
    embeds = @(
        [ordered]@{
            title = [string]$release.name
            description = $embedDescription
            color = 3447003
        }
    )
    allowed_mentions = [ordered]@{
        parse = @()
    }
}

$result = [ordered]@{
    repo = $Repo
    tag = $release.tagName
    name = $release.name
    url = $release.url
    templateIndex = $index
    roleMention = $role
    messageLength = $message.Length
    message = $message
    payload = $embedPayload
}

if ($OutFile) {
    $parent = Split-Path -Parent $OutFile
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if ($Format -eq 'DiscordEmbedJson') {
        $embedPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    } else {
        $message | Set-Content -LiteralPath $OutFile -Encoding UTF8
    }
}

if ($Format -eq 'DiscordEmbedJson') {
    $embedPayload | ConvertTo-Json -Depth 8
} else {
    $result | ConvertTo-Json -Depth 8
}
