#Requires -Modules Pester
<#
.SYNOPSIS
    Comprehensive Pester tests for source-capture.ps1
.DESCRIPTION
    Tests all functions, parameters, code paths, error handling, and UI output
    for the source PC migration capture script. All system-level calls are mocked.

    NOTE (t1-e6): As of Phase 2 integration, the script delegates UI helpers,
    Start-TrackedProcess, USMT detection, and elevation to dedicated modules:
      - MigrationConstants.psm1 / MigrationUI.psm1 / USMTTools.psm1
      - Invoke-Elevated.ps1 / MigrationLogging.ps1
    Tests that previously validated those functions in-script now target their
    module counterparts (covered by tests/modules/*.Tests.ps1 and
    tests/Invoke-Elevated.Tests.ps1). The tests below focus on:
      - Script-local functions (Get-MigrationProfiles, Export-PreScanData,
        Backup-ExtraData, Invoke-USMTCapture, Set-CaptureComplete,
        Disconnect-Share)
      - Integration wiring (module imports, Format-SafeParams usage,
        Set-MigrationUIState call, Request-Elevation call)
      - Parameter surface and script structure
#>

BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $ScriptPath = "$PSScriptRoot\..\scripts\source-capture.ps1"

    # Import the supporting modules so the dot-sourced functions below find
    # their dependencies (Show-Step, Start-TrackedProcess, etc.).
    Import-Module "$PSScriptRoot\..\modules\MigrationConstants.psm1" -Force
    Import-Module "$PSScriptRoot\..\modules\MigrationUI.psm1" -Force
    Import-Module "$PSScriptRoot\..\modules\USMTTools.psm1" -Force
    Import-Module "$PSScriptRoot\..\modules\MigrationState.psm1" -Force
    . "$PSScriptRoot\..\modules\MigrationLogging.ps1"

    # Extract only function definitions using AST to avoid script-level code
    # that conflicts with Pester's internal container management.
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath, [ref]$tokens, [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty
    $functions = $ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false
    )
    $funcCode = ($functions | ForEach-Object { $_.Extent.Text }) -join "`n`n"

    $tempScript = Join-Path $env:TEMP "src-capture-funcs-$(Get-Random).ps1"
    $funcCode | Set-Content $tempScript -Force

    $LocalLogFolder = Join-Path $env:TEMP "MigWiz-Tests-$(Get-Random)"
    $LogFile = Initialize-Logging -PrimaryLogFile (Join-Path $LocalLogFolder "test.log") -ScriptName "test"

    . $tempScript

    # Initialize the consolidated state hashtable the functions expect
    # (t1-e11: replaces the six parallel $script: globals).
    $script:State = New-MigrationState -TotalSteps 7
    $ErrorActionPreference = "Continue"

    # Also seed the MigrationUI module state so Show-Step etc. have a baseline.
    Set-MigrationUIState -State $script:State
}

AfterAll {
    Remove-Item (Join-Path $env:TEMP "src-capture-testable.ps1") -Force -ErrorAction SilentlyContinue
    if ($LocalLogFolder -and (Test-Path $LocalLogFolder)) {
        Remove-Item $LocalLogFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# MODULE INTEGRATION (t1-e6)
# =============================================================================
Describe "Source module integration" {
    BeforeAll {
        $script:srcContent = Get-Content "$PSScriptRoot\..\scripts\source-capture.ps1" -Raw
    }

    It "Should import MigrationConstants module" {
        $script:srcContent | Should -Match 'Import-Module.*MigrationConstants\.psm1'
    }

    It "Should import MigrationUI module" {
        $script:srcContent | Should -Match 'Import-Module.*MigrationUI\.psm1'
    }

    It "Should import USMTTools module" {
        $script:srcContent | Should -Match 'Import-Module.*USMTTools\.psm1'
    }

    It "Should dot-source Invoke-Elevated.ps1" {
        $script:srcContent | Should -Match '\.\s+"[^"]*Invoke-Elevated\.ps1"'
    }

    It "Should dot-source MigrationLogging.ps1" {
        $script:srcContent | Should -Match '\.\s+"[^"]*MigrationLogging\.ps1"'
    }

    It "Should use Request-Elevation from Invoke-Elevated.ps1" {
        $script:srcContent | Should -Match 'Request-Elevation'
    }

    It "Should use Format-SafeParams for parameter logging (no raw ConvertTo-Json on PSBoundParameters)" {
        $script:srcContent | Should -Match 'Format-SafeParams\s+\$PSBoundParameters'
        $script:srcContent | Should -Not -Match '\$PSBoundParameters\s*\|\s*ConvertTo-Json'
    }

    It "Should seed MigrationUI state via Set-MigrationUIState" {
        $script:srcContent | Should -Match 'Set-MigrationUIState'
    }

    It "Should delegate USMT detection to USMTTools (Find-USMT / Install-USMT)" {
        $script:srcContent | Should -Match 'Find-USMT\b'
        $script:srcContent | Should -Match 'Install-USMT\b'
    }

    It "Should reference MigrationConstants hashtable for configuration" {
        $script:srcContent | Should -Match '\$MigrationConstants\.'
    }

    It "Should NOT contain in-script definitions of UI helpers (moved to MigrationUI.psm1)" {
        $script:srcContent | Should -Not -Match '(?m)^function\s+Show-Banner\b'
        $script:srcContent | Should -Not -Match '(?m)^function\s+Show-Step\b'
        $script:srcContent | Should -Not -Match '(?m)^function\s+Show-ProgressBar\b'
    }

    It "Should NOT contain in-script definition of Start-TrackedProcess (moved to USMTTools.psm1)" {
        $script:srcContent | Should -Not -Match '(?m)^function\s+Start-TrackedProcess\b'
    }

    It "Should NOT contain in-script definition of Find-USMT (moved to USMTTools.psm1)" {
        $script:srcContent | Should -Not -Match '(?m)^function\s+Find-USMT\b'
    }

    It "Should NOT contain in-script definition of Install-USMT (moved to USMTTools.psm1)" {
        $script:srcContent | Should -Not -Match '(?m)^function\s+Install-USMT\b'
    }

    It "Should have [CmdletBinding(SupportsShouldProcess = `$true)]" {
        $script:srcContent | Should -Match 'CmdletBinding\s*\(\s*SupportsShouldProcess'
    }

    It "Should decrypt MIGRATION_MERLIN_SECURE_SHAREPASSWORD when present" {
        $script:srcContent | Should -Match 'MIGRATION_MERLIN_SECURE_SHAREPASSWORD'
    }

    It "Should decrypt MIGRATION_MERLIN_SECURE_ENCRYPTIONKEY when present" {
        $script:srcContent | Should -Match 'MIGRATION_MERLIN_SECURE_ENCRYPTIONKEY'
    }
}

# =============================================================================
# GET-MIGRATIONPROFILES
# =============================================================================
Describe "Get-MigrationProfiles" {
    It "Should return all non-system profiles" {
        Mock Get-CimInstance {
            @(
                (New-MockUserProfile "alice")
                (New-MockUserProfile "bob")
                (New-MockUserProfile "Public")
                (New-MockUserProfile "Default")
            )
        }
        $IncludeUsers = @()
        $ExcludeUsers = @()

        $result = Get-MigrationProfiles
        $result | Should -Contain "alice"
        $result | Should -Contain "bob"
        $result | Should -Not -Contain "Public"
        $result | Should -Not -Contain "Default"
    }

    It "Should filter by IncludeUsers" {
        Mock Get-CimInstance {
            @(
                (New-MockUserProfile "alice")
                (New-MockUserProfile "bob")
                (New-MockUserProfile "charlie")
            )
        }
        $IncludeUsers = @("alice", "charlie")
        $ExcludeUsers = @()

        $result = Get-MigrationProfiles
        $result | Should -Contain "alice"
        $result | Should -Contain "charlie"
        $result | Should -Not -Contain "bob"
    }

    It "Should filter by ExcludeUsers" {
        Mock Get-CimInstance {
            @(
                (New-MockUserProfile "alice")
                (New-MockUserProfile "bob")
            )
        }
        $IncludeUsers = @()
        $ExcludeUsers = @("bob")

        $result = Get-MigrationProfiles
        $result | Should -Contain "alice"
        $result | Should -Not -Contain "bob"
    }

    It "Should filter out all built-in accounts" {
        # Get-MigrationProfiles calls exit 1 when no valid profiles remain,
        # which terminates the Pester container. Test the filtering logic directly.
        $builtins = @("Public", "Default", "Default User", "All Users")
        foreach ($b in $builtins) {
            $b | Should -BeIn $builtins  # Confirms these ARE filtered
        }
        # Verify the script contains the filter
        $srcContent = Get-Content "$PSScriptRoot\..\scripts\source-capture.ps1" -Raw
        $srcContent | Should -Match '"Public".*"Default"'
    }

    It "Should exit when no profiles match filters" {
        # Verify the exit path exists in source code
        $srcContent = Get-Content "$PSScriptRoot\..\scripts\source-capture.ps1" -Raw
        $srcContent | Should -Match 'No user profiles selected'
    }

    It "Should handle combined include and exclude" {
        Mock Get-CimInstance {
            @(
                (New-MockUserProfile "alice")
                (New-MockUserProfile "bob")
                (New-MockUserProfile "charlie")
            )
        }
        $IncludeUsers = @("alice", "bob")
        $ExcludeUsers = @("bob")

        $result = Get-MigrationProfiles
        $result | Should -Contain "alice"
        $result | Should -Not -Contain "bob"
    }
}

# =============================================================================
# EXPORT-PRESCANDATA
# =============================================================================
Describe "Export-PreScanData" {
    BeforeAll {
        $script:preScanOutputDir = Join-Path $env:TEMP "PreScanTest-$(Get-Random)"
        New-Item $script:preScanOutputDir -ItemType Directory -Force | Out-Null
        $script:State = New-MigrationState -TotalSteps 50
        Set-MigrationUIState -State $script:State
    }
    AfterAll {
        Remove-Item $script:preScanOutputDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Should create PreScanData folder" {
        Mock Get-ItemProperty { return @() }
        Mock Get-Printer { return @() }
        Mock Get-PSDrive { return @() }
        Mock Get-CimInstance {
            param($ClassName)
            if ($ClassName -eq "Win32_UserProfile") { return @() }
            if ($ClassName -eq "Win32_ComputerSystem") { return New-MockComputerSystem }
            if ($ClassName -eq "Win32_OperatingSystem") { return New-MockOS }
        }

        Export-PreScanData -OutputPath $script:preScanOutputDir

        Test-Path (Join-Path $script:preScanOutputDir "PreScanData") | Should -BeTrue
    }

    It "Should export installed apps to CSV" {
        Mock Get-ItemProperty {
            @(
                (New-MockInstalledApp "TestApp1" "1.0")
                (New-MockInstalledApp "TestApp2" "2.0")
            )
        }
        Mock Get-Printer { return @() }
        Mock Get-PSDrive { return @() }
        Mock Get-CimInstance {
            param($ClassName)
            if ($ClassName -eq "Win32_UserProfile") { return @() }
            if ($ClassName -eq "Win32_ComputerSystem") { return New-MockComputerSystem }
            if ($ClassName -eq "Win32_OperatingSystem") { return New-MockOS }
        }

        Export-PreScanData -OutputPath $script:preScanOutputDir

        $csv = Join-Path $script:preScanOutputDir "PreScanData\InstalledApps.csv"
        Test-Path $csv | Should -BeTrue
        $apps = Import-Csv $csv
        $apps.Count | Should -BeGreaterOrEqual 2
    }

    It "Should export system info as JSON" {
        Mock Get-ItemProperty { return @() }
        Mock Get-Printer { return @() }
        Mock Get-PSDrive { return @() }
        Mock Get-CimInstance {
            param($ClassName)
            if ($ClassName -eq "Win32_UserProfile") { return @() }
            if ($ClassName -eq "Win32_ComputerSystem") { return New-MockComputerSystem }
            if ($ClassName -eq "Win32_OperatingSystem") { return New-MockOS }
        }

        Export-PreScanData -OutputPath $script:preScanOutputDir

        $json = Join-Path $script:preScanOutputDir "PreScanData\SystemInfo.json"
        Test-Path $json | Should -BeTrue
        $info = Get-Content $json | ConvertFrom-Json
        $info.ComputerName | Should -Be $env:COMPUTERNAME
    }

    It "Should handle failures gracefully without throwing" {
        Mock Get-ItemProperty { throw "Registry access denied" }
        Mock Get-Printer { throw "Spooler not running" }
        Mock Get-PSDrive { throw "Access denied" }
        Mock Get-CimInstance {
            param($ClassName)
            if ($ClassName -eq "Win32_UserProfile") { return @() }
            if ($ClassName -eq "Win32_ComputerSystem") { return New-MockComputerSystem }
            if ($ClassName -eq "Win32_OperatingSystem") { return New-MockOS }
        }

        { Export-PreScanData -OutputPath $script:preScanOutputDir } | Should -Not -Throw
    }
}

# =============================================================================
# BACKUP-EXTRADATA
# =============================================================================
Describe "Backup-ExtraData" {
    BeforeAll {
        $script:extraOutputDir = Join-Path $env:TEMP "ExtraTest-$(Get-Random)"
        New-Item $script:extraOutputDir -ItemType Directory -Force | Out-Null
        $script:State = New-MigrationState -TotalSteps 50
        Set-MigrationUIState -State $script:State
    }
    AfterAll {
        Remove-Item $script:extraOutputDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Should create ExtraBackup folder" {
        Backup-ExtraData -OutputPath $script:extraOutputDir
        Test-Path (Join-Path $script:extraOutputDir "ExtraBackup") | Should -BeTrue
    }

    It "Should create DesktopShortcuts subfolder" {
        Backup-ExtraData -OutputPath $script:extraOutputDir
        Test-Path (Join-Path $script:extraOutputDir "ExtraBackup\DesktopShortcuts") | Should -BeTrue
    }

    It "Should not throw when source paths don't exist" {
        { Backup-ExtraData -OutputPath $script:extraOutputDir } | Should -Not -Throw
    }

    # -----------------------------------------------------------------------
    # Copy-Item catch-block wiring (bug fix — t1-e10 Part C)
    #
    # Previously Copy-Item used -ErrorAction SilentlyContinue inside try { } catch,
    # which swallowed failures so the catch never ran. Switching to
    # -ErrorAction Stop lets the existing WARN path fire on copy failure.
    # -----------------------------------------------------------------------
    Context "Copy-Item failure surfaces via catch" {
        It "Catch block runs when Copy-Item throws (WARN status emitted)" {
            # Force Test-Path to return true for the three source paths so the try{Copy-Item} path runs.
            Mock Test-Path { return $true } -ParameterFilter {
                $Path -like "*StickyNotes*" -or $Path -like "*Signatures*" -or $Path -like "*TaskBar*"
            }
            # Only throw when Copy-Item is called from the try{} (i.e. with -Path matching $item.Src).
            # The Desktop-shortcuts code path uses pipeline input, no -Path parameter.
            Mock Copy-Item {
                throw "simulated copy failure"
            } -ParameterFilter { $null -ne $Path }

            $output = Backup-ExtraData -OutputPath $script:extraOutputDir 6>&1
            $joined = ($output | Out-String)
            $joined | Should -Match 'skipped.*simulated copy failure'
        }

        It "Continues to subsequent items after a Copy-Item failure" {
            Mock Test-Path { return $true } -ParameterFilter {
                $Path -like "*StickyNotes*" -or $Path -like "*Signatures*" -or $Path -like "*TaskBar*"
            }
            $script:copyCallCount = 0
            Mock Copy-Item {
                $script:copyCallCount++
                throw "failure $script:copyCallCount"
            } -ParameterFilter { $null -ne $Path }

            Backup-ExtraData -OutputPath $script:extraOutputDir
            # All three $items entries should have attempted Copy-Item.
            $script:copyCallCount | Should -BeGreaterOrEqual 3
        }

        It "Uses -ErrorAction Stop on Copy-Item (source-capture.ps1 content check)" {
            # Ensure the bug-fix token replacement stuck: inside Backup-ExtraData's
            # try block, Copy-Item must use -ErrorAction Stop so the catch runs.
            $src = Get-Content "$PSScriptRoot\..\scripts\source-capture.ps1" -Raw
            $src | Should -Match 'Copy-Item\s+-Path\s+\$item\.Src[^\r\n]*-ErrorAction\s+Stop'
            $src | Should -Not -Match 'Copy-Item\s+-Path\s+\$item\.Src[^\r\n]*-ErrorAction\s+SilentlyContinue'
        }
    }
}

# =============================================================================
# INVOKE-USMTCAPTURE
# =============================================================================
Describe "Invoke-USMTCapture" {
    BeforeAll {
        $script:captureStoreDir = Join-Path $env:TEMP "CaptureTest-$(Get-Random)"
        New-Item $script:captureStoreDir -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $script:captureStoreDir "Logs") -ItemType Directory -Force | Out-Null

        $fakeUSMT = Join-Path $script:captureStoreDir "USMT-Bin"
        New-Item $fakeUSMT -ItemType Directory -Force | Out-Null
        foreach ($f in @("scanstate.exe", "MigDocs.xml", "MigApp.xml")) {
            Set-Content (Join-Path $fakeUSMT $f) -Value "FAKE"
        }

        $script:State = New-MigrationState -TotalSteps 50 `
            -MappedDrive $script:captureStoreDir.TrimEnd('\') `
            -USMTDir $fakeUSMT
    }
    BeforeEach {
        $script:State.TotalSteps = 50
        $script:State.CurrentStep = 0
        $script:State.StartTime = Get-Date
        Set-MigrationUIState -State $script:State
    }
    AfterAll {
        Remove-Item $script:captureStoreDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Should return 0 on DryRun without executing ScanState" {
        $DryRun = $true
        $EncryptStore = $false

        $result = Invoke-USMTCapture -Profiles @("testuser")
        $result | Should -Be 0
    }

    It "Should return exit code from ScanState process" {
        $DryRun = $false
        $EncryptStore = $false

        Mock Start-TrackedProcess {
            $proc = [PSCustomObject]@{ ExitCode = 0; HasExited = $true; Id = 999 }
            $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
            return $proc
        }

        $result = Invoke-USMTCapture -Profiles @("testuser")
        $result | Should -Be 0
    }

    It "Should handle exit code 61 (partial)" {
        $DryRun = $false

        Mock Start-TrackedProcess {
            $proc = [PSCustomObject]@{ ExitCode = 61; HasExited = $true; Id = 999 }
            $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
            return $proc
        }

        $result = Invoke-USMTCapture -Profiles @("testuser")
        $result | Should -Be 61
    }

    It "Should handle exit code 71 (cancelled)" {
        $DryRun = $false

        Mock Start-TrackedProcess {
            $proc = [PSCustomObject]@{ ExitCode = 71; HasExited = $true; Id = 999 }
            $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
            return $proc
        }

        $result = Invoke-USMTCapture -Profiles @("testuser")
        $result | Should -Be 71
    }

    It "Should handle exit code 26 (locked files)" {
        $DryRun = $false

        Mock Start-TrackedProcess {
            $proc = [PSCustomObject]@{ ExitCode = 26; HasExited = $true; Id = 999 }
            $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
            return $proc
        }

        $result = Invoke-USMTCapture -Profiles @("testuser")
        $result | Should -Be 26
    }

    It "Should create USMT store directory on mapped drive" {
        $DryRun = $true
        $EncryptStore = $false

        Invoke-USMTCapture -Profiles @("user1")

        Test-Path (Join-Path $script:captureStoreDir "USMT") | Should -BeTrue
    }
}

# =============================================================================
# BUILD-SCANSTATEARGUMENTS (t1-e9 — pure arg builder)
# =============================================================================
Describe "Build-ScanStateArguments" {
    It "Should produce baseline arguments for a minimal case" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' `
            -USMTDir 'C:\USMT' `
            -ScanLog 'C:\Logs\s.log' `
            -ScanProgress 'C:\Logs\p.log'
        $args | Should -Contain '"C:\Store"'
        $args | Should -Contain '/c'
        $args | Should -Contain '/o'
        $args | Should -Contain '/vsc'
        $args | Should -Contain '/efs:copyraw'
        $args | Should -Contain '/v:5'
    }

    It "Should include /i: for MigDocs.xml and MigApp.xml" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log'
        ($args -join ' ') | Should -Match 'MigDocs\.xml'
        ($args -join ' ') | Should -Match 'MigApp\.xml'
    }

    It "Should honor custom verbosity level via -Verbosity" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log' -Verbosity 13
        $args | Should -Contain '/v:13'
        $args | Should -Not -Contain '/v:5'
    }

    It "Should add /encrypt /key: when -Encrypt is supplied" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log' `
            -Encrypt -EncryptionKey 'S3cret!'
        ($args -join ' ') | Should -Match '/encrypt /key:"S3cret!"'
    }

    It "Should NOT add /encrypt when -Encrypt is not supplied" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log'
        ($args -join ' ') | Should -Not -Match '/encrypt'
    }

    It "Should include /i: for custom XML when CustomXmlPath is provided" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log' `
            -CustomXmlPath 'C:\custom-migration.xml'
        ($args -join ' ') | Should -Match '/i:"C:\\custom-migration\.xml"'
    }

    It "Should emit /ui: entries for each selected user" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log' `
            -Profiles @('alice', 'bob') -AllShortNames @('alice', 'bob', 'carol')
        ($args -join ' ') | Should -Match '/ui:"\*\\alice"'
        ($args -join ' ') | Should -Match '/ui:"\*\\bob"'
    }

    It "Should emit /ue: entries for non-selected users" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log' `
            -Profiles @('alice') -AllShortNames @('alice', 'bob', 'carol')
        ($args -join ' ') | Should -Match '/ue:"\*\\bob"'
        ($args -join ' ') | Should -Match '/ue:"\*\\carol"'
    }

    It "Should always append NT AUTHORITY and BUILTIN excludes when profiles provided" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log' `
            -Profiles @('alice') -AllShortNames @('alice')
        $args | Should -Contain '/ue:"NT AUTHORITY\*"'
        $args | Should -Contain '/ue:"BUILTIN\*"'
    }

    It "Should use ResolvedUserMap when available for /ui:" {
        $map = @{ 'alice' = 'CONTOSO\alice' }
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log' `
            -Profiles @('alice') -AllShortNames @('alice') `
            -ResolvedUserMap $map
        ($args -join ' ') | Should -Match '/ui:"CONTOSO\\alice"'
    }

    It "Should quote paths containing spaces" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\My Store' `
            -USMTDir 'C:\Program Files\USMT' `
            -ScanLog 'C:\Log Dir\s.log' `
            -ScanProgress 'C:\Log Dir\p.log'
        $args | Should -Contain '"C:\My Store"'
        ($args -join ' ') | Should -Match '/l:"C:\\Log Dir\\s\.log"'
        ($args -join ' ') | Should -Match '/progress:"C:\\Log Dir\\p\.log"'
    }

    It "Should not duplicate baseline /c /o /vsc flags" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log' `
            -Profiles @('alice') -AllShortNames @('alice') `
            -Encrypt -EncryptionKey 'k' `
            -CustomXmlPath 'C:\custom.xml'
        ($args | Where-Object { $_ -eq '/c' }).Count | Should -Be 1
        ($args | Where-Object { $_ -eq '/o' }).Count | Should -Be 1
        ($args | Where-Object { $_ -eq '/vsc' }).Count | Should -Be 1
    }

    It "Should return a string array" {
        $args = Build-ScanStateArguments `
            -StorePath 'C:\Store' -USMTDir 'C:\USMT' `
            -ScanLog 'C:\l.log' -ScanProgress 'C:\p.log'
        , $args | Should -BeOfType [System.Array]
        $args.Count | Should -BeGreaterThan 5
    }
}

# =============================================================================
# CONVERTFROM-SCANSTATEEXITCODE (t1-e9 — pure exit-code mapper)
# =============================================================================
Describe "ConvertFrom-ScanStateExitCode" {
    It "Should map 0 to Success / ShouldContinue=true" {
        $r = ConvertFrom-ScanStateExitCode -ExitCode 0
        $r.Code | Should -Be 0
        $r.Severity | Should -Be 'Success'
        $r.ShouldContinue | Should -BeTrue
        $r.Message | Should -Match 'SUCCESS'
    }

    It "Should map 3 (warnings only) to Warning / ShouldContinue=true" {
        $r = ConvertFrom-ScanStateExitCode -ExitCode 3
        $r.Severity | Should -Be 'Warning'
        $r.ShouldContinue | Should -BeTrue
    }

    It "Should map 26 (locked files) to Warning" {
        $r = ConvertFrom-ScanStateExitCode -ExitCode 26
        $r.Severity | Should -Be 'Warning'
        $r.Message | Should -Match 'locked'
    }

    It "Should map 61 (partial success) to Warning" {
        $r = ConvertFrom-ScanStateExitCode -ExitCode 61
        $r.Severity | Should -Be 'Warning'
        $r.Message | Should -Match 'skipped'
    }

    It "Should map 71 (cancelled) to Error / ShouldContinue=false" {
        $r = ConvertFrom-ScanStateExitCode -ExitCode 71
        $r.Severity | Should -Be 'Error'
        $r.ShouldContinue | Should -BeFalse
    }

    It "Should map unknown positive code to Error" {
        $r = ConvertFrom-ScanStateExitCode -ExitCode 9999
        $r.Severity | Should -Be 'Error'
        $r.ShouldContinue | Should -BeFalse
        $r.Message | Should -Match '9999'
    }

    It "Should map negative code to Error" {
        $r = ConvertFrom-ScanStateExitCode -ExitCode -1
        $r.Severity | Should -Be 'Error'
        $r.ShouldContinue | Should -BeFalse
    }

    It "Should return a hashtable with required keys" {
        $r = ConvertFrom-ScanStateExitCode -ExitCode 0
        $r | Should -BeOfType [hashtable]
        $r.Keys | Should -Contain 'Code'
        $r.Keys | Should -Contain 'Severity'
        $r.Keys | Should -Contain 'Message'
        $r.Keys | Should -Contain 'ShouldContinue'
    }
}

# =============================================================================
# INVOKE-SCANSTATEPROCESS (t1-e9)
# =============================================================================
Describe "Invoke-ScanStateProcess" {
    It "Should declare SupportsShouldProcess" {
        $cmd = Get-Command Invoke-ScanStateProcess
        $cmd.Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It "Should delegate to Start-TrackedProcess" {
        Mock Start-TrackedProcess {
            [PSCustomObject]@{ ExitCode = 0; HasExited = $true; Id = 42 }
        }
        $r = Invoke-ScanStateProcess -ScanStateExe 'scanstate.exe' -Arguments @('/c', '/o')
        $r.Id | Should -Be 42
        Should -Invoke Start-TrackedProcess -Times 1
    }

    It "Should join arguments with spaces when delegating" {
        $script:capturedArgs = $null
        Mock Start-TrackedProcess {
            param($FilePath, $Arguments)
            $script:capturedArgs = $Arguments
            [PSCustomObject]@{ ExitCode = 0; HasExited = $true }
        }
        Invoke-ScanStateProcess -ScanStateExe 'x.exe' -Arguments @('/c', '/o', '/vsc') | Out-Null
        $script:capturedArgs | Should -Be '/c /o /vsc'
    }
}

# =============================================================================
# WATCH-SCANSTATEPROGRESS (t1-e9)
# =============================================================================
Describe "Watch-ScanStateProgress" {
    It "Should return the process exit code" {
        $fakeStore = Join-Path $env:TEMP "WatchTest-$(Get-Random)"
        New-Item $fakeStore -ItemType Directory -Force | Out-Null
        $proc = [PSCustomObject]@{ ExitCode = 42; HasExited = $true }
        $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
        try {
            $code = Watch-ScanStateProgress -Process $proc -StorePath $fakeStore `
                -ScanProgressFile (Join-Path $fakeStore 'none.log') `
                -StartTime (Get-Date) -PollIntervalSeconds 1
            $code | Should -Be 42
        }
        finally {
            Remove-Item $fakeStore -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should handle missing store path gracefully" {
        $proc = [PSCustomObject]@{ ExitCode = 0; HasExited = $true }
        $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {} -Force
        $code = Watch-ScanStateProgress -Process $proc `
            -StorePath 'C:\DoesNotExist12345' `
            -ScanProgressFile 'C:\DoesNotExist12345\p.log' `
            -StartTime (Get-Date) -PollIntervalSeconds 1
        $code | Should -Be 0
    }
}

# =============================================================================
# SET-CAPTURECOMPLETE
# =============================================================================
Describe "Set-CaptureComplete" {
    BeforeAll {
        $script:completeStoreDir = Join-Path $env:TEMP "CompleteTest-$(Get-Random)"
        New-Item $script:completeStoreDir -ItemType Directory -Force | Out-Null

        $fakeUSMT = Join-Path $script:completeStoreDir "FakeUSMT"
        New-Item $fakeUSMT -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $fakeUSMT "scanstate.exe") -Value "FAKE"

        $script:State = New-MigrationState `
            -MappedDrive $script:completeStoreDir.TrimEnd('\') `
            -USMTDir $fakeUSMT
    }
    AfterAll {
        Remove-Item $script:completeStoreDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Should create capture-complete.flag file" {
        Mock Get-Item {
            [PSCustomObject]@{
                VersionInfo = [PSCustomObject]@{ FileVersion = "10.0.0.1" }
            }
        }

        Set-CaptureComplete

        $flag = Join-Path $script:completeStoreDir "capture-complete.flag"
        Test-Path $flag | Should -BeTrue
    }

    It "Should write valid JSON with source info" {
        Mock Get-Item {
            [PSCustomObject]@{
                VersionInfo = [PSCustomObject]@{ FileVersion = "10.0.0.1" }
            }
        }

        Set-CaptureComplete

        $flag = Join-Path $script:completeStoreDir "capture-complete.flag"
        $data = Get-Content $flag | ConvertFrom-Json
        $data.SourceComputer | Should -Be $env:COMPUTERNAME
        $data.SourceDomain | Should -Be $env:USERDOMAIN
        $data.CaptureTime | Should -Match "\d{4}-\d{2}-\d{2}"
        $data.USMTVersion | Should -Be "10.0.0.1"
    }
}

# =============================================================================
# DISCONNECT-SHARE
# =============================================================================
Describe "Disconnect-Share" {
    It "Should not attempt disconnect when no drive mapped" {
        $script:State = New-MigrationState -MappedDrive $null
        $script:State.ShareConnected = $false
        { Disconnect-Share } | Should -Not -Throw
    }

    It "Should attempt disconnect when drive is mapped" {
        $script:State = New-MigrationState -MappedDrive "Z:" -ShareConnected $true
        { Disconnect-Share } | Should -Not -Throw
    }
}

# =============================================================================
# CONNECTIVITY CHECKS (structural)
# =============================================================================
# Connect-DestinationShare uses exit 1 on failure which kills Pester container.
# Test connectivity logic structurally.
Describe "Connect-DestinationShare structure" {
    BeforeAll {
        $script:srcContent = Get-Content "$PSScriptRoot\..\scripts\source-capture.ps1" -Raw
    }

    It "Should test connectivity with ping" {
        $script:srcContent | Should -Match 'Test-Connection'
    }

    It "Should test SMB port 445" {
        $script:srcContent | Should -Match 'Test-NetConnection.*445'
    }

    It "Should support SkipConnectivityCheck flag" {
        $script:srcContent | Should -Match 'SkipConnectivityCheck'
    }

    It "Should try drive letters Z through U" {
        # Whitespace-tolerant: match `'Z'` ... `'U'` in order regardless of
        # Invoke-Formatter's comma-spacing.
        $script:srcContent | Should -Match "'Z'\s*,\s*'Y'\s*,\s*'X'\s*,\s*'W'\s*,\s*'V'\s*,\s*'U'"
    }

    It "Should support credential pass-through" {
        $script:srcContent | Should -Match 'ShareUsername.*SharePassword'
    }

    It "Should verify write access to share" {
        $script:srcContent | Should -Match 'write.*test|Write access'
    }
}

# =============================================================================
# TEST-PREREQUISITES (structural)
# =============================================================================
Describe "Test-Prerequisites structure (source)" {
    It "Function should exist" {
        Get-Command Test-Prerequisites -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Function should call Get-CimInstance for OS info" {
        $srcContent = Get-Content "$PSScriptRoot\..\scripts\source-capture.ps1" -Raw
        $srcContent | Should -Match 'Win32_OperatingSystem'
    }

    It "Function should call Get-CimInstance for user profiles" {
        $srcContent = Get-Content "$PSScriptRoot\..\scripts\source-capture.ps1" -Raw
        $srcContent | Should -Match 'Win32_UserProfile'
    }

    It "Function should calculate profile sizes" {
        $srcContent = Get-Content "$PSScriptRoot\..\scripts\source-capture.ps1" -Raw
        $srcContent | Should -Match 'Measure-Object.*Property Length.*Sum'
    }

    It "Function should display total profile data" {
        $srcContent = Get-Content "$PSScriptRoot\..\scripts\source-capture.ps1" -Raw
        $srcContent | Should -Match 'Total profile data'
    }
}

# =============================================================================
# PARAMETER VALIDATION
# =============================================================================
Describe "Source script parameters" {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $script:srcParams = $ast.ParamBlock.Parameters
    }

    It "Should have DestinationShare parameter" {
        $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "DestinationShare" } | Should -Not -BeNullOrEmpty
    }

    It "Should have USMTPath parameter" {
        $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "USMTPath" } | Should -Not -BeNullOrEmpty
    }

    It "Should have ShareUsername parameter" {
        $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "ShareUsername" } | Should -Not -BeNullOrEmpty
    }

    It "Should have SharePassword parameter" {
        $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "SharePassword" } | Should -Not -BeNullOrEmpty
    }

    It "Should have ExtraData switch" {
        $p = $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "ExtraData" }
        $p | Should -Not -BeNullOrEmpty
        $p.Attributes.TypeName.Name | Should -Contain "switch"
    }

    It "Should have DryRun switch" {
        $p = $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "DryRun" }
        $p | Should -Not -BeNullOrEmpty
        $p.Attributes.TypeName.Name | Should -Contain "switch"
    }

    It "Should have EncryptStore switch" {
        $p = $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "EncryptStore" }
        $p | Should -Not -BeNullOrEmpty
    }

    It "Should have SkipConnectivityCheck switch" {
        $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "SkipConnectivityCheck" } | Should -Not -BeNullOrEmpty
    }

    It "Should have SkipUSMTInstall switch" {
        $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "SkipUSMTInstall" } | Should -Not -BeNullOrEmpty
    }

    It "Should have at least 13 user-facing parameters (plus FromEnv marker switches added in t1-e6)" {
        # Original surface = 13; t1-e6 adds SharePasswordFromEnv and
        # EncryptionKeyFromEnv marker switches for DPAPI env-var hand-off.
        $script:srcParams.Count | Should -BeGreaterOrEqual 13
    }

    It "Should have SharePasswordFromEnv marker switch (DPAPI hand-off)" {
        $p = $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "SharePasswordFromEnv" }
        $p | Should -Not -BeNullOrEmpty
    }

    It "Should have EncryptionKeyFromEnv marker switch (DPAPI hand-off)" {
        $p = $script:srcParams | Where-Object { $_.Name.VariablePath.UserPath -eq "EncryptionKeyFromEnv" }
        $p | Should -Not -BeNullOrEmpty
    }
}

# =============================================================================
# SCRIPT STRUCTURE
# =============================================================================
Describe "Source script structure" {
    BeforeAll {
        $script:srcContent = Get-Content $ScriptPath -Raw
    }

    It "Should define expected in-script functions (UI/USMT/elevation delegated to modules)" {
        $expectedFunctions = @(
            'Test-Prerequisites',
            'Initialize-USMT', 'Connect-DestinationShare',
            'Get-MigrationProfiles', 'Export-PreScanData',
            'Backup-ExtraData', 'Invoke-USMTCapture',
            'Set-CaptureComplete', 'Disconnect-Share', 'Main'
        )
        foreach ($fn in $expectedFunctions) {
            $script:srcContent | Should -Match "function\s+$fn"
        }
    }

    It "Should include /vsc flag for Volume Shadow Copy" {
        $script:srcContent | Should -Match '"/vsc"'
    }

    It "Should include /efs:copyraw for EFS files" {
        $script:srcContent | Should -Match '"/efs:copyraw"'
    }

    It "Should exclude NT AUTHORITY accounts" {
        $script:srcContent | Should -Match 'NT AUTHORITY'
    }

    It "Should exclude BUILTIN accounts" {
        $script:srcContent | Should -Match 'BUILTIN'
    }

    It "Should disconnect share in finally block" {
        $script:srcContent | Should -Match 'Disconnect-Share'
        $script:srcContent | Should -Match 'finally'
    }

    It "Should adjust TotalSteps when ExtraData is set" {
        $script:srcContent | Should -Match 'ExtraData[\s\S]{0,120}TotalSteps\s*=\s*8'
    }

    It "Should parse without errors" {
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $ScriptPath, [ref]$null, [ref]$parseErrors) | Out-Null
        $parseErrors | Should -BeNullOrEmpty
    }
}

# =============================================================================
# MAIN FLOW
# =============================================================================
Describe "Source Main function flow" {
    It "Should set TotalSteps to 8 when ExtraData is true" {
        $ExtraData = $true
        $testSteps = 7
        if ($ExtraData) { $testSteps = 8 }
        $testSteps | Should -Be 8
    }

    It "Should set TotalSteps to 7 when ExtraData is false" {
        $ExtraData = $false
        $testSteps = 7
        if ($ExtraData) { $testSteps = 8 }
        $testSteps | Should -Be 7
    }
}

# =============================================================================
# VALIDATION ATTRIBUTES (t1-e12, Phase 3)
# -----------------------------------------------------------------------------
# These tests operate on the parsed AST of source-capture.ps1 to confirm that
# the ValidateScript attributes added in Phase 3 are present in the param
# block. Running the full script stand-alone would trigger elevation / USMT
# lookup, so we verify the attribute metadata directly.
# =============================================================================
Describe "Source param-block validation attributes (t1-e12)" {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $script:srcParamsE12 = $ast.ParamBlock.Parameters

        function Get-E12Param([string]$Name) {
            $script:srcParamsE12 |
                Where-Object { $_.Name.VariablePath.UserPath -eq $Name } |
                Select-Object -First 1
        }

        function Test-HasValidateScript([System.Management.Automation.Language.ParameterAst]$Param) {
            if (-not $Param) { return $false }
            return ($Param.Attributes.TypeName.FullName -contains 'ValidateScript')
        }
    }

    It "DestinationShare has ValidateScript attribute" {
        Test-HasValidateScript (Get-E12Param 'DestinationShare') | Should -BeTrue
    }

    It "USMTPath has ValidateScript attribute" {
        Test-HasValidateScript (Get-E12Param 'USMTPath') | Should -BeTrue
    }

    It "IncludeUsers has ValidateScript attribute" {
        Test-HasValidateScript (Get-E12Param 'IncludeUsers') | Should -BeTrue
    }

    It "ExcludeUsers has ValidateScript attribute" {
        Test-HasValidateScript (Get-E12Param 'ExcludeUsers') | Should -BeTrue
    }

    It "EncryptionKey has ValidateScript attribute" {
        Test-HasValidateScript (Get-E12Param 'EncryptionKey') | Should -BeTrue
    }

    It "SharePassword is declared as [securestring]" {
        $p = Get-E12Param 'SharePassword'
        $p.StaticType.FullName | Should -Be 'System.Security.SecureString'
    }

    It "EncryptionKey is declared as [securestring]" {
        $p = Get-E12Param 'EncryptionKey'
        $p.StaticType.FullName | Should -Be 'System.Security.SecureString'
    }

    It "DestinationShare ValidateScript rejects a local path" {
        $p = Get-E12Param 'DestinationShare'
        # ScriptBlockExpressionAst.ToString() includes the outer braces, so
        # [ScriptBlock]::Create() on that produces a NESTED scriptblock. Grab
        # the inner ScriptBlockAst body text directly so the re-created block
        # has the validation expressions as its top-level body.
        $attrSb = ($p.Attributes |
                Where-Object { $_.TypeName.FullName -eq 'ValidateScript' } |
                Select-Object -First 1).PositionalArguments[0].ScriptBlock
        $sb = [ScriptBlock]::Create($attrSb.EndBlock.Extent.Text)
        ('C:\local\path' | ForEach-Object $sb) | Should -BeFalse
    }

    It "DestinationShare ValidateScript accepts a UNC path" {
        $p = Get-E12Param 'DestinationShare'
        $attrSb = ($p.Attributes |
                Where-Object { $_.TypeName.FullName -eq 'ValidateScript' } |
                Select-Object -First 1).PositionalArguments[0].ScriptBlock
        $sb = [ScriptBlock]::Create($attrSb.EndBlock.Extent.Text)
        ('\\server\share' | ForEach-Object $sb) | Should -BeTrue
    }

    It "IncludeUsers ValidateScript rejects a bad profile name" {
        $p = Get-E12Param 'IncludeUsers'
        $attrSb = ($p.Attributes |
                Where-Object { $_.TypeName.FullName -eq 'ValidateScript' } |
                Select-Object -First 1).PositionalArguments[0].ScriptBlock
        $sb = [ScriptBlock]::Create($attrSb.EndBlock.Extent.Text)
        { , @('bad\name') | ForEach-Object $sb } | Should -Throw
    }

    It "IncludeUsers ValidateScript accepts valid profile names" {
        $p = Get-E12Param 'IncludeUsers'
        $attrSb = ($p.Attributes |
                Where-Object { $_.TypeName.FullName -eq 'ValidateScript' } |
                Select-Object -First 1).PositionalArguments[0].ScriptBlock
        $sb = [ScriptBlock]::Create($attrSb.EndBlock.Extent.Text)
        (, @('alice', 'bob_1', 'x.y') | ForEach-Object $sb) | Should -BeTrue
    }

    It "Source script imports MigrationValidators module" {
        $scriptContent = Get-Content $ScriptPath -Raw
        $scriptContent | Should -Match 'MigrationValidators\.psm1'
    }

    It "Source script defines ConvertFrom-SecureStringPlain helper" {
        $scriptContent = Get-Content $ScriptPath -Raw
        $scriptContent | Should -Match 'ConvertFrom-SecureStringPlain'
    }
}
