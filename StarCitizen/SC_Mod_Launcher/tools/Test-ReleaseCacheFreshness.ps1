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
$releaseSeedItems = @('modules\mining\cache\seed.json')
$seed = Join-Path $fixtureRoot $releaseSeedItems[0]
$backend = Join-Path $fixtureRoot 'SC_Mod_Launcher.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $seed) -Force | Out-Null
function Write-FixtureBackend {
    param([string]$Body)
    [System.IO.File]::WriteAllText($backend, ('param([string]$LivePath,[switch]$WarmCache)' + [Environment]::NewLine + $Body), [System.Text.Encoding]::UTF8)
}
function Assert-GateRejects {
    param([string]$ExpectedReason)
    $reason = ''
    try { Update-ReleaseCacheSeeds } catch { $reason = $_.Exception.Message }
    if ($reason -notlike ('*' + $ExpectedReason + '*')) { throw ('Gate did not reject expected case: ' + $ExpectedReason + '; actual: ' + $reason) }
}
try {
    [System.IO.File]::WriteAllText($seed, '{}')
    (Get-Item -LiteralPath $seed).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
    Write-FixtureBackend -Body "Write-Host 'Source Wiki: FALLBACK'; exit 0"
    Assert-GateRejects -ExpectedReason 'fresh successful cache warmup'
    Write-FixtureBackend -Body "Write-Host 'Source Wiki: OK'; exit 1"
    Assert-GateRejects -ExpectedReason 'fresh successful cache warmup'
    Write-FixtureBackend -Body "Write-Host 'Source Wiki: OK'; exit 0"
    Assert-GateRejects -ExpectedReason 'not refreshed'
    Write-FixtureBackend -Body @'
$seed = Join-Path $PSScriptRoot 'modules\mining\cache\seed.json'
[System.IO.File]::WriteAllText($seed, '{"fresh":true}')
Write-Host 'Source Wiki: OK'
exit 0
'@
    Update-ReleaseCacheSeeds
    Write-Host 'Release cache freshness test passed: fallback, failed refresh and stale seed reject; fresh seed passes.'
}
finally {
    $resolved = [System.IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'sc-release-freshness-test-*') { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
