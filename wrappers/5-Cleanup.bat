@echo off
setlocal EnableDelayedExpansion
title Migration Merlin - Cleanup
color 0E

set "SILENT="
set "PS_SILENT="
for %%A in (%*) do (
    if /i "%%A"=="/silent" set "SILENT=1" & set "PS_SILENT=-NonInteractive"
    if /i "%%A"=="-silent" set "SILENT=1" & set "PS_SILENT=-NonInteractive"
)

if not defined SILENT (
    echo.
    echo  ============================================================
    echo     MIGRATION MERLIN - Cleanup
    echo  ============================================================
    echo.
    echo   This will remove:
    echo     - The migration network share
    echo     - Temporary firewall rules
    echo     - Optionally, the migration store data
    echo.
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    if not defined SILENT echo   Requesting Administrator privileges...& echo.
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "& '%~dp0..\scripts\destination-setup.ps1' -Cleanup %PS_SILENT%"

set "EXIT_CODE=%errorlevel%"

if not defined SILENT (
    echo.
    echo  ============================================================
    echo   Cleanup complete!
    echo  ============================================================
    echo.
    echo   Press any key to exit...
    pause >nul
)
exit /b %EXIT_CODE%
