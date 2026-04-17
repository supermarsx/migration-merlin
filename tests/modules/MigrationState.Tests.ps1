#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for MigrationState.psm1.
.DESCRIPTION
    Validates the New-MigrationState factory, Step-MigrationState mutator,
    and Get-MigrationStateProgress / Get-MigrationStateElapsed accessors.
#>

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\modules\MigrationState.psm1'
    Import-Module $ModulePath -Force
}

AfterAll {
    Remove-Module MigrationState -Force -ErrorAction SilentlyContinue
}

Describe 'MigrationState module load' {
    It 'imports cleanly and exports the expected functions' {
        $mod = Get-Module MigrationState
        $mod | Should -Not -BeNullOrEmpty

        $exported = $mod.ExportedFunctions.Keys
        'New-MigrationState', 'Step-MigrationState',
        'Get-MigrationStateProgress', 'Get-MigrationStateElapsed' | ForEach-Object {
            $exported | Should -Contain $_
        }
    }
}

Describe 'New-MigrationState' {
    It 'returns a hashtable-like object with all 6 expected keys' {
        $s = New-MigrationState
        $keys = @($s.Keys)
        'TotalSteps', 'CurrentStep', 'StartTime', 'USMTDir', 'MappedDrive', 'ShareConnected' |
            ForEach-Object { $keys | Should -Contain $_ }
        $keys.Count | Should -Be 6
    }

    It 'uses expected defaults: TotalSteps=7, CurrentStep=0, ShareConnected=$false' {
        $s = New-MigrationState
        $s.TotalSteps     | Should -Be 7
        $s.CurrentStep    | Should -Be 0
        $s.ShareConnected | Should -BeFalse
        $s.USMTDir        | Should -BeNullOrEmpty
        $s.MappedDrive    | Should -BeNullOrEmpty
        $s.StartTime      | Should -BeOfType ([datetime])
    }

    It 'honors parameter overrides (TotalSteps=5)' {
        $s = New-MigrationState -TotalSteps 5
        $s.TotalSteps | Should -Be 5
    }

    It 'honors USMTDir / MappedDrive / ShareConnected overrides' {
        $s = New-MigrationState -USMTDir 'C:\USMT' -MappedDrive 'Z:' -ShareConnected $true
        $s.USMTDir        | Should -Be 'C:\USMT'
        $s.MappedDrive    | Should -Be 'Z:'
        $s.ShareConnected | Should -BeTrue
    }

    It 'honors StartTime override' {
        $when = Get-Date '2024-01-01T00:00:00'
        $s = New-MigrationState -StartTime $when
        $s.StartTime | Should -Be $when
    }
}

Describe 'Step-MigrationState' {
    It 'increments CurrentStep by 1 by default' {
        $s = New-MigrationState -TotalSteps 7
        Step-MigrationState -State $s | Out-Null
        $s.CurrentStep | Should -Be 1
    }

    It 'increments by -By 3 when specified' {
        $s = New-MigrationState -TotalSteps 7
        Step-MigrationState -State $s -By 3 | Out-Null
        $s.CurrentStep | Should -Be 3
    }

    It 'clamps CurrentStep at TotalSteps (does not exceed)' {
        $s = New-MigrationState -TotalSteps 5 -CurrentStep 4
        Step-MigrationState -State $s -By 10 | Out-Null
        $s.CurrentStep | Should -Be 5
    }

    It 'returns the same state instance (mutates in place)' {
        $s = New-MigrationState
        $returned = Step-MigrationState -State $s
        [object]::ReferenceEquals($returned, $s) | Should -BeTrue
    }
}

Describe 'Get-MigrationStateProgress' {
    It 'returns 0.0 when CurrentStep is 0' {
        $s = New-MigrationState -TotalSteps 10 -CurrentStep 0
        Get-MigrationStateProgress -State $s | Should -Be 0.0
    }

    It 'returns 50.0 when half complete' {
        $s = New-MigrationState -TotalSteps 10 -CurrentStep 5
        Get-MigrationStateProgress -State $s | Should -Be 50.0
    }

    It 'returns 100.0 when fully complete' {
        $s = New-MigrationState -TotalSteps 4 -CurrentStep 4
        Get-MigrationStateProgress -State $s | Should -Be 100.0
    }

    It 'handles TotalSteps=0 without divide-by-zero' {
        $s = New-MigrationState -TotalSteps 0 -CurrentStep 0
        { Get-MigrationStateProgress -State $s } | Should -Not -Throw
        Get-MigrationStateProgress -State $s | Should -Be 0.0
    }
}

Describe 'Get-MigrationStateElapsed' {
    It 'returns a TimeSpan' {
        $s = New-MigrationState
        $elapsed = Get-MigrationStateElapsed -State $s
        $elapsed | Should -BeOfType ([timespan])
    }

    It 'returns a roughly correct elapsed value' {
        $when = (Get-Date).AddSeconds(-30)
        $s = New-MigrationState -StartTime $when
        $elapsed = Get-MigrationStateElapsed -State $s
        $elapsed.TotalSeconds | Should -BeGreaterOrEqual 29
        $elapsed.TotalSeconds | Should -BeLessThan 60
    }
}
