# UserData Migration Toolkit

Cross-platform tool for migrating user dot folders (dotfiles) to a custom location with automatic symlink management.

## Features

- **Cross-platform**: Works on Windows (PowerShell), Linux, and macOS (Bash)
- **Menu-driven interface**: All features accessible through interactive menus
- **WhatIf mode**: Preview migration plans before making changes
- **DryRun mode**: Simulate migration on all folders
- **ListLinks**: Show all linked dot folders and their targets
- **Unlink**: Restore linked folders to original location with selection menu
- **Status reporting**: Comprehensive status of dot folders (ready, linked, protected)
- **FixBroken**: Detect and remove broken/invalid symlinks
- **RemoveEmpty**: Remove empty dot folders
- **App detection**: Automatically skips orphaned folders (no installed app)
- **Protected folders**: Critical folders (.ssh, .config, .cache, .local) are protected
- **Progress tracking**: Visual progress during migration
- **Verification**: File count and size verification before/after migration
- **Rollback**: Automatic rollback on failure
- **Logging**: Detailed logs saved to migration_log.txt

## Supported Platforms

| Platform | Script |
|----------|--------|
| Windows  | `migrate_userdata.ps1` |
| Linux/macOS | `migrate_userdata.sh` |

## Quick Start

### Windows (PowerShell)

```powershell
# Run with bypass (no admin needed for WhatIf/ListLinks/Status)
powershell -ExecutionPolicy Bypass -File .\migrate_userdata.ps1

# Or set execution policy for current user (recommended)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
.\migrate_userdata.ps1
```

### Linux/macOS (Bash)

```bash
chmod +x migrate_userdata.sh
./migrate_userdata.sh
```

## Menu Options

When you run the script, you'll see:

```
=== UserData Migration Menu ===
  1) WhatIf      - Show migration plans (no changes)
  2) DryRun      - Simulate migration on all folders
  3) ListLinks   - Show all linked dot folders and targets
  4) Unlink      - Restore linked folders to original location
  5) Status      - Show comprehensive status
  6) FixBroken   - Fix broken symlinks
  7) RemoveEmpty - Remove empty dot folders
  8) Migrate     - Start interactive migration
  9) Exit
```

### WhatIf (Option 1)
Shows what would be migrated without making changes.

### DryRun (Option 2)
Simulates migration on all eligible folders.

### ListLinks (Option 3)
Shows list of dot folders that are currently linked and their target locations.

### Unlink (Option 4)
Shows list of linked folders, allows selection of which ones to restore.

### Status (Option 5)
Shows comprehensive status including ready/linked/protected folders.

### FixBroken (Option 6)
Finds and removes symlinks that point to non-existent targets.

### RemoveEmpty (Option 7)
Finds and removes empty dot folders (not linked or protected).

### Migrate (Option 8)
Interactive migration - select which folders to migrate.

## Protected Folders

The following folders are protected and will never be migrated:
- `.ssh`
- `.cache`
- `.local`

## App Detection

The script detects installed applications and only migrates folders for apps that are present:
- VS Code: `.vscode`, `.vscode-shared`
- Docker: `.docker`
- Antigravity IDE: `.antigravity-ide`
- Gemini CLI: `.gemini`
- Codex CLI: `.codex`
- GitHub Copilot: `.copilot`
- And more...

## Safety Features

1. **Pre-flight checks**: Validates administrator/root privileges
2. **File verification**: Compares file count and size before/after copy
3. **Symlink verification**: Confirms symlinks resolve correctly after migration
4. **Backup rollback**: Creates `.bak_pending` before migration, removes on success
5. **Process termination**: Stops processes using the folders before migration

## Windows Execution Policy

Windows blocks script execution by default. Choose one method:

```powershell
# Option 1: Set policy for current user (persistent, recommended)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# Option 2: Bypass for single execution
powershell -ExecutionPolicy Bypass -File .\migrate_userdata.ps1

# Option 3: Set policy for current session only
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## License

MIT License