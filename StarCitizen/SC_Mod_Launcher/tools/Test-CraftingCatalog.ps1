param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('sc-crafting-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'modules\scmdb\SC_Crafting_Catalog.ps1') -Destination (Join-Path $temp 'SC_Crafting_Catalog.ps1')
. (Join-Path $temp 'SC_Crafting_Catalog.ps1')
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
function Assert-Rejected { param([scriptblock]$Action, [string]$Message); $rejected = $false; try { & $Action } catch { $rejected = $true }; Assert-True $rejected $Message }
$version = '4.10.2-live.12881860'
$sourcePath = Join-Path $root "modules\scmdb\cache\crafting-catalog-$version.json"
$source = Get-Content -LiteralPath $sourcePath -Encoding UTF8 -Raw | ConvertFrom-Json
$path = Write-SCCraftingCatalog -CacheKey $version -BlueprintData $source.blueprintData -ItemData $source.itemData
$recipes = @(Get-SCCraftingRecipes -CacheKey $version)
Assert-True ($recipes.Count -eq 1618) 'All exact-build recipes must reach the real adapter.'
$shadow = @($recipes | Where-Object { $_.output_name -match 'Shadowflux' })
Assert-True ($shadow.Count -eq 6) 'All six Shadowflux recipes must be available.'
$f55 = @($shadow | Where-Object { $_.output_name -match '^F55' })[0]
Assert-True ($f55.craft_time_seconds -eq 240) 'F55 crafting time must retain seconds.'
$iron = @($f55.ingredients | Where-Object { $_.name -eq 'Iron' })[0]
Assert-True ($iron.kind -eq 'resource' -and $iron.quantity_scu -eq [decimal]0.03 -and $iron.unit -eq 'SCU') 'Resource quantity and units must survive adaptation.'
Assert-True (@($f55.tiers[0].slots[0].modifiers).Count -gt 0) 'Quality modifiers must remain in the stored recipe.'
Assert-True (@($recipes | Where-Object { $_.uuid -eq 'cdd236fa-56b9-4913-90cf-be7f4e6ca5a7' -and $_.output_name -eq 'Antium Arms Maroon' }).Count -eq 1) 'Verified Antium presentation alias must survive.'
$diagnostics = Get-SCCraftingCatalogDiagnostics -Catalog (Read-SCCraftingCatalog -CacheKey $version)
Assert-True ($diagnostics.status -eq 'partial' -and $diagnostics.unresolvedCount -eq 5 -and $diagnostics.missingNameCount -eq 5 -and $diagnostics.missingProductIdentityCount -eq 1 -and $diagnostics.correctedNameCount -eq 2) 'Known gaps and corrected source names must be explicit.'
$json = $diagnostics | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$pioneer = @($json.issues | Where-Object { $_.blueprintGuid -eq 'd7f3ad24-fca7-4393-b026-f55675cfe820' })
Assert-True ($pioneer.Count -eq 1 -and $pioneer[0].missingName -and $pioneer[0].missingProductIdentity) 'Pioneer must retain both reasons in serialized diagnostics.'
# A source correction removes the issue; diagnostics must never persist stale debt.
$fixed = $source | ConvertTo-Json -Depth 80 | ConvertFrom-Json
foreach ($record in @($fixed.blueprintData.blueprints | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.productName) })) { $record.productName = 'Fixture verified product' }
$fixed.itemData.items = @($fixed.itemData.items) + @([pscustomobject]@{ entityClass = '3cf6753c-d69c-4980-a45e-724151407096'; name = 'Fixture verified product' })
foreach ($record in $fixed.blueprintData.blueprints) { if ($record.guid -eq 'cdd236fa-56b9-4913-90cf-be7f4e6ca5a7') { $record.productName = 'Antium Arms Maroon' }; if ($record.guid -eq '2487dc3a-6a2e-4071-a165-f140d0c8b20d') { $record.productName = 'Antium Helmet Jet' } }
$complete = Get-SCCraftingCatalogDiagnostics -Catalog $fixed
Assert-True ($complete.status -eq 'complete' -and $complete.unresolvedCount -eq 0 -and $complete.correctedNameCount -eq 0) 'Corrected source data must clear its own issue counts.'
$single = $source | ConvertTo-Json -Depth 80 | ConvertFrom-Json
$single.blueprintData.blueprints = @($single.blueprintData.blueprints | Where-Object { $_.guid -eq 'd7f3ad24-fca7-4393-b026-f55675cfe820' })
$singleJson = Get-SCCraftingCatalogDiagnostics -Catalog $single | ConvertTo-Json -Depth 12
Assert-True ($singleJson -match '"issues":\s*\[' -and ($singleJson | ConvertFrom-Json).issues.Count -eq 1) 'A single unresolved record must remain an array at the real serializer boundary.'
$hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
$bad = $source.blueprintData | ConvertTo-Json -Depth 80 | ConvertFrom-Json
$bad.version = '4.10.1-live.12660092'
Assert-Rejected { Write-SCCraftingCatalog -CacheKey $version -BlueprintData $bad -ItemData $source.itemData } 'Mixed builds must be rejected before activation.'
$bad = $source.itemData | ConvertTo-Json -Depth 80 | ConvertFrom-Json
$bad.items = @($bad.items | Select-Object -Skip 1)
Assert-Rejected { Write-SCCraftingCatalog -CacheKey $version -BlueprintData $source.blueprintData -ItemData $bad } 'Partial item downloads must be rejected.'
$bad = $source.blueprintData | ConvertTo-Json -Depth 80 | ConvertFrom-Json
$bad.blueprints[0].tiers[0].slots[0].options = @($bad.blueprints[0].tiers[0].slots[0].options[0], $bad.blueprints[0].tiers[0].slots[0].options[0])
Assert-Rejected { Write-SCCraftingCatalog -CacheKey $version -BlueprintData $bad -ItemData $source.itemData } 'Alternatives must not silently become mandatory combined ingredients.'
Assert-True ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $hash) 'Rejected sources must preserve the exact previous cache.'
function Invoke-SCCraftingRemoteJson { param([string]$Uri, [hashtable]$Headers); if ($Uri -match 'crafting_blueprints-') { return $source.blueprintData }; throw 'Simulated second download interruption' }
$fallback = Update-SCCraftingCatalog -CacheKey $version -Headers @{}
Assert-True ($fallback -eq $path -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $hash) 'Interrupted pair download must use unchanged verified fallback.'
Assert-Rejected { Update-SCCraftingCatalog -CacheKey '4.10.3-live.12881861' -Headers @{} } 'Failed new-build download must not borrow another build.'
Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '*.tmp').Count -eq 0) 'Atomic writes must not leave reader-visible partial files.'
# Exercise atomic replacement of an existing entry, not just initial creation.
[void](Write-SCCraftingCatalog -CacheKey $version -BlueprintData $source.blueprintData -ItemData $source.itemData)
Assert-True (@(Get-SCCraftingRecipes -CacheKey $version).Count -eq 1618) 'Replaced cache must remain readable on PS5.1.'
Write-Host "PASS: crafting adapter, exact build, units, aliases, partial failure and atomic recovery ($temp)"
