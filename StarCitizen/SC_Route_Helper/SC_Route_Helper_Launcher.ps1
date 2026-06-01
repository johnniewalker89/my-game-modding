$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkerScript = Join-Path $ScriptDir 'SC_Route_Helper.ps1'

function Test-LivePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return (Test-Path -LiteralPath (Join-Path $Path 'Game.log') -PathType Leaf)
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

function Select-BatPath {
    param([string]$InitialPath)

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Выберите исходный zapret .bat'
    $dialog.Filter = 'Batch files (*.bat)|*.bat|All files (*.*)|*.*'
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false

    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        if (Test-Path -LiteralPath $InitialPath -PathType Leaf) {
            $dialog.FileName = $InitialPath
            $dialog.InitialDirectory = Split-Path -Parent $InitialPath
        }
        elseif (Test-Path -LiteralPath $InitialPath -PathType Container) {
            $dialog.InitialDirectory = $InitialPath
        }
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
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

function Set-StatusIdle {
    $statusLabel.Text = 'Готово'
}

function Set-StatusBusy {
    param([string]$Text)

    $statusLabel.Text = $Text
}

function Quote-PowerShellLiteral {
    param([string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Invoke-Worker {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$ModeText,
        [switch]$NeedsLivePath,
        [switch]$NeedsBatPath
    )

    if (-not (Test-Path -LiteralPath $WorkerScript -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Не найден SC_Route_Helper.ps1.",
            'SC Route Helper',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $livePath = $livePathBox.Text.Trim()
    $batPath = $batPathBox.Text.Trim()

    if ($NeedsLivePath -and [string]::IsNullOrWhiteSpace($livePath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Выберите папку StarCitizen\LIVE.",
            'SC Route Helper',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    if ($NeedsBatPath -and [string]::IsNullOrWhiteSpace($batPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Выберите исходный zapret .bat.",
            'SC Route Helper',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $buttons = @($checkGameButton, $startButton, $stopButton, $showCandidatesButton, $createBatButton, $browseLiveButton, $browseBatButton, $openReportsButton)
    foreach ($button in $buttons) { $button.Enabled = $false }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    Set-StatusBusy -Text $ModeText

    try {
        Add-LogLine ''
        Add-LogLine "== $ModeText =="

        $args = @("-Action $(Quote-PowerShellLiteral -Value $Action)")
        if ($livePath) {
            $args += "-LivePath $(Quote-PowerShellLiteral -Value $livePath)"
        }
        if ($batPath) {
            $args += "-SourceBatPath $(Quote-PowerShellLiteral -Value $batPath)"
        }

        $powerShellExe = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
            $powerShellExe = 'powershell.exe'
        }

        $reportsDir = Join-Path $ScriptDir 'reports'
        New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
        $runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $runLogPath = Join-Path $reportsDir "launcher-run-$runStamp.log"
        Set-Content -LiteralPath $runLogPath -Value $null -Encoding UTF8

        $command = @"
`$logPath = $(Quote-PowerShellLiteral -Value $runLogPath)
function Write-LauncherRunLog {
    param([string]`$Text)
    Add-Content -LiteralPath `$logPath -Value `$Text -Encoding UTF8
}

try {
    & $(Quote-PowerShellLiteral -Value $WorkerScript) $($args -join ' ') *>&1 | ForEach-Object {
        Write-LauncherRunLog ([string]`$_)
    }
    if (`$global:LASTEXITCODE) { exit `$global:LASTEXITCODE }
    exit 0
}
catch {
    Write-LauncherRunLog ("ERROR: " + `$_.Exception.Message)
    exit 1
}
"@

        $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $powerShellExe
        $processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $false
        $processInfo.RedirectStandardError = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        [void]$process.Start()

        $seenLineCount = 0
        while (-not $process.HasExited) {
            if (Test-Path -LiteralPath $runLogPath -PathType Leaf) {
                $lines = @(Get-Content -LiteralPath $runLogPath -ErrorAction SilentlyContinue)
                if ($lines.Count -gt $seenLineCount) {
                    foreach ($line in @($lines[$seenLineCount..($lines.Count - 1)])) {
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            Add-LogLine ([string]$line)
                        }
                    }
                    $seenLineCount = $lines.Count
                }
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
        $process.WaitForExit()

        if (Test-Path -LiteralPath $runLogPath -PathType Leaf) {
            $lines = @(Get-Content -LiteralPath $runLogPath -ErrorAction SilentlyContinue)
            if ($lines.Count -gt $seenLineCount) {
                foreach ($line in @($lines[$seenLineCount..($lines.Count - 1)])) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        Add-LogLine ([string]$line)
                    }
                }
            }
        }

        if ($process.ExitCode -ne 0) {
            Add-LogLine "Exit code: $($process.ExitCode)"
            [System.Windows.Forms.MessageBox]::Show(
                "$ModeText завершено с ошибкой. Подробности в окне лога.",
                'SC Route Helper',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "$ModeText завершено. Подробности в окне лога.",
                'SC Route Helper',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        Add-LogLine "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'SC Route Helper',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        Set-StatusIdle
        foreach ($button in $buttons) { $button.Enabled = $true }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'SC Route Helper'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(820, 560)
$form.MinimumSize = New-Object System.Drawing.Size(760, 520)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'SC Route Helper'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(16, 14)
$form.Controls.Add($titleLabel)

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = 'Начните запись перед запуском Star Citizen, остановите после ошибки, затем создайте новый zapret bat.'
$hintLabel.AutoSize = $true
$hintLabel.Location = New-Object System.Drawing.Point(18, 48)
$form.Controls.Add($hintLabel)

$liveLabel = New-Object System.Windows.Forms.Label
$liveLabel.Text = 'StarCitizen\LIVE'
$liveLabel.Location = New-Object System.Drawing.Point(20, 80)
$liveLabel.Size = New-Object System.Drawing.Size(140, 20)
$form.Controls.Add($liveLabel)

$livePathBox = New-Object System.Windows.Forms.TextBox
$livePathBox.Location = New-Object System.Drawing.Point(160, 76)
$livePathBox.Size = New-Object System.Drawing.Size(500, 24)
$livePathBox.Anchor = 'Top,Left,Right'
$livePathBox.Text = Find-DefaultLivePath
$form.Controls.Add($livePathBox)

$browseLiveButton = New-Object System.Windows.Forms.Button
$browseLiveButton.Text = 'Выбрать...'
$browseLiveButton.Location = New-Object System.Drawing.Point(672, 74)
$browseLiveButton.Size = New-Object System.Drawing.Size(110, 28)
$browseLiveButton.Anchor = 'Top,Right'
$browseLiveButton.Add_Click({
    $selected = Select-LivePath -InitialPath $livePathBox.Text
    if ($selected) {
        $livePathBox.Text = $selected
    }
})
$form.Controls.Add($browseLiveButton)

$batLabel = New-Object System.Windows.Forms.Label
$batLabel.Text = 'Исходный zapret .bat'
$batLabel.Location = New-Object System.Drawing.Point(20, 116)
$batLabel.Size = New-Object System.Drawing.Size(140, 20)
$form.Controls.Add($batLabel)

$batPathBox = New-Object System.Windows.Forms.TextBox
$batPathBox.Location = New-Object System.Drawing.Point(160, 112)
$batPathBox.Size = New-Object System.Drawing.Size(500, 24)
$batPathBox.Anchor = 'Top,Left,Right'
$form.Controls.Add($batPathBox)

$browseBatButton = New-Object System.Windows.Forms.Button
$browseBatButton.Text = 'Выбрать...'
$browseBatButton.Location = New-Object System.Drawing.Point(672, 110)
$browseBatButton.Size = New-Object System.Drawing.Size(110, 28)
$browseBatButton.Anchor = 'Top,Right'
$browseBatButton.Add_Click({
    $selected = Select-BatPath -InitialPath $batPathBox.Text
    if ($selected) {
        $batPathBox.Text = $selected
    }
})
$form.Controls.Add($browseBatButton)

$checkGameButton = New-Object System.Windows.Forms.Button
$checkGameButton.Text = 'Проверить игру'
$checkGameButton.Location = New-Object System.Drawing.Point(20, 154)
$checkGameButton.Size = New-Object System.Drawing.Size(130, 34)
$checkGameButton.Add_Click({ Invoke-Worker -Action 'CheckGame' -ModeText 'Проверка игры' -NeedsLivePath })
$form.Controls.Add($checkGameButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = 'Начать запись'
$startButton.Location = New-Object System.Drawing.Point(162, 154)
$startButton.Size = New-Object System.Drawing.Size(130, 34)
$startButton.Add_Click({ Invoke-Worker -Action 'Start' -ModeText 'Начало записи' -NeedsLivePath })
$form.Controls.Add($startButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = 'Остановить и разобрать'
$stopButton.Location = New-Object System.Drawing.Point(304, 154)
$stopButton.Size = New-Object System.Drawing.Size(170, 34)
$stopButton.Add_Click({ Invoke-Worker -Action 'Stop' -ModeText 'Остановка и разбор' -NeedsLivePath })
$form.Controls.Add($stopButton)

$showCandidatesButton = New-Object System.Windows.Forms.Button
$showCandidatesButton.Text = 'Показать IP'
$showCandidatesButton.Location = New-Object System.Drawing.Point(486, 154)
$showCandidatesButton.Size = New-Object System.Drawing.Size(120, 34)
$showCandidatesButton.Add_Click({ Invoke-Worker -Action 'ShowCandidates' -ModeText 'Список IP' })
$form.Controls.Add($showCandidatesButton)

$createBatButton = New-Object System.Windows.Forms.Button
$createBatButton.Text = 'Создать bat'
$createBatButton.Location = New-Object System.Drawing.Point(618, 154)
$createBatButton.Size = New-Object System.Drawing.Size(110, 34)
$createBatButton.Add_Click({ Invoke-Worker -Action 'CreateBat' -ModeText 'Создание bat' -NeedsBatPath })
$form.Controls.Add($createBatButton)

$openReportsButton = New-Object System.Windows.Forms.Button
$openReportsButton.Text = 'Отчёты'
$openReportsButton.Location = New-Object System.Drawing.Point(20, 198)
$openReportsButton.Size = New-Object System.Drawing.Size(100, 30)
$openReportsButton.Add_Click({
    $reportsDir = Join-Path $ScriptDir 'reports'
    $evidenceDir = Join-Path $ScriptDir 'evidence'
    New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
    New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
    Start-Process explorer.exe $evidenceDir
})
$form.Controls.Add($openReportsButton)

$exitButton = New-Object System.Windows.Forms.Button
$exitButton.Text = 'Выход'
$exitButton.Location = New-Object System.Drawing.Point(672, 198)
$exitButton.Size = New-Object System.Drawing.Size(110, 30)
$exitButton.Anchor = 'Top,Right'
$exitButton.Add_Click({ $form.Close() })
$form.Controls.Add($exitButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Готово'
$statusLabel.Location = New-Object System.Drawing.Point(20, 238)
$statusLabel.Size = New-Object System.Drawing.Size(762, 20)
$statusLabel.Anchor = 'Top,Left,Right'
$form.Controls.Add($statusLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 266)
$logBox.Size = New-Object System.Drawing.Size(762, 236)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

Add-LogLine 'Готово. Выберите LIVE, нажмите "Начать запись", затем после ошибки "Остановить и разобрать".'
if ($livePathBox.Text) {
    Add-LogLine "Найден путь: $($livePathBox.Text)"
}

[void]$form.ShowDialog()
