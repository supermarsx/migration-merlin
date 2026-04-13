<#
.SYNOPSIS
    Runs the full Pester test suite for migration-merlin.
.DESCRIPTION
    Executes all *.Tests.ps1 files in this directory and produces
    a summary report. Supports filtering by test file name.
.EXAMPLE
    .\Run-Tests.ps1                           # Run all tests
    .\Run-Tests.ps1 -Filter "destination"     # Run only destination tests
    .\Run-Tests.ps1 -Output Detailed          # Verbose output
    .\Run-Tests.ps1 -CI                       # CI mode with JUnit XML output
#>

param(
    [string]$Filter = "*",
    [ValidateSet("Minimal", "Normal", "Detailed", "Diagnostic")]
    [string]$Output = "Normal",
    [switch]$CI
)

$ErrorActionPreference = "Stop"

# Ensure Pester v5+ is available
$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version.Major -lt 5) {
    Write-Host "Installing Pester v5..." -ForegroundColor Yellow
    Install-Module Pester -Force -Scope CurrentUser -MinimumVersion 5.0.0 -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.0.0

$testDir = $PSScriptRoot
$testFiles = Get-ChildItem $testDir -Filter "*$Filter*.Tests.ps1" | Sort-Object Name

if ($testFiles.Count -eq 0) {
    Write-Host "No test files matching '$Filter' found in $testDir" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Magenta
Write-Host "    Migration Merlin - Test Suite" -ForegroundColor Magenta
Write-Host "  ============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Test files:" -ForegroundColor Cyan
foreach ($f in $testFiles) {
    Write-Host "    - $($f.Name)" -ForegroundColor White
}
Write-Host ""

$config = New-PesterConfiguration
$config.Run.Path = $testFiles.FullName
$config.Run.Exit = $CI.IsPresent
$config.Output.Verbosity = $Output

if ($CI) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = "JUnitXml"
    $config.TestResult.OutputPath = Join-Path $testDir "test-results.xml"
}

$result = Invoke-Pester -Configuration $config

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Magenta
if ($result.FailedCount -eq 0) {
    Write-Host "    ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "    $($result.FailedCount) TEST(S) FAILED" -ForegroundColor Red
}
Write-Host "    Passed: $($result.PassedCount)  Failed: $($result.FailedCount)  Skipped: $($result.SkippedCount)" -ForegroundColor White
Write-Host "    Duration: $([math]::Round($result.Duration.TotalSeconds, 2))s" -ForegroundColor DarkGray
Write-Host "  ============================================" -ForegroundColor Magenta
Write-Host ""

exit $result.FailedCount
