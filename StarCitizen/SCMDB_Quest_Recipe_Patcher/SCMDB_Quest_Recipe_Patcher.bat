@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%SCMDB_Quest_Recipe_Patcher.ps1"
set "LAUNCHER_SCRIPT=%SCRIPT_DIR%SCMDB_Quest_Recipe_Launcher.ps1"

if not exist "%PS_SCRIPT%" (
    echo Error: SCMDB_Quest_Recipe_Patcher.ps1 not found.
    pause
    exit /b 1
)

if "%~1"=="" (
    if not exist "%LAUNCHER_SCRIPT%" (
        echo Error: SCMDB_Quest_Recipe_Launcher.ps1 not found.
        pause
        exit /b 1
    )
    start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%LAUNCHER_SCRIPT%"
    exit /b 0
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
)

echo.
pause
