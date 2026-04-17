<#
.SYNOPSIS
    Integration tests for USMT handling across source-capture.ps1,
    destination-setup.ps1, and MigrationMerlin.ps1.

.DESCRIPTION
    After task t1 (phases p1/p2), USMT detection/install/download logic
    moved into USMTTools.psm1 and magic strings moved into
    MigrationConstants.psm1. Their unit-level behavior is covered by:

      - tests/modules/USMTTools.Tests.ps1
      - tests/modules/MigrationConstants.Tests.ps1

    This file now only covers script-level INTEGRATION concerns that the
    module tests do not exercise:

      1. The scripts import USMTTools/MigrationConstants.
      2. The scripts call Install-USMT/Find-USMT with the right -ExeName
         (scanstate.exe for source, loadstate.exe for destination).
      3. The scripts forward -USMTPath into the module.
      4. The ADK installer URL flows through MigrationConstants and is pinned
         at the integration level (regression guard).
      5. The TUI (MigrationMerlin.ps1) still does its own lightweight USMT
         pre-check and passes -USMTPath to the scripts. (TUI has not yet been
         migrated to USMTTools — tracked separately.)
      6. Live USMT binaries on the host (when installed) work.

    Tests that previously grep'd inline source for constants/logic have been
    removed; the rationale is noted inline below.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force

    $ScriptRoot    = Split-Path $PSScriptRoot -Parent
    $SourceScript  = "$ScriptRoot\scripts\source-capture.ps1"
    $DestScript    = "$ScriptRoot\scripts\destination-setup.ps1"
    $TuiScript     = "$ScriptRoot\MigrationMerlin.ps1"
    $ConstantsPath = "$ScriptRoot\modules\MigrationConstants.psm1"

    $srcContent  = Get-Content $SourceScript  -Raw
    $destContent = Get-Content $DestScript    -Raw
    $tuiContent  = Get-Content $TuiScript     -Raw

    # Load MigrationConstants so the URL-integrity test can read the real value.
    Import-Module $ConstantsPath -Force
    $script:MC = & (Get-Module MigrationConstants) { $MigrationConstants }

    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' }
            elseif ([Environment]::Is64BitOperatingSystem)  { 'amd64' }
            else                                            { 'x86' }
}

AfterAll {
    Remove-Module MigrationConstants -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# REMOVED — covered elsewhere (do not re-add):
#
#   "USMT Detection (Find-USMT) / Search path coverage" inline-string greps
#     -> now in tests/modules/USMTTools.Tests.ps1 (Find-USMT) and
#        tests/modules/MigrationConstants.Tests.ps1 (USMT.SearchPaths).
#
#   "Bundled USMT Zip / Zip search paths / Zip extraction logic / Zip internal
#   structure" inline-string greps
#     -> Expand-BundledUSMT unit tests in tests/modules/USMTTools.Tests.ps1
#        and USMT.ZipName/ZipInternalRoot assertions in
#        tests/modules/MigrationConstants.Tests.ps1.
#
#   "ADK Online Download / URL accessibility / Download method availability /
#   ADK installer arguments" inline-string greps
#     -> Install-USMTOnline behavior and download-method fallback in
#        tests/modules/USMTTools.Tests.ps1. Installer argument list
#        ('/quiet', '/norestart', 'OptionId.UserStateMigrationTool',
#        '/ceip off') is compiled inside Install-USMTOnline, so it lives
#        with that module. URL literal is pinned by the "ADK installer URL
#        integrity" Describe block below.
#
#   "USMT Initialization Flow / Install-USMT priority order / Error handling"
#   inline-string greps
#     -> Install-USMT orchestration tests in tests/modules/USMTTools.Tests.ps1.
#
#   "Architecture detection / Detection with mock filesystem" scaffold
#     -> Find-USMT tests in tests/modules/USMTTools.Tests.ps1 already cover the
#        arch-suffixed layout with a real temp-dir filesystem. The pure
#        "can I create a file" scaffold tests added no integration value.
# ---------------------------------------------------------------------------

Describe 'Script -> USMTTools module wiring' {
    It 'source-capture.ps1 imports USMTTools.psm1' {
        $srcContent | Should -Match 'Import-Module\s+"[^"]*USMTTools\.psm1"'
    }

    It 'destination-setup.ps1 imports USMTTools.psm1' {
        $destContent | Should -Match 'Import-Module\s+"[^"]*USMTTools\.psm1"'
    }

    It 'source-capture.ps1 calls Install-USMT for the source side (scanstate.exe)' {
        # Source uses MigrationConstants.USMT.ScanStateExe (-> scanstate.exe).
        $srcContent | Should -Match 'Install-USMT\b[^\n]*-ExeName\s+\$MigrationConstants\.USMT\.ScanStateExe'
    }

    It 'destination-setup.ps1 calls Install-USMT with loadstate.exe' {
        # Destination wraps USMTTools\Install-USMT with a hard-coded loadstate.exe.
        $destContent | Should -Match "USMTTools\\Install-USMT[^`n]*-ExeName\s+'loadstate\.exe'"
    }

    It 'destination-setup.ps1 calls Find-USMT with loadstate.exe as the default' {
        # The wrapper defines: function Find-USMT { param([string]$ExeName = "loadstate.exe") ... }
        $destContent | Should -Match 'function\s+Find-USMT\s*\{[^}]*ExeName\s*=\s*"loadstate\.exe"'
    }
}

Describe 'Script -> -USMTPath forwarding' {
    It 'source-capture.ps1 forwards its -USMTPath parameter into Find-USMT' {
        $srcContent | Should -Match 'Find-USMT\b[^\n]*-USMTPathOverride\s+\$USMTPath'
    }

    It 'source-capture.ps1 forwards its -USMTPath parameter into Install-USMT' {
        $srcContent | Should -Match 'Install-USMT\b[^\n]*-USMTPathOverride\s+\$USMTPath'
    }

    It 'destination-setup.ps1 forwards its -USMTPath parameter into the module' {
        $destContent | Should -Match '-USMTPathOverride\s+\$USMTPath'
    }
}

Describe 'ADK installer URL integrity' {
    # Integration-level regression guard: if anyone ever changes the URL in
    # MigrationConstants.psm1, this test fails next to the other integration
    # assertions (the module test in MigrationConstants.Tests.ps1 also pins
    # it, but we want the anchor visible at the script-wiring level too).
    It 'MigrationConstants.ADK.InstallerUrl is the Microsoft fwlink' {
        $script:MC['ADK']['InstallerUrl'] |
            Should -Be 'https://go.microsoft.com/fwlink/?linkid=2271337'
    }

    It 'ADK installer URL is a go.microsoft.com fwlink' {
        $script:MC['ADK']['InstallerUrl'] | Should -Match '^https://go\.microsoft\.com/fwlink/\?linkid=\d+$'
    }
}

Describe 'TUI USMT pre-check (MigrationMerlin.ps1)' {
    # The TUI has not yet been migrated to USMTTools (its Find-USMT is a
    # lightweight pre-check with no install). Until that migration lands we
    # keep a minimal wiring check: function exists, it still knows about the
    # bundled zip, and it forwards a USMTPath into the worker scripts.
    It 'TUI defines Find-USMT and Show-USMTCheck' {
        $tuiContent | Should -Match 'function\s+Find-USMT'
        $tuiContent | Should -Match 'function\s+Show-USMTCheck'
    }

    It 'TUI references the bundled zip name' {
        $tuiContent | Should -Match 'user-state-migration-tool\.zip'
    }

    It 'TUI forwards -USMTPath when launching worker scripts' {
        $tuiContent | Should -Match '-USMTPath\s'
    }
}

Describe 'USMT binaries validation (live system)' -Tag 'Integration' {
    # End-to-end smoke check: when the ADK is installed on the test host,
    # verify the binaries are usable. Skips cleanly otherwise.
    BeforeAll {
        $adkUsmt = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        $script:UsmtDir = $null
        $candidates = @(
            (Join-Path $adkUsmt $Arch)
            (Join-Path $ScriptRoot "USMT-Tools\$Arch")
            "C:\USMT\$Arch"
        )
        foreach ($p in $candidates) {
            if (Test-Path (Join-Path $p 'scanstate.exe')) { $script:UsmtDir = $p; break }
        }
    }

    It 'scanstate.exe and loadstate.exe exist and are non-empty' {
        if (-not $script:UsmtDir) { Set-ItResult -Skipped -Because 'USMT not installed on this host' }
        foreach ($exe in 'scanstate.exe','loadstate.exe') {
            $path = Join-Path $script:UsmtDir $exe
            Test-Path $path | Should -BeTrue
            (Get-Item $path).Length | Should -BeGreaterThan 0
        }
    }

    It 'scanstate.exe /? returns recognizable help output' {
        if (-not $script:UsmtDir) { Set-ItResult -Skipped -Because 'USMT not installed on this host' }
        $exe = Join-Path $script:UsmtDir 'scanstate.exe'
        $output = & $exe /? 2>&1 | Out-String
        $output | Should -Match 'ScanState|usage|USMT'
    }
}
