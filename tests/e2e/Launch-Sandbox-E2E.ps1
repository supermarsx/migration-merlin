<#
.SYNOPSIS
    Launches Windows Sandbox with the E2E test suite.
.DESCRIPTION
    Starts a clean sandbox, maps the toolkit folder, and runs all E2E tests.
    Results are written back to tests/e2e/results/ (shared folder).
.NOTES
    Requires Windows Sandbox feature enabled:
      Enable-WindowsOptionalFeature -FeatureName Containers-DisposableClientVM -Online
#>

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot
$ProjectRoot = Split-Path (Split-Path $ScriptRoot -Parent) -Parent
$WsbFile = Join-Path $ScriptRoot 'sandbox-e2e.wsb'
$ResultsDir = Join-Path $ScriptRoot 'results'

# ── Pre-checks ──
Write-Host ''
Write-Host '  MigrationMerlin — E2E Sandbox Test Launcher' -ForegroundColor Cyan
Write-Host '  ──────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

# Check sandbox
if (-not (Test-Path 'C:\Windows\System32\WindowsSandbox.exe')) {
    Write-Host '  ERROR: Windows Sandbox not found.' -ForegroundColor Red
    Write-Host '  Enable it: Enable-WindowsOptionalFeature -FeatureName Containers-DisposableClientVM -Online' -ForegroundColor Yellow
    exit 1
}

# Check wsb file
if (-not (Test-Path $WsbFile)) {
    Write-Host "  ERROR: $WsbFile not found." -ForegroundColor Red
    exit 1
}

# Check toolkit zip
$zip = Join-Path $ProjectRoot 'user-state-migration-tool.zip'
if (-not (Test-Path $zip)) {
    Write-Host "  WARNING: user-state-migration-tool.zip not found." -ForegroundColor Yellow
    Write-Host "  USMT extraction tests will fail." -ForegroundColor Yellow
    Write-Host ''
}

# Clean previous results
if (Test-Path $ResultsDir) {
    Remove-Item "$ResultsDir\*" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "  Project:  $ProjectRoot" -ForegroundColor Gray
Write-Host "  WSB file: $WsbFile" -ForegroundColor Gray
Write-Host "  Results:  $ResultsDir" -ForegroundColor Gray
Write-Host ''
Write-Host '  Launching sandbox...' -ForegroundColor Cyan

# Launch sandbox
Start-Process 'WindowsSandbox.exe' -ArgumentList $WsbFile

Write-Host '  Sandbox started. Tests running inside...' -ForegroundColor Green
Write-Host ''
Write-Host '  When tests complete, results will appear in:' -ForegroundColor Gray
Write-Host "    $ResultsDir\e2e-summary.json" -ForegroundColor White
Write-Host "    $ResultsDir\e2e-run.log" -ForegroundColor White
Write-Host ''

# Wait for results
Write-Host '  Waiting for results...' -ForegroundColor DarkGray -NoNewline
$summaryFile = Join-Path $ResultsDir 'e2e-summary.json'
$timeout = 600  # 10 minutes
$elapsed = 0
while (-not (Test-Path $summaryFile) -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    Write-Host '.' -NoNewline -ForegroundColor DarkGray
}
Write-Host ''

if (Test-Path $summaryFile) {
    Write-Host ''
    $summary = Get-Content $summaryFile -Raw | ConvertFrom-Json
    $color = if ($summary.Failed -eq 0) { 'Green' } else { 'Red' }
    Write-Host "  ══════════════════════════════════════" -ForegroundColor $color
    Write-Host "  E2E Results: $($summary.Passed) passed, $($summary.Failed) failed (of $($summary.Total))" -ForegroundColor $color
    Write-Host "  OS: $($summary.OS)" -ForegroundColor Gray
    Write-Host "  Arch: $($summary.Arch)" -ForegroundColor Gray
    Write-Host "  ══════════════════════════════════════" -ForegroundColor $color
    Write-Host ''

    if ($summary.Failed -gt 0) {
        Write-Host '  Failed tests (see log for details):' -ForegroundColor Red
        $log = Get-Content (Join-Path $ResultsDir 'e2e-run.log') -Encoding UTF8
        $log | Where-Object { $_ -match 'FAIL' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    }
}
else {
    Write-Host '  TIMEOUT: Sandbox did not produce results within 10 minutes.' -ForegroundColor Red
    Write-Host '  Check if sandbox is still running or if tests errored early.' -ForegroundColor Yellow
}
