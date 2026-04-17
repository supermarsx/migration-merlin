<#
.SYNOPSIS
    Build step for migration-merlin.

.DESCRIPTION
    Since this project ships PowerShell source (nothing compiles), the
    "build" step is really a verification + staging step:

      1. Parse every .ps1/.psm1 under the production tree with the PowerShell
         parser and fail fast on any syntax errors.
      2. Copy the production payload into -OutputDir, leaving developer
         artefacts (tests, .github, .orchestration, .git, build outputs)
         behind.
      3. Write a BUILD_INFO.txt stamp containing the commit SHA, build date
         and current version for traceability.

    The resulting directory is what the package step zips.

.PARAMETER OutputDir
    Destination directory for the staged build. Created if missing. Cleaned
    before each run.

.PARAMETER RepoRoot
    Override for the repository root. Defaults to the directory two levels
    above this script (.github/scripts -> repo root).

.EXAMPLE
    PS> .\.github\scripts\Invoke-Build.ps1 -OutputDir dist
#>
[CmdletBinding()]
param(
    [string]$OutputDir = 'dist',
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

Write-Host "Build: repo root = $RepoRoot"
Write-Host "Build: output    = $OutputDir"

# --- 1. Syntax-validate every PowerShell source file -----------------------

$srcDirs = @('modules', 'scripts', 'wrappers', 'config') |
    ForEach-Object { Join-Path $RepoRoot $_ } |
    Where-Object { Test-Path $_ }

$entryFiles = @('MigrationMerlin.ps1') |
    ForEach-Object { Join-Path $RepoRoot $_ } |
    Where-Object { Test-Path $_ }

$psFiles = @()
foreach ($dir in $srcDirs) {
    $psFiles += Get-ChildItem -Path $dir -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue
}
foreach ($file in $entryFiles) {
    $psFiles += Get-Item -LiteralPath $file
}

$syntaxErrors = 0
foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $syntaxErrors += $errors.Count
        foreach ($err in $errors) {
            Write-Host "SYNTAX ERROR  $($file.FullName):$($err.Extent.StartLineNumber)  $($err.Message)"
        }
    }
}
if ($syntaxErrors -gt 0) {
    throw "Build failed: $syntaxErrors syntax error(s) detected."
}
Write-Host "Build: parsed $($psFiles.Count) PowerShell file(s) cleanly."

# --- 2. Stage production payload into $OutputDir ---------------------------

$absOutput = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
}
else {
    Join-Path $RepoRoot $OutputDir
}

if (Test-Path -LiteralPath $absOutput) {
    Remove-Item -LiteralPath $absOutput -Recurse -Force
}
New-Item -ItemType Directory -Path $absOutput -Force | Out-Null

$stageDirs = @('modules', 'scripts', 'wrappers', 'config', 'assets')
foreach ($dir in $stageDirs) {
    $src = Join-Path $RepoRoot $dir
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $absOutput -Recurse -Force
    }
}

$stageFiles = @(
    'MigrationMerlin.ps1',
    'MigrationMerlin.bat',
    'readme.md',
    'README.md',
    'license.md',
    'LICENSE.md',
    'LICENSE',
    'version',
    # Bundled USMT binaries. Shipping the zip inside the release artifact
    # means users on offline / air-gapped machines do not have to fetch
    # USMT separately; Expand-BundledUSMT finds it at the repo root.
    'user-state-migration-tool.zip'
)
foreach ($file in $stageFiles) {
    $src = Join-Path $RepoRoot $file
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $absOutput -Force
    }
}

# --- 3. Stamp build info ---------------------------------------------------

$version = 'unknown'
$versionPath = Join-Path $RepoRoot 'version'
if (Test-Path -LiteralPath $versionPath) {
    $version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
}

$sha = $env:GITHUB_SHA
if ([string]::IsNullOrWhiteSpace($sha)) {
    try {
        Push-Location $RepoRoot
        $sha = (git rev-parse HEAD 2>$null).Trim()
    }
    catch {
        $sha = 'unknown'
    }
    finally {
        Pop-Location
    }
}
if ([string]::IsNullOrWhiteSpace($sha)) { $sha = 'unknown' }

$buildInfo = @(
    "MigrationMerlin build information",
    "---------------------------------",
    "Version:    $version",
    "Commit:     $sha",
    "BuildDate:  $((Get-Date).ToUniversalTime().ToString('u'))",
    "Host:       $([System.Environment]::MachineName)"
) -join [System.Environment]::NewLine

Set-Content -LiteralPath (Join-Path $absOutput 'BUILD_INFO.txt') -Value $buildInfo -Encoding utf8

Write-Host "Build: staged payload to $absOutput"
Write-Host "Build: version = $version, commit = $sha"
