<#
.SYNOPSIS
    Auto-elevation helper. Re-launches the current script as Administrator if not already elevated.
.DESCRIPTION
    Call this at the top of any script BEFORE param() processing.
    If not elevated, it re-launches the same script via RunAs with all original arguments preserved.
    Supports both interactive (pause on exit) and silent modes.
.EXAMPLE
    # At the very top of your script (before param):
    . "$PSScriptRoot\Invoke-Elevated.ps1"
    Request-Elevation
#>

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    <#
    .SYNOPSIS
        If not running as admin, re-launches the calling script elevated.
    .PARAMETER ScriptPath
        Path to the script to elevate. Defaults to the calling script.
    .PARAMETER Arguments
        Arguments to pass through. Defaults to the original invocation args.
    .PARAMETER NoExit
        Keep the elevated window open after completion.
    .PARAMETER Silent
        Don't show any prompts, just elevate silently.
    #>
    param(
        [string]$ScriptPath = "",
        [string]$Arguments = "",
        [switch]$NoExit,
        [switch]$Silent
    )

    if (Test-IsAdmin) { return }

    # Resolve the calling script
    if (-not $ScriptPath) {
        $ScriptPath = $MyInvocation.PSCommandPath
        if (-not $ScriptPath) {
            $ScriptPath = $MyInvocation.ScriptName
        }
        if (-not $ScriptPath -and $PSCommandPath) {
            $ScriptPath = $PSCommandPath
        }
    }

    if (-not $ScriptPath) {
        Write-Host "ERROR: Cannot determine script path for elevation." -ForegroundColor Red
        Write-Host "Run this script from a .ps1 file, or use 'Run as Administrator'." -ForegroundColor Yellow
        pause
        exit 1
    }

    if (-not $Silent) {
        Write-Host ""
        Write-Host "  This script requires Administrator privileges." -ForegroundColor Yellow
        Write-Host "  Requesting elevation..." -ForegroundColor Cyan
        Write-Host ""
    }

    # Build the PowerShell command
    $psExe = (Get-Process -Id $PID).Path
    $noExitFlag = if ($NoExit) { "-NoExit" } else { "" }
    $cmd = "-ExecutionPolicy Bypass $noExitFlag -File `"$ScriptPath`""
    if ($Arguments) {
        $cmd += " $Arguments"
    }

    try {
        Start-Process -FilePath $psExe -ArgumentList $cmd -Verb RunAs -Wait
    } catch {
        Write-Host ""
        Write-Host "  Elevation was cancelled or failed." -ForegroundColor Red
        Write-Host "  Right-click the script and select 'Run as Administrator'." -ForegroundColor Yellow
        Write-Host ""
        pause
    }

    exit
}

Export-ModuleMember -Function Test-IsAdmin, Request-Elevation -ErrorAction SilentlyContinue
