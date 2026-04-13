<#
.SYNOPSIS
    Source PC Capture - Captures user state via USMT and stores on destination share.
.DESCRIPTION
    Run this script on the SOURCE (old) PC AFTER the destination PC share is ready.
    It auto-downloads and installs USMT if needed, validates connectivity,
    captures user profiles with rich progress, and writes to the destination share.
    Auto-elevates to Administrator if not already running elevated.
.NOTES
    Must be run as Administrator (auto-elevates via UAC if needed).
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$DestinationShare = "",

    [string]$USMTPath = "",

    [string]$ShareUsername = "",
    [string]$SharePassword = "",

    [string[]]$IncludeUsers = @(),
    [string[]]$ExcludeUsers = @(),

    [switch]$ExtraData,
    [switch]$SkipConnectivityCheck,
    [switch]$SkipUSMTInstall,
    [switch]$DryRun,
    [switch]$EncryptStore,
    [string]$EncryptionKey = "",
    [Alias("Silent")]
    [switch]$NonInteractive
)

# ============================================================================
# AUTO-ELEVATION
# ============================================================================
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $_isAdmin) {
    Write-Host "`n  This script requires Administrator privileges." -ForegroundColor Yellow
    Write-Host "  Requesting elevation via UAC...`n" -ForegroundColor Cyan

    $paramStr = ""
    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [switch]) {
            if ($val.IsPresent) { $paramStr += " -$key" }
        } elseif ($val -is [array]) {
            $items = ($val | ForEach-Object { "`"$_`"" }) -join ","
            $paramStr += " -$key $items"
        } else {
            $paramStr += " -$key `"$val`""
        }
    }
    $argList = "-ExecutionPolicy Bypass -File `"$PSCommandPath`"$paramStr"

    try {
        $psExe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -Wait
    } catch {
        Write-Host "  Elevation cancelled or failed." -ForegroundColor Red
        Write-Host "  Right-click this script and select 'Run as Administrator'.`n" -ForegroundColor Yellow
        if ($Host.Name -notmatch 'ISE') { pause }
    }
    exit
}

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"

$LocalLogFolder = "$env:TEMP\MigrationMerlin"
$script:USMTDir = $null
$script:MappedDrive = $null
$script:ShareConnected = $false
$script:TotalSteps = 7
$script:CurrentStep = 0
$script:StartTime = Get-Date

# Bundled USMT zip (ships with the toolkit - preferred source)
$script:USMTZipName = "user-state-migration-tool.zip"
$script:USMTZipInternalRoot = "User State Migration Tool"

# Windows ADK download URL (online fallback)
$script:ADKInstallerUrl = "https://go.microsoft.com/fwlink/?linkid=2271337"
$script:ADKInstallerFile = "adksetup.exe"

# Load shared logging infrastructure
$_loggingPath = "$PSScriptRoot\MigrationLogging.ps1"
if (-not (Test-Path $_loggingPath)) {
    Write-Host "  FATAL: MigrationLogging.ps1 not found at: $_loggingPath" -ForegroundColor Red
    Write-Host "  Ensure all toolkit files are in the same directory." -ForegroundColor Yellow
    exit 1
}
. $_loggingPath
$LogFile = Initialize-Logging -PrimaryLogFile (Join-Path $LocalLogFolder "source-capture.log") -ScriptName "source-capture"
Write-Log "Script started with parameters: $($PSBoundParameters | ConvertTo-Json -Compress -Depth 1)"

# ============================================================================
# PROCESS LAUNCHER (mockable wrapper for reliable ExitCode)
# ============================================================================
function Start-TrackedProcess([string]$FilePath, [string]$Arguments) {
    <# Launches a process using System.Diagnostics.Process for reliable .ExitCode.
       Start-Process -PassThru has a known bug where ExitCode is empty after HasExited loop.
       Returns a [System.Diagnostics.Process] object. #>
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    return [System.Diagnostics.Process]::Start($psi)
}

# ============================================================================
# UI HELPERS
# ============================================================================
function Show-Banner {
    param([string]$Title, [ConsoleColor]$Color = "Magenta")
    $width = 56
    $pad = [math]::Max(0, [math]::Floor(($width - $Title.Length - 2) / 2))
    $line = "=" * $width
    Write-Host ""
    Write-Host "  $line" -ForegroundColor $Color
    Write-Host "  $(' ' * $pad) $Title $(' ' * $pad)" -ForegroundColor $Color
    Write-Host "  $line" -ForegroundColor $Color
    Write-Host ""
}

function Show-Step {
    param([string]$Description)
    $script:CurrentStep++
    $pct = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
    $elapsed = ((Get-Date) - $script:StartTime).ToString('mm\:ss')
    $barLen = 30
    $filled = [math]::Floor($barLen * $script:CurrentStep / $script:TotalSteps)
    $empty = $barLen - $filled
    $bar = ([char]0x2588).ToString() * $filled + ([char]0x2591).ToString() * $empty

    Write-Host ""
    Write-Host "  [$bar] $pct% " -NoNewline -ForegroundColor Cyan
    Write-Host "Step $($script:CurrentStep)/$($script:TotalSteps)" -NoNewline -ForegroundColor DarkGray
    Write-Host "  ($elapsed elapsed)" -ForegroundColor DarkGray
    Write-Host "  >> $Description" -ForegroundColor White
    Write-Host "  $('-' * 50)" -ForegroundColor DarkGray
}

function Show-Status {
    param([string]$Message, [string]$Level = "INFO")
    $icon = switch ($Level) {
        "OK"      { "[+]" }
        "FAIL"    { "[X]" }
        "WARN"    { "[!]" }
        "WAIT"    { "[~]" }
        "INFO"    { "[i]" }
        default   { "[.]" }
    }
    $color = switch ($Level) {
        "OK"      { "Green" }
        "FAIL"    { "Red" }
        "WARN"    { "Yellow" }
        "WAIT"    { "DarkCyan" }
        default   { "Gray" }
    }
    Write-Host "     $icon $Message" -ForegroundColor $color
}

function Show-Detail {
    param([string]$Label, [string]$Value)
    Write-Host "         $Label : " -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor White
}

function Show-ProgressBar {
    param([int]$Current, [int]$Total, [string]$Label, [string]$Detail = "")
    if ($Total -le 0) { return }
    $pct = [math]::Min(100, [math]::Round(($Current / $Total) * 100))
    $barLen = 35
    $filled = [math]::Floor($barLen * $pct / 100)
    $empty = $barLen - $filled
    $bar = ([char]0x2588).ToString() * $filled + ([char]0x2591).ToString() * $empty
    $line = "     [$bar] $pct% - $Label"
    if ($Detail) { $line += " ($Detail)" }
    Write-Host "`r$line    " -NoNewline -ForegroundColor Cyan
}

function Show-SubProgress {
    param([string]$Item, [int]$Index, [int]$Total)
    $pct = [math]::Round(($Index / $Total) * 100)
    Write-Host "`r         ($Index/$Total) $Item                              " -NoNewline -ForegroundColor DarkGray
}

# Write-Log is provided by MigrationLogging.ps1 (robust, with fallback paths)

# ============================================================================
# USMT DETECTION
# ============================================================================
function Find-USMT {
    if ($USMTPath -and (Test-Path $USMTPath)) {
        if (Test-Path (Join-Path $USMTPath "scanstate.exe")) {
            $script:USMTDir = $USMTPath
            return $true
        }
    }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" }
            elseif ([Environment]::Is64BitOperatingSystem) { "amd64" }
            else { "x86" }

    $searchPaths = @(
        "$PSScriptRoot\USMT-Tools"
        "$env:TEMP\USMT-Tools"
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        "C:\USMT"
        "C:\Tools\USMT"
    )

    foreach ($basePath in $searchPaths) {
        if (Test-Path $basePath) {
            $archPath = Join-Path $basePath $arch
            if (Test-Path (Join-Path $archPath "scanstate.exe")) {
                $script:USMTDir = $archPath
                return $true
            }
            if ($arch -eq "arm64") {
                $amd64Path = Join-Path $basePath "amd64"
                if (Test-Path (Join-Path $amd64Path "scanstate.exe")) {
                    $script:USMTDir = $amd64Path
                    return $true
                }
            }
            if (Test-Path (Join-Path $basePath "scanstate.exe")) {
                $script:USMTDir = $basePath
                return $true
            }
        }
    }

    return $false
}

# ============================================================================
# USMT EXTRACTION FROM BUNDLED ZIP
# ============================================================================
function Expand-BundledUSMT {
    $zipSearchPaths = @(
        (Join-Path $PSScriptRoot $script:USMTZipName)
        (Join-Path (Split-Path $PSScriptRoot -Parent) $script:USMTZipName)
        (Join-Path $env:TEMP $script:USMTZipName)
    )

    $zipPath = $null
    foreach ($p in $zipSearchPaths) {
        if (Test-Path $p) { $zipPath = $p; break }
    }
    if (-not $zipPath) { return $false }

    $zipSizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Show-Status "Found bundled USMT zip: $zipPath (${zipSizeMB} MB)" "OK"
    Write-Log "Found bundled USMT zip: $zipPath"

    $extractTarget = Join-Path $PSScriptRoot "USMT-Tools"
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" }
            elseif ([Environment]::Is64BitOperatingSystem) { "amd64" }
            else { "x86" }
    $archTarget = Join-Path $extractTarget $arch

    if (Test-Path (Join-Path $archTarget "scanstate.exe")) {
        Show-Status "USMT already extracted at: $archTarget" "OK"
        $script:USMTDir = $archTarget
        return $true
    }

    Show-Status "Extracting USMT ($arch) from zip..." "WAIT"
    Write-Log "Extracting USMT $arch from $zipPath to $extractTarget"

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $prefix = "$($script:USMTZipInternalRoot)/$arch/"
        $totalEntries = ($zip.Entries | Where-Object { $_.FullName.StartsWith($prefix) -and $_.Length -gt 0 }).Count
        $extracted = 0

        foreach ($entry in $zip.Entries) {
            if (-not $entry.FullName.StartsWith($prefix)) { continue }
            $relativePath = $entry.FullName.Substring($prefix.Length)
            if (-not $relativePath) { continue }
            $destPath = Join-Path $archTarget $relativePath

            if ($entry.FullName.EndsWith('/')) {
                if (-not (Test-Path $destPath)) { New-Item -Path $destPath -ItemType Directory -Force | Out-Null }
                continue
            }
            $parentDir = Split-Path $destPath -Parent
            if (-not (Test-Path $parentDir)) { New-Item -Path $parentDir -ItemType Directory -Force | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
            $extracted++
            if ($totalEntries -gt 0 -and ($extracted % 10 -eq 0 -or $extracted -eq $totalEntries)) {
                Show-ProgressBar $extracted $totalEntries "Extracting" "$extracted / $totalEntries files"
            }
        }
        $zip.Dispose()
        Write-Host ""

        if (Test-Path (Join-Path $archTarget "scanstate.exe")) {
            Show-Status "Extracted $extracted files to: $archTarget" "OK"
            $script:USMTDir = $archTarget
            return $true
        }
        Show-Status "Extraction completed but scanstate.exe not found" "FAIL"
        return $false
    } catch {
        Show-Status "Failed to extract USMT zip: $_" "FAIL"
        Write-Log "USMT zip extraction error: $_" "ERROR"
        return $false
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

# ============================================================================
# USMT ONLINE DOWNLOAD & INSTALL (fallback)
# ============================================================================
function Install-USMTOnline {
    Show-Status "Downloading Windows ADK (USMT component only)..." "WAIT"

    $downloadDir = Join-Path $env:TEMP "ADK-Download"
    if (-not (Test-Path $downloadDir)) { New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null }
    $installerPath = Join-Path $downloadDir $script:ADKInstallerFile

    try {
        Show-Status "Downloading ADK setup bootstrapper..." "WAIT"
        $downloaded = $false
        $downloadErrors = @()

        # Method 1: Invoke-WebRequest (most reliable in elevated contexts)
        if (-not $downloaded) {
            try {
                Show-Status "Trying Invoke-WebRequest..." "WAIT"
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $script:ADKInstallerUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) { $downloaded = $true }
                elseif (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue; throw "Downloaded file too small (likely error page)" }
            } catch { $downloadErrors += "Invoke-WebRequest: $_" }
        }

        # Method 2: System.Net.HttpClient (works without BITS service)
        if (-not $downloaded) {
            try {
                Show-Status "Trying HttpClient..." "WAIT"
                $handler = [System.Net.Http.HttpClientHandler]::new()
                $handler.UseDefaultCredentials = $true
                $client = [System.Net.Http.HttpClient]::new($handler)
                $client.DefaultRequestHeaders.Add("User-Agent", "Mozilla/5.0")
                $bytes = $client.GetByteArrayAsync($script:ADKInstallerUrl).GetAwaiter().GetResult()
                [System.IO.File]::WriteAllBytes($installerPath, $bytes)
                $client.Dispose()
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) { $downloaded = $true }
                elseif (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue; throw "Downloaded file too small (likely error page)" }
            } catch { $downloadErrors += "HttpClient: $_" }
        }

        # Method 3: BITS (often fails in elevated/service contexts)
        if (-not $downloaded -and (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) {
            try {
                Show-Status "Trying BITS transfer..." "WAIT"
                Start-BitsTransfer -Source $script:ADKInstallerUrl -Destination $installerPath -ErrorAction Stop
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) { $downloaded = $true }
                elseif (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue; throw "Downloaded file too small (likely error page)" }
            } catch { $downloadErrors += "BITS: $_" }
        }

        # Method 4: WebClient (legacy fallback)
        if (-not $downloaded) {
            try {
                Show-Status "Trying WebClient..." "WAIT"
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("User-Agent", "Mozilla/5.0")
                $wc.UseDefaultCredentials = $true
                $wc.DownloadFile($script:ADKInstallerUrl, $installerPath)
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) { $downloaded = $true }
                elseif (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue; throw "Downloaded file too small (likely error page)" }
            } catch { $downloadErrors += "WebClient: $_" }
        }

        if (-not $downloaded) {
            foreach ($e in $downloadErrors) { Write-Log "Download attempt failed: $e" "ERROR" }
            throw ($downloadErrors | Select-Object -Last 1)
        }

        $fileSize = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
        Show-Status "ADK installer downloaded (${fileSize} MB)" "OK"
    } catch {
        Show-Status "Download failed: $_" "FAIL"
        Show-Status "This often happens when UAC elevated to a different admin account" "INFO"
        Show-Status "Get ADK from: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" "INFO"
        return $false
    }

    try {
        Show-Status "Installing USMT component (this takes a few minutes)..." "WAIT"
        $installArgs = @("/quiet", "/norestart", "/features", "OptionId.UserStateMigrationTool", "/ceip", "off")
        $installStart = Get-Date
        $proc = Start-TrackedProcess -FilePath $installerPath -Arguments ($installArgs -join ' ')
        $frames = @('|','/','-','\')
        $i = 0
        while (-not $proc.HasExited) {
            $elapsed = ((Get-Date) - $installStart).ToString('mm\:ss')
            Write-Host "`r     [$($frames[$i % 4])] Installing USMT... ($elapsed elapsed)          " -NoNewline -ForegroundColor DarkCyan
            Start-Sleep -Milliseconds 300; $i++
        }
        $proc.WaitForExit(); Write-Host ""
        $installDuration = ((Get-Date) - $installStart).ToString('mm\:ss')

        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Show-Status "USMT installed ($installDuration)" "OK"
        } else {
            Show-Status "ADK installer exit code: $($proc.ExitCode)" "FAIL"
        }

        if (Find-USMT) { Show-Status "USMT verified at: $($script:USMTDir)" "OK"; return $true }
        Show-Status "USMT not found after install" "FAIL"
        return $false
    } catch {
        Show-Status "Installation failed: $_" "FAIL"
        return $false
    } finally {
        if (Test-Path $downloadDir) { Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Install-USMT {
    Show-Status "USMT not found on this system" "WARN"

    # Priority 1: Extract from bundled zip
    Show-Status "Checking for bundled USMT zip..." "WAIT"
    if (Expand-BundledUSMT) { return $true }

    # Priority 2: Download ADK online
    Show-Status "Bundled zip not found - trying online download..." "WARN"
    return Install-USMTOnline
}

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
# USMT DETECTION + AUTO-INSTALL
# ============================================================================
function Initialize-USMT {
    Show-Step "Locating USMT tools"

    if (Find-USMT) {
        $version = (Get-Item (Join-Path $script:USMTDir "scanstate.exe")).VersionInfo.FileVersion
        Show-Status "USMT found: $($script:USMTDir)" "OK"
        Show-Detail "Version" $version
        Write-Log "USMT found at $($script:USMTDir), version $version"
        return $true
    }

    if ($SkipUSMTInstall) {
        Show-Status "USMT not found and -SkipUSMTInstall specified" "FAIL"
        return $false
    }

    $installed = Install-USMT
    if (-not $installed) {
        Show-Status "USMT is required for migration. Options:" "FAIL"
        Show-Status "  1. Install Windows ADK manually with USMT" "INFO"
        Show-Status "  2. Copy USMT binaries to C:\USMT" "INFO"
        Show-Status "  3. Specify path with -USMTPath" "INFO"
    }
    return $installed
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
        Write-Host "     (e.g., \\DEST-PC\MigrationShare`$):" -ForegroundColor Yellow
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
        if ($ShareUsername -and $SharePassword) {
            $netArgs += "/user:$ShareUsername"
            $netArgs += $SharePassword
            Show-Status "Using provided credentials" "INFO"
        }
        $netArgs += "/persistent:no"

        $result = & net @netArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "net use failed: $result" }

        $script:MappedDrive = "${driveLetter}:"
        $script:ShareConnected = $true
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
                Copy-Item -Path $item.Src -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host ""
                Show-Status "$($item.Name) backed up" "OK"
            } catch {
                Write-Host ""
                Show-Status "$($item.Name) skipped: $_" "WARN"
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
function Invoke-USMTCapture {
    param([string[]]$Profiles)

    Show-Step "Capturing user state (USMT ScanState)"

    $storePath = Join-Path "$($script:MappedDrive)\" "USMT"
    if (-not (Test-Path $storePath)) {
        New-Item -Path $storePath -ItemType Directory -Force | Out-Null
    }

    $scanstate = Join-Path $script:USMTDir "scanstate.exe"
    $logPath = Join-Path "$($script:MappedDrive)\" "Logs"
    if (-not (Test-Path $logPath)) {
        New-Item -Path $logPath -ItemType Directory -Force | Out-Null
    }
    $scanLog = Join-Path $logPath "scanstate.log"
    $scanProgress = Join-Path $logPath "scanstate-progress.log"

    # Build arguments
    $scanArgs = @(
        "`"$storePath`""
        "/i:`"$(Join-Path $script:USMTDir 'MigDocs.xml')`""
        "/i:`"$(Join-Path $script:USMTDir 'MigApp.xml')`""
        "/v:5"
        "/l:`"$scanLog`""
        "/progress:`"$scanProgress`""
        "/c"
        "/o"
        "/vsc"
        "/efs:copyraw"
    )

    # Custom XML
    $customXml = Join-Path $PSScriptRoot "custom-migration.xml"
    if (Test-Path $customXml) {
        Copy-Item $customXml -Destination "$($script:MappedDrive)\" -Force
        $scanArgs += "/i:`"$customXml`""
        Show-Status "Custom migration rules included" "OK"
    }

    # User selection — resolve actual domain\user from SID for accurate USMT filtering
    if ($Profiles.Count -gt 0) {
        # Build a lookup of short-username → full DOMAIN\username from Win32_UserProfile SIDs
        $allWmiProfiles = Get-CimInstance Win32_UserProfile |
            Where-Object { -not $_.Special -and $_.LocalPath }
        $resolvedMap = @{}
        foreach ($wp in $allWmiProfiles) {
            $short = Split-Path $wp.LocalPath -Leaf
            try {
                $ntAccount = (New-Object System.Security.Principal.SecurityIdentifier($wp.SID)).Translate(
                    [System.Security.Principal.NTAccount]).Value
                $resolvedMap[$short] = $ntAccount
            } catch {
                # Fallback: try common domain prefixes
                $resolvedMap[$short] = "$env:USERDOMAIN\$short"
            }
        }

        # /ui: for each selected user (with resolved domain)
        foreach ($user in $Profiles) {
            $fullName = if ($resolvedMap.ContainsKey($user)) { $resolvedMap[$user] } else { "$env:USERDOMAIN\$user" }
            $scanArgs += "/ui:`"$fullName`""
            # Also add with wildcard domain in case of domain/local mismatch
            $scanArgs += "/ui:`"*\$user`""
            Write-Log "Include user: $fullName (and *\$user)"
        }

        # /ue: for every non-selected user (belt + suspenders)
        $allShortNames = $allWmiProfiles | ForEach-Object { Split-Path $_.LocalPath -Leaf } |
            Where-Object { $_ -notin @('Public','Default','Default User','All Users') }
        foreach ($name in $allShortNames) {
            if ($name -notin $Profiles) {
                $fullName = if ($resolvedMap.ContainsKey($name)) { $resolvedMap[$name] } else { "$env:USERDOMAIN\$name" }
                $scanArgs += "/ue:`"$fullName`""
                $scanArgs += "/ue:`"*\$name`""
                Write-Log "Exclude user: $fullName (and *\$name)"
            }
        }

        # Always exclude system accounts
        $scanArgs += '/ue:"NT AUTHORITY\*"'
        $scanArgs += '/ue:"BUILTIN\*"'
        Show-Status "Users: $($Profiles -join ', ')" "OK"
    }

    # Encryption
    if ($EncryptStore) {
        if (-not $EncryptionKey) {
            if ($NonInteractive) {
                Safe-Exit -Code 1 -Reason "No -EncryptionKey provided and running non-interactive (required with -EncryptStore)"
            }
            $EncryptionKey = Read-Host "     Enter encryption key"
        }
        $scanArgs += "/encrypt /key:`"$EncryptionKey`""
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

    # Launch ScanState
    $scanStart = Get-Date
    try {
        $process = Start-TrackedProcess -FilePath $scanstate -Arguments ($scanArgs -join ' ')
    } catch {
        Safe-Exit -Code 1 -Reason "Failed to launch ScanState ($scanstate): $_"
    }

    # Live progress monitoring
    $lastSize = 0
    $lastFileCount = 0
    $speedSamples = @()
    $lastCheck = Get-Date
    $frames = @([char]0x2588, [char]0x2593, [char]0x2592, [char]0x2591)
    $frameIdx = 0

    while (-not $process.HasExited) {
        $elapsed = ((Get-Date) - $scanStart).ToString('hh\:mm\:ss')
        $frameIdx++

        if (Test-Path $storePath) {
            $items = Get-ChildItem -Path $storePath -Recurse -ErrorAction SilentlyContinue
            $currentSize = ($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if (-not $currentSize) { $currentSize = 0 }
            $fileCount = ($items | Measure-Object).Count

            $sizeMB = [math]::Round($currentSize / 1MB, 1)
            $sizeGB = [math]::Round($currentSize / 1GB, 2)
            $sizeStr = if ($sizeGB -ge 1) { "${sizeGB} GB" } else { "${sizeMB} MB" }

            # Speed calculation
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

            # Progress line from USMT progress file
            $usmtProgress = ""
            if (Test-Path $scanProgress) {
                $lastLine = Get-Content $scanProgress -Tail 1 -ErrorAction SilentlyContinue
                if ($lastLine -and $lastLine.Length -gt 0) {
                    # Truncate long lines
                    if ($lastLine.Length -gt 40) { $lastLine = $lastLine.Substring(0, 37) + "..." }
                    $usmtProgress = " | $lastLine"
                }
            }

            # Animated spinner
            $spin = $frames[$frameIdx % $frames.Count]
            Write-Host "`r     [$spin] $sizeStr | $fileCount files | ${elapsed}${speedStr}${usmtProgress}              " -NoNewline -ForegroundColor Cyan
        } else {
            $spin = $frames[$frameIdx % $frames.Count]
            Write-Host "`r     [$spin] Initializing ScanState... ($elapsed)              " -NoNewline -ForegroundColor DarkCyan
        }

        Start-Sleep -Seconds 2
    }
    $process.WaitForExit()
    Write-Host ""

    $exitCode = $process.ExitCode
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
            Show-Status "ScanState exited with code: $exitCode" "FAIL"
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
    $marker = Join-Path "$($script:MappedDrive)\" "capture-complete.flag"
    $completionInfo = @{
        SourceComputer = $env:COMPUTERNAME
        SourceDomain   = $env:USERDOMAIN
        CaptureTime    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        USMTVersion    = (Get-Item (Join-Path $script:USMTDir "scanstate.exe")).VersionInfo.FileVersion
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

    if ($ExtraData) { $script:TotalSteps = 8 }

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
        Export-PreScanData -OutputPath "$($script:MappedDrive)\"

        # Step 6: Extra data (optional)
        if ($ExtraData) {
            Backup-ExtraData -OutputPath "$($script:MappedDrive)\"
        }

        # Step 7: ScanState
        $exitCode = Invoke-USMTCapture -Profiles $profiles

        # Step 8: Finalize
        $script:CurrentStep = $script:TotalSteps
        $pct = 100
        $elapsed = ((Get-Date) - $script:StartTime).ToString('mm\:ss')
        $barLen = 30
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
            Copy-Item $LogFile -Destination (Join-Path "$($script:MappedDrive)\" "Logs") -Force -ErrorAction SilentlyContinue
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
    if ($script:MappedDrive -and $script:ShareConnected) {
        try {
            $result = Invoke-SafeCommand -Command "net" -Arguments @("use", $script:MappedDrive, "/delete", "/yes") -OperationName "Drive disconnect" -SuppressStderr
            if ($result.Success) {
                Show-Status "Drive $($script:MappedDrive) disconnected" "OK"
                Write-Log "Disconnected drive $($script:MappedDrive)"
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
$totalElapsed = { ((Get-Date) - $script:StartTime).ToString('hh\:mm\:ss') }
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
