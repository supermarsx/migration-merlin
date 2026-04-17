#Requires -Modules Pester
<#
.SYNOPSIS
    Comprehensive Pester tests for custom-migration.xml
.DESCRIPTION
    Validates the USMT custom migration XML structure, component definitions,
    include/exclude patterns, and schema conformance.
#>

BeforeAll {
    $XmlPath = "$PSScriptRoot\..\config\custom-migration.xml"
    [xml]$script:MigXml = Get-Content $XmlPath -Raw
    $script:ns = @{ m = "http://www.microsoft.com/migration/1.0/migxmlext/custom" }
}

# =============================================================================
# XML WELL-FORMEDNESS
# =============================================================================
Describe "XML well-formedness" {
    It "Should parse as valid XML" {
        { [xml](Get-Content $XmlPath -Raw) } | Should -Not -Throw
    }

    It "Should have a migration root element" {
        $script:MigXml.migration | Should -Not -BeNullOrEmpty
    }

    It "Should have correct urlid attribute" {
        $script:MigXml.migration.urlid | Should -Be "http://www.microsoft.com/migration/1.0/migxmlext/custom"
    }

    It "Should be UTF-8 encoded" {
        $declaration = (Get-Content $XmlPath -Raw) -match 'encoding="UTF-8"'
        $declaration | Should -BeTrue
    }
}

# =============================================================================
# COMPONENT COUNT
# =============================================================================
Describe "Component definitions" {
    It "Should have exactly 9 components" {
        $components = $script:MigXml.migration.component
        $components.Count | Should -Be 9
    }

    It "All components should have a displayName" {
        foreach ($comp in $script:MigXml.migration.component) {
            $comp.displayName | Should -Not -BeNullOrEmpty
        }
    }

    It "All components should have a type attribute" {
        foreach ($comp in $script:MigXml.migration.component) {
            $comp.type | Should -Not -BeNullOrEmpty
            $comp.type | Should -BeIn @("Application", "Documents", "System")
        }
    }

    It "All components should have context=User" {
        foreach ($comp in $script:MigXml.migration.component) {
            $comp.context | Should -Be "User"
        }
    }

    It "All components should have a role element with role=Data" {
        foreach ($comp in $script:MigXml.migration.component) {
            $comp.role.role | Should -Be "Data"
        }
    }

    It "All components should have rules with at least one include" {
        foreach ($comp in $script:MigXml.migration.component) {
            $comp.role.rules.include | Should -Not -BeNullOrEmpty
        }
    }
}

# =============================================================================
# CHROME COMPONENT
# =============================================================================
Describe "Google Chrome component" {
    BeforeAll {
        $script:chrome = $script:MigXml.migration.component |
            Where-Object { $_.displayName -eq "Google Chrome User Data" }
    }

    It "Should exist" {
        $script:chrome | Should -Not -BeNullOrEmpty
    }

    It "Should be type Application" {
        $script:chrome.type | Should -Be "Application"
    }

    It "Should include Bookmarks" {
        $patterns = $script:chrome.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "Bookmarks"
    }

    It "Should include Preferences" {
        $patterns = $script:chrome.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "Preferences"
    }

    It "Should include Login Data" {
        $patterns = $script:chrome.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "Login Data"
    }

    It "Should include Extensions" {
        $patterns = $script:chrome.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "Extensions"
    }

    It "Should reference CSIDL_LOCAL_APPDATA" {
        $patterns = $script:chrome.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "CSIDL_LOCAL_APPDATA"
    }
}

# =============================================================================
# EDGE COMPONENT
# =============================================================================
Describe "Microsoft Edge component" {
    BeforeAll {
        $script:edge = $script:MigXml.migration.component |
            Where-Object { $_.displayName -eq "Microsoft Edge User Data" }
    }

    It "Should exist" {
        $script:edge | Should -Not -BeNullOrEmpty
    }

    It "Should include Bookmarks" {
        $patterns = $script:edge.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "Bookmarks"
    }

    It "Should include Login Data" {
        $patterns = $script:edge.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "Login Data"
    }

    It "Should reference Edge User Data path" {
        $patterns = $script:edge.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "Microsoft\\Edge\\User Data"
    }
}

# =============================================================================
# FIREFOX COMPONENT
# =============================================================================
Describe "Firefox component" {
    BeforeAll {
        $script:firefox = $script:MigXml.migration.component |
            Where-Object { $_.displayName -eq "Firefox User Data" }
    }

    It "Should exist" {
        $script:firefox | Should -Not -BeNullOrEmpty
    }

    It "Should include places.sqlite (bookmarks/history)" {
        $patterns = $script:firefox.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "places\.sqlite"
    }

    It "Should include key4.db (encryption keys)" {
        $patterns = $script:firefox.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "key4\.db"
    }

    It "Should include logins.json" {
        $patterns = $script:firefox.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "logins\.json"
    }

    It "Should include profiles.ini" {
        $patterns = $script:firefox.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "profiles\.ini"
    }

    It "Should use CSIDL_APPDATA (roaming)" {
        $patterns = $script:firefox.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "CSIDL_APPDATA"
    }
}

# =============================================================================
# STICKY NOTES COMPONENT
# =============================================================================
Describe "Sticky Notes component" {
    BeforeAll {
        $script:sticky = $script:MigXml.migration.component |
            Where-Object { $_.displayName -eq "Sticky Notes Data" }
    }

    It "Should exist" {
        $script:sticky | Should -Not -BeNullOrEmpty
    }

    It "Should reference MicrosoftStickyNotes package path" {
        $patterns = $script:sticky.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "MicrosoftStickyNotes"
    }

    It "Should capture all files in LocalState" {
        $patterns = $script:sticky.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "LocalState"
    }
}

# =============================================================================
# OUTLOOK SIGNATURES COMPONENT
# =============================================================================
Describe "Outlook Signatures component" {
    BeforeAll {
        $script:outlook = $script:MigXml.migration.component |
            Where-Object { $_.displayName -eq "Outlook Signatures" }
    }

    It "Should exist" {
        $script:outlook | Should -Not -BeNullOrEmpty
    }

    It "Should include Signatures folder" {
        $patterns = $script:outlook.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "Microsoft\\Signatures"
    }

    It "Should include Stationery folder" {
        $patterns = $script:outlook.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "Microsoft\\Stationery"
    }

    It "Should include Outlook templates (.oft)" {
        $patterns = $script:outlook.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "\.oft"
    }
}

# =============================================================================
# EXTRA DOCUMENTS COMPONENT
# =============================================================================
Describe "Extra Document Folders component" {
    BeforeAll {
        $script:docs = $script:MigXml.migration.component |
            Where-Object { $_.displayName -eq "Extra Document Folders" }
    }

    It "Should exist" {
        $script:docs | Should -Not -BeNullOrEmpty
    }

    It "Should be type Documents" {
        $script:docs.type | Should -Be "Documents"
    }

    It "Should include Projects folder" {
        $patterns = $script:docs.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "\\Projects\\"
    }

    It "Should include Source folder" {
        $patterns = $script:docs.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "\\Source\\"
    }

    It "Should include Repos folder" {
        $patterns = $script:docs.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "\\Repos\\"
    }

    It "Should include Scripts folder" {
        $patterns = $script:docs.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "\\Scripts\\"
    }

    It "Should include Work folder" {
        $patterns = $script:docs.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "\\Work\\"
    }

    Context "Exclusions" {
        BeforeAll {
            $script:excludePatterns = $script:docs.role.rules.exclude.objectSet.pattern |
                ForEach-Object { $_.'#text' }
            $script:excludeJoined = $script:excludePatterns -join "`n"
        }

        It "Should exclude node_modules" {
            $script:excludeJoined | Should -Match "node_modules"
        }

        It "Should exclude bin directories" {
            $script:excludeJoined | Should -Match "\\bin\\"
        }

        It "Should exclude obj directories" {
            $script:excludeJoined | Should -Match "\\obj\\"
        }

        It "Should exclude .git directories" {
            $script:excludeJoined | Should -Match "\\\.git\\"
        }

        It "Should exclude packages directories" {
            $script:excludeJoined | Should -Match "\\packages\\"
        }

        It "Should have exactly 5 exclude patterns" {
            $script:excludePatterns.Count | Should -Be 5
        }
    }
}

# =============================================================================
# TERMINAL/SHELL PROFILES COMPONENT
# =============================================================================
Describe "Terminal and Shell Profiles component" {
    BeforeAll {
        $script:terminal = $script:MigXml.migration.component |
            Where-Object { $_.displayName -eq "Terminal and Shell Profiles" }
        $script:termPatterns = $script:terminal.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        $script:termJoined = $script:termPatterns -join "`n"
    }

    It "Should exist" {
        $script:terminal | Should -Not -BeNullOrEmpty
    }

    It "Should include Windows Terminal settings.json" {
        $script:termJoined | Should -Match "WindowsTerminal.*settings\.json"
    }

    It "Should include PowerShell profiles" {
        $script:termJoined | Should -Match "PowerShell.*Profile"
    }

    It "Should include WindowsPowerShell profiles" {
        $script:termJoined | Should -Match "WindowsPowerShell"
    }

    It "Should include SSH config" {
        $script:termJoined | Should -Match "\.ssh.*config"
    }

    It "Should include SSH known_hosts" {
        $script:termJoined | Should -Match "\.ssh.*known_hosts"
    }

    It "Should include .gitconfig" {
        $script:termJoined | Should -Match "\.gitconfig"
    }

    It "Should include .gitignore_global" {
        $script:termJoined | Should -Match "\.gitignore_global"
    }
}

# =============================================================================
# VSCODE COMPONENT
# =============================================================================
Describe "Visual Studio Code component" {
    BeforeAll {
        $script:vscode = $script:MigXml.migration.component |
            Where-Object { $_.displayName -eq "Visual Studio Code Settings" }
        $script:vsPatterns = $script:vscode.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        $script:vsJoined = $script:vsPatterns -join "`n"
    }

    It "Should exist" {
        $script:vscode | Should -Not -BeNullOrEmpty
    }

    It "Should include settings.json" {
        $script:vsJoined | Should -Match "Code\\User.*settings\.json"
    }

    It "Should include keybindings.json" {
        $script:vsJoined | Should -Match "Code\\User.*keybindings\.json"
    }

    It "Should include snippets" {
        $script:vsJoined | Should -Match "Code\\User\\snippets"
    }

    It "Should include extensions" {
        $script:vsJoined | Should -Match "\.vscode\\extensions"
    }
}

# =============================================================================
# QUICK ACCESS COMPONENT
# =============================================================================
Describe "Quick Access component" {
    BeforeAll {
        $script:quickAccess = $script:MigXml.migration.component |
            Where-Object { $_.displayName -eq "Quick Access and Recent Files" }
    }

    It "Should exist" {
        $script:quickAccess | Should -Not -BeNullOrEmpty
    }

    It "Should be type System" {
        $script:quickAccess.type | Should -Be "System"
    }

    It "Should include AutomaticDestinations" {
        $patterns = $script:quickAccess.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "AutomaticDestinations"
    }

    It "Should include CustomDestinations" {
        $patterns = $script:quickAccess.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }
        ($patterns -join "`n") | Should -Match "CustomDestinations"
    }
}

# =============================================================================
# PATTERN FORMAT VALIDATION
# =============================================================================
Describe "Pattern format validation" {
    It "All patterns should have a type attribute" {
        $allPatterns = $script:MigXml.SelectNodes("//pattern")
        foreach ($p in $allPatterns) {
            $p.type | Should -Be "File"
        }
    }

    It "All patterns should use CSIDL variables or known prefixes" {
        $allPatterns = $script:MigXml.SelectNodes("//pattern")
        foreach ($p in $allPatterns) {
            $text = $p.'#text'
            $text | Should -Match '^%CSIDL_'
        }
    }

    It "All include patterns should have file specification in brackets" {
        $includePatterns = $script:MigXml.SelectNodes("//include//pattern")
        foreach ($p in $includePatterns) {
            $text = $p.'#text'
            $text | Should -Match '\[.+\]$'
        }
    }

    It "All exclude patterns should have file specification in brackets" {
        $excludePatterns = $script:MigXml.SelectNodes("//exclude//pattern")
        foreach ($p in $excludePatterns) {
            $text = $p.'#text'
            $text | Should -Match '\[.+\]$'
        }
    }
}

# =============================================================================
# CROSS-COMPONENT VALIDATION
# =============================================================================
Describe "Cross-component consistency" {
    It "Should have unique displayNames for all components" {
        $names = $script:MigXml.migration.component | ForEach-Object { $_.displayName }
        $uniqueNames = $names | Select-Object -Unique
        $names.Count | Should -Be $uniqueNames.Count
    }

    It "Application components should use CSIDL_APPDATA or CSIDL_LOCAL_APPDATA" {
        $appComponents = $script:MigXml.migration.component |
            Where-Object { $_.type -eq "Application" }
        foreach ($comp in $appComponents) {
            $allText = ($comp.role.rules.include.objectSet.pattern |
                ForEach-Object { $_.'#text' }) -join "`n"
            $allText | Should -Match "CSIDL_(LOCAL_)?APPDATA|CSIDL_PROFILE|CSIDL_MYDOCUMENTS"
        }
    }

    It "Documents component should use CSIDL_PROFILE" {
        $docsComp = $script:MigXml.migration.component |
            Where-Object { $_.type -eq "Documents" }
        $allText = ($docsComp.role.rules.include.objectSet.pattern |
            ForEach-Object { $_.'#text' }) -join "`n"
        $allText | Should -Match "CSIDL_PROFILE"
    }

    It "Only Documents component should have exclude rules" {
        foreach ($comp in $script:MigXml.migration.component) {
            if ($comp.displayName -ne "Extra Document Folders") {
                $comp.role.rules.exclude | Should -BeNullOrEmpty
            }
        }
    }
}
