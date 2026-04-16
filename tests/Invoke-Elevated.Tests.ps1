<#
.SYNOPSIS
    Tests for Invoke-Elevated.ps1 - admin detection, argument marshalling,
    SecureString env-var hand-off, and re-launch behavior.
#>

BeforeAll {
    $ScriptRoot = Split-Path $PSScriptRoot -Parent
    $InvokeElevated = Join-Path $ScriptRoot 'Invoke-Elevated.ps1'

    # Dot-source in the test's scope so all public functions are available
    . $InvokeElevated

    function global:Clear-MerlinTestEnv {
        $toRemove = @()
        foreach ($entry in [System.Environment]::GetEnvironmentVariables('Process').Keys) {
            if ($entry -like 'MERLIN_TEST_SECURE_*' -or
                $entry -like 'MERLIN_TEST_CRED_USER_*' -or
                $entry -like 'MERLIN_TEST_CRED_PASS_*') {
                $toRemove += $entry
            }
        }
        foreach ($v in $toRemove) {
            [System.Environment]::SetEnvironmentVariable($v, $null, 'Process')
        }
    }
}

AfterAll {
    Clear-MerlinTestEnv
    Remove-Item function:global:Clear-MerlinTestEnv -ErrorAction SilentlyContinue
}

Describe "Invoke-Elevated.ps1 - public surface" {
    It "Exports Test-IsAdmin" {
        Get-Command Test-IsAdmin -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It "Exports Request-Elevation" {
        Get-Command Request-Elevation -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It "Exports ConvertTo-ElevationArgumentString" {
        Get-Command ConvertTo-ElevationArgumentString -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It "Request-Elevation accepts BoundParameters (hashtable)" {
        (Get-Command Request-Elevation).Parameters.ContainsKey('BoundParameters') | Should -Be $true
        (Get-Command Request-Elevation).Parameters['BoundParameters'].ParameterType.Name | Should -Be 'Hashtable'
    }
    It "Legacy signature parameters still exist" {
        $p = (Get-Command Request-Elevation).Parameters
        $p.ContainsKey('ScriptPath') | Should -Be $true
        $p.ContainsKey('Arguments')  | Should -Be $true
        $p.ContainsKey('NoExit')     | Should -Be $true
        $p.ContainsKey('Silent')     | Should -Be $true
    }
}

Describe "Test-IsAdmin" {
    It "Returns a boolean" {
        $result = Test-IsAdmin
        ($result -is [bool]) | Should -Be $true
    }
    It "Matches the current process token" {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $expected = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Test-IsAdmin | Should -Be $expected
    }
}

Describe "ConvertTo-ElevationArgumentString - marshalling" {

    BeforeEach {
        Clear-MerlinTestEnv
    }

    Context "Basic types" {
        It "Builds canonical mix Foo Verbose List" {
            $bp = @{
                Foo     = 'bar'
                Verbose = [System.Management.Automation.SwitchParameter]::new($true)
                List    = @('a','b')
            }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Match '-Foo "bar"'
            $s | Should -Match '-Verbose'
            $s | Should -Match '-List "a","b"'
        }

        It "Marshals a 3-element string array with commas and quotes" {
            $bp = @{ Items = @('a','b','c') }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Match '-Items "a","b","c"'
        }

        It "Quotes a plain string and escapes embedded double quotes" {
            $bp = @{ Msg = 'hello "world"' }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            # backtick-quote escape
            $s | Should -Match 'hello `"world`"'
        }

        It "Emits integer parameters unquoted" {
            $bp = @{ Count = 42 }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Match '-Count 42'
            $s | Should -Not -Match '-Count "42"'
        }

        It "Emits boolean parameters as PowerShell literals" {
            $bp = @{ Flag = $true }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Match '-Flag \$true'
        }
    }

    Context "Switch parameters" {
        It "Includes switch when present" {
            $bp = @{ Force = [System.Management.Automation.SwitchParameter]::new($true) }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Match '-Force'
        }
        It "Omits switch when not present" {
            $bp = @{ Force = [System.Management.Automation.SwitchParameter]::new($false) }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Not -Match '-Force'
        }
    }

    Context "SecureString hand-off" {
        It "Does not place SecureString value on the command line" {
            $sec = ConvertTo-SecureString 'p@ssw0rd!' -AsPlainText -Force
            $bp = @{ EncryptionKey = $sec }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Not -Match 'p@ssw0rd'
        }

        It "Emits a FromEnv marker switch for SecureString" {
            $sec = ConvertTo-SecureString 'p@ssw0rd!' -AsPlainText -Force
            $bp = @{ EncryptionKey = $sec }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Match '-EncryptionKeyFromEnv'
        }

        It "Sets an encrypted env var named with uppercase parameter name" {
            $sec = ConvertTo-SecureString 'p@ssw0rd!' -AsPlainText -Force
            $bp = @{ EncryptionKey = $sec }
            $null = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $envVal = [System.Environment]::GetEnvironmentVariable('MERLIN_TEST_SECURE_ENCRYPTIONKEY', 'Process')
            $envVal | Should -Not -BeNullOrEmpty
            $envVal | Should -Not -Match 'p@ssw0rd'
        }

        It "Round-trips env var to original plaintext" {
            $plain = 'round-trip-secret-123'
            $sec = ConvertTo-SecureString $plain -AsPlainText -Force
            $bp = @{ Key = $sec }
            $null = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $envVal = [System.Environment]::GetEnvironmentVariable('MERLIN_TEST_SECURE_KEY', 'Process')
            $restored = ConvertTo-SecureString -String $envVal
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($restored)
            try {
                $decrypted = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
            $decrypted | Should -Be $plain
        }
    }

    Context "PSCredential hand-off" {
        It "Sets CRED_USER and CRED_PASS env vars and emits FromEnv marker" {
            $sec = ConvertTo-SecureString 'creds-pass' -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential('DOMAIN\user', $sec)
            $bp = @{ ShareCredential = $cred }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'

            $s | Should -Match '-ShareCredentialFromEnv'
            $s | Should -Not -Match 'creds-pass'

            $user = [System.Environment]::GetEnvironmentVariable('MERLIN_TEST_CRED_USER_SHARECREDENTIAL', 'Process')
            $pass = [System.Environment]::GetEnvironmentVariable('MERLIN_TEST_CRED_PASS_SHARECREDENTIAL', 'Process')
            $user | Should -Be 'DOMAIN\user'
            $pass | Should -Not -BeNullOrEmpty
            $pass | Should -Not -Match 'creds-pass'
        }
    }

    Context "Null and empty" {
        It "Skips parameters with null values" {
            $bp = @{ Empty = $null; Real = 'x' }
            $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Not -Match '-Empty'
            $s | Should -Match '-Real "x"'
        }
        It "Returns empty string for an empty hashtable" {
            $s = ConvertTo-ElevationArgumentString -BoundParameters @{} -EnvVarPrefix 'MERLIN_TEST_'
            $s | Should -Be ''
        }
    }
}

Describe "Request-Elevation - re-launch behavior" {

    BeforeEach {
        Clear-MerlinTestEnv
    }

    It "Returns without calling Start-Process when already admin" {
        Mock Test-IsAdmin { $true }
        Mock Start-Process { throw "Start-Process should NOT be called when already admin" }

        { Request-Elevation -ScriptPath 'C:\fake\script.ps1' -BoundParameters @{ X = 1 } -Silent } |
            Should -Not -Throw

        Should -Invoke Start-Process -Times 0
    }

    It "Calls Start-Process with -Verb RunAs when not admin" {
        $script:runAsCalls = 0
        $script:capturedArgs = $null
        Mock Test-IsAdmin { $false }
        Mock Exit-Elevation { }
        Mock Start-Process {
            $script:runAsCalls++
            $script:capturedArgs = $ArgumentList
            [PSCustomObject]@{ ExitCode = 0 }
        } -ParameterFilter { $Verb -eq 'RunAs' }

        Request-Elevation -ScriptPath 'C:\fake\script.ps1' -BoundParameters @{ Foo = 'bar' } -Silent

        $script:runAsCalls | Should -BeGreaterOrEqual 1
        $script:capturedArgs | Should -Match 'C:\\fake\\script\.ps1'
        $script:capturedArgs | Should -Match '-Foo "bar"'
    }

    It "Propagates child exit code to Exit-Elevation" {
        $script:capturedExit = $null
        Mock Test-IsAdmin { $false }
        Mock Exit-Elevation { $script:capturedExit = $ExitCode }
        Mock Start-Process {
            [PSCustomObject]@{ ExitCode = 42 }
        } -ParameterFilter { $Verb -eq 'RunAs' }

        Request-Elevation -ScriptPath 'C:\fake\script.ps1' -BoundParameters @{} -Silent

        $script:capturedExit | Should -Be 42
    }

    It "Marshalled args reach the command line (integration via builder)" {
        $bp = @{
            Foo     = 'bar'
            Verbose = [System.Management.Automation.SwitchParameter]::new($true)
            List    = @('a','b')
        }
        $s = ConvertTo-ElevationArgumentString -BoundParameters $bp -EnvVarPrefix 'MERLIN_TEST_'
        $s | Should -Match '-Foo "bar"'
        $s | Should -Match '-Verbose'
        $s | Should -Match '-List "a","b"'
    }
}
