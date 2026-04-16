<#
.SYNOPSIS
    USMTTools.psm1 - Discovery, extraction, download, and install of USMT.
.DESCRIPTION
    Centralizes the User State Migration Tool (USMT) plumbing previously
    duplicated across source-capture.ps1 and destination-setup.ps1.

    Functions return discovered/extracted directory paths. No script-scope
    side effects - the caller is responsible for holding the path
    (typically in a MigrationState object - see t1-e11).
.NOTES
    Task t1-e3 (phase p1) of the Migration-Merlin refactor.
#>

# ----------------------------------------------------------------------------
# Constants (soft-wired to MigrationConstants.psm1 once it exists)
# TODO t1-e6/e7 wire into constants module
# ----------------------------------------------------------------------------
$script:UsmtToolsConstants = $null
$_constantsModule = Join-Path $PSScriptRoot 'MigrationConstants.psm1'
if (Test-Path $_constantsModule) {
    try {
        Import-Module $_constantsModule -Force -ErrorAction Stop
        if (Get-Variable -Name 'MigrationConstants' -Scope Global -ErrorAction SilentlyContinue) {
            $script:UsmtToolsConstants = $Global:MigrationConstants
        }
    } catch {
        # Fall back to local defaults below.
        $script:UsmtToolsConstants = $null
    }
}

function _Get-UsmtDefaults {
    <# Returns a hashtable of constants, using MigrationConstants if loaded
       otherwise local defaults. Local defaults mirror the values currently
       hard-coded in source-capture.ps1 / destination-setup.ps1. #>
    if ($script:UsmtToolsConstants -and $script:UsmtToolsConstants.USMT) {
        return @{
            SearchPaths      = $script:UsmtToolsConstants.USMT.SearchPaths
            ZipName          = $script:UsmtToolsConstants.USMT.ZipName
            ZipInternalRoot  = $script:UsmtToolsConstants.USMT.ZipInternalRoot
            AdkInstallerUrl  = $script:UsmtToolsConstants.USMT.ADK.InstallerUrl
            AdkInstallerFile = $script:UsmtToolsConstants.USMT.ADK.InstallerFile
        }
    }
    return @{
        SearchPaths = @(
            "$PSScriptRoot\USMT-Tools"
            "$env:TEMP\USMT-Tools"
            "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
            "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
            "C:\USMT"
            "C:\Tools\USMT"
        )
        ZipName          = 'user-state-migration-tool.zip'
        ZipInternalRoot  = 'User State Migration Tool'
        AdkInstallerUrl  = 'https://go.microsoft.com/fwlink/?linkid=2271337'
        AdkInstallerFile = 'adksetup.exe'
    }
}

function _Write-UsmtLog {
    <# Soft-fallback logger. Uses Write-Log if defined (MigrationLogging.ps1),
       otherwise Write-Host. Keeps tests independent of the logging module. #>
    param([string]$Message, [string]$Level = 'INFO')
    $cmd = Get-Command Write-Log -ErrorAction SilentlyContinue
    if ($cmd) {
        & $cmd $Message $Level
    } else {
        Write-Host "[$Level] $Message"
    }
}

function _Get-UsmtArchitecture {
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { return 'arm64' }
    if ([Environment]::Is64BitOperatingSystem)    { return 'amd64' }
    return 'x86'
}

# ----------------------------------------------------------------------------
# Find-USMT
# ----------------------------------------------------------------------------
function Find-USMT {
    <#
    .SYNOPSIS
        Searches well-known locations for a USMT installation.
    .PARAMETER ExeName
        The USMT executable that must be present for a directory to qualify.
        Defaults to scanstate.exe (source side). Use loadstate.exe for the
        destination side.
    .PARAMETER USMTPathOverride
        Explicit path to check first. Returned as-is when it contains ExeName.
    .PARAMETER AdditionalSearchPaths
        Extra directories to scan before the built-in list (e.g. a script's
        MigrationFolder\USMT-Tools).
    .OUTPUTS
        [string] the resolved directory containing ExeName, or $null.
    #>
    [CmdletBinding()]
    param(
        [string]$ExeName = 'scanstate.exe',
        [string]$USMTPathOverride,
        [string[]]$AdditionalSearchPaths = @()
    )

    # 1. Caller-supplied explicit path takes precedence.
    if ($USMTPathOverride -and (Test-Path $USMTPathOverride)) {
        $exe = Join-Path $USMTPathOverride $ExeName
        if (Test-Path $exe) {
            return $USMTPathOverride
        }
    }

    $defaults = _Get-UsmtDefaults
    $arch     = _Get-UsmtArchitecture
    $searchPaths = @()
    $searchPaths += $AdditionalSearchPaths
    $searchPaths += $defaults.SearchPaths

    foreach ($basePath in $searchPaths) {
        if (-not $basePath) { continue }
        if (-not (Test-Path $basePath)) { continue }

        # Primary: base\<arch>\ExeName
        $archPath = Join-Path $basePath $arch
        if (Test-Path (Join-Path $archPath $ExeName)) {
            return $archPath
        }

        # Fallback: ARM64 systems can fall back to amd64 binaries.
        if ($arch -eq 'arm64') {
            $amd64Path = Join-Path $basePath 'amd64'
            if (Test-Path (Join-Path $amd64Path $ExeName)) {
                return $amd64Path
            }
        }

        # Flat layout: base\ExeName
        if (Test-Path (Join-Path $basePath $ExeName)) {
            return $basePath
        }
    }

    return $null
}

# ----------------------------------------------------------------------------
# Expand-BundledUSMT
# ----------------------------------------------------------------------------
function Expand-BundledUSMT {
    <#
    .SYNOPSIS
        Extracts USMT from a bundled user-state-migration-tool.zip.
    .PARAMETER ExeName
        The executable that must be present after extraction (defaults to
        scanstate.exe). Used to short-circuit if already extracted.
    .PARAMETER AdditionalZipSearchPaths
        Extra locations to probe for the zip (e.g. a MigrationFolder).
    .PARAMETER ExtractTarget
        Root extraction directory. Defaults to $PSScriptRoot\USMT-Tools.
    .OUTPUTS
        [string] path to the architecture-specific extracted directory, or $null.
    #>
    [CmdletBinding()]
    param(
        [string]$ExeName = 'scanstate.exe',
        [string[]]$AdditionalZipSearchPaths = @(),
        [string]$ExtractTarget
    )

    $defaults = _Get-UsmtDefaults
    $zipName  = $defaults.ZipName
    $zipRoot  = $defaults.ZipInternalRoot

    $zipSearchPaths = @()
    $zipSearchPaths += (Join-Path $PSScriptRoot $zipName)
    $zipSearchPaths += (Join-Path (Split-Path $PSScriptRoot -Parent) $zipName)
    $zipSearchPaths += (Join-Path $env:TEMP $zipName)
    foreach ($p in $AdditionalZipSearchPaths) {
        if ($p) { $zipSearchPaths += (Join-Path $p $zipName) }
    }

    $zipPath = $null
    foreach ($p in $zipSearchPaths) {
        if (Test-Path $p) { $zipPath = $p; break }
    }
    if (-not $zipPath) {
        _Write-UsmtLog "No bundled USMT zip found in: $($zipSearchPaths -join '; ')" 'INFO'
        return $null
    }

    $zipSizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    _Write-UsmtLog "Found bundled USMT zip: $zipPath (${zipSizeMB} MB)"

    if (-not $ExtractTarget) {
        $ExtractTarget = Join-Path $PSScriptRoot 'USMT-Tools'
    }
    $arch       = _Get-UsmtArchitecture
    $archTarget = Join-Path $ExtractTarget $arch

    if (Test-Path (Join-Path $archTarget $ExeName)) {
        _Write-UsmtLog "USMT already extracted at: $archTarget"
        return $archTarget
    }

    _Write-UsmtLog "Extracting USMT ($arch) from $zipPath to $ExtractTarget"

    # Prefer Expand-Archive (mockable, idiomatic). Fall back to the ZipFile
    # class for zips whose internal layout contains the <root>/<arch>/ prefix.
    $zip = $null
    try {
        # Try the simple path: Expand-Archive to a staging folder then pull
        # the arch subtree. This keeps the function easily mockable in tests.
        $staging = Join-Path $env:TEMP ("usmt-stage-" + [guid]::NewGuid().ToString('N'))
        try {
            Expand-Archive -Path $zipPath -DestinationPath $staging -Force -ErrorAction Stop
        } catch {
            _Write-UsmtLog "Expand-Archive failed: $_ - falling back to ZipFile API" 'WARN'
            if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
            $staging = $null
        }

        if ($staging -and (Test-Path $staging)) {
            $stagedArch = Join-Path (Join-Path $staging $zipRoot) $arch
            if (Test-Path $stagedArch) {
                if (-not (Test-Path $archTarget)) {
                    New-Item -Path $archTarget -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path (Join-Path $stagedArch '*') -Destination $archTarget -Recurse -Force
            }
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            # ZipFile API fallback
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            $prefix = "$zipRoot/$arch/"
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
            }
            $zip.Dispose(); $zip = $null
        }

        if (Test-Path (Join-Path $archTarget $ExeName)) {
            _Write-UsmtLog "Extracted USMT to: $archTarget"
            return $archTarget
        }
        _Write-UsmtLog "Extraction completed but $ExeName not found" 'ERROR'
        return $null
    } catch {
        _Write-UsmtLog "Failed to extract USMT zip: $_" 'ERROR'
        return $null
    } finally {
        if ($zip) { try { $zip.Dispose() } catch {} }
    }
}

# ----------------------------------------------------------------------------
# Install-USMTOnline
# ----------------------------------------------------------------------------
function Install-USMTOnline {
    <#
    .SYNOPSIS
        Downloads the Windows ADK bootstrapper and installs only the USMT feature.
    .PARAMETER ExeName
        Executable used to verify a successful install (defaults to scanstate.exe).
    .OUTPUTS
        [string] path to the resolved USMT directory, or $null on failure.
    .NOTES
        Four download methods are attempted in order with try/catch fallbacks:
        Invoke-WebRequest, HttpClient, BITS, WebClient.
    #>
    [CmdletBinding()]
    param(
        [string]$ExeName = 'scanstate.exe'
    )

    $defaults     = _Get-UsmtDefaults
    $installerUrl = $defaults.AdkInstallerUrl
    $installerFile = $defaults.AdkInstallerFile

    _Write-UsmtLog 'Downloading Windows ADK (USMT component only)...'

    $downloadDir = Join-Path $env:TEMP 'ADK-Download'
    if (-not (Test-Path $downloadDir)) {
        New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null
    }
    $installerPath = Join-Path $downloadDir $installerFile

    try {
        $downloaded     = $false
        $downloadErrors = @()

        # Method 1: Invoke-WebRequest
        if (-not $downloaded) {
            try {
                _Write-UsmtLog 'Trying Invoke-WebRequest...'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) {
                    $downloaded = $true
                } elseif (Test-Path $installerPath) {
                    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
                    throw 'Downloaded file too small (likely error page)'
                }
            } catch { $downloadErrors += "Invoke-WebRequest: $_" }
        }

        # Method 2: HttpClient
        if (-not $downloaded) {
            try {
                _Write-UsmtLog 'Trying HttpClient...'
                $handler = [System.Net.Http.HttpClientHandler]::new()
                $handler.UseDefaultCredentials = $true
                $client = [System.Net.Http.HttpClient]::new($handler)
                $client.DefaultRequestHeaders.Add('User-Agent', 'Mozilla/5.0')
                $bytes = $client.GetByteArrayAsync($installerUrl).GetAwaiter().GetResult()
                [System.IO.File]::WriteAllBytes($installerPath, $bytes)
                $client.Dispose()
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) {
                    $downloaded = $true
                } elseif (Test-Path $installerPath) {
                    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
                    throw 'Downloaded file too small (likely error page)'
                }
            } catch { $downloadErrors += "HttpClient: $_" }
        }

        # Method 3: BITS
        if (-not $downloaded -and (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) {
            try {
                _Write-UsmtLog 'Trying BITS transfer...'
                Start-BitsTransfer -Source $installerUrl -Destination $installerPath -ErrorAction Stop
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) {
                    $downloaded = $true
                } elseif (Test-Path $installerPath) {
                    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
                    throw 'Downloaded file too small (likely error page)'
                }
            } catch { $downloadErrors += "BITS: $_" }
        }

        # Method 4: WebClient
        if (-not $downloaded) {
            try {
                _Write-UsmtLog 'Trying WebClient...'
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
                $wc.UseDefaultCredentials = $true
                $wc.DownloadFile($installerUrl, $installerPath)
                if ((Test-Path $installerPath) -and (Get-Item $installerPath).Length -gt 50KB) {
                    $downloaded = $true
                } elseif (Test-Path $installerPath) {
                    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
                    throw 'Downloaded file too small (likely error page)'
                }
            } catch { $downloadErrors += "WebClient: $_" }
        }

        if (-not $downloaded) {
            foreach ($e in $downloadErrors) { _Write-UsmtLog "Download attempt failed: $e" 'ERROR' }
            throw ($downloadErrors | Select-Object -Last 1)
        }

        $fileSize = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
        _Write-UsmtLog "ADK installer downloaded (${fileSize} MB) to $installerPath"
    } catch {
        _Write-UsmtLog "ADK download failed: $_" 'ERROR'
        _Write-UsmtLog 'Hint: UAC may have elevated to a different admin account.'
        _Write-UsmtLog 'Manual download: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install'
        return $null
    }

    try {
        _Write-UsmtLog 'Installing USMT component (this may take a few minutes)...'
        $installArgs = @('/quiet', '/norestart', '/features', 'OptionId.UserStateMigrationTool', '/ceip', 'off')
        $proc = Start-TrackedProcess -FilePath $installerPath -Arguments ($installArgs -join ' ')
        if ($proc) {
            $proc.WaitForExit()
            $exitCode = $proc.ExitCode
            if ($exitCode -eq 0 -or $exitCode -eq 3010) {
                _Write-UsmtLog "USMT installed (exit code $exitCode)"
            } else {
                _Write-UsmtLog "ADK installer exited with code: $exitCode" 'ERROR'
            }
        }

        $found = Find-USMT -ExeName $ExeName
        if ($found) {
            _Write-UsmtLog "USMT verified at: $found"
            return $found
        }
        _Write-UsmtLog 'USMT binaries not found after install' 'ERROR'
        return $null
    } catch {
        _Write-UsmtLog "USMT installation failed: $_" 'ERROR'
        return $null
    } finally {
        if (Test-Path $downloadDir) {
            Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ----------------------------------------------------------------------------
# Install-USMT (orchestrator)
# ----------------------------------------------------------------------------
function Install-USMT {
    <#
    .SYNOPSIS
        Orchestrator: Find-USMT -> Expand-BundledUSMT -> Install-USMTOnline.
    .OUTPUTS
        [string] path to the USMT directory, or $null when all strategies fail.
    #>
    [CmdletBinding()]
    param(
        [string]$ExeName = 'scanstate.exe',
        [string]$USMTPathOverride,
        [string[]]$AdditionalSearchPaths = @(),
        [string[]]$AdditionalZipSearchPaths = @()
    )

    # Priority 1: already installed / user-supplied
    $found = Find-USMT -ExeName $ExeName -USMTPathOverride $USMTPathOverride -AdditionalSearchPaths $AdditionalSearchPaths
    if ($found) {
        _Write-UsmtLog "USMT already present at: $found"
        return $found
    }

    _Write-UsmtLog 'USMT not found on this system' 'WARN'

    # Priority 2: bundled zip
    _Write-UsmtLog 'Checking for bundled USMT zip...'
    $extracted = Expand-BundledUSMT -ExeName $ExeName -AdditionalZipSearchPaths $AdditionalZipSearchPaths
    if ($extracted) { return $extracted }

    # Priority 3: online ADK
    _Write-UsmtLog 'Bundled zip not found - trying online download...' 'WARN'
    return Install-USMTOnline -ExeName $ExeName
}

# ----------------------------------------------------------------------------
# Start-TrackedProcess
# ----------------------------------------------------------------------------
function Start-TrackedProcess {
    <#
    .SYNOPSIS
        Launches a process via System.Diagnostics.Process for a reliable ExitCode.
    .DESCRIPTION
        Start-Process -PassThru has a known bug where ExitCode is empty after a
        HasExited loop. This wrapper uses the framework type directly.
    .OUTPUTS
        [System.Diagnostics.Process]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = ''
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName        = $FilePath
    $psi.Arguments       = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $false
    return [System.Diagnostics.Process]::Start($psi)
}

Export-ModuleMember -Function Find-USMT, Expand-BundledUSMT, Install-USMTOnline, Install-USMT, Start-TrackedProcess
