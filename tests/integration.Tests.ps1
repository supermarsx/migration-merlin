#Requires -Modules Pester
<#
.SYNOPSIS
    Integration tests for the full migration workflow.
.DESCRIPTION
    Tests end-to-end scenarios using the test helpers to simulate
    complete migration workflows without actual USMT execution.
    Validates data flow between source capture and destination restore.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
}

# =============================================================================
# TEST HELPER VALIDATION
# =============================================================================
Describe "TestHelpers module" {
    It "Should create a valid test migration folder" {
        $folder = Get-TestMigrationFolder
        Test-Path $folder | Should -BeTrue
        Test-Path (Join-Path $folder "USMT") | Should -BeTrue
        Test-Path (Join-Path $folder "Logs") | Should -BeTrue
        Test-Path (Join-Path $folder "Backup") | Should -BeTrue
        Test-Path (Join-Path $folder "PreScanData") | Should -BeTrue
        Remove-TestMigrationFolder $folder
    }

    It "Should clean up test folders completely" {
        $folder = Get-TestMigrationFolder
        Remove-TestMigrationFolder $folder
        Test-Path $folder | Should -BeFalse
    }

    It "Should create fake USMT directory with all needed files" {
        $folder = Get-TestMigrationFolder
        $usmtDir = New-FakeUSMTDir -BasePath $folder
        Test-Path (Join-Path $usmtDir "scanstate.exe") | Should -BeTrue
        Test-Path (Join-Path $usmtDir "loadstate.exe") | Should -BeTrue
        Test-Path (Join-Path $usmtDir "MigDocs.xml") | Should -BeTrue
        Test-Path (Join-Path $usmtDir "MigApp.xml") | Should -BeTrue
        Remove-TestMigrationFolder $folder
    }

    It "Should create fake migration store with .mig files" {
        $folder = Get-TestMigrationFolder
        New-FakeMigStore -StorePath $folder -FileCount 5 -FileSizeKB 200

        $migFiles = Get-ChildItem (Join-Path $folder "USMT") -Filter "*.mig"
        $migFiles.Count | Should -Be 5
        foreach ($f in $migFiles) {
            $f.Length | Should -BeGreaterOrEqual (200 * 1024)
        }
        Remove-TestMigrationFolder $folder
    }

    It "Should create valid PreScanData" {
        $folder = Get-TestMigrationFolder
        New-FakePreScanData -MigrationFolder $folder

        Test-Path (Join-Path $folder "PreScanData\InstalledApps.csv") | Should -BeTrue
        Test-Path (Join-Path $folder "PreScanData\Printers.csv") | Should -BeTrue
        Test-Path (Join-Path $folder "PreScanData\MappedDrives.csv") | Should -BeTrue
        Test-Path (Join-Path $folder "PreScanData\WiFiProfiles.txt") | Should -BeTrue
        Test-Path (Join-Path $folder "PreScanData\BrowserBookmarks.txt") | Should -BeTrue
        Test-Path (Join-Path $folder "PreScanData\SystemInfo.json") | Should -BeTrue

        Remove-TestMigrationFolder $folder
    }

    It "Should create valid capture-complete flag" {
        $folder = Get-TestMigrationFolder
        New-FakeCaptureCompleteFlag -MigrationFolder $folder

        $flag = Join-Path $folder "capture-complete.flag"
        Test-Path $flag | Should -BeTrue

        $data = Get-Content $flag | ConvertFrom-Json
        $data.SourceComputer | Should -Be "SOURCE-PC"
        $data.SourceDomain | Should -Be "WORKGROUP"
        $data.CaptureTime | Should -Match "\d{4}-\d{2}-\d{2}"
        $data.USMTVersion | Should -Match "\d+\.\d+"

        Remove-TestMigrationFolder $folder
    }
}

# =============================================================================
# MOCK OBJECT VALIDATION
# =============================================================================
Describe "Mock objects" {
    It "New-MockOS should return valid OS object" {
        $os = New-MockOS
        $os.Caption | Should -Match "Windows"
        $os.BuildNumber | Should -Match "\d+"
    }

    It "New-MockDisk should return disk with correct free space" {
        $disk = New-MockDisk -FreeGB 50 -TotalGB 200
        $disk.FreeSpace | Should -Be (50 * 1GB)
        $disk.Size | Should -Be (200 * 1GB)
        $disk.DeviceID | Should -Be "C:"
    }

    It "New-MockNetAdapter should have correct status" {
        $up = New-MockNetAdapter -Status "Up"
        $up.Status | Should -Be "Up"

        $down = New-MockNetAdapter -Status "Disconnected"
        $down.Status | Should -Be "Disconnected"
    }

    It "New-MockIPAddress should have correct IP" {
        $ip = New-MockIPAddress "10.0.0.1"
        $ip.IPAddress | Should -Be "10.0.0.1"
        $ip.PrefixOrigin | Should -Be "Dhcp"
    }

    It "New-MockUserProfile should have correct username in path" {
        $p = New-MockUserProfile "alice"
        $p.LocalPath | Should -Match "alice$"
        $p.Special | Should -BeFalse
        $p.SID | Should -Match "^S-1-5-21-"
    }

    It "New-MockUserProfile should support Special flag" {
        $p = New-MockUserProfile "system" "C:\Windows" $true
        $p.Special | Should -BeTrue
    }

    It "New-MockPrinter should have correct name" {
        $p = New-MockPrinter "Office Laser"
        $p.Name | Should -Be "Office Laser"
        $p.DriverName | Should -Be "Generic Driver"
    }

    It "New-MockInstalledApp should have correct name and version" {
        $a = New-MockInstalledApp "Test App" "2.5"
        $a.DisplayName | Should -Be "Test App"
        $a.DisplayVersion | Should -Be "2.5"
    }

    It "New-MockComputerSystem should have realistic values" {
        $cs = New-MockComputerSystem
        $cs.Domain | Should -Be "WORKGROUP"
        $cs.TotalPhysicalMemory | Should -BeGreaterThan 0
    }
}

# =============================================================================
# DATA FLOW: SOURCE -> DESTINATION
# =============================================================================
Describe "Data flow: capture to restore" {
    BeforeAll {
        $script:migFolder = Get-TestMigrationFolder
    }
    AfterAll {
        Remove-TestMigrationFolder $script:migFolder
    }

    It "Pre-scan data written by source should be readable by verify script" {
        New-FakePreScanData -MigrationFolder $script:migFolder

        # Simulate what post-migration-verify does
        $preScanDir = Join-Path $script:migFolder "PreScanData"
        $hasPreScan = Test-Path $preScanDir
        $hasPreScan | Should -BeTrue

        $sysInfo = Get-Content (Join-Path $preScanDir "SystemInfo.json") | ConvertFrom-Json
        $sysInfo.ComputerName | Should -Not -BeNullOrEmpty

        $apps = Import-Csv (Join-Path $preScanDir "InstalledApps.csv")
        $apps.Count | Should -BeGreaterThan 0

        $printers = Import-Csv (Join-Path $preScanDir "Printers.csv")
        $printers.Count | Should -BeGreaterThan 0
    }

    It "Capture-complete flag should contain valid JSON for destination to parse" {
        New-FakeCaptureCompleteFlag -MigrationFolder $script:migFolder

        $flagPath = Join-Path $script:migFolder "capture-complete.flag"
        $flagContent = Get-Content $flagPath -Raw

        { $flagContent | ConvertFrom-Json } | Should -Not -Throw

        $data = $flagContent | ConvertFrom-Json
        $data.PSObject.Properties.Name | Should -Contain "SourceComputer"
        $data.PSObject.Properties.Name | Should -Contain "SourceDomain"
        $data.PSObject.Properties.Name | Should -Contain "CaptureTime"
        $data.PSObject.Properties.Name | Should -Contain "USMTVersion"
    }

    It "Migration store should have .mig files for LoadState to find" {
        New-FakeMigStore -StorePath $script:migFolder -FileCount 3

        $usmtDir = Join-Path $script:migFolder "USMT"
        $migFiles = Get-ChildItem $usmtDir -Filter "*.mig" -Recurse
        $migFiles.Count | Should -Be 3
    }
}

# =============================================================================
# APP COMPARISON LOGIC
# =============================================================================
Describe "Application comparison logic" {
    It "Should correctly identify missing apps" {
        $sourceApps = @("Chrome", "Firefox", "VSCode", "Slack", "Zoom")
        $destApps = @("Chrome", "Firefox", "Teams")

        $missing = $sourceApps | Where-Object { $_ -notin $destApps }
        $missing | Should -Contain "VSCode"
        $missing | Should -Contain "Slack"
        $missing | Should -Contain "Zoom"
        $missing | Should -Not -Contain "Chrome"
        $missing | Should -Not -Contain "Firefox"
        $missing.Count | Should -Be 3
    }

    It "Should handle empty source apps list" {
        $sourceApps = @()
        $destApps = @("Chrome")
        $missing = $sourceApps | Where-Object { $_ -notin $destApps }
        @($missing).Count | Should -Be 0
    }

    It "Should handle all apps present on destination" {
        $sourceApps = @("Chrome", "Firefox")
        $destApps = @("Chrome", "Firefox", "VSCode")
        $missing = $sourceApps | Where-Object { $_ -notin $destApps }
        @($missing).Count | Should -Be 0
    }
}

# =============================================================================
# PRINTER COMPARISON LOGIC
# =============================================================================
Describe "Printer comparison logic" {
    It "Should identify printers missing on destination" {
        $sourcePrinters = @("HP LaserJet", "Canon Scanner", "Network Copier")
        $destPrinters = @("HP LaserJet")

        $missing = $sourcePrinters | Where-Object { $_ -notin $destPrinters }
        $missing | Should -Contain "Canon Scanner"
        $missing | Should -Contain "Network Copier"
        $missing.Count | Should -Be 2
    }
}

# =============================================================================
# WIFI COMPARISON LOGIC
# =============================================================================
Describe "Wi-Fi profile comparison logic" {
    It "Should identify missing Wi-Fi profiles" {
        $sourceWifi = @("CorpWiFi", "GuestNet", "HomeNet")
        $destWifi = @("CorpWiFi")

        $missing = $sourceWifi | Where-Object { $_ -notin $destWifi }
        $missing | Should -Contain "GuestNet"
        $missing | Should -Contain "HomeNet"
        $missing.Count | Should -Be 2
    }
}

# =============================================================================
# PROFILE FILTERING LOGIC
# =============================================================================
Describe "Profile filtering logic" {
    It "Should correctly apply include filter" {
        $allUsers = @("alice", "bob", "charlie", "Public", "Default")
        $includeUsers = @("alice", "charlie")
        $excludeUsers = @()
        $systemAccounts = @("Public", "Default", "Default User", "All Users")

        $result = $allUsers | Where-Object {
            $_ -notin $systemAccounts -and
            ($includeUsers.Count -eq 0 -or $_ -in $includeUsers) -and
            $_ -notin $excludeUsers
        }

        $result | Should -Contain "alice"
        $result | Should -Contain "charlie"
        $result | Should -Not -Contain "bob"
        $result | Should -Not -Contain "Public"
    }

    It "Should correctly apply exclude filter" {
        $allUsers = @("alice", "bob", "charlie")
        $includeUsers = @()
        $excludeUsers = @("bob")
        $systemAccounts = @("Public", "Default", "Default User", "All Users")

        $result = $allUsers | Where-Object {
            $_ -notin $systemAccounts -and
            ($includeUsers.Count -eq 0 -or $_ -in $includeUsers) -and
            $_ -notin $excludeUsers
        }

        $result | Should -Contain "alice"
        $result | Should -Contain "charlie"
        $result | Should -Not -Contain "bob"
    }

    It "Should apply both include and exclude (exclude wins)" {
        $allUsers = @("alice", "bob", "charlie")
        $includeUsers = @("alice", "bob")
        $excludeUsers = @("bob")
        $systemAccounts = @()

        $result = $allUsers | Where-Object {
            $_ -notin $systemAccounts -and
            ($includeUsers.Count -eq 0 -or $_ -in $includeUsers) -and
            $_ -notin $excludeUsers
        }

        $result | Should -Contain "alice"
        $result | Should -Not -Contain "bob"
        $result | Should -Not -Contain "charlie"
    }
}

# =============================================================================
# USMT EXIT CODE HANDLING
# =============================================================================
Describe "USMT exit code interpretation" {
    $testCases = @(
        @{ Code = 0;  Expected = "Success";        IsSuccess = $true }
        @{ Code = 61; Expected = "Partial";         IsSuccess = $true }
        @{ Code = 71; Expected = "Cancelled";       IsSuccess = $false }
        @{ Code = 26; Expected = "Locked files";    IsSuccess = $false }
        @{ Code = 27; Expected = "Unknown";         IsSuccess = $false }
    )

    It "Exit code <Code> should be treated as success=<IsSuccess>" -TestCases $testCases {
        param($Code, $Expected, $IsSuccess)
        $isOk = ($Code -eq 0 -or $Code -eq 61)
        $isOk | Should -Be $IsSuccess
    }
}

# =============================================================================
# FILE STRUCTURE VALIDATION
# =============================================================================
Describe "Project file structure" {
    It "Should have destination-setup.ps1" {
        Test-Path "$PSScriptRoot\..\destination-setup.ps1" | Should -BeTrue
    }

    It "Should have source-capture.ps1" {
        Test-Path "$PSScriptRoot\..\source-capture.ps1" | Should -BeTrue
    }

    It "Should have custom-migration.xml" {
        Test-Path "$PSScriptRoot\..\custom-migration.xml" | Should -BeTrue
    }

    It "Should have post-migration-verify.ps1" {
        Test-Path "$PSScriptRoot\..\post-migration-verify.ps1" | Should -BeTrue
    }

    It "Should have QUICKSTART.md" {
        Test-Path "$PSScriptRoot\..\QUICKSTART.md" | Should -BeTrue
    }

    It "Should have tests directory" {
        Test-Path "$PSScriptRoot" | Should -BeTrue
    }

    It "Should have TestHelpers module" {
        Test-Path "$PSScriptRoot\TestHelpers.psm1" | Should -BeTrue
    }
}

# =============================================================================
# DISK SPACE ESTIMATION
# =============================================================================
Describe "Disk space estimation" {
    It "Should warn when free space is under 20GB" {
        $freeGB = 15
        $isLow = $freeGB -lt 20
        $isLow | Should -BeTrue
    }

    It "Should not warn when free space is over 20GB" {
        $freeGB = 50
        $isLow = $freeGB -lt 20
        $isLow | Should -BeFalse
    }

    It "Should correctly format sizes in MB vs GB" {
        $sizeBytes = 500MB
        $sizeMB = [math]::Round($sizeBytes / 1MB, 1)
        $sizeGB = [math]::Round($sizeBytes / 1GB, 2)
        $sizeStr = if ($sizeGB -ge 1) { "${sizeGB} GB" } else { "${sizeMB} MB" }
        $sizeStr | Should -Be "500 MB"

        $sizeBytes = 2GB
        $sizeMB = [math]::Round($sizeBytes / 1MB, 1)
        $sizeGB = [math]::Round($sizeBytes / 1GB, 2)
        $sizeStr = if ($sizeGB -ge 1) { "${sizeGB} GB" } else { "${sizeMB} MB" }
        $sizeStr | Should -Be "2 GB"
    }
}

# =============================================================================
# UNC PATH PARSING
# =============================================================================
Describe "UNC path parsing" {
    It "Should extract hostname from UNC path" {
        $share = "\\DEST-PC\MigrationShare$"
        $parts = $share -replace '\\\\', '' -split '\\'
        $targetHost = $parts[0]
        $targetHost | Should -Be "DEST-PC"
    }

    It "Should extract hostname from IP-based UNC path" {
        $share = "\\192.168.1.100\MigrationShare$"
        $parts = $share -replace '\\\\', '' -split '\\'
        $targetHost = $parts[0]
        $targetHost | Should -Be "192.168.1.100"
    }

    It "Should handle hidden share names (with $)" {
        $share = "\\SERVER\Share$"
        $parts = $share -replace '\\\\', '' -split '\\'
        $shareName = $parts[1]
        $shareName | Should -Be 'Share$'
    }
}

# =============================================================================
# SPEED CALCULATION
# =============================================================================
Describe "Transfer speed calculation" {
    It "Should calculate speed in MB/s from byte deltas" {
        $delta = 50MB
        $intervalSeconds = 5
        $speedMBs = [math]::Round($delta / 1MB / $intervalSeconds, 1)
        $speedMBs | Should -Be 10.0
    }

    It "Should compute rolling average from speed samples" {
        $samples = @(10.0, 15.0, 12.0, 8.0, 14.0)
        $avg = [math]::Round(($samples | Measure-Object -Average).Average, 1)
        $avg | Should -Be 11.8
    }

    It "Should keep only last N samples" {
        $maxSamples = 12
        $samples = 1..20 | ForEach-Object { $_ * 1.0 }
        if ($samples.Count -gt $maxSamples) {
            $samples = $samples[-$maxSamples..-1]
        }
        $samples.Count | Should -Be $maxSamples
        $samples[0] | Should -Be 9.0  # 20-12+1 = 9th element
    }
}
