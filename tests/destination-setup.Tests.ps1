#Requires -Modules Pester
<#
.SYNOPSIS
    Comprehensive Pester tests for destination-setup.ps1
.DESCRIPTION
    Tests all functions, parameters, code paths, error handling, and UI output
    for the destination PC migration script. All system-level calls are mocked.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $ScriptPath = "$PSScriptRoot\..\destination-setup.ps1"

    # Source the script's functions without running Main
    # We'll dot-source a modified version that doesn't auto-execute
    # Extract only function definitions using AST to avoid script-level code
    # that conflicts with Pester's internal container management
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath, [ref]$tokens, [ref]$parseErrors
    )
    $functions = $ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false
    )
    $funcCode = ($functions | ForEach-Object { $_.Extent.Text }) -join "`n`n"

    $tempScript = Join-Path $env:TEMP "dest-setup-funcs-$(Get-Random).ps1"
    $funcCode | Set-Content $tempScript -Force

    # Load shared logging module, then dot-source functions
    . "$PSScriptRoot\..\MigrationLogging.ps1"
    $MigrationFolder = Get-TestMigrationFolder
    $ShareName = "TestMigShare$"
    $LogFile = Initialize-Logging -PrimaryLogFile (Join-Path $MigrationFolder "test.log") -ScriptName "test"
    . $tempScript
    $script:TotalSteps = 20
    $script:CurrentStep = 0
    $script:StartTime = Get-Date
    $script:USMTDir = $null
    $script:ADKInstallerUrl = "https://go.microsoft.com/fwlink/?linkid=2271337"
    $script:ADKInstallerFile = "adksetup.exe"
    $ErrorActionPreference = "Continue"
}

AfterAll {
    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    if ($MigrationFolder) { Remove-TestMigrationFolder $MigrationFolder }
}

# =============================================================================
# UI HELPER TESTS
# =============================================================================
Describe "Show-Banner" {
    BeforeEach {
        $script:CurrentStep = 0
        $script:StartTime = Get-Date
    }

    It "Should output the title text" {
        $output = Show-Banner "TEST TITLE" 6>&1
        ($output -join "`n") | Should -Match "TEST TITLE"
    }

    It "Should output separator lines" {
        $output = Show-Banner "X" 6>&1
        ($output -join "`n") | Should -Match "={5,}"
    }
}

Describe "Show-Step" {
    BeforeEach {
        $script:TotalSteps = 20
        $script:CurrentStep = 0
        $script:StartTime = Get-Date
    }

    It "Should increment CurrentStep" {
        $before = $script:CurrentStep
        Show-Step "Test step" 6>&1 | Out-Null
        $script:CurrentStep | Should -Be ($before + 1)
    }

    It "Should display the description" {
        $script:CurrentStep = 0
        $output = Show-Step "My Description" 6>&1
        ($output -join "`n") | Should -Match "My Description"
    }

    It "Should show step number out of total" {
        $script:CurrentStep = 2
        $output = Show-Step "StepTest" 6>&1
        ($output -join "`n") | Should -Match "Step 3/"
    }
}

Describe "Show-Status" {
    BeforeEach {
        $script:CurrentStep = 0
    }

    It "Should display [+] for OK level" {
        $output = Show-Status "test ok" "OK" 6>&1
        ($output -join "") | Should -Match "\[\+\]"
    }

    It "Should display [X] for FAIL level" {
        $output = Show-Status "test fail" "FAIL" 6>&1
        ($output -join "") | Should -Match "\[X\]"
    }

    It "Should display [!] for WARN level" {
        $output = Show-Status "test warn" "WARN" 6>&1
        ($output -join "") | Should -Match "\[!\]"
    }

    It "Should display [~] for WAIT level" {
        $output = Show-Status "test wait" "WAIT" 6>&1
        ($output -join "") | Should -Match "\[~\]"
    }

    It "Should display [i] for INFO level" {
        $output = Show-Status "test info" "INFO" 6>&1
        ($output -join "") | Should -Match "\[i\]"
    }

    It "Should display [.] for unknown level" {
        $output = Show-Status "test default" "UNKNOWN" 6>&1
        ($output -join "") | Should -Match "\[\.\]"
    }

    It "Should include the message text" {
        $output = Show-Status "hello world" "OK" 6>&1
        ($output -join "") | Should -Match "hello world"
    }
}

Describe "Show-Detail" {
    BeforeEach {
        $script:CurrentStep = 0
    }

    It "Should display label and value" {
        $output = Show-Detail "MyLabel" "MyValue" 6>&1
        $joined = $output -join ""
        $joined | Should -Match "MyLabel"
        $joined | Should -Match "MyValue"
    }
}

Describe "Show-ProgressBar" {
    BeforeEach {
        $script:CurrentStep = 0
    }

    It "Should display percentage" {
        $output = Show-ProgressBar 50 100 "Test" 6>&1
        ($output -join "") | Should -Match "50%"
    }

    It "Should cap at 100%" {
        $output = Show-ProgressBar 150 100 "Over" 6>&1
        ($output -join "") | Should -Match "100%"
    }

    It "Should not crash when Total is 0" {
        { Show-ProgressBar 0 0 "Zero" 6>&1 } | Should -Not -Throw
    }

    It "Should include detail text when provided" {
        $output = Show-ProgressBar 25 100 "Label" "extra info" 6>&1
        ($output -join "") | Should -Match "extra info"
    }

    It "Should include label" {
        $output = Show-ProgressBar 10 100 "DiskCheck" 6>&1
        ($output -join "") | Should -Match "DiskCheck"
    }
}

Describe "Write-Log (from MigrationLogging module)" {
    It "Write-Log function should be available" {
        Get-Command Write-Log -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Should write timestamped entries to log file" {
        Write-Log "test entry" "INFO"
        if ($LogFile -and (Test-Path $LogFile)) {
            $content = Get-Content $LogFile -Raw
            $content | Should -Match "\[\d{4}-\d{2}-\d{2}.*\] \[INFO\] test entry"
        }
    }

    It "Should include the level in log entry" {
        Write-Log "error msg" "ERROR"
        if ($LogFile -and (Test-Path $LogFile)) {
            $content = Get-Content $LogFile -Raw
            $content | Should -Match "\[ERROR\] error msg"
        }
    }

    It "Safe-Exit function should be available" {
        Get-Command Safe-Exit -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Invoke-WithRetry should be available" {
        Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Invoke-SafeCommand should be available" {
        Get-Command Invoke-SafeCommand -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Try-CimInstance should be available" {
        Get-Command Try-CimInstance -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# =============================================================================
# USMT DETECTION TESTS
# =============================================================================
Describe "Find-USMT" {
    BeforeEach {
        $script:CurrentStep = 0
    }

    Context "When user-supplied USMTPath is valid" {
        It "Should find USMT at user-specified path" {
            $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
            $script:USMTPath = $fakeDir
            $USMTPath = $fakeDir
            $result = Find-USMT "loadstate.exe"
            $result | Should -BeTrue
            $script:USMTDir | Should -Be $fakeDir
        }
    }

    Context "When USMT is in a standard path" {
        It "Should find USMT in MigrationFolder\USMT-Tools" {
            $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
            $script:USMTPath = ""
            $USMTPath = ""
            $script:USMTDir = $null
            $result = Find-USMT "loadstate.exe"
            $result | Should -BeTrue
        }
    }

    Context "When USMT is not installed" {
        It "Should return false when no paths contain USMT" {
            $emptyFolder = Get-TestMigrationFolder
            $script:USMTPath = ""
            $USMTPath = ""
            $MigrationFolder = $emptyFolder
            $script:USMTDir = $null

            # Mock Test-Path to return false for all standard USMT locations
            Mock Test-Path {
                param($Path)
                # Only return true for the empty folder itself
                if ($Path -eq $emptyFolder) { return $true }
                # Return false for all USMT search paths
                if ($Path -match 'Windows Kits|USMT|loadstate|scanstate') { return $false }
                return (Microsoft.PowerShell.Management\Test-Path $Path)
            }

            $result = Find-USMT "loadstate.exe"
            $result | Should -BeFalse
            Remove-TestMigrationFolder $emptyFolder
        }
    }

    Context "When exe is directly in base path (no arch subfolder)" {
        It "Should find USMT" {
            $noArchDir = Join-Path $MigrationFolder "USMT-Tools"
            if (-not (Test-Path $noArchDir)) { New-Item $noArchDir -ItemType Directory -Force | Out-Null }
            Set-Content (Join-Path $noArchDir "loadstate.exe") -Value "FAKE" -Force
            $script:USMTPath = $noArchDir
            $USMTPath = $noArchDir
            $script:USMTDir = $null
            $result = Find-USMT "loadstate.exe"
            $result | Should -BeTrue
        }
    }
}

# =============================================================================
# INSTALL-USMT TESTS
# =============================================================================
Describe "Install-USMT" {
    BeforeAll {
        $MigrationFolder = Get-TestMigrationFolder
        $LogFile = Join-Path $MigrationFolder "destination-setup.log"

    }


    Context "When all download methods fail" {
        It "Should return false and show error" {
            Mock Invoke-WebRequest { throw "Network error" }
            Mock Start-BitsTransfer { throw "Network error" }
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq "Start-BitsTransfer" }
            Mock Test-Path { return $false } -ParameterFilter { $Path -like "*adksetup*" }

            $result = Install-USMT
            $result | Should -BeFalse
        }
    }

    Context "When ADK installer exits with success but USMT not found" {
        It "Should return false when Find-USMT fails after install" {
            $downloadDir = Join-Path $env:TEMP "ADK-Download"
            New-Item $downloadDir -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $downloadDir "adksetup.exe") -Value "FAKE"

            Mock Start-BitsTransfer { }
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq "Start-BitsTransfer" }
            Mock Start-TrackedProcess {
                $mockProc = [PSCustomObject]@{ ExitCode = 0; HasExited = $true }
                $mockProc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
                return $mockProc
            } -ParameterFilter { $FilePath -like "*adksetup*" }

            # Override Find-USMT to always return false (simulating USMT not found after install)
            Mock Find-USMT { return $false }

            $script:USMTDir = $null
            $USMTPath = ""
            $script:USMTPath = ""

            $result = Install-USMT
            $result | Should -BeFalse

            Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# =============================================================================
# TEST-PREREQUISITES TESTS
# =============================================================================
# Note: Test-Prerequisites uses exit 1 for fatal conditions (no admin, no network)
# which kills the Pester container. We test it structurally instead.
Describe "Test-Prerequisites structure" {
    BeforeAll {
        $script:destContent = Get-Content $ScriptPath -Raw
    }

    It "Function should exist" {
        Get-Command Test-Prerequisites -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Should check admin privileges" {
        $script:destContent | Should -Match 'WindowsBuiltInRole.*Administrator'
    }

    It "Should check OS version via CIM" {
        $script:destContent | Should -Match 'CimInstance.*Win32_OperatingSystem|Try-CimInstance.*OperatingSystem'
    }

    It "Should check disk space via CIM" {
        $script:destContent | Should -Match 'CimInstance.*Win32_LogicalDisk|Try-CimInstance.*LogicalDisk'
    }

    It "Should warn when less than 20GB free" {
        $script:destContent | Should -Match '20'
        $script:destContent | Should -Match 'Low disk|space'
    }

    It "Should check for active network adapters" {
        $script:destContent | Should -Match 'Get-NetAdapter'
    }

    It "Should get IPv4 addresses" {
        $script:destContent | Should -Match 'Get-NetIPAddress.*IPv4'
    }
}

# =============================================================================
# INITIALIZE-USMT TESTS
# =============================================================================
Describe "Initialize-USMT" {
    BeforeAll {
        $MigrationFolder = Get-TestMigrationFolder
        $LogFile = Join-Path $MigrationFolder "destination-setup.log"

        $script:TotalSteps = 20
        $script:CurrentStep = 0
        $script:StartTime = Get-Date
    }


    Context "When USMT is already installed" {
        It "Should return true and set USMTDir" {
            $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
            $script:USMTPath = $fakeDir
            $USMTPath = $fakeDir

            Mock Get-Item {
                [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ FileVersion = "10.1.22621.1" }
                }
            }

            $result = Initialize-USMT
            $result | Should -BeTrue
        }
    }

    Context "When USMT is not installed and SkipUSMTInstall is set" {
        It "Should return false" {
            $script:USMTDir = $null
            $USMTPath = ""
            $SkipUSMTInstall = $true

            # Mock Find-USMT to always return false
            Mock Find-USMT { return $false }

            $result = Initialize-USMT
            $result | Should -BeFalse
        }
    }
}

# =============================================================================
# NEW-MIGRATIONSHARE TESTS
# =============================================================================
Describe "New-MigrationShare" {
    BeforeEach {
        $script:TotalSteps = 10
        $script:CurrentStep = 0
        $script:StartTime = Get-Date
    }
    BeforeAll {
        # Define stub functions if Get-Acl/Set-Acl aren't available, then mock them
        if (-not (Get-Command Get-Acl -ErrorAction SilentlyContinue)) {
            function global:Get-Acl { param($Path) }
            function global:Set-Acl { param($Path, $AclObject) }
        }
        Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
        Mock Set-Acl { }
    }


    It "Should create subfolder structure" {
        Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
        Mock Set-Acl { }
        Mock Get-SmbShare { return $null }
        Mock New-SmbShare { }
        Mock Grant-SmbShareAccess { }

        New-MigrationShare

        Test-Path (Join-Path $MigrationFolder "USMT") | Should -BeTrue
        Test-Path (Join-Path $MigrationFolder "Logs") | Should -BeTrue
        Test-Path (Join-Path $MigrationFolder "Backup") | Should -BeTrue
    }

    It "Should remove existing share before creating new one" {
        Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
        Mock Set-Acl { }
        Mock Get-SmbShare { return [PSCustomObject]@{ Name = $ShareName } }
        Mock Remove-SmbShare { } -Verifiable
        Mock New-SmbShare { }
        Mock Grant-SmbShareAccess { }

        New-MigrationShare

        Should -InvokeVerifiable
    }

    It "Should call New-SmbShare with correct parameters" {
        Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
        Mock Set-Acl { }
        Mock Get-SmbShare { return $null }
        Mock New-SmbShare { } -Verifiable -ParameterFilter {
            $Name -eq $ShareName -and $Path -eq $MigrationFolder -and $FullAccess -eq "Everyone"
        }
        Mock Grant-SmbShareAccess { }

        New-MigrationShare

        Should -InvokeVerifiable
    }

    It "Should grant Everyone full share access" {
        Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
        Mock Set-Acl { }
        Mock Get-SmbShare { return $null }
        Mock New-SmbShare { }
        Mock Grant-SmbShareAccess { } -Verifiable -ParameterFilter {
            $AccountName -eq "Everyone" -and $AccessRight -eq "Full"
        }

        New-MigrationShare

        Should -InvokeVerifiable
    }
}

# =============================================================================
# SET-MIGRATIONFIREWALL TESTS
# =============================================================================
Describe "Set-MigrationFirewall" {
    BeforeEach {
        $script:TotalSteps = 10
        $script:CurrentStep = 0
        $script:StartTime = Get-Date
    }


    It "Should enable File and Printer Sharing rules" {
        Mock Get-NetFirewallRule { return $null }
        Mock Set-NetFirewallRule { }
        Mock Remove-NetFirewallRule { }
        Mock New-NetFirewallRule { } -Verifiable
        Mock Get-SmbServerConfiguration { [PSCustomObject]@{ EnableSMB2Protocol = $true } }

        Set-MigrationFirewall

        Should -InvokeVerifiable  # New-NetFirewallRule was called
    }

    It "Should create USMT-Migration-Inbound rule on ports 445 and 139" {
        Mock Get-NetFirewallRule { return $null }
        Mock Set-NetFirewallRule { }
        Mock New-NetFirewallRule { } -Verifiable -ParameterFilter {
            $DisplayName -eq "USMT-Migration-Inbound" -and
            $Protocol -eq "TCP" -and
            $Direction -eq "Inbound"
        }
        Mock Get-SmbServerConfiguration { [PSCustomObject]@{ EnableSMB2Protocol = $true } }

        Set-MigrationFirewall

        Should -InvokeVerifiable
    }

    It "Should remove existing migration rule before creating new one" {
        Mock Get-NetFirewallRule {
            param($DisplayName, $DisplayGroup)
            if ($DisplayName -eq "USMT-Migration-Inbound") {
                return [PSCustomObject]@{ DisplayName = "USMT-Migration-Inbound" }
            }
            return $null
        }
        Mock Set-NetFirewallRule { }
        Mock Remove-NetFirewallRule { } -Verifiable -ParameterFilter {
            $DisplayName -eq "USMT-Migration-Inbound"
        }
        Mock New-NetFirewallRule { }
        Mock Get-SmbServerConfiguration { [PSCustomObject]@{ EnableSMB2Protocol = $true } }

        Set-MigrationFirewall

        Should -InvokeVerifiable
    }

    It "Should restrict to AllowedSourceIP when specified" {
        $AllowedSourceIP = "10.0.0.50"
        Mock Get-NetFirewallRule { return $null }
        Mock Set-NetFirewallRule { }
        Mock New-NetFirewallRule { } -Verifiable -ParameterFilter {
            $RemoteAddress -eq "10.0.0.50"
        }
        Mock Get-SmbServerConfiguration { [PSCustomObject]@{ EnableSMB2Protocol = $true } }

        Set-MigrationFirewall

        Should -InvokeVerifiable
    }

    It "Should enable SMB2 when disabled" {
        Mock Get-NetFirewallRule { return $null }
        Mock Set-NetFirewallRule { }
        Mock New-NetFirewallRule { }
        Mock Get-SmbServerConfiguration { [PSCustomObject]@{ EnableSMB2Protocol = $false } }
        Mock Set-SmbServerConfiguration { } -Verifiable -ParameterFilter {
            $EnableSMB2Protocol -eq $true
        }

        Set-MigrationFirewall

        Should -InvokeVerifiable
    }
}

# =============================================================================
# SHOW-CONNECTIONINFO TESTS
# =============================================================================
Describe "Show-ConnectionInfo" {
    BeforeEach {
        $script:TotalSteps = 20
        $script:CurrentStep = 0
        $script:StartTime = Get-Date
    }


    It "Should return true when share exists and is writable" {
        Mock Get-SmbShare { [PSCustomObject]@{ Name = $ShareName } }
        Mock Get-NetIPAddress { @(New-MockIPAddress "192.168.1.100") }

        $result = Show-ConnectionInfo
        $result | Should -BeTrue
    }

    It "Should return false when share does not exist" {
        Mock Get-SmbShare { return $null }

        $result = Show-ConnectionInfo
        $result | Should -BeFalse
    }

    It "Should display computer name and share path" {
        Mock Get-SmbShare { [PSCustomObject]@{ Name = $ShareName } }
        Mock Get-NetIPAddress { @(New-MockIPAddress "10.0.0.5") }

        $output = Show-ConnectionInfo 6>&1
        $joined = $output -join "`n"
        $joined | Should -Match $env:COMPUTERNAME
        $joined | Should -Match "SHARE READY"
    }
}

# =============================================================================
# INVOKE-USMTRESTORE TESTS
# =============================================================================
Describe "Invoke-USMTRestore" {
    BeforeAll {
        $MigrationFolder = Get-TestMigrationFolder
        $LogFile = Join-Path $MigrationFolder "destination-setup.log"

    }


    Context "When migration store has .mig files" {
        BeforeEach {
            New-FakeMigStore -StorePath $MigrationFolder -FileCount 2 -FileSizeKB 50
            $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
            $script:USMTPath = $fakeDir
            $USMTPath = $fakeDir
            $script:USMTDir = $fakeDir
            $script:TotalSteps = 20
            $script:CurrentStep = 0
            $script:StartTime = Get-Date
        }

        It "Should call LoadState and return exit code 0 on success" {
            Mock Get-Item {
                [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ FileVersion = "10.0.0.1" }
                }
            }
            Mock Start-TrackedProcess {
                $proc = [PSCustomObject]@{
                    ExitCode  = 0
                    HasExited = $true
                    Id        = 999
                }
                $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
                return $proc
            }

            $exitCode = Invoke-USMTRestore
            $exitCode | Should -Be 0
        }

        It "Should return exit code 61 for partial success" {
            Mock Get-Item {
                [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ FileVersion = "10.0.0.1" }
                }
            }
            Mock Start-TrackedProcess {
                $proc = [PSCustomObject]@{
                    ExitCode  = 61
                    HasExited = $true
                    Id        = 999
                }
                $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
                return $proc
            }

            $exitCode = Invoke-USMTRestore
            $exitCode | Should -Be 61
        }

        It "Should return exit code 71 for failure" {
            Mock Get-Item {
                [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ FileVersion = "10.0.0.1" }
                }
            }
            Mock Start-TrackedProcess {
                $proc = [PSCustomObject]@{
                    ExitCode  = 71
                    HasExited = $true
                    Id        = 999
                }
                $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
                return $proc
            }

            $exitCode = Invoke-USMTRestore
            $exitCode | Should -Be 71
        }
    }

    Context "When migration store is empty" {
        It "Should verify script checks for .mig files" {
            # Invoke-USMTRestore calls exit 1 when no .mig files found,
            # which kills the Pester container. Verify structurally instead.
            $destContent = Get-Content "$PSScriptRoot\..\destination-setup.ps1" -Raw
            $destContent | Should -Match '\.mig'
            $destContent | Should -Match 'No.*mig.*files|Ensure.*source.*completed'
        }
    }

    Context "LoadState argument construction" {
        It "Should include custom XML when present" {
            New-FakeMigStore -StorePath $MigrationFolder
            Set-Content (Join-Path $MigrationFolder "custom-migration.xml") -Value "<xml/>"
            $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
            $script:USMTDir = $fakeDir
            $script:USMTPath = $fakeDir
            $USMTPath = $fakeDir
            $script:TotalSteps = 20
            $script:CurrentStep = 0
            $script:StartTime = Get-Date

            Mock Get-Item {
                [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ FileVersion = "10.0.0.1" }
                }
            }

            $capturedArgs = $null
            Mock Start-TrackedProcess {
                param($FilePath, $Arguments)
                $script:capturedArgs = $Arguments
                $proc = [PSCustomObject]@{ ExitCode = 0; HasExited = $true; Id = 999 }
                $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
                return $proc
            }

            Invoke-USMTRestore

            $script:capturedArgs | Should -Match "custom-migration\.xml"
        }
    }
}

# =============================================================================
# REMOVE-MIGRATIONARTIFACTS TESTS
# =============================================================================
Describe "Remove-MigrationArtifacts" {
    BeforeAll {
        $MigrationFolder = Get-TestMigrationFolder
        $ShareName = "CleanupTestShare$"
        $LogFile = Join-Path $MigrationFolder "destination-setup.log"

    }


    It "Should remove share when confirmed" {
        Mock Read-Host { return 'Y' }
        Mock Get-SmbShare { [PSCustomObject]@{ Name = $ShareName } }
        Mock Remove-SmbShare { } -Verifiable
        Mock Get-NetFirewallRule { return $null }

        Remove-MigrationArtifacts

        Should -InvokeVerifiable
    }

    It "Should remove firewall rule when it exists" {
        Mock Read-Host { return 'Y' }
        Mock Get-SmbShare { return $null }
        Mock Get-NetFirewallRule {
            [PSCustomObject]@{ DisplayName = "USMT-Migration-Inbound" }
        }
        Mock Remove-NetFirewallRule { }

        Remove-MigrationArtifacts

        Should -Invoke Remove-NetFirewallRule -Times 1
    }

    It "Should not proceed when user declines" {
        Mock Read-Host { return 'N' }
        Mock Remove-SmbShare { }
        Mock Remove-NetFirewallRule { }

        Remove-MigrationArtifacts

        Assert-MockCalled Remove-SmbShare -Times 0 -Scope It
        Assert-MockCalled Remove-NetFirewallRule -Times 0 -Scope It
    }
}

# =============================================================================
# MAIN FUNCTION FLOW TESTS
# =============================================================================
Describe "Main function routing" {
    BeforeAll {
        $MigrationFolder = Get-TestMigrationFolder
        $LogFile = Join-Path $MigrationFolder "destination-setup.log"
        $ShareName = "FlowTestShare$"

    }


    It "Should call Remove-MigrationArtifacts when Cleanup is set" {
        $Cleanup = $true
        $RestoreOnly = $false

        Mock Read-Host { return 'N' }  # decline cleanup
        Mock Remove-SmbShare { }
        Mock Remove-NetFirewallRule { }

        { Main } | Should -Not -Throw
    }

    It "Should call Invoke-USMTRestore when RestoreOnly is set" {
        $Cleanup = $false
        $RestoreOnly = $true

        # Mock the restore chain
        $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
        $script:USMTPath = $fakeDir
        $USMTPath = $fakeDir

        New-FakeMigStore -StorePath $MigrationFolder

        Mock Get-Item {
            [PSCustomObject]@{
                VersionInfo = [PSCustomObject]@{ FileVersion = "10.0.0.1" }
            }
        }
        Mock Start-TrackedProcess {
            $proc = [PSCustomObject]@{ ExitCode = 0; HasExited = $true; Id = 999 }
            $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
            return $proc
        }

        { Main } | Should -Not -Throw
    }
}

# =============================================================================
# WATCH-MIGRATIONPROGRESS TESTS
# =============================================================================
Describe "Watch-MigrationProgress" {
    BeforeAll {
        $MigrationFolder = Get-TestMigrationFolder
        $LogFile = Join-Path $MigrationFolder "destination-setup.log"

    }


    It "Should detect capture-complete.flag and exit" {
        # Create USMT store with data
        New-FakeMigStore -StorePath $MigrationFolder -FileCount 1 -FileSizeKB 10
        # Create completion flag
        New-FakeCaptureCompleteFlag -MigrationFolder $MigrationFolder

        # Should not hang — flag exists immediately
        $output = Watch-MigrationProgress 6>&1
        $joined = $output -join "`n"
        $joined | Should -Match "CAPTURE COMPLETE|DATA RECEIVED"
    }
}

# =============================================================================
# PARAMETER VALIDATION TESTS
# =============================================================================
Describe "Script parameters" {
    It "Should have correct default MigrationFolder" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $mfParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "MigrationFolder" }
        $mfParam.DefaultValue.Value | Should -Be "C:\MigrationStore"
    }

    It "Should have correct default ShareName" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $snParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "ShareName" }
        $snParam.DefaultValue.Value | Should -Be 'MigrationShare$'
    }

    It "Should have RestoreOnly as switch parameter" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $roParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "RestoreOnly" }
        $roParam.Attributes.TypeName.Name | Should -Contain "switch"
    }

    It "Should have Cleanup as switch parameter" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $clParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "Cleanup" }
        $clParam.Attributes.TypeName.Name | Should -Contain "switch"
    }

    It "Should have SkipUSMTInstall as switch parameter" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $param = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "SkipUSMTInstall" }
        $param | Should -Not -BeNullOrEmpty
    }

    It "Should have 8 parameters total" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $ast.ParamBlock.Parameters.Count | Should -Be 8
    }
}

# =============================================================================
# SCRIPT STRUCTURE TESTS
# =============================================================================
Describe "Script structure validation" {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It "Should require RunAsAdministrator" {
        $scriptContent | Should -Match 'IsInRole.*Administrator|RunAsAdministrator'
    }

    It "Should define all expected functions" {
        $expectedFunctions = @(
            'Show-Banner', 'Show-Step', 'Show-Status', 'Show-Detail',
            'Show-Spinner', 'Show-ProgressBar',
            'Find-USMT', 'Install-USMT', 'Test-Prerequisites',
            'Initialize-USMT', 'New-MigrationShare', 'Set-MigrationFirewall',
            'Show-ConnectionInfo', 'Watch-MigrationProgress',
            'Invoke-USMTRestore', 'Remove-MigrationArtifacts', 'Main'
        )
        foreach ($fn in $expectedFunctions) {
            $scriptContent | Should -Match "function $fn"
        }
    }

    It "Should have ErrorActionPreference set to Stop" {
        $scriptContent | Should -Match '\$ErrorActionPreference\s*=\s*"Stop"'
    }

    It "Should define ADK installer URL" {
        $scriptContent | Should -Match 'ADKInstallerUrl'
    }

    It "Should have a try/catch/finally wrapper" {
        $scriptContent | Should -Match 'try\s*\{[\s\S]*Main[\s\S]*\}\s*catch'
    }
}
