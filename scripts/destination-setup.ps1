<#
.SYNOPSIS
    Destination PC Setup - Creates a migration share and restores captured state via USMT.

.DESCRIPTION
    Run this script on the DESTINATION (new) PC FIRST (before running
    source-capture.ps1 on the old PC). It auto-downloads and installs USMT
    if not present, creates a local folder and SMB share for the source PC
    to write migration data to, configures Windows Firewall to allow SMB
    from the source, and provides a restore mode (-RestoreOnly) that invokes
    loadstate.exe against the captured store. A cleanup mode (-Cleanup) tears
    the share and firewall rules down when the migration is complete.
    Auto-elevates to Administrator via UAC if not already running elevated.

.PARAMETER MigrationFolder
    Local directory on the destination PC that backs the SMB share. Must be
    an absolute path on a drive letter. Defaults to C:\MigrationStore.

.PARAMETER ShareName
    Name for the SMB share that the source PC writes into. Defaults to
    "MigrationShare$" (trailing '$' makes it a hidden share). Validated against
    Windows share-name rules (1-80 characters, limited punctuation).

.PARAMETER USMTPath
    Optional path to an existing USMT install directory. Must contain
    loadstate.exe when supplied. When empty, USMT is auto-installed.

.PARAMETER AllowedSourceIP
    Optional IP address (or CIDR) of the source PC. When supplied the firewall
    rule is narrowed to that address only. When empty, any LAN host may
    connect.

.PARAMETER AllowedSourceUser
    Optional Windows account name of the source-side user. When supplied the
    share ACL is tightened so only that principal (plus Administrators) can
    read and write the store; anonymous and "Everyone" access is removed.

.PARAMETER RestoreOnly
    Switch. Skips share creation and jumps directly to invoking loadstate.exe
    against an already-captured store in -MigrationFolder.

.PARAMETER Cleanup
    Switch. Removes the SMB share, firewall rules, and optionally the
    migration folder. Use after the migration is verified complete.

.PARAMETER SkipUSMTInstall
    Switch. Skips the automatic USMT download/install step. Requires -USMTPath
    to point at an existing install.

.PARAMETER NonInteractive
    Alias: -Silent. Suppresses prompts; causes the script to fail fast when
    any required value is missing.

.EXAMPLE
    PS> .\destination-setup.ps1

    Initial setup with defaults: creates C:\MigrationStore, shares it as
    MigrationShare$, configures firewall, auto-installs USMT if missing.

.EXAMPLE
    PS> .\destination-setup.ps1 -AllowedSourceUser 'OLDPC\alice' `
        -AllowedSourceIP 192.168.1.42

    Tightened setup: share ACL restricted to 'OLDPC\alice' and firewall rule
    scoped to the single source IP.

.EXAMPLE
    PS> .\destination-setup.ps1 -RestoreOnly

    Runs loadstate.exe against the store already present in
    C:\MigrationStore.

.EXAMPLE
    PS> .\destination-setup.ps1 -Cleanup

    Removes the SMB share and firewall rules once migration is verified.

.INPUTS
    None. This script does not accept piped input.

.OUTPUTS
    None. Exit code 0 indicates success; non-zero indicates failure. Setup,
    restore, and cleanup logs are written under the migration folder's Logs
    subdirectory.

.NOTES
    - Requires Administrator privileges (auto-elevates via UAC).
    - Run BEFORE source-capture.ps1 on the source PC.
    - Run -RestoreOnly AFTER source-capture.ps1 completes.
    - Run -Cleanup AFTER verification to remove share and firewall rules.

.LINK
    https://github.com/supermarsx/migration-merlin

.LINK
    .\source-capture.ps1

.LINK
    .\post-migration-verify.ps1
#>

# ============================================================================
# PARAMETER BLOCK (validation attributes added in Phase 3 / t1-e12)
# ----------------------------------------------------------------------------
# ValidateScript attributes use inline checks rather than calling into
# MigrationValidators.psm1 directly — param-binder validation runs before
# the script body's Import-Module calls, so referencing module functions
# here would fail when the script is invoked stand-alone. The shared Test-*
# helpers are unit-tested in their own module suite and mirror the logic
# applied inline below.
# ============================================================================
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateScript({
            [string]::IsNullOrEmpty($_) -or ($_ -match '^[a-zA-Z]:\\')
        })]
    [string]$MigrationFolder = "C:\MigrationStore",

    [ValidateScript({
            # SMB share name: 1-80 chars, limited punctuation, optional trailing $
            (-not [string]::IsNullOrEmpty($_)) -and
            ($_.Length -le 80) -and
            ($_ -match '^[A-Za-z0-9_\$][A-Za-z0-9_\-\.\$]{0,79}$')
        })]
    [string]$ShareName = "MigrationShare$",

    [ValidateScript({
            [string]::IsNullOrEmpty($_) -or
            ((Test-Path -LiteralPath $_ -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $_ 'loadstate.exe') -PathType Leaf))
        })]
    [string]$USMTPath = "",

    [string]$AllowedSourceIP = "",

    [Parameter()]
    [ValidateScript({ [string]::IsNullOrEmpty($_) -or $_ -match '^[A-Za-z0-9_\\\.\$-]+$' })]
    [string]$AllowedSourceUser = "",

    [switch]$RestoreOnly,
    [switch]$Cleanup,
    [switch]$SkipUSMTInstall,
    [Alias("Silent")]
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

# ============================================================================
# SHARED MODULE IMPORTS (MigrationValidators + ErrorHandling added in
# Phase 3 / t1-e12)
# ============================================================================
Import-Module "$PSScriptRoot\..\modules\MigrationConstants.psm1" -Force
Import-Module "$PSScriptRoot\..\modules\MigrationUI.psm1" -Force
Import-Module "$PSScriptRoot\..\modules\USMTTools.psm1" -Force
Import-Module "$PSScriptRoot\..\modules\MigrationState.psm1" -Force
Import-Module "$PSScriptRoot\..\modules\MigrationValidators.psm1" -Force
Import-Module "$PSScriptRoot\..\modules\ErrorHandling.psm1" -Force
. "$PSScriptRoot\..\modules\Invoke-Elevated.ps1"
. "$PSScriptRoot\..\modules\MigrationLogging.ps1"

# ============================================================================
# AUTO-ELEVATION (via Invoke-Elevated.ps1)
# ============================================================================
Request-Elevation -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# ============================================================================
# SECURESTRING HAND-OFF CLEANUP
# ----------------------------------------------------------------------------
# Reclaim any DPAPI env-var secrets passed across UAC boundary. Destination
# currently takes no SecureString params; this is forward-compat scaffolding
# for e12. Simply clears any MIGRATION_MERLIN_SECURE_* env vars that may be
# present in the elevated process's environment.
# ============================================================================
foreach ($var in (Get-ChildItem env:MIGRATION_MERLIN_SECURE_* -ErrorAction SilentlyContinue)) {
    Remove-Item $var.PSPath -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# CONFIGURATION
# ============================================================================
# Consolidated migration run state (t1-e11): replaces the parallel $script:
# globals (USMTDir, TotalSteps, CurrentStep, StartTime) with a single
# hashtable wrapper. destination-setup doesn't use MappedDrive/ShareConnected
# but they're kept on the state for symmetry with source-capture.
$script:State = New-MigrationState -TotalSteps $MigrationConstants.UI.DestinationTotalSteps

# Initialize module-scoped UI state (required because MigrationUI runs in
# isolated module session state and cannot reach this script's $script: vars).
Set-MigrationUIState -State $script:State

# Load shared logging infrastructure
$LogFile = Initialize-Logging -PrimaryLogFile (Join-Path $MigrationFolder "destination-setup.log") -ScriptName "destination-setup"
Write-Log "Script started with parameters: $(Format-SafeParams $PSBoundParameters)"

# ============================================================================
# USMT DETECTION + AUTO-INSTALL (wraps USMTTools.psm1)
# ============================================================================
function Find-USMT {
    param([string]$ExeName = "loadstate.exe")

    # Include caller-provided MigrationFolder\USMT-Tools as an extra search path.
    $extra = @("$MigrationFolder\USMT-Tools")
    $found = USMTTools\Find-USMT -ExeName $ExeName -USMTPathOverride $USMTPath -AdditionalSearchPaths $extra
    if ($found) {
        $script:State.USMTDir = $found
        return $true
    }
    return $false
}

function Install-USMT {
    <# Tries bundled zip first, then falls back to online ADK download. #>
    Show-Status "USMT not found on this system" "WARN"
    Show-Status "Checking for bundled USMT zip..." "WAIT"

    $extraZip = @()
    if (Test-Path $MigrationFolder) { $extraZip += $MigrationFolder }

    $found = USMTTools\Install-USMT -ExeName 'loadstate.exe' `
        -USMTPathOverride $USMTPath `
        -AdditionalSearchPaths @("$MigrationFolder\USMT-Tools") `
        -AdditionalZipSearchPaths $extraZip

    if ($found) {
        $script:State.USMTDir = $found
        Show-Status "USMT ready at: $found" "OK"
        Write-Log "USMT ready at: $found"
        return $true
    }

    Show-Status "USMT installation failed (all methods exhausted)" "FAIL"
    Write-Log "USMT installation failed" "ERROR"
    return $false
}

# ============================================================================
# SYSTEM CHECKS
# ============================================================================
function Test-Prerequisites {
    Show-Step "Checking system prerequisites"

    # Check admin
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Safe-Exit -Code 1 -Reason "Script must be run as Administrator"
    }
    Show-Status "Running as Administrator" "OK"

    # Check OS version
    $os = Try-CimInstance -ClassName "Win32_OperatingSystem" -FriendlyName "Operating System"
    if ($os) {
        Show-Status "OS: $($os.Caption) (Build $($os.BuildNumber))" "OK"
        Write-Log "OS: $($os.Caption) Build $($os.BuildNumber)"
    }
    else {
        Show-Status "Could not determine OS version (WMI unavailable)" "WARN"
        Write-Log "WMI query for OS failed - continuing anyway" "WARN"
    }

    # Check disk space
    try {
        $drive = (Split-Path $MigrationFolder -Qualifier)
        $disk = Try-CimInstance -ClassName "Win32_LogicalDisk" -Filter "DeviceID='$drive'" -FriendlyName "Disk $drive"
        if ($disk -and $disk.Size -gt 0) {
            $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
            $totalGB = [math]::Round($disk.Size / 1GB, 2)
            $usedPct = [math]::Round((1 - $disk.FreeSpace / $disk.Size) * 100)
            Show-ProgressBar $usedPct 100 "Disk ${drive}" "${freeGB} GB free / ${totalGB} GB"
            Write-Host ""
            if ($freeGB -lt 20) {
                Show-Status "Low disk space! Migration may need 20+ GB" "WARN"
                Write-Log "Low disk space on ${drive}: ${freeGB} GB free" "WARN"
            }
            else {
                Show-Status "Disk space OK (${freeGB} GB free)" "OK"
            }
        }
        else {
            Show-Status "Could not check disk space for $drive" "WARN"
            Write-Log "Disk space check failed for $drive" "WARN"
        }
    }
    catch {
        Show-Status "Disk space check failed: $_" "WARN"
        Write-Log "Disk space check error: $_" "WARN"
    }

    # Check network
    try {
        $networkAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
        if (-not $networkAdapters -or $networkAdapters.Count -eq 0) {
            # Fallback: try ipconfig
            $ipconfigOut = & ipconfig 2>$null
            if ($ipconfigOut -match "IPv4 Address") {
                Show-Status "Network detected via ipconfig (Get-NetAdapter unavailable)" "WARN"
                Write-Log "Get-NetAdapter failed but ipconfig shows network" "WARN"
            }
            else {
                Safe-Exit -Code 1 -Reason "No active network adapters found"
            }
        }

        $ipAddresses = @()
        try {
            $ipAddresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
                Select-Object -ExpandProperty IPAddress
        }
        catch {
            Write-Log "Get-NetIPAddress failed, falling back to hostname resolution" "WARN"
            $ipAddresses = @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                    Select-Object -ExpandProperty IPAddressToString)
        }
        foreach ($ip in $ipAddresses) {
            Show-Status "Network: $ip" "OK"
        }
        Write-Log "IPs: $($ipAddresses -join ', ')"
    }
    catch {
        Show-Status "Network check failed: $_" "WARN"
        Write-Log "Network check error: $_" "WARN"
    }

    return $true
}

# ============================================================================
# USMT DETECTION + AUTO-INSTALL
# ============================================================================
function Initialize-USMT {
    Show-Step "Locating USMT tools"

    if (Find-USMT) {
        $version = (Get-Item (Join-Path $script:State.USMTDir "loadstate.exe")).VersionInfo.FileVersion
        Show-Status "USMT found: $($script:State.USMTDir)" "OK"
        Show-Detail "Version" $version
        Write-Log "USMT found at $($script:State.USMTDir), version $version"
        return $true
    }

    if ($SkipUSMTInstall) {
        Show-Status "USMT not found and -SkipUSMTInstall specified" "WARN"
        Show-Status "Share will be created but restore will need USMT installed later" "INFO"
        return $false
    }

    # Auto-install
    Show-Status "USMT not detected - starting automatic installation" "WAIT"
    $installed = Install-USMT

    if (-not $installed) {
        Show-Status "Auto-install failed. You can:" "FAIL"
        Show-Status "  1. Install Windows ADK manually with USMT component" "INFO"
        Show-Status "  2. Copy USMT binaries to C:\USMT or specify -USMTPath" "INFO"
        Show-Status "  3. Re-run with -SkipUSMTInstall to set up share without USMT" "INFO"
    }

    return $installed
}

# ============================================================================
# SHARE CREATION
# ============================================================================
function New-MigrationShare {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Show-Step "Creating migration share"

    # Create folder structure
    try {
        if (-not (Test-Path $MigrationFolder)) {
            New-Item -Path $MigrationFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Show-Status "Created: $MigrationFolder" "OK"
            Write-Log "Created migration folder: $MigrationFolder"
        }
        else {
            Show-Status "Folder exists: $MigrationFolder" "WARN"
        }

        $subfolders = @("USMT", "Logs", "Backup")
        foreach ($sub in $subfolders) {
            $subPath = Join-Path $MigrationFolder $sub
            if (-not (Test-Path $subPath)) {
                New-Item -Path $subPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
        }
        Show-Status "Subfolders: $($subfolders -join ', ')" "OK"
    }
    catch {
        Safe-Exit -Code 1 -Reason "Failed to create migration folder structure: $_"
    }

    # NTFS permissions — branch on -AllowedSourceUser for tightened ACL
    try {
        $acl = Get-Acl $MigrationFolder
        if ([string]::IsNullOrWhiteSpace($AllowedSourceUser)) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "Everyone", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
            )
            $acl.SetAccessRule($rule)
            if ($PSCmdlet.ShouldProcess($MigrationFolder, "Set NTFS ACL (Everyone: FullControl)")) {
                Set-Acl -Path $MigrationFolder -AclObject $acl
            }
            Show-Status "NTFS permissions set (Everyone: Full Control)" "OK"
        }
        else {
            foreach ($account in @($AllowedSourceUser, "SYSTEM", $env:USERNAME)) {
                try {
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $account, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
                    )
                    $acl.SetAccessRule($rule)
                }
                catch {
                    Write-Log "Skipping NTFS rule for '$account': $_" "WARN"
                }
            }
            if ($PSCmdlet.ShouldProcess($MigrationFolder, "Set NTFS ACL (restricted to $AllowedSourceUser + SYSTEM + $env:USERNAME)")) {
                Set-Acl -Path $MigrationFolder -AclObject $acl
            }
            Show-Status "NTFS permissions set (restricted: $AllowedSourceUser, SYSTEM, $env:USERNAME)" "OK"
        }
    }
    catch {
        Show-Status "Could not set NTFS permissions: $_ (share may still work)" "WARN"
        Write-Log "NTFS permission set failed: $_" "WARN"
    }

    # Remove existing share
    try {
        $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
        if ($existingShare) {
            if ($PSCmdlet.ShouldProcess($ShareName, "Remove existing SMB share")) {
                Remove-SmbShare -Name $ShareName -Force -ErrorAction Stop
            }
            Show-Status "Removed existing share" "WARN"
            Write-Log "Removed existing share: $ShareName"
        }
    }
    catch {
        Show-Status "Could not remove existing share: $_" "WARN"
        Write-Log "Remove existing share failed: $_" "WARN"
    }

    # Create SMB share — access account depends on -AllowedSourceUser
    try {
        if ([string]::IsNullOrWhiteSpace($AllowedSourceUser)) {
            Show-Status "Granting SMB share access to 'Everyone' (use -AllowedSourceUser to restrict)." 'WARN'
            Write-Log "Share '$ShareName' granted to 'Everyone' (no -AllowedSourceUser restriction)" "WARN"
            if ($PSCmdlet.ShouldProcess($ShareName, "Create SMB share (FullAccess: Everyone)")) {
                New-SmbShare -Name $ShareName -Path $MigrationFolder -FullAccess "Everyone" `
                    -Description $MigrationConstants.Defaults.ShareDescription -ErrorAction Stop | Out-Null
            }
            if ($PSCmdlet.ShouldProcess("SMB share $ShareName", "Grant FullAccess to Everyone")) {
                Grant-SmbShareAccess -Name $ShareName -AccountName "Everyone" `
                    -AccessRight Full -Force -ErrorAction Stop | Out-Null
            }
        }
        else {
            Show-Status "Granting SMB share access to '$AllowedSourceUser' (tightened ACL)." 'OK'
            Write-Log "Share '$ShareName' restricted to '$AllowedSourceUser'" "INFO"
            if ($PSCmdlet.ShouldProcess($ShareName, "Create SMB share (FullAccess: $AllowedSourceUser)")) {
                New-SmbShare -Name $ShareName -Path $MigrationFolder -FullAccess $AllowedSourceUser `
                    -Description $MigrationConstants.Defaults.ShareDescription -ErrorAction Stop | Out-Null
            }
            if ($PSCmdlet.ShouldProcess("SMB share $ShareName", "Grant FullAccess to $AllowedSourceUser")) {
                Grant-SmbShareAccess -Name $ShareName -AccountName $AllowedSourceUser `
                    -AccessRight Full -Force -ErrorAction Stop | Out-Null
            }
        }
        Show-Status "Share created: \\$env:COMPUTERNAME\$ShareName" "OK"
        Write-Log "Share created: \\$env:COMPUTERNAME\$ShareName -> $MigrationFolder"
    }
    catch {
        # Fallback: try net share command
        Show-Status "New-SmbShare failed: $_ - trying net share fallback..." "WARN"
        Write-Log "New-SmbShare failed: $_ - attempting net share fallback" "WARN"
        try {
            $netResult = Invoke-SafeCommand -Command "net" `
                -Arguments @("share", "$ShareName=$MigrationFolder", "/grant:Everyone,Full") `
                -OperationName "net share"
            if ($netResult.Success) {
                Show-Status "Share created via net share: \\$env:COMPUTERNAME\$ShareName" "OK"
                Write-Log "Share created via net share fallback"
            }
            else {
                Safe-Exit -Code 1 -Reason "Failed to create share. net share exit code: $($netResult.ExitCode)"
            }
        }
        catch {
            Safe-Exit -Code 1 -Reason "All share creation methods failed: $_"
        }
    }
}

# ============================================================================
# FIREWALL CONFIGURATION
# ============================================================================
function Set-MigrationFirewall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Show-Step "Configuring firewall"

    # File and Printer Sharing
    try {
        $fpsRules = Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" -ErrorAction SilentlyContinue
        if ($fpsRules) {
            $fpsRules | Set-NetFirewallRule -Enabled True -ErrorAction Stop
            Show-Status "Enabled: File and Printer Sharing" "OK"
        }
    }
    catch {
        Show-Status "Could not enable File and Printer Sharing: $_" "WARN"
        Write-Log "File and Printer Sharing enable failed: $_" "WARN"
        # Fallback: try netsh
        $netshResult = Invoke-SafeCommand "netsh" @("advfirewall", "firewall", "set", "rule", "group=File and Printer Sharing", "new", "enable=Yes") -OperationName "netsh FPS enable" -SuppressStderr
        if ($netshResult.Success) { Show-Status "Enabled FPS via netsh fallback" "OK" }
    }

    # Custom migration rule
    $ruleName = "USMT-Migration-Inbound"
    try {
        $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($existingRule) {
            if ($PSCmdlet.ShouldProcess($ruleName, "Remove existing firewall rule")) {
                Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
            }
        }
    }
    catch {
        Write-Log "Could not remove existing rule '$ruleName': $_" "WARN"
    }

    try {
        $ruleParams = @{
            DisplayName = $ruleName
            Direction   = "Inbound"
            Protocol    = "TCP"
            LocalPort   = @(445, 139)
            Action      = "Allow"
            Profile     = @("Domain", "Private")
            Description = "Temporary rule for USMT migration - safe to remove after migration"
        }
        if ($AllowedSourceIP) {
            $ruleParams.RemoteAddress = $AllowedSourceIP
            Show-Status "Restricted to source IP: $AllowedSourceIP" "OK"
        }
        if ($PSCmdlet.ShouldProcess($ruleName, "Create firewall rule (TCP 445, 139)")) {
            New-NetFirewallRule @ruleParams -ErrorAction Stop | Out-Null
        }
        Show-Status "Migration firewall rule created (TCP 445, 139)" "OK"
    }
    catch {
        Show-Status "Could not create firewall rule: $_" "WARN"
        Write-Log "Firewall rule creation failed: $_" "WARN"
        # Fallback: try netsh
        $netshResult = Invoke-SafeCommand "netsh" @("advfirewall", "firewall", "add", "rule", "name=$ruleName", "dir=in", "action=allow", "protocol=tcp", "localport=445,139") -OperationName "netsh rule add" -SuppressStderr
        if ($netshResult.Success) { Show-Status "Firewall rule created via netsh fallback" "OK" }
        else { Show-Status "Firewall rule creation failed - share may not be accessible" "WARN" }
    }

    # SMB2
    try {
        $smbConfig = Get-SmbServerConfiguration -ErrorAction Stop
        if (-not $smbConfig.EnableSMB2Protocol) {
            Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force -ErrorAction Stop
            Show-Status "Enabled SMB2 protocol" "OK"
        }
    }
    catch {
        Show-Status "Could not verify/enable SMB2: $_" "WARN"
        Write-Log "SMB2 check/enable failed: $_" "WARN"
    }

    # Network Discovery
    try {
        $ndRules = Get-NetFirewallRule -DisplayGroup "Network Discovery" -ErrorAction SilentlyContinue
        if ($ndRules) {
            $ndRules | Set-NetFirewallRule -Enabled True -ErrorAction Stop
            Show-Status "Enabled: Network Discovery" "OK"
        }
    }
    catch {
        Show-Status "Could not enable Network Discovery: $_" "WARN"
        Write-Log "Network Discovery enable failed: $_" "WARN"
    }

    Write-Log "Firewall configuration completed"
}

# ============================================================================
# SHARE READINESS & CONNECTION INFO
# ============================================================================
function Show-ConnectionInfo {
    Show-Step "Ready for migration"

    # Verify share
    $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if (-not $share) {
        Show-Status "Share not found: $ShareName" "FAIL"
        return $false
    }

    # Test write
    try {
        if (-not (Test-WritablePath $MigrationFolder)) {
            Show-Status "Share folder is not writable!" "FAIL"
            Write-Log "Share write test failed for $MigrationFolder" "ERROR"
            return $false
        }
        Show-Status "Share is writable" "OK"
    }
    catch {
        Show-Status "Share write test failed: $_" "FAIL"
        Write-Log "Share write test error: $_" "ERROR"
        return $false
    }

    $ipAddresses = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
        Select-Object -ExpandProperty IPAddress

    # Display connection box
    Write-Host ""
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
    Write-Host "  |              SHARE READY FOR MIGRATION                |" -ForegroundColor Green
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Show-Detail "Computer Name" $env:COMPUTERNAME
    Show-Detail "Share (name) " "\\$env:COMPUTERNAME\$ShareName"
    foreach ($ip in $ipAddresses) {
        Show-Detail "Share (IP)   " "\\$ip\$ShareName"
    }
    Show-Detail "Local Path   " $MigrationFolder
    if ($script:State.USMTDir) {
        Show-Detail "USMT Path    " $script:State.USMTDir
    }

    Write-Host ""
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  On the SOURCE PC, run:                               |" -ForegroundColor Yellow
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "     .\source-capture.ps1 -DestinationShare `"\\$env:COMPUTERNAME\$ShareName`"" -ForegroundColor White
    Write-Host ""

    return $true
}

# ============================================================================
# LIVE MONITORING
# ============================================================================
function Watch-MigrationProgress {
    Write-Host ""
    Show-Status "Monitoring for incoming migration data..." "WAIT"
    Show-Status "Press Ctrl+C to stop" "INFO"
    Write-Host ""

    $usmtStore = Join-Path $MigrationFolder "USMT"
    $lastSize = 0
    $startWatch = Get-Date
    $lastFileCount = 0
    $speedSamples = @()

    while ($true) {
        if (Test-Path $usmtStore) {
            $items = Get-ChildItem -Path $usmtStore -Recurse -ErrorAction SilentlyContinue
            $currentSize = ($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if (-not $currentSize) { $currentSize = 0 }
            $fileCount = ($items | Measure-Object).Count
            $sizeMB = [math]::Round($currentSize / 1MB, 1)
            $sizeGB = [math]::Round($currentSize / 1GB, 2)
            $elapsed = ((Get-Date) - $startWatch).ToString('hh\:mm\:ss')

            # Calculate transfer speed
            if ($currentSize -ne $lastSize) {
                $delta = $currentSize - $lastSize
                $speedMBs = [math]::Round($delta / 1MB / 5, 1)  # 5 second intervals
                $speedSamples += $speedMBs
                if ($speedSamples.Count -gt 12) { $speedSamples = $speedSamples[-12..-1] }  # keep last minute
                $avgSpeed = [math]::Round(($speedSamples | Measure-Object -Average).Average, 1)

                $sizeStr = if ($sizeGB -ge 1) { "${sizeGB} GB" } else { "${sizeMB} MB" }
                $speedStr = if ($avgSpeed -gt 0) { " @ ${avgSpeed} MB/s" } else { "" }
                Write-Host "`r     [>>] $sizeStr | $fileCount files | ${elapsed} elapsed${speedStr}        " -NoNewline -ForegroundColor Cyan

                $lastSize = $currentSize
                $lastFileCount = $fileCount
            }

            # Check completion
            $marker = Join-Path $MigrationFolder "capture-complete.flag"
            if (Test-Path $marker) {
                Write-Host ""
                Write-Host ""
                $sizeStr = if ($sizeGB -ge 1) { "${sizeGB} GB" } else { "${sizeMB} MB" }
                Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
                Write-Host "  |            CAPTURE COMPLETE - DATA RECEIVED           |" -ForegroundColor Green
                Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
                Write-Host ""
                Show-Detail "Final Size " $sizeStr
                Show-Detail "Files      " "$fileCount"
                Show-Detail "Duration   " $elapsed

                # Read source info from marker
                try {
                    $srcInfo = Get-Content $marker | ConvertFrom-Json
                    Show-Detail "Source PC  " $srcInfo.SourceComputer
                    Show-Detail "Captured   " $srcInfo.CaptureTime
                }
                catch {
                    Write-Log "Could not parse capture-complete.flag: $_" "WARN"
                }

                Write-Host ""
                Write-Host "     Ready to restore. Run:" -ForegroundColor Yellow
                Write-Host "       .\destination-setup.ps1 -RestoreOnly" -ForegroundColor White
                Write-Host ""
                break
            }
        }
        else {
            $elapsed = ((Get-Date) - $startWatch).ToString('hh\:mm\:ss')
            Write-Host "`r     [..] Waiting for data ($elapsed elapsed)...          " -NoNewline -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 5
    }
}

# ============================================================================
# USMT RESTORE WITH PROGRESS
# ============================================================================
# ----------------------------------------------------------------------------
# Build-LoadStateArguments
#   Pure function: constructs the loadstate.exe argument array from inputs.
#   No host output, no process launch, no $script: state read/write — safe for
#   direct unit tests. Preserves the exact argument order/format the original
#   inline code produced.
# ----------------------------------------------------------------------------
function Build-LoadStateArguments {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorePath,

        [Parameter(Mandatory = $true)]
        [string]$USMTDir,

        [Parameter(Mandatory = $true)]
        [string]$LogFile,

        [Parameter(Mandatory = $true)]
        [string]$ProgressFile,

        [int]$Verbosity = 5,

        [switch]$LocalAccountCreate,

        [switch]$LocalAccountEnable,

        [switch]$Continue,

        [string[]]$CustomXml = @(),

        [string]$DecryptionKey = $null
    )

    $loadArgs = @(
        "`"$StorePath`""
        "/i:`"$(Join-Path $USMTDir 'MigDocs.xml')`""
        "/i:`"$(Join-Path $USMTDir 'MigApp.xml')`""
        "/v:$Verbosity"
        "/l:`"$LogFile`""
        "/progress:`"$ProgressFile`""
    )

    if ($Continue) {
        $loadArgs += "/c"
    }
    if ($LocalAccountCreate) {
        $loadArgs += "/lac"
    }
    if ($LocalAccountEnable) {
        $loadArgs += "/lae"
    }

    foreach ($xml in $CustomXml) {
        if ($xml) {
            $loadArgs += "/i:`"$xml`""
        }
    }

    if ($DecryptionKey) {
        $loadArgs += "/decrypt /key:`"$DecryptionKey`""
    }

    return , $loadArgs
}

# ----------------------------------------------------------------------------
# ConvertFrom-LoadStateExitCode
#   Pure function: maps a loadstate.exe exit code to a structured result
#   hashtable. No host output, no $script: state. Safe for direct unit tests.
# ----------------------------------------------------------------------------
function ConvertFrom-LoadStateExitCode {
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
                Message        = 'Restore completed successfully'
                ShouldContinue = $true
            }
        }
        61 {
            return @{
                Code           = 61
                Severity       = 'Warning'
                Message        = 'Some items were not restored (non-fatal errors)'
                ShouldContinue = $true
            }
        }
        71 {
            return @{
                Code           = 71
                Severity       = 'Error'
                Message        = 'Restore was cancelled or the store was corrupt'
                ShouldContinue = $false
            }
        }
        default {
            return @{
                Code           = $ExitCode
                Severity       = 'Error'
                Message        = "Loadstate returned unexpected code $ExitCode"
                ShouldContinue = $false
            }
        }
    }
}

function Invoke-USMTRestore {
    Show-Banner "USMT RESTORE (LoadState)" "Cyan"

    $script:State.TotalSteps = 3
    $script:State.CurrentStep = 0
    $script:State.StartTime = Get-Date
    Set-MigrationUIState -State $script:State

    # Step 1: Verify USMT
    Show-Step "Verifying USMT installation"
    if (-not (Find-USMT)) {
        Show-Status "USMT not found" "FAIL"
        $installed = Install-USMT
        if (-not $installed) {
            Safe-Exit -Code 1 -Reason "Cannot restore without USMT - all install methods failed"
        }
    }
    try {
        $version = (Get-Item (Join-Path $script:State.USMTDir "loadstate.exe")).VersionInfo.FileVersion
    }
    catch {
        $version = "unknown"
        Write-Log "Could not read USMT version: $_" "WARN"
    }
    Show-Status "USMT ready: v$version" "OK"

    # Step 2: Verify migration data
    Show-Step "Validating migration store"
    $storePath = Join-Path $MigrationFolder "USMT"
    $storeFiles = Get-ChildItem -Path $storePath -Recurse -ErrorAction SilentlyContinue
    $migFiles = $storeFiles | Where-Object { $_.Extension -eq ".mig" }

    if (-not $migFiles) {
        Safe-Exit -Code 1 -Reason "No .mig files found in $storePath - ensure source PC capture completed first"
    }

    $storeSize = ($storeFiles | Measure-Object -Property Length -Sum).Sum
    $storeSizeMB = [math]::Round($storeSize / 1MB, 1)
    $storeSizeGB = [math]::Round($storeSize / 1GB, 2)
    $sizeStr = if ($storeSizeGB -ge 1) { "${storeSizeGB} GB" } else { "${storeSizeMB} MB" }
    Show-Status "Migration store: $sizeStr ($($migFiles.Count) .mig files)" "OK"

    # Step 3: Run LoadState
    Show-Step "Restoring user state (LoadState)"

    $loadstate = Join-Path $script:State.USMTDir "loadstate.exe"
    $logPath = Join-Path $MigrationFolder "Logs"
    if (-not (Test-Path $logPath)) { New-Item -Path $logPath -ItemType Directory -Force | Out-Null }
    $loadLog = Join-Path $logPath "loadstate.log"
    $loadProgress = Join-Path $logPath "loadstate-progress.log"

    $customXmls = @()
    $customXml = Join-Path $MigrationFolder "custom-migration.xml"
    if (Test-Path $customXml) {
        $customXmls += $customXml
        Show-Status "Including custom migration rules" "OK"
    }

    $loadArgs = Build-LoadStateArguments -StorePath $storePath -USMTDir $script:State.USMTDir `
        -LogFile $loadLog -ProgressFile $loadProgress -Verbosity 5 `
        -Continue -LocalAccountCreate -LocalAccountEnable `
        -CustomXml $customXmls

    Show-Status "Starting LoadState... (this may take a while)" "WAIT"
    Write-Log "LoadState command: $loadstate $($loadArgs -join ' ')"

    # Run LoadState with progress monitoring
    $restoreStart = Get-Date
    try {
        $process = Start-TrackedProcess -FilePath $loadstate -Arguments ($loadArgs -join ' ')
    }
    catch {
        Safe-Exit -Code 1 -Reason "Failed to launch LoadState ($loadstate): $_"
    }

    # Monitor progress file while LoadState runs
    while (-not $process.HasExited) {
        $elapsed = ((Get-Date) - $restoreStart).ToString('hh\:mm\:ss')
        if (Test-Path $loadProgress) {
            $lastLine = Get-Content $loadProgress -Tail 1 -ErrorAction SilentlyContinue
            if ($lastLine) {
                Write-Host "`r     [>>] Restoring... ($elapsed elapsed) $lastLine            " -NoNewline -ForegroundColor Cyan
            }
        }
        else {
            Write-Host "`r     [>>] Restoring... ($elapsed elapsed)                          " -NoNewline -ForegroundColor Cyan
        }
        Start-Sleep -Seconds 2
    }
    $process.WaitForExit()
    Write-Host ""

    $exitCode = $process.ExitCode
    $restoreDuration = ((Get-Date) - $restoreStart).ToString('hh\:mm\:ss')

    $result = ConvertFrom-LoadStateExitCode -ExitCode $exitCode
    $severityToStatus = @{ 'Success' = 'OK'; 'Warning' = 'WARN'; 'Error' = 'FAIL' }
    $severityToLog = @{ 'Success' = 'INFO'; 'Warning' = 'WARN'; 'Error' = 'ERROR' }
    $statusLevel = $severityToStatus[$result.Severity]
    $logLevel = $severityToLog[$result.Severity]

    if ($result.Code -eq 0) {
        Write-Host ""
        Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
        Write-Host "  |          RESTORE COMPLETED SUCCESSFULLY               |" -ForegroundColor Green
        Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
        Write-Host ""
    }
    else {
        Write-Host ""
        Show-Status $result.Message $statusLevel
    }
    Show-Detail "Duration" $restoreDuration
    Show-Detail "Log     " $loadLog

    Write-Log "LoadState finished, exit code: $exitCode, duration: $restoreDuration. $($result.Message)" $logLevel
    return $exitCode
}

# ============================================================================
# CLEANUP
# ============================================================================
function Remove-MigrationArtifacts {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Show-Banner "CLEANUP" "Yellow"

    if ($NonInteractive) {
        $confirm = 'Y'
    }
    else {
        $confirm = Read-Host "  Remove migration share, firewall rules, and optionally data? (Y/N)"
    }
    if ($confirm -ne 'Y') {
        Show-Status "Cleanup cancelled" "WARN"
        return
    }

    $localPSCmdlet = $PSCmdlet
    $cleanSteps = @(
        @{ Name = "SMB Share"; Action = {
                $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
                if ($share) {
                    if ($localPSCmdlet.ShouldProcess($ShareName, "Remove SMB share")) {
                        Remove-SmbShare -Name $ShareName -Force
                    }
                    return "Removed"
                }
                return "Not found"
            }
        },
        @{ Name = "Firewall Rule"; Action = {
                $rules = @(Get-NetFirewallRule -DisplayName "USMT-Migration-Inbound" -ErrorAction SilentlyContinue | Where-Object { $_ })
                if ($rules.Count -gt 0) {
                    if ($localPSCmdlet.ShouldProcess("USMT-Migration-Inbound", "Remove firewall rule")) {
                        Remove-NetFirewallRule -DisplayName "USMT-Migration-Inbound" -ErrorAction SilentlyContinue
                    }
                    return "Removed $($rules.Count) rule(s)"
                }
                return "Not found"
            }
        }
    )

    $i = 0
    foreach ($step in $cleanSteps) {
        $i++
        Show-ProgressBar $i $cleanSteps.Count "Cleaning"
        $result = & $step.Action
        Write-Host ""
        Show-Status "$($step.Name): $result" "OK"
    }

    if ($NonInteractive) {
        $removeData = 'Y'
    }
    else {
        $removeData = Read-Host "`n  Also delete migration data at $MigrationFolder? (Y/N)"
    }
    if ($removeData -eq 'Y') {
        $size = (Get-ChildItem -Path $MigrationFolder -Recurse -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        $sizeMB = [math]::Round($size / 1MB, 1)
        if ($PSCmdlet.ShouldProcess($MigrationFolder, "Remove migration folder recursively")) {
            Remove-Item -Path $MigrationFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        Show-Status "Removed $MigrationFolder (freed ~${sizeMB} MB)" "OK"
    }
    else {
        Show-Status "Data preserved at: $MigrationFolder" "WARN"
    }

    Write-Host ""
    Show-Status "Cleanup complete!" "OK"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
function Main {
    # Prevent sleep/screen-off during migration
    try {
        Add-Type 'using System; using System.Runtime.InteropServices; public static class MwPwrD { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f); }' -EA SilentlyContinue
        [MwPwrD]::SetThreadExecutionState(0x80000003) | Out-Null
    }
    catch {}

    Show-Banner "USMT MIGRATION - DESTINATION PC"

    # Handle modes
    if ($Cleanup) {
        Remove-MigrationArtifacts
        return
    }

    if ($RestoreOnly) {
        $logPath = Join-Path $MigrationFolder "Logs"
        if (-not (Test-Path $logPath)) { New-Item -Path $logPath -ItemType Directory -Force | Out-Null }
        $exitCode = Invoke-USMTRestore
        if ($exitCode -eq 0 -or $exitCode -eq 61) {
            Write-Host ""
            Show-Status "Migration restore finished! Run cleanup when ready:" "OK"
            Write-Host "       .\destination-setup.ps1 -Cleanup" -ForegroundColor White
            Write-Host ""
        }
        return
    }

    # Full setup flow
    Test-Prerequisites
    Initialize-USMT
    New-MigrationShare
    Set-MigrationFirewall

    if (Show-ConnectionInfo) {
        if ($NonInteractive) {
            # Non-interactive: auto-monitor, exit when capture completes
            Show-Status "Non-interactive mode: monitoring for incoming data..." "INFO"
            Watch-MigrationProgress
        }
        else {
            Write-Host "     [M] Monitor for incoming data   [Q] Quit (share stays active)" -ForegroundColor DarkGray
            Write-Host ""

            while ($true) {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    switch ($key.Key) {
                        'M' { Watch-MigrationProgress; return }
                        'Q' {
                            Show-Status "Share remains active. Run -RestoreOnly after capture." "OK"
                            return
                        }
                    }
                }
                Start-Sleep -Milliseconds 200
            }
        }
    }
}

# Run
$totalElapsed = { ((Get-Date) - $script:State.StartTime).ToString('hh\:mm\:ss') }
try {
    Main
}
catch {
    Show-Status "Fatal error: $_" "FAIL"
    Write-Log "FATAL: $_ `n $($_.ScriptStackTrace)" "FATAL"
    exit 1
}
finally {
    Write-Host ""
    Write-Host "  Total time: $(& $totalElapsed)" -ForegroundColor DarkGray
    Write-Log "Script finished. Total time: $(& $totalElapsed)"
    Stop-Logging
    Write-Host ""
}
