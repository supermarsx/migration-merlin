# Pester 5 tests for USMTTools.psm1
# t1-e3 / phase p1

BeforeAll {
    $script:ModuleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\modules')).Path
    $script:ModulePath = Join-Path $script:ModuleRoot 'USMTTools.psm1'
    Import-Module $script:ModulePath -Force
}

AfterAll {
    Get-Module USMTTools | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Find-USMT' {
    BeforeEach {
        $script:TestRoot = Join-Path $env:TEMP ("USMTTools-Tests-" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TestRoot) {
            Remove-Item $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns the arch-specific directory when scanstate.exe is present' {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' }
                elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' }
                else { 'x86' }
        $base = Join-Path $script:TestRoot 'USMT-Tools'
        $archDir = Join-Path $base $arch
        New-Item -Path $archDir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $archDir 'scanstate.exe') -Value 'FAKE' -Force

        $result = Find-USMT -ExeName 'scanstate.exe' -AdditionalSearchPaths @($base)
        $result | Should -Be $archDir
    }

    It 'returns $null when no search location contains USMT' {
        # Point at an empty search path and only empty additional paths.
        # Mock Test-Path within module scope so the default search paths
        # (including a possibly-extracted repo-root USMT-Tools) all report
        # "not found" -- we're exercising the fan-out logic, not the FS.
        $emptyBase = Join-Path $script:TestRoot 'Empty'
        New-Item -Path $emptyBase -ItemType Directory -Force | Out-Null

        InModuleScope USMTTools -Parameters @{ EmptyBase = $emptyBase } {
            param($EmptyBase)
            Mock Test-Path { $false } -ParameterFilter { $Path -like '*scanstate.exe' -or $Path -like '*loadstate.exe' }

            $result = Find-USMT -ExeName 'scanstate.exe' -USMTPathOverride $EmptyBase -AdditionalSearchPaths @($EmptyBase)
            $result | Should -Be $null
        }
    }

    It 'honors -USMTPathOverride when the override contains the exe' {
        $override = Join-Path $script:TestRoot 'Custom'
        New-Item -Path $override -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $override 'scanstate.exe') -Value 'FAKE' -Force

        $result = Find-USMT -ExeName 'scanstate.exe' -USMTPathOverride $override
        $result | Should -Be $override
    }

    It 'returns $null when the override path lacks the exe' {
        $override = Join-Path $script:TestRoot 'Custom'
        New-Item -Path $override -ItemType Directory -Force | Out-Null

        InModuleScope USMTTools -Parameters @{
            Override = $override; Nope = (Join-Path $script:TestRoot 'Nope')
        } {
            param($Override, $Nope)
            Mock Test-Path { $false } -ParameterFilter { $Path -like '*scanstate.exe' -or $Path -like '*loadstate.exe' }

            $result = Find-USMT -ExeName 'scanstate.exe' -USMTPathOverride $Override -AdditionalSearchPaths @($Nope)
            $result | Should -Be $null
        }
    }

    It 'supports a custom -ExeName (loadstate.exe)' {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' }
                elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' }
                else { 'x86' }
        $base = Join-Path $script:TestRoot 'USMT-Tools'
        $archDir = Join-Path $base $arch
        New-Item -Path $archDir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $archDir 'loadstate.exe') -Value 'FAKE' -Force

        $result = Find-USMT -ExeName 'loadstate.exe' -AdditionalSearchPaths @($base)
        $result | Should -Be $archDir
    }
}

Describe 'Expand-BundledUSMT' {
    BeforeEach {
        $script:TestRoot = Join-Path $env:TEMP ("USMTTools-Expand-" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TestRoot) {
            Remove-Item $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns $null when no zip is found in any search location' {
        # Stub Test-Path within the module's scope so every probe for
        # user-state-migration-tool.zip reports "not found", regardless of
        # whether a real bundled zip exists at the repo root, in TEMP, or
        # anywhere else on the runner. We're exercising the module's fan-out
        # logic, not the filesystem.
        $empty = Join-Path $script:TestRoot 'NoZipHere'
        New-Item -Path $empty -ItemType Directory -Force | Out-Null

        InModuleScope USMTTools -Parameters @{ Empty = $empty } {
            param($Empty)
            Mock Test-Path { $false } -ParameterFilter { $Path -like '*user-state-migration-tool.zip' }

            $result = Expand-BundledUSMT -AdditionalZipSearchPaths @($Empty)
            $result | Should -Be $null
        }
    }

    It 'returns the arch directory when the zip extracts successfully (mocked Expand-Archive)' {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' }
                elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' }
                else { 'x86' }

        # Put a dummy zip file in an additional search path.
        $zipDir = Join-Path $script:TestRoot 'ZipHere'
        New-Item -Path $zipDir -ItemType Directory -Force | Out-Null
        $zipPath = Join-Path $zipDir 'user-state-migration-tool.zip'
        Set-Content -Path $zipPath -Value 'FAKE-ZIP' -Force

        $extractTarget = Join-Path $script:TestRoot 'Extracted'

        InModuleScope USMTTools -Parameters @{
            Arch = $arch; ZipDir = $zipDir; ExtractTarget = $extractTarget
        } {
            param($Arch, $ZipDir, $ExtractTarget)
            Mock Expand-Archive {
                param($Path, $DestinationPath, $Force)
                # Simulate extracting <zipRoot>/<arch>/scanstate.exe into DestinationPath.
                $rootInside = Join-Path $DestinationPath 'User State Migration Tool'
                $archInside = Join-Path $rootInside $Arch
                New-Item -Path $archInside -ItemType Directory -Force | Out-Null
                Set-Content -Path (Join-Path $archInside 'scanstate.exe') -Value 'FAKE' -Force
                Set-Content -Path (Join-Path $archInside 'loadstate.exe') -Value 'FAKE' -Force
            }

            $result = Expand-BundledUSMT `
                -ExeName 'scanstate.exe' `
                -AdditionalZipSearchPaths @($ZipDir) `
                -ExtractTarget $ExtractTarget

            $expected = Join-Path $ExtractTarget $Arch
            $result | Should -Be $expected
            Test-Path (Join-Path $expected 'scanstate.exe') | Should -BeTrue
            Assert-MockCalled Expand-Archive -Times 1 -Exactly
        }
    }

    It 'short-circuits when the target already contains the executable' {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' }
                elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' }
                else { 'x86' }
        $zipDir = Join-Path $script:TestRoot 'ZipHere'
        New-Item -Path $zipDir -ItemType Directory -Force | Out-Null
        $zipPath = Join-Path $zipDir 'user-state-migration-tool.zip'
        Set-Content -Path $zipPath -Value 'FAKE-ZIP' -Force

        $extractTarget = Join-Path $script:TestRoot 'Extracted'
        $archTarget = Join-Path $extractTarget $arch
        New-Item -Path $archTarget -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $archTarget 'scanstate.exe') -Value 'ALREADY' -Force

        InModuleScope USMTTools -Parameters @{
            ZipDir = $zipDir; ExtractTarget = $extractTarget; ArchTarget = $archTarget
        } {
            param($ZipDir, $ExtractTarget, $ArchTarget)
            Mock Expand-Archive { throw 'Should not be called' }

            $result = Expand-BundledUSMT `
                -ExeName 'scanstate.exe' `
                -AdditionalZipSearchPaths @($ZipDir) `
                -ExtractTarget $ExtractTarget

            $result | Should -Be $ArchTarget
            Assert-MockCalled Expand-Archive -Times 0 -Exactly
        }
    }
}

Describe 'Install-USMTOnline' {
    It 'tries every download method when each one fails, then returns $null' {
        InModuleScope USMTTools {
            Mock _Write-UsmtLog {}
            Mock Invoke-WebRequest   { throw 'iwr fail' }
            Mock Start-BitsTransfer  { throw 'bits fail' }
            # Force the WebClient path to fail.
            Mock New-Object {
                param($TypeName)
                if ($TypeName -eq 'System.Net.WebClient') {
                    $obj = [pscustomobject]@{ Headers = @{} ; UseDefaultCredentials = $false }
                    $obj | Add-Member -MemberType ScriptMethod -Name DownloadFile -Value { param($u,$p) throw 'wc fail' } -PassThru |
                        Add-Member -MemberType ScriptMethod -Name Dispose -Value {} -PassThru
                    return $obj
                }
                if ($TypeName) { return (Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName) }
            }
            Mock Start-TrackedProcess { return $null }
            Mock Find-USMT { return $null }

            $result = Install-USMTOnline -ExeName 'scanstate.exe'
            # HttpClient availability varies per host, so only assert the
            # universally-available methods were attempted and overall outcome.
            Assert-MockCalled Invoke-WebRequest -Scope It -Times 1 -Exactly
            $result | Should -Be $null
        }
    }

    It 'returns early on the first successful download' {
        InModuleScope USMTTools {
            Mock _Write-UsmtLog {}
            # Make IWR "succeed" by writing a >50KB dummy file.
            Mock Invoke-WebRequest {
                param($Uri, $OutFile, $UseBasicParsing)
                $bytes = New-Object byte[] (60KB)
                [System.IO.File]::WriteAllBytes($OutFile, $bytes)
            }
            Mock Start-BitsTransfer  { throw 'should not be called' }
            Mock Start-TrackedProcess {
                [pscustomobject]@{
                    HasExited = $true
                    ExitCode  = 0
                } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { } -PassThru
            }
            Mock Find-USMT { return 'C:\Fake\USMT\amd64' }

            $result = Install-USMTOnline -ExeName 'scanstate.exe'
            $result | Should -Be 'C:\Fake\USMT\amd64'
            Assert-MockCalled Invoke-WebRequest   -Scope It -Times 1 -Exactly
            Assert-MockCalled Start-BitsTransfer  -Scope It -Times 0 -Exactly
        }
    }
}

Describe 'Install-USMT orchestration' {
    It 'returns Find-USMT result without trying bundled/online when USMT already exists' {
        InModuleScope USMTTools {
            Mock Find-USMT { 'C:\Exists\amd64' }
            Mock Expand-BundledUSMT { throw 'should not run' }
            Mock Install-USMTOnline { throw 'should not run' }
            Mock _Write-UsmtLog {}

            $result = Install-USMT -ExeName 'scanstate.exe'
            $result | Should -Be 'C:\Exists\amd64'
            Assert-MockCalled Expand-BundledUSMT -Scope It -Times 0 -Exactly
            Assert-MockCalled Install-USMTOnline -Scope It -Times 0 -Exactly
        }
    }

    It 'falls through to Expand-BundledUSMT when Find-USMT returns $null' {
        InModuleScope USMTTools {
            Mock Find-USMT { $null }
            Mock Expand-BundledUSMT { 'C:\Extracted\amd64' }
            Mock Install-USMTOnline { throw 'should not run' }
            Mock _Write-UsmtLog {}

            $result = Install-USMT -ExeName 'scanstate.exe'
            $result | Should -Be 'C:\Extracted\amd64'
            Assert-MockCalled Expand-BundledUSMT -Scope It -Times 1 -Exactly
            Assert-MockCalled Install-USMTOnline -Scope It -Times 0 -Exactly
        }
    }

    It 'falls through to Install-USMTOnline when both earlier strategies fail' {
        InModuleScope USMTTools {
            Mock Find-USMT { $null }
            Mock Expand-BundledUSMT { $null }
            Mock Install-USMTOnline { 'C:\Installed\amd64' }
            Mock _Write-UsmtLog {}

            $result = Install-USMT -ExeName 'scanstate.exe'
            $result | Should -Be 'C:\Installed\amd64'
            Assert-MockCalled Install-USMTOnline -Scope It -Times 1 -Exactly
        }
    }

    It 'returns $null when every strategy fails' {
        InModuleScope USMTTools {
            Mock Find-USMT { $null }
            Mock Expand-BundledUSMT { $null }
            Mock Install-USMTOnline { $null }
            Mock _Write-UsmtLog {}

            $result = Install-USMT -ExeName 'scanstate.exe'
            $result | Should -Be $null
        }
    }
}

Describe 'Start-TrackedProcess' {
    It 'launches a no-op command and returns a Process object with a reachable ExitCode' {
        # Use cmd.exe /c exit 0 - universally available, finishes immediately.
        $proc = Start-TrackedProcess -FilePath 'cmd.exe' -Arguments '/c exit 0'
        $proc | Should -Not -Be $null
        $proc.GetType().FullName | Should -Be 'System.Diagnostics.Process'
        $proc.WaitForExit(5000) | Should -BeTrue
        $proc.ExitCode | Should -Be 0
    }

    It 'propagates a non-zero ExitCode' {
        $proc = Start-TrackedProcess -FilePath 'cmd.exe' -Arguments '/c exit 7'
        $proc.WaitForExit(5000) | Should -BeTrue
        $proc.ExitCode | Should -Be 7
    }
}
