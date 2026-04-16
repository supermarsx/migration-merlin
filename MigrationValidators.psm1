<#
.SYNOPSIS
    Shared validation helpers for Migration-Merlin parameter attributes and
    optional runtime checks.

.DESCRIPTION
    Introduced in Phase 3 (t1-e12). Each exported Test-* function returns a
    plain [bool] so it can be used from [ValidateScript({ ... })] attributes
    on the main scripts' param() blocks as well as from normal runtime code.

    Keeping the functions small, side-effect free, and returning Boolean
    makes them trivially unit-testable.
#>

function Test-UncPath {
    <#
    .SYNOPSIS
        Returns $true when the path looks like a valid UNC share path.
    .DESCRIPTION
        Accepts forms such as:
            \\server\share
            \\server\share$
            \\server\share\sub\path
        Rejects local paths, slash-delimited POSIX paths, empty strings, and
        any value containing characters that are illegal in Windows share or
        path segments.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return $Path -match '^\\\\[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+(\\.*)?$'
}

function Test-USMTPath {
    <#
    .SYNOPSIS
        Returns $true when the path is a directory containing the expected
        USMT executable (default scanstate.exe).
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,

        [string]$ExeName = 'scanstate.exe'
    )
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path $ExeName) -PathType Leaf)
}

function Test-ProfileName {
    <#
    .SYNOPSIS
        Returns $true when the string is a plausible Windows local / domain
        account short name.
    .DESCRIPTION
        Rejects names containing any of: \ / [ ] : ; | = , + * ? < >
        Rejects empty / whitespace-only strings.
        Does NOT enforce Windows' 20-character local-account limit because
        Migration-Merlin also supports domain accounts which can be longer.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return ($Name -notmatch '[\\/\[\]:;\|=,\+\*\?<>]')
}

function Test-EncryptionKeyStrength {
    <#
    .SYNOPSIS
        Returns $true when the supplied key meets a minimum length.
    .DESCRIPTION
        Accepts either [string] or [SecureString]. The length check is purely
        a floor — USMT itself imposes no specific complexity requirements.
        Any other type returns $false rather than throwing.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Key,

        [int]$MinimumLength = 8
    )
    if ($null -eq $Key) { return $false }

    $plain = $null
    if ($Key -is [System.Security.SecureString]) {
        try {
            $plain = [System.Net.NetworkCredential]::new('', $Key).Password
        } catch {
            return $false
        }
    } elseif ($Key -is [string]) {
        $plain = $Key
    } else {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($plain)) { return $false }
    return ($plain.Length -ge $MinimumLength)
}

function Test-ShareName {
    <#
    .SYNOPSIS
        Returns $true when the string is a valid SMB share name.
    .DESCRIPTION
        SMB share names are limited to 80 characters and may not contain:
            \ / [ ] : ; | = , + * ? < > "
        A trailing $ is allowed for admin / hidden shares (e.g. MigrationShare$).
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name.Length -gt 80) { return $false }
    return ($Name -match '^[A-Za-z0-9_\$][A-Za-z0-9_\-\.\$]{0,79}$')
}

Export-ModuleMember -Function `
    Test-UncPath, `
    Test-USMTPath, `
    Test-ProfileName, `
    Test-EncryptionKeyStrength, `
    Test-ShareName
