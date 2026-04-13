<#
.SYNOPSIS
    Post-migration verification script. Run on the DESTINATION PC after restore.
.DESCRIPTION
    Compares pre-scan data from the source with the current state of the destination,
    reporting what migrated successfully and what needs manual attention.
    Auto-elevates to Administrator if not already running elevated.
#>

param(
    [string]$MigrationFolder = "C:\MigrationStore"
)

# ---- Auto-elevation ----
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $_isAdmin) {
    Write-Host "`n  Requesting Administrator privileges...`n" -ForegroundColor Cyan
    $argList = @("-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($PSBoundParameters.ContainsKey('MigrationFolder')) {
        $argList += "-MigrationFolder"; $argList += "`"$MigrationFolder`""
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs -Wait
    } catch {
        Write-Host "  Elevation failed. Right-click and 'Run as Administrator'.`n" -ForegroundColor Red
        if ($Host.Name -notmatch 'ISE') { pause }
    }
    exit
}

$ErrorActionPreference = "Continue"

# Load shared logging infrastructure
. "$PSScriptRoot\MigrationLogging.ps1"
$LogFile = Initialize-Logging -PrimaryLogFile (Join-Path $MigrationFolder "Logs\verify.log") -ScriptName "verify"
Write-Log "Post-migration verification started for folder: $MigrationFolder"

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
