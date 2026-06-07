param(
    [string]$AppPath = '',
    [switch]$Build,
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [string]$Message,
        [int]$Seconds = $TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $value = & $Condition
        if ($value) {
            return $value
        }

        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)

    throw "Timed out: $Message"
}

function Find-ByAutomationId {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$AutomationId
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    )
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Invoke-Button {
    param([System.Windows.Automation.AutomationElement]$Button)

    $pattern = $Button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
}

function Get-AutomationText {
    param([System.Windows.Automation.AutomationElement]$Element)

    try {
        $textPattern = $Element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        if ($textPattern) {
            return $textPattern.DocumentRange.GetText(-1)
        }
    }
    catch {
    }

    try {
        $valuePattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($valuePattern) {
            return [string]$valuePattern.Current.Value
        }
    }
    catch {
    }

    return ''
}

if ($Build) {
    & (Join-Path $ScriptDir 'Build-WpfLauncher.ps1') | Out-Host
}

if ([string]::IsNullOrWhiteSpace($AppPath)) {
    $AppPath = Join-Path $ProjectDir 'app\SCModLauncher.exe'
}

if (-not (Test-Path -LiteralPath $AppPath -PathType Leaf)) {
    throw "Launcher executable not found: $AppPath"
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$process = $null
try {
    $process = Start-Process -FilePath $AppPath -WorkingDirectory (Split-Path -Parent $AppPath) -PassThru
    try {
        [void]$process.WaitForInputIdle(7000)
    }
    catch {
    }

    $window = Wait-Until -Message 'launcher window should open' -Condition {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
            $process.Id
        )
        [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            $condition
        )
    }

    Assert-True ($window.Current.Name -eq 'SC Mod Launcher') 'Window title should be SC Mod Launcher.'

    $expectedControls = @(
        'LivePathBox',
        'BrowseButton',
        'CheckPathButton',
        'DryRunButton',
        'WarmCacheButton',
        'ApplyLiveButton',
        'RestoreBackupButton',
        'SignatureButton',
        'OverviewNavButton',
        'ModulesNavButton',
        'CheckUpdatesButton',
        'InstallUpdateButton',
        'ScreenTitleText',
        'LogBox'
    )

    foreach ($controlId in $expectedControls) {
        $control = Find-ByAutomationId -Root $window -AutomationId $controlId
        Assert-True ($null -ne $control) "Control should exist: $controlId"
    }

    $expectedButtonNames = @{
        BrowseButton = 'Выбрать'
        CheckPathButton = 'Проверить путь'
        DryRunButton = 'Проверить'
        WarmCacheButton = 'Прогреть кэш'
        ApplyLiveButton = 'Применить в LIVE'
        RestoreBackupButton = 'Backup'
        SignatureButton = 'Johnnie на связи'
        OverviewNavButton = 'Обзор'
        ModulesNavButton = 'Модули'
        CheckUpdatesButton = 'Проверить обновления'
        InstallUpdateButton = 'Обновить'
    }

    foreach ($pair in $expectedButtonNames.GetEnumerator()) {
        $button = Find-ByAutomationId -Root $window -AutomationId $pair.Key
        Assert-True ($button.Current.Name -eq $pair.Value) "Button '$($pair.Key)' should be Russian text '$($pair.Value)'."
    }

    $screenTitle = Find-ByAutomationId -Root $window -AutomationId 'ScreenTitleText'
    Assert-True ($screenTitle.Current.Name -eq 'Панель корабельного техника') 'Overview title should be technician panel.'

    $navChecks = @(
        @{ Button = 'ModulesNavButton'; Title = 'Модульная сборка' },
        @{ Button = 'RestoreBackupButton'; Title = 'Backup' },
        @{ Button = 'OverviewNavButton'; Title = 'Панель корабельного техника' }
    )

    foreach ($check in $navChecks) {
        Invoke-Button -Button (Find-ByAutomationId -Root $window -AutomationId $check.Button)
        $title = Wait-Until -Message "screen title should become $($check.Title)" -Condition {
            $current = Find-ByAutomationId -Root $window -AutomationId 'ScreenTitleText'
            if ($current -and $current.Current.Name -eq $check.Title) {
                return $current
            }

            return $null
        }
        Assert-True ($title.Current.Name -eq $check.Title) "Navigation should show title: $($check.Title)"

        if ($check.Button -eq 'RestoreBackupButton') {
            $backupControls = @(
                'BackupListBox',
                'RefreshBackupsButton',
                'RestoreLatestBackupButton',
                'RestoreSelectedBackupButton',
                'DeleteSelectedBackupButton'
            )

            foreach ($controlId in $backupControls) {
                $control = Find-ByAutomationId -Root $window -AutomationId $controlId
                Assert-True ($null -ne $control) "Control should exist after opening backup tab: $controlId"
            }

            $backupButtonNames = @{
                RefreshBackupsButton = 'Обновить'
                RestoreLatestBackupButton = 'Восстановить последний'
                RestoreSelectedBackupButton = 'Восстановить выбранный'
                DeleteSelectedBackupButton = 'Удалить выбранный'
            }

            foreach ($pair in $backupButtonNames.GetEnumerator()) {
                $button = Find-ByAutomationId -Root $window -AutomationId $pair.Key
                Assert-True ($button.Current.Name -eq $pair.Value) "Button '$($pair.Key)' should be Russian text '$($pair.Value)'."
            }
        }
    }

    $livePathBox = Find-ByAutomationId -Root $window -AutomationId 'LivePathBox'
    $valuePattern = $livePathBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    Assert-True (-not [string]::IsNullOrWhiteSpace($valuePattern.Current.Value)) 'LIVE path field should be populated or user-editable.'

    $dryRunButton = Find-ByAutomationId -Root $window -AutomationId 'DryRunButton'
    Invoke-Button -Button $dryRunButton
    $logBox = Find-ByAutomationId -Root $window -AutomationId 'LogBox'
    $logText = Wait-Until -Message 'preflight should finish without WPF animation errors' -Seconds 45 -Condition {
        $text = Get-AutomationText -Element $logBox
        if ($text -match 'Источники доступны|КРАСНЫЙ КОНТУР|Источник SCMDB|Cache ') {
            return $text
        }

        if ($dryRunButton.Current.IsEnabled) {
            if ([string]::IsNullOrWhiteSpace($text)) {
                return 'completed-without-readable-log'
            }

            return $text
        }

        return $null
    }
    Assert-True ($logText -notmatch 'анимировать свойство|SolidColorBrush|запечатан|заморожен') 'Preflight should not log WPF brush animation errors.'

    Write-Host 'SC_Mod_Launcher WPF smoke test passed.'
    Write-Host "Launcher: $AppPath"
}
finally {
    if ($process -and -not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(3000)) {
            Stop-Process -Id $process.Id -Force
        }
    }
}
