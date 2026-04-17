#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for ErrorHandling.psm1.
#>

BeforeAll {
    $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\modules\ErrorHandling.psm1')).Path
    Import-Module $script:ModulePath -Force
}

AfterAll {
    Remove-Module ErrorHandling -Force -ErrorAction SilentlyContinue
}

Describe 'ErrorHandling module import' {
    It 'imports without error' {
        { Import-Module $script:ModulePath -Force } | Should -Not -Throw
    }

    It 'exports Invoke-WithErrorContext and Assert-NotNull' {
        $exported = (Get-Module ErrorHandling).ExportedFunctions.Keys
        $exported | Should -Contain 'Invoke-WithErrorContext'
        $exported | Should -Contain 'Assert-NotNull'
    }
}

Describe 'Invoke-WithErrorContext' {
    It 'runs the scriptblock and returns its output when no exception is thrown' {
        $result = Invoke-WithErrorContext -ScriptBlock { 42 } -Context 'NormalRun'
        $result | Should -Be 42
    }

    It 'swallows the exception when -Rethrow is NOT specified' {
        { Invoke-WithErrorContext -ScriptBlock { throw 'boom' } -Context 'BoomCtx' } |
            Should -Not -Throw
    }

    It 'rethrows the exception when -Rethrow IS specified' {
        { Invoke-WithErrorContext -ScriptBlock { throw 'boom again' } -Context 'BoomCtx' -Rethrow } |
            Should -Throw
    }

    It 'writes the error via Write-Host when Write-Log is not available' {
        # Capture Write-Host output by redirecting information / stream 6.
        $captured = Invoke-WithErrorContext -ScriptBlock { throw 'visible-error' } -Context 'VisibleCtx' 6>&1
        ($captured | Out-String) | Should -Match 'VisibleCtx failed: visible-error'
    }

    It 'calls Write-Log when it exists in caller scope' {
        $script:logged = @()
        function global:Write-Log {
            param([string]$Message, [string]$Level = 'INFO')
            $script:logged += ,@($Message, $Level)
        }
        try {
            Invoke-WithErrorContext -ScriptBlock { throw 'ouch' } -Context 'CtxLog' -Severity 'WARN' | Out-Null
            # Should have at least the main error entry plus the DEBUG stack trace.
            $script:logged.Count | Should -BeGreaterOrEqual 1
            ($script:logged | ForEach-Object { $_[0] }) -join '|' | Should -Match 'CtxLog failed: ouch'
        } finally {
            Remove-Item function:global:Write-Log -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Assert-NotNull' {
    It 'does not throw for a normal string value' {
        { Assert-NotNull -Value 'hello' -Name 'Thing' } | Should -Not -Throw
    }

    It 'does not throw for a non-string value (e.g. integer)' {
        { Assert-NotNull -Value 0 -Name 'Zero' } | Should -Not -Throw
    }

    It 'throws ArgumentNullException when value is $null' {
        { Assert-NotNull -Value $null -Name 'MyParam' } |
            Should -Throw -ExceptionType ([System.ArgumentNullException])
    }

    It 'throws for an empty string' {
        { Assert-NotNull -Value '' -Name 'EmptyParam' } |
            Should -Throw -ExceptionType ([System.ArgumentNullException])
    }

    It 'throws for a whitespace-only string' {
        { Assert-NotNull -Value '   ' -Name 'WsParam' } |
            Should -Throw -ExceptionType ([System.ArgumentNullException])
    }

    It 'includes the parameter name and context in the thrown message' {
        try {
            Assert-NotNull -Value $null -Name 'Foo' -Context 'MyFunc'
            throw 'expected Assert-NotNull to throw'
        } catch {
            $_.Exception.Message | Should -Match 'Foo'
            $_.Exception.Message | Should -Match 'MyFunc'
        }
    }
}
