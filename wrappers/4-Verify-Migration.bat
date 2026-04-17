@echo off
setlocal EnableDelayedExpansion
title MigrationMerlin - Verify Migration
color 0B

set "SILENT="
for %%A in (%*) do (
    if /i "%%A"=="/silent" set "SILENT=1"
    if /i "%%A"=="-silent" set "SILENT=1"
)

if not defined SILENT (
    echo.
    echo  ============================================================
    echo     MIGRATIONMERLIN - Post-Migration Verification
    echo  ============================================================
    echo.
    echo   This will compare the source PC inventory against
    echo   the current destination PC state and report any gaps.
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
    "& '%~dp0..\scripts\post-migration-verify.ps1'"

set "EXIT_CODE=%errorlevel%"

if not defined SILENT (
    echo.
    echo  ============================================================
    echo   Verification complete!
    echo  ============================================================
    echo.
    echo   Press any key to exit...
    pause >nul
)
exit /b %EXIT_CODE%
