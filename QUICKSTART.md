# USMT Migration Merlin - Quick Start

## Repo layout

```
migration-merlin\
  Migration-Merlin.ps1       # Interactive TUI launcher (stays at root)
  Migration-Merlin.bat       # Auto-elevating batch wrapper (stays at root)
  scripts\                   # Workflow PowerShell scripts (source/destination/verify)
  wrappers\                  # Numbered .bat wrappers for step-by-step runs
  modules\                   # Shared PowerShell modules (.psm1) and helpers
  config\                    # USMT XML rule files (e.g. custom-migration.xml)
  tests\                     # Pester test suite
```

## Prerequisites

- Both PCs on the same network
- Administrator access on both PCs
- **USMT is auto-installed** if not present (downloads Windows ADK silently with just the USMT component)
- Manual install: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install (only "User State Migration Tool" needed)

## Step-by-Step

### 1. Destination PC (New PC) - Run First

Open PowerShell **as Administrator**:

```powershell
.\scripts\destination-setup.ps1
```

This will:
- Create `C:\MigrationStore` folder
- Create a hidden SMB share (`MigrationShare$`)
- Open firewall for SMB traffic
- Display the share path for the source PC

**Options:**
```powershell
# Custom folder location
.\scripts\destination-setup.ps1 -MigrationFolder "D:\Migration"

# Restrict access to a specific source IP
.\scripts\destination-setup.ps1 -AllowedSourceIP "192.168.1.50"

# Skip auto-install of USMT (just set up the share)
.\scripts\destination-setup.ps1 -SkipUSMTInstall
```

### 2. Source PC (Old PC) - Run Second

Open PowerShell **as Administrator**:

```powershell
# Use the share path shown by the destination script
.\scripts\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$"
```

This will:
- Verify network connectivity to destination
- Map the share as a drive
- Inventory installed apps, printers, Wi-Fi profiles
- Run USMT ScanState to capture all user data
- Write a completion flag when done

**Options:**
```powershell
# With credentials for the share
.\scripts\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -ShareUsername "DEST-PC\Admin" -SharePassword "pass"

# Migrate only specific users
.\scripts\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -IncludeUsers "john","jane"

# Include extra data (Sticky Notes, taskbar pins, power settings)
.\scripts\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -ExtraData

# Dry run (shows what would happen without capturing)
.\scripts\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -DryRun

# Encrypt the migration store
.\scripts\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -EncryptStore
```

### 3. Destination PC - Restore

After capture completes, back on the destination PC:

```powershell
.\scripts\destination-setup.ps1 -RestoreOnly
```

### 4. Verify Migration

```powershell
.\scripts\post-migration-verify.ps1
```

### 5. Clean Up

```powershell
.\scripts\destination-setup.ps1 -Cleanup
```

## What Gets Migrated

### USMT Built-in (MigDocs.xml + MigApp.xml)
- Documents, Desktop, Pictures, Music, Videos, Downloads, Favorites
- Windows settings (accessibility, mouse, keyboard, regional)
- Internet Explorer / Edge settings
- Wallpaper and display settings

### Custom XML (config\custom-migration.xml)
- Chrome, Edge, Firefox bookmarks and settings
- Sticky Notes
- Outlook signatures and templates
- Projects/Source/Repos/Scripts/Work folders (excluding node_modules, .git, bin, obj)
- Windows Terminal settings
- PowerShell profiles
- SSH config and known_hosts
- Git config
- VSCode settings, keybindings, and snippets
- Quick Access / Recent files

### Extra Data (with -ExtraData flag)
- Taskbar pins
- Desktop shortcuts
- Power plan settings
- Wi-Fi profiles (exported with keys)
- Credential Manager listing

## Files

| File | Purpose |
|------|---------|
| `scripts\destination-setup.ps1` | Run on new PC - creates share, restores, cleans up |
| `scripts\source-capture.ps1` | Run on old PC - captures and transfers user state |
| `config\custom-migration.xml` | Extra USMT rules for browsers, dev tools, etc. |
| `scripts\post-migration-verify.ps1` | Validates migration success on destination |

## Troubleshooting

- **Can't connect to share**: Ensure both PCs are on the same network, firewall allows SMB (port 445), and the share name is correct (note the `$` makes it a hidden share)
- **ScanState errors**: Check `C:\MigrationStore\Logs\scanstate.log` on the destination share
- **LoadState errors**: Check `C:\MigrationStore\Logs\loadstate.log`
- **Access denied**: Run both scripts as Administrator; if the share needs credentials, use `-ShareUsername` and `-SharePassword`
- **Large profiles**: Ensure the destination drive has enough free space (the script warns if < 20GB)

### Cannot reach `\\DEST-PC\MigrationShare$`
Run `scripts\destination-setup.ps1` on the destination PC first - the share does not exist until then. Confirm SMB ports 445 (and optionally 139) are open on the destination's firewall and that both PCs are in the same subnet or VLAN. If name resolution is unreliable, try the destination's IPv4 address in the UNC path: `\\192.168.1.50\MigrationShare$`.

### USMT not found
The source script tries to auto-install USMT via the ADK. If that fails (no internet, managed endpoint, etc.), drop a pre-downloaded USMT zip into one of the `USMT.SearchPaths` locations (for example `C:\USMT` or `%TEMP%\USMT-Tools`), or install the ADK manually and pick only the "User State Migration Tool" feature: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install.

### Capture stuck / slow
`scanstate.exe` can run for several hours on large profiles. Monitor real-time progress by watching the migration store grow: `Get-ChildItem \\DEST-PC\MigrationShare$\USMT -Recurse | Measure-Object -Property Length -Sum`. The inline spinner also prints a running file count and MB/s figure.

### UAC prompt cancelled
If the script is launched without elevation it re-launches itself via UAC. Clicking "No" at the prompt leaves no admin child running and the original window exits cleanly - no partial state is written. Re-run the batch file or script to retry.

### Encryption key forgotten
There is no recovery path. Migration stores created with `-EncryptStore` cannot be decrypted without the original key. Re-capture on the source PC with a fresh key and restore that new store.

### Everyone has access to the migration share
By default the hidden share is readable by `Everyone` on the local network (with file-system ACLs still guarding the contents). To restrict reads to a single source account, pass `-AllowedSourceUser <DOMAIN\user>` to `scripts\destination-setup.ps1`. Firewall scoping via `-AllowedSourceIP` is also available.

### Non-UTF-8 console renders progress bars as `?`
Progress bars and the braille spinner use Unicode glyphs. On legacy OEM codepages (437, 850) the UI now auto-detects the console encoding and falls back to ASCII glyphs (`#`, `-`, and the classic `|/-\` spinner). No configuration needed - `Get-MigrationUIGlyphs` picks the right set per call.

### `Test-UncPath` rejects my share
The validator accepts `\\server\share` and `\\server\share$`, optionally followed by sub-paths. Paths with wildcards or any of `\ / : * ? " < > |` in the server or share segment are rejected on purpose. If the share name contains special characters, rename the share on the destination PC.
