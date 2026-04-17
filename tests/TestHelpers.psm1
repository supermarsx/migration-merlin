# Shared mock factories and helpers for migrationmerlin Pester tests.
# Import with:  Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force

function New-MockAdminIdentity {
    <# Returns objects that make the admin-role check pass. #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity
}

function Get-TestMigrationFolder {
    $base = Join-Path $env:TEMP "MigWiz-Tests-$(Get-Random)"
    New-Item -Path $base -ItemType Directory -Force | Out-Null
    # Pre-create subfolders the scripts expect
    foreach ($sub in @("USMT","Logs","Backup","PreScanData")) {
        New-Item -Path (Join-Path $base $sub) -ItemType Directory -Force | Out-Null
    }
    return $base
}

function Remove-TestMigrationFolder {
    param([string]$Path)
    if ($Path -and (Test-Path $Path)) {
        Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-FakeUSMTDir {
    <# Creates a temp dir with fake scanstate.exe and loadstate.exe plus XML files. #>
    param([string]$BasePath)
    $usmtDir = Join-Path $BasePath "USMT-Tools\amd64"
    New-Item -Path $usmtDir -ItemType Directory -Force | Out-Null
    foreach ($exe in @("scanstate.exe","loadstate.exe")) {
        $p = Join-Path $usmtDir $exe
        # Create a tiny PE-like stub with version info
        Set-Content -Path $p -Value "FAKE_EXE" -Force
    }
    foreach ($xml in @("MigDocs.xml","MigApp.xml")) {
        Set-Content -Path (Join-Path $usmtDir $xml) -Value "<xml/>" -Force
    }
    return $usmtDir
}

function New-FakeMigStore {
    <# Creates fake .mig files in a USMT store folder. #>
    param([string]$StorePath, [int]$FileCount = 3, [int]$FileSizeKB = 100)
    $usmtPath = Join-Path $StorePath "USMT"
    if (-not (Test-Path $usmtPath)) {
        New-Item -Path $usmtPath -ItemType Directory -Force | Out-Null
    }
    for ($i = 1; $i -le $FileCount; $i++) {
        $file = Join-Path $usmtPath "store$i.mig"
        $bytes = New-Object byte[] ($FileSizeKB * 1024)
        [System.IO.File]::WriteAllBytes($file, $bytes)
    }
}

function New-FakePreScanData {
    <# Populates PreScanData with sample CSV/JSON files. #>
    param([string]$MigrationFolder)
    $dir = Join-Path $MigrationFolder "PreScanData"
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    # InstalledApps.csv
    @(
        [PSCustomObject]@{DisplayName="App One";DisplayVersion="1.0";Publisher="Pub1";InstallDate="20240101"}
        [PSCustomObject]@{DisplayName="App Two";DisplayVersion="2.0";Publisher="Pub2";InstallDate="20240201"}
        [PSCustomObject]@{DisplayName="Missing App";DisplayVersion="3.0";Publisher="Pub3";InstallDate="20240301"}
    ) | Export-Csv (Join-Path $dir "InstalledApps.csv") -NoTypeInformation

    # Printers.csv
    @(
        [PSCustomObject]@{Name="HP LaserJet";DriverName="HP Universal";PortName="USB001";Shared="False";PrinterStatus="Normal"}
        [PSCustomObject]@{Name="Network Copier";DriverName="Ricoh";PortName="\\print\copier";Shared="True";PrinterStatus="Normal"}
    ) | Export-Csv (Join-Path $dir "Printers.csv") -NoTypeInformation

    # MappedDrives.csv
    @(
        [PSCustomObject]@{Name="S";DisplayRoot="\\fileserver\shared"}
    ) | Export-Csv (Join-Path $dir "MappedDrives.csv") -NoTypeInformation

    # WiFiProfiles.txt
    @(
        "Profiles on interface Wi-Fi:",
        "    All User Profile     : CorpWiFi",
        "    All User Profile     : GuestNet"
    ) | Out-File (Join-Path $dir "WiFiProfiles.txt") -Encoding UTF8

    # BrowserBookmarks.txt
    @("testuser : Chrome", "testuser : Edge") |
        Out-File (Join-Path $dir "BrowserBookmarks.txt") -Encoding UTF8

    # SystemInfo.json
    @{
        ComputerName = "SOURCE-PC"
        Domain       = "WORKGROUP"
        OSVersion    = "Microsoft Windows 11 Pro"
        OSBuild      = "22631"
        Architecture = "AMD64"
        TotalRAM_GB  = 16
        CaptureDate  = "2025-03-15 10:30:00"
        CaptureUser  = "WORKGROUP\testuser"
    } | ConvertTo-Json | Out-File (Join-Path $dir "SystemInfo.json") -Encoding UTF8
}

function New-FakeCaptureCompleteFlag {
    param([string]$MigrationFolder)
    @{
        SourceComputer = "SOURCE-PC"
        SourceDomain   = "WORKGROUP"
        CaptureTime    = "2025-03-15 10:45:00"
        USMTVersion    = "10.1.22621.1"
    } | ConvertTo-Json | Out-File (Join-Path $MigrationFolder "capture-complete.flag") -Encoding UTF8
}

# CIM mock objects
function New-MockOS {
    [PSCustomObject]@{
        Caption     = "Microsoft Windows 11 Pro"
        BuildNumber = "22631"
    }
}

function New-MockDisk {
    param([long]$FreeGB = 100, [long]$TotalGB = 500)
    [PSCustomObject]@{
        DeviceID  = "C:"
        FreeSpace = $FreeGB * 1GB
        Size      = $TotalGB * 1GB
    }
}

function New-MockNetAdapter {
    param([string]$Status = "Up", [string]$Name = "Ethernet")
    [PSCustomObject]@{
        Name            = $Name
        Status          = $Status
        InterfaceDescription = "Mock Adapter"
    }
}

function New-MockIPAddress {
    param([string]$IP = "192.168.1.100")
    [PSCustomObject]@{
        IPAddress    = $IP
        PrefixOrigin = "Dhcp"
    }
}

function New-MockUserProfile {
    param([string]$Username, [string]$BasePath = "C:\Users", [bool]$Special = $false)
    [PSCustomObject]@{
        LocalPath   = Join-Path $BasePath $Username
        Special     = $Special
        SID         = "S-1-5-21-$(Get-Random)"
        LastUseTime = (Get-Date).AddDays(-1)
    }
}

function New-MockPrinter {
    param([string]$Name, [string]$Driver = "Generic Driver")
    [PSCustomObject]@{
        Name          = $Name
        DriverName    = $Driver
        PortName      = "USB001"
        Shared        = $false
        PrinterStatus = "Normal"
    }
}

function New-MockInstalledApp {
    param([string]$Name, [string]$Version = "1.0")
    [PSCustomObject]@{
        DisplayName    = $Name
        DisplayVersion = $Version
        Publisher      = "TestPub"
        InstallDate    = "20240101"
    }
}

function New-MockComputerSystem {
    [PSCustomObject]@{
        Domain              = "WORKGROUP"
        TotalPhysicalMemory = 16GB
    }
}

Export-ModuleMember -Function *
