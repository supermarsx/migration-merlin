@echo off
setlocal EnableDelayedExpansion
title Migration Merlin - Source PC Capture
color 0B

:: ---- Parse flags ----
:: Usage: 2-Capture-Source.bat ["\\DEST\Share$"] [/silent] [/extra]
:: The share path MUST be the first argument (quoted if it contains spaces).
set "SILENT="
set "PS_SILENT="
set "EXTRA_FLAG="
set "SHARE="

:: Parse positional: first arg is share (if not a flag), rest are flags
set "ARG1=%~1"
if defined ARG1 (
    if /i not "%ARG1%"=="/silent" if /i not "%ARG1%"=="-silent" if /i not "%ARG1%"=="/extra" if /i not "%ARG1%"=="-extra" (
        set "SHARE=%ARG1%"
    )
)

:: Parse all args for flags
for %%A in (%*) do (
    if /i "%%~A"=="/silent" ( set "SILENT=1" & set "PS_SILENT=-NonInteractive" )
    if /i "%%~A"=="-silent" ( set "SILENT=1" & set "PS_SILENT=-NonInteractive" )
    if /i "%%~A"=="/extra"  ( set "EXTRA_FLAG=-ExtraData" )
    if /i "%%~A"=="-extra"  ( set "EXTRA_FLAG=-ExtraData" )
)

if not defined SILENT (
    echo.
    echo  ============================================================
    echo     MIGRATION MERLIN - Source PC Capture
    echo  ============================================================
    echo.
    echo   This will:
    echo     [1] Install USMT automatically ^(if not present^)
    echo     [2] Inventory installed apps, printers, Wi-Fi, and more
    echo     [3] Capture all user profiles and settings
    echo     [4] Transfer everything to the destination PC share
    echo.
)

:: ---- Check for admin ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    if not defined SILENT echo   Requesting Administrator privileges...& echo.
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList '\"%SHARE%\" %2 %3 %4 %5' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

:: ---- Get share if not provided ----
if "!SHARE!"=="" (
    if defined SILENT (
        echo   ERROR: Share path required in silent mode.
        echo   Usage: %~nx0 "\\DEST-PC\MigrationShare$" /silent [/extra]
        exit /b 1
    )
    set /p "SHARE=  Enter destination share path (e.g. \\DEST-PC\MigrationShare$): "
)
if "!SHARE!"=="" (
    echo.& echo   ERROR: No share path entered. Exiting.
    if not defined SILENT pause
    exit /b 1
)

:: ---- Ask about extra data (only if interactive and not already set) ----
if not defined SILENT if not defined EXTRA_FLAG (
    set "ASK_EXTRA="
    set /p "ASK_EXTRA=  Include extra data? (Sticky Notes, taskbar pins, power plan) [Y/N]: "
    if /i "!ASK_EXTRA!"=="Y" set "EXTRA_FLAG=-ExtraData"
)

if not defined SILENT (
    echo.
    echo  ------------------------------------------------------------
    echo   Starting capture to: !SHARE!
    echo  ------------------------------------------------------------
    echo.
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "& '%~dp0..\scripts\source-capture.ps1' -DestinationShare '!SHARE!' !EXTRA_FLAG! !PS_SILENT!"

set "EXIT_CODE=%errorlevel%"

if not defined SILENT (
    echo.
    echo  ============================================================
    if !EXIT_CODE! equ 0 (
        echo   Capture completed successfully!
        color 0A
    ) else (
        echo   Capture encountered errors. Check output above.
        color 0C
    )
    echo  ============================================================
    echo.
    echo   Press any key to exit...
    pause >nul
)
exit /b %EXIT_CODE%
