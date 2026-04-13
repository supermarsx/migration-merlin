@echo off
title Migration Merlin

:: ---- Auto-elevate ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: pushd handles UNC paths by auto-mapping a temp drive letter
pushd "%~dp0"

:: Launch the interactive TUI
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Migration-Merlin.ps1"
if %errorlevel% neq 0 (
    echo.
    echo  TUI failed to launch. Run the numbered .bat files directly:
    echo    1-Setup-Destination.bat / 2-Capture-Source.bat / etc.
    echo.
    pause
)

popd
