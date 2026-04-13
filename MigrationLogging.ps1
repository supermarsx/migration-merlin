<#
.SYNOPSIS
    Shared logging, error handling, and retry infrastructure for migration-merlin.
.DESCRIPTION
    Dot-source this file from any migration script to get:
    - Robust Write-Log with fallback locations
    - Automatic transcript capture
    - Invoke-WithRetry for transient failure recovery
    - Invoke-SafeCommand for external exe calls with LASTEXITCODE checking
    - Safe-Exit that always logs why the script terminated
    - Try-CimInstance with fallback for WMI failures
#>

# ============================================================================
# LOG INITIALIZATION
# ============================================================================
function Initialize-Logging {
    <# Sets up logging with primary and fallback paths, starts transcript. #>
    param(
        [string]$PrimaryLogFile,
        [string]$ScriptName = "migration"
    )

    $script:_LogInitialized = $false
    $script:_LogFile = $null
    $script:_TranscriptStarted = $false
    $script:_ScriptName = $ScriptName

    # Try primary log path
    $primaryDir = Split-Path $PrimaryLogFile -Parent
    if (Initialize-LogPath $primaryDir) {
        $script:_LogFile = $PrimaryLogFile
    } else {
        # Fallback 1: TEMP folder
        $fallback1 = Join-Path $env:TEMP "MigrationMerlin"
        if (Initialize-LogPath $fallback1) {
            $script:_LogFile = Join-Path $fallback1 "$ScriptName.log"
        } else {
            # Fallback 2: User profile
            $fallback2 = Join-Path $env:USERPROFILE "MigrationMerlin-Logs"
            if (Initialize-LogPath $fallback2) {
                $script:_LogFile = Join-Path $fallback2 "$ScriptName.log"
            }
        }
    }

    if ($script:_LogFile) {
        $script:_LogInitialized = $true
        # Write session header
        $header = "=" * 60
        $sessionInfo = @(
            $header
            "Session started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "Script: $ScriptName"
            "Computer: $env:COMPUTERNAME"
            "User: $env:USERDOMAIN\$env:USERNAME"
            "PID: $PID"
            "PowerShell: $($PSVersionTable.PSVersion)"
            $header
        )
        $sessionInfo | Out-File -Append -FilePath $script:_LogFile -Encoding UTF8 -ErrorAction SilentlyContinue
    }

    # Start transcript alongside the log file
    try {
        $transcriptDir = if ($script:_LogFile) { Split-Path $script:_LogFile -Parent } else { $env:TEMP }
        $transcriptPath = Join-Path $transcriptDir "$ScriptName-transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        Start-Transcript -Path $transcriptPath -Append -ErrorAction SilentlyContinue | Out-Null
        $script:_TranscriptStarted = $true
    } catch {
        # Transcript is best-effort - don't fail if it can't start
    }

    return $script:_LogFile
}

function Initialize-LogPath {
    param([string]$Path)
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        # Verify writable
        $testFile = Join-Path $Path ".log-write-test"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Stop-Logging {
    if ($script:_TranscriptStarted) {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}

# ============================================================================
# WRITE-LOG (robust, with fallback)
# ============================================================================
function Write-Log {
    <# Writes a timestamped entry to the log file. Handles its own errors. #>
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","FATAL","DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $entry = "[$timestamp] [$Level] $Message"

    # Try primary log
    if ($script:_LogFile) {
        try {
            $entry | Out-File -Append -FilePath $script:_LogFile -Encoding UTF8 -ErrorAction Stop
            return
        } catch {
            # Primary log failed - try fallback
            $fallbackLog = Join-Path $env:TEMP "migration-fallback.log"
            try {
                $entry | Out-File -Append -FilePath $fallbackLog -Encoding UTF8 -ErrorAction Stop
                # Also log that primary failed
                "[$timestamp] [WARN] Primary log write failed ($($script:_LogFile)): $_" |
                    Out-File -Append -FilePath $fallbackLog -Encoding UTF8 -ErrorAction SilentlyContinue
            } catch {
                # Both failed - write to event log as last resort
                try {
                    Write-EventLog -LogName Application -Source "Migration Merlin" `
                        -EventId 1000 -EntryType Warning -Message $entry -ErrorAction SilentlyContinue
                } catch {}
            }
        }
    }

    # If no log file at all, use the LogFile variable from the calling script
    if ($LogFile) {
        try {
            $logDir = Split-Path $LogFile -Parent
            if (-not (Test-Path $logDir)) { New-Item $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
            $entry | Out-File -Append -FilePath $LogFile -Encoding UTF8 -ErrorAction Stop
        } catch {}
    }
}

# ============================================================================
# SAFE-EXIT (always logs the reason)
# ============================================================================
function Safe-Exit {
    <# Logs the exit reason, stops transcript, then exits with the given code. #>
    param(
        [int]$Code = 1,
        [string]$Reason = "Unspecified exit",
        [string]$Level = "ERROR"
    )
    Write-Log "EXIT ($Code): $Reason" $Level
    Show-Status $Reason "FAIL"
    Stop-Logging
    exit $Code
}

# ============================================================================
# INVOKE-WITHRETRY
# ============================================================================
function Invoke-WithRetry {
    <# Retries a scriptblock up to N times with exponential backoff. #>
    param(
        [scriptblock]$ScriptBlock,
        [string]$OperationName = "operation",
        [int]$MaxRetries = 3,
        [int]$InitialDelaySeconds = 2,
        [switch]$LogOnly  # Don't show status, just log
    )

    $attempt = 0
    $delay = $InitialDelaySeconds
    $lastError = $null

    while ($attempt -lt $MaxRetries) {
        $attempt++
        try {
            $result = & $ScriptBlock
            if ($attempt -gt 1) {
                $msg = "$OperationName succeeded on attempt $attempt"
                Write-Log $msg
                if (-not $LogOnly) { Show-Status $msg "OK" }
            }
            return $result
        } catch {
            $lastError = $_
            Write-Log "$OperationName failed (attempt $attempt/$MaxRetries): $_" "WARN"
            if (-not $LogOnly) {
                Show-Status "$OperationName failed (attempt $attempt/$MaxRetries), retrying in ${delay}s..." "WARN"
            }
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds $delay
                $delay = [math]::Min($delay * 2, 30)  # exponential backoff, cap at 30s
            }
        }
    }

    Write-Log "$OperationName failed after $MaxRetries attempts: $lastError" "ERROR"
    throw "Failed after $MaxRetries attempts: $lastError"
}

# ============================================================================
# INVOKE-SAFECOMMAND (external exe with LASTEXITCODE check)
# ============================================================================
function Invoke-SafeCommand {
    <# Runs an external command and checks LASTEXITCODE. Returns output. #>
    param(
        [string]$Command,
        [string[]]$Arguments = @(),
        [string]$OperationName = "",
        [int[]]$AcceptableExitCodes = @(0),
        [switch]$SuppressStderr
    )

    if (-not $OperationName) { $OperationName = $Command }

    Write-Log "Running: $Command $($Arguments -join ' ')" "DEBUG"

    try {
        if ($SuppressStderr) {
            $output = & $Command @Arguments 2>$null
        } else {
            $output = & $Command @Arguments 2>&1
        }
        $exitCode = $LASTEXITCODE

        if ($exitCode -notin $AcceptableExitCodes) {
            Write-Log "$OperationName exited with code $exitCode. Output: $($output -join ' ')" "WARN"
            return @{ Success = $false; ExitCode = $exitCode; Output = $output }
        }

        return @{ Success = $true; ExitCode = $exitCode; Output = $output }
    } catch {
        Write-Log "$OperationName threw exception: $_" "ERROR"
        return @{ Success = $false; ExitCode = -1; Output = $_.Exception.Message }
    }
}

# ============================================================================
# TRY-CIMINSTANCE (WMI with fallback)
# ============================================================================
function Try-CimInstance {
    <# Gets a CIM instance with error handling and fallback to Get-WmiObject. #>
    param(
        [string]$ClassName,
        [string]$Filter = "",
        [string]$FriendlyName = ""
    )

    if (-not $FriendlyName) { $FriendlyName = $ClassName }

    # Try CIM first
    try {
        $params = @{ ClassName = $ClassName; ErrorAction = "Stop" }
        if ($Filter) { $params.Filter = $Filter }
        $result = Get-CimInstance @params
        return $result
    } catch {
        Write-Log "Get-CimInstance $ClassName failed: $_. Trying Get-WmiObject fallback..." "WARN"
    }

    # Fallback to WMI
    try {
        $params = @{ Class = $ClassName; ErrorAction = "Stop" }
        if ($Filter) { $params.Filter = $Filter }
        $result = Get-WmiObject @params
        Write-Log "Get-WmiObject $ClassName fallback succeeded" "INFO"
        return $result
    } catch {
        Write-Log "Both CIM and WMI failed for $FriendlyName : $_" "ERROR"
        Show-Status "Failed to query $FriendlyName : $_" "FAIL"
        return $null
    }
}

# ============================================================================
# SAFE FILE OPERATIONS
# ============================================================================
function Copy-ItemSafe {
    <# Copies with retry and logging. Returns $true on success. #>
    param(
        [string]$Source,
        [string]$Destination,
        [switch]$Recurse,
        [int]$MaxRetries = 3,
        [string]$Description = ""
    )

    if (-not $Description) { $Description = "Copy $(Split-Path $Source -Leaf)" }

    try {
        Invoke-WithRetry -OperationName $Description -MaxRetries $MaxRetries -LogOnly -ScriptBlock {
            $copyParams = @{
                Path        = $Source
                Destination = $Destination
                Force       = $true
                ErrorAction = "Stop"
            }
            if ($Recurse) { $copyParams.Recurse = $true }
            Copy-Item @copyParams
        }
        return $true
    } catch {
        Write-Log "Copy failed ($Description): $_" "ERROR"
        return $false
    }
}

function Test-WritablePath {
    <# Tests if a path is writable by creating and removing a temp file. #>
    param([string]$Path)
    try {
        $testFile = Join-Path $Path ".write-test-$(Get-Random)"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}
