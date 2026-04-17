<#
.SYNOPSIS
    Centralized constants for the Migration-Merlin toolkit.
.DESCRIPTION
    Exports a single read-only hashtable `$MigrationConstants` that replaces
    values previously duplicated across source-capture.ps1, destination-setup.ps1,
    post-migration-verify.ps1, and Migration-Merlin.ps1.

    A `Get-MigrationConstant` helper supports dotted-path lookup (e.g.
    `Get-MigrationConstant 'USMT.ZipName'`).

    NOTE: `$PSScriptRoot` at module-load time resolves to the `modules/`
    directory that contains MigrationConstants.psm1. The bundled USMT-Tools
    directory lives at the repo root (one level up), so USMT.SearchPaths
    rebases its default to `(Split-Path $PSScriptRoot -Parent)\USMT-Tools`
    to continue pointing at the toolkit directory.
.NOTES
    Exports:
      - $MigrationConstants   (read-only hashtable)
      - Get-MigrationConstant (dotted-path accessor)
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Build the constants hashtable
# ---------------------------------------------------------------------------
$__USMTSearchPaths = @(
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'USMT-Tools')
    "$env:TEMP\USMT-Tools"
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
    "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
    "C:\USMT"
    "C:\Tools\USMT"
)

$__SpinnerFrames = @(
    [char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838,
    [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827,
    [char]0x2807, [char]0x280F
)

$__SimpleSpinnerFrames = @('|','/','-','\')

$__StatusIcons = @{
    OK   = '[+]'
    FAIL = '[X]'
    WARN = '[!]'
    WAIT = '[~]'
    INFO = '[i]'
}

$__StatusColors = @{
    OK   = 'Green'
    FAIL = 'Red'
    WARN = 'Yellow'
    WAIT = 'DarkCyan'
    INFO = 'Gray'
}

$__Constants = @{
    USMT = @{
        # Candidate directories searched by Find-USMT in order.
        SearchPaths      = [string[]]$__USMTSearchPaths
        # Name of the bundled zip file that ships next to the toolkit.
        ZipName          = 'user-state-migration-tool.zip'
        # Root folder inside the zip (created after extraction).
        ZipInternalRoot  = 'User State Migration Tool'
        # Executable names used during detection / invocation.
        ScanStateExe     = 'scanstate.exe'
        LoadStateExe     = 'loadstate.exe'
    }

    ADK = @{
        # Windows ADK online installer (fallback when no bundled zip is present).
        InstallerUrl  = 'https://go.microsoft.com/fwlink/?linkid=2271337'
        InstallerFile = 'adksetup.exe'
    }

    Defaults = @{
        MigrationFolder  = 'C:\MigrationStore'
        ShareName        = 'MigrationShare$'
        ShareDescription = 'Migration-Merlin migration share'
    }

    UI = @{
        # Widths used by Show-Step and Show-ProgressBar respectively.
        ProgressBarWidth    = 30
        SubProgressBarWidth = 35
        # Default step counts per script (verified against sources).
        SourceTotalSteps      = 7
        DestinationTotalSteps = 5
        # Banner width used by Show-Banner.
        BannerWidth         = 56
        # Spinner frames.
        SpinnerFrames       = $__SpinnerFrames
        SimpleSpinnerFrames = $__SimpleSpinnerFrames
        # Status level -> icon / color.
        StatusIcons  = $__StatusIcons
        StatusColors = $__StatusColors
    }

    Logging = @{
        DefaultLogFolder = "$env:TEMP\MigrationMerlin"
    }
}

# Exported as a plain hashtable. Callers are expected to treat it as read-only
# by convention; mutating it at runtime would propagate to every consumer.
$MigrationConstants = $__Constants

# ---------------------------------------------------------------------------
# Dotted-path accessor
# ---------------------------------------------------------------------------
function Get-MigrationConstant {
    <#
    .SYNOPSIS
        Retrieve a value from $MigrationConstants by dotted path.
    .PARAMETER Name
        Dotted path, e.g. 'USMT.ZipName', 'UI.StatusIcons.OK'.
    .OUTPUTS
        The value at that path, or $null if any segment is missing.
    .EXAMPLE
        Get-MigrationConstant 'USMT.ZipName'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $segments = $Name -split '\.'
    $cursor = $MigrationConstants
    foreach ($seg in $segments) {
        if ($null -eq $cursor) { return $null }
        if ($cursor -is [System.Collections.IDictionary]) {
            if (-not $cursor.Contains($seg)) { return $null }
            $cursor = $cursor[$seg]
        }
        else {
            return $null
        }
    }
    return $cursor
}

Export-ModuleMember -Function Get-MigrationConstant -Variable MigrationConstants
