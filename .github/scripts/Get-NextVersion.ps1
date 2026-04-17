<#
.SYNOPSIS
    Compute the next rolling-release version in YY.N format.

.DESCRIPTION
    Reads the repository-root version file, parses its YY.N contents, and
    returns the next version:

      * If the stored year (YY) matches the current year, N is incremented.
      * If the year has changed, the version resets to "<current YY>.1".

    When -Write is supplied the version file is updated in place (no trailing
    newline). The next version string is always written to the output stream
    so callers can capture it.

    If the version file is missing or empty the script initialises it to
    "<current YY>.1" instead of throwing.

.PARAMETER Write
    When specified, persist the computed next version to the version file.

.PARAMETER Now
    Optional override for the current date. Primarily for tests that need to
    simulate year boundaries.

.EXAMPLE
    PS> .\Get-NextVersion.ps1
    26.2

.EXAMPLE
    PS> .\Get-NextVersion.ps1 -Write
#>
[CmdletBinding()]
param(
    [switch]$Write,
    [datetime]$Now = (Get-Date)
)

$ErrorActionPreference = 'Stop'

$versionPath = Join-Path $PSScriptRoot '..\..\version'
$currentYear = [int]$Now.ToString('yy')

$current = $null
if (Test-Path -LiteralPath $versionPath) {
    $raw = Get-Content -LiteralPath $versionPath -Raw -ErrorAction SilentlyContinue
    if ($null -ne $raw) {
        $current = $raw.Trim()
    }
}

if ([string]::IsNullOrWhiteSpace($current)) {
    # Bootstrap: missing/empty version file starts at <YY>.1.
    $next = '{0:D2}.1' -f $currentYear
}
else {
    if ($current -notmatch '^(\d{2})\.(\d+)$') {
        throw "version file has invalid format: '$current'. Expected YY.N."
    }

    $storedYear = [int]$matches[1]
    $storedN    = [int]$matches[2]

    if ($currentYear -ne $storedYear) {
        $next = '{0:D2}.1' -f $currentYear
    }
    else {
        $next = '{0:D2}.{1}' -f $storedYear, ($storedN + 1)
    }
}

if ($Write) {
    # -NoNewline keeps the file free of a trailing LF so the value is
    # byte-for-byte stable between writes.
    Set-Content -LiteralPath $versionPath -Value $next -NoNewline -Encoding ascii
}

Write-Output $next
