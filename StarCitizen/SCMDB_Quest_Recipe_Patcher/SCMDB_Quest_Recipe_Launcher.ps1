$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PatchScript = Join-Path $ScriptDir 'SCMDB_Quest_Recipe_Patcher.ps1'
$LocalizationRelativePath = 'data\Localization\korean_(south_korea)\global.ini'
$script:LastReportPath = $null

function Test-LivePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $globalIni = Join-Path $Path $LocalizationRelativePath
    return (Test-Path -LiteralPath $globalIni -PathType Leaf)
}

function Get-GlobalIniPath {
    param([string]$LivePath)

    if ([string]::IsNullOrWhiteSpace($LivePath)) {
        return $null
    }

    return (Join-Path $LivePath $LocalizationRelativePath)
}

function Find-DefaultLivePath {
    $candidates = @(
        'C:\Games\StarCitizen\LIVE',
        'C:\Program Files\Roberts Space Industries\StarCitizen\LIVE',
        'C:\Program Files (x86)\Roberts Space Industries\StarCitizen\LIVE',
        (Join-Path $env:USERPROFILE 'Games\StarCitizen\LIVE')
    )

    foreach ($candidate in $candidates) {
        if (Test-LivePath -Path $candidate) {
            return $candidate
        }
    }

    return ''
}

function Select-LivePath {
    param([string]$InitialPath)

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Выберите папку StarCitizen\LIVE'
    $dialog.ShowNewFolderButton = $false
    if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dialog.SelectedPath = $InitialPath
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }

    return $null
}

function Add-LogLine {
    param([string]$Text)

    $logBox.AppendText($Text + [Environment]::NewLine)
    $logBox.SelectionStart = $logBox.Text.Length
    $logBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-LatestReportPath {
    $reportDir = Join-Path $ScriptDir 'reports'
    if (-not (Test-Path -LiteralPath $reportDir -PathType Container)) {
        return $null
    }

    $latest = Get-ChildItem -LiteralPath $reportDir -Filter 'scmdb-recipe-patch-*.json' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($latest) {
        return $latest.FullName
    }

    return $null
}

function Add-ReportSummary {
    param(
        [string]$Mode,
        [string]$ReportPath
    )

    if ([string]::IsNullOrWhiteSpace($ReportPath) -or -not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        Add-LogLine 'Итог: отчёт не найден. Если выше нет ERROR, операция могла пройти, но сводку прочитать не удалось.'
        return
    }

    try {
        $report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
        $unknownCount = @($report.unknownBlueprints).Count
        $missingDescriptions = [int]$report.missingDescriptionKeys
        $missingTitles = [int]$report.missingTitleKeys
        $hasWarnings = $unknownCount -gt 0 -or $missingDescriptions -gt 0 -or $missingTitles -gt 0

        Add-LogLine ''
        if ($hasWarnings) {
            Add-LogLine 'Итог: ГОТОВО, но есть предупреждения.'
        }
        elseif ($report.dryRun) {
            if ([int]$report.changedLines -eq 0) {
                Add-LogLine 'Итог: OK. Файл уже выглядит пропатченным, изменений не требуется.'
            }
            else {
                Add-LogLine "Итог: OK. Проверка прошла, можно патчить. Будет изменено строк: $($report.changedLines)."
            }
        }
        else {
            if ([int]$report.changedLines -eq 0) {
                Add-LogLine 'Итог: OK. Изменений не требовалось.'
            }
            else {
                Add-LogLine "Итог: OK. Патч применён. Изменено строк: $($report.changedLines)."
            }
        }

        Add-LogLine "SCMDB: $($report.scmdbVersion)"
        Add-LogLine "Контрактов с рецептами: $($report.scmdbRewardContracts)"
        Add-LogLine "Ключей описаний найдено: $($report.matchedDescriptionKeys) из $($report.scmdbRewardDescriptionKeys)"
        Add-LogLine "Ключей названий найдено: $($report.matchedTitleKeys) из $($report.scmdbRewardTitleKeys)"
        Add-LogLine "Рецептов: Wiki $($report.wikiMatched), overrides $($report.overrideMatched), fallback $($report.patternMatched), unknown $unknownCount"
        if ($report.PSObject.Properties['blueprintRecipesMatched']) {
            Add-LogLine "Крафт-справочник: рецептов $($report.blueprintRecipesMatched), локационных ресурсов $($report.resourceLocationEntries)"
        }
        if ($report.PSObject.Properties['changedPlanetDescriptionLines'] -and [int]$report.changedPlanetDescriptionLines -gt 0) {
            Add-LogLine "Подсказки в описаниях планет/лун: $($report.changedPlanetDescriptionLines)"
        }
        if ($report.PSObject.Properties['changedCraftGuideLines'] -and [int]$report.changedCraftGuideLines -gt 0) {
            Add-LogLine "Строк справочника в журнале: $($report.changedCraftGuideLines)"
        }

        if ($unknownCount -gt 0) {
            Add-LogLine ('Не распознано: ' + ((@($report.unknownBlueprints) | Select-Object -First 8) -join '; '))
        }
        if ($missingDescriptions -gt 0) {
            Add-LogLine "Проблема: не найдены ключи описаний: $missingDescriptions"
        }
        if ($missingTitles -gt 0) {
            Add-LogLine "Проблема: не найдены ключи названий: $missingTitles"
        }

        Add-LogLine "Отчёт: $ReportPath"
    }
    catch {
        Add-LogLine "Итог: отчёт найден, но не удалось прочитать сводку: $($_.Exception.Message)"
        Add-LogLine "Отчёт: $ReportPath"
    }
}

function Invoke-LightCheck {
    $livePath = $pathBox.Text.Trim()
    $globalIni = Get-GlobalIniPath -LivePath $livePath

    Add-LogLine ''
    Add-LogLine '== Проверка пути =='
    Add-LogLine "LIVE: $livePath"

    if ([string]::IsNullOrWhiteSpace($livePath) -or -not (Test-Path -LiteralPath $livePath -PathType Container)) {
        Add-LogLine 'Итог: путь LIVE не найден.'
        [System.Windows.Forms.MessageBox]::Show(
            "Выберите папку StarCitizen\LIVE.",
            'SCMDB Quest Recipe Patcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    Add-LogLine "global.ini: $globalIni"
    if (-not (Test-Path -LiteralPath $globalIni -PathType Leaf)) {
        Add-LogLine 'Итог: global.ini не найден. Выберите именно папку StarCitizen\LIVE.'
        [System.Windows.Forms.MessageBox]::Show(
            "Не найден global.ini. Выберите именно папку StarCitizen\LIVE.",
            'SCMDB Quest Recipe Patcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    try {
        $stream = [System.IO.File]::Open($globalIni, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $stream.Dispose()
    }
    catch {
        Add-LogLine "Итог: global.ini найден, но не читается: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "global.ini найден, но не читается. Закройте программы, которые могли заблокировать файл, и попробуйте снова.",
            'SCMDB Quest Recipe Patcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $reportDir = Join-Path $ScriptDir 'reports'
    $backupDir = Join-Path $ScriptDir 'backups'
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

    Add-LogLine 'Итог: OK. Путь подходит, global.ini найден и читается.'
    Add-LogLine 'Это быстрая проверка без загрузки SCMDB/Wiki. Для полной проверки используйте консольный dry-run из README.'
    Add-LogLine "Отчёты: $reportDir"
    Add-LogLine "Backups: $backupDir"

    [System.Windows.Forms.MessageBox]::Show(
        "Путь подходит. Можно нажимать `"Пропатчить`".",
        'SCMDB Quest Recipe Patcher',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Invoke-Patcher {
    param(
        [string]$Mode,
        [string[]]$ExtraArgs
    )

    $livePath = $pathBox.Text.Trim()
    if (-not (Test-LivePath -Path $livePath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Не найден global.ini. Выберите именно папку StarCitizen\LIVE.",
            'SCMDB Quest Recipe Patcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $buttons = @($checkButton, $patchButton, $restoreButton, $browseButton, $openReportsButton)
    foreach ($button in $buttons) { $button.Enabled = $false }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    try {
        $script:LastReportPath = $null
        $beforeReportPath = Get-LatestReportPath

        Add-LogLine ''
        Add-LogLine "== $Mode =="
        Add-LogLine "LIVE: $livePath"

        $parameters = @{
            LivePath = $livePath
        }

        foreach ($arg in $ExtraArgs) {
            switch ($arg) {
                '-DryRun' { $parameters['DryRun'] = $true }
                '-RestoreLatestBackup' { $parameters['RestoreLatestBackup'] = $true }
                default { throw "Unsupported launcher argument: $arg" }
            }
        }

        $output = & $PatchScript @parameters *>&1
        foreach ($line in $output) {
            Add-LogLine ([string]$line)
            if ([string]$line -match '^Report:\s*(.+)$') {
                $script:LastReportPath = $Matches[1].Trim()
            }
        }

        if ($LASTEXITCODE -ne 0) {
            Add-LogLine "Exit code: $LASTEXITCODE"
        }

        $reportPath = $script:LastReportPath
        if (-not $reportPath) {
            $latestReportPath = Get-LatestReportPath
            if ($latestReportPath -and $latestReportPath -ne $beforeReportPath) {
                $reportPath = $latestReportPath
                $script:LastReportPath = $latestReportPath
            }
        }
        Add-ReportSummary -Mode $Mode -ReportPath $reportPath

        [System.Windows.Forms.MessageBox]::Show(
            "$Mode завершено. Подробности в окне лога.",
            'SCMDB Quest Recipe Patcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        Add-LogLine "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'SCMDB Quest Recipe Patcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        foreach ($button in $buttons) { $button.Enabled = $true }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'SCMDB Quest Recipe Patcher'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(760, 520)
$form.MinimumSize = New-Object System.Drawing.Size(680, 460)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'SCMDB Quest Recipe Patcher'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(16, 14)
$form.Controls.Add($titleLabel)

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = 'Выберите папку StarCitizen\LIVE. "Проверить путь" не загружает SCMDB/Wiki.'
$hintLabel.AutoSize = $true
$hintLabel.Location = New-Object System.Drawing.Point(18, 48)
$form.Controls.Add($hintLabel)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Location = New-Object System.Drawing.Point(20, 78)
$pathBox.Size = New-Object System.Drawing.Size(580, 24)
$pathBox.Anchor = 'Top,Left,Right'
$pathBox.Text = Find-DefaultLivePath
$form.Controls.Add($pathBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = 'Выбрать...'
$browseButton.Location = New-Object System.Drawing.Point(612, 76)
$browseButton.Size = New-Object System.Drawing.Size(110, 28)
$browseButton.Anchor = 'Top,Right'
$browseButton.Add_Click({
    $selected = Select-LivePath -InitialPath $pathBox.Text
    if ($selected) {
        $pathBox.Text = $selected
    }
})
$form.Controls.Add($browseButton)

$checkButton = New-Object System.Windows.Forms.Button
$checkButton.Text = 'Проверить путь'
$checkButton.Location = New-Object System.Drawing.Point(20, 118)
$checkButton.Size = New-Object System.Drawing.Size(130, 34)
$checkButton.Add_Click({ Invoke-LightCheck })
$form.Controls.Add($checkButton)

$patchButton = New-Object System.Windows.Forms.Button
$patchButton.Text = 'Пропатчить'
$patchButton.Location = New-Object System.Drawing.Point(162, 118)
$patchButton.Size = New-Object System.Drawing.Size(130, 34)
$patchButton.Add_Click({ Invoke-Patcher -Mode 'Патч' -ExtraArgs @() })
$form.Controls.Add($patchButton)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = 'Откатить backup'
$restoreButton.Location = New-Object System.Drawing.Point(304, 118)
$restoreButton.Size = New-Object System.Drawing.Size(150, 34)
$restoreButton.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Восстановить последний backup global.ini?',
        'SCMDB Quest Recipe Patcher',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Invoke-Patcher -Mode 'Откат backup' -ExtraArgs @('-RestoreLatestBackup')
    }
})
$form.Controls.Add($restoreButton)

$openReportsButton = New-Object System.Windows.Forms.Button
$openReportsButton.Text = 'Открыть отчёты'
$openReportsButton.Location = New-Object System.Drawing.Point(466, 118)
$openReportsButton.Size = New-Object System.Drawing.Size(140, 34)
$openReportsButton.Add_Click({
    $reportDir = Join-Path $ScriptDir 'reports'
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    Start-Process explorer.exe $reportDir
})
$form.Controls.Add($openReportsButton)

$exitButton = New-Object System.Windows.Forms.Button
$exitButton.Text = 'Выход'
$exitButton.Location = New-Object System.Drawing.Point(618, 118)
$exitButton.Size = New-Object System.Drawing.Size(104, 34)
$exitButton.Anchor = 'Top,Right'
$exitButton.Add_Click({ $form.Close() })
$form.Controls.Add($exitButton)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 168)
$logBox.Size = New-Object System.Drawing.Size(702, 292)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

Add-LogLine 'Готово. Выберите LIVE и нажмите "Проверить путь" или "Пропатчить".'
if ($pathBox.Text) {
    Add-LogLine "Найден путь: $($pathBox.Text)"
}

[void]$form.ShowDialog()
