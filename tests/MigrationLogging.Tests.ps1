#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for MigrationLogging.ps1 — focused on Format-SafeParams and
    smoke tests for the existing logging/retry/CIM helpers.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\modules\MigrationLogging.ps1'
    . $script:ScriptPath

    # Initialize logging into a temp dir so Write-Log has somewhere to write.
    $script:TestLogDir = Join-Path $env:TEMP ("MigrationLoggingTests-" + [guid]::NewGuid())
    New-Item -Path $script:TestLogDir -ItemType Directory -Force | Out-Null
    $script:TestLogFile = Join-Path $script:TestLogDir 'test.log'
    Initialize-Logging -PrimaryLogFile $script:TestLogFile -ScriptName 'migration-logging-tests' | Out-Null
}

AfterAll {
    try { Stop-Logging } catch {}
    if ($script:TestLogDir -and (Test-Path $script:TestLogDir)) {
        Remove-Item $script:TestLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'MigrationLogging import' {
    It 'dot-sources without error and defines core functions' {
        Get-Command Format-SafeParams -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Write-Log        -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Safe-Exit        -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Try-CimInstance  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Invoke-SafeCommand -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Format-SafeParams — sensitive key masking' {
    It 'masks Password, EncryptionKey, SharePassword, ApiKey, Token with ***' {
        $params = @{
            Password      = 'hunter2'
            EncryptionKey = 'DEADBEEF'
            SharePassword = 'p@ss'
            ApiKey        = 'sk_live_123'
            Token         = 'abc.def.ghi'
        }
        $out = Format-SafeParams -Parameters $params -AsObject
        $out['Password']      | Should -Be '***'
        $out['EncryptionKey'] | Should -Be '***'
        $out['SharePassword'] | Should -Be '***'
        $out['ApiKey']        | Should -Be '***'
        $out['Token']         | Should -Be '***'
    }

    It 'does not mask non-sensitive keys like DestinationShare, UserName, Path' {
        # Note: PowerShell hashtables are case-insensitive, so 'Username' and
        # 'UserName' would collide. We test the canonical spellings here.
        $params = @{
            DestinationShare = '\\server\share'
            UserName         = 'alice'
            Path             = 'C:\data'
        }
        $out = Format-SafeParams -Parameters $params -AsObject
        $out['DestinationShare'] | Should -Be '\\server\share'
        $out['UserName']         | Should -Be 'alice'
        $out['Path']             | Should -Be 'C:\data'
    }

    It 'is case-insensitive: password / PASSWORD / Password all masked' {
        # Each cased spelling must mask independently (one hashtable per case
        # because PowerShell hashtables are case-insensitive by default and
        # would collapse these into a single key).
        foreach ($k in @('password', 'PASSWORD', 'Password', 'pAsSwOrD')) {
            $params = @{ $k = 'secret' }
            $out = Format-SafeParams -Parameters $params -AsObject
            $out[$k] | Should -Be '***'
        }
    }

    It 'custom -SensitivePatterns overrides defaults' {
        $params = @{
            Password = 'should-remain'  # NOT in custom list
            Moo      = 'redact-me'      # IS in custom list
        }
        $out = Format-SafeParams -Parameters $params -SensitivePatterns @('Moo') -AsObject
        $out['Password'] | Should -Be 'should-remain'
        $out['Moo']      | Should -Be '***'
    }
}

Describe 'Format-SafeParams — return type' {
    It '-AsObject returns a hashtable' {
        $out = Format-SafeParams -Parameters @{ Foo = 'bar' } -AsObject
        $out | Should -BeOfType [hashtable]
    }

    It 'without -AsObject returns a compressed JSON string' {
        $out = Format-SafeParams -Parameters @{ Foo = 'bar'; Password = 'x' }
        $out | Should -BeOfType [string]
        $out | Should -Match '"Foo":"bar"'
        $out | Should -Match '"Password":"\*\*\*"'
        # Compressed — no newlines or indentation spaces.
        $out | Should -Not -Match "`n"
    }
}

Describe 'Format-SafeParams — special value types' {
    It 'masks [SecureString] values regardless of key name' {
        $ss = ConvertTo-SecureString 'topsecret' -AsPlainText -Force
        $params = @{ HarmlessLookingName = $ss }
        $out = Format-SafeParams -Parameters $params -AsObject
        $out['HarmlessLookingName'] | Should -Be '***'
    }

    It 'masks [PSCredential] values with ***(PSCredential)***' {
        $ss = ConvertTo-SecureString 'pw' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential('user', $ss)
        $params = @{ MyCred = $cred }
        $out = Format-SafeParams -Parameters $params -AsObject
        $out['MyCred'] | Should -Be '***(PSCredential)***'
    }
}

Describe 'Format-SafeParams — caller hashtable is not mutated' {
    It 'leaves the original Password value intact' {
        $params = @{ Password = 'keep-me-original'; Other = 1 }
        $null = Format-SafeParams -Parameters $params -AsObject
        $params['Password'] | Should -Be 'keep-me-original'
        $params['Other']    | Should -Be 1
    }
}

Describe 'Format-SafeParams — nested masking' {
    It 'recurses into nested hashtables up to depth 2' {
        $params = @{
            Outer = @{
                Password = 'secret1'
                Inner    = @{
                    ApiKey = 'secret2'
                    Note   = 'visible'
                }
            }
            Plain = 'top-level-visible'
        }
        $out = Format-SafeParams -Parameters $params -Depth 3 -AsObject
        $out['Plain'] | Should -Be 'top-level-visible'
        $out['Outer']['Password']        | Should -Be '***'
        $out['Outer']['Inner']['ApiKey'] | Should -Be '***'
        $out['Outer']['Inner']['Note']   | Should -Be 'visible'
    }
}

Describe 'Existing logging surface — smoke tests' {
    It 'Write-Log is callable and does not throw on minimal args' {
        { Write-Log 'smoke test message' } | Should -Not -Throw
        { Write-Log 'warn message' 'WARN' } | Should -Not -Throw
    }

    It 'Invoke-WithRetry returns the scriptblock result on success' {
        $result = Invoke-WithRetry -ScriptBlock { 42 } -OperationName 'smoke' -MaxRetries 2 -InitialDelaySeconds 0 -LogOnly
        $result | Should -Be 42
    }

    It 'Invoke-WithRetry rethrows after exceeding MaxRetries' {
        {
            Invoke-WithRetry -ScriptBlock { throw 'boom' } -OperationName 'fail-smoke' `
                -MaxRetries 2 -InitialDelaySeconds 0 -LogOnly
        } | Should -Throw
    }

    It 'Try-CimInstance is callable and returns something or $null without throwing' {
        # Use a real but cheap class so the call has a chance to succeed.
        { Try-CimInstance -ClassName 'Win32_OperatingSystem' -FriendlyName 'OS' } | Should -Not -Throw
    }

    It 'Safe-Exit is defined (not invoked — it calls exit)' {
        Get-Command Safe-Exit | Should -Not -BeNullOrEmpty
        (Get-Command Safe-Exit).Parameters.ContainsKey('Code')   | Should -BeTrue
        (Get-Command Safe-Exit).Parameters.ContainsKey('Reason') | Should -BeTrue
    }
}
