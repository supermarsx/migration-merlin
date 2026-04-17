<#
.SYNOPSIS
    Migration Merlin - Unified interactive TUI for USMT PC-to-PC migration.

.DESCRIPTION
    Single-file entry point that wraps destination-setup.ps1, source-capture.ps1,
    and post-migration-verify.ps1 behind an arrow-key navigable text UI.
    Features animated banner, interactive configuration panels, spinners,
    real-time progress bars, and persisted configuration in
    %LOCALAPPDATA%\MigrationMerlin\config.json. Auto-elevates to Administrator
    via UAC on launch and keeps the console awake (prevents display sleep) for
    the duration of a long-running capture or restore. This is the recommended
    launch surface for interactive use; the underlying scripts remain available
    for scripted / unattended deployments.

.EXAMPLE
    PS> .\Migration-Merlin.ps1

    Launches the TUI with defaults. The menu walks the user through setup,
    capture, restore, verification, and cleanup in sequence.

.EXAMPLE
    PS> .\Migration-Merlin.bat

    Double-click wrapper that launches the TUI via PowerShell with the
    correct execution policy. Equivalent to the direct .ps1 invocation.

.EXAMPLE
    PS> .\Migration-Merlin.ps1
    (Once inside the TUI, pick "Load Configuration" to restore a previously
     saved run configuration from %LOCALAPPDATA%\MigrationMerlin\config.json.)

    Launches the TUI and resumes from a saved configuration.

.INPUTS
    None. Input is collected interactively through the TUI.

.OUTPUTS
    None. Exit code 0 indicates a clean exit. Logs from individual phases are
    written under the migration folder's Logs subdirectory.

.NOTES
    - Requires Windows PowerShell 5.1 or later.
    - Requires Administrator privileges (auto-elevates via UAC).
    - Minimum console width 64 columns; the script attempts to widen to 80.
    - Uses VT100 / ANSI escape sequences; Windows 10 1511+ or Windows Terminal
      recommended.
    - Prevents system and display sleep while running via
      SetThreadExecutionState.

.LINK
    https://github.com/supermarsx/migration-merlin

.LINK
    .\scripts\destination-setup.ps1

.LINK
    .\scripts\source-capture.ps1

.LINK
    .\scripts\post-migration-verify.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ════════════════════════════════════════════════════════════════
#  MODULE IMPORTS
# ════════════════════════════════════════════════════════════════
# Phase 1 shared modules. Imported here so Request-Elevation can marshal
# $PSBoundParameters across UAC and Format-SafeParams can scrub param logs.
# MigrationUI is imported for completeness; the TUI keeps its own ANSI
# helpers because their colour/format contract differs from the module's
# (see note in the HELPERS section below).
Import-Module "$PSScriptRoot\modules\MigrationConstants.psm1" -Force -ErrorAction SilentlyContinue
Import-Module "$PSScriptRoot\modules\MigrationUI.psm1" -Force -ErrorAction SilentlyContinue
# Phase 3 / t1-e12: shared validators exposed in the TUI's scope so future
# interactive input handling can reuse Test-UncPath / Test-ProfileName etc.
Import-Module "$PSScriptRoot\modules\MigrationValidators.psm1" -Force -ErrorAction SilentlyContinue
. "$PSScriptRoot\modules\Invoke-Elevated.ps1"
. "$PSScriptRoot\modules\MigrationLogging.ps1"

# ════════════════════════════════════════════════════════════════
#  BOOTSTRAP
# ════════════════════════════════════════════════════════════════

# Enable VT100 / ANSI sequences + keep-awake via kernel32
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MwKernel {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
    // ES_CONTINUOUS=0x80000000  ES_SYSTEM_REQUIRED=0x1  ES_DISPLAY_REQUIRED=0x2
    public static void KeepAwake()  { SetThreadExecutionState(0x80000003); }
    public static void AllowSleep() { SetThreadExecutionState(0x80000000); }
}
"@ -ErrorAction SilentlyContinue
    # Enable VT100
    $h = [MwKernel]::GetStdHandle(-11); $m = 0
    [void][MwKernel]::GetConsoleMode($h, [ref]$m)
    [void][MwKernel]::SetConsoleMode($h, $m -bor 4)
    # Prevent sleep + screen off while TUI is running
    [MwKernel]::KeepAwake()
} catch {}

# Auto-elevate (marshals $PSBoundParameters across UAC via Invoke-Elevated helper).
Request-Elevation -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# Handle UNC paths — PS 5.1 can't Set-Location to \\server\share
$script:ScriptRoot = $PSScriptRoot
$script:ScriptsDir = Join-Path $PSScriptRoot 'scripts'
$script:IsUNC = $PSScriptRoot -match '^\\\\'
if (-not $script:IsUNC) {
    Set-Location $PSScriptRoot
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'Migration Merlin'

# Minimum terminal size
if ([Console]::WindowWidth -lt 64) {
    try { [Console]::WindowWidth = 80 } catch {}
}

# ════════════════════════════════════════════════════════════════
#  ANSI CONSTANTS
# ════════════════════════════════════════════════════════════════

$E          = [char]0x1B
$RST        = "$E[0m"
$BLD        = "$E[1m"
$cR         = "$E[91m"   # red
$cG         = "$E[92m"   # green
$cY         = "$E[93m"   # yellow
$cB         = "$E[94m"   # blue
$cM         = "$E[95m"   # magenta
$cC         = "$E[96m"   # cyan
$cW         = "$E[97m"   # white
$cGR        = "$E[90m"   # gray

# Spinner frames. Prefer $MigrationConstants.UI.SpinnerFrames (same braille
# sequence, centralized in Phase 1). Fall back to the original literal array
# if MigrationConstants isn't loaded for any reason.
if ($MigrationConstants -and $MigrationConstants.UI -and $MigrationConstants.UI.SpinnerFrames) {
    $Spin = $MigrationConstants.UI.SpinnerFrames
} else {
    $Spin = @([char]0x280B,[char]0x2819,[char]0x2839,[char]0x2838,
              [char]0x283C,[char]0x2834,[char]0x2826,[char]0x2827,
              [char]0x2807,[char]0x280F)
}

# ════════════════════════════════════════════════════════════════
#  STATE
# ════════════════════════════════════════════════════════════════

$script:Sel = 0
$script:Done = @{}                        # Action -> $true
$script:Items = @(
    [pscustomobject]@{ Key='1'; Label='Setup Destination'; Tag='DEST';
        Desc='Install USMT, create hidden network share (MigrationShare$), open firewall ports. Run on the NEW PC first.'; Action='Setup' }
    [pscustomobject]@{ Key='2'; Label='Capture Source'; Tag='SRC';
        Desc='Scan user profiles, files & settings on the OLD PC and transfer to the destination share.'; Action='Capture' }
    [pscustomobject]@{ Key='3'; Label='Restore Data'; Tag='DEST';
        Desc='Apply captured user state on the NEW PC via USMT LoadState. Steps 1 & 2 must be complete.'; Action='Restore' }
    [pscustomobject]@{ Key='4'; Label='Verify Migration'; Tag='DEST';
        Desc='Compare pre-migration inventory with current state. Shows what migrated and what needs attention.'; Action='Verify' }
    [pscustomobject]@{ Key='5'; Label='Cleanup'; Tag='DEST';
        Desc='Remove network share, firewall rules, and temporary migration data from the NEW PC.'; Action='Cleanup' }
)
$script:TotalChoices = $script:Items.Count + 1   # +1 for Quit

# ════════════════════════════════════════════════════════════════
#  HELPERS
# ════════════════════════════════════════════════════════════════

function Rep([string]$c,[int]$n){ if($n -le 0){''}else{$c * $n} }
function Strip([string]$t){ $t -replace '\x1B\[[0-9;]*m','' }
function PadR([string]$t,[int]$w){ $p=[Math]::Max(0,$w-(Strip $t).Length); "$t$(Rep ' ' $p)" }
function PadC([string]$t,[int]$w){
    $vis=(Strip $t).Length; $gap=[Math]::Max(0,$w-$vis)
    $l=[Math]::Floor($gap/2); $r=$gap-$l
    "$(Rep ' ' $l)$t$(Rep ' ' $r)"
}
function HideCur { [Console]::Write("$E[?25l") }
function ShowCur { [Console]::Write("$E[?25h") }
function FlushKeys { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } }
function WaitKey  { FlushKeys; return [Console]::ReadKey($true) }

# ════════════════════════════════════════════════════════════════
#  CONFIG SAVE / LOAD / RESUME
# ════════════════════════════════════════════════════════════════

$script:ConfigDir = Join-Path $script:ScriptRoot '.mw-configs'

function Save-RunConfig([string]$Step, [hashtable]$Config) {
    <# Save step config to JSON so the user can resume or re-use it. #>
    if (-not (Test-Path $script:ConfigDir)) { New-Item $script:ConfigDir -ItemType Directory -Force | Out-Null }
    $file = Join-Path $script:ConfigDir "$Step.json"
    $Config['_saved'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $Config | ConvertTo-Json -Depth 10 | Set-Content $file -Encoding UTF8
    Write-Host "    ${cG}$([char]0x2713)${RST} ${cGR}Config saved to $file${RST}"
}

function Load-RunConfig([string]$Step) {
    <# Load saved config. Returns $null if none exists. #>
    $file = Join-Path $script:ConfigDir "$Step.json"
    if (-not (Test-Path $file)) { return $null }
    try {
        $json = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        return $json
    } catch { return $null }
}

function Show-ConfigPrompt([string]$Step) {
    <# If a saved config exists, offer to load it. Returns loaded config or $null. #>
    $saved = Load-RunConfig $Step
    if (-not $saved) { return $null }
    Write-Host ""
    Write-Host "    ${cC}$([char]0x25B8)${RST} ${cW}Saved config found${RST} ${cGR}($($saved._saved))${RST}"
    Write-Host "    ${cC}L${RST} ${cW}Load saved config${RST}  ${cC}N${RST} ${cW}Start fresh${RST}"
    Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
    ShowCur; FlushKeys
    $k = [Console]::ReadKey($true); HideCur
    switch ($k.KeyChar) {
        'l' { Write-Host 'Load'; return $saved }
        default { Write-Host 'Fresh'; return $null }
    }
}

# ════════════════════════════════════════════════════════════════
#  SHARE DISCOVERY & VALIDATION
# ════════════════════════════════════════════════════════════════

function Find-MigrationShares {
    <# Scan ARP table for hosts with MigrationShare$. Fast — no broadcast scan. #>
    $found = [System.Collections.Generic.List[pscustomobject]]::new()

    # Parse ARP table for dynamic entries
    $arpLines = arp -a 2>$null
    $candidates = @()
    foreach ($line in $arpLines) {
        if ($line -match '^\s+(\d+\.\d+\.\d+\.\d+)\s+[0-9a-f-]+\s+dynamic') {
            $candidates += $Matches[1]
        }
    }
    # Add default gateway
    try {
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Select-Object -First 1).NextHop
        if ($gw -and $gw -ne '0.0.0.0') { $candidates += $gw }
    } catch {}

    $candidates = $candidates |
        Where-Object { $_ -notmatch '\.(255|0)$' -and $_ -ne '255.255.255.255' } |
        Select-Object -Unique

    $myIPs = @()
    try { $myIPs = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress } catch {}

    foreach ($ip in $candidates) {
        if ($ip -in $myIPs) { continue }

        # Quick SMB port check (500 ms timeout)
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $tcp.BeginConnect($ip, 445, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                $tcp.EndConnect($ar)
                if (Test-Path "\\$ip\MigrationShare`$" -ErrorAction SilentlyContinue) {
                    $name = $ip
                    try { $name = ([System.Net.Dns]::GetHostEntry($ip)).HostName.Split('.')[0] } catch {}
                    $found.Add([pscustomobject]@{ IP = $ip; Name = $name; Path = "\\$ip\MigrationShare`$" })
                }
            }
        } catch {} finally { $tcp.Dispose() }
    }
    return ,$found.ToArray()
}

function Test-ShareAccess([string]$Path) {
    <# Returns a PSCustomObject: .OK  .Detail #>
    if ($Path -notmatch '^\\\\[^\\]+\\[^\\]+') {
        return [pscustomobject]@{ OK = $false; Detail = 'Invalid UNC format (expected \\HOST\Share)' }
    }
    $hostPart = ($Path -split '\\' | Where-Object { $_ })[0]

    # Test-Path can be slow on unreachable hosts — pre-check with TCP 445
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $tcp.BeginConnect($hostPart, 445, $null, $null)
        if (-not ($ar.AsyncWaitHandle.WaitOne(2000) -and $tcp.Connected)) {
            return [pscustomobject]@{ OK = $false; Detail = "Host $hostPart is not reachable (port 445 timeout)" }
        }
        $tcp.EndConnect($ar)
    } catch {
        return [pscustomobject]@{ OK = $false; Detail = "Host $hostPart is not reachable" }
    } finally { $tcp.Dispose() }

    if (Test-Path $Path -ErrorAction SilentlyContinue) {
        return [pscustomobject]@{ OK = $true; Detail = 'Share accessible' }
    }
    return [pscustomobject]@{ OK = $false; Detail = "Host reachable but share not found or access denied" }
}

function Show-SharePicker {
    <# Let the user scan or type a share, then validate it. Returns the UNC path. #>
    Write-Host ""
    Write-Host "    ${BLD}${cW}Destination Share${RST}"
    Write-Host "    ${cGR}$(Rep ([char]0x2500) 40)${RST}"
    Write-Host "    ${cC}S${RST}  ${cW}Scan network${RST} for MigrationShare`$"
    Write-Host "    ${cC}M${RST}  ${cW}Enter path manually${RST}"
    Write-Host ""
    Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
    ShowCur

    $choice = $null
    FlushKeys
    while ($null -eq $choice) {
        $k = [Console]::ReadKey($true)
        switch -regex ("$($k.KeyChar)") {
            '[sS]'  { Write-Host 'Scan'; HideCur; $choice = 'scan' }
            '[mM]'  { Write-Host 'Manual'; HideCur; $choice = 'manual' }
            default  {
                if ($k.Key -eq 'Enter') { Write-Host 'Scan'; HideCur; $choice = 'scan' }
            }
        }
    }

    $sharePath = $null

    if ($choice -eq 'scan') {
        Write-Host ""
        # Animated scan
        $scanDone = $false; $frame = 0
        Write-Host "    " -NoNewline
        $shares = $null

        # Run scan — show spinner between ARP parse and host checks
        Write-Host "`r    ${cC}$($Spin[0])${RST} ${cGR}Reading ARP table...${RST}" -NoNewline
        $shares = Find-MigrationShares
        Write-Host "`r    ${cG}$([char]0x2713)${RST} ${cW}Scan complete${RST}                        "

        if ($shares.Count -eq 0) {
            Write-Host ""
            Write-Host "    ${cY}$([char]0x26A0)${RST}  ${cY}No MigrationShare`$ found on the network.${RST}"
            Write-Host "    ${cGR}Make sure Step 1 was run on the destination PC first.${RST}"
            Write-Host ""
            $sharePath = Prompt-Text 'Enter share path manually' -Example '\\NEWPC\MigrationShare$' -Required
        } else {
            Write-Host ""
            Write-Host "    ${BLD}${cW}Found $($shares.Count) share$(if($shares.Count -gt 1){'s'}):${RST}"
            for ($i = 0; $i -lt $shares.Count; $i++) {
                $sh = $shares[$i]
                $display = $sh.Path
                if ($sh.Name -ne $sh.IP) { $display += "  ${cGR}($($sh.Name))${RST}" }
                Write-Host "    ${cC}$($i + 1)${RST}  ${cW}$display${RST}"
            }
            Write-Host "    ${cC}M${RST}  ${cGR}Enter manually instead${RST}"
            Write-Host ""
            Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
            ShowCur

            $picked = $false
            FlushKeys
            while (-not $picked) {
                $k = [Console]::ReadKey($true)
                if ($k.KeyChar -eq 'm' -or $k.KeyChar -eq 'M') {
                    Write-Host 'Manual'; HideCur
                    $sharePath = Prompt-Text 'Enter share path' -Example '\\NEWPC\MigrationShare$' -Required
                    $picked = $true
                } else {
                    $numVal = 0
                    if ([int]::TryParse("$($k.KeyChar)", [ref]$numVal) -and $numVal -ge 1 -and $numVal -le $shares.Count) {
                        $sharePath = $shares[$numVal - 1].Path
                        Write-Host $sharePath; HideCur
                        $picked = $true
                    }
                }
            }
        }
    } else {
        $sharePath = Prompt-Text 'Destination share path' -Example '\\NEWPC\MigrationShare$' -Required
    }

    # Validate the selected share
    Write-Host ""
    for ($f = 0; $f -lt 8; $f++) {
        [Console]::Write("`r    ${cC}$($Spin[$f % $Spin.Count])${RST} ${cGR}Validating share...${RST}   ")
        Start-Sleep -Milliseconds 60
    }
    $result = Test-ShareAccess $sharePath
    if ($result.OK) {
        Write-Host "`r    ${cG}$([char]0x2713)${RST} ${cW}$($result.Detail)${RST}                      "
    } else {
        Write-Host "`r    ${cR}$([char]0x2717)${RST} ${cR}$($result.Detail)${RST}                      "
        if (-not (Prompt-Confirm 'Continue anyway?')) {
            return Show-SharePicker   # retry
        }
    }

    return $sharePath
}

# ════════════════════════════════════════════════════════════════
#  SCREEN BUILDER  (single-buffer → no flicker)
# ════════════════════════════════════════════════════════════════

function Build-MainScreen {
    $W = 62; $IW = $W - 2
    $b = [System.Text.StringBuilder]::new(4096)

    # clear + home
    [void]$b.Append("$E[2J$E[H`n")

    # ── banner ──
    [void]$b.AppendLine("  ${cC}$(Rep ([char]0x2550) $IW)${RST}")
    [void]$b.AppendLine("  $(PadC "${BLD}${cY}$([char]0x26A1)${RST}  ${BLD}${cW}M I G R A T I O N   W I Z A R D R Y${RST}  ${BLD}${cY}$([char]0x26A1)${RST}" $IW)")
    [void]$b.AppendLine("  $(PadC "${cGR}USMT  PC-to-PC  User State Migration${RST}" $IW)")
    [void]$b.AppendLine("  ${cC}$(Rep ([char]0x2550) $IW)${RST}")
    [void]$b.AppendLine()

    # ── menu items ──
    for ($i = 0; $i -lt $script:Items.Count; $i++) {
        $it = $script:Items[$i]
        $isSel = ($i -eq $script:Sel)
        $isDone = $script:Done.ContainsKey($it.Action)

        $arrow  = if($isSel){ "${cC}$([char]0x25B8)${RST}" } else { ' ' }
        $marker = if($isDone){ "${cG}$([char]0x2713)${RST}" } else { "${cGR}$([char]0x25CB)${RST}" }
        $num    = "${cGR}$($it.Key).${RST}"
        $lbl    = if($isSel){ "${BLD}${cW}$($it.Label)${RST}" } else { "${cW}$($it.Label)${RST}" }
        $tag    = "${cGR}[$($it.Tag)]${RST}"

        $left   = "  $arrow $marker $num $lbl"
        $visL   = (Strip $left).Length
        $gap    = [Math]::Max(1, 55 - $visL)
        [void]$b.AppendLine("$left$(Rep ' ' $gap)$tag")

        if ($i -eq 1) { [void]$b.AppendLine() }   # visual break after Capture
    }

    # ── quit ──
    [void]$b.AppendLine("  ${cGR}$(Rep ([char]0x2500) 56)${RST}")
    $qSel = ($script:Sel -eq $script:Items.Count)
    if ($qSel) {
        [void]$b.AppendLine("  ${cC}$([char]0x25B8)${RST}   ${BLD}${cW}Q. Quit${RST}")
    } else {
        [void]$b.AppendLine("      ${cGR}Q.${RST} ${cW}Quit${RST}")
    }

    # ── description panel ──
    [void]$b.AppendLine()
    if ($script:Sel -lt $script:Items.Count) {
        $desc = $script:Items[$script:Sel].Desc
        $mw = 54
        $words = $desc -split ' '; $lines = @(); $cur = ''
        foreach ($wd in $words) {
            if (($cur.Length + $wd.Length + 1) -gt $mw) { $lines += $cur; $cur = $wd }
            else { $cur = if($cur){"$cur $wd"}else{$wd} }
        }
        if ($cur) { $lines += $cur }

        [void]$b.AppendLine("  ${cC}$([char]0x250C)$(Rep ([char]0x2500) 56)$([char]0x2510)${RST}")
        foreach ($ln in $lines) {
            [void]$b.AppendLine("  ${cC}$([char]0x2502)${RST} $(PadR "${cGR}$ln${RST}" 55)${cC}$([char]0x2502)${RST}")
        }
        [void]$b.AppendLine("  ${cC}$([char]0x2514)$(Rep ([char]0x2500) 56)$([char]0x2518)${RST}")
    }

    # ── status bar ──
    [void]$b.AppendLine()
    [void]$b.Append("  ${cGR}$([char]0x2191)$([char]0x2193)${RST} ${cW}Navigate${RST}  ${cGR}$([char]0x00B7)${RST}  ${cGR}Enter${RST} ${cW}Select${RST}  ${cGR}$([char]0x00B7)${RST}  ${cGR}Q${RST} ${cW}Quit${RST}")

    return $b.ToString()
}

# ════════════════════════════════════════════════════════════════
#  INPUT
# ════════════════════════════════════════════════════════════════

function Read-MenuChoice {
    FlushKeys
    while ($true) {
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'UpArrow'   { $script:Sel = ($script:Sel - 1 + $script:TotalChoices) % $script:TotalChoices; [Console]::Write((Build-MainScreen)) }
            'DownArrow' { $script:Sel = ($script:Sel + 1) % $script:TotalChoices; [Console]::Write((Build-MainScreen)) }
            'Enter' {
                if ($script:Sel -eq $script:Items.Count) { return 'Quit' }
                return $script:Items[$script:Sel].Action
            }
            default {
                $ch = $k.KeyChar
                if ($ch -eq 'q' -or $ch -eq 'Q') { return 'Quit' }
                $m = $script:Items | Where-Object { $_.Key -eq "$ch" }
                if ($m) { return $m.Action }
            }
        }
    }
}

function Prompt-Text([string]$Label, [string]$Default='', [string]$Example='', [switch]$Required) {
    ShowCur
    Write-Host "    ${BLD}${cW}${Label}${RST}"
    if ($Example) { Write-Host "    ${cGR}Example: $Example${RST}" }
    $hint = if ($Default) { "${cGR}[$Default]${RST} " } else { '' }
    Write-Host "    ${cC}$([char]0x25B8)${RST} $hint" -NoNewline
    $val = Read-Host
    if (-not $val -and $Default) { $val = $Default }
    if ($Required -and -not $val) {
        Write-Host "    ${cR}Required.${RST}"; return Prompt-Text $Label $Default $Example -Required:$Required
    }
    HideCur; return $val
}

function Prompt-Toggle([string]$Label, [bool]$Default=$false) {
    $opts = if($Default){"[${cG}Y${RST}/n]"}else{"[y/${cG}N${RST}]"}
    Write-Host "    ${cW}$Label${RST} $opts " -NoNewline
    ShowCur
    $k = WaitKey
    # switch is case-insensitive by default — duplicate branches cause array return!
    $r = switch($k.KeyChar){ 'y'{$true} 'n'{$false} default{$Default} }
    if ($r) {
        Write-Host "${cG}Yes $([char]0x2713)${RST}"
    } else {
        Write-Host "${cW}No ${cR}$([char]0x2717)${RST}"
    }
    HideCur; return $r
}

function Prompt-Confirm([string]$Msg, [switch]$DefaultYes) {
    Write-Host ""
    if ($DefaultYes) {
        $opts = "[${cG}Y${RST}/n]"
    } else {
        $opts = "[y/${cG}N${RST}]"
    }
    Write-Host "    ${BLD}${cY}?${RST} ${cW}$Msg${RST} $opts " -NoNewline
    ShowCur
    $k = WaitKey
    if ($DefaultYes) {
        $r = $k.KeyChar -ne 'n' -and $k.KeyChar -ne 'N'
    } else {
        $r = $k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y'
    }
    if ($r) {
        Write-Host "${cG}Yes $([char]0x2713)${RST}"
    } else {
        Write-Host "${BLD}${cR}No $([char]0x2717)${RST}"
    }
    HideCur; return $r
}

function Wait-AnyKey {
    Write-Host ""
    Write-Host "    ${cGR}Press any key to return to menu...${RST}"
    ShowCur; [void](WaitKey); HideCur
}

# ════════════════════════════════════════════════════════════════
#  STEP HEADER & RESULT BANNERS
# ════════════════════════════════════════════════════════════════

function Show-StepHeader([string]$Title, [string]$Sub='') {
    [Console]::Write("$E[2J$E[H"); HideCur
    $W = 62; $IW = $W - 2
    Write-Host ""
    Write-Host "  ${cC}$(Rep ([char]0x2550) $IW)${RST}"
    Write-Host "  $(PadC "${BLD}${cW}$Title${RST}" $IW)"
    if ($Sub) { Write-Host "  $(PadC "${cGR}$Sub${RST}" $IW)" }
    Write-Host "  ${cC}$(Rep ([char]0x2550) $IW)${RST}"
}

function Show-ResultBanner([bool]$Ok, [string]$Msg) {
    try {
        # Truncate long messages to fit the 56-char box
        if ($Msg.Length -gt 50) { $Msg = $Msg.Substring(0,47) + '...' }
        $icon = if($Ok){ "$([char]0x2713)" }else{ "$([char]0x2717)" }
        $col  = if($Ok){ $cG }else{ $cR }

        Write-Host ""
        Write-Host "  ${cGR}$(Rep ([char]0x2500) 58)${RST}"
        Write-Host ""
        Write-Host "  ${col}$([char]0x250C)$(Rep ([char]0x2500) 56)$([char]0x2510)${RST}"
        # Build the inner text without nesting ANSI in PadC — pad manually
        $inner = "$icon $Msg"
        $pad = [Math]::Max(0, 54 - $inner.Length)
        $lp = [Math]::Floor($pad / 2); $rp = $pad - $lp
        Write-Host "  ${col}$([char]0x2502)${RST} $(Rep ' ' $lp)${BLD}${col}${inner}${RST}$(Rep ' ' $rp) ${col}$([char]0x2502)${RST}"
        Write-Host "  ${col}$([char]0x2514)$(Rep ([char]0x2500) 56)$([char]0x2518)${RST}"
    } catch {
        # Fallback if anything goes wrong with rendering
        Write-Host ""
        if ($Ok) { Write-Host "  ${cG}$([char]0x2713) $Msg${RST}" }
        else     { Write-Host "  ${cR}$([char]0x2717) $Msg${RST}" }
    }
}

function Show-Summary([System.Collections.Specialized.OrderedDictionary]$Fields) {
    Write-Host ""
    Write-Host "    ${BLD}${cW}Configuration${RST}"
    Write-Host "    ${cGR}$(Rep ([char]0x2500) 46)${RST}"
    foreach ($k in $Fields.Keys) {
        Write-Host "    $(PadR "${cGR}${k}:${RST}" 24) ${cW}$($Fields[$k])${RST}"
    }
}

# ════════════════════════════════════════════════════════════════
#  EXECUTE STEP  (child process + title-bar spinner)
# ════════════════════════════════════════════════════════════════

function Invoke-Step([string]$Label, [string]$Script, [string]$ParamBlock) {
    $tmp = Join-Path $env:TEMP "mw-run-$([System.IO.Path]::GetRandomFileName()).ps1"
    $fullScript = Join-Path $script:ScriptsDir $Script

    $body = @"
`$ErrorActionPreference = 'Continue'
& '$($fullScript -replace "'","''")' $ParamBlock
exit `$LASTEXITCODE
"@
    [System.IO.File]::WriteAllText($tmp, $body, [System.Text.Encoding]::UTF8)

    Write-Host ""
    Write-Host "  ${cC}$([char]0x2501)$([char]0x2501)$([char]0x2501)${RST} ${cW}$Label${RST} ${cC}$([char]0x2501)$([char]0x2501)$([char]0x2501)${RST}"
    Write-Host ""

    # Brief launch spinner
    for ($f = 0; $f -lt 8; $f++) {
        $s = $Spin[$f % $Spin.Count]
        [Console]::Write("`r    ${cC}$s${RST} ${cGR}Launching...${RST}   ")
        Start-Sleep -Milliseconds 60
    }
    Write-Host "`r    ${cG}$([char]0x2713)${RST} ${cW}Running${RST}              "
    Write-Host ""

    # Shared console — child output renders directly (preserves progress bars + Unicode)
    ShowCur
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`""
    $psi.WorkingDirectory = if ($script:IsUNC) { $env:SystemRoot } else { $script:ScriptRoot }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false

    $proc = [System.Diagnostics.Process]::Start($psi)

    # Title bar spinner + WT tab progress indicator while child runs
    $frame = 0; $t0 = Get-Date
    while (-not $proc.HasExited) {
        $el = ((Get-Date) - $t0).ToString('mm\:ss')
        $s  = $Spin[$frame % $Spin.Count]
        $host.UI.RawUI.WindowTitle = "$s  $Label  [$el]"
        # Windows Terminal tab progress (indeterminate spinner)
        [Console]::Write("$E]9;4;3;0$E\")
        $frame++
        Start-Sleep -Milliseconds 80
    }

    # Clear WT progress + show elapsed
    [Console]::Write("$E]9;4;0;0$E\")
    $ec = $proc.ExitCode
    $elapsed = ((Get-Date) - $t0).ToString('mm\:ss')
    Write-Host ""
    Write-Host "    ${cG}$([char]0x2713)${RST} ${cW}Done${RST} ${cGR}[$elapsed]${RST}"

    $host.UI.RawUI.WindowTitle = 'Migration Merlin'
    HideCur
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return ($ec -eq 0)
}

# ════════════════════════════════════════════════════════════════
#  USMT PRE-CHECK
# ════════════════════════════════════════════════════════════════

function Find-USMT([string]$CustomPath) {
    <# Check if USMT (scanstate/loadstate) is reachable. Returns @{ Found; Path; Detail }. #>
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' }
            elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' }
            else { 'x86' }

    $candidates = @()
    if ($CustomPath) { $candidates += $CustomPath }
    $candidates += @(
        (Join-Path $script:ScriptRoot 'USMT-Tools')
        (Join-Path $env:TEMP 'USMT-Tools')
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        'C:\USMT'
        'C:\Tools\USMT'
    )

    foreach ($base in $candidates) {
        if (-not (Test-Path $base -ErrorAction SilentlyContinue)) { continue }
        # Try: arch subfolder → arm64 fallback → flat folder
        $tryPaths = @((Join-Path $base $arch))
        if ($arch -eq 'arm64') { $tryPaths += (Join-Path $base 'amd64') }
        $tryPaths += $base

        foreach ($tp in $tryPaths) {
            $exe = Join-Path $tp 'scanstate.exe'
            if (-not (Test-Path $exe -ErrorAction SilentlyContinue)) { continue }
            # Verify binary is compatible with this OS
            try {
                $null = & $exe /? 2>&1
                return [pscustomobject]@{ Found = $true; Path = $tp; Detail = "scanstate.exe verified in $tp" }
            } catch {
                $errMsg = "$_"
                if ($errMsg -match 'compat|machine type|version') {
                    # Binary exists but wrong arch — keep searching
                    continue
                }
                # Other error (permissions etc) — still usable
                return [pscustomobject]@{ Found = $true; Path = $tp; Detail = "scanstate.exe found in $tp (not verified: $errMsg)" }
            }
        }
    }

    # Check for bundled zip (scripts will extract it at runtime)
    $zipSearchPaths = @(
        (Join-Path $script:ScriptRoot 'user-state-migration-tool.zip')
        (Join-Path (Split-Path $script:ScriptRoot -Parent -ErrorAction SilentlyContinue) 'user-state-migration-tool.zip')
        (Join-Path $env:TEMP 'user-state-migration-tool.zip')
    )
    foreach ($zp in $zipSearchPaths) {
        if ($zp -and (Test-Path $zp -ErrorAction SilentlyContinue)) {
            $sizeMB = [Math]::Round((Get-Item $zp).Length / 1MB, 1)
            return [pscustomobject]@{ Found = $true; Path = "ZIP: $zp"; Detail = "Bundled zip found ($sizeMB MB) - will extract at runtime" }
        }
    }

    return [pscustomobject]@{ Found = $false; Path = ''; Detail = 'USMT not found (no scanstate.exe, no bundled zip, no ADK)' }
}

function Show-USMTCheck([string]$CustomPath) {
    <# Run USMT check with spinner, show result, offer options if missing. Returns USMTPath string (empty = auto). #>
    Write-Host ""
    for ($f = 0; $f -lt 6; $f++) {
        [Console]::Write("`r    ${cC}$($Spin[$f % $Spin.Count])${RST} ${cGR}Checking for USMT...${RST}   ")
        Start-Sleep -Milliseconds 50
    }
    $result = Find-USMT $CustomPath
    if ($result.Found) {
        Write-Host "`r    ${cG}$([char]0x2713)${RST} ${cW}$($result.Detail)${RST}                    "
        return $CustomPath
    }

    Write-Host "`r    ${cR}$([char]0x2717)${RST} ${cR}$($result.Detail)${RST}"
    Write-Host ""
    Write-Host "    ${cY}USMT is required for migration. Options:${RST}"
    Write-Host "    ${cW}1.${RST} ${cGR}Install Windows ADK with USMT component${RST}"
    Write-Host "    ${cW}2.${RST} ${cGR}Copy the bundled zip (user-state-migration-tool.zip) to this PC${RST}"
    Write-Host "    ${cW}3.${RST} ${cGR}Specify a custom USMT path below${RST}"
    Write-Host "    ${cGR}   ADK download: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install${RST}"
    Write-Host ""
    $uPath = Prompt-Text 'Custom USMT path (blank to let the script try auto-install)'
    return $uPath
}

# ════════════════════════════════════════════════════════════════
#  INLINE VALIDATION
# ════════════════════════════════════════════════════════════════

function Validate-Inline([string]$Label, [scriptblock]$Check) {
    <# Run a quick check and show pass/fail inline. Returns $true/$false. #>
    for ($f = 0; $f -lt 6; $f++) {
        [Console]::Write("`r    ${cC}$($Spin[$f % $Spin.Count])${RST} ${cGR}$Label${RST}   ")
        Start-Sleep -Milliseconds 50
    }
    $ok = & $Check
    if ($ok) {
        Write-Host "`r    ${cG}$([char]0x2713)${RST} ${cW}$Label${RST}                                    "
    } else {
        Write-Host "`r    ${cR}$([char]0x2717)${RST} ${cR}$Label${RST}                                    "
    }
    return $ok
}

# ════════════════════════════════════════════════════════════════
#  INTERACTIVE USER PICKER
# ════════════════════════════════════════════════════════════════

function Show-UserPicker {
    <# Arrow-key checkbox picker for local user profiles. Returns hashtable with Include/Exclude strings. #>
    Write-Host ""
    Write-Host "    ${BLD}${cW}User Selection${RST}"
    Write-Host "    ${cGR}$(Rep ([char]0x2500) 40)${RST}"
    Write-Host "    ${cC}I${RST}  ${cW}Interactive${RST} (pick from system users)"
    Write-Host "    ${cC}M${RST}  ${cW}Manual entry${RST} (comma-separated)"
    Write-Host "    ${cC}A${RST}  ${cW}All users${RST} (default)"
    Write-Host ""
    Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
    ShowCur

    $mode = $null
    FlushKeys
    while ($null -eq $mode) {
        $k = [Console]::ReadKey($true)
        switch -regex ("$($k.KeyChar)") {
            '[iI]'  { Write-Host 'Interactive'; HideCur; $mode = 'interactive' }
            '[mM]'  { Write-Host 'Manual'; HideCur; $mode = 'manual' }
            '[aA]'  { Write-Host 'All users'; HideCur; return @{ Include = ''; Exclude = '' } }
            default {
                if ($k.Key -eq 'Enter') { Write-Host 'All users'; HideCur; return @{ Include = ''; Exclude = '' } }
            }
        }
    }

    if ($mode -eq 'manual') {
        $inc = Prompt-Text 'Include users (comma-separated, blank for all)'
        $exc = Prompt-Text 'Exclude users (comma-separated, blank for none)'
        return @{ Include = $inc; Exclude = $exc }
    }

    # ── Interactive mode: enumerate profiles ──
    Write-Host ""
    $profiles = @()
    try {
        $wpList = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object { -not $_.Special -and $_.LocalPath }
        foreach ($wp in $wpList) {
            $short = Split-Path $wp.LocalPath -Leaf
            $display = $short
            try {
                $display = (New-Object System.Security.Principal.SecurityIdentifier($wp.SID)).Translate(
                    [System.Security.Principal.NTAccount]).Value
            } catch {}
            $profiles += [pscustomobject]@{
                Display  = $display
                Short    = $short
                Path     = $wp.LocalPath
                Selected = $true
            }
        }
    } catch {
        Write-Host "    ${cY}$([char]0x26A0) Could not enumerate users. Falling back to manual entry.${RST}"
        $inc = Prompt-Text 'Include users (comma-separated, blank for all)'
        $exc = Prompt-Text 'Exclude users (comma-separated, blank for none)'
        return @{ Include = $inc; Exclude = $exc }
    }

    if ($profiles.Count -eq 0) {
        Write-Host "    ${cY}$([char]0x26A0) No user profiles found.${RST}"
        return @{ Include = ''; Exclude = '' }
    }

    # Render the checkbox list using ANSI cursor-up for re-render (SetCursorPosition is unreliable in WT)
    $script:ulProfiles = $profiles
    $script:ulIdx = 0
    $script:ulFirstRender = $true
    # Cursor is ON the hint line, so go up (profiles + 1 blank) = profiles+1 lines to reach line 0
    $script:ulTotalLines = $profiles.Count + 1

    function Render-UserList {
        # On re-render: move cursor up to overwrite previous list
        if (-not $script:ulFirstRender) {
            [Console]::Write("$E[$($script:ulTotalLines)A`r")
        }
        $script:ulFirstRender = $false

        $buf = [System.Text.StringBuilder]::new(1024)
        for ($i = 0; $i -lt $script:ulProfiles.Count; $i++) {
            $p = $script:ulProfiles[$i]
            $arrow = if ($i -eq $script:ulIdx) { "${cC}$([char]0x25B8)${RST}" } else { ' ' }
            $check = if ($p.Selected) { "${cG}$([char]0x2713)${RST}" } else { "${cGR}$([char]0x25CB)${RST}" }
            $lbl   = if ($i -eq $script:ulIdx) { "${BLD}${cW}$($p.Display)${RST}" } else { "${cW}$($p.Display)${RST}" }
            $path  = "${cGR}$($p.Path)${RST}"
            [void]$buf.AppendLine("    $arrow [$check] $(PadR $lbl 28) $path          ")
        }
        [void]$buf.AppendLine()
        [void]$buf.Append("    ${cGR}$([char]0x2191)$([char]0x2193)${RST} Navigate  ${cGR}T${RST} Toggle  ${cGR}A${RST} All  ${cGR}N${RST} None  ${cGR}Enter${RST} Done")
        [Console]::Write($buf.ToString())
    }

    Render-UserList
    HideCur
    FlushKeys

    $done = $false
    while (-not $done) {
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'UpArrow'   { $script:ulIdx = ($script:ulIdx - 1 + $script:ulProfiles.Count) % $script:ulProfiles.Count }
            'DownArrow' { $script:ulIdx = ($script:ulIdx + 1) % $script:ulProfiles.Count }
            'Enter'     { $done = $true; continue }
            default {
                switch ($k.KeyChar) {
                    't' { $script:ulProfiles[$script:ulIdx].Selected = -not $script:ulProfiles[$script:ulIdx].Selected }
                    'a' { $script:ulProfiles | ForEach-Object { $_.Selected = $true } }
                    'n' { $script:ulProfiles | ForEach-Object { $_.Selected = $false } }
                }
            }
        }
        if (-not $done) { Render-UserList }
    }

    $selected = @($script:ulProfiles | Where-Object { $_.Selected } | ForEach-Object { $_.Short })
    $excluded = @($script:ulProfiles | Where-Object { -not $_.Selected } | ForEach-Object { $_.Short })
    $total = $script:ulProfiles.Count

    Write-Host ""
    if ($excluded.Count -eq 0) {
        Write-Host "    ${cG}$([char]0x2713)${RST} ${cW}All $total users selected${RST}"
    } else {
        Write-Host "    ${cG}$([char]0x2713)${RST} ${cW}$($selected.Count) of $total users selected${RST}"
    }

    # Build include/exclude strings
    $incStr = if ($excluded.Count -eq 0) { '' } else { $selected -join ',' }
    $excStr = $excluded -join ','
    return @{ Include = $incStr; Exclude = $excStr }
}

# ════════════════════════════════════════════════════════════════
#  STEP WORKFLOWS
# ════════════════════════════════════════════════════════════════

# ── 1. Setup Destination ──────────────────────────────────────
function Step-Setup {
    :setupLoop while ($true) {
        Show-StepHeader 'STEP 1: SETUP DESTINATION' 'Run this on the NEW PC'

        $cfg = Show-ConfigPrompt 'setup'
        Write-Host ""

        $defFolder = if ($cfg) { $cfg.Folder } else { 'C:\MigrationStore' }
        $defShare  = if ($cfg) { $cfg.Share } else { 'MigrationShare$' }
        $defIP     = if ($cfg) { $cfg.SourceIP } else { '' }
        $folder = Prompt-Text 'Migration folder path' -Default $defFolder
        $parentDir = Split-Path $folder -Parent
        if ($parentDir -and -not (Test-Path $parentDir -ErrorAction SilentlyContinue)) {
            Write-Host "    ${cY}$([char]0x26A0) Parent directory '$parentDir' does not exist (will be created)${RST}"
        } elseif (Test-Path $folder -ErrorAction SilentlyContinue) {
            Write-Host "    ${cG}$([char]0x2713)${RST} ${cGR}Folder already exists${RST}"
        }

        $share = Prompt-Text 'Share name' -Default 'MigrationShare$'
        if ($share -match '[\\/:*?"<>|]') {
            Write-Host "    ${cR}$([char]0x2717) Invalid characters in share name${RST}"
            if (-not (Prompt-Confirm 'Continue anyway?')) { continue setupLoop }
        }

        $srcIP = Prompt-Text 'Restrict to source IP (optional, Enter to skip)' -Example '192.168.1.100'
        if ($srcIP -and $srcIP -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            Write-Host "    ${cY}$([char]0x26A0) Does not look like a valid IPv4 address${RST}"
            if (-not (Prompt-Confirm 'Continue anyway?')) { continue setupLoop }
        }

        $skipUSMT = Prompt-Toggle 'Skip USMT install? (if already installed)'

        # ── USMT pre-check ──
        $usmtPath = ''
        if (-not $skipUSMT) {
            $usmtPath = Show-USMTCheck ''
        }

        # ── Disk space check ──
        $drive = Split-Path $folder -Qualifier -ErrorAction SilentlyContinue
        if ($drive) {
            try {
                $freeGB = [Math]::Round((Get-PSDrive ($drive -replace ':') -ErrorAction Stop).Free / 1GB, 1)
                Write-Host "    ${cGR}Free space on $($drive) $($freeGB) GB${RST}"
                if ($freeGB -lt 5) {
                    Write-Host "    ${cY}$([char]0x26A0) Less than 5 GB free${RST}"
                }
            } catch {}
        }

        $fields = [ordered]@{
            'Migration folder'  = $folder
            'Share name'        = $share
            'Source IP filter'  = if($srcIP){$srcIP}else{'Any'}
            'Skip USMT install' = if($skipUSMT){'Yes'}else{'No'}
        }
        Show-Summary $fields

        Write-Host ""
        Write-Host "    ${cC}Y${RST} ${cW}Start${RST}  ${cC}R${RST} ${cW}Reconfigure${RST}  ${cC}S${RST} ${cW}Save config${RST}  ${cC}N${RST} ${cW}Cancel${RST}"
        Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
        ShowCur
        $k = WaitKey; HideCur
        switch ($k.KeyChar) {
            'r' { Write-Host 'Reconfigure'; continue setupLoop }
            's' { Write-Host 'Save'; Save-RunConfig 'setup' @{ Folder=$folder; Share=$share; SourceIP=$srcIP; SkipUSMT=$skipUSMT; USMTPath=$usmtPath }; continue setupLoop }
            'y' { Write-Host 'Start'; break setupLoop }
            default { Write-Host 'Cancel'; return }
        }
    }

    $p = "-MigrationFolder '$($folder -replace "'","''")' -ShareName '$($share -replace "'","''")' -NonInteractive"
    if ($srcIP)    { $p += " -AllowedSourceIP '$($srcIP -replace "'","''")'" }
    if ($skipUSMT) { $p += ' -SkipUSMTInstall' }
    if ($usmtPath) { $p += " -USMTPath '$($usmtPath -replace "'","''")'" }

    $ok = Invoke-Step 'Setting up destination' 'destination-setup.ps1' $p
    Show-ResultBanner $ok $(if($ok){'Destination setup complete!'}else{'Setup encountered errors'})
    if ($ok) { $script:Done['Setup'] = $true }
    Wait-AnyKey
}

# ── 2. Capture Source ─────────────────────────────────────────
function Test-ShareWrite([string]$Path, [string]$User, [string]$Pass) {
    <# Try to write a tiny temp file to the share. Returns @{ OK; Detail }. #>
    $probe = Join-Path $Path ".mw-probe-$([System.IO.Path]::GetRandomFileName())"
    try {
        # If credentials provided, map a temp PSDrive
        if ($User) {
            $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
            $cred = [System.Management.Automation.PSCredential]::new($User, $secPass)
            $drv = "mwprobe$((Get-Random) % 1000)"
            New-PSDrive -Name $drv -PSProvider FileSystem -Root $Path -Credential $cred -ErrorAction Stop | Out-Null
            try {
                '' | Set-Content "${drv}:\$([System.IO.Path]::GetFileName($probe))" -ErrorAction Stop
                Remove-Item "${drv}:\$([System.IO.Path]::GetFileName($probe))" -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ OK = $true; Detail = 'Authenticated and writable' }
            } finally {
                Remove-PSDrive $drv -Force -ErrorAction SilentlyContinue
            }
        } else {
            '' | Set-Content $probe -ErrorAction Stop
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ OK = $true; Detail = 'Share is writable' }
        }
    } catch {
        $msg = "$_" -replace '\r?\n',' '
        if ($msg.Length -gt 80) { $msg = $msg.Substring(0,77) + '...' }
        return [pscustomobject]@{ OK = $false; Detail = $msg }
    }
}

function Step-Capture {
    :captureLoop while ($true) {
        Show-StepHeader 'STEP 2: CAPTURE SOURCE' 'Run this on the OLD PC'

        # ── Share ──
        $dest = Show-SharePicker

        # ── Authentication ──
        Write-Host ""
        Write-Host "    ${BLD}${cW}Authentication (optional)${RST}"
        $user = Prompt-Text 'Share username (blank to use current credentials)'
        $pass = ''
        if ($user) { $pass = Prompt-Text 'Share password' }

        # ── Verify share is writable (with creds if provided) ──
        Write-Host ""
        for ($f = 0; $f -lt 8; $f++) {
            [Console]::Write("`r    ${cC}$($Spin[$f % $Spin.Count])${RST} ${cGR}Testing share write access...${RST}   ")
            Start-Sleep -Milliseconds 60
        }
        $writeTest = Test-ShareWrite $dest $user $pass
        if ($writeTest.OK) {
            Write-Host "`r    ${cG}$([char]0x2713)${RST} ${cW}$($writeTest.Detail)${RST}                              "
        } else {
            Write-Host "`r    ${cR}$([char]0x2717)${RST} ${cR}$($writeTest.Detail)${RST}"
            if ($user) {
                Write-Host "    ${cGR}  Check username/password and share permissions${RST}"
            } else {
                Write-Host "    ${cGR}  Check share permissions or provide credentials${RST}"
            }
            Write-Host ""
            Write-Host "    ${cC}R${RST} ${cW}Retry / reconfigure${RST}  ${cC}C${RST} ${cW}Continue anyway${RST}  ${cC}N${RST} ${cW}Cancel${RST}"
            Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
            ShowCur; $k = WaitKey; HideCur
            switch ($k.KeyChar) {
                'r' { Write-Host 'Retry'; continue captureLoop }
                'c' { Write-Host 'Continue' }
                default { Write-Host 'Cancel'; return }
            }
        }

        # ── Options ──
        Write-Host ""
        Write-Host "    ${BLD}${cW}Options${RST}"
        $extra   = Prompt-Toggle 'Include extra data? (Sticky Notes, taskbar pins, power plans)'
        $encrypt = Prompt-Toggle 'Encrypt migration store?'
        $encKey  = ''
        if ($encrypt) {
            $encKey = Prompt-Text 'Encryption key (password)' -Required
        }
        $dryRun   = Prompt-Toggle 'Dry run? (preview only, no actual capture)'
        $skipUSMT = Prompt-Toggle 'Skip USMT install? (if already installed)'

        # ── USMT pre-check ──
        $usmtPath = ''
        if (-not $skipUSMT) {
            $usmtPath = Show-USMTCheck ''
        }

        # ── User selection ──
        $userSel = Show-UserPicker
        $incUsers = $userSel.Include
        $excUsers = $userSel.Exclude

        # ── Summary + review ──
        $fields = [ordered]@{
            'Destination share' = $dest
            'Credentials'       = if($user){"$user / ****"}else{'Current session'}
            'Write access'      = if($writeTest.OK){'Verified'}else{'NOT VERIFIED'}
            'Extra data'        = if($extra){'Yes'}else{'No'}
            'Encryption'        = if($encrypt){'Yes'}else{'No'}
            'Dry run'           = if($dryRun){'Yes'}else{'No'}
            'Include users'     = if($incUsers){$incUsers}else{'All'}
            'Exclude users'     = if($excUsers){$excUsers}else{'None'}
        }
        Show-Summary $fields

        Write-Host ""
        Write-Host "    ${cC}Y${RST} ${cW}Start$(if($dryRun){' dry run'})${RST}  ${cC}R${RST} ${cW}Reconfigure${RST}  ${cC}S${RST} ${cW}Save config${RST}  ${cC}N${RST} ${cW}Cancel${RST}"
        Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
        ShowCur; $k = WaitKey; HideCur
        switch ($k.KeyChar) {
            'r' { Write-Host 'Reconfigure'; continue captureLoop }
            's' { Write-Host 'Save'; Save-RunConfig 'capture' @{ Dest=$dest; User=$user; Extra=[bool]$extra; Encrypt=[bool]$encrypt; DryRun=[bool]$dryRun; SkipUSMT=[bool]$skipUSMT; USMTPath=$usmtPath; IncUsers=$incUsers; ExcUsers=$excUsers }; continue captureLoop }
            'y' { Write-Host 'Start'; break captureLoop }
            default { Write-Host 'Cancel'; return }
        }
    }

    $p = "-DestinationShare '$($dest -replace "'","''")' -NonInteractive"
    if ($user)     { $p += " -ShareUsername '$($user -replace "'","''")'" }
    if ($pass)     { $p += " -SharePassword '$($pass -replace "'","''")'" }
    if ($extra)    { $p += ' -ExtraData' }
    if ($encrypt)  { $p += ' -EncryptStore' }
    if ($encKey)   { $p += " -EncryptionKey '$($encKey -replace "'","''")'" }
    if ($dryRun)   { $p += ' -DryRun' }
    if ($skipUSMT) { $p += ' -SkipUSMTInstall' }
    if ($usmtPath) { $p += " -USMTPath '$($usmtPath -replace "'","''")'" }
    if ($incUsers) {
        $vals = ($incUsers -split ',').Trim() | ForEach-Object { "'$($_ -replace "'","''")'" }
        $p += " -IncludeUsers $($vals -join ',')"
    }
    if ($excUsers) {
        $vals = ($excUsers -split ',').Trim() | ForEach-Object { "'$($_ -replace "'","''")'" }
        $p += " -ExcludeUsers $($vals -join ',')"
    }

    $label = if($dryRun){'Capturing Source (Dry Run)'}else{'Capturing Source'}
    $ok = Invoke-Step $label 'source-capture.ps1' $p
    Show-ResultBanner $ok $(if($ok){'Source capture complete!'}else{'Capture encountered errors'})
    if ($ok) { $script:Done['Capture'] = $true }
    Wait-AnyKey
}

# ── 3. Restore ────────────────────────────────────────────────
function Step-Restore {
    :restoreLoop while ($true) {
        Show-StepHeader 'STEP 3: RESTORE DATA' 'Run this on the NEW PC'
        Write-Host ""
        Write-Host "    ${cW}Applies captured user state using USMT LoadState.${RST}"
        Write-Host "    ${cY}$([char]0x26A0)  Steps 1 (Setup) and 2 (Capture) must be complete.${RST}"
        Write-Host ""

        $folder = Prompt-Text 'Migration folder path' -Default 'C:\MigrationStore'

        # Pre-check: does migration data exist?
        $usmtStore = Join-Path $folder 'USMT'
        if (Test-Path $folder -ErrorAction SilentlyContinue) {
            if (Test-Path $usmtStore -ErrorAction SilentlyContinue) {
                Write-Host "    ${cG}$([char]0x2713)${RST} ${cW}Migration data found in $folder${RST}"
            } else {
                Write-Host "    ${cY}$([char]0x26A0) Folder exists but no USMT store found yet${RST}"
                Write-Host "    ${cGR}  (Capture may still be in progress or used a different path)${RST}"
            }
        } else {
            Write-Host "    ${cR}$([char]0x2717) Folder '$folder' does not exist${RST}"
        }

        $fields = [ordered]@{ 'Migration folder' = $folder }
        Show-Summary $fields

        Write-Host ""
        Write-Host "    ${cC}Y${RST} ${cW}Start${RST}  ${cC}R${RST} ${cW}Reconfigure${RST}  ${cC}N${RST} ${cW}Cancel${RST}"
        Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
        ShowCur; $k = WaitKey; HideCur
        switch ($k.KeyChar) {
            'r' { Write-Host 'Reconfigure'; continue restoreLoop }
            'y' { Write-Host 'Start'; break restoreLoop }
            default { Write-Host 'Cancel'; return }
        }
    }

    $p = "-MigrationFolder '$($folder -replace "'","''")' -RestoreOnly -NonInteractive"
    $ok = Invoke-Step 'Restoring user state' 'destination-setup.ps1' $p
    Show-ResultBanner $ok $(if($ok){'Restore complete!'}else{'Restore encountered errors'})
    if ($ok) { $script:Done['Restore'] = $true }
    Wait-AnyKey
}

# ── 4. Verify ─────────────────────────────────────────────────
function Step-Verify {
    :verifyLoop while ($true) {
        Show-StepHeader 'STEP 4: VERIFY MIGRATION' 'Run this on the NEW PC'
        Write-Host ""
        Write-Host "    ${cW}Compares pre-migration inventory with current system state.${RST}"
        Write-Host "    ${cW}Shows what migrated and what needs manual attention.${RST}"
        Write-Host ""

        $folder = Prompt-Text 'Migration folder path' -Default 'C:\MigrationStore'

        # Pre-check: does pre-scan data exist?
        $preScan = Join-Path $folder 'PreScanData'
        if (Test-Path $preScan -ErrorAction SilentlyContinue) {
            Write-Host "    ${cG}$([char]0x2713)${RST} ${cW}Pre-scan data found${RST}"
        } elseif (-not (Test-Path $folder -ErrorAction SilentlyContinue)) {
            Write-Host "    ${cR}$([char]0x2717) Folder '$folder' does not exist${RST}"
        } else {
            Write-Host "    ${cY}$([char]0x26A0) No pre-scan data found (verification may be limited)${RST}"
        }

        $fields = [ordered]@{ 'Migration folder' = $folder }
        Show-Summary $fields

        Write-Host ""
        Write-Host "    ${cC}Y${RST} ${cW}Start${RST}  ${cC}R${RST} ${cW}Reconfigure${RST}  ${cC}N${RST} ${cW}Cancel${RST}"
        Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
        ShowCur; $k = WaitKey; HideCur
        switch ($k.KeyChar) {
            'r' { Write-Host 'Reconfigure'; continue verifyLoop }
            'y' { Write-Host 'Start'; break verifyLoop }
            default { Write-Host 'Cancel'; return }
        }
    }

    $p = "-MigrationFolder '$($folder -replace "'","''")'"
    $ok = Invoke-Step 'Verifying migration' 'post-migration-verify.ps1' $p
    Show-ResultBanner $ok $(if($ok){'Verification complete!'}else{'Verification encountered errors'})
    if ($ok) { $script:Done['Verify'] = $true }
    Wait-AnyKey
}

# ── 5. Cleanup ────────────────────────────────────────────────
function Step-Cleanup {
    :cleanupLoop while ($true) {
        Show-StepHeader 'STEP 5: CLEANUP' 'Run this on the NEW PC'
        Write-Host ""
        Write-Host "    ${cW}Removes network share, firewall rules, and migration data.${RST}"
        Write-Host "    ${cR}$([char]0x26A0)  This is destructive. Verify migration results first!${RST}"
        Write-Host ""

        $folder = Prompt-Text 'Migration folder path' -Default 'C:\MigrationStore'

        # Show what will be cleaned
        if (Test-Path $folder -ErrorAction SilentlyContinue) {
            $size = (Get-ChildItem $folder -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $sizeMB = [Math]::Round($size / 1MB, 1)
            Write-Host "    ${cY}$([char]0x26A0) Will delete: $folder ($sizeMB MB)${RST}"
        } else {
            Write-Host "    ${cGR}Folder does not exist (firewall rules and share will still be removed)${RST}"
        }

        $fields = [ordered]@{ 'Migration folder' = $folder }
        Show-Summary $fields

        Write-Host ""
        Write-Host "    ${cC}Y${RST} ${cW}Proceed${RST}  ${cC}R${RST} ${cW}Reconfigure${RST}  ${cC}N${RST} ${cW}Cancel${RST}"
        Write-Host "    ${cC}$([char]0x25B8)${RST} " -NoNewline
        ShowCur; $k = WaitKey; HideCur
        switch ($k.KeyChar) {
            'r' { Write-Host 'Reconfigure'; continue cleanupLoop }
            'y' { Write-Host 'Proceed' }
            default { Write-Host 'Cancel'; return }
        }

        # Second confirmation for destructive action
        if (-not (Prompt-Confirm 'This cannot be undone. Really proceed?')) { continue cleanupLoop }
        break cleanupLoop
    }

    $p = "-MigrationFolder '$($folder -replace "'","''")' -Cleanup -NonInteractive"
    $ok = Invoke-Step 'Cleaning up' 'destination-setup.ps1' $p
    Show-ResultBanner $ok $(if($ok){'Cleanup complete!'}else{'Cleanup encountered errors'})
    if ($ok) { $script:Done['Cleanup'] = $true }
    Wait-AnyKey
}

# ════════════════════════════════════════════════════════════════
#  STARTUP ANIMATION
# ════════════════════════════════════════════════════════════════

function Show-Intro {
    [Console]::Write("$E[2J$E[H"); HideCur

    # Phase 1 — centered spinner
    $cRow = [Math]::Floor([Console]::WindowHeight / 2)
    $cCol = [Math]::Floor([Console]::WindowWidth  / 2)
    for ($i = 0; $i -lt 10; $i++) {
        $s = $Spin[$i % $Spin.Count]
        [Console]::SetCursorPosition([Math]::Max(0,$cCol - 1), [Math]::Max(0,$cRow))
        [Console]::Write("${cC}$s${RST}")
        Start-Sleep -Milliseconds 55
    }

    # Phase 2 — clear, draw box, typewriter title
    [Console]::Write("$E[2J$E[H")
    $W = 62; $IW = $W - 2
    $topRow = 1
    [Console]::SetCursorPosition(2, $topRow)
    [Console]::Write("${cC}$(Rep ([char]0x2550) $IW)${RST}")
    [Console]::SetCursorPosition(2, $topRow + 1)
    [Console]::Write("${cC}$(Rep ' ' $IW)${RST}")
    [Console]::SetCursorPosition(2, $topRow + 2)
    [Console]::Write("$(Rep ' ' $IW)")
    [Console]::SetCursorPosition(2, $topRow + 3)
    [Console]::Write("${cC}$(Rep ([char]0x2550) $IW)${RST}")

    $title = 'M I G R A T I O N   W I Z A R D R Y'
    $startCol = [Math]::Floor(($IW - $title.Length) / 2) + 2
    for ($i = 0; $i -lt $title.Length; $i++) {
        [Console]::SetCursorPosition($startCol + $i, $topRow + 1)
        [Console]::Write("${BLD}${cW}$($title[$i])${RST}")
        Start-Sleep -Milliseconds 18
    }

    # Lightning bolts
    [Console]::SetCursorPosition([Math]::Max(0,$startCol - 3), $topRow + 1)
    [Console]::Write("${BLD}${cY}$([char]0x26A1)${RST}")
    [Console]::SetCursorPosition($startCol + $title.Length + 2, $topRow + 1)
    [Console]::Write("${BLD}${cY}$([char]0x26A1)${RST}")

    # Subtitle
    $sub = 'USMT  PC-to-PC  User State Migration'
    $subCol = [Math]::Floor(($IW - $sub.Length) / 2) + 2
    [Console]::SetCursorPosition($subCol, $topRow + 2)
    [Console]::Write("${cGR}$sub${RST}")

    Start-Sleep -Milliseconds 350
}

# ════════════════════════════════════════════════════════════════
#  MAIN LOOP
# ════════════════════════════════════════════════════════════════

function Main {
    Show-Intro

    while ($true) {
        [Console]::Write((Build-MainScreen))
        HideCur

        $action = Read-MenuChoice

        switch ($action) {
            'Setup'   { Step-Setup }
            'Capture' { Step-Capture }
            'Restore' { Step-Restore }
            'Verify'  { Step-Verify }
            'Cleanup' { Step-Cleanup }
            'Quit' {
                [Console]::Write("$E[2J$E[H")
                ShowCur
                Write-Host ""
                Write-Host "  ${cC}$([char]0x26A1)${RST} ${cW}Thanks for using Migration Merlin!${RST} ${cC}$([char]0x26A1)${RST}"
                Write-Host ""
                return
            }
        }
    }
}

# ════════════════════════════════════════════════════════════════
#  ENTRY
# ════════════════════════════════════════════════════════════════

try {
    Main
} catch {
    ShowCur
    Write-Host ""
    Write-Host "  ${cR}Unexpected error: $_${RST}" -ForegroundColor Red
    Write-Host ""
} finally {
    ShowCur
    $host.UI.RawUI.WindowTitle = 'PowerShell'
    # Restore normal sleep/screen-off behavior
    try { [MwKernel]::AllowSleep() } catch {}
}
