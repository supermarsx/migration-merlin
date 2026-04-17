@{
    # Migration-Merlin PSScriptAnalyzer configuration.
    # The CI `lint` job fails only on Error-severity findings. Warnings are
    # reported for awareness but do not block the pipeline. Adjust excluded
    # rules here when a check produces noisy false-positives that are
    # intentional in this codebase.

    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # The TUI in MigrationUI.psm1 and many user-facing scripts use
        # Write-Host intentionally to colour the console; Write-Output would
        # corrupt the pipeline.
        'PSAvoidUsingWriteHost'

        # Several state-changing helpers in this repo are intentionally
        # imperative and do not implement -WhatIf; adding ShouldProcess to
        # everything would bloat the codebase without user value.
        'PSUseShouldProcessForStateChangingFunctions'

        # USMT and DISM command assembly occasionally requires Invoke-Expression
        # where input is fully constructed from validated parameters.
        'PSAvoidUsingInvokeExpression'

        # Password/plaintext rules flag USMT encryption-key parameters which
        # are required by the underlying tool's contract.
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.2')
        }
    }
}
