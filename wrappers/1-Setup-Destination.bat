@echo off
setlocal EnableDelayedExpansion
title MigrationMerlin - Destination PC Setup
color 0B

:: ---- Parse /silent flag ----
set "SILENT="
set "PS_SILENT="
for %%A in (%*) do (
    if /i "%%A"=="/silent" set "SILENT=1" & set "PS_SILENT=-NonInteractive"
    if /i "%%A"=="-silent" set "SILENT=1" & set "PS_SILENT=-NonInteractive"
)

if not defined SILENT (
    echo.
    echo  ============================================================
    echo     MIGRATIONMERLIN - Destination PC Setup
    echo  ============================================================
    echo.
    echo   This will:
    echo     [1] Install USMT automatically ^(if not present^)
    echo     [2] Create a network share for migration data
    echo     [3] Configure firewall rules
    echo     [4] Wait for source PC to send data
    echo.
    echo   Press any key to continue or close this window to cancel...
    pause >nul
)

:: ---- Check for admin ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    if not defined SILENT echo.& echo   Requesting Administrator privileges...& echo.
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "& '%~dp0..\scripts\destination-setup.ps1' %PS_SILENT%"

set "EXIT_CODE=%errorlevel%"

if not defined SILENT (
    echo.
    echo  ============================================================
    if %EXIT_CODE% equ 0 (
        echo   Setup completed successfully!
        color 0A
    ) else (
        echo   Setup encountered errors. Check output above.
        color 0C
    )
    echo  ============================================================
    echo.
    echo   Press any key to exit...
    pause >nul
)
exit /b %EXIT_CODE%
