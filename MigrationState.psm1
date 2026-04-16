<#
.SYNOPSIS
    Shared migration run state — replaces the $script: globals that previously
    lived in source-capture.ps1 and destination-setup.ps1.
.DESCRIPTION
    Consolidates six parallel $script: variables (USMTDir, MappedDrive,
    ShareConnected, TotalSteps, CurrentStep, StartTime) into a single hashtable
    that interoperates cleanly with MigrationUI.psm1's existing -State contract.
.NOTES
    Hashtable (not PS class) so Set-MigrationUIState can consume it directly.
    Keys match what MigrationUI.psm1 already expects.
#>

function New-MigrationState {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [int]$TotalSteps = 7,
        [int]$CurrentStep = 0,
        [datetime]$StartTime = (Get-Date),
        [string]$USMTDir = $null,
        [string]$MappedDrive = $null,
        [bool]$ShareConnected = $false
    )
    return [ordered]@{
        TotalSteps     = $TotalSteps
        CurrentStep    = $CurrentStep
        StartTime      = $StartTime
        USMTDir        = $USMTDir
        MappedDrive    = $MappedDrive
        ShareConnected = $ShareConnected
    }
}

function Step-MigrationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [int]$By = 1
    )
    $State.CurrentStep = [Math]::Min($State.CurrentStep + $By, $State.TotalSteps)
    return $State
}

function Get-MigrationStateProgress {
    [OutputType([double])]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    if ($State.TotalSteps -le 0) { return 0.0 }
    return [Math]::Round(($State.CurrentStep / $State.TotalSteps) * 100, 2)
}

function Get-MigrationStateElapsed {
    [OutputType([timespan])]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    return (Get-Date) - $State.StartTime
}

Export-ModuleMember -Function New-MigrationState, Step-MigrationState, Get-MigrationStateProgress, Get-MigrationStateElapsed
