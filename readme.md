<img width="300" height="300" alt="Migration Merlin Logotype" src="https://github.com/user-attachments/assets/a73cdd48-4ffd-49b7-97d5-665d88393c51" />

# MigrationMerlin

USMT-based Windows user-profile migration toolkit with TUI, batch wrappers, and a robust test suite.

![CI](https://github.com/supermarsx/migration-merlin/actions/workflows/ci.yml/badge.svg)

Rolling release · [latest release](https://github.com/supermarsx/migration-merlin/releases/latest)

MigrationMerlin is a PC-to-PC user-state migration tool for Windows sysadmins and power users. It wraps Microsoft's official User State Migration Tool (`scanstate.exe` / `loadstate.exe`) with a friendly interactive TUI, numbered batch wrappers for step-by-step runs, an auto-configured SMB transfer share, optional AES-256 store encryption, multi-user include/exclude filtering, and a substantial Pester test suite. It is designed for the real-world case of moving a user (or a handful of users) from an old Windows 10/11 PC to a new one over the local network without hand-rolling USMT commands.

## Features

- USMT auto-detect and auto-install (bundled zip or silent Windows ADK fallback)
- SMB share auto-setup on the destination PC, including firewall rule
- Optional ACL tightening via `-AllowedSourceUser` and firewall scoping via `-AllowedSourceIP`
- AES-256 encryption of the migration store (`-EncryptStore` + SecureString key)
- Multi-user include / exclude filtering (`-IncludeUsers`, `-ExcludeUsers`)
- Live progress bars, file counters, and MB/s throughput during scanstate / loadstate
- Codepage-aware UI (braille spinner on UTF-8, ASCII fallback on OEM 437/850)
- Dry-run mode that prints the composed USMT command line without executing it
- Auto-elevation via UAC with safe SecureString marshalling across the boundary
- Transcript logging with credential masking to the migration folder's `Logs\`
- Interactive TUI launcher (`MigrationMerlin.bat`) with saved configurations
- Pester v5 test suite (~645 tests) covering modules, scripts, and integration paths

## Repo layout

```
/
├── MigrationMerlin.bat        Entry point (auto-elevating batch wrapper)
├── MigrationMerlin.ps1        Interactive TUI launcher
├── modules/                   Reusable PowerShell modules (8 files)
├── scripts/                   Workflow scripts (capture / restore / verify)
├── wrappers/                  Numbered .bat wrappers for the 5 manual steps
├── config/                    USMT XML config (custom-migration.xml)
└── tests/                     Pester suite (~645 tests)
```

## Requirements

- Windows 10 or Windows 11 (source and destination)
- Windows PowerShell 5.1 or PowerShell 7+
- Administrator privileges on both PCs (scripts auto-elevate via UAC)
- Both PCs reachable on the same network (SMB port 445 open between them)
- Pester 5.x to run the test suite (auto-installed by `tests\Run-Tests.ps1`)

USMT itself is **not** a prerequisite - the source script auto-installs it if it's not already present.

## Quick start

### Two-PC migration (recommended, numbered wrappers)

On the **new** (destination) PC, as Administrator:

```bat
wrappers\1-Setup-Destination.bat
```

On the **old** (source) PC, as Administrator:

```bat
wrappers\2-Capture-Source.bat
```

Back on the **new** PC, once capture completes:

```bat
wrappers\3-Restore-Destination.bat
wrappers\4-Verify-Migration.bat
wrappers\5-Cleanup.bat
```

### Interactive TUI

Double-click `MigrationMerlin.bat` (or run `.\MigrationMerlin.ps1`) for an arrow-key driven menu that walks through setup, capture, restore, verification, and cleanup in sequence. Configuration is persisted to `%LOCALAPPDATA%\MigrationMerlin\config.json` between runs.

### Scripted invocation

```powershell
# Destination (new PC)
pwsh -File scripts\destination-setup.ps1

# Source (old PC) - share path is printed by the destination script
pwsh -File scripts\source-capture.ps1 -DestinationShare '\\NewPC\MigrationShare$'
```

Default migration folder is `C:\MigrationStore` and default share name is `MigrationShare$` (the trailing `$` makes it a hidden share).

## Common scenarios

**Encrypted capture.** Pass a SecureString key to protect the store with AES-256. There is no recovery path if the key is lost.

```powershell
$key = Read-Host -AsSecureString 'Encryption key'
pwsh -File scripts\source-capture.ps1 `
    -DestinationShare '\\NewPC\MigrationShare$' `
    -EncryptStore -EncryptionKey $key
```

**Selective users.** Migrate only a specific set of profiles, optionally excluding others.

```powershell
pwsh -File scripts\source-capture.ps1 `
    -DestinationShare '\\NewPC\MigrationShare$' `
    -IncludeUsers 'alice','bob' -ExcludeUsers 'tempuser'
```

**Restricted destination share.** Lock the share to a single source account and source IP on the destination PC.

```powershell
pwsh -File scripts\destination-setup.ps1 `
    -AllowedSourceUser 'OLDPC\alice' `
    -AllowedSourceIP '192.168.1.50'
```

**Extra data + custom XML.** Include taskbar pins, Wi-Fi profiles, power plans, and the rules defined in `config\custom-migration.xml` (browsers, dev tools, SSH, Git, VSCode, etc.).

```powershell
pwsh -File scripts\source-capture.ps1 `
    -DestinationShare '\\NewPC\MigrationShare$' `
    -ExtraData
```

**Dry run.** Validate everything and print the scanstate command line without capturing.

```powershell
pwsh -File scripts\source-capture.ps1 `
    -DestinationShare '\\NewPC\MigrationShare$' -DryRun
```

## Troubleshooting

### Cannot reach `\\DEST-PC\MigrationShare$`
Run `scripts\destination-setup.ps1` on the destination PC first - the share does not exist until then. Confirm SMB ports 445 (and optionally 139) are open on the destination's firewall and that both PCs are in the same subnet or VLAN. If name resolution is unreliable, try the destination's IPv4 address in the UNC path: `\\192.168.1.50\MigrationShare$`.

### USMT not found
The source script tries to auto-install USMT via the ADK. If that fails (no internet, managed endpoint, etc.), drop a pre-downloaded USMT zip into one of the `USMT.SearchPaths` locations (for example `C:\USMT` or `%TEMP%\USMT-Tools`), or install the ADK manually and pick only the "User State Migration Tool" feature: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install.

### Capture stuck or slow
`scanstate.exe` can run for several hours on large profiles. Monitor real-time progress by watching the migration store grow: `Get-ChildItem \\DEST-PC\MigrationShare$\USMT -Recurse | Measure-Object -Property Length -Sum`. The inline spinner also prints a running file count and MB/s figure.

### UAC prompt cancelled
If the script is launched without elevation it re-launches itself via UAC. Clicking "No" at the prompt leaves no admin child running and the original window exits cleanly - no partial state is written. Re-run the batch file or script to retry.

### Encryption key forgotten
There is no recovery path. Migration stores created with `-EncryptStore` cannot be decrypted without the original key. Re-capture on the source PC with a fresh key and restore that new store.

### Everyone has access to the migration share
By default the hidden share is readable by `Everyone` on the local network (with file-system ACLs still guarding the contents). To restrict reads to a single source account, pass `-AllowedSourceUser <DOMAIN\user>` to `scripts\destination-setup.ps1`. Firewall scoping via `-AllowedSourceIP` is also available.

### Non-UTF-8 console renders progress bars as `?`
Progress bars and the braille spinner use Unicode glyphs. On legacy OEM codepages (437, 850) the UI auto-detects the console encoding and falls back to ASCII glyphs (`#`, `-`, and the classic `|/-\` spinner). No configuration needed - `Get-MigrationUIGlyphs` picks the right set per call.

### `Test-UncPath` rejects my share
The validator accepts `\\server\share` and `\\server\share$`, optionally followed by sub-paths. Paths with wildcards or any of `\ / : * ? " < > |` in the server or share segment are rejected on purpose. If the share name contains special characters, rename the share on the destination PC.

## Testing

Run the full Pester suite from the repo root:

```powershell
pwsh -File tests\Run-Tests.ps1
```

Useful options:

```powershell
pwsh -File tests\Run-Tests.ps1 -Filter 'destination'  # Subset by file name
pwsh -File tests\Run-Tests.ps1 -Output Detailed       # Verbose output
pwsh -File tests\Run-Tests.ps1 -CI                    # JUnit XML for CI
```

Expected baseline on Windows with Pester 5.x installed: **645 passed / 0 failed / 2 skipped**. The two skipped tests are environment-gated (long-running integration paths).

## Releases

Migration Merlin ships as a rolling release. Every commit that passes
lint, format, test, build, and package stages is published as a new
release automatically.

Version format: **YY.N** (two-digit year, dot, incremental within
the year). No `v` prefix. The current version is stored in the
`version` file at the repo root and bumped automatically by CI.

Examples: `26.1`, `26.2`, … `26.47`. A new year resets the counter:
`27.1`, `27.2`, …

Releases are tagged on `main`. Downloadable zip artifacts are
attached to each GitHub Release.

## License

See [`license.md`](license.md).

## About

Built on Microsoft's [User State Migration Tool (USMT)](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-overview).
