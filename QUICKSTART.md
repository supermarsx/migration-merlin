# USMT Migration Merlin - Quick Start

## Prerequisites

- Both PCs on the same network
- Administrator access on both PCs
- **USMT is auto-installed** if not present (downloads Windows ADK silently with just the USMT component)
- Manual install: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install (only "User State Migration Tool" needed)

## Step-by-Step

### 1. Destination PC (New PC) - Run First

Open PowerShell **as Administrator**:

```powershell
.\destination-setup.ps1
```

This will:
- Create `C:\MigrationStore` folder
- Create a hidden SMB share (`MigrationShare$`)
- Open firewall for SMB traffic
- Display the share path for the source PC

**Options:**
```powershell
# Custom folder location
.\destination-setup.ps1 -MigrationFolder "D:\Migration"

# Restrict access to a specific source IP
.\destination-setup.ps1 -AllowedSourceIP "192.168.1.50"

# Skip auto-install of USMT (just set up the share)
.\destination-setup.ps1 -SkipUSMTInstall
```

### 2. Source PC (Old PC) - Run Second

Open PowerShell **as Administrator**:

```powershell
# Use the share path shown by the destination script
.\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$"
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
.\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -ShareUsername "DEST-PC\Admin" -SharePassword "pass"

# Migrate only specific users
.\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -IncludeUsers "john","jane"

# Include extra data (Sticky Notes, taskbar pins, power settings)
.\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -ExtraData

# Dry run (shows what would happen without capturing)
.\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -DryRun

# Encrypt the migration store
.\source-capture.ps1 -DestinationShare "\\DEST-PC\MigrationShare$" -EncryptStore
```

### 3. Destination PC - Restore

After capture completes, back on the destination PC:

```powershell
.\destination-setup.ps1 -RestoreOnly
```

### 4. Verify Migration

```powershell
.\post-migration-verify.ps1
```

### 5. Clean Up

```powershell
.\destination-setup.ps1 -Cleanup
```

## What Gets Migrated

### USMT Built-in (MigDocs.xml + MigApp.xml)
- Documents, Desktop, Pictures, Music, Videos, Downloads, Favorites
- Windows settings (accessibility, mouse, keyboard, regional)
- Internet Explorer / Edge settings
- Wallpaper and display settings

### Custom XML (custom-migration.xml)
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
| `destination-setup.ps1` | Run on new PC - creates share, restores, cleans up |
| `source-capture.ps1` | Run on old PC - captures and transfers user state |
| `custom-migration.xml` | Extra USMT rules for browsers, dev tools, etc. |
| `post-migration-verify.ps1` | Validates migration success on destination |

## Troubleshooting

- **Can't connect to share**: Ensure both PCs are on the same network, firewall allows SMB (port 445), and the share name is correct (note the `$` makes it a hidden share)
- **ScanState errors**: Check `C:\MigrationStore\Logs\scanstate.log` on the destination share
- **LoadState errors**: Check `C:\MigrationStore\Logs\loadstate.log`
- **Access denied**: Run both scripts as Administrator; if the share needs credentials, use `-ShareUsername` and `-SharePassword`
- **Large profiles**: Ensure the destination drive has enough free space (the script warns if < 20GB)
