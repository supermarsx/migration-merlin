<#
.SYNOPSIS
    Shared UI helper functions for MigrationMerlin scripts.

.DESCRIPTION
    Extracted from source-capture.ps1 and destination-setup.ps1 to eliminate
    duplication. Provides banner, step, status, detail, progress-bar,
    sub-progress, and spinner helpers with a flexible state-injection model.

    State injection (for CurrentStep / TotalSteps / StartTime) resolves in
    this priority order:
      1. Explicit -State hashtable parameter.
      2. Module-scoped state set via Set-MigrationUIState.
      3. Caller's script-scope variables ($script:CurrentStep, etc.),
         discovered via Get-Variable -Scope 1.

    The Get-Variable fallback preserves backward compatibility with existing
    dot-sourced scripts until executor t1-e11 replaces the script-scope
    globals with a MigrationState class. When that lands, the fallback block
    in Resolve-UIState can be removed.

.NOTES
    Executor: t1-e2
    Locks: MigrationUI.psm1, tests/modules/MigrationUI.Tests.ps1
#>

# ---------------------------------------------------------------------------
# UI constants (local defaults). Soft-import MigrationConstants.psm1 if the
# peer executor t1-e1 has published it by the time this module loads.
# ---------------------------------------------------------------------------
$script:UIConstants = @{
    BannerWidth     = 56
    StepBarLen      = 30
    ProgressBarLen  = 35
    Divider         = 50
}

try {
    $constantsPath = Join-Path $PSScriptRoot 'MigrationConstants.psm1'
    if (Test-Path $constantsPath) {
        Import-Module $constantsPath -Force -ErrorAction Stop
        if ((Get-Variable -Name MigrationConstants -Scope Global -ErrorAction SilentlyContinue) -and
            $Global:MigrationConstants.UI) {
            foreach ($k in 'BannerWidth','StepBarLen','ProgressBarLen','Divider') {
                if ($Global:MigrationConstants.UI.ContainsKey($k)) {
                    $script:UIConstants[$k] = $Global:MigrationConstants.UI[$k]
                }
            }
        }
    }
} catch {
    # Soft failure — keep local defaults.
}

# ---------------------------------------------------------------------------
# Codepage-aware glyph fallback (t1-e14a).
#   On non-UTF-8 consoles (legacy codepages like 437, 850, 1252) the Unicode
#   block / braille glyphs render as '?'. Get-MigrationUIGlyphs returns either
#   the Unicode set (on UTF-8 / UTF-16 / UTF-32 codepages) or an ASCII
#   fallback set so Show-ProgressBar / Show-SubProgress / Show-Spinner /
#   Show-Status can degrade gracefully.
# ---------------------------------------------------------------------------
function Get-MigrationUIGlyphs {
    <#
    .SYNOPSIS
        Returns a glyph hashtable appropriate for the current console codepage.
    .DESCRIPTION
        Codepage 65001 (UTF-8), 1200/1201 (UTF-16 LE/BE), 12000/12001 (UTF-32)
        are treated as Unicode-capable. Anything else (437, 850, 1252, etc.)
        falls back to ASCII-safe glyphs.
    .OUTPUTS
        hashtable with keys:
            BarFilled, BarEmpty, Spinner (array), CheckMark, Cross
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param()

    $cp = 65001
    try { $cp = [int][Console]::OutputEncoding.CodePage } catch { $cp = 65001 }

    # 65001 = UTF-8, 1200/1201 = UTF-16 LE/BE, 12000/12001 = UTF-32
    $unicodeCodepages = @(65001, 1200, 1201, 12000, 12001)
    if ($cp -in $unicodeCodepages) {
        return @{
            BarFilled = [char]0x2588   # Full block
            BarEmpty  = [char]0x2591   # Light shade
            Spinner   = @(
                [char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838,
                [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827,
                [char]0x2807, [char]0x280F
            )
            CheckMark = [char]0x2713   # Check mark
            Cross     = [char]0x2717   # Ballot X
        }
    } else {
        return @{
            BarFilled = '#'
            BarEmpty  = '-'
            Spinner   = @('|', '/', '-', '\')
            CheckMark = '+'
            Cross     = 'x'
        }
    }
}

# ---------------------------------------------------------------------------
# Module-scoped default state (optional convenience for callers).
# ---------------------------------------------------------------------------
$script:UIState = @{
    CurrentStep = 0
    TotalSteps  = 0
    StartTime   = $null
}

function Set-MigrationUIState {
    <#
    .SYNOPSIS
        Sets the module's default UI state hashtable.
    .PARAMETER State
        Hashtable with keys CurrentStep, TotalSteps, StartTime.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )
    foreach ($k in 'CurrentStep','TotalSteps','StartTime') {
        if ($State.ContainsKey($k)) {
            $script:UIState[$k] = $State[$k]
        }
    }
}

function Get-MigrationUIState {
    <#
    .SYNOPSIS
        Returns a clone of the module's default UI state hashtable.
    #>
    [CmdletBinding()]
    param()
    return @{
        CurrentStep = $script:UIState.CurrentStep
        TotalSteps  = $script:UIState.TotalSteps
        StartTime   = $script:UIState.StartTime
    }
}

function Resolve-UIState {
    <#
    .SYNOPSIS
        Private helper. Returns a state hashtable following the priority:
        param > module > caller script scope. Increments CurrentStep if
        -Increment is set, mutating the source of truth.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$State,
        [switch]$Increment
    )

    $resolved = @{ CurrentStep = 0; TotalSteps = 0; StartTime = $null }
    $source   = 'default'

    if ($State) {
        foreach ($k in 'CurrentStep','TotalSteps','StartTime') {
            if ($State.ContainsKey($k)) { $resolved[$k] = $State[$k] }
        }
        $source = 'param'
    }
    elseif ($script:UIState.TotalSteps -gt 0 -or $script:UIState.StartTime) {
        $resolved.CurrentStep = $script:UIState.CurrentStep
        $resolved.TotalSteps  = $script:UIState.TotalSteps
        $resolved.StartTime   = $script:UIState.StartTime
        $source = 'module'
    }
    else {
        # ---- Fallback: best-effort read of caller-provided variables. --------
        # Module functions run in an isolated session state, so we cannot cheaply
        # reach the caller's *script-scope* variables. We try two avenues:
        #   (a) the caller's callstack-frame locals (works when the vars are
        #       declared at a function scope with the dot-sourced style);
        #   (b) the global scope, which callers may opt into by assigning
        #       $global:CurrentStep etc.
        # Callers that dot-source the legacy scripts will fall out of this
        # fallback path; those scripts should either call Set-MigrationUIState
        # or pass -State explicitly.
        # TODO t1-e11: remove this block once MigrationState class is in place.
        try {
            $frames = Get-PSCallStack
            $callerFrame = $null
            for ($fi = 2; $fi -lt $frames.Count; $fi++) {
                if ($frames[$fi].ScriptName -and
                    $frames[$fi].ScriptName -notmatch 'MigrationUI\.psm1$') {
                    $callerFrame = $frames[$fi]
                    break
                }
            }
            $found = $false
            if ($callerFrame) {
                $vars = $callerFrame.GetFrameVariables()
                $cs = $vars['CurrentStep']; $ts = $vars['TotalSteps']; $st = $vars['StartTime']
                if ($cs) { $resolved.CurrentStep = [int]$cs.Value; $found = $true }
                if ($ts) { $resolved.TotalSteps  = [int]$ts.Value; $found = $true }
                if ($st) { $resolved.StartTime   = $st.Value;      $found = $true }
                if ($found) {
                    $source = 'caller-frame'
                    $script:__UIState_CallerFrame = $callerFrame
                }
            }
            if (-not $found) {
                $gcs = Get-Variable -Name 'CurrentStep' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
                $gts = Get-Variable -Name 'TotalSteps'  -Scope Global -ValueOnly -ErrorAction SilentlyContinue
                $gst = Get-Variable -Name 'StartTime'   -Scope Global -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $gcs) { $resolved.CurrentStep = [int]$gcs; $found = $true }
                if ($null -ne $gts) { $resolved.TotalSteps  = [int]$gts; $found = $true }
                if ($null -ne $gst) { $resolved.StartTime   = $gst;      $found = $true }
                if ($found) { $source = 'global-scope' }
            }
        } catch {
            # leave defaults
        }
    }

    if ($Increment) {
        $resolved.CurrentStep++
        switch ($source) {
            'param' {
                $State.CurrentStep = $resolved.CurrentStep
            }
            'module' {
                $script:UIState.CurrentStep = $resolved.CurrentStep
            }
            'caller-frame' {
                try {
                    if ($script:__UIState_CallerFrame) {
                        $vars = $script:__UIState_CallerFrame.GetFrameVariables()
                        if ($vars['CurrentStep']) {
                            $vars['CurrentStep'].Value = $resolved.CurrentStep
                        }
                    }
                } catch { }
            }
            'global-scope' {
                try {
                    Set-Variable -Name 'CurrentStep' -Scope Global -Value $resolved.CurrentStep -ErrorAction SilentlyContinue
                } catch { }
            }
        }
    }

    return $resolved
}

# ---------------------------------------------------------------------------
# Public UI functions
# ---------------------------------------------------------------------------

function Show-Banner {
    <#
    .SYNOPSIS
        Prints a centered title inside a double-line banner.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [ConsoleColor]$Color = [ConsoleColor]::Magenta
    )
    $width = $script:UIConstants.BannerWidth
    $pad = [math]::Max(0, [math]::Floor(($width - $Title.Length - 2) / 2))
    $line = "=" * $width
    Write-Host ""
    Write-Host "  $line" -ForegroundColor $Color
    Write-Host "  $(' ' * $pad) $Title $(' ' * $pad)" -ForegroundColor $Color
    Write-Host "  $line" -ForegroundColor $Color
    Write-Host ""
}

function Show-Step {
    <#
    .SYNOPSIS
        Announces a numbered migration step with a progress bar and elapsed time.
    .PARAMETER State
        Optional hashtable with CurrentStep, TotalSteps, StartTime.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [hashtable]$State
    )
    $s = Resolve-UIState -State $State -Increment

    $total = [math]::Max(1, [int]$s.TotalSteps)
    $current = [int]$s.CurrentStep
    $pct = [math]::Round(($current / $total) * 100)

    $elapsed = if ($s.StartTime) {
        ((Get-Date) - $s.StartTime).ToString('mm\:ss')
    } else {
        '00:00'
    }

    $barLen = $script:UIConstants.StepBarLen
    $filled = [math]::Floor($barLen * $current / $total)
    $empty  = $barLen - $filled
    $g = Get-MigrationUIGlyphs
    $bar = ($g.BarFilled.ToString()) * $filled + ($g.BarEmpty.ToString()) * $empty

    Write-Host ""
    Write-Host "  [$bar] $pct% " -NoNewline -ForegroundColor Cyan
    Write-Host "Step $current/$total" -NoNewline -ForegroundColor DarkGray
    Write-Host "  ($elapsed elapsed)" -ForegroundColor DarkGray
    Write-Host "  >> $Description" -ForegroundColor White
    Write-Host "  $('-' * $script:UIConstants.Divider)" -ForegroundColor DarkGray
}

function Show-Status {
    <#
    .SYNOPSIS
        Prints an OK/WARN/FAIL/INFO/WAIT status line with colored icon.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('OK','FAIL','WARN','WAIT','INFO')]
        [string]$Level = 'INFO'
    )
    $icon = switch ($Level) {
        'OK'   { '[+]' }
        'FAIL' { '[X]' }
        'WARN' { '[!]' }
        'WAIT' { '[~]' }
        'INFO' { '[i]' }
        default { '[.]' }
    }
    $color = switch ($Level) {
        'OK'   { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        'WAIT' { 'DarkCyan' }
        default { 'Gray' }
    }
    Write-Host "     $icon $Message" -ForegroundColor $color
}

function Show-Detail {
    <#
    .SYNOPSIS
        Prints an indented Label : Value detail line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Value
    )
    Write-Host "         $Label : " -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor White
}

function Show-ProgressBar {
    <#
    .SYNOPSIS
        Renders a carriage-return progress bar on the current line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Current,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$Label,
        [string]$Detail = ''
    )
    if ($Total -le 0) { return }
    $pct = [math]::Min(100, [math]::Round(($Current / $Total) * 100))
    $barLen = $script:UIConstants.ProgressBarLen
    $filled = [math]::Floor($barLen * $pct / 100)
    $empty  = $barLen - $filled
    $g = Get-MigrationUIGlyphs
    $bar = ($g.BarFilled.ToString()) * $filled + ($g.BarEmpty.ToString()) * $empty
    $line = "     [$bar] $pct% - $Label"
    if ($Detail) { $line += " ($Detail)" }
    Write-Host "`r$line    " -NoNewline -ForegroundColor Cyan
}

function Show-SubProgress {
    <#
    .SYNOPSIS
        Renders an indented sub-progress line for nested operations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total
    )
    # Total is captured for future formatting; currently drives the count display.
    if ($Total -le 0) { return }
    Write-Host "`r         ($Index/$Total) $Item                              " -NoNewline -ForegroundColor DarkGray
}

function Show-Spinner {
    <#
    .SYNOPSIS
        Runs a script block in a background job while animating a spinner.
    .PARAMETER Message
        Label to display beside the spinner.
    .PARAMETER Action
        Script block to execute. Its output is returned when complete.
    .PARAMETER IntervalMs
        Frame interval in milliseconds. Defaults to 150.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$IntervalMs = 150
    )
    $g = Get-MigrationUIGlyphs
    $frames = $g.Spinner
    $job = Start-Job -ScriptBlock $Action
    $i = 0
    while ($job.State -eq 'Running') {
        $frame = $frames[$i % $frames.Count]
        Write-Host "`r     [$frame] $Message..." -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Milliseconds $IntervalMs
        $i++
    }
    $result = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Write-Host "`r     [+] $Message   " -ForegroundColor Green
    return $result
}

Export-ModuleMember -Function @(
    'Show-Banner',
    'Show-Step',
    'Show-Status',
    'Show-Detail',
    'Show-ProgressBar',
    'Show-SubProgress',
    'Show-Spinner',
    'Set-MigrationUIState',
    'Get-MigrationUIState',
    'Get-MigrationUIGlyphs'
)
