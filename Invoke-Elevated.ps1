<#
.SYNOPSIS
    Auto-elevation helper. Re-launches the current script as Administrator if not already elevated.
.DESCRIPTION
    Call this at the top of any script BEFORE param() processing.
    If not elevated, it re-launches the same script via RunAs with all original arguments preserved,
    marshalling $PSBoundParameters across the UAC boundary.

    SECURE PARAMETER HAND-OFF (SecureString / PSCredential)
    -------------------------------------------------------
    SecureString and PSCredential values are NEVER placed on the child process command line.
    Instead, they are DPAPI-encrypted (per-user, per-machine by default via ConvertFrom-SecureString)
    and placed into environment variables with these conventions:

        MIGRATION_MERLIN_SECURE_<PARAMNAME>           (encrypted SecureString blob)
        MIGRATION_MERLIN_CRED_USER_<PARAMNAME>        (PSCredential.UserName, plain)
        MIGRATION_MERLIN_CRED_PASS_<PARAMNAME>        (PSCredential.Password as DPAPI blob)

    The child script is informed with a marker switch (`-<ParamName>FromEnv`) so it knows to read
    the env var and reconstruct the value via `ConvertTo-SecureString` (and `New-Object PSCredential`
    for credentials). Executors e6, e7, e8, e12 wire the child-side decryption in their scripts.

    Because DPAPI is scoped to the current user, the encrypted blob is only decryptable by the same
    user principal that gets elevated - i.e. the elevated child inherits the same user token, just
    with the administrator role active. This is safe across UAC, but NOT across user boundaries
    (RunAs /user:OtherUser would break decryption - a feature, not a bug).

.EXAMPLE
    # At the very top of your script (before param):
    . "$PSScriptRoot\Invoke-Elevated.ps1"
    Request-Elevation -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

.EXAMPLE
    # Legacy callers still work:
    . "$PSScriptRoot\Invoke-Elevated.ps1"
    Request-Elevation
#>

function Exit-Elevation {
    <#
    .SYNOPSIS
        Thin wrapper around `exit` so Request-Elevation can be unit-tested.
        Mock this function to suppress process termination in tests.
    #>
    [CmdletBinding()]
    param([int]$ExitCode = 0)
    exit $ExitCode
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-ElevationArgumentString {
    <#
    .SYNOPSIS
        Pure function: converts a hashtable of bound parameters into a PowerShell-safe argument string.
    .DESCRIPTION
        SecureString / PSCredential values are side-effected into environment variables and represented
        on the command line as `-<Name>FromEnv` marker switches.

        Return value is a single string suitable for concatenation into a `-File "script.ps1" ...` line.
    .PARAMETER BoundParameters
        The hashtable from $PSBoundParameters.
    .PARAMETER EnvVarPrefix
        Prefix for env vars holding SecureString/PSCredential values. Defaults to `MIGRATION_MERLIN_`.
    .PARAMETER EnvScope
        One of 'Process', 'User', 'Machine'. Defaults to 'Process' - inherited by child via Start-Process.
    .OUTPUTS
        [string] argument string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$BoundParameters,

        [string]$EnvVarPrefix = 'MIGRATION_MERLIN_',

        [ValidateSet('Process','User','Machine')]
        [string]$EnvScope = 'Process'
    )

    $parts = New-Object System.Collections.Generic.List[string]

    foreach ($name in $BoundParameters.Keys) {
        $value = $BoundParameters[$name]

        if ($null -eq $value) { continue }

        # --- SwitchParameter ---
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $parts.Add("-$name") | Out-Null
            }
            continue
        }

        # --- SecureString ---
        if ($value -is [System.Security.SecureString]) {
            $envName = "${EnvVarPrefix}SECURE_$($name.ToUpperInvariant())"
            try {
                $encrypted = ConvertFrom-SecureString -SecureString $value
                [System.Environment]::SetEnvironmentVariable($envName, $encrypted, $EnvScope)
                $parts.Add("-${name}FromEnv") | Out-Null
            } catch {
                Write-Warning "Failed to marshal SecureString parameter '$name': $_"
            }
            continue
        }

        # --- PSCredential ---
        if ($value -is [System.Management.Automation.PSCredential]) {
            $userEnv = "${EnvVarPrefix}CRED_USER_$($name.ToUpperInvariant())"
            $passEnv = "${EnvVarPrefix}CRED_PASS_$($name.ToUpperInvariant())"
            try {
                [System.Environment]::SetEnvironmentVariable($userEnv, $value.UserName, $EnvScope)
                $encrypted = ConvertFrom-SecureString -SecureString $value.Password
                [System.Environment]::SetEnvironmentVariable($passEnv, $encrypted, $EnvScope)
                $parts.Add("-${name}FromEnv") | Out-Null
            } catch {
                Write-Warning "Failed to marshal PSCredential parameter '$name': $_"
            }
            continue
        }

        # --- Arrays / IEnumerable of strings ---
        if ($value -is [array] -or ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])) {
            $items = @()
            foreach ($item in $value) {
                if ($null -eq $item) { continue }
                if ($item -is [bool] -or $item -is [int] -or $item -is [long] -or $item -is [double] -or $item -is [decimal]) {
                    $items += "$item"
                } else {
                    $escaped = ($item.ToString()) -replace '"','`"'
                    $items += '"' + $escaped + '"'
                }
            }
            if ($items.Count -gt 0) {
                $parts.Add("-$name $($items -join ',')") | Out-Null
            }
            continue
        }

        # --- Numeric / Bool ---
        if ($value -is [bool]) {
            $parts.Add("-$name `$$($value.ToString().ToLowerInvariant())") | Out-Null
            continue
        }
        if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal] -or $value -is [uint32] -or $value -is [uint64]) {
            $parts.Add("-$name $value") | Out-Null
            continue
        }

        # --- String / fallback: ToString with quote escape ---
        $escaped = ($value.ToString()) -replace '"','`"'
        $parts.Add('-' + $name + ' "' + $escaped + '"') | Out-Null
    }

    return ($parts -join ' ')
}

function Request-Elevation {
    <#
    .SYNOPSIS
        If not running as admin, re-launches the calling script elevated.
    .PARAMETER ScriptPath
        Path to the script to elevate. Defaults to the calling script.
    .PARAMETER Arguments
        LEGACY: pre-built argument string to pass through. Prefer -BoundParameters.
    .PARAMETER BoundParameters
        Hashtable (normally $PSBoundParameters) to marshal across the UAC boundary.
    .PARAMETER NoExit
        Keep the elevated window open after completion.
    .PARAMETER Silent
        Don't show any prompts, just elevate silently.
    .PARAMETER EnvVarPrefix
        Prefix for secure env var hand-off. Defaults to `MIGRATION_MERLIN_`.
    #>
    [CmdletBinding()]
    param(
        [string]$ScriptPath = "",
        [string]$Arguments = "",
        [hashtable]$BoundParameters,
        [switch]$NoExit,
        [switch]$Silent,
        [string]$EnvVarPrefix = 'MIGRATION_MERLIN_'
    )

    if (Test-IsAdmin) { return }

    # Resolve the calling script path
    if (-not $ScriptPath) {
        # Try the dot-source caller via PSCallStack (most reliable across import patterns)
        $callers = Get-PSCallStack
        for ($i = 1; $i -lt $callers.Count; $i++) {
            if ($callers[$i].ScriptName -and (Test-Path $callers[$i].ScriptName)) {
                $ScriptPath = $callers[$i].ScriptName
                break
            }
        }
    }
    if (-not $ScriptPath) {
        $ScriptPath = $MyInvocation.PSCommandPath
    }
    if (-not $ScriptPath -and $MyInvocation.ScriptName) {
        $ScriptPath = $MyInvocation.ScriptName
    }
    if (-not $ScriptPath -and $PSCommandPath) {
        $ScriptPath = $PSCommandPath
    }

    if (-not $ScriptPath) {
        Write-Host "ERROR: Cannot determine script path for elevation." -ForegroundColor Red
        Write-Host "Run this script from a .ps1 file, or use 'Run as Administrator'." -ForegroundColor Yellow
        if (-not $Silent) { pause }
        Exit-Elevation -ExitCode 1
        return
    }

    if (-not $Silent) {
        Write-Host ""
        Write-Host "  This script requires Administrator privileges." -ForegroundColor Yellow
        Write-Host "  Requesting elevation..." -ForegroundColor Cyan
        Write-Host ""
    }

    # Marshal parameters
    $marshalled = ""
    if ($BoundParameters -and $BoundParameters.Count -gt 0) {
        $marshalled = ConvertTo-ElevationArgumentString -BoundParameters $BoundParameters -EnvVarPrefix $EnvVarPrefix -EnvScope 'Process'
    }

    # Build the PowerShell command line
    $psExe = (Get-Process -Id $PID).Path
    $noExitFlag = if ($NoExit) { "-NoExit " } else { "" }
    $cmd = "-ExecutionPolicy Bypass ${noExitFlag}-File `"$ScriptPath`""
    if ($marshalled) {
        $cmd += " $marshalled"
    }
    if ($Arguments) {
        $cmd += " $Arguments"
    }

    $exitCode = 1
    try {
        $proc = Start-Process -FilePath $psExe -ArgumentList $cmd -Verb RunAs -Wait -PassThru
        if ($proc) { $exitCode = $proc.ExitCode }
    } catch {
        Write-Host ""
        Write-Host "  Elevation was cancelled or failed." -ForegroundColor Red
        Write-Host "  Right-click the script and select 'Run as Administrator'." -ForegroundColor Yellow
        Write-Host ""
        if (-not $Silent) { pause }
        Exit-Elevation -ExitCode 1
        return
    }

    Exit-Elevation -ExitCode $exitCode
}

try {
    Export-ModuleMember -Function Test-IsAdmin, Request-Elevation, ConvertTo-ElevationArgumentString, Exit-Elevation -ErrorAction Stop
} catch {
    # Ignored: file is dot-sourced, not imported as a module.
}
