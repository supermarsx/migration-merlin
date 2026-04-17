#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for MigrationValidators.psm1.
.DESCRIPTION
    Covers each exported Test-* function across positive / negative / edge
    cases. All tests are side-effect free; Test-USMTPath uses a temp dir.
#>

BeforeAll {
    $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\modules\MigrationValidators.psm1')).Path
    Import-Module $script:ModulePath -Force
}

AfterAll {
    Remove-Module MigrationValidators -Force -ErrorAction SilentlyContinue
}

Describe 'MigrationValidators module import' {
    It 'imports without error' {
        { Import-Module $script:ModulePath -Force } | Should -Not -Throw
    }

    It 'exports the five expected functions' {
        $exported = (Get-Module MigrationValidators).ExportedFunctions.Keys | Sort-Object
        $exported | Should -Contain 'Test-UncPath'
        $exported | Should -Contain 'Test-USMTPath'
        $exported | Should -Contain 'Test-ProfileName'
        $exported | Should -Contain 'Test-EncryptionKeyStrength'
        $exported | Should -Contain 'Test-ShareName'
    }
}

Describe 'Test-UncPath' {
    It 'accepts a simple \\server\share path' {
        Test-UncPath -Path '\\server\share' | Should -BeTrue
    }

    It 'accepts a hidden / admin share (trailing $)' {
        Test-UncPath -Path '\\server\share$' | Should -BeTrue
    }

    It 'accepts a share with a subpath' {
        Test-UncPath -Path '\\server\share\sub\path' | Should -BeTrue
    }

    It 'accepts a dotted server name' {
        Test-UncPath -Path '\\host.example.com\share' | Should -BeTrue
    }

    It 'rejects a local C: drive path' {
        Test-UncPath -Path 'C:\local\path' | Should -BeFalse
    }

    It 'rejects a POSIX-style path' {
        Test-UncPath -Path '/server/share' | Should -BeFalse
    }

    It 'rejects an empty string' {
        Test-UncPath -Path '' | Should -BeFalse
    }

    It 'rejects a relative path' {
        Test-UncPath -Path '..\share' | Should -BeFalse
    }

    It 'rejects a single-backslash prefix' {
        Test-UncPath -Path '\server\share' | Should -BeFalse
    }

    It 'rejects paths containing illegal characters in the share segment' {
        Test-UncPath -Path '\\server\sh?are' | Should -BeFalse
        Test-UncPath -Path '\\server\sh*re'  | Should -BeFalse
        Test-UncPath -Path '\\server\sh|re'  | Should -BeFalse
    }
}

Describe 'Test-USMTPath' {
    BeforeAll {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "mv-usmt-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

        $script:withScan  = Join-Path $script:tmpRoot 'withscan'
        $script:withLoad  = Join-Path $script:tmpRoot 'withload'
        $script:emptyDir  = Join-Path $script:tmpRoot 'empty'
        foreach ($d in $script:withScan, $script:withLoad, $script:emptyDir) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
        Set-Content -Path (Join-Path $script:withScan 'scanstate.exe') -Value 'stub'
        Set-Content -Path (Join-Path $script:withLoad 'loadstate.exe') -Value 'stub'
    }

    AfterAll {
        if ($script:tmpRoot -and (Test-Path $script:tmpRoot)) {
            Remove-Item $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns true when directory contains scanstate.exe (default)' {
        Test-USMTPath -Path $script:withScan | Should -BeTrue
    }

    It 'returns false when directory is missing scanstate.exe' {
        Test-USMTPath -Path $script:emptyDir | Should -BeFalse
    }

    It 'returns false when path does not exist' {
        Test-USMTPath -Path (Join-Path $script:tmpRoot 'does-not-exist') | Should -BeFalse
    }

    It 'honors a custom -ExeName (loadstate.exe)' {
        Test-USMTPath -Path $script:withLoad -ExeName 'loadstate.exe' | Should -BeTrue
    }

    It 'returns false when the requested ExeName is absent' {
        Test-USMTPath -Path $script:withScan -ExeName 'loadstate.exe' | Should -BeFalse
    }

    It 'returns false for an empty path' {
        Test-USMTPath -Path '' | Should -BeFalse
    }
}

Describe 'Test-ProfileName' {
    It 'accepts a simple lowercase name' {
        Test-ProfileName -Name 'alice' | Should -BeTrue
    }

    It 'accepts a mixed-case name with digits and underscore' {
        Test-ProfileName -Name 'Bob_1' | Should -BeTrue
    }

    It 'accepts a name with a period' {
        Test-ProfileName -Name 'x.y' | Should -BeTrue
    }

    It 'rejects a name containing a backslash' {
        Test-ProfileName -Name 'bad\name' | Should -BeFalse
    }

    It 'rejects an empty string' {
        Test-ProfileName -Name '' | Should -BeFalse
    }

    It 'rejects a whitespace-only string' {
        Test-ProfileName -Name '   ' | Should -BeFalse
    }

    It 'rejects a name containing a semicolon' {
        Test-ProfileName -Name 'a;b' | Should -BeFalse
    }

    It 'rejects a name containing a forward slash' {
        Test-ProfileName -Name 'alice/bob' | Should -BeFalse
    }

    It 'rejects a name containing square brackets' {
        Test-ProfileName -Name 'a[b]' | Should -BeFalse
    }
}

Describe 'Test-EncryptionKeyStrength' {
    It 'accepts a plain string at the default minimum length' {
        Test-EncryptionKeyStrength -Key 'abcdefgh' | Should -BeTrue
    }

    It 'rejects a string shorter than the default minimum' {
        Test-EncryptionKeyStrength -Key 'abc' | Should -BeFalse
    }

    It 'accepts a SecureString whose plaintext meets the length requirement' {
        $sec = ConvertTo-SecureString 'longenough' -AsPlainText -Force
        Test-EncryptionKeyStrength -Key $sec | Should -BeTrue
    }

    It 'rejects a SecureString whose plaintext is too short' {
        $sec = ConvertTo-SecureString 'short' -AsPlainText -Force
        Test-EncryptionKeyStrength -Key $sec | Should -BeFalse
    }

    It 'rejects an empty string' {
        Test-EncryptionKeyStrength -Key '' | Should -BeFalse
    }

    It 'rejects a whitespace-only string' {
        Test-EncryptionKeyStrength -Key '        ' | Should -BeFalse
    }

    It 'rejects a non-string / non-securestring type' {
        Test-EncryptionKeyStrength -Key 12345 | Should -BeFalse
    }

    It 'rejects $null' {
        Test-EncryptionKeyStrength -Key $null | Should -BeFalse
    }

    It 'honors a custom -MinimumLength 16' {
        Test-EncryptionKeyStrength -Key 'tooShortForSixteen' -MinimumLength 16 | Should -BeTrue
        Test-EncryptionKeyStrength -Key 'fifteen_charsss'    -MinimumLength 16 | Should -BeFalse
    }
}

Describe 'Test-ShareName' {
    It 'accepts a simple alphanumeric share name' {
        Test-ShareName -Name 'Share' | Should -BeTrue
    }

    It 'accepts a hidden share with trailing $' {
        Test-ShareName -Name 'MigrationShare$' | Should -BeTrue
    }

    It 'accepts a name with allowed punctuation (dash and dot)' {
        Test-ShareName -Name 'A-B.C' | Should -BeTrue
    }

    It 'rejects an empty string' {
        Test-ShareName -Name '' | Should -BeFalse
    }

    It 'rejects a name longer than 80 characters' {
        $long = 'a' * 81
        Test-ShareName -Name $long | Should -BeFalse
    }

    It 'rejects a name containing a forward slash' {
        Test-ShareName -Name 'bad/name' | Should -BeFalse
    }

    It 'rejects a name containing a backslash' {
        Test-ShareName -Name 'bad\name' | Should -BeFalse
    }

    It 'rejects a name starting with a dash' {
        Test-ShareName -Name '-share' | Should -BeFalse
    }

    It 'rejects a name containing a semicolon' {
        Test-ShareName -Name 'bad;name' | Should -BeFalse
    }
}
