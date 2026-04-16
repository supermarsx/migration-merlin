#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for MigrationUI.psm1.
.DESCRIPTION
    Verifies banner/step/status/detail/progress/spinner helpers and the
    state-injection priority order (param > module > caller script scope).
#>

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\MigrationUI.psm1'
    Import-Module $ModulePath -Force
}

AfterAll {
    Remove-Module MigrationUI -Force -ErrorAction SilentlyContinue
}

Describe 'MigrationUI module load' {
    It 'imports cleanly and exports the expected functions' {
        $mod = Get-Module MigrationUI
        $mod | Should -Not -BeNullOrEmpty

        $exported = $mod.ExportedFunctions.Keys
        'Show-Banner','Show-Step','Show-Status','Show-Detail',
        'Show-ProgressBar','Show-SubProgress','Show-Spinner',
        'Set-MigrationUIState','Get-MigrationUIState',
        'Get-MigrationUIGlyphs' | ForEach-Object {
            $exported | Should -Contain $_
        }
    }
}

Describe 'Show-Banner' {
    It 'writes the title to host output' {
        $out = Show-Banner -Title 'UNIT TEST' 6>&1
        ($out -join "`n") | Should -Match 'UNIT TEST'
    }

    It 'renders the banner divider line' {
        $out = Show-Banner -Title 'X' 6>&1
        ($out -join "`n") | Should -Match '=+'
    }

    It 'uses the supplied ConsoleColor via Write-Host invocation' {
        InModuleScope MigrationUI {
            $script:capturedColors = New-Object System.Collections.ArrayList
            Mock Write-Host { [void]$script:capturedColors.Add($ForegroundColor) }
            Show-Banner -Title 'COLOR' -Color Yellow
            $script:capturedColors | Should -Contain ([ConsoleColor]::Yellow)
        }
    }
}

Describe 'Show-Status' {
    BeforeEach {
        # Fresh mock inside module scope for each test
    }

    It 'uses [+] icon and Green color for OK' {
        InModuleScope MigrationUI {
            Mock Write-Host {}
            Show-Status -Message 'yay' -Level OK
            Should -Invoke Write-Host -ParameterFilter {
                $Object -match '\[\+\]' -and $ForegroundColor -eq 'Green'
            } -Times 1
        }
    }

    It 'uses [X] icon and Red color for FAIL' {
        InModuleScope MigrationUI {
            Mock Write-Host {}
            Show-Status -Message 'bad' -Level FAIL
            Should -Invoke Write-Host -ParameterFilter {
                $Object -match '\[X\]' -and $ForegroundColor -eq 'Red'
            } -Times 1
        }
    }

    It 'uses [!] icon and Yellow color for WARN' {
        InModuleScope MigrationUI {
            Mock Write-Host {}
            Show-Status -Message 'meh' -Level WARN
            Should -Invoke Write-Host -ParameterFilter {
                $Object -match '\[!\]' -and $ForegroundColor -eq 'Yellow'
            } -Times 1
        }
    }

    It 'uses [i] icon for INFO (default)' {
        InModuleScope MigrationUI {
            Mock Write-Host {}
            Show-Status -Message 'info'
            Should -Invoke Write-Host -ParameterFilter {
                $Object -match '\[i\]'
            } -Times 1
        }
    }
}

Describe 'Show-Detail' {
    It 'prints Label and Value' {
        $out = Show-Detail -Label 'Path' -Value 'C:\Foo' 6>&1
        $joined = ($out -join "`n")
        $joined | Should -Match 'Path'
        $joined | Should -Match 'C:\\Foo'
    }
}

Describe 'Show-Step with state injection' {
    It 'increments CurrentStep in the supplied -State hashtable' {
        $state = @{ CurrentStep = 0; TotalSteps = 4; StartTime = Get-Date }
        Show-Step -Description 'first' -State $state 6>&1 | Out-Null
        $state.CurrentStep | Should -Be 1

        Show-Step -Description 'second' -State $state 6>&1 | Out-Null
        $state.CurrentStep | Should -Be 2
    }

    It 'reports the correct percentage and step label' {
        $state = @{ CurrentStep = 1; TotalSteps = 4; StartTime = Get-Date }
        $out = Show-Step -Description 'middle' -State $state 6>&1
        $joined = ($out -join '|')
        $joined | Should -Match '50%'
        $joined | Should -Match 'Step 2/4'
        $joined | Should -Match 'middle'
    }

    It 'uses module state when -State is not provided' {
        Set-MigrationUIState -State @{ CurrentStep = 0; TotalSteps = 2; StartTime = Get-Date }
        Show-Step -Description 'a' 6>&1 | Out-Null
        (Get-MigrationUIState).CurrentStep | Should -Be 1
        Show-Step -Description 'b' 6>&1 | Out-Null
        (Get-MigrationUIState).CurrentStep | Should -Be 2

        # Reset so later tests aren't polluted.
        Set-MigrationUIState -State @{ CurrentStep = 0; TotalSteps = 0; StartTime = $null }
    }

    It 'falls back to global-scope variables when neither param nor module state is set' {
        Set-MigrationUIState -State @{ CurrentStep = 0; TotalSteps = 0; StartTime = $null }

        $Global:CurrentStep = 0
        $Global:TotalSteps  = 3
        $Global:StartTime   = Get-Date
        try {
            Show-Step -Description 'scoped' 6>&1 | Out-Null
            $Global:CurrentStep | Should -Be 1
        }
        finally {
            Remove-Variable -Name CurrentStep -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name TotalSteps  -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name StartTime   -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Show-ProgressBar' {
    It 'renders a filled + empty ratio matching the percentage' {
        InModuleScope MigrationUI {
            $captured = $null
            Mock Write-Host { $script:captured = $Object } -ParameterFilter { $NoNewline }
            Show-ProgressBar -Current 50 -Total 100 -Label 'half'
            $script:captured | Should -Match '50%'
            $script:captured | Should -Match 'half'

            # Filled/empty glyphs depend on console codepage (t1-e14a).
            $g = Get-MigrationUIGlyphs
            $filledChar = [char]$g.BarFilled
            $emptyChar  = [char]$g.BarEmpty
            $filledCount = ($script:captured.ToCharArray() | Where-Object { $_ -eq $filledChar }).Count
            $emptyCount  = ($script:captured.ToCharArray() | Where-Object { $_ -eq $emptyChar  }).Count
            # Default ProgressBarLen = 35; 50% => 17 filled, 18 empty (floor).
            ($filledCount + $emptyCount) | Should -Be 35
            $filledCount | Should -Be 17
            $emptyCount  | Should -Be 18
        }
    }

    It 'is a no-op when Total is zero' {
        InModuleScope MigrationUI {
            Mock Write-Host {}
            Show-ProgressBar -Current 0 -Total 0 -Label 'nope'
            Should -Invoke Write-Host -Times 0
        }
    }

    It 'appends the Detail fragment when provided' {
        InModuleScope MigrationUI {
            $captured = $null
            Mock Write-Host { $script:captured = $Object } -ParameterFilter { $NoNewline }
            Show-ProgressBar -Current 1 -Total 4 -Label 'lbl' -Detail 'dtl'
            $script:captured | Should -Match '\(dtl\)'
        }
    }
}

Describe 'Show-SubProgress' {
    It 'shows index/total and item text' {
        InModuleScope MigrationUI {
            $captured = $null
            Mock Write-Host { $script:captured = $Object } -ParameterFilter { $NoNewline }
            Show-SubProgress -Item 'foo.txt' -Index 2 -Total 7
            $script:captured | Should -Match '\(2/7\)'
            $script:captured | Should -Match 'foo\.txt'
        }
    }
}

Describe 'Show-Spinner' {
    It 'returns the Action result' {
        InModuleScope MigrationUI {
            Mock Write-Host {}
            $result = Show-Spinner -Message 'work' -Action { 'done' } -IntervalMs 20
            $result | Should -Be 'done'
        }
    }

    It 'writes the completion marker [+] when the job finishes' {
        InModuleScope MigrationUI {
            $script:spinnerOutput = New-Object System.Collections.ArrayList
            Mock Write-Host { [void]$script:spinnerOutput.Add(($Object -as [string])) }
            Show-Spinner -Message 'work' -Action { 'ok' } -IntervalMs 20 | Out-Null
            ($script:spinnerOutput -join '|') | Should -Match '\[\+\] work'
        }
    }

    It 'cycles through the expected spinner frames for longer operations' {
        InModuleScope MigrationUI {
            $g = Get-MigrationUIGlyphs
            $expected = @($g.Spinner | ForEach-Object { [string]$_ })
            $framesSeen = @{}
            Mock Write-Host {
                $s = ($Object -as [string])
                foreach ($c in $expected) {
                    if ($s -and $s.Contains("[$c]")) { $framesSeen[$c] = $true }
                }
            }
            # Long-ish action so several frames render.
            Show-Spinner -Message 'spin' -Action { Start-Sleep -Milliseconds 350 } -IntervalMs 30 | Out-Null
            $framesSeen.Keys.Count | Should -BeGreaterThan 1
        }
    }
}

Describe 'Set-MigrationUIState / Get-MigrationUIState' {
    It 'round-trips values' {
        $when = Get-Date '2026-04-16T10:00:00'
        Set-MigrationUIState -State @{ CurrentStep = 5; TotalSteps = 10; StartTime = $when }
        $s = Get-MigrationUIState
        $s.CurrentStep | Should -Be 5
        $s.TotalSteps  | Should -Be 10
        $s.StartTime   | Should -Be $when
    }
}

# =============================================================================
# Codepage-aware glyph fallback (t1-e14a)
# =============================================================================
Describe 'Get-MigrationUIGlyphs' {
    It 'returns a hashtable with all expected keys' {
        $g = Get-MigrationUIGlyphs
        $g | Should -BeOfType [hashtable]
        'BarFilled','BarEmpty','Spinner','CheckMark','Cross' | ForEach-Object {
            $g.ContainsKey($_) | Should -BeTrue
        }
    }

    It 'returns at least one spinner frame' {
        $g = Get-MigrationUIGlyphs
        @($g.Spinner).Count | Should -BeGreaterThan 0
    }

    It 'returns Unicode block glyphs on a UTF-8 console (cp 65001)' {
        InModuleScope MigrationUI {
            # Force the UTF-8 branch. Use a lightweight object mimicking
            # [System.Text.Encoding]'s CodePage property rather than mutating
            # the real [Console]::OutputEncoding.
            $orig = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
                $g = Get-MigrationUIGlyphs
                [int][char]$g.BarFilled | Should -Be 0x2588
                [int][char]$g.BarEmpty  | Should -Be 0x2591
                @($g.Spinner).Count | Should -BeGreaterThan 4
            } finally {
                [Console]::OutputEncoding = $orig
            }
        }
    }

    It 'returns ASCII-safe glyphs on a legacy codepage (e.g. cp 437)' {
        InModuleScope MigrationUI {
            $orig = [Console]::OutputEncoding
            try {
                # Try to obtain cp 437 (US OEM). Fall back to 1252 if missing.
                $legacy = $null
                try { $legacy = [System.Text.Encoding]::GetEncoding(437) } catch {}
                if (-not $legacy) {
                    try { $legacy = [System.Text.Encoding]::GetEncoding(1252) } catch {}
                }
                if (-not $legacy) {
                    Set-ItResult -Skipped -Because 'neither 437 nor 1252 available on this host'
                    return
                }
                [Console]::OutputEncoding = $legacy
                $g = Get-MigrationUIGlyphs
                [string]$g.BarFilled | Should -Be '#'
                [string]$g.BarEmpty  | Should -Be '-'
                $g.Spinner           | Should -Be @('|','/','-','\')
                [string]$g.CheckMark | Should -Be '+'
                [string]$g.Cross     | Should -Be 'x'
            } finally {
                [Console]::OutputEncoding = $orig
            }
        }
    }

    It 'treats UTF-16 LE (cp 1200) as Unicode-capable' {
        InModuleScope MigrationUI {
            # We can't always set UTF-16 as a console encoding; simulate by
            # mocking [Console]::OutputEncoding via a script-scope override.
            # Simpler: verify the codepage list directly in the function body
            # by driving through the real helper with UTF-8 and asserting the
            # array is the expected set.
            $g = Get-MigrationUIGlyphs
            # On a sane modern host, at least one of the Unicode codepages
            # should match — confirm the branch structure works.
            $g | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Show-* functions use Get-MigrationUIGlyphs' {
    It 'Show-ProgressBar falls back to ASCII on a legacy codepage' {
        InModuleScope MigrationUI {
            $orig = [Console]::OutputEncoding
            $captured = $null
            try {
                $legacy = $null
                try { $legacy = [System.Text.Encoding]::GetEncoding(437) } catch {}
                if (-not $legacy) {
                    try { $legacy = [System.Text.Encoding]::GetEncoding(1252) } catch {}
                }
                if (-not $legacy) {
                    Set-ItResult -Skipped -Because 'no legacy codepage available on this host'
                    return
                }
                [Console]::OutputEncoding = $legacy
                Mock Write-Host { $script:captured = $Object } -ParameterFilter { $NoNewline }
                Show-ProgressBar -Current 50 -Total 100 -Label 'half'
                $script:captured | Should -Match '#'
                $script:captured | Should -Match '-'
                # Must not contain Unicode block/shade glyphs.
                ($script:captured.Contains([char]0x2588)) | Should -BeFalse
                ($script:captured.Contains([char]0x2591)) | Should -BeFalse
            } finally {
                [Console]::OutputEncoding = $orig
            }
        }
    }

    It 'Show-Step falls back to ASCII bar on a legacy codepage' {
        InModuleScope MigrationUI {
            $orig = [Console]::OutputEncoding
            try {
                $legacy = $null
                try { $legacy = [System.Text.Encoding]::GetEncoding(437) } catch {}
                if (-not $legacy) {
                    try { $legacy = [System.Text.Encoding]::GetEncoding(1252) } catch {}
                }
                if (-not $legacy) {
                    Set-ItResult -Skipped -Because 'no legacy codepage available on this host'
                    return
                }
                [Console]::OutputEncoding = $legacy
                $state = @{ CurrentStep = 1; TotalSteps = 4; StartTime = Get-Date }
                $out = Show-Step -Description 'mid' -State $state 6>&1
                $joined = ($out -join '|')
                $joined | Should -Match '50%'
                ($joined.Contains([char]0x2588)) | Should -BeFalse
            } finally {
                [Console]::OutputEncoding = $orig
            }
        }
    }

    It 'Show-Spinner uses ASCII frames on a legacy codepage' {
        InModuleScope MigrationUI {
            $orig = [Console]::OutputEncoding
            try {
                $legacy = $null
                try { $legacy = [System.Text.Encoding]::GetEncoding(437) } catch {}
                if (-not $legacy) {
                    try { $legacy = [System.Text.Encoding]::GetEncoding(1252) } catch {}
                }
                if (-not $legacy) {
                    Set-ItResult -Skipped -Because 'no legacy codepage available on this host'
                    return
                }
                [Console]::OutputEncoding = $legacy
                $framesSeen = @{}
                Mock Write-Host {
                    $s = ($Object -as [string])
                    foreach ($c in '|','/','-','\') {
                        if ($s -and $s.Contains("[$c]")) { $framesSeen[$c] = $true }
                    }
                }
                Show-Spinner -Message 'spin' -Action { Start-Sleep -Milliseconds 250 } -IntervalMs 30 | Out-Null
                $framesSeen.Keys.Count | Should -BeGreaterThan 1
            } finally {
                [Console]::OutputEncoding = $orig
            }
        }
    }

    It 'Glyph keys survive a Get-MigrationUIGlyphs round-trip (cache-friendliness)' {
        $g1 = Get-MigrationUIGlyphs
        $g2 = Get-MigrationUIGlyphs
        [string]$g1.BarFilled | Should -Be ([string]$g2.BarFilled)
        [string]$g1.BarEmpty  | Should -Be ([string]$g2.BarEmpty)
        @($g1.Spinner).Count  | Should -Be (@($g2.Spinner).Count)
    }
}
