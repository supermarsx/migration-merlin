<#
.SYNOPSIS
    Zip the staged build directory into a release artefact.

.DESCRIPTION
    Takes the directory produced by Invoke-Build.ps1 and compresses it into
    `<OutputDir>\MigrationMerlin-<version>.zip`. The version is read from the
    VERSION file at the repo root (or -Version if supplied).

    If the destination zip already exists it is replaced.

.PARAMETER InputDir
    Path to the staged build directory (typically 'dist').

.PARAMETER OutputDir
    Directory to place the zip into (typically 'pkg'). Created if missing.

.PARAMETER Version
    Explicit version string; falls back to the repo VERSION file.

.EXAMPLE
    PS> .\.github\scripts\Invoke-Package.ps1 -InputDir dist -OutputDir pkg
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InputDir,

    [Parameter(Mandatory)]
    [string]$OutputDir,

    [string]$Version,

    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputDir)) {
    throw "Package: input directory '$InputDir' does not exist."
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionPath = Join-Path $RepoRoot 'VERSION'
    if (Test-Path -LiteralPath $versionPath) {
        $Version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = '0.0'
    }
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$zipName = "MigrationMerlin-$Version.zip"
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

# Compress the *contents* of $InputDir (wildcard) so the archive does not
# include the staging directory name as a top-level prefix.
$sourceGlob = Join-Path (Resolve-Path $InputDir).Path '*'
Compress-Archive -Path $sourceGlob -DestinationPath $zipPath -Force

$size = (Get-Item -LiteralPath $zipPath).Length
Write-Host "Package: wrote $zipPath ($size bytes) for version $Version"

# Emit the path on stdout so calling workflows / scripts can capture it.
Write-Output $zipPath
