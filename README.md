# UserData Migration Toolkit

Cross-platform tool for migrating user dot folders (dotfiles) to a custom location with automatic symlink management.

## Features

- **Cross-platform**: Works on Windows (PowerShell), Linux, and macOS (Bash)
- **Interactive selection**: Choose which dot folders to migrate
- **Dry-run support**: Preview changes before applying them
- **WhatIf mode**: Show migration plans without prompts
- **Status reporting**: Comprehensive status of dot folders
- **Reverse migration**: Unlink and restore folders to original location
- **App detection**: Automatically skips orphaned folders (no installed app)
- **Protected folders**: Critical folders (.ssh, .config, .cache, .local) are protected
- **Progress tracking**: Visual progress bar during migration
- **Verification**: File count and size verification before/after migration
- **Rollback**: Automatic rollback on failure
- **Logging**: Detailed logs saved to migration_log.txt

## Supported Platforms

| Platform | Script |
|----------|--------|
| Windows  | `migrate_userdata.ps1` |
| Linux/macOS | `migrate_userdata.sh` |

## Usage

### Windows (PowerShell)

```powershell
# Show what would be migrated
.\migrate_userdata.ps1 -WhatIf

# Dry-run migration on specific folders
.\migrate_userdata.ps1 -DryRun -Folders ".vscode",".docker"

# List all linked dot folders
.\migrate_userdata.ps1 -ListLinks

# Reverse migration (unlink)
.\migrate_userdata.ps1 -Unlink

# Show comprehensive status
.\migrate_userdata.ps1 -Status

# Interactive migration (requires admin)
.\migrate_userdata.ps1
```

### Linux/macOS (Bash)

```bash
# Show what would be migrated
./migrate_userdata.sh -WhatIf

# Dry-run migration on specific folders
./migrate_userdata.sh -DryRun -Folders .vscode,.docker

# List all linked dot folders
./migrate_userdata.sh -ListLinks

# Reverse migration (unlink)
./migrate_userdata.sh -Unlink

# Show comprehensive status
./migrate_userdata.sh -Status

# Interactive migration
./migrate_userdata.sh
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-TargetRoot` | Target directory for migrated dot folders (default: `D:\UserData` on Windows, `~/UserData` on Unix) |
| `-DryRun` | Simulate migration without making actual changes |
| `-WhatIf` | Show what would be migrated without prompts |
| `-ListLinks` | List all currently linked dot folders and their targets |
| `-Unlink` | Reverse migration - restore linked folders to original location |
| `-Status` | Show comprehensive status of dot folders |
| `-Folders` | Specify specific dot folders to migrate (comma-separated) |
| `-LogLevel` | 0=Errors only, 1=Normal (default), 2=Verbose |
| `-Help` | Show help message |

## Protected Folders

The following folders are protected and will never be migrated:
- `.ssh`
- `.config`
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
6. **Dry-run mode**: Test without making changes

## Setup

### Windows

By default, Windows blocks script execution for security. To allow the script to run:

```powershell
# Option 1: Set execution policy for current user (recommended)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# Option 2: Run with bypass for single execution
powershell -ExecutionPolicy Bypass -File .\migrate_userdata.ps1 -WhatIf

# Option 3: Set execution policy for current process only
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\migrate_userdata.ps1 -WhatIf
```

### Linux/macOS
```bash
chmod +x migrate_userdata.sh
./migrate_userdata.sh -WhatIf
```

## License

MIT License