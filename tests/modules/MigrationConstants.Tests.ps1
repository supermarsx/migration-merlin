#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for MigrationConstants.psm1.
.DESCRIPTION
    Verifies module import, exported surface, key presence, value types, and
    the Get-MigrationConstant dotted-path helper.
#>

BeforeAll {
    $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\modules\MigrationConstants.psm1')).Path
    Import-Module $script:ModulePath -Force

    # Pester v5 runs `It` blocks in a child scope — exported module variables
    # aren't automatically visible there. Re-bind into $script: so the tests
    # can see them.
    $script:MC = & (Get-Module MigrationConstants) { $MigrationConstants }
    $script:GetConst = Get-Command Get-MigrationConstant -Module MigrationConstants
}

AfterAll {
    Remove-Module MigrationConstants -Force -ErrorAction SilentlyContinue
}

Describe 'MigrationConstants module import' {
    It 'imports without error' {
        { Import-Module $script:ModulePath -Force } | Should -Not -Throw
    }

    It 'exports the MigrationConstants variable' {
        $mod = Get-Module MigrationConstants
        $mod | Should -Not -BeNullOrEmpty
        $mod.ExportedVariables.Keys | Should -Contain 'MigrationConstants'
    }

    It 'exports the Get-MigrationConstant function' {
        $script:GetConst | Should -Not -BeNullOrEmpty
    }
}

Describe 'MigrationConstants top-level keys' {
    It 'contains the expected top-level sections' {
        foreach ($section in 'USMT', 'ADK', 'Defaults', 'UI', 'Logging') {
            $script:MC.ContainsKey($section) | Should -BeTrue -Because "missing section: $section"
        }
    }
}

Describe 'USMT constants' {
    It 'USMT.SearchPaths is a string array' {
        $paths = $script:MC['USMT']['SearchPaths']
        , $paths | Should -BeOfType [string[]]
        $paths.Count | Should -BeGreaterThan 0
    }

    It 'USMT.SearchPaths includes the ADK install path' {
        $paths = $script:MC['USMT']['SearchPaths']
        ($paths -join '|') | Should -Match 'Windows Kits\\10\\Assessment and Deployment Kit\\User State Migration Tool'
    }

    It 'USMT.SearchPaths includes the bundled USMT-Tools path' {
        $paths = $script:MC['USMT']['SearchPaths']
        ($paths -join '|') | Should -Match 'USMT-Tools'
    }

    It 'USMT.ZipName is the bundled zip filename' {
        $script:MC['USMT']['ZipName'] | Should -Be 'user-state-migration-tool.zip'
    }

    It 'USMT.ZipInternalRoot matches the extracted folder name' {
        $script:MC['USMT']['ZipInternalRoot'] | Should -Be 'User State Migration Tool'
    }

    It 'USMT executable names are set' {
        $script:MC['USMT']['ScanStateExe'] | Should -Be 'scanstate.exe'
        $script:MC['USMT']['LoadStateExe'] | Should -Be 'loadstate.exe'
    }
}

Describe 'ADK constants' {
    It 'ADK.InstallerUrl is the Microsoft fwlink' {
        $url = $script:MC['ADK']['InstallerUrl']
        $url | Should -BeOfType [string]
        $url | Should -Be 'https://go.microsoft.com/fwlink/?linkid=2271337'
    }

    It 'ADK.InstallerFile is adksetup.exe' {
        $script:MC['ADK']['InstallerFile'] | Should -Be 'adksetup.exe'
    }
}

Describe 'Defaults constants' {
    It 'Defaults.MigrationFolder is C:\MigrationStore' {
        $script:MC['Defaults']['MigrationFolder'] | Should -Be 'C:\MigrationStore'
    }

    It 'Defaults.ShareName is the hidden share name' {
        $script:MC['Defaults']['ShareName'] | Should -Be 'MigrationShare$'
    }

    It 'Defaults.ShareDescription is a non-empty string' {
        $desc = $script:MC['Defaults']['ShareDescription']
        $desc | Should -BeOfType [string]
        [string]::IsNullOrWhiteSpace($desc) | Should -BeFalse
    }
}

Describe 'UI constants' {
    It 'UI.ProgressBarWidth is the integer 30' {
        $w = $script:MC['UI']['ProgressBarWidth']
        $w | Should -BeOfType [int]
        $w | Should -Be 30
    }

    It 'UI.SubProgressBarWidth is the integer 35' {
        $script:MC['UI']['SubProgressBarWidth'] | Should -Be 35
    }

    It 'UI.SourceTotalSteps is 7 and UI.DestinationTotalSteps is 5' {
        $script:MC['UI']['SourceTotalSteps']      | Should -Be 7
        $script:MC['UI']['DestinationTotalSteps'] | Should -Be 5
    }

    It 'UI.SpinnerFrames is a non-empty char array' {
        $frames = $script:MC['UI']['SpinnerFrames']
        $frames.Count | Should -BeGreaterThan 0
        $frames[0] | Should -BeOfType [char]
    }

    It 'UI.StatusIcons contains OK/WARN/FAIL/INFO entries' {
        $icons = $script:MC['UI']['StatusIcons']
        foreach ($k in 'OK', 'WARN', 'FAIL', 'INFO') {
            $icons.ContainsKey($k) | Should -BeTrue -Because "StatusIcons missing: $k"
        }
        $icons['OK']   | Should -Be '[+]'
        $icons['WARN'] | Should -Be '[!]'
        $icons['FAIL'] | Should -Be '[X]'
        $icons['INFO'] | Should -Be '[i]'
    }

    It 'UI.StatusColors contains OK/WARN/FAIL/INFO entries' {
        $colors = $script:MC['UI']['StatusColors']
        foreach ($k in 'OK', 'WARN', 'FAIL', 'INFO') {
            $colors.ContainsKey($k) | Should -BeTrue -Because "StatusColors missing: $k"
        }
        $colors['OK']   | Should -Be 'Green'
        $colors['FAIL'] | Should -Be 'Red'
        $colors['WARN'] | Should -Be 'Yellow'
    }
}

Describe 'Logging constants' {
    It 'Logging.DefaultLogFolder lives under TEMP\MigrationMerlin' {
        $script:MC['Logging']['DefaultLogFolder'] |
            Should -Be (Join-Path $env:TEMP 'MigrationMerlin')
    }
}

Describe 'Get-MigrationConstant helper' {
    It 'returns a leaf value via dotted path' {
        Get-MigrationConstant 'USMT.ZipName' | Should -Be 'user-state-migration-tool.zip'
    }

    It 'returns a nested leaf value' {
        Get-MigrationConstant 'UI.StatusIcons.OK' | Should -Be '[+]'
    }

    It 'returns the section for a single segment' {
        $section = Get-MigrationConstant 'ADK'
        $section['InstallerFile'] | Should -Be 'adksetup.exe'
    }

    It 'returns $null for a missing top-level key' {
        (Get-MigrationConstant 'NonExistent.Key') | Should -BeNullOrEmpty
    }

    It 'returns $null for a missing nested key' {
        (Get-MigrationConstant 'USMT.DoesNotExist') | Should -BeNullOrEmpty
    }

    It 'throws when Name is empty' {
        { Get-MigrationConstant -Name '' } | Should -Throw
    }
}
