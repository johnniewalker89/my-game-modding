param()
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $sourceRoot 'shared\SC_Localization_Core.ps1')
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('sc-menu-version-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'modules') -Force | Out-Null
$global = Join-Path $root 'global.ini'
$encoding = New-Object System.Text.UTF8Encoding($true)
function Assert-Menu([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

try {
    $version = [regex]::Match((Get-Content -LiteralPath (Join-Path $sourceRoot 'SC_Mod_Launcher.ps1') -Raw -Encoding UTF8), "LauncherVersion = '(\d+\.\d+\.\d+)'").Groups[1].Value
    $gui = Get-Content -LiteralPath (Join-Path $sourceRoot 'src\SCModLauncher\MainWindow.xaml.cs') -Raw -Encoding UTF8
    Assert-Menu ($gui.Contains('CurrentLauncherVersion = "' + $version + '"')) 'GUI and CLI versions differ.'
    $builder = Get-Content -LiteralPath (Join-Path $sourceRoot 'tools\Build-ReleaseZip.ps1') -Raw -Encoding UTF8
    Assert-Menu ($builder.Contains("Version = '$version'")) 'Package and CLI versions differ.'

    foreach ($key in @('Frontend_PU_Version,P', 'Frontend_PU_Version')) {
        $old = 'SC Mod Launcher: 2.1.7 \nРусификатор RuSC: 4.10.2-v128'
        $lines = @('quest=Already patched quest', ($key + '=' + $old), 'item=Already patched item')
        [System.IO.File]::WriteAllLines($global, $lines, $encoding)
        $originalHash = Get-SCFileSha256 $global
        $dry = Invoke-SCModDryRun -GlobalIniPath $global -ScriptRoot $root -LauncherVersion $version
        Assert-Menu ($dry.Report.operationCount -eq 1 -and -not $dry.Report.writeAttempted) 'Dry-run did not report exactly one stamp change.'
        Assert-Menu ((Get-SCFileSha256 $global) -eq $originalHash) 'Dry-run wrote global.ini.'
        Assert-Menu ($dry.Report.operations[0].ModuleId -eq 'shared' -and $dry.Report.operations[0].OptionId -eq 'gameMenuVersion') 'Menu operation is absent from shared report.'
        $apply = Invoke-SCModPatch -GlobalIniPath $global -ScriptRoot $root -LauncherVersion $version
        Assert-Menu ($apply.Report.writeSucceeded -and $apply.Report.changedLines -eq 1 -and $apply.Report.conflictCount -eq 0) 'Apply did not update exactly one line.'
        Assert-Menu ((Get-SCFileSha256 $apply.Report.backupPath) -eq $originalHash) 'Backup did not preserve the original input.'
        $actual = [System.IO.File]::ReadAllLines($global, $encoding)
        Assert-Menu ($actual[0] -eq $lines[0] -and $actual[2] -eq $lines[2]) 'Unrelated module text changed.'
        Assert-Menu ($actual[1] -eq ($key + '=SC Mod Launcher: ' + $version + ' \nРусификатор RuSC: 4.10.2-v128')) 'RuSC stamp changed.'
        $newHash = Get-SCFileSha256 $global
        $repeat = Invoke-SCModPatch -GlobalIniPath $global -ScriptRoot $root -LauncherVersion $version
        Assert-Menu ($repeat.Report.operationCount -eq 0 -and -not $repeat.Report.writeAttempted -and -not $repeat.Report.backupPath) 'Repeat apply should be a no-op.'
        Assert-Menu ((Get-SCFileSha256 $global) -eq $newHash) 'Repeat apply rewrote the input.'
        Copy-Item -LiteralPath $apply.Report.backupPath -Destination $global -Force
        Assert-Menu ((Get-SCFileSha256 $global) -eq $originalHash) 'Restoring the backup did not restore the original input.'
    }

    foreach ($lines in @(@('quest=No menu key'), @('Frontend_PU_Version,P=Unmodified localization text'))) {
        [System.IO.File]::WriteAllLines($global, [string[]]$lines, $encoding)
        $hash = Get-SCFileSha256 $global
        $result = Invoke-SCModPatch -GlobalIniPath $global -ScriptRoot $root -LauncherVersion $version
        Assert-Menu ($result.Report.operationCount -eq 0 -and (Get-SCFileSha256 $global) -eq $hash) 'Missing or unowned stamp should be preserved.'
    }
    $context = Read-SCLocalizationData -GlobalIniPath $global
    $rejected = $false
    try { New-SCGameMenuVersionOperations -Context $context -LauncherVersion 'bad-version' | Out-Null } catch { $rejected = $true }
    Assert-Menu $rejected 'Invalid launcher version should be rejected.'

    Write-Host 'PASS: menu version dry-run/apply, both keys, report, backup/restore, RuSC preservation, repeat and absent/unowned stamp.'
} finally {
    $resolvedRoot = [System.IO.Path]::GetFullPath($root)
    $tempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($tempParent, [System.StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedRoot) -notlike 'sc-menu-version-*') {
        throw 'Unsafe menu test cleanup path.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
