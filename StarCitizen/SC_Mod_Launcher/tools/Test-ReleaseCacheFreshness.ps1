param()
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'Build-ReleaseZip.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if (@($errors).Count -gt 0) { throw 'Release script parse failed' }
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-ReleaseCacheSeeds' }, $true)
if ($null -eq $fn) { throw 'Missing release warmup gate' }
Invoke-Expression $fn.Extent.Text
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sc-release-freshness-test-' + [guid]::NewGuid().ToString('N'))
$ProjectDir = $fixtureRoot
$ReleaseCacheBuild = '4.10.3-live.13165946'
$releaseSeedItems = @('modules\mining\cache\seed.json', 'modules\mining\cache\wiki-item-passports-4.10.3-live.13165946.json')
$seed = Join-Path $fixtureRoot $releaseSeedItems[0]
$backend = Join-Path $fixtureRoot 'SC_Mod_Launcher.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $seed) -Force | Out-Null
function Write-FixtureBackend {
    param([string[]]$Lines, [string]$Match = 'exact', [string]$Requested = '4.10.3-LIVE.13165946', [switch]$Empty, [switch]$Stale, [switch]$OldCopy, [int]$ExitCode = 0)
    [System.IO.File]::WriteAllText($seed, '{}')
    (Get-Item -LiteralPath $seed).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
    $fixture = @{
        lines = @($Lines); refresh = (-not $Stale); oldCopy = [bool]$OldCopy; exitCode = $ExitCode
        passport = @{
            schemaVersion = 3; source = 'Star Citizen Wiki'; cacheKey = $ReleaseCacheBuild; requestedGameVersion = $Requested
            gameVersion = $(if ($Match -eq 'offline-fallback') { '4.10.2-LIVE.12881860' } else { $Requested })
            versionMatch = $Match; createdAt = '2026-10-31T00:00:00Z'; fallbackFromCacheKey = '4.10.2-live.12913470'
            records = @(@{ identity = 'fixture' })
        }
    }
    if ($Empty) { $fixture.passport.records = @() }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($fixture | ConvertTo-Json -Depth 10 -Compress)))
    $body = @'
param([string]$LivePath,[switch]$WarmCache)
$f = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__FIXTURE__')) | ConvertFrom-Json
$seed = Join-Path $PSScriptRoot 'modules\mining\cache\seed.json'
if ($f.refresh) { [IO.File]::WriteAllText($seed, '{"fresh":true}') }
$f.passport | Add-Member -NotePropertyName fallbackCopiedAt -NotePropertyValue $(if ($f.oldCopy) { '2026-10-31T00:00:00Z' } else { [DateTime]::UtcNow.ToString('o') })
$wiki = Join-Path $PSScriptRoot 'modules\mining\cache\wiki-item-passports-4.10.3-live.13165946.json'
[IO.File]::WriteAllText($wiki, ($f.passport | ConvertTo-Json -Depth 10), [Text.Encoding]::UTF8)
foreach ($line in $f.lines) { Write-Host $line }
exit ([int]$f.exitCode)
'@
    [System.IO.File]::WriteAllText($backend, $body.Replace('__FIXTURE__', $encoded), [Text.Encoding]::UTF8)
}
function Assert-GateRejects {
    param([string]$ExpectedReason)
    $reason = ''
    try { Update-ReleaseCacheSeeds } catch { $reason = $_.Exception.Message }
    if ($reason -notlike ('*' + $ExpectedReason + '*')) { throw ('Gate did not reject expected case: ' + $ExpectedReason + '; actual: ' + $reason) }
}
try {
    $fallback = @('Source Wiki item passports: FALLBACK; source unavailable', 'Cache mining item passports: FALLBACK; explicit source build')
    Write-FixtureBackend -Lines @('Source UEX refinery yields: FALLBACK; fixture')
    Assert-GateRejects -ExpectedReason 'fresh successful cache warmup'
    Write-FixtureBackend -Lines @('Source SCMDB crafting catalogs: FALLBACK; fixture')
    Assert-GateRejects -ExpectedReason 'fresh successful cache warmup'
    Write-FixtureBackend -Lines @('Source Wiki: OK') -ExitCode 1
    Assert-GateRejects -ExpectedReason 'fresh successful cache warmup'
    Write-FixtureBackend -Lines @('Source Wiki: OK') -Stale
    Assert-GateRejects -ExpectedReason 'not refreshed'
    Write-FixtureBackend -Lines $fallback -Match 'offline-fallback' -Requested '4.10.2-LIVE.12913470'
    Assert-GateRejects -ExpectedReason 'identity or records'
    Write-FixtureBackend -Lines $fallback -Match 'offline-fallback' -Empty
    Assert-GateRejects -ExpectedReason 'identity or records'
    Write-FixtureBackend -Lines @('Source Wiki: OK') -Match 'offline-fallback'
    Assert-GateRejects -ExpectedReason 'unreported fallback'
    Write-FixtureBackend -Lines @($fallback[0]) -Match 'offline-fallback'
    Assert-GateRejects -ExpectedReason 'fallback metadata'
    Write-FixtureBackend -Lines @($fallback[0], $fallback[0]) -Match 'offline-fallback'
    Assert-GateRejects -ExpectedReason 'fallback metadata'
    Write-FixtureBackend -Lines $fallback -Match 'offline-fallback' -OldCopy
    Assert-GateRejects -ExpectedReason 'fallback metadata'
    Write-FixtureBackend -Lines @('Source Wiki item passports: OK; exact build')
    Update-ReleaseCacheSeeds
    Write-FixtureBackend -Lines $fallback -Match 'offline-fallback'
    Update-ReleaseCacheSeeds
    Write-Host 'Release freshness PASS: 10 invalid cases rejected; fresh and verified explicit Wiki fallback pass.'
}
finally {
    $resolved = [System.IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'sc-release-freshness-test-*') { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
