#Requires -Modules Pester
<#
.SYNOPSIS
    Comprehensive Pester tests for post-migration-verify.ps1
.DESCRIPTION
    Tests all verification sections, pre-scan data comparison logic,
    and output formatting of the post-migration verification script.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $ScriptPath = "$PSScriptRoot\..\post-migration-verify.ps1"
    $scriptContent = Get-Content $ScriptPath -Raw
}

# =============================================================================
# PARAMETER VALIDATION
# =============================================================================
Describe "Post-migration verify parameters" {
    It "Should have MigrationFolder parameter with default C:\MigrationStore" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $mfParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "MigrationFolder" }
        $mfParam | Should -Not -BeNullOrEmpty
        $mfParam.DefaultValue.Value | Should -Be "C:\MigrationStore"
    }

    It "Should have exactly 1 parameter" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $ast.ParamBlock.Parameters.Count | Should -Be 1
    }
}

# =============================================================================
# SCRIPT STRUCTURE
# =============================================================================
Describe "Script structure" {
    It "Should elevate via the shared Request-Elevation helper" {
        # Phase 2: inline IsInRole block replaced with the Invoke-Elevated helper.
        $scriptContent | Should -Match 'Request-Elevation\s+-ScriptPath\s+\$PSCommandPath\s+-BoundParameters\s+\$PSBoundParameters'
    }

    It "Should set ErrorActionPreference to Continue" {
        $scriptContent | Should -Match '\$ErrorActionPreference\s*=\s*"Continue"'
    }

    It "Should import MigrationConstants module" {
        $scriptContent | Should -Match 'Import-Module\s+"\$PSScriptRoot\\MigrationConstants\.psm1"'
    }

    It "Should import MigrationUI module" {
        $scriptContent | Should -Match 'Import-Module\s+"\$PSScriptRoot\\MigrationUI\.psm1"'
    }

    It "Should dot-source Invoke-Elevated.ps1" {
        $scriptContent | Should -Match '\.\s+"\$PSScriptRoot\\Invoke-Elevated\.ps1"'
    }

    It "Should dot-source MigrationLogging.ps1" {
        $scriptContent | Should -Match '\.\s+"\$PSScriptRoot\\MigrationLogging\.ps1"'
    }

    It "Should route parameter logging through Format-SafeParams" {
        $scriptContent | Should -Match 'Format-SafeParams\s+\$PSBoundParameters'
    }

    It "Should use [CmdletBinding(SupportsShouldProcess)]" {
        $scriptContent | Should -Match '\[CmdletBinding\(SupportsShouldProcess\s*=\s*\$true\)\]'
    }

    It "Should define Write-Result function" {
        $scriptContent | Should -Match 'function Write-Result'
    }

    It "Should check user profiles" {
        $scriptContent | Should -Match 'User Profiles|Win32_UserProfile'
    }

    It "Should check documents" {
        $scriptContent | Should -Match 'User Documents|Documents.*Desktop.*Downloads'
    }

    It "Should check browser data" {
        $scriptContent | Should -Match 'Browser Data|Chrome.*Edge.*Firefox'
    }

    It "Should check Outlook signatures" {
        $scriptContent | Should -Match 'Outlook|Signatures'
    }

    It "Should check printers" {
        $scriptContent | Should -Match 'Printers|Get-Printer'
    }

    It "Should check installed apps" {
        $scriptContent | Should -Match 'Applications.*Reinstall|InstalledApps'
    }

    It "Should check developer settings" {
        $scriptContent | Should -Match 'Developer|gitconfig|ssh.*config|VSCode'
    }

    It "Should check Wi-Fi profiles" {
        $scriptContent | Should -Match 'Wi-Fi|wlan.*show.*profiles'
    }
}

# =============================================================================
# WRITE-RESULT FUNCTION
# =============================================================================
Describe "Write-Result function" {
    BeforeAll {
        # Extract and dot-source just the function
        $funcMatch = [regex]::Match($scriptContent, '(?s)(function Write-Result \{.*?\n\})')
        $funcBody = $funcMatch.Groups[1].Value
        Invoke-Expression $funcBody
    }

    It "Should display PASS in green" {
        $output = Write-Result "test check" "PASS" 6>&1
        ($output -join "") | Should -Match "PASS"
        ($output -join "") | Should -Match "test check"
    }

    It "Should display WARN in yellow" {
        $output = Write-Result "warn check" "WARN" 6>&1
        ($output -join "") | Should -Match "WARN"
    }

    It "Should display FAIL in red" {
        $output = Write-Result "fail check" "FAIL" 6>&1
        ($output -join "") | Should -Match "FAIL"
    }

    It "Should display INFO in cyan" {
        $output = Write-Result "info check" "INFO" 6>&1
        ($output -join "") | Should -Match "INFO"
    }

    It "Should include detail when provided" {
        $output = Write-Result "check" "PASS" "extra detail" 6>&1
        ($output -join "") | Should -Match "extra detail"
    }

    It "Should work without detail" {
        $output = Write-Result "check" "PASS" 6>&1
        ($output -join "") | Should -Match "check"
    }
}

# =============================================================================
# VERIFICATION LOGIC - USER PROFILES
# =============================================================================
Describe "User profile verification" {
    It "Script should query Win32_UserProfile" {
        $scriptContent | Should -Match 'Get-CimInstance Win32_UserProfile'
    }

    It "Should filter out special and system profiles" {
        $scriptContent | Should -Match '-not \$_\.Special'
        $scriptContent | Should -Match 'systemprofile'
    }

    It "Should filter out built-in accounts" {
        $scriptContent | Should -Match '"Public".*"Default".*"Default User".*"All Users"'
    }
}

# =============================================================================
# VERIFICATION LOGIC - PRESCAN DATA
# =============================================================================
Describe "PreScan data handling" {
    BeforeAll {
        $testDir = Get-TestMigrationFolder
    }
    AfterAll {
        Remove-TestMigrationFolder $testDir
    }

    It "Should check for PreScanData directory existence" {
        $scriptContent | Should -Match 'hasPreScan.*Test-Path.*preScanDir'
    }

    It "Should read SystemInfo.json when available" {
        $scriptContent | Should -Match 'SystemInfo\.json'
        $scriptContent | Should -Match 'ConvertFrom-Json'
    }

    It "Should read InstalledApps.csv for comparison" {
        $scriptContent | Should -Match 'InstalledApps\.csv'
        $scriptContent | Should -Match 'Import-Csv'
    }

    It "Should read Printers.csv for comparison" {
        $scriptContent | Should -Match 'Printers\.csv'
    }

    It "Should read WiFiProfiles.txt for comparison" {
        $scriptContent | Should -Match 'WiFiProfiles\.txt'
    }

    Context "With valid PreScanData" {
        BeforeAll {
            New-FakePreScanData -MigrationFolder $testDir
        }

        It "Should parse SystemInfo.json correctly" {
            $json = Join-Path $testDir "PreScanData\SystemInfo.json"
            $info = Get-Content $json | ConvertFrom-Json
            $info.ComputerName | Should -Be "SOURCE-PC"
            $info.OSVersion | Should -Match "Windows 11"
            $info.TotalRAM_GB | Should -Be 16
        }

        It "Should parse InstalledApps.csv correctly" {
            $csv = Join-Path $testDir "PreScanData\InstalledApps.csv"
            $apps = Import-Csv $csv
            $apps.Count | Should -Be 3
            $apps[0].DisplayName | Should -Be "App One"
        }

        It "Should parse Printers.csv correctly" {
            $csv = Join-Path $testDir "PreScanData\Printers.csv"
            $printers = Import-Csv $csv
            $printers.Count | Should -Be 2
            $printers[0].Name | Should -Be "HP LaserJet"
        }

        It "Should parse WiFiProfiles.txt correctly" {
            $txt = Join-Path $testDir "PreScanData\WiFiProfiles.txt"
            $content = Get-Content $txt
            $names = ($content | Select-String "All User Profile\s+:\s+(.+)$").Matches |
                ForEach-Object { $_.Groups[1].Value.Trim() }
            $names | Should -Contain "CorpWiFi"
            $names | Should -Contain "GuestNet"
        }
    }
}

# =============================================================================
# DOCUMENT FOLDER CHECKS
# =============================================================================
Describe "Document folder verification" {
    It "Should check standard user folders" {
        $folders = @("Documents", "Desktop", "Downloads", "Pictures", "Music", "Videos", "Favorites")
        foreach ($f in $folders) {
            $scriptContent | Should -Match $f
        }
    }

    It "Should count files in each folder" {
        $scriptContent | Should -Match 'Get-ChildItem.*-Recurse.*-File'
        $scriptContent | Should -Match 'Measure-Object'
    }
}

# =============================================================================
# BROWSER DATA CHECKS
# =============================================================================
Describe "Browser data verification" {
    It "Should check Chrome bookmarks path" {
        $scriptContent | Should -Match 'Google\\Chrome\\User Data\\Default\\Bookmarks'
    }

    It "Should check Edge bookmarks path" {
        $scriptContent | Should -Match 'Microsoft\\Edge\\User Data\\Default\\Bookmarks'
    }

    It "Should check Firefox profiles path" {
        $scriptContent | Should -Match 'Mozilla\\Firefox\\Profiles'
    }

    It "Should mark as INFO when browser not installed (not FAIL)" {
        $scriptContent | Should -Match '"INFO".*"Not present'
    }
}

# =============================================================================
# PRINTER COMPARISON
# =============================================================================
Describe "Printer comparison logic" {
    It "Should compare source printers against destination" {
        $scriptContent | Should -Match 'srcPrinterList|srcPrinters'
        $scriptContent | Should -Match 'destPrinterNames'
    }

    It "Should warn about missing printers" {
        $scriptContent | Should -Match '"WARN".*"Was on source'
    }
}

# =============================================================================
# APP COMPARISON
# =============================================================================
Describe "Application comparison logic" {
    It "Should query both x86 and x64 registry hives" {
        $scriptContent | Should -Match 'WOW6432Node'
        $scriptContent | Should -Match 'Windows\\CurrentVersion\\Uninstall'
    }

    It "Should identify missing applications" {
        $scriptContent | Should -Match 'missing.*\$sourceApps.*-notin.*\$destApps'
    }

    It "Should report count of missing applications" {
        $scriptContent | Should -Match 'application.*need.*reinstall'
    }
}

# =============================================================================
# DEVELOPER SETTINGS CHECKS
# =============================================================================
Describe "Developer settings verification" {
    It "Should check for .gitconfig" {
        $scriptContent | Should -Match '\.gitconfig'
    }

    It "Should check for SSH config" {
        $scriptContent | Should -Match '\.ssh\\config'
    }

    It "Should check for VSCode settings" {
        $scriptContent | Should -Match 'Code\\User\\settings\.json'
    }
}

# =============================================================================
# WIFI COMPARISON
# =============================================================================
Describe "Wi-Fi profile comparison" {
    It "Should run netsh wlan show profiles" {
        $scriptContent | Should -Match 'netsh wlan show profiles'
    }

    It "Should compare source and destination Wi-Fi profiles" {
        $scriptContent | Should -Match 'missingWifi|srcWifiNames'
    }

    It "Should handle missing wireless adapter gracefully" {
        $scriptContent | Should -Match 'No wireless adapter'
    }
}

# =============================================================================
# OUTPUT FORMAT
# =============================================================================
Describe "Output formatting" {
    It "Should display a banner header" {
        $scriptContent | Should -Match 'Post-Migration Verification'
    }

    It "Should display section headers" {
        $sections = @("User Profiles", "User Documents", "Browser Data", "Outlook",
                      "Printers", "Developer", "Wi-Fi")
        foreach ($s in $sections) {
            $scriptContent | Should -Match $s
        }
    }

    It "Should display summary footer" {
        $scriptContent | Should -Match 'Verification Complete'
    }

    It "Should explain WARN items need attention" {
        $scriptContent | Should -Match '\[WARN\].*manual attention'
    }

    It "Should explain INFO items are informational" {
        $scriptContent | Should -Match '\[INFO\].*informational'
    }
}

# =============================================================================
# VALIDATION ATTRIBUTES (t1-e12, Phase 3)
# =============================================================================
Describe "Post-migration-verify param-block validation (t1-e12)" {
    BeforeAll {
        $scriptPath = (Resolve-Path "$PSScriptRoot\..\post-migration-verify.ps1").Path
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $script:verifyParamsE12 = $ast.ParamBlock.Parameters
    }

    It "MigrationFolder has ValidateScript attribute" {
        $p = $script:verifyParamsE12 |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'MigrationFolder' } |
            Select-Object -First 1
        ($p.Attributes.TypeName.FullName -contains 'ValidateScript') | Should -BeTrue
    }

    It "Verify script imports MigrationValidators module" {
        $scriptPath = (Resolve-Path "$PSScriptRoot\..\post-migration-verify.ps1").Path
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'MigrationValidators\.psm1'
    }
}
