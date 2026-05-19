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

        $output = & $PatchScript @parameters 2>&1
        foreach ($line in $output) {
            Add-LogLine ([string]$line)
            if ([string]$line -match '^Report:\s*(.+)$') {
                $script:LastReportPath = $Matches[1].Trim()
            }
        }

        if ($LASTEXITCODE -ne 0) {
            Add-LogLine "Exit code: $LASTEXITCODE"
        }

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
$hintLabel.Text = 'Выберите папку StarCitizen\LIVE. Перед патчем рекомендуется нажать "Проверить".'
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
$checkButton.Text = 'Проверить'
$checkButton.Location = New-Object System.Drawing.Point(20, 118)
$checkButton.Size = New-Object System.Drawing.Size(130, 34)
$checkButton.Add_Click({ Invoke-Patcher -Mode 'Проверка' -ExtraArgs @('-DryRun') })
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

Add-LogLine 'Готово. Выберите LIVE и нажмите "Проверить" или "Пропатчить".'
if ($pathBox.Text) {
    Add-LogLine "Найден путь: $($pathBox.Text)"
}

[void]$form.ShowDialog()
