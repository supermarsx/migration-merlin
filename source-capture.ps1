<#
.SYNOPSIS
    Source PC Capture - Captures user state via USMT and writes it to the destination share.

.DESCRIPTION
    Run this script on the SOURCE (old) PC AFTER the destination PC share is ready
    (see destination-setup.ps1). It auto-downloads and installs USMT if needed,
    validates SMB connectivity to the destination, enumerates user profiles,
    captures them via scanstate.exe with rich progress output, and writes the
    resulting store to the destination share. Optionally encrypts the store with
    AES-256 and can be driven non-interactively for scripted deployments.
    Auto-elevates to Administrator via UAC if not already running elevated.

.PARAMETER DestinationShare
    UNC path to the migration share on the destination PC (for example
    \\NewPC\MigrationShare$). Validation accepts an empty string (prompted
    interactively) or a well-formed UNC path.

.PARAMETER USMTPath
    Optional path to an existing USMT install directory. When supplied it must
    contain scanstate.exe; otherwise the script auto-installs USMT.

.PARAMETER ShareUsername
    Username used to authenticate to the destination share when the current
    user lacks access. Supply together with -SharePassword.

.PARAMETER SharePassword
    SecureString password paired with -ShareUsername. Converted to plaintext
    just-in-time for `net use` and cleared immediately after. Never stored on
    disk. Use Read-Host -AsSecureString to supply interactively.

.PARAMETER IncludeUsers
    Array of profile names to capture. When empty, all non-system profiles are
    captured. Names are validated against characters that are illegal in
    Windows account names.

.PARAMETER ExcludeUsers
    Array of profile names to skip. Validated the same way as -IncludeUsers.

.PARAMETER ExtraData
    Switch. When set, includes additional non-profile data locations defined
    in custom-migration.xml.

.PARAMETER SkipConnectivityCheck
    Switch. Skips the SMB reachability pre-flight to the destination share.

.PARAMETER SkipUSMTInstall
    Switch. Skips the automatic USMT download/install step. Requires -USMTPath
    to point at an existing install.

.PARAMETER DryRun
    Switch. Performs all validation and prints the scanstate.exe command line
    without executing the capture.

.PARAMETER EncryptStore
    Switch. Enables AES-256 encryption of the store. Requires -EncryptionKey.

.PARAMETER EncryptionKey
    SecureString encryption key (minimum 8 characters). Validated for length
    without exposing the plaintext in parameter metadata.

.PARAMETER NonInteractive
    Alias: -Silent. Suppresses prompts; causes the script to fail fast when
    any required value is missing.

.PARAMETER SharePasswordFromEnv
    Marker switch. Set automatically by Request-Elevation when a SecureString
    password must be marshalled across the UAC boundary via a DPAPI-encrypted
    environment variable. Users should not pass this manually.

.PARAMETER EncryptionKeyFromEnv
    Marker switch. Set automatically by Request-Elevation when a SecureString
    encryption key must be marshalled across the UAC boundary via a
    DPAPI-encrypted environment variable. Users should not pass this manually.

.EXAMPLE
    PS> .\source-capture.ps1 -DestinationShare \\NewPC\MigrationShare$

    Captures all user profiles and writes the store to the destination share,
    auto-installing USMT if needed.

.EXAMPLE
    PS> .\source-capture.ps1 -DestinationShare \\NewPC\MigrationShare$ `
        -IncludeUsers 'alice','bob' -ExcludeUsers 'tempuser'

    Captures only the specified profiles, skipping 'tempuser'.

.EXAMPLE
    PS> $key = Read-Host -AsSecureString 'Encryption key'
    PS> .\source-capture.ps1 -DestinationShare \\NewPC\MigrationShare$ `
        -EncryptStore -EncryptionKey $key -NonInteractive

    Runs unattended with an AES-256 encrypted store.

.INPUTS
    None. This script does not accept piped input.

.OUTPUTS
    None. Exit code 0 indicates success; non-zero indicates failure. A capture
    log is written under the migration folder's Logs subdirectory.

.NOTES
    - Requires Administrator privileges (auto-elevates via UAC).
    - Destination share must already exist (run destination-setup.ps1 first).
    - SecureString parameters are cleared from memory as soon as they are
      consumed.

.LINK
    https://github.com/supermarsx/migration-merlin

.LINK
    .\destination-setup.ps1

.LINK
    .\post-migration-verify.ps1
#>

# ============================================================================
# PARAMETER BLOCK (with validation attributes added in Phase 3 / t1-e12)
# ----------------------------------------------------------------------------
# ValidateScript attributes use inline regex / Test-Path checks rather than
# calling MigrationValidators.psm1 functions directly — the param binder
# evaluates these attributes before the script body runs (where Import-Module
# lives), so referencing module functions here would fail with
# "The term 'Test-UncPath' is not recognized" when the script is invoked
# stand-alone. The shared Test-* helpers are unit-tested in their own module
# suite; the inline checks here mirror their logic for the narrow cases the
# param-binder needs.
# ============================================================================
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({
        [string]::IsNullOrEmpty($_) -or
        ($_ -match '^\\\\[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+(\\.*)?$')
    })]
    [string]$DestinationShare = "",

    [ValidateScript({
        [string]::IsNullOrEmpty($_) -or
        ((Test-Path -LiteralPath $_ -PathType Container) -and
         (Test-Path -LiteralPath (Join-Path $_ 'scanstate.exe') -PathType Leaf))
    })]
    [string]$USMTPath = "",

    [string]$ShareUsername = "",
    # Converted to [SecureString] in t1-e12 so the credential never lives as
    # a plaintext string in the param binder. Use ConvertFrom-SecureStringPlain
    # (defined below) at the point of use to obtain the temporary plaintext
    # required by `net use`.
    [securestring]$SharePassword,

    [ValidateScript({
        foreach ($u in $_) {
            if ([string]::IsNullOrWhiteSpace($u) -or $u -match '[\\/\[\]:;\|=,\+\*\?<>]') {
                throw "Invalid profile name: '$u'"
            }
        }
        $true
    })]
    [string[]]$IncludeUsers = @(),

    [ValidateScript({
        foreach ($u in $_) {
            if ([string]::IsNullOrWhiteSpace($u) -or $u -match '[\\/\[\]:;\|=,\+\*\?<>]') {
                throw "Invalid profile name: '$u'"
            }
        }
        $true
    })]
    [string[]]$ExcludeUsers = @(),

    [switch]$ExtraData,
    [switch]$SkipConnectivityCheck,
    [switch]$SkipUSMTInstall,
    [switch]$DryRun,
    [switch]$EncryptStore,
    # SecureString in t1-e12. Length floor enforced by inline check mirroring
    # Test-EncryptionKeyStrength (8 char minimum).
    [ValidateScript({
        $null -eq $_ -or
        ([System.Net.NetworkCredential]::new('', $_).Password.Length -ge 8)
    })]
    [securestring]$EncryptionKey,
    [Alias("Silent")]
    [switch]$NonInteractive,

    # Marker switches: present when Request-Elevation marshalled a SecureString
    # value via the MIGRATION_MERLIN_SECURE_* env-var mechanism. With the
    # t1-e12 SecureString conversion these are now fully functional — the env
    # var is read below and rehydrated into the SecureString parameter.
    [switch]$SharePasswordFromEnv,
    [switch]$EncryptionKeyFromEnv
)

$ErrorActionPreference = "Stop"

# ============================================================================
# MODULE IMPORTS (Phase p2 — t1-e6; MigrationValidators + ErrorHandling added
# in Phase 3 — t1-e12)
# ============================================================================
Import-Module "$PSScriptRoot\MigrationConstants.psm1" -Force
Import-Module "$PSScriptRoot\MigrationUI.psm1" -Force
Import-Module "$PSScriptRoot\USMTTools.psm1" -Force
Import-Module "$PSScriptRoot\MigrationState.psm1" -Force
Import-Module "$PSScriptRoot\MigrationValidators.psm1" -Force
Import-Module "$PSScriptRoot\ErrorHandling.psm1" -Force
. "$PSScriptRoot\Invoke-Elevated.ps1"
. "$PSScriptRoot\MigrationLogging.ps1"

# ============================================================================
# SECURESTRING HELPER (Phase 3 — t1-e12)
# ----------------------------------------------------------------------------
# Just-in-time conversion from [SecureString] to plaintext. Callers are
# expected to clear the returned variable (set to $null) as soon as the
# plaintext has been consumed.
# ============================================================================
function ConvertFrom-SecureStringPlain {
    [OutputType([string])]
    param([Parameter(Mandatory)][securestring]$Secure)
    return [System.Net.NetworkCredential]::new('', $Secure).Password
}

# ============================================================================
# SECURE ENV-VAR PICKUP (DPAPI hand-off from Request-Elevation)
# ----------------------------------------------------------------------------
# Phase 3 / t1-e12: SharePassword and EncryptionKey are now [SecureString]
# params, so the DPAPI hand-off stays in SecureString form end-to-end. The
# plaintext conversion is deferred until the exact call site that needs it
# (net use, scanstate /key:), via ConvertFrom-SecureStringPlain.
# ============================================================================
if ($env:MIGRATION_MERLIN_SECURE_SHAREPASSWORD -and -not $SharePassword) {
    try {
        $SharePassword = $env:MIGRATION_MERLIN_SECURE_SHAREPASSWORD | ConvertTo-SecureString
    } catch {
        Write-Warning "Failed to decrypt MIGRATION_MERLIN_SECURE_SHAREPASSWORD: $_"
    } finally {
        Remove-Item env:MIGRATION_MERLIN_SECURE_SHAREPASSWORD -Force -ErrorAction SilentlyContinue
    }
}
if ($env:MIGRATION_MERLIN_SECURE_ENCRYPTIONKEY -and -not $EncryptionKey) {
    try {
        $EncryptionKey = $env:MIGRATION_MERLIN_SECURE_ENCRYPTIONKEY | ConvertTo-SecureString
    } catch {
        Write-Warning "Failed to decrypt MIGRATION_MERLIN_SECURE_ENCRYPTIONKEY: $_"
    } finally {
        Remove-Item env:MIGRATION_MERLIN_SECURE_ENCRYPTIONKEY -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# AUTO-ELEVATION
# ============================================================================
Request-Elevation -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# ============================================================================
# CONFIGURATION
# ============================================================================
$LocalLogFolder = $MigrationConstants.Logging.DefaultLogFolder
# Consolidated migration run state (t1-e11): replaces the six parallel
# $script: globals (USMTDir, MappedDrive, ShareConnected, TotalSteps,
# CurrentStep, StartTime) with a single hashtable wrapper.
$script:State = New-MigrationState -TotalSteps $MigrationConstants.UI.SourceTotalSteps

# Initialize the MigrationUI module's internal state so Show-Step picks up the
# right totals even when callers don't pass -State explicitly.
Set-MigrationUIState -State $script:State

# Load shared logging infrastructure (already dot-sourced above via module
# import section; Initialize-Logging is defined in MigrationLogging.ps1).
$LogFile = Initialize-Logging -PrimaryLogFile (Join-Path $LocalLogFolder "source-capture.log") -ScriptName "source-capture"
Write-Log "Script started with parameters: $(Format-SafeParams $PSBoundParameters)"

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================
function Test-Prerequisites {
    Show-Step "Checking source PC prerequisites"

    # Admin check
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Safe-Exit -Code 1 -Reason "Script must be run as Administrator"
    }
    Show-Status "Running as Administrator" "OK"

    # OS info
    $os = Try-CimInstance -ClassName "Win32_OperatingSystem" -FriendlyName "Operating System"
    if ($os) {
        Show-Status "OS: $($os.Caption) (Build $($os.BuildNumber))" "OK"
        Write-Log "Source OS: $($os.Caption) Build $($os.BuildNumber)"
    } else {
        Show-Status "Could not determine OS version" "WARN"
    }

    # User profiles
    $profiles = Try-CimInstance -ClassName "Win32_UserProfile" -FriendlyName "User Profiles"
    if (-not $profiles) { Safe-Exit -Code 1 -Reason "Cannot enumerate user profiles (WMI failure)" }
    $profiles = $profiles |
        Where-Object { -not $_.Special -and $_.LocalPath -notlike "*systemprofile*" }
    $realProfiles = $profiles | Where-Object {
        $name = Split-Path $_.LocalPath -Leaf
        $name -notin @("Public", "Default", "Default User", "All Users")
    }
    Show-Status "Found $($realProfiles.Count) user profile(s) on system" "OK"

    # Filter to only included/excluded users (match Get-MigrationProfiles logic)
    $filteredProfiles = @()
    foreach ($p in $realProfiles) {
        $username = Split-Path $p.LocalPath -Leaf
        if ($IncludeUsers.Count -gt 0 -and $username -notin $IncludeUsers) { continue }
        if ($username -in $ExcludeUsers) { continue }
        $filteredProfiles += $p
    }

    if ($filteredProfiles.Count -ne $realProfiles.Count) {
        Show-Status "Selected $($filteredProfiles.Count) of $($realProfiles.Count) profiles for migration" "INFO"
    }

    # Profile size estimation with progress (only selected users)
    $totalProfileSize = 0
    $i = 0
    foreach ($p in $filteredProfiles) {
        $i++
        $username = Split-Path $p.LocalPath -Leaf
        Show-SubProgress "Sizing $username..." $i $filteredProfiles.Count
        if (Test-Path $p.LocalPath) {
            try {
                $size = (Get-ChildItem -Path $p.LocalPath -Recurse -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                $totalProfileSize += $size
                $sizeGB = [math]::Round($size / 1GB, 2)
                $lastUsed = if ($p.LastUseTime) { $p.LastUseTime.ToString("yyyy-MM-dd") } else { "Unknown" }
            } catch {
                $sizeGB = "?"
                $lastUsed = "Unknown"
            }
        }
    }
    Write-Host ""
    $totalGB = [math]::Round($totalProfileSize / 1GB, 2)
    Show-Status "Total profile data to migrate: ~${totalGB} GB" "INFO"

    # List selected profiles
    foreach ($p in $filteredProfiles) {
        $username = Split-Path $p.LocalPath -Leaf
        $lastUsed = if ($p.LastUseTime) { $p.LastUseTime.ToString("yyyy-MM-dd") } else { "Unknown" }
        try {
            $sizeGB = [math]::Round((Get-ChildItem -Path $p.LocalPath -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum / 1GB, 2)
        } catch { $sizeGB = "?" }
        Show-Detail $username "${sizeGB} GB (last used: $lastUsed)"
    }

    # Show skipped profiles if any
    if ($filteredProfiles.Count -ne $realProfiles.Count) {
        $skipped = $realProfiles | Where-Object {
            $n = Split-Path $_.LocalPath -Leaf
            ($IncludeUsers.Count -gt 0 -and $n -notin $IncludeUsers) -or ($n -in $ExcludeUsers)
        }
        foreach ($p in $skipped) {
            $username = Split-Path $p.LocalPath -Leaf
            Show-Detail "$username (skipped)" "not selected"
        }
    }
    Write-Log "Profiles selected: $($filteredProfiles.Count)/$($realProfiles.Count), total size: ~${totalGB} GB"
}

# ============================================================================
# USMT DETECTION + AUTO-INSTALL (delegates to USMTTools.psm1)
# ============================================================================
function Initialize-USMT {
    Show-Step "Locating USMT tools"

    # First try: detection only (no install).
    $found = Find-USMT -ExeName $MigrationConstants.USMT.ScanStateExe -USMTPathOverride $USMTPath
    if ($found) {
        $script:State.USMTDir = $found
        $version = (Get-Item (Join-Path $script:State.USMTDir $MigrationConstants.USMT.ScanStateExe)).VersionInfo.FileVersion
        Show-Status "USMT found: $($script:State.USMTDir)" "OK"
        Show-Detail "Version" $version
        Write-Log "USMT found at $($script:State.USMTDir), version $version"
        return $true
    }

    if ($SkipUSMTInstall) {
        Show-Status "USMT not found and -SkipUSMTInstall specified" "FAIL"
        return $false
    }

    # Full install orchestration: Find -> Expand bundled -> ADK online.
    $installed = Install-USMT -ExeName $MigrationConstants.USMT.ScanStateExe -USMTPathOverride $USMTPath
    if (-not $installed) {
        Show-Status "USMT is required for migration. Options:" "FAIL"
        Show-Status "  1. Install Windows ADK manually with USMT" "INFO"
        Show-Status "  2. Copy USMT binaries to C:\USMT" "INFO"
        Show-Status "  3. Specify path with -USMTPath" "INFO"
        return $false
    }
    $script:State.USMTDir = $installed
    Show-Status "USMT ready at: $($script:State.USMTDir)" "OK"
    return $true
}

# ============================================================================
# NETWORK SHARE CONNECTION
# ============================================================================
function Connect-DestinationShare {
    Show-Step "Connecting to destination share"

    if (-not $DestinationShare) {
        if ($NonInteractive) {
            Safe-Exit -Code 1 -Reason "No -DestinationShare provided and running non-interactive"
        }
        Write-Host ""
        Write-Host "     Enter the destination share path" -ForegroundColor Yellow
        Write-Host "     (e.g., \\DEST-PC\$($MigrationConstants.Defaults.ShareName)):" -ForegroundColor Yellow
        $DestinationShare = Read-Host "     Share path"
        if (-not $DestinationShare) {
            Safe-Exit -Code 1 -Reason "No share path provided"
        }
    }

    Show-Status "Target: $DestinationShare" "INFO"

    # Connectivity tests
    if (-not $SkipConnectivityCheck) {
        $shareParts = $DestinationShare -replace '\\\\', '' -split '\\'
        $targetHost = $shareParts[0]

        # Ping
        Show-Status "Pinging $targetHost..." "WAIT"
        $ping = Test-Connection -ComputerName $targetHost -Count 2 -Quiet -ErrorAction SilentlyContinue
        if (-not $ping) {
            Safe-Exit -Code 1 -Reason "Cannot reach $targetHost - check network, firewall, and hostname/IP"
        }
        Show-Status "Ping OK" "OK"

        # SMB port
        Show-Status "Testing SMB port 445..." "WAIT"
        $portTest = Test-NetConnection -ComputerName $targetHost -Port 445 -WarningAction SilentlyContinue
        if (-not $portTest.TcpTestSucceeded) {
            Safe-Exit -Code 1 -Reason "SMB port 445 blocked on $targetHost - run destination-setup.ps1 on target PC first"
        }
        Show-Status "SMB port 445 open" "OK"
    }

    # Map drive
    $driveLetter = $null
    foreach ($letter in 'Z','Y','X','W','V','U') {
        if (-not (Test-Path "${letter}:\")) {
            $driveLetter = $letter
            break
        }
    }
    if (-not $driveLetter) {
        Safe-Exit -Code 1 -Reason "No available drive letters (Z through U all in use)"
    }

    Show-Status "Mapping to ${driveLetter}:\..." "WAIT"

    try {
        $netArgs = @("use", "${driveLetter}:", $DestinationShare)
        $plainPwd = $null
        if ($ShareUsername -and $SharePassword) {
            $plainPwd = ConvertFrom-SecureStringPlain -Secure $SharePassword
            $netArgs += "/user:$ShareUsername"
            $netArgs += $plainPwd
            Show-Status "Using provided credentials" "INFO"
        }
        $netArgs += "/persistent:no"

        try {
            $result = & net @netArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "net use failed: $result" }
        } finally {
            # Scrub plaintext password reference as soon as net.exe has consumed it.
            $plainPwd = $null
        }

        $script:State.MappedDrive = "${driveLetter}:"
        $script:State.ShareConnected = $true
        Show-Status "Mapped: $DestinationShare -> ${driveLetter}:\" "OK"
    } catch {
        Write-Log "Share connection failed: $_" "ERROR"
        Show-Status "Connection failed: $_" "FAIL"
        Show-Status "Try: -ShareUsername 'DOMAIN\user' -SharePassword 'pass'" "INFO"
        Safe-Exit -Code 1 -Reason "Failed to map share $DestinationShare : $_"
    }

    # Write test
    $testFile = Join-Path "${driveLetter}:\" ".write-test"
    try {
        "test" | Out-File $testFile -Force
        Remove-Item $testFile -Force
        Show-Status "Write access confirmed" "OK"
    } catch {
        Safe-Exit -Code 1 -Reason "Cannot write to share at ${driveLetter}:\ - check permissions"
    }

    # Check free space on destination
    try {
        $driveInfo = Get-PSDrive $driveLetter -ErrorAction SilentlyContinue
        if ($driveInfo -and $driveInfo.Free) {
            $freeGB = [math]::Round($driveInfo.Free / 1GB, 2)
            Show-Status "Destination free space: ${freeGB} GB" "OK"
        }
    } catch {
        Write-Log "Could not check destination free space: $_" "WARN"
    }

    Write-Log "Connected to $DestinationShare as ${driveLetter}:\"
}

# ============================================================================
# PROFILE SELECTION
# ============================================================================
function Get-MigrationProfiles {
    $allProfiles = Get-CimInstance Win32_UserProfile |
        Where-Object { -not $_.Special -and $_.LocalPath -notlike "*systemprofile*" }

    $selectedProfiles = @()
    foreach ($p in $allProfiles) {
        $username = Split-Path $p.LocalPath -Leaf
        if ($username -in @("Public", "Default", "Default User", "All Users")) { continue }
        if ($IncludeUsers.Count -gt 0 -and $username -notin $IncludeUsers) { continue }
        if ($username -in $ExcludeUsers) { continue }
        $selectedProfiles += $username
    }

    if ($selectedProfiles.Count -eq 0) {
        Safe-Exit -Code 1 -Reason "No user profiles selected for migration (check -IncludeUsers/-ExcludeUsers filters)"
    }

    return $selectedProfiles
}

# ============================================================================
# PRE-SCAN DATA COLLECTION
# ============================================================================
function Export-PreScanData {
    param([string]$OutputPath)

    Show-Step "Collecting system inventory"

    $preScanDir = Join-Path $OutputPath "PreScanData"
    if (-not (Test-Path $preScanDir)) {
        New-Item -Path $preScanDir -ItemType Directory -Force | Out-Null
    }

    $tasks = @(
        @{ Name = "Installed applications"; Action = {
            param($dir)
            $apps = @()
            $regPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            foreach ($rp in $regPaths) {
                $apps += Get-ItemProperty $rp -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName } |
                    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
            }
            $apps | Sort-Object DisplayName -Unique |
                Export-Csv (Join-Path $dir "InstalledApps.csv") -NoTypeInformation
            return "$($apps.Count) apps"
        }},
        @{ Name = "Printers"; Action = {
            param($dir)
            $p = Get-Printer -ErrorAction SilentlyContinue
            $p | Select-Object Name, DriverName, PortName, Shared, PrinterStatus |
                Export-Csv (Join-Path $dir "Printers.csv") -NoTypeInformation
            return "$($p.Count) printers"
        }},
        @{ Name = "Mapped network drives"; Action = {
            param($dir)
            $d = Get-PSDrive -PSProvider FileSystem |
                Where-Object { $_.DisplayRoot -like "\\*" } |
                Select-Object Name, DisplayRoot
            $d | Export-Csv (Join-Path $dir "MappedDrives.csv") -NoTypeInformation
            return "$($d.Count) drives"
        }},
        @{ Name = "Wi-Fi profiles"; Action = {
            param($dir)
            $wifi = netsh wlan show profiles 2>$null
            if ($wifi) {
                $wifi | Out-File (Join-Path $dir "WiFiProfiles.txt") -Encoding UTF8
                $names = ($wifi | Select-String "All User Profile\s+:\s+(.+)$").Matches |
                    ForEach-Object { $_.Groups[1].Value.Trim() }
                foreach ($n in $names) {
                    netsh wlan export profile name="$n" folder="$dir" key=clear 2>$null | Out-Null
                }
                return "$($names.Count) profiles"
            }
            return "No wireless"
        }},
        @{ Name = "Browser bookmarks scan"; Action = {
            param($dir)
            $info = @()
            $ups = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } |
                Select-Object -ExpandProperty LocalPath
            foreach ($pp in $ups) {
                $u = Split-Path $pp -Leaf
                if (Test-Path (Join-Path $pp "AppData\Local\Google\Chrome\User Data\Default\Bookmarks")) { $info += "$u : Chrome" }
                if (Test-Path (Join-Path $pp "AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks")) { $info += "$u : Edge" }
                if (Test-Path (Join-Path $pp "AppData\Roaming\Mozilla\Firefox\Profiles")) { $info += "$u : Firefox" }
            }
            $info | Out-File (Join-Path $dir "BrowserBookmarks.txt") -Encoding UTF8
            return "$($info.Count) browser profiles"
        }},
        @{ Name = "System info"; Action = {
            param($dir)
            $si = [ordered]@{
                ComputerName = $env:COMPUTERNAME
                Domain       = (Get-CimInstance Win32_ComputerSystem).Domain
                OSVersion    = (Get-CimInstance Win32_OperatingSystem).Caption
                OSBuild      = (Get-CimInstance Win32_OperatingSystem).BuildNumber
                Architecture = $env:PROCESSOR_ARCHITECTURE
                TotalRAM_GB  = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
                CaptureDate  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                CaptureUser  = "$env:USERDOMAIN\$env:USERNAME"
            }
            $si | ConvertTo-Json -Depth 3 | Out-File (Join-Path $dir "SystemInfo.json") -Encoding UTF8
            return "OK"
        }}
    )

    $i = 0
    foreach ($task in $tasks) {
        $i++
        Show-ProgressBar $i $tasks.Count "Inventorying" $task.Name
        try {
            $result = & $task.Action $preScanDir
            Write-Host ""
            Show-Status "$($task.Name): $result" "OK"
        } catch {
            Write-Host ""
            Show-Status "$($task.Name): failed ($_)" "WARN"
            Write-Log "Pre-scan task '$($task.Name)' failed: $_" "WARN"
        }
    }

    Write-Log "Pre-scan data collected to $preScanDir"
}

# ============================================================================
# EXTRA DATA BACKUP
# ============================================================================
function Backup-ExtraData {
    param([string]$OutputPath)

    Show-Step "Backing up extra data"

    $extraDir = Join-Path $OutputPath "ExtraBackup"
    if (-not (Test-Path $extraDir)) {
        New-Item -Path $extraDir -ItemType Directory -Force | Out-Null
    }

    $items = @(
        @{ Name = "Sticky Notes"; Src = "$env:LOCALAPPDATA\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState"; Dest = "StickyNotes" },
        @{ Name = "Outlook Signatures"; Src = "$env:APPDATA\Microsoft\Signatures"; Dest = "OutlookSignatures" },
        @{ Name = "Taskbar Pins"; Src = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"; Dest = "TaskbarPins" }
    )

    $i = 0
    foreach ($item in $items) {
        $i++
        Show-ProgressBar $i ($items.Count + 3) "Extra backup" $item.Name
        if (Test-Path $item.Src) {
            try {
                $dest = Join-Path $extraDir $item.Dest
                Copy-Item -Path $item.Src -Destination $dest -Recurse -Force -ErrorAction Stop
                Write-Host ""
                Show-Status "$($item.Name) backed up" "OK"
            } catch {
                Write-Host ""
                Show-Status "$($item.Name) skipped: $_" "WARN"
                Write-Log "$($item.Name) copy failed: $_" "WARN"
            }
        } else {
            Write-Host ""
            Show-Status "$($item.Name): not found (skipped)" "INFO"
        }
    }

    # Desktop shortcuts
    $i++
    Show-ProgressBar $i ($items.Count + 3) "Extra backup" "Desktop shortcuts"
    $shortcutDest = Join-Path $extraDir "DesktopShortcuts"
    if (-not (Test-Path $shortcutDest)) { New-Item -Path $shortcutDest -ItemType Directory -Force | Out-Null }
    $desktopPaths = @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("CommonDesktopDirectory"))
    $scCount = 0
    foreach ($dp in $desktopPaths) {
        if (Test-Path $dp) {
            $shortcuts = Get-ChildItem $dp -Filter "*.lnk" -ErrorAction SilentlyContinue
            $shortcuts | Copy-Item -Destination $shortcutDest -Force -ErrorAction SilentlyContinue
            $scCount += $shortcuts.Count
        }
    }
    Write-Host ""
    Show-Status "Desktop shortcuts: $scCount items" "OK"

    # Power plan
    $i++
    Show-ProgressBar $i ($items.Count + 3) "Extra backup" "Power plan"
    try {
        $powerDest = Join-Path $extraDir "PowerPlan.pow"
        powercfg /export $powerDest (powercfg /getactivescheme).Split()[3] 2>$null
        Write-Host ""
        Show-Status "Power plan exported" "OK"
    } catch {
        Write-Host ""
        Show-Status "Power plan skipped" "WARN"
    }

    # Credentials list
    $i++
    Show-ProgressBar $i ($items.Count + 3) "Extra backup" "Credentials list"
    try {
        $credList = cmdkey /list 2>$null
        $credList | Out-File (Join-Path $extraDir "CredentialsList.txt") -Encoding UTF8
        Write-Host ""
        Show-Status "Credentials listed (passwords not exported)" "OK"
    } catch {
        Write-Host ""
        Show-Status "Credentials list skipped" "WARN"
    }

    Write-Log "Extra data backed up to $extraDir"
}

# ============================================================================
# USMT SCANSTATE WITH LIVE PROGRESS
# ============================================================================
# ----------------------------------------------------------------------------
# Build-ScanStateArguments
#   Pure function: constructs the scanstate.exe argument array from inputs.
#   No host output, no process launch, no $script: state read/write — safe for
#   direct unit tests. Preserves the exact argument order/format the original
#   inline code produced.
# ----------------------------------------------------------------------------
function Build-ScanStateArguments {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorePath,

        [Parameter(Mandatory = $true)]
        [string]$USMTDir,

        [Parameter(Mandatory = $true)]
        [string]$ScanLog,

        [Parameter(Mandatory = $true)]
        [string]$ScanProgress,

        [string[]]$Profiles = @(),

        [hashtable]$ResolvedUserMap = @{},

        [string[]]$AllShortNames = @(),

        [string]$CustomXmlPath = "",

        [switch]$Encrypt,

        [string]$EncryptionKey = "",

        [int]$Verbosity = 5
    )

    $scanArgs = @(
        "`"$StorePath`""
        "/i:`"$(Join-Path $USMTDir 'MigDocs.xml')`""
        "/i:`"$(Join-Path $USMTDir 'MigApp.xml')`""
        "/v:$Verbosity"
        "/l:`"$ScanLog`""
        "/progress:`"$ScanProgress`""
        "/c"
        "/o"
        "/vsc"
        "/efs:copyraw"
    )

    # Custom XML (only if explicitly provided; orchestrator decides whether to
    # test existence and/or copy the file)
    if ($CustomXmlPath) {
        $scanArgs += "/i:`"$CustomXmlPath`""
    }

    # User include/exclude
    if ($Profiles.Count -gt 0) {
        foreach ($user in $Profiles) {
            $fullName = if ($ResolvedUserMap.ContainsKey($user)) {
                $ResolvedUserMap[$user]
            } else {
                "$env:USERDOMAIN\$user"
            }
            $scanArgs += "/ui:`"$fullName`""
            $scanArgs += "/ui:`"*\$user`""
        }

        foreach ($name in $AllShortNames) {
            if ($name -notin $Profiles) {
                $fullName = if ($ResolvedUserMap.ContainsKey($name)) {
                    $ResolvedUserMap[$name]
                } else {
                    "$env:USERDOMAIN\$name"
                }
                $scanArgs += "/ue:`"$fullName`""
                $scanArgs += "/ue:`"*\$name`""
            }
        }

        $scanArgs += '/ue:"NT AUTHORITY\*"'
        $scanArgs += '/ue:"BUILTIN\*"'
    }

    if ($Encrypt) {
        $scanArgs += "/encrypt /key:`"$EncryptionKey`""
    }

    return ,$scanArgs
}

# ----------------------------------------------------------------------------
# Invoke-ScanStateProcess
#   Launches scanstate.exe via Start-TrackedProcess. Declares SupportsShouldProcess
#   so Phase 4 can wire -WhatIf. Returns the running process object.
# ----------------------------------------------------------------------------
function Invoke-ScanStateProcess {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScanStateExe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    if ($PSCmdlet.ShouldProcess($ScanStateExe, "Launch ScanState")) {
        return Start-TrackedProcess -FilePath $ScanStateExe -Arguments ($Arguments -join ' ')
    }
    return $null
}

# ----------------------------------------------------------------------------
# Watch-ScanStateProgress
#   Polls the running scanstate process, prints a live spinner/size/speed line,
#   and returns the final exit code. Blocks until the process exits.
# ----------------------------------------------------------------------------
function Watch-ScanStateProgress {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        $Process,

        [Parameter(Mandatory = $true)]
        [string]$StorePath,

        [Parameter(Mandatory = $true)]
        [string]$ScanProgressFile,

        [Parameter(Mandatory = $true)]
        [datetime]$StartTime,

        [int]$PollIntervalSeconds = 2
    )

    $lastSize = 0
    $speedSamples = @()
    $lastCheck = Get-Date
    $frames = @([char]0x2588, [char]0x2593, [char]0x2592, [char]0x2591)
    $frameIdx = 0

    while (-not $Process.HasExited) {
        $elapsed = ((Get-Date) - $StartTime).ToString('hh\:mm\:ss')
        $frameIdx++

        if (Test-Path $StorePath) {
            $items = Get-ChildItem -Path $StorePath -Recurse -ErrorAction SilentlyContinue
            $currentSize = ($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if (-not $currentSize) { $currentSize = 0 }
            $fileCount = ($items | Measure-Object).Count

            $sizeMB = [math]::Round($currentSize / 1MB, 1)
            $sizeGB = [math]::Round($currentSize / 1GB, 2)
            $sizeStr = if ($sizeGB -ge 1) { "${sizeGB} GB" } else { "${sizeMB} MB" }

            $now = Get-Date
            $interval = ($now - $lastCheck).TotalSeconds
            if ($interval -ge 3 -and $currentSize -gt $lastSize) {
                $speedMBs = [math]::Round(($currentSize - $lastSize) / 1MB / $interval, 1)
                $speedSamples += $speedMBs
                if ($speedSamples.Count -gt 20) { $speedSamples = $speedSamples[-20..-1] }
                $lastSize = $currentSize
                $lastCheck = $now
            }
            $avgSpeed = if ($speedSamples.Count -gt 0) {
                [math]::Round(($speedSamples | Measure-Object -Average).Average, 1)
            } else { 0 }
            $speedStr = if ($avgSpeed -gt 0) { " @ ${avgSpeed} MB/s" } else { "" }

            $usmtProgress = ""
            if (Test-Path $ScanProgressFile) {
                $lastLine = Get-Content $ScanProgressFile -Tail 1 -ErrorAction SilentlyContinue
                if ($lastLine -and $lastLine.Length -gt 0) {
                    if ($lastLine.Length -gt 40) { $lastLine = $lastLine.Substring(0, 37) + "..." }
                    $usmtProgress = " | $lastLine"
                }
            }

            $spin = $frames[$frameIdx % $frames.Count]
            Write-Host "`r     [$spin] $sizeStr | $fileCount files | ${elapsed}${speedStr}${usmtProgress}              " -NoNewline -ForegroundColor Cyan
        } else {
            $spin = $frames[$frameIdx % $frames.Count]
            Write-Host "`r     [$spin] Initializing ScanState... ($elapsed)              " -NoNewline -ForegroundColor DarkCyan
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
    $Process.WaitForExit()
    Write-Host ""

    return [int]$Process.ExitCode
}

# ----------------------------------------------------------------------------
# ConvertFrom-ScanStateExitCode
#   Pure function: maps a scanstate.exe exit code to a status descriptor.
#   Returns a hashtable: @{ Code; Severity; Message; ShouldContinue }.
#   Safe for unit tests — no host output, no side effects.
# ----------------------------------------------------------------------------
function ConvertFrom-ScanStateExitCode {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    switch ($ExitCode) {
        0 {
            return @{
                Code           = 0
                Severity       = 'Success'
                Message        = 'SCANSTATE COMPLETED SUCCESSFULLY'
                ShouldContinue = $true
            }
        }
        3 {
            return @{
                Code           = 3
                Severity       = 'Warning'
                Message        = 'ScanState completed with warnings only'
                ShouldContinue = $true
            }
        }
        26 {
            return @{
                Code           = 26
                Severity       = 'Warning'
                Message        = 'Some files locked - a re-run may capture more'
                ShouldContinue = $true
            }
        }
        61 {
            return @{
                Code           = 61
                Severity       = 'Warning'
                Message        = 'SCANSTATE COMPLETED (some files skipped)'
                ShouldContinue = $true
            }
        }
        71 {
            return @{
                Code           = 71
                Severity       = 'Error'
                Message        = 'ScanState was cancelled or failed'
                ShouldContinue = $false
            }
        }
        default {
            return @{
                Code           = $ExitCode
                Severity       = 'Error'
                Message        = "ScanState exited with code: $ExitCode"
                ShouldContinue = $false
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Invoke-USMTCapture (orchestrator)
#   External contract unchanged: takes $Profiles, returns scanstate exit code
#   (or 0 on DryRun). Delegates to the four helpers above.
# ----------------------------------------------------------------------------
function Invoke-USMTCapture {
    param([string[]]$Profiles)

    Show-Step "Capturing user state (USMT ScanState)"

    $storePath = Join-Path "$($script:State.MappedDrive)\" "USMT"
    if (-not (Test-Path $storePath)) {
        New-Item -Path $storePath -ItemType Directory -Force | Out-Null
    }

    $scanstate = Join-Path $script:State.USMTDir $MigrationConstants.USMT.ScanStateExe
    $logPath = Join-Path "$($script:State.MappedDrive)\" "Logs"
    if (-not (Test-Path $logPath)) {
        New-Item -Path $logPath -ItemType Directory -Force | Out-Null
    }
    $scanLog = Join-Path $logPath "scanstate.log"
    $scanProgress = Join-Path $logPath "scanstate-progress.log"

    # Resolve users (needs Win32_UserProfile lookup — side-effectful, kept in orchestrator)
    $resolvedMap = @{}
    $allShortNames = @()
    if ($Profiles.Count -gt 0) {
        $allWmiProfiles = Get-CimInstance Win32_UserProfile |
            Where-Object { -not $_.Special -and $_.LocalPath }
        foreach ($wp in $allWmiProfiles) {
            $short = Split-Path $wp.LocalPath -Leaf
            try {
                $ntAccount = (New-Object System.Security.Principal.SecurityIdentifier($wp.SID)).Translate(
                    [System.Security.Principal.NTAccount]).Value
                $resolvedMap[$short] = $ntAccount
            } catch {
                $resolvedMap[$short] = "$env:USERDOMAIN\$short"
            }
        }
        $allShortNames = @($allWmiProfiles | ForEach-Object { Split-Path $_.LocalPath -Leaf } |
            Where-Object { $_ -notin @('Public','Default','Default User','All Users') })

        foreach ($user in $Profiles) {
            $fullName = if ($resolvedMap.ContainsKey($user)) { $resolvedMap[$user] } else { "$env:USERDOMAIN\$user" }
            Write-Log "Include user: $fullName (and *\$user)"
        }
        foreach ($name in $allShortNames) {
            if ($name -notin $Profiles) {
                $fullName = if ($resolvedMap.ContainsKey($name)) { $resolvedMap[$name] } else { "$env:USERDOMAIN\$name" }
                Write-Log "Exclude user: $fullName (and *\$name)"
            }
        }
    }

    # Custom XML: copy to share if present, then pass path to builder.
    $customXmlPath = ""
    $localCustomXml = Join-Path $PSScriptRoot "custom-migration.xml"
    if (Test-Path $localCustomXml) {
        Copy-Item $localCustomXml -Destination "$($script:State.MappedDrive)\" -Force
        $customXmlPath = $localCustomXml
        Show-Status "Custom migration rules included" "OK"
    }

    # Encryption: prompt for key if needed, then delegate arg assembly.
    # Post t1-e12, $EncryptionKey is a [SecureString]; prompt with Read-Host
    # -AsSecureString and convert to plaintext only at the Build-ScanStateArguments
    # boundary (which is itself a pure arg assembler consuming a plain string).
    if ($EncryptStore) {
        if (-not $EncryptionKey) {
            if ($NonInteractive) {
                Safe-Exit -Code 1 -Reason "No -EncryptionKey provided and running non-interactive (required with -EncryptStore)"
            }
            $EncryptionKey = Read-Host "     Enter encryption key" -AsSecureString
        }
    }

    # Just-in-time plaintext: scanstate.exe requires the key inline in the /key:
    # argument, so there is no way to avoid at least one in-memory plaintext
    # copy. The $plainEncKey variable is scrubbed below after arg assembly.
    $plainEncKey = ""
    if ($EncryptStore -and $EncryptionKey) {
        $plainEncKey = ConvertFrom-SecureStringPlain -Secure $EncryptionKey
    }

    # Build scanstate arg list (pure)
    $scanArgs = Build-ScanStateArguments `
        -StorePath $storePath `
        -USMTDir $script:State.USMTDir `
        -ScanLog $scanLog `
        -ScanProgress $scanProgress `
        -Profiles $Profiles `
        -ResolvedUserMap $resolvedMap `
        -AllShortNames $allShortNames `
        -CustomXmlPath $customXmlPath `
        -Encrypt:$EncryptStore `
        -EncryptionKey $plainEncKey `
        -Verbosity 5

    # Scrub the local plaintext reference. $scanArgs still contains the key
    # in the /key:"..." entry but that is the minimum footprint required.
    $plainEncKey = $null

    if ($Profiles.Count -gt 0) {
        Show-Status "Users: $($Profiles -join ', ')" "OK"
    }
    if ($EncryptStore) {
        Show-Status "Encryption enabled" "OK"
    }

    Show-Detail "Store" $storePath
    Show-Detail "Log  " $scanLog
    Write-Log "ScanState command: $scanstate $($scanArgs -join ' ')"

    if ($DryRun) {
        Write-Host ""
        Show-Status "DRY RUN - ScanState will NOT execute" "WARN"
        Show-Status "Review output above and re-run without -DryRun" "INFO"
        return 0
    }

    Write-Host ""
    Show-Status "ScanState starting... this may take a while" "WAIT"
    Write-Host ""

    # Launch
    $scanStart = Get-Date
    try {
        $process = Invoke-ScanStateProcess -ScanStateExe $scanstate -Arguments $scanArgs
    } catch {
        Safe-Exit -Code 1 -Reason "Failed to launch ScanState ($scanstate): $_"
    }

    # Watch + exit code
    $exitCode = Watch-ScanStateProgress `
        -Process $process `
        -StorePath $storePath `
        -ScanProgressFile $scanProgress `
        -StartTime $scanStart

    $duration = ((Get-Date) - $scanStart).ToString('hh\:mm\:ss')

    # Final stats
    $finalSize = 0
    $finalFiles = 0
    if (Test-Path $storePath) {
        $finalItems = Get-ChildItem -Path $storePath -Recurse -ErrorAction SilentlyContinue
        $finalSize = ($finalItems | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        $finalFiles = ($finalItems | Measure-Object).Count
    }
    $finalMB = [math]::Round($finalSize / 1MB, 1)
    $finalGB = [math]::Round($finalSize / 1GB, 2)
    $finalStr = if ($finalGB -ge 1) { "${finalGB} GB" } else { "${finalMB} MB" }

    # Map exit code -> status descriptor (pure)
    $status = ConvertFrom-ScanStateExitCode -ExitCode $exitCode

    Write-Host ""
    switch ($exitCode) {
        0 {
            Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
            Write-Host "  |          SCANSTATE COMPLETED SUCCESSFULLY             |" -ForegroundColor Green
            Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
        }
        61 {
            Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
            Write-Host "  |    SCANSTATE COMPLETED (some files skipped)           |" -ForegroundColor Yellow
            Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
        }
        71 {
            Show-Status "ScanState was cancelled or failed" "FAIL"
        }
        26 {
            Show-Status "Some files locked - a re-run may capture more" "WARN"
        }
        default {
            Show-Status $status.Message "FAIL"
        }
    }

    Write-Host ""
    Show-Detail "Duration   " $duration
    Show-Detail "Store Size " $finalStr
    Show-Detail "Files      " "$finalFiles"
    Show-Detail "Log        " $scanLog

    Write-Log "ScanState finished: exit=$exitCode, duration=$duration, size=$finalStr, files=$finalFiles"
    return $exitCode
}

# ============================================================================
# COMPLETION
# ============================================================================
function Set-CaptureComplete {
    $marker = Join-Path "$($script:State.MappedDrive)\" "capture-complete.flag"
    $completionInfo = @{
        SourceComputer = $env:COMPUTERNAME
        SourceDomain   = $env:USERDOMAIN
        CaptureTime    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        USMTVersion    = (Get-Item (Join-Path $script:State.USMTDir $MigrationConstants.USMT.ScanStateExe)).VersionInfo.FileVersion
    }
    $completionInfo | ConvertTo-Json | Out-File $marker -Encoding UTF8
    Write-Log "Capture completion marker written"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
function Main {
    # Prevent sleep/screen-off during migration (can take hours)
    try {
        Add-Type 'using System; using System.Runtime.InteropServices; public static class MwPwrS { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f); }' -EA SilentlyContinue
        [MwPwrS]::SetThreadExecutionState(0x80000003) | Out-Null
    } catch {}

    Show-Banner "USMT MIGRATION - SOURCE PC CAPTURE"

    if ($ExtraData) {
        $script:State.TotalSteps = 8
        Set-MigrationUIState -State $script:State
    }

    try {
        # Step 1: Prerequisites
        Test-Prerequisites

        # Step 2: USMT
        if (-not (Initialize-USMT)) {
            Safe-Exit -Code 1 -Reason "USMT initialization failed - all install methods exhausted"
        }

        # Step 3: Connect to destination
        Connect-DestinationShare

        # Step 4: Get profiles
        $profiles = Get-MigrationProfiles

        # Step 5: Pre-scan inventory
        Export-PreScanData -OutputPath "$($script:State.MappedDrive)\"

        # Step 6: Extra data (optional)
        if ($ExtraData) {
            Backup-ExtraData -OutputPath "$($script:State.MappedDrive)\"
        }

        # Step 7: ScanState
        $exitCode = Invoke-USMTCapture -Profiles $profiles

        # Step 8: Finalize
        $script:State.CurrentStep = $script:State.TotalSteps
        $pct = 100
        $elapsed = ((Get-Date) - $script:State.StartTime).ToString('mm\:ss')
        $barLen = $MigrationConstants.UI.ProgressBarWidth
        $bar = ([char]0x2588).ToString() * $barLen

        if ($exitCode -eq 0 -or $exitCode -eq 61) {
            Set-CaptureComplete

            Write-Host ""
            Write-Host "  [$bar] 100% " -NoNewline -ForegroundColor Green
            Write-Host "Complete ($elapsed elapsed)" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
            Write-Host "  |              MIGRATION CAPTURE COMPLETE               |" -ForegroundColor Green
            Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
            Write-Host ""
            Write-Host "     Next steps on the DESTINATION PC:" -ForegroundColor Yellow
            Write-Host "       1. .\destination-setup.ps1 -RestoreOnly" -ForegroundColor White
            Write-Host "       2. .\post-migration-verify.ps1" -ForegroundColor White
            Write-Host "       3. .\destination-setup.ps1 -Cleanup" -ForegroundColor White
            Write-Host ""
        } else {
            Write-Host ""
            Show-Status "Capture had errors. Check logs before proceeding." "FAIL"
        }

        # Copy local log to share
        if (Test-Path $LogFile) {
            Copy-Item $LogFile -Destination (Join-Path "$($script:State.MappedDrive)\" "Logs") -Force -ErrorAction SilentlyContinue
        }

    } catch {
        Show-Status "Fatal error: $_" "FAIL"
        Write-Log "FATAL: $_ `n $($_.ScriptStackTrace)" "FATAL"
        exit 1
    } finally {
        Disconnect-Share
    }
}

# Disconnect-Share also needs logging
function Disconnect-Share {
    if ($script:State.MappedDrive -and $script:State.ShareConnected) {
        try {
            $result = Invoke-SafeCommand -Command "net" -Arguments @("use", $script:State.MappedDrive, "/delete", "/yes") -OperationName "Drive disconnect" -SuppressStderr
            if ($result.Success) {
                Show-Status "Drive $($script:State.MappedDrive) disconnected" "OK"
                Write-Log "Disconnected drive $($script:State.MappedDrive)"
            } else {
                Show-Status "Drive disconnect returned code $($result.ExitCode)" "WARN"
                Write-Log "Drive disconnect exit code: $($result.ExitCode)" "WARN"
            }
        } catch {
            Show-Status "Could not disconnect drive: $_" "WARN"
            Write-Log "Drive disconnect error: $_" "WARN"
        }
    }
}

# Run
$totalElapsed = { ((Get-Date) - $script:State.StartTime).ToString('hh\:mm\:ss') }
try {
    Main
} catch {
    Show-Status "Fatal error: $_" "FAIL"
    Write-Log "FATAL (outer): $_ `n $($_.ScriptStackTrace)" "FATAL"
    exit 1
} finally {
    Write-Host ""
    Write-Host "  Total time: $(& $totalElapsed)" -ForegroundColor DarkGray
    Write-Log "Script finished. Total time: $(& $totalElapsed)"
    Stop-Logging
    Write-Host ""
}
