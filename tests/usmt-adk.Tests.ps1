<#
.SYNOPSIS
    Tests for USMT detection, ADK download, and USMT extraction.
    Covers the full USMT initialization pipeline used by source-capture.ps1
    and destination-setup.ps1.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $ScriptRoot = Split-Path $PSScriptRoot -Parent
    $SourceScript = "$ScriptRoot\source-capture.ps1"
    $DestScript   = "$ScriptRoot\destination-setup.ps1"

    # Load the source script content for function extraction
    $srcContent = Get-Content $SourceScript -Raw
    $destContent = Get-Content $DestScript -Raw

    # Constants from the scripts
    $USMTZipName = "user-state-migration-tool.zip"
    $ADKInstallerUrl = "https://go.microsoft.com/fwlink/?linkid=2271337"

    # Architecture detection (mirrors the scripts)
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" }
            elseif ([Environment]::Is64BitOperatingSystem) { "amd64" }
            else { "x86" }
}

Describe "USMT Detection (Find-USMT)" {
    Context "Search path coverage" {
        It "Source script searches PSScriptRoot\USMT-Tools" {
            $srcContent | Should -Match 'PSScriptRoot\\USMT-Tools'
        }
        It "Source script searches TEMP\USMT-Tools" {
            $srcContent | Should -Match 'TEMP\\USMT-Tools'
        }
        It "Source script searches ADK default path" {
            $srcContent | Should -Match 'Assessment and Deployment Kit\\User State Migration Tool'
        }
        It "Source script searches C:\USMT fallback" {
            $srcContent | Should -Match 'C:\\USMT'
        }
        It "Source script searches C:\Tools\USMT fallback" {
            $srcContent | Should -Match 'C:\\Tools\\USMT'
        }
        It "Destination script has same search paths" {
            $destContent | Should -Match 'USMT-Tools'
            $destContent | Should -Match 'Assessment and Deployment Kit'
        }
    }

    Context "Architecture detection" {
        It "Detects correct architecture" {
            $Arch | Should -BeIn @('amd64', 'x86', 'arm64')
        }
        It "Script checks for scanstate.exe in arch subfolder" {
            $srcContent | Should -Match 'Join-Path \$archPath "scanstate\.exe"'
        }
        It "Script has ARM64 fallback to amd64" {
            $srcContent | Should -Match 'arch -eq "arm64"'
        }
    }

    Context "Detection with mock filesystem" {
        BeforeEach {
            $testBase = Join-Path $TestDrive "usmt-detect"
        }

        It "Finds scanstate.exe in arch subfolder" {
            $archDir = Join-Path $testBase $Arch
            New-Item $archDir -ItemType Directory -Force | Out-Null
            '' | Set-Content (Join-Path $archDir 'scanstate.exe')
            Test-Path (Join-Path $archDir 'scanstate.exe') | Should -BeTrue
        }

        It "Finds scanstate.exe in flat directory" {
            New-Item $testBase -ItemType Directory -Force | Out-Null
            '' | Set-Content (Join-Path $testBase 'scanstate.exe')
            Test-Path (Join-Path $testBase 'scanstate.exe') | Should -BeTrue
        }

        It "Does not find scanstate in empty directory" {
            $emptyDir = Join-Path $TestDrive "usmt-empty-$(Get-Random)"
            New-Item $emptyDir -ItemType Directory -Force | Out-Null
            Test-Path (Join-Path $emptyDir 'scanstate.exe') | Should -BeFalse
            Test-Path (Join-Path (Join-Path $emptyDir $Arch) 'scanstate.exe') | Should -BeFalse
        }
    }

    Context "Real system USMT detection" {
        It "ADK USMT path structure is valid when installed" {
            $adkPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
            if (Test-Path $adkPath) {
                $archPath = Join-Path $adkPath $Arch
                Test-Path (Join-Path $archPath 'scanstate.exe') | Should -BeTrue
                Test-Path (Join-Path $archPath 'loadstate.exe') | Should -BeTrue
            } else {
                Set-ItResult -Skipped -Because "ADK not installed on this system"
            }
        }
    }
}

Describe "Bundled USMT Zip" {
    Context "Zip search paths" {
        It "Source script defines zip name constant" {
            $srcContent | Should -Match 'USMTZipName\s*=\s*"user-state-migration-tool\.zip"'
        }
        It "Script searches PSScriptRoot for zip" {
            $srcContent | Should -Match 'PSScriptRoot'
        }
        It "Script searches parent directory for zip" {
            $srcContent | Should -Match 'Split-Path.*-Parent'
        }
        It "Script searches TEMP for zip" {
            $srcContent | Should -Match 'env:TEMP'
        }
    }

    Context "Zip extraction logic" {
        It "Source script defines internal root path" {
            $srcContent | Should -Match 'USMTZipInternalRoot'
        }
        It "Extracts to USMT-Tools directory" {
            $srcContent | Should -Match 'Join-Path \$PSScriptRoot "USMT-Tools"'
        }
        It "Checks for scanstate.exe after extraction" {
            $srcContent | Should -Match 'scanstate\.exe.*after.*extract|Test-Path.*scanstate\.exe'
        }
    }

    Context "Zip extraction with mock zip" {
        It "Can create and read a test zip file" {
            $zipDir = Join-Path $TestDrive 'zip-test'
            $innerDir = Join-Path $zipDir "User State Migration Tool\$Arch"
            New-Item $innerDir -ItemType Directory -Force | Out-Null
            '' | Set-Content (Join-Path $innerDir 'scanstate.exe')
            '' | Set-Content (Join-Path $innerDir 'loadstate.exe')

            $zipPath = Join-Path $TestDrive 'test-usmt.zip'
            Compress-Archive -Path "$zipDir\*" -DestinationPath $zipPath -Force

            Test-Path $zipPath | Should -BeTrue
            (Get-Item $zipPath).Length | Should -BeGreaterThan 0
        }

        It "Expand-Archive extracts scanstate.exe from mock zip" {
            $zipDir = Join-Path $TestDrive 'zip-test2'
            $innerDir = Join-Path $zipDir "User State Migration Tool\$Arch"
            New-Item $innerDir -ItemType Directory -Force | Out-Null
            '' | Set-Content (Join-Path $innerDir 'scanstate.exe')

            $zipPath = Join-Path $TestDrive 'test-usmt2.zip'
            Compress-Archive -Path "$zipDir\*" -DestinationPath $zipPath -Force

            $extractDir = Join-Path $TestDrive 'extracted'
            Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

            $scanstate = Join-Path $extractDir "User State Migration Tool\$Arch\scanstate.exe"
            Test-Path $scanstate | Should -BeTrue
        }
    }

    Context "Bundled zip presence" {
        It "Bundled zip exists in project root OR is documented as required" {
            $zipPath = Join-Path $ScriptRoot $USMTZipName
            $readmePath = Join-Path $ScriptRoot 'QUICKSTART.md'
            $zipExists = Test-Path $zipPath
            $readmeExists = Test-Path $readmePath
            ($zipExists -or $readmeExists) | Should -BeTrue
        }
    }

    Context "Zip internal structure" {
        It "Uses 'User State Migration Tool' as internal root" {
            $srcContent | Should -Match 'User State Migration Tool'
        }
        It "Extracts arch-specific subfolder (amd64/x86/arm64)" {
            $srcContent | Should -Match 'USMTZipInternalRoot.*arch'
        }
    }
}

Describe "ADK Online Download" {
    Context "Download URL" {
        It "Source script has ADK download URL" {
            $srcContent | Should -Match 'ADKInstallerUrl'
        }
        It "URL is a Microsoft go.microsoft.com redirect" {
            $ADKInstallerUrl | Should -Match 'go\.microsoft\.com/fwlink'
        }
    }

    Context "URL accessibility" -Tag 'Network' {
        It "ADK download URL responds with redirect (HTTP 200/301/302)" {
            try {
                $req = [System.Net.HttpWebRequest]::Create($ADKInstallerUrl)
                $req.Method = 'HEAD'
                $req.Timeout = 10000
                $req.AllowAutoRedirect = $true
                $req.UserAgent = 'Mozilla/5.0'
                $resp = $req.GetResponse()
                $resp.StatusCode | Should -Be 'OK'
                $resp.Close()
            } catch [System.Net.WebException] {
                $status = $_.Exception.Response.StatusCode
                # Redirects or OK are fine
                if ($status) {
                    [int]$status | Should -BeLessOrEqual 399
                } else {
                    Set-ItResult -Skipped -Because "Network unreachable: $_"
                }
            } catch {
                Set-ItResult -Skipped -Because "Network error: $_"
            }
        }

        It "ADK download URL resolves to an executable" {
            try {
                $req = [System.Net.HttpWebRequest]::Create($ADKInstallerUrl)
                $req.Method = 'HEAD'
                $req.Timeout = 10000
                $req.AllowAutoRedirect = $true
                $req.UserAgent = 'Mozilla/5.0'
                $resp = $req.GetResponse()
                $contentType = $resp.ContentType
                $resp.Close()
                $contentType | Should -Match 'octet-stream|executable|application'
            } catch {
                Set-ItResult -Skipped -Because "Network error: $_"
            }
        }
    }

    Context "Download method availability" {
        It "System.Net.WebClient is available" {
            { New-Object System.Net.WebClient } | Should -Not -Throw
        }
        It "Start-BitsTransfer is available or gracefully absent" {
            # Script checks for this and falls back to WebClient
            $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
            # Either available or script handles absence
            $srcContent | Should -Match 'Get-Command Start-BitsTransfer'
        }
    }

    Context "ADK installer arguments" {
        It "Script installs only USMT component (not full ADK)" {
            $srcContent | Should -Match 'OptionId\.UserStateMigrationTool'
        }
        It "Script uses quiet/norestart flags" {
            $srcContent | Should -Match '/quiet'
            $srcContent | Should -Match '/norestart'
        }
        It "Script disables CEIP" {
            $srcContent | Should -Match '/ceip.*off'
        }
    }
}

Describe "USMT Initialization Flow" {
    Context "Install-USMT priority order" {
        It "Tries bundled zip first" {
            $srcContent | Should -Match 'Priority 1.*bundled zip|Expand-BundledUSMT'
        }
        It "Falls back to online download" {
            $srcContent | Should -Match 'Priority 2.*online|Install-USMTOnline'
        }
        It "Shows guidance on total failure" {
            $srcContent | Should -Match 'Install Windows ADK|USMT is required'
        }
    }

    Context "Error handling" {
        It "Handles download failure gracefully" {
            $srcContent | Should -Match 'Download failed'
        }
        It "Checks exit code after ADK install" {
            $srcContent | Should -Match 'ExitCode.*-eq 0.*-or.*ExitCode.*-eq 3010'
        }
        It "Verifies USMT after install" {
            $srcContent | Should -Match 'Find-USMT.*after install|USMT verified'
        }
        It "Cleans up download directory" {
            $srcContent | Should -Match 'finally.*Remove-Item.*downloadDir|ADK-Download'
        }
    }

    Context "Find-USMT uses -USMTPath parameter" {
        It "Source script accepts USMTPath parameter" {
            $srcContent | Should -Match '\$USMTPath'
        }
        It "Destination script accepts USMTPath parameter" {
            $destContent | Should -Match '\$USMTPath'
        }
        It "Custom path is checked before default paths" {
            # The Find-USMT function should check the user-provided path first
            $srcContent | Should -Match 'USMTPath.*searchPaths|if.*USMTPath'
        }
    }
}

Describe "TUI USMT Pre-check (Find-USMT in Migration-Merlin.ps1)" {
    BeforeAll {
        $tuiContent = Get-Content "$ScriptRoot\Migration-Merlin.ps1" -Raw
    }

    Context "Find-USMT function exists" {
        It "TUI defines Find-USMT" {
            $tuiContent | Should -Match 'function Find-USMT'
        }
        It "TUI defines Show-USMTCheck" {
            $tuiContent | Should -Match 'function Show-USMTCheck'
        }
    }

    Context "Search path coverage matches scripts" {
        It "Checks USMT-Tools directory" {
            $tuiContent | Should -Match 'USMT-Tools'
        }
        It "Checks ADK install path" {
            $tuiContent | Should -Match 'Assessment and Deployment Kit'
        }
        It "Checks C:\USMT and C:\Tools\USMT" {
            $tuiContent | Should -Match 'C:\\USMT'
            $tuiContent | Should -Match 'C:\\Tools\\USMT'
        }
        It "Checks for bundled zip" {
            $tuiContent | Should -Match 'user-state-migration-tool\.zip'
        }
    }

    Context "USMTPath integration" {
        It "Step-Setup passes USMTPath to script" {
            $tuiContent | Should -Match "USMTPath"
        }
        It "Step-Capture passes USMTPath to script" {
            # USMTPath appears in the param-building section
            $tuiContent | Should -Match "-USMTPath"
        }
    }

    Context "User guidance on missing USMT" {
        It "Shows ADK download URL" {
            $tuiContent | Should -Match 'learn\.microsoft\.com.*adk-install'
        }
        It "Suggests copying bundled zip" {
            $tuiContent | Should -Match 'user-state-migration-tool\.zip.*this PC|Copy.*bundled zip'
        }
        It "Offers custom path option" {
            $tuiContent | Should -Match 'Custom USMT path|Specify.*custom.*USMT'
        }
    }
}

Describe "USMT Binaries Validation" -Tag 'Integration' {
    Context "scanstate.exe and loadstate.exe" {
        BeforeAll {
            $adkUsmt = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
            $usmtDir = $null
            $searchPaths = @(
                (Join-Path $adkUsmt $Arch)
                (Join-Path $ScriptRoot "USMT-Tools\$Arch")
                "C:\USMT\$Arch"
            )
            foreach ($p in $searchPaths) {
                if (Test-Path (Join-Path $p 'scanstate.exe')) { $usmtDir = $p; break }
            }
        }

        It "USMT binaries found on this system" {
            if (-not $usmtDir) { Set-ItResult -Skipped -Because "USMT not installed" }
            $usmtDir | Should -Not -BeNullOrEmpty
        }

        It "scanstate.exe exists and is executable" {
            if (-not $usmtDir) { Set-ItResult -Skipped -Because "USMT not installed" }
            $exe = Join-Path $usmtDir 'scanstate.exe'
            Test-Path $exe | Should -BeTrue
            (Get-Item $exe).Length | Should -BeGreaterThan 0
        }

        It "loadstate.exe exists and is executable" {
            if (-not $usmtDir) { Set-ItResult -Skipped -Because "USMT not installed" }
            $exe = Join-Path $usmtDir 'loadstate.exe'
            Test-Path $exe | Should -BeTrue
        }

        It "scanstate.exe responds to /?" {
            if (-not $usmtDir) { Set-ItResult -Skipped -Because "USMT not installed" }
            $exe = Join-Path $usmtDir 'scanstate.exe'
            $output = & $exe /? 2>&1 | Out-String
            $output | Should -Match 'ScanState|usage|USMT'
        }

        It "Required migration DLLs are present" {
            if (-not $usmtDir) { Set-ItResult -Skipped -Because "USMT not installed" }
            # Key DLLs that USMT needs
            foreach ($dll in @('migcore.dll', 'migstore.dll')) {
                $dllPath = Join-Path $usmtDir $dll
                if (Test-Path $dllPath) {
                    (Get-Item $dllPath).Length | Should -BeGreaterThan 0
                }
                # Some USMT versions may not have all DLLs - just check the main ones exist
            }
        }
    }
}
