<#
.SYNOPSIS
    Post-migration verification - Reports what migrated and what needs manual attention.

.DESCRIPTION
    Run this script on the DESTINATION (new) PC AFTER destination-setup.ps1
    -RestoreOnly completes. It reads the pre-scan manifest captured on the
    source, compares it to the current state of the destination (user profiles,
    file counts, key application footprints, shell customisations), and prints
    a colour-coded PASS / WARN / FAIL / INFO report. The script is purely
    diagnostic - it never modifies system state. Individual checks are allowed
    to fail so the full report is always produced.
    Auto-elevates to Administrator via UAC if not already running elevated.

.PARAMETER MigrationFolder
    Path to the migration store to verify against. Defaults to
    C:\MigrationStore; when the caller accepts the default the value is
    realigned at runtime with MigrationConstants.Defaults.MigrationFolder so
    there is a single source of truth. Validation accepts an empty string,
    any absolute drive-letter path, or any existing directory.

.EXAMPLE
    PS> .\post-migration-verify.ps1

    Runs the standard report against C:\MigrationStore.

.EXAMPLE
    PS> .\post-migration-verify.ps1 -MigrationFolder 'D:\MigrationStore'

    Runs the report against a non-default store location (useful when
    destination-setup.ps1 was invoked with a custom -MigrationFolder).

.INPUTS
    None. This script does not accept piped input.

.OUTPUTS
    None (console report). Exit code 0 is always returned because the script
    is diagnostic; check the console output for FAIL entries. A verify log is
    written under the migration folder's Logs subdirectory.

.NOTES
    - Requires Administrator privileges (auto-elevates via UAC).
    - Run AFTER destination-setup.ps1 -RestoreOnly.
    - Safe to re-run; makes no system changes.

.LINK
    https://github.com/supermarsx/migration-merlin

.LINK
    .\destination-setup.ps1

.LINK
    .\source-capture.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Default kept as a literal so parameter metadata stays self-documenting.
    # Runtime value is re-aligned with $MigrationConstants.Defaults.MigrationFolder
    # right below so there is a single source of truth across the toolkit.
    # Phase 3 / t1-e12: validation attribute accepts the literal default,
    # any empty value (realigned below), and any existing directory.
    [ValidateScript({
        [string]::IsNullOrEmpty($_) -or
        ($_ -match '^[a-zA-Z]:\\') -or
        (Test-Path -LiteralPath $_ -PathType Container)
    })]
    [string]$MigrationFolder = "C:\MigrationStore"
)

# ---- Module imports / shared helpers ----
Import-Module "$PSScriptRoot\MigrationConstants.psm1" -Force
Import-Module "$PSScriptRoot\MigrationUI.psm1" -Force
Import-Module "$PSScriptRoot\MigrationValidators.psm1" -Force
Import-Module "$PSScriptRoot\ErrorHandling.psm1" -Force
. "$PSScriptRoot\Invoke-Elevated.ps1"
. "$PSScriptRoot\MigrationLogging.ps1"

# If the caller accepted the default literal, realign with the shared constant
# so a future change to the constant flows through without touching this file.
if (-not $PSBoundParameters.ContainsKey('MigrationFolder')) {
    $MigrationFolder = $MigrationConstants.Defaults.MigrationFolder
}

# ---- Auto-elevation ----
Request-Elevation -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# Continue rather than Stop - this is a reporting script; individual checks may legitimately fail
# and we want to see the full report anyway.
$ErrorActionPreference = "Continue"

$LogFile = Initialize-Logging -PrimaryLogFile (Join-Path $MigrationFolder "Logs\verify.log") -ScriptName "verify"
Write-Log "Post-migration verification started for folder: $MigrationFolder"
Write-Log "Parameters: $(Format-SafeParams $PSBoundParameters)"

# Validate migration folder exists
if (-not (Test-Path $MigrationFolder)) {
    Write-Host ""
    Write-Host "  WARNING: Migration folder not found at: $MigrationFolder" -ForegroundColor Red
    Write-Host "  If you used a custom -MigrationFolder during setup, specify it here:" -ForegroundColor Yellow
    Write-Host "    .\post-migration-verify.ps1 -MigrationFolder 'D:\YourPath'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Continuing with limited checks (no pre-scan comparison)..." -ForegroundColor DarkGray
    Write-Host ""
}

function Write-Result {
    param([string]$Check, [string]$Status, [string]$Detail = "")
    $color = switch ($Status) {
        "PASS" { "Green" }
        "WARN" { "Yellow" }
        "FAIL" { "Red" }
        "INFO" { "Cyan" }
        default { "White" }
    }
    $line = "  [{0,-4}] {1}" -f $Status, $Check
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line -ForegroundColor $color
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  Post-Migration Verification Report" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""

$preScanDir = Join-Path $MigrationFolder "PreScanData"
$hasPreScan = Test-Path $preScanDir

# ---- USER PROFILES ----
Write-Host "`n--- User Profiles ---" -ForegroundColor White
try {
    $destProfiles = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special -and $_.LocalPath -notlike "*systemprofile*" }
    foreach ($p in $destProfiles) {
        $user = Split-Path $p.LocalPath -Leaf
        if ($user -notin @("Public", "Default", "Default User", "All Users")) {
            Write-Result "Profile: $user" "PASS" "Exists at $($p.LocalPath)"
        }
    }
} catch {
    Write-Result "User profiles" "WARN" "Could not enumerate profiles: $_"
    Write-Log "User profile enumeration failed: $_" "WARN"
}

if ($hasPreScan) {
    $sourceInfo = Join-Path $preScanDir "SystemInfo.json"
    if (Test-Path $sourceInfo) {
        try {
            $srcInfo = Get-Content $sourceInfo -ErrorAction Stop | ConvertFrom-Json
            Write-Host "`n--- Source System Info ---" -ForegroundColor White
            Write-Result "Source PC" "INFO" "$($srcInfo.ComputerName) ($($srcInfo.OSVersion))"
            Write-Result "Captured" "INFO" $srcInfo.CaptureDate
        } catch {
            Write-Result "Source system info" "WARN" "Could not parse SystemInfo.json: $_"
            Write-Log "SystemInfo.json parse failed: $_" "WARN"
        }
    }
}

# ---- DOCUMENTS ----
Write-Host "`n--- User Documents ---" -ForegroundColor White
$docFolders = @("Documents", "Desktop", "Downloads", "Pictures", "Music", "Videos", "Favorites")
$currentUser = $env:USERNAME
foreach ($folder in $docFolders) {
    $path = Join-Path $env:USERPROFILE $folder
    if (Test-Path $path) {
        $count = (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Result "$folder" "PASS" "$count files"
    } else {
        Write-Result "$folder" "WARN" "Folder not found"
    }
}

# ---- BROWSER DATA ----
Write-Host "`n--- Browser Data ---" -ForegroundColor White
$chromeBm = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Bookmarks"
$edgeBm = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Bookmarks"
$ffProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"

if (Test-Path $chromeBm) { Write-Result "Chrome bookmarks" "PASS" }
else { Write-Result "Chrome bookmarks" "INFO" "Not present (Chrome may not be installed)" }

if (Test-Path $edgeBm) { Write-Result "Edge bookmarks" "PASS" }
else { Write-Result "Edge bookmarks" "INFO" "Not present" }

if (Test-Path $ffProfiles) { Write-Result "Firefox profiles" "PASS" }
else { Write-Result "Firefox profiles" "INFO" "Not present" }

# ---- OUTLOOK SIGNATURES ----
Write-Host "`n--- Outlook ---" -ForegroundColor White
$sigPath = "$env:APPDATA\Microsoft\Signatures"
if (Test-Path $sigPath) {
    $sigCount = (Get-ChildItem $sigPath -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Result "Outlook signatures" "PASS" "$sigCount files"
} else {
    Write-Result "Outlook signatures" "WARN" "Not found"
}

# ---- PRINTERS ----
Write-Host "`n--- Printers ---" -ForegroundColor White
$destPrinters = Get-Printer -ErrorAction SilentlyContinue
if ($destPrinters) {
    foreach ($p in $destPrinters) {
        Write-Result "Printer: $($p.Name)" "INFO" "Driver: $($p.DriverName)"
    }
}
if ($hasPreScan) {
    $srcPrinters = Join-Path $preScanDir "Printers.csv"
    if (Test-Path $srcPrinters) {
        try {
            $srcPrinterList = Import-Csv $srcPrinters -ErrorAction Stop
            $destPrinterNames = @()
            if ($destPrinters) { $destPrinterNames = $destPrinters | Select-Object -ExpandProperty Name }
            foreach ($sp in $srcPrinterList) {
                if ($sp.Name -notin $destPrinterNames) {
                    Write-Result "Printer: $($sp.Name)" "WARN" "Was on source but not found on destination"
                }
            }
        } catch {
            Write-Result "Printer comparison" "WARN" "Could not parse Printers.csv: $_"
            Write-Log "Printers.csv parse failed: $_" "WARN"
        }
    }
}

# ---- INSTALLED APPS COMPARISON ----
if ($hasPreScan) {
    Write-Host "`n--- Applications Needing Reinstall ---" -ForegroundColor White
    $srcApps = Join-Path $preScanDir "InstalledApps.csv"
    if (Test-Path $srcApps) {
        try {
            $sourceApps = Import-Csv $srcApps -ErrorAction Stop | Select-Object -ExpandProperty DisplayName -Unique
            $destApps = @()
            $regPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            foreach ($regPath in $regPaths) {
                $destApps += Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName } |
                    Select-Object -ExpandProperty DisplayName
            }
            $destApps = $destApps | Sort-Object -Unique

            $missing = $sourceApps | Where-Object { $_ -notin $destApps }
            if ($missing) {
                $missing | ForEach-Object { Write-Result $_ "WARN" "Not installed on destination" }
                Write-Host "`n  $($missing.Count) application(s) may need reinstalling." -ForegroundColor Yellow
            } else {
                Write-Result "All source apps found" "PASS"
            }
        } catch {
            Write-Result "App comparison" "WARN" "Could not compare apps: $_"
            Write-Log "App comparison failed: $_" "WARN"
        }
    }
}

# ---- DEVELOPER TOOLS ----
Write-Host "`n--- Developer Settings ---" -ForegroundColor White
$gitconfig = Join-Path $env:USERPROFILE ".gitconfig"
if (Test-Path $gitconfig) { Write-Result ".gitconfig" "PASS" }
else { Write-Result ".gitconfig" "WARN" "Not found" }

$sshConfig = Join-Path $env:USERPROFILE ".ssh\config"
if (Test-Path $sshConfig) { Write-Result "SSH config" "PASS" }
else { Write-Result "SSH config" "INFO" "Not present" }

$vsSettings = "$env:APPDATA\Code\User\settings.json"
if (Test-Path $vsSettings) { Write-Result "VSCode settings" "PASS" }
else { Write-Result "VSCode settings" "INFO" "Not present" }

# ---- WI-FI ----
Write-Host "`n--- Wi-Fi Profiles ---" -ForegroundColor White
$wifiResult = netsh wlan show profiles 2>$null
if ($wifiResult) {
    $wifiNames = ($wifiResult | Select-String "All User Profile\s+:\s+(.+)$").Matches |
        ForEach-Object { $_.Groups[1].Value.Trim() }
    $wifiNames | ForEach-Object { Write-Result "Wi-Fi: $_" "PASS" }

    if ($hasPreScan) {
        $srcWifi = Join-Path $preScanDir "WiFiProfiles.txt"
        if (Test-Path $srcWifi) {
            $srcWifiNames = (Get-Content $srcWifi | Select-String "All User Profile\s+:\s+(.+)$").Matches |
                ForEach-Object { $_.Groups[1].Value.Trim() }
            $missingWifi = $srcWifiNames | Where-Object { $_ -notin $wifiNames }
            $missingWifi | ForEach-Object { Write-Result "Wi-Fi: $_" "WARN" "Was on source, not on destination" }
        }
    }
} else {
    Write-Result "Wi-Fi" "INFO" "No wireless adapter found"
}

# ---- SUMMARY ----
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "  Verification Complete" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Items marked [WARN] may need manual attention." -ForegroundColor Yellow
Write-Host "  Items marked [INFO] are informational only." -ForegroundColor Cyan
Write-Host ""
if ($hasPreScan) {
    Write-Host "  Pre-scan data used from: $preScanDir" -ForegroundColor Gray
} else {
    Write-Host "  No pre-scan data found. Run source-capture.ps1 with pre-scan for full comparison." -ForegroundColor Gray
}
if ($LogFile) {
    Write-Host "  Log saved to: $LogFile" -ForegroundColor Gray
}
Write-Log "Verification complete"
Stop-Logging
Write-Host ""
