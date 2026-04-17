<#
.SYNOPSIS
    Shared error-handling primitives for MigrationMerlin.

.DESCRIPTION
    Introduced in Phase 3 (t1-e12). Sister module to MigrationValidators.psm1.
    Provides two small helpers used by the main scripts and modules:
        * Invoke-WithErrorContext  — wrap a scriptblock with uniform logging
        * Assert-NotNull           — throw an ArgumentNullException with
                                     consistent phrasing

    Neither helper mutates global state. Write-Log, if present in the caller's
    scope, is used for logging; otherwise a red Write-Host line is emitted so
    the helpers can be used from modules that haven't loaded MigrationLogging.
#>

function Invoke-WithErrorContext {
    <#
    .SYNOPSIS
        Executes a scriptblock, logging any exception with a caller-supplied
        context string.
    .PARAMETER ScriptBlock
        The code to run.
    .PARAMETER Context
        Short phrase describing what is being attempted (used in the error
        message and log entry).
    .PARAMETER Severity
        Log severity level for Write-Log. Defaults to 'ERROR'.
    .PARAMETER Rethrow
        When set, the original exception is re-thrown after logging. Without
        this switch the exception is swallowed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [string]$Context,

        [string]$Severity = 'ERROR',

        [switch]$Rethrow
    )
    try {
        & $ScriptBlock
    }
    catch {
        $msg = "$Context failed: $($_.Exception.Message)"
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log $msg $Severity
            Write-Log "StackTrace: $($_.ScriptStackTrace)" 'DEBUG'
        }
        else {
            Write-Host $msg -ForegroundColor Red
        }
        if ($Rethrow) { throw }
    }
}

function Assert-NotNull {
    <#
    .SYNOPSIS
        Throws [ArgumentNullException] if Value is $null or, for strings,
        null/empty/whitespace.
    .PARAMETER Value
        The value to check.
    .PARAMETER Name
        Parameter / variable name (used as the ArgumentNullException ParamName).
    .PARAMETER Context
        Optional prefix for the error message (e.g. caller function name).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Context
    )

    $isEmpty = $false
    if ($null -eq $Value) {
        $isEmpty = $true
    }
    elseif ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        $isEmpty = $true
    }

    if ($isEmpty) {
        $msg = "Required value '$Name' is null or empty"
        if ($Context) { $msg = "$Context : $msg" }
        throw [System.ArgumentNullException]::new($Name, $msg)
    }
}

Export-ModuleMember -Function Invoke-WithErrorContext, Assert-NotNull
