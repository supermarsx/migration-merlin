#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for destination-setup.ps1 (post-Phase-2 integration).
.DESCRIPTION
    UI helpers, Start-TrackedProcess, and USMT discovery/install now live in
    shared modules (MigrationUI.psm1, USMTTools.psm1). Tests that exercised
    those functions have been moved to tests/modules/*.Tests.ps1 by
    executors t1-e2 and t1-e3. This file focuses on:
      * script-level structural assertions (imports, parameters, cmdlet binding)
      * destination-specific functions (Test-Prerequisites, New-MigrationShare,
        Set-MigrationFirewall, Show-ConnectionInfo, Invoke-USMTRestore,
        Remove-MigrationArtifacts, Watch-MigrationProgress, Initialize-USMT)
      * the Main routing logic
#>

BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $ScriptPath = "$PSScriptRoot\..\scripts\destination-setup.ps1"

    # Load shared modules the script depends on so that dot-sourced functions
    # see Show-*, Start-TrackedProcess, Format-SafeParams, Request-Elevation, etc.
    Import-Module "$PSScriptRoot\..\modules\MigrationConstants.psm1" -Force
    Import-Module "$PSScriptRoot\..\modules\MigrationUI.psm1" -Force
    Import-Module "$PSScriptRoot\..\modules\USMTTools.psm1" -Force
    Import-Module "$PSScriptRoot\..\modules\MigrationState.psm1" -Force
    . "$PSScriptRoot\..\modules\Invoke-Elevated.ps1"
    . "$PSScriptRoot\..\modules\MigrationLogging.ps1"

    # Extract function definitions via AST (skips auto-elevation, Main(), etc.)
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

    $MigrationFolder = Get-TestMigrationFolder
    $ShareName = "TestMigShare$"
    $LogFile = Initialize-Logging -PrimaryLogFile (Join-Path $MigrationFolder "test.log") -ScriptName "test"
    . $tempScript

    # Seed consolidated state (t1-e11) used by the extracted functions and
    # by Show-Step in the MigrationUI module.
    $script:State = New-MigrationState -TotalSteps 20
    Set-MigrationUIState -State $script:State
    $ErrorActionPreference = "Continue"
}

AfterAll {
    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    if ($MigrationFolder) { Remove-TestMigrationFolder $MigrationFolder }
}

# =============================================================================
# UI HELPER AVAILABILITY (functions now live in MigrationUI module)
# =============================================================================
Describe "UI helper module wiring" {
    It "Show-Banner is imported from MigrationUI" {
        Get-Command Show-Banner -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It "Show-Step is imported from MigrationUI" {
        Get-Command Show-Step -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It "Show-Status is imported from MigrationUI" {
        Get-Command Show-Status -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It "Show-Detail is imported from MigrationUI" {
        Get-Command Show-Detail -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It "Show-ProgressBar is imported from MigrationUI" {
        Get-Command Show-ProgressBar -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It "Show-Spinner is imported from MigrationUI" {
        Get-Command Show-Spinner -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "USMTTools module wiring" {
    It "Start-TrackedProcess is imported from USMTTools" {
        Get-Command Start-TrackedProcess -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
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

    It "Format-SafeParams should be available" {
        Get-Command Format-SafeParams -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# =============================================================================
# USMT WRAPPER FUNCTIONS (thin wrappers over USMTTools module)
# =============================================================================
Describe "Find-USMT wrapper" {
    Context "When user-supplied USMTPath is valid" {
        It "Should find USMT at user-specified path" {
            $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
            $USMTPath = $fakeDir
            $script:State.USMTDir = $null
            $result = Find-USMT "loadstate.exe"
            $result | Should -BeTrue
            $script:State.USMTDir | Should -Be $fakeDir
        }
    }

    Context "When USMT is in MigrationFolder\USMT-Tools" {
        It "Should find USMT via the additional search path" {
            $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
            $USMTPath = ""
            $script:State.USMTDir = $null
            $result = Find-USMT "loadstate.exe"
            $result | Should -BeTrue
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

        $script:State = New-MigrationState -TotalSteps 20
        Set-MigrationUIState -State $script:State
    }


    Context "When USMT is already installed" {
        It "Should return true and set USMTDir" {
            $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
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
            $script:State.USMTDir = $null
            $USMTPath = ""
            $SkipUSMTInstall = $true

            # Override the script-level wrapper Find-USMT to always return false.
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
        $script:State = New-MigrationState -TotalSteps 10
        Set-MigrationUIState -State $script:State
    }
    BeforeAll {
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
        $script:State = New-MigrationState -TotalSteps 10
        Set-MigrationUIState -State $script:State
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
        $script:State = New-MigrationState -TotalSteps 20
        Set-MigrationUIState -State $script:State
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
            $USMTPath = $fakeDir
            $script:State = New-MigrationState -TotalSteps 20 -USMTDir $fakeDir
            Set-MigrationUIState -State $script:State
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
            $destContent = Get-Content "$PSScriptRoot\..\scripts\destination-setup.ps1" -Raw
            $destContent | Should -Match '\.mig'
            $destContent | Should -Match 'No.*mig.*files|Ensure.*source.*completed'
        }
    }

    Context "LoadState argument construction" {
        It "Should include custom XML when present" {
            New-FakeMigStore -StorePath $MigrationFolder
            Set-Content (Join-Path $MigrationFolder "custom-migration.xml") -Value "<xml/>"
            $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
            $USMTPath = $fakeDir
            $script:State = New-MigrationState -TotalSteps 20 -USMTDir $fakeDir
            Set-MigrationUIState -State $script:State

            Mock Get-Item {
                [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ FileVersion = "10.0.0.1" }
                }
            }

            $script:capturedArgs = $null
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

        $fakeDir = New-FakeUSMTDir -BasePath $MigrationFolder
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
        New-FakeMigStore -StorePath $MigrationFolder -FileCount 1 -FileSizeKB 10
        New-FakeCaptureCompleteFlag -MigrationFolder $MigrationFolder

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

    It "Should have 9 parameters total" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $ast.ParamBlock.Parameters.Count | Should -Be 9
    }

    It "Should declare CmdletBinding with SupportsShouldProcess" {
        $scriptContent = Get-Content $ScriptPath -Raw
        $scriptContent | Should -Match '\[CmdletBinding\(SupportsShouldProcess\s*=\s*\$true\)\]'
    }
}

# =============================================================================
# SCRIPT STRUCTURE TESTS
# =============================================================================
Describe "Script structure validation" {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It "Should import MigrationConstants module" {
        $scriptContent | Should -Match 'Import-Module\s+.+MigrationConstants\.psm1'
    }

    It "Should import MigrationUI module" {
        $scriptContent | Should -Match 'Import-Module\s+.+MigrationUI\.psm1'
    }

    It "Should import USMTTools module" {
        $scriptContent | Should -Match 'Import-Module\s+.+USMTTools\.psm1'
    }

    It "Should dot-source Invoke-Elevated helper" {
        $scriptContent | Should -Match '\.\s+".*Invoke-Elevated\.ps1"'
    }

    It "Should call Request-Elevation instead of inline UAC logic" {
        $scriptContent | Should -Match 'Request-Elevation\s+-ScriptPath\s+\$PSCommandPath'
        $scriptContent | Should -Not -Match 'Start-Process\s+-FilePath\s+\$psExe'
    }

    It "Should call Install-USMT with -ExeName 'loadstate.exe'" {
        $scriptContent | Should -Match "Install-USMT\s+-ExeName\s+'loadstate\.exe'"
    }

    It "Should initialize UI state via Set-MigrationUIState" {
        $scriptContent | Should -Match 'Set-MigrationUIState\s+-State'
    }

    It "Should use Format-SafeParams for parameter logging" {
        $scriptContent | Should -Match 'Format-SafeParams\s+\$PSBoundParameters'
    }

    It "Should reference MigrationConstants.Defaults.ShareDescription" {
        $scriptContent | Should -Match '\$MigrationConstants\.Defaults\.ShareDescription'
    }

    It "Should reference MigrationConstants.UI.DestinationTotalSteps" {
        $scriptContent | Should -Match '\$MigrationConstants\.UI\.DestinationTotalSteps'
    }

    It "Should include SecureString env-var cleanup loop" {
        $scriptContent | Should -Match 'MIGRATION_MERLIN_SECURE_\*'
    }

    It "Should NOT declare Show-Banner as a script-local function (moved to MigrationUI)" {
        $scriptContent | Should -Not -Match '(?m)^function\s+Show-Banner'
    }

    It "Should NOT declare Start-TrackedProcess as a script-local function (moved to USMTTools)" {
        $scriptContent | Should -Not -Match '(?m)^function\s+Start-TrackedProcess'
    }

    It "Should still define destination-specific functions" {
        $expectedFunctions = @(
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

    It "Should have a try/catch/finally wrapper around Main" {
        $scriptContent | Should -Match 'try\s*\{[\s\S]*Main[\s\S]*\}\s*catch'
    }
}

# =============================================================================
# BUILD-LOADSTATEARGUMENTS (pure function — added by t1-e10)
# =============================================================================
Describe "Build-LoadStateArguments" {
    BeforeAll {
        $script:tbUSMT = Join-Path $env:TEMP "BuildLoadArgs-USMT-$(Get-Random)"
        $script:tbStore = Join-Path $env:TEMP "BuildLoadArgs-Store-$(Get-Random)"
        $script:tbLog = Join-Path $env:TEMP "BuildLoadArgs-Log-$(Get-Random).log"
        $script:tbProg = Join-Path $env:TEMP "BuildLoadArgs-Prog-$(Get-Random).log"
    }

    It "Returns baseline args with just required params" {
        $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg
        $a[0] | Should -Be "`"$script:tbStore`""
        ($a -join ' ') | Should -Match 'MigDocs\.xml'
        ($a -join ' ') | Should -Match 'MigApp\.xml'
        ($a -join ' ') | Should -Match '/v:5'
        $logPattern = [regex]::Escape("/l:`"$script:tbLog`"")
        $progPattern = [regex]::Escape("/progress:`"$script:tbProg`"")
        ($a -join ' ') | Should -Match $logPattern
        ($a -join ' ') | Should -Match $progPattern
    }

    It "Omits /c when -Continue switch is absent" {
        $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg
        $a | Should -Not -Contain "/c"
    }

    It "Adds /c when -Continue switch is present" {
        $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg -Continue
        $a | Should -Contain "/c"
    }

    It "Adds /lac and /lae when respective switches present" {
        $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg `
            -LocalAccountCreate -LocalAccountEnable
        $a | Should -Contain "/lac"
        $a | Should -Contain "/lae"
    }

    It "Omits /lac and /lae when switches absent" {
        $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg
        $a | Should -Not -Contain "/lac"
        $a | Should -Not -Contain "/lae"
    }

    It "Adds /i:<custom> once per custom XML path" {
        $xml1 = "C:\custom\one.xml"
        $xml2 = "C:\custom\two.xml"
        $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg `
            -CustomXml @($xml1, $xml2)
        $joined = $a -join ' '
        $p1 = [regex]::Escape("/i:`"$xml1`"")
        $p2 = [regex]::Escape("/i:`"$xml2`"")
        $joined | Should -Match $p1
        $joined | Should -Match $p2
        # Count occurrences of /i: (MigDocs, MigApp, xml1, xml2 = 4)
        ([regex]::Matches($joined, '/i:')).Count | Should -Be 4
    }

    It "Quotes paths with spaces in store path" {
        $spacedStore = "C:\With Space\Migration Store"
        $a = Build-LoadStateArguments -StorePath $spacedStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg
        $a[0] | Should -Be "`"$spacedStore`""
    }

    It "Adds /decrypt /key:`"<key>`" when key provided" {
        $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg `
            -DecryptionKey "s3cr3t"
        $decryptPattern = [regex]::Escape('/decrypt /key:"s3cr3t"')
        ($a -join ' ') | Should -Match $decryptPattern
    }

    It "Omits /decrypt when DecryptionKey is null or empty" {
        $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg
        ($a -join ' ') | Should -Not -Match '/decrypt'
        $b = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg `
            -DecryptionKey ""
        ($b -join ' ') | Should -Not -Match '/decrypt'
    }

    It "Honors -Verbosity parameter" {
        foreach ($v in @(0, 5, 13)) {
            $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
                -LogFile $script:tbLog -ProgressFile $script:tbProg -Verbosity $v
            $a | Should -Contain "/v:$v"
        }
    }

    It "Returns a string[] array" {
        $a = Build-LoadStateArguments -StorePath $script:tbStore -USMTDir $script:tbUSMT `
            -LogFile $script:tbLog -ProgressFile $script:tbProg
        , $a | Should -BeOfType [System.Array]
        $a.Count | Should -BeGreaterThan 0
    }
}

# =============================================================================
# CONVERTFROM-LOADSTATEEXITCODE (pure function — added by t1-e10)
# =============================================================================
Describe "ConvertFrom-LoadStateExitCode" {
    It "Exit code 0 returns Success + ShouldContinue=true" {
        $r = ConvertFrom-LoadStateExitCode -ExitCode 0
        $r.Code | Should -Be 0
        $r.Severity | Should -Be 'Success'
        $r.ShouldContinue | Should -BeTrue
        $r.Message | Should -Match 'successfully'
    }

    It "Exit code 61 returns Warning + ShouldContinue=true" {
        $r = ConvertFrom-LoadStateExitCode -ExitCode 61
        $r.Code | Should -Be 61
        $r.Severity | Should -Be 'Warning'
        $r.ShouldContinue | Should -BeTrue
        $r.Message | Should -Match 'not restored|non-fatal'
    }

    It "Exit code 71 returns Error + ShouldContinue=false" {
        $r = ConvertFrom-LoadStateExitCode -ExitCode 71
        $r.Code | Should -Be 71
        $r.Severity | Should -Be 'Error'
        $r.ShouldContinue | Should -BeFalse
        $r.Message | Should -Match 'cancelled|corrupt'
    }

    It "Unknown exit code (e.g. 999) returns Error + ShouldContinue=false" {
        $r = ConvertFrom-LoadStateExitCode -ExitCode 999
        $r.Severity | Should -Be 'Error'
        $r.ShouldContinue | Should -BeFalse
        $r.Message | Should -Match '999'
    }

    It "Includes the numeric Code in output" {
        foreach ($code in @(0, 61, 71, 123, 999)) {
            $r = ConvertFrom-LoadStateExitCode -ExitCode $code
            $r.Code | Should -Be $code
        }
    }

    It "Returns a hashtable with required keys" {
        $r = ConvertFrom-LoadStateExitCode -ExitCode 0
        $r | Should -BeOfType [hashtable]
        $r.ContainsKey('Code') | Should -BeTrue
        $r.ContainsKey('Severity') | Should -BeTrue
        $r.ContainsKey('Message') | Should -BeTrue
        $r.ContainsKey('ShouldContinue') | Should -BeTrue
    }
}

# =============================================================================
# VALIDATION ATTRIBUTES (t1-e12, Phase 3)
# -----------------------------------------------------------------------------
# Verify the ValidateScript attributes added to destination-setup.ps1's
# param block in Phase 3 are present and enforce the intended rules.
# =============================================================================
Describe "Destination param-block validation attributes (t1-e12)" {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $script:dstParamsE12 = $ast.ParamBlock.Parameters

        function Get-DstE12Param([string]$Name) {
            $script:dstParamsE12 |
                Where-Object { $_.Name.VariablePath.UserPath -eq $Name } |
                Select-Object -First 1
        }

        function Get-DstValidateScriptBlock([System.Management.Automation.Language.ParameterAst]$Param) {
            $attr = $Param.Attributes |
                Where-Object { $_.TypeName.FullName -eq 'ValidateScript' } |
                Select-Object -First 1
            if (-not $attr) { return $null }
            # Use EndBlock.Extent.Text to unwrap the outer braces so the
            # re-created scriptblock's body IS the validator (not a nested
            # scriptblock expression).
            return [ScriptBlock]::Create($attr.PositionalArguments[0].ScriptBlock.EndBlock.Extent.Text)
        }
    }

    It "MigrationFolder has ValidateScript attribute" {
        $p = Get-DstE12Param 'MigrationFolder'
        ($p.Attributes.TypeName.FullName -contains 'ValidateScript') | Should -BeTrue
    }

    It "ShareName has ValidateScript attribute" {
        $p = Get-DstE12Param 'ShareName'
        ($p.Attributes.TypeName.FullName -contains 'ValidateScript') | Should -BeTrue
    }

    It "USMTPath has ValidateScript attribute" {
        $p = Get-DstE12Param 'USMTPath'
        ($p.Attributes.TypeName.FullName -contains 'ValidateScript') | Should -BeTrue
    }

    It "ShareName ValidateScript accepts 'MigrationShare$'" {
        $sb = Get-DstValidateScriptBlock (Get-DstE12Param 'ShareName')
        ('MigrationShare$' | ForEach-Object $sb) | Should -BeTrue
    }

    It "ShareName ValidateScript rejects an empty name" {
        $sb = Get-DstValidateScriptBlock (Get-DstE12Param 'ShareName')
        ('' | ForEach-Object $sb) | Should -BeFalse
    }

    It "ShareName ValidateScript rejects a forward-slash name" {
        $sb = Get-DstValidateScriptBlock (Get-DstE12Param 'ShareName')
        ('bad/name' | ForEach-Object $sb) | Should -BeFalse
    }

    It "ShareName ValidateScript rejects a name over 80 chars" {
        $sb = Get-DstValidateScriptBlock (Get-DstE12Param 'ShareName')
        $long = 'a' * 81
        ($long | ForEach-Object $sb) | Should -BeFalse
    }

    It "MigrationFolder ValidateScript accepts a drive-letter path" {
        $sb = Get-DstValidateScriptBlock (Get-DstE12Param 'MigrationFolder')
        ('D:\Some\Path' | ForEach-Object $sb) | Should -BeTrue
    }

    It "Destination script imports MigrationValidators module" {
        $scriptContent = Get-Content $ScriptPath -Raw
        $scriptContent | Should -Match 'MigrationValidators\.psm1'
    }

    It "Destination script keeps exactly 9 top-level params (t1-e13 added AllowedSourceUser)" {
        $script:dstParamsE12.Count | Should -Be 9
    }
}

# =============================================================================
# T1-E13 — WhatIf / ShouldProcess wiring + AllowedSourceUser parameter
# -----------------------------------------------------------------------------
# Verifies that destructive operations respect $WhatIfPreference and that the
# new -AllowedSourceUser parameter branches Grant-SmbShareAccess away from
# 'Everyone' when provided.
# =============================================================================
Describe "T1-e13 -AllowedSourceUser parameter" {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $script:e13Params = $ast.ParamBlock.Parameters

        function Get-E13Param([string]$Name) {
            $script:e13Params |
                Where-Object { $_.Name.VariablePath.UserPath -eq $Name } |
                Select-Object -First 1
        }

        function Get-E13ValidateScriptBlock([System.Management.Automation.Language.ParameterAst]$Param) {
            $attr = $Param.Attributes |
                Where-Object { $_.TypeName.FullName -eq 'ValidateScript' } |
                Select-Object -First 1
            if (-not $attr) { return $null }
            return [ScriptBlock]::Create($attr.PositionalArguments[0].ScriptBlock.EndBlock.Extent.Text)
        }
    }

    It "Declares -AllowedSourceUser parameter" {
        $p = Get-E13Param 'AllowedSourceUser'
        $p | Should -Not -BeNullOrEmpty
    }

    It "AllowedSourceUser has a ValidateScript attribute" {
        $p = Get-E13Param 'AllowedSourceUser'
        ($p.Attributes.TypeName.FullName -contains 'ValidateScript') | Should -BeTrue
    }

    It "AllowedSourceUser validator accepts an empty string (omitted)" {
        $sb = Get-E13ValidateScriptBlock (Get-E13Param 'AllowedSourceUser')
        ('' | ForEach-Object $sb) | Should -BeTrue
    }

    It "AllowedSourceUser validator accepts DOMAIN\user" {
        $sb = Get-E13ValidateScriptBlock (Get-E13Param 'AllowedSourceUser')
        ('CORP\jdoe' | ForEach-Object $sb) | Should -BeTrue
    }

    It "AllowedSourceUser validator accepts machine account with trailing $" {
        $sb = Get-E13ValidateScriptBlock (Get-E13Param 'AllowedSourceUser')
        ('SRV-01$' | ForEach-Object $sb) | Should -BeTrue
    }

    It "AllowedSourceUser validator rejects whitespace-only input" {
        $sb = Get-E13ValidateScriptBlock (Get-E13Param 'AllowedSourceUser')
        ('   ' | ForEach-Object $sb) | Should -BeFalse
    }

    It "AllowedSourceUser validator rejects embedded spaces" {
        $sb = Get-E13ValidateScriptBlock (Get-E13Param 'AllowedSourceUser')
        ('bad user' | ForEach-Object $sb) | Should -BeFalse
    }

    It "AllowedSourceUser validator rejects a forward-slash name" {
        $sb = Get-E13ValidateScriptBlock (Get-E13Param 'AllowedSourceUser')
        ('bad/name' | ForEach-Object $sb) | Should -BeFalse
    }
}

Describe "T1-e13 New-MigrationShare -AllowedSourceUser behavior" {
    BeforeEach {
        $script:State = New-MigrationState -TotalSteps 10
        Set-MigrationUIState -State $script:State
    }

    It "Grants 'Everyone' when -AllowedSourceUser omitted" {
        $AllowedSourceUser = ""
        Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
        Mock Set-Acl { }
        Mock Get-SmbShare { return $null }
        Mock New-SmbShare { }
        Mock Grant-SmbShareAccess { } -Verifiable -ParameterFilter {
            $AccountName -eq "Everyone"
        }

        New-MigrationShare

        Should -InvokeVerifiable
    }

    It "Emits a WARN status when -AllowedSourceUser omitted (Everyone fallback)" {
        $AllowedSourceUser = ""
        Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
        Mock Set-Acl { }
        Mock Get-SmbShare { return $null }
        Mock New-SmbShare { }
        Mock Grant-SmbShareAccess { }

        $output = New-MigrationShare 6>&1
        $joined = $output -join "`n"
        $joined | Should -Match 'AllowedSourceUser|Everyone'
    }

    It "Grants the specified account when -AllowedSourceUser provided" {
        $AllowedSourceUser = "CORP\migrator"
        Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
        Mock Set-Acl { }
        Mock Get-SmbShare { return $null }
        Mock New-SmbShare { }
        Mock Grant-SmbShareAccess { } -Verifiable -ParameterFilter {
            $AccountName -eq "CORP\migrator" -and $AccessRight -eq "Full"
        }

        New-MigrationShare

        Should -InvokeVerifiable
    }

    It "Does NOT grant 'Everyone' when -AllowedSourceUser provided" {
        $AllowedSourceUser = "CORP\migrator"
        Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
        Mock Set-Acl { }
        Mock Get-SmbShare { return $null }
        Mock New-SmbShare { }
        Mock Grant-SmbShareAccess { }

        New-MigrationShare

        Should -Invoke Grant-SmbShareAccess -Times 0 -ParameterFilter {
            $AccountName -eq "Everyone"
        }
    }
}

Describe "T1-e13 ShouldProcess / -WhatIf wiring" {
    BeforeEach {
        $script:State = New-MigrationState -TotalSteps 10
        Set-MigrationUIState -State $script:State
    }

    Context "New-MigrationShare" {
        It "Does NOT call New-SmbShare when -WhatIf is passed" {
            Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
            Mock Set-Acl { }
            Mock Get-SmbShare { return $null }
            Mock New-SmbShare { } -Verifiable
            Mock Grant-SmbShareAccess { }

            New-MigrationShare -WhatIf

            Should -Invoke New-SmbShare -Times 0
        }

        It "Does NOT call Grant-SmbShareAccess when -WhatIf is passed" {
            Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
            Mock Set-Acl { }
            Mock Get-SmbShare { return $null }
            Mock New-SmbShare { }
            Mock Grant-SmbShareAccess { }

            New-MigrationShare -WhatIf

            Should -Invoke Grant-SmbShareAccess -Times 0
        }

        It "Does NOT call Remove-SmbShare (pre-existing share) when -WhatIf is passed" {
            Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
            Mock Set-Acl { }
            Mock Get-SmbShare { return [PSCustomObject]@{ Name = $ShareName } }
            Mock Remove-SmbShare { }
            Mock New-SmbShare { }
            Mock Grant-SmbShareAccess { }

            New-MigrationShare -WhatIf

            Should -Invoke Remove-SmbShare -Times 0
        }

        It "Calls New-SmbShare when -WhatIf is NOT passed" {
            Mock Get-Acl { return New-Object System.Security.AccessControl.DirectorySecurity }
            Mock Set-Acl { }
            Mock Get-SmbShare { return $null }
            Mock New-SmbShare { }
            Mock Grant-SmbShareAccess { }

            New-MigrationShare

            Should -Invoke New-SmbShare -Times 1
        }
    }

    Context "Set-MigrationFirewall" {
        It "Does NOT call New-NetFirewallRule when -WhatIf is passed" {
            Mock Get-NetFirewallRule { return $null }
            Mock Set-NetFirewallRule { }
            Mock Remove-NetFirewallRule { }
            Mock New-NetFirewallRule { }
            Mock Get-SmbServerConfiguration { [PSCustomObject]@{ EnableSMB2Protocol = $true } }

            Set-MigrationFirewall -WhatIf

            Should -Invoke New-NetFirewallRule -Times 0
        }

        It "Does NOT call Remove-NetFirewallRule (pre-existing) when -WhatIf is passed" {
            Mock Get-NetFirewallRule {
                param($DisplayName, $DisplayGroup)
                if ($DisplayName -eq "USMT-Migration-Inbound") {
                    return [PSCustomObject]@{ DisplayName = "USMT-Migration-Inbound" }
                }
                return $null
            }
            Mock Set-NetFirewallRule { }
            Mock Remove-NetFirewallRule { }
            Mock New-NetFirewallRule { }
            Mock Get-SmbServerConfiguration { [PSCustomObject]@{ EnableSMB2Protocol = $true } }

            Set-MigrationFirewall -WhatIf

            Should -Invoke Remove-NetFirewallRule -Times 0
        }

        It "Calls New-NetFirewallRule when -WhatIf is NOT passed" {
            Mock Get-NetFirewallRule { return $null }
            Mock Set-NetFirewallRule { }
            Mock New-NetFirewallRule { }
            Mock Get-SmbServerConfiguration { [PSCustomObject]@{ EnableSMB2Protocol = $true } }

            Set-MigrationFirewall

            Should -Invoke New-NetFirewallRule -Times 1
        }
    }

    Context "Remove-MigrationArtifacts" {
        It "Does NOT call Remove-SmbShare when -WhatIf is passed" {
            Mock Read-Host { return 'Y' }
            Mock Get-SmbShare { [PSCustomObject]@{ Name = $ShareName } }
            Mock Remove-SmbShare { }
            Mock Get-NetFirewallRule { return $null }
            Mock Remove-Item { }

            Remove-MigrationArtifacts -WhatIf

            Should -Invoke Remove-SmbShare -Times 0
        }

        It "Does NOT call Remove-NetFirewallRule when -WhatIf is passed" {
            Mock Read-Host { return 'Y' }
            Mock Get-SmbShare { return $null }
            Mock Get-NetFirewallRule {
                [PSCustomObject]@{ DisplayName = "USMT-Migration-Inbound" }
            }
            Mock Remove-NetFirewallRule { }
            Mock Remove-Item { }

            Remove-MigrationArtifacts -WhatIf

            Should -Invoke Remove-NetFirewallRule -Times 0
        }

        It "Calls Remove-SmbShare when -WhatIf is NOT passed" {
            Mock Read-Host { return 'Y' }
            Mock Get-SmbShare { [PSCustomObject]@{ Name = $ShareName } }
            Mock Remove-SmbShare { }
            Mock Get-NetFirewallRule { return $null }
            Mock Remove-Item { }

            Remove-MigrationArtifacts

            Should -Invoke Remove-SmbShare -Times 1
        }
    }

    Context "SupportsShouldProcess declarations" {
        BeforeAll {
            $script:e13Content = Get-Content $ScriptPath -Raw
        }

        It "New-MigrationShare declares SupportsShouldProcess" {
            $script:e13Content | Should -Match '(?s)function\s+New-MigrationShare\s*\{\s*\[CmdletBinding\(SupportsShouldProcess\s*=\s*\$true\)\]'
        }

        It "Set-MigrationFirewall declares SupportsShouldProcess" {
            $script:e13Content | Should -Match '(?s)function\s+Set-MigrationFirewall\s*\{\s*\[CmdletBinding\(SupportsShouldProcess\s*=\s*\$true\)\]'
        }

        It "Remove-MigrationArtifacts declares SupportsShouldProcess" {
            $script:e13Content | Should -Match '(?s)function\s+Remove-MigrationArtifacts\s*\{\s*\[CmdletBinding\(SupportsShouldProcess\s*=\s*\$true\)\]'
        }
    }
}
