<#
.SYNOPSIS
    Compute the next rolling-release version in YY.N format.

.DESCRIPTION
    Reads the repository-root version file, parses its YY.N contents, and
    returns the next version:

      * If the stored year (YY) matches the current year, N is incremented.
      * If the year has changed, the version resets to "<current YY>.1".

    When -Write is supplied the version file is updated in place (no trailing
    newline), and the README version badge is updated to match. The next
    version string is always written to the output stream so callers can
    capture it.

    If the version file is missing or empty the script initialises it to
    "<current YY>.1" instead of throwing.

.PARAMETER Write
    When specified, persist the version to the version file and README badge.

.PARAMETER Version
    Optional explicit version to write instead of computing the next version.
    This is used by CI jobs that need to apply the frozen build version after
    a fresh checkout.

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
    [string]$Version,
    [datetime]$Now = (Get-Date)
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')
$versionPath = Join-Path $repoRoot 'version'
$readmePath = Join-Path $repoRoot 'readme.md'
$currentYear = [int]$Now.ToString('yy')

function Update-ReadmeVersionBadge {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    if (-not (Test-Path -LiteralPath $readmePath)) {
        return
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $readme = [System.IO.File]::ReadAllText($readmePath, $utf8NoBom)
    $pattern = '(https://img\.shields\.io/badge/version-)([^-?\s\)]+)'

    if ($readme -notmatch $pattern) {
        throw "README version badge not found in '$readmePath'."
    }

    $updated = $readme -replace $pattern, "`${1}$Value"
    [System.IO.File]::WriteAllText($readmePath, $updated, $utf8NoBom)
}

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $next = $Version.Trim()

    if ($next -notmatch '^\d{2}\.\d+$') {
        throw "version has invalid format: '$next'. Expected YY.N."
    }
}
else {
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
        $storedN = [int]$matches[2]

        if ($currentYear -ne $storedYear) {
            $next = '{0:D2}.1' -f $currentYear
        }
        else {
            $next = '{0:D2}.{1}' -f $storedYear, ($storedN + 1)
        }
    }
}

if ($Write) {
    # -NoNewline keeps the file free of a trailing LF so the value is
    # byte-for-byte stable between writes.
    Set-Content -LiteralPath $versionPath -Value $next -NoNewline -Encoding ascii
    Update-ReadmeVersionBadge -Value $next
}

Write-Output $next
