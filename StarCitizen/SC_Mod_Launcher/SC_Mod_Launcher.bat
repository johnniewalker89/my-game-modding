@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "LAUNCHER_EXE=%SCRIPT_DIR%app\SCModLauncher.exe"

if not exist "%LAUNCHER_EXE%" (
    echo Error: app\SCModLauncher.exe not found.
    echo Run tools\Build-WpfLauncher.ps1 first.
    pause
    exit /b 1
)

if "%~1"=="" (
    start "" "%LAUNCHER_EXE%"
    exit /b 0
) else (
    "%LAUNCHER_EXE%" %*
)

echo.
pause
