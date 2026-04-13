<#
.SYNOPSIS
    Destination PC Setup - Creates a migration share and prepares for USMT restore.
.DESCRIPTION
    Run this script on the DESTINATION (new) PC FIRST.
    It auto-downloads and installs USMT if not present, creates a network share
    for the source PC to write migration data to, configures firewall rules,
    and provides a restore function once capture is complete.
    Auto-elevates to Administrator if not already running elevated.
.NOTES
    Must be run as Administrator (auto-elevates via UAC if needed).
#>

param(
    [string]$MigrationFolder = "C:\MigrationStore",
    [string]$ShareName = "MigrationShare$",
    [string]$USMTPath = "",
    [string]$AllowedSourceIP = "",
    [switch]$RestoreOnly,
    [switch]$Cleanup,
    [switch]$SkipUSMTInstall,
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

    # Rebuild argument list from bound parameters
    # Build a single command string for -ArgumentList (avoids array escaping issues)
    $paramStr = ""
    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [switch]) {
            if ($val.IsPresent) { $paramStr += " -$key" }
        } elseif ($val -is [array]) {
            # Pass each array element as a quoted, comma-separated list
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

$script:USMTDir = $null
$script:TotalSteps = 5
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
$LogFile = Initialize-Logging -PrimaryLogFile (Join-Path $MigrationFolder "destination-setup.log") -ScriptName "destination-setup"
Write-Log "Script started with parameters: $($PSBoundParameters | ConvertTo-Json -Compress -Depth 1)"

# ============================================================================
# PROCESS LAUNCHER (mockable wrapper for reliable ExitCode)
# ============================================================================
function Start-TrackedProcess([string]$FilePath, [string]$Arguments) {
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

function Show-Spinner {
    param([string]$Message, [scriptblock]$Action)
    $frames = @('|','/','-','\')
    $job = Start-Job -ScriptBlock $Action
    $i = 0
    while ($job.State -eq 'Running') {
        $frame = $frames[$i % $frames.Count]
        Write-Host "`r     [$frame] $Message..." -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Milliseconds 150
        $i++
    }
    $result = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Write-Host "`r     [+] $Message   " -ForegroundColor Green
    return $result
}

# Write-Log is provided by MigrationLogging.ps1 (robust, with fallback paths)

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

# ============================================================================
# USMT DETECTION
# ============================================================================
function Find-USMT {
    param([string]$ExeName = "loadstate.exe")

    # Check user-supplied path first
    if ($USMTPath -and (Test-Path $USMTPath)) {
        $exe = Join-Path $USMTPath $ExeName
        if (Test-Path $exe) {
            $script:USMTDir = $USMTPath
            return $true
        }
    }

    # Determine architecture
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "x86" }
    # On ARM64, prefer arm64 if available
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $arch = "arm64" }

    # Common USMT locations (including where we extract the bundled zip)
    $searchPaths = @(
        "$MigrationFolder\USMT-Tools"
        "$PSScriptRoot\USMT-Tools"
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        "C:\USMT"
        "C:\Tools\USMT"
    )

    foreach ($basePath in $searchPaths) {
        if (Test-Path $basePath) {
            $archPath = Join-Path $basePath $arch
            if (Test-Path (Join-Path $archPath $ExeName)) {
                $script:USMTDir = $archPath
                return $true
            }
            # Fallback: try amd64 on ARM64 systems
            if ($arch -eq "arm64") {
                $amd64Path = Join-Path $basePath "amd64"
                if (Test-Path (Join-Path $amd64Path $ExeName)) {
                    $script:USMTDir = $amd64Path
                    return $true
                }
            }
            if (Test-Path (Join-Path $basePath $ExeName)) {
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
    <# Extracts USMT from the bundled user-state-migration-tool.zip.
       Returns $true if extraction succeeded and USMT is usable. #>

    $zipSearchPaths = @(
        (Join-Path $PSScriptRoot $script:USMTZipName)
        (Join-Path (Split-Path $PSScriptRoot -Parent) $script:USMTZipName)
    )
    if (Test-Path $MigrationFolder) {
        $zipSearchPaths += (Join-Path $MigrationFolder $script:USMTZipName)
    }

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

    if (Test-Path (Join-Path $archTarget "loadstate.exe")) {
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

        if (Test-Path (Join-Path $archTarget "loadstate.exe")) {
            Show-Status "Extracted $extracted files to: $archTarget" "OK"
            Write-Log "USMT extracted: $extracted files to $archTarget"
            $script:USMTDir = $archTarget
            return $true
        }
        Show-Status "Extraction completed but loadstate.exe not found" "FAIL"
        Write-Log "USMT extraction failed - loadstate.exe missing" "ERROR"
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
    Write-Log "Starting USMT online install via Windows ADK"

    $downloadDir = Join-Path $env:TEMP "ADK-Download"
    if (-not (Test-Path $downloadDir)) {
        New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null
    }
    $installerPath = Join-Path $downloadDir $script:ADKInstallerFile

    # Download the ADK online installer (multiple methods for elevated contexts)
    try {
        Show-Status "Downloading ADK installer..." "WAIT"
        $downloaded = $false
        $downloadErrors = @()

        # Method 1: Invoke-WebRequest (most reliable in elevated contexts)
        if (-not $downloaded) {
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $script:ADKInstallerUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) { $downloaded = $true }
                elseif (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue; throw "Downloaded file too small (likely error page)" }
            } catch { $downloadErrors += "Invoke-WebRequest: $_" }
        }

        # Method 2: System.Net.HttpClient
        if (-not $downloaded) {
            try {
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
                Start-BitsTransfer -Source $script:ADKInstallerUrl -Destination $installerPath -ErrorAction Stop
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) { $downloaded = $true }
                elseif (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue; throw "Downloaded file too small (likely error page)" }
            } catch { $downloadErrors += "BITS: $_" }
        }

        # Method 4: WebClient (legacy fallback)
        if (-not $downloaded) {
            try {
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
        Write-Log "ADK installer downloaded: $installerPath ($fileSize MB)"
    } catch {
        Show-Status "Failed to download ADK: $_" "FAIL"
        Show-Status "This often happens when UAC elevated to a different admin account" "INFO"
        Show-Status "Download manually from: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" "INFO"
        Write-Log "ADK download failed: $_" "ERROR"
        return $false
    }

    # Install USMT component only (silent)
    try {
        Show-Status "Installing USMT (this may take a few minutes)..." "WAIT"
        $installArgs = @("/quiet", "/norestart", "/features", "OptionId.UserStateMigrationTool", "/ceip", "off")
        Show-Status "Running: adksetup.exe /quiet /features OptionId.UserStateMigrationTool" "INFO"

        $installStart = Get-Date
        $proc = Start-TrackedProcess -FilePath $installerPath -Arguments ($installArgs -join ' ')
        $frames = @('|','/','-','\')
        $i = 0
        while (-not $proc.HasExited) {
            $elapsed = ((Get-Date) - $installStart).ToString('mm\:ss')
            $frame = $frames[$i % $frames.Count]
            Write-Host "`r     [$frame] Installing USMT... ($elapsed elapsed)          " -NoNewline -ForegroundColor DarkCyan
            Start-Sleep -Milliseconds 300
            $i++
        }
        $proc.WaitForExit()
        Write-Host ""
        $installDuration = ((Get-Date) - $installStart).ToString('mm\:ss')

        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Show-Status "USMT installed ($installDuration)" "OK"
            Write-Log "ADK/USMT installed, exit code: $($proc.ExitCode)"
        } else {
            Show-Status "ADK installer exited with code: $($proc.ExitCode)" "FAIL"
            Write-Log "ADK installer failed, exit code: $($proc.ExitCode)" "ERROR"
        }

        if (Find-USMT) {
            Show-Status "USMT verified at: $($script:USMTDir)" "OK"
            return $true
        }
        Show-Status "USMT binaries not found after install" "FAIL"
        return $false
    } catch {
        Show-Status "USMT installation failed: $_" "FAIL"
        Write-Log "USMT installation failed: $_" "ERROR"
        return $false
    } finally {
        if (Test-Path $downloadDir) {
            Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-USMT {
    <# Tries bundled zip first, then falls back to online ADK download. #>
    Show-Status "USMT not found on this system" "WARN"

    # Priority 1: Extract from bundled zip
    Show-Status "Checking for bundled USMT zip..." "WAIT"
    if (Expand-BundledUSMT) {
        return $true
    }

    # Priority 2: Download ADK online
    Show-Status "Bundled zip not found - trying online download..." "WARN"
    return Install-USMTOnline
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
    } else {
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
            } else {
                Show-Status "Disk space OK (${freeGB} GB free)" "OK"
            }
        } else {
            Show-Status "Could not check disk space for $drive" "WARN"
            Write-Log "Disk space check failed for $drive" "WARN"
        }
    } catch {
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
            } else {
                Safe-Exit -Code 1 -Reason "No active network adapters found"
            }
        }

        $ipAddresses = @()
        try {
            $ipAddresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
                Select-Object -ExpandProperty IPAddress
        } catch {
            Write-Log "Get-NetIPAddress failed, falling back to hostname resolution" "WARN"
            $ipAddresses = @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                Select-Object -ExpandProperty IPAddressToString)
        }
        foreach ($ip in $ipAddresses) {
            Show-Status "Network: $ip" "OK"
        }
        Write-Log "IPs: $($ipAddresses -join ', ')"
    } catch {
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
        $version = (Get-Item (Join-Path $script:USMTDir "loadstate.exe")).VersionInfo.FileVersion
        Show-Status "USMT found: $($script:USMTDir)" "OK"
        Show-Detail "Version" $version
        Write-Log "USMT found at $($script:USMTDir), version $version"
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
    Show-Step "Creating migration share"

    # Create folder structure
    try {
        if (-not (Test-Path $MigrationFolder)) {
            New-Item -Path $MigrationFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Show-Status "Created: $MigrationFolder" "OK"
            Write-Log "Created migration folder: $MigrationFolder"
        } else {
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
    } catch {
        Safe-Exit -Code 1 -Reason "Failed to create migration folder structure: $_"
    }

    # NTFS permissions
    try {
        $acl = Get-Acl $MigrationFolder
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Everyone", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.SetAccessRule($rule)
        Set-Acl -Path $MigrationFolder -AclObject $acl
        Show-Status "NTFS permissions set (Everyone: Full Control)" "OK"
    } catch {
        Show-Status "Could not set NTFS permissions: $_ (share may still work)" "WARN"
        Write-Log "NTFS permission set failed: $_" "WARN"
    }

    # Remove existing share
    try {
        $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
        if ($existingShare) {
            Remove-SmbShare -Name $ShareName -Force -ErrorAction Stop
            Show-Status "Removed existing share" "WARN"
            Write-Log "Removed existing share: $ShareName"
        }
    } catch {
        Show-Status "Could not remove existing share: $_" "WARN"
        Write-Log "Remove existing share failed: $_" "WARN"
    }

    # Create SMB share
    try {
        New-SmbShare -Name $ShareName -Path $MigrationFolder -FullAccess "Everyone" `
            -Description "USMT Migration Store - Temporary" -ErrorAction Stop | Out-Null
        Grant-SmbShareAccess -Name $ShareName -AccountName "Everyone" `
            -AccessRight Full -Force -ErrorAction Stop | Out-Null
        Show-Status "Share created: \\$env:COMPUTERNAME\$ShareName" "OK"
        Write-Log "Share created: \\$env:COMPUTERNAME\$ShareName -> $MigrationFolder"
    } catch {
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
            } else {
                Safe-Exit -Code 1 -Reason "Failed to create share. net share exit code: $($netResult.ExitCode)"
            }
        } catch {
            Safe-Exit -Code 1 -Reason "All share creation methods failed: $_"
        }
    }
}

# ============================================================================
# FIREWALL CONFIGURATION
# ============================================================================
function Set-MigrationFirewall {
    Show-Step "Configuring firewall"

    # File and Printer Sharing
    try {
        $fpsRules = Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" -ErrorAction SilentlyContinue
        if ($fpsRules) {
            $fpsRules | Set-NetFirewallRule -Enabled True -ErrorAction Stop
            Show-Status "Enabled: File and Printer Sharing" "OK"
        }
    } catch {
        Show-Status "Could not enable File and Printer Sharing: $_" "WARN"
        Write-Log "File and Printer Sharing enable failed: $_" "WARN"
        # Fallback: try netsh
        $netshResult = Invoke-SafeCommand "netsh" @("advfirewall","firewall","set","rule","group=File and Printer Sharing","new","enable=Yes") -OperationName "netsh FPS enable" -SuppressStderr
        if ($netshResult.Success) { Show-Status "Enabled FPS via netsh fallback" "OK" }
    }

    # Custom migration rule
    $ruleName = "USMT-Migration-Inbound"
    try {
        $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($existingRule) { Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop }
    } catch {
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
        New-NetFirewallRule @ruleParams -ErrorAction Stop | Out-Null
        Show-Status "Migration firewall rule created (TCP 445, 139)" "OK"
    } catch {
        Show-Status "Could not create firewall rule: $_" "WARN"
        Write-Log "Firewall rule creation failed: $_" "WARN"
        # Fallback: try netsh
        $netshResult = Invoke-SafeCommand "netsh" @("advfirewall","firewall","add","rule","name=$ruleName","dir=in","action=allow","protocol=tcp","localport=445,139") -OperationName "netsh rule add" -SuppressStderr
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
    } catch {
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
    } catch {
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
    } catch {
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
    if ($script:USMTDir) {
        Show-Detail "USMT Path    " $script:USMTDir
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
                } catch {
                    Write-Log "Could not parse capture-complete.flag: $_" "WARN"
                }

                Write-Host ""
                Write-Host "     Ready to restore. Run:" -ForegroundColor Yellow
                Write-Host "       .\destination-setup.ps1 -RestoreOnly" -ForegroundColor White
                Write-Host ""
                break
            }
        } else {
            $elapsed = ((Get-Date) - $startWatch).ToString('hh\:mm\:ss')
            Write-Host "`r     [..] Waiting for data ($elapsed elapsed)...          " -NoNewline -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 5
    }
}

# ============================================================================
# USMT RESTORE WITH PROGRESS
# ============================================================================
function Invoke-USMTRestore {
    Show-Banner "USMT RESTORE (LoadState)" "Cyan"

    $script:TotalSteps = 3
    $script:CurrentStep = 0
    $script:StartTime = Get-Date

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
        $version = (Get-Item (Join-Path $script:USMTDir "loadstate.exe")).VersionInfo.FileVersion
    } catch {
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

    $loadstate = Join-Path $script:USMTDir "loadstate.exe"
    $logPath = Join-Path $MigrationFolder "Logs"
    if (-not (Test-Path $logPath)) { New-Item -Path $logPath -ItemType Directory -Force | Out-Null }
    $loadLog = Join-Path $logPath "loadstate.log"
    $loadProgress = Join-Path $logPath "loadstate-progress.log"

    $loadArgs = @(
        "`"$storePath`""
        "/i:`"$(Join-Path $script:USMTDir 'MigDocs.xml')`""
        "/i:`"$(Join-Path $script:USMTDir 'MigApp.xml')`""
        "/v:5"
        "/l:`"$loadLog`""
        "/progress:`"$loadProgress`""
        "/c"
        "/lac"
        "/lae"
    )

    $customXml = Join-Path $MigrationFolder "custom-migration.xml"
    if (Test-Path $customXml) {
        $loadArgs += "/i:`"$customXml`""
        Show-Status "Including custom migration rules" "OK"
    }

    Show-Status "Starting LoadState... (this may take a while)" "WAIT"
    Write-Log "LoadState command: $loadstate $($loadArgs -join ' ')"

    # Run LoadState with progress monitoring
    $restoreStart = Get-Date
    try {
        $process = Start-TrackedProcess -FilePath $loadstate -Arguments ($loadArgs -join ' ')
    } catch {
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
        } else {
            Write-Host "`r     [>>] Restoring... ($elapsed elapsed)                          " -NoNewline -ForegroundColor Cyan
        }
        Start-Sleep -Seconds 2
    }
    $process.WaitForExit()
    Write-Host ""

    $exitCode = $process.ExitCode
    $restoreDuration = ((Get-Date) - $restoreStart).ToString('hh\:mm\:ss')

    switch ($exitCode) {
        0 {
            Write-Host ""
            Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
            Write-Host "  |          RESTORE COMPLETED SUCCESSFULLY               |" -ForegroundColor Green
            Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
            Write-Host ""
            Show-Detail "Duration" $restoreDuration
            Show-Detail "Log     " $loadLog
        }
        61 {
            Write-Host ""
            Show-Status "Restore completed with some items skipped (non-critical)" "WARN"
            Show-Detail "Duration" $restoreDuration
            Show-Detail "Log     " $loadLog
        }
        71 {
            Show-Status "Restore was cancelled or store is corrupted" "FAIL"
        }
        default {
            Show-Status "LoadState exited with code: $exitCode" "FAIL"
            Show-Detail "Check log" $loadLog
        }
    }

    Write-Log "LoadState finished, exit code: $exitCode, duration: $restoreDuration"
    return $exitCode
}

# ============================================================================
# CLEANUP
# ============================================================================
function Remove-MigrationArtifacts {
    Show-Banner "CLEANUP" "Yellow"

    if ($NonInteractive) {
        $confirm = 'Y'
    } else {
        $confirm = Read-Host "  Remove migration share, firewall rules, and optionally data? (Y/N)"
    }
    if ($confirm -ne 'Y') {
        Show-Status "Cleanup cancelled" "WARN"
        return
    }

    $cleanSteps = @(
        @{ Name = "SMB Share"; Action = {
            $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
            if ($share) { Remove-SmbShare -Name $ShareName -Force; return "Removed" }
            return "Not found"
        }},
        @{ Name = "Firewall Rule"; Action = {
            $rules = @(Get-NetFirewallRule -DisplayName "USMT-Migration-Inbound" -ErrorAction SilentlyContinue | Where-Object { $_ })
            if ($rules.Count -gt 0) { Remove-NetFirewallRule -DisplayName "USMT-Migration-Inbound" -ErrorAction SilentlyContinue; return "Removed $($rules.Count) rule(s)" }
            return "Not found"
        }}
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
    } else {
        $removeData = Read-Host "`n  Also delete migration data at $MigrationFolder? (Y/N)"
    }
    if ($removeData -eq 'Y') {
        $size = (Get-ChildItem -Path $MigrationFolder -Recurse -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $sizeMB = [math]::Round($size / 1MB, 1)
        Remove-Item -Path $MigrationFolder -Recurse -Force -ErrorAction SilentlyContinue
        Show-Status "Removed $MigrationFolder (freed ~${sizeMB} MB)" "OK"
    } else {
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
    } catch {}

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
        } else {
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
$totalElapsed = { ((Get-Date) - $script:StartTime).ToString('hh\:mm\:ss') }
try {
    Main
} catch {
    Show-Status "Fatal error: $_" "FAIL"
    Write-Log "FATAL: $_ `n $($_.ScriptStackTrace)" "FATAL"
    exit 1
} finally {
    Write-Host ""
    Write-Host "  Total time: $(& $totalElapsed)" -ForegroundColor DarkGray
    Write-Log "Script finished. Total time: $(& $totalElapsed)"
    Stop-Logging
    Write-Host ""
}
