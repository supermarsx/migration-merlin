@echo off
setlocal EnableDelayedExpansion
title Migration Merlin - Restore on Destination PC
color 0B

set "SILENT="
set "PS_SILENT="
for %%A in (%*) do (
    if /i "%%A"=="/silent" set "SILENT=1" & set "PS_SILENT=-NonInteractive"
    if /i "%%A"=="-silent" set "SILENT=1" & set "PS_SILENT=-NonInteractive"
)

if not defined SILENT (
    echo.
    echo  ============================================================
    echo     MIGRATION MERLIN - Restore User State
    echo  ============================================================
    echo.
    echo   This will restore captured user data using USMT LoadState.
    echo   Run this AFTER the source PC capture has completed.
    echo.
    echo   Press any key to continue or close this window to cancel...
    pause >nul
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    if not defined SILENT echo.& echo   Requesting Administrator privileges...& echo.
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "& '%~dp0destination-setup.ps1' -RestoreOnly %PS_SILENT%"

set "EXIT_CODE=%errorlevel%"

if not defined SILENT (
    echo.
    echo  ============================================================
    if %EXIT_CODE% equ 0 (
        echo   Restore completed successfully!
        color 0A
        echo.
        echo   Next step: Run "4-Verify-Migration.bat" to check results.
    ) else (
        echo   Restore encountered errors. Check output above.
        color 0C
    )
    echo  ============================================================
    echo.
    echo   Press any key to exit...
    pause >nul
)
exit /b %EXIT_CODE%
