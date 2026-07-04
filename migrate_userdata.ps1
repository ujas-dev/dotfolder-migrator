<#
.SYNOPSIS
    Interactive migration tool for user dot folders with selective selection and reverse operations.

.DESCRIPTION
    Migrates user dot folders from C:\Users\<User> to a target location with symlinks.
    Supports interactive folder selection, unlink/reverse operations, and comprehensive safety features.

.PARAMETER TargetRoot
    Target directory for migrated dot folders (default: D:\UserData)

.PARAMETER DryRun
    Simulate migration without making actual changes (no admin required)

.PARAMETER WhatIf
    Show what would be migrated without prompts (no admin required)

.PARAMETER ListLinks
    List all currently linked dot folders and their targets

.PARAMETER Unlink
    Reverse migration - restore linked folders to original location

.PARAMETER Status
    Show comprehensive status of dot folders (ready, linked, protected)

.PARAMETER Folders
    Specify specific dot folders to migrate (comma-separated)

.PARAMETER AutoRemoveOrphans
    Remove dot folders with no matching installed app

.PARAMETER LogFile
    Custom log file path

.PARAMETER LogLevel
    0=Errors only, 1=Normal, 2=Verbose

.EXAMPLE
    .\migrate_userdata.ps1 -WhatIf
    Show migration plans without making changes

.EXAMPLE
    .\migrate_userdata.ps1 -DryRun -Folders ".vscode",".docker"
    Dry-run migration for specific folders only

.EXAMPLE
    .\migrate_userdata.ps1 -ListLinks
    Show all linked dot folders

.NOTES
    - Run as Administrator for actual migration.
    - ALWAYS run with -WhatIf or -DryRun first.
#>

param(
    [string]$TargetRoot = "D:\UserData",
    [switch]$DryRun,
    [switch]$WhatIf,
    [switch]$ListLinks,
    [switch]$Unlink,
    [switch]$Status,
    [string[]]$Folders = @(),
    [switch]$AutoRemoveOrphans,
    [string]$ConfigFile,
    [string]$LogFile = "",
    [int]$LogLevel = 1
)

# Normalize Folders parameter - handle comma-separated strings (PowerShell sometimes passes as single string)
$FoldersString = $Folders -join ","
if ($FoldersString -match ",") {
    $Folders = $FoldersString -split "," | ForEach-Object { $_.Trim() }
}

$ErrorActionPreference = "Stop"
$UserHome = $env:USERPROFILE
if (-not $LogFile) { $LogFile = Join-Path $TargetRoot "migration_log.txt" }

# ---------- UI Helpers ----------

function Write-Log {
    param([string]$msg, [string]$color = "White", [int]$level = 1)
    if ($level -le $LogLevel) {
        Write-Host $msg -ForegroundColor $color
    }
    if (-not (Test-Path $TargetRoot)) { New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null }
    "$(Get-Date -Format u)  $msg" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Write-Section($msg) { Write-Log "`n=== $msg ===" "Cyan" }

function Show-ProgressBar {
    param([int]$Current, [int]$Total, [string]$Activity)
    $percent = [math]::Round(($Current / $Total) * 100, 0)
    Write-Progress -Activity $Activity -Status "$Current of $Total" -PercentComplete $percent
}

# ---------- Detection Functions ----------

function Get-LinkedFolders {
    $linked = @{}
    Get-ChildItem -Path $UserHome -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like ".*" -and $_.PsIsContainer
    } | ForEach-Object {
        if ($_.LinkType -in @("SymbolicLink", "Junction")) {
            $target = try { $_.Target } catch { $_.LinkType }
            $linked[$_.Name] = $target
        }
    }
    return $linked
}

function Get-DotFolders {
    return Get-ChildItem -Path $UserHome -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ".*" -and $_.PsIsContainer -and $_.LinkType -eq $null } |
        Select-Object -ExpandProperty Name | Sort-Object
}

function Get-DotFolderSize {
    param([string]$Path)
    $files = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue
    return ($files | Measure-Object -Property Length -Sum).Sum
}

function Test-AppInstalled {
    param([string[]]$NamePatterns, [string[]]$CommandNames, [string[]]$PathHints)

    foreach ($hint in $PathHints) {
        if ($hint -and (Test-Path $hint)) { return $true }
    }
    foreach ($cmd in $CommandNames) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) { return $true }
    }
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($p in $uninstallPaths) {
        $apps = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
        foreach ($pattern in $NamePatterns) {
            if ($apps | Where-Object { $_.DisplayName -match $pattern }) { return $true }
        }
    }
    return $false
}

function Get-ProcessesUsingFolder {
    param([string]$FolderPath)
    $procMap = @{
        ".vscode"          = "Code"
        ".vscode-shared"   = "Code"
        ".antigravity-ide" = "Antigravity"
        ".docker"          = "Docker Desktop"
        ".gemini"          = "gemini"
        ".codex"           = "codex"
        ".copilot"         = "copilot"
        ".codeium"         = "codeium"
        ".openshot_qt"     = "openshot-qt"
    }
    $name = Split-Path $FolderPath -Leaf
    if ($procMap.ContainsKey($name)) {
        return Get-Process -Name $procMap[$name] -ErrorAction SilentlyContinue
    }
    return $null
}

function Stop-BlockingProcess {
    param([string]$FolderPath)
    $procs = Get-ProcessesUsingFolder -FolderPath $FolderPath
    if ($procs) {
        foreach ($p in $procs) {
            Write-Log "  Stopping running process '$($p.ProcessName)' (PID $($p.Id)) before migration..." "Yellow"
            if (-not $DryRun) {
                $p | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Seconds 2
    }
}

# ---------- Core Migration Functions ----------

function Move-FolderSafely {
    param([string]$SourcePath, [string]$DestPath, [string]$FolderName)

    $srcStats = Get-FolderStats -Path $SourcePath
    Write-Log "  Source: $($srcStats.Count) files, $([math]::Round($srcStats.Size/1MB,2)) MB"

    if (Test-Path $DestPath) {
        $destExists = Get-FolderStats -Path $DestPath
        Write-Log "  Target exists: $($destExists.Count) files, $([math]::Round($destExists.Size/1MB,2)) MB" "Yellow"
        if (-not $DryRun) {
            $confirm = Read-Host "  Overwrite existing target? (y/N)"
            if ($confirm -ne 'y') { return $false }
        }
    }

    if (-not $DryRun) {
        Write-Log "  Copying to $DestPath..." "Yellow"
        Copy-Item -Path $SourcePath -Destination $DestPath -Recurse -Force
        $destStats = Get-FolderStats -Path $DestPath
    } else {
        Write-Log "  [DRY-RUN] Would copy to $DestPath" "Cyan"
        $destStats = $srcStats
    }
    Write-Log "  Copied: $($destStats.Count) files, $([math]::Round($destStats.Size/1MB,2)) MB"

    if ($destStats.Count -ne $srcStats.Count -or $destStats.Size -ne $srcStats.Size) {
        Write-Log "  [FAIL] Copy verification mismatch for $FolderName." "Red"
        if (-not $DryRun) {
            Remove-Item -Path $DestPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $false
    }

    if (-not $DryRun) {
        Rename-Item -Path $SourcePath -NewName "$SourcePath.bak_pending" -ErrorAction Stop
        try {
            New-Item -ItemType SymbolicLink -Path $SourcePath -Target $DestPath -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Log "  [FAIL] Symlink creation failed for $FolderName. Restoring original." "Red"
            Rename-Item -Path "$SourcePath.bak_pending" -NewName $SourcePath -ErrorAction SilentlyContinue
            Remove-Item -Path $DestPath -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }

        $linkStats = Get-FolderStats -Path $SourcePath
        if ($linkStats.Count -ne $srcStats.Count) {
            Write-Log "  [FAIL] Symlink verification mismatch for $FolderName. Rolling back." "Red"
            Remove-Item -Path $SourcePath -Force -ErrorAction SilentlyContinue
            Rename-Item -Path "$SourcePath.bak_pending" -NewName $SourcePath -ErrorAction SilentlyContinue
            return $false
        }

        Remove-Item -Path "$SourcePath.bak_pending" -Recurse -Force
        Write-Log "  [OK] $FolderName migrated -> $DestPath" "Green"
    } else {
        Write-Log "  [DRY-RUN] Would rename original and create symlink to $DestPath" "Green"
    }
    return $true
}

function Get-FolderStats {
    param([string]$Path)
    $files = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue
    return @{ Count = $files.Count; Size = ($files | Measure-Object -Property Length -Sum).Sum }
}

# ---------- Interactive Selection ----------

function Show-FolderMenu {
    param([string[]]$Folders, [hashtable]$LinkedMap)

    Write-Host "`nAvailable dot folders for migration:" -ForegroundColor Cyan
    Write-Host "L = Linked, S = Skipped (no app), * = Ready to migrate" -ForegroundColor White
    Write-Host ""

    $indexMap = @{}
    for ($i = 0; $i -lt $Folders.Count; $i++) {
        $f = $Folders[$i]
        $status = ""
        if ($LinkedMap.ContainsKey($f)) {
            $status = "L"
        } elseif ($NeverDelete -contains $f) {
            $status = "S"
        } else {
            $status = "*"
        }
        Write-Host "[$($i+1)] [$status] $f"
        $indexMap[$i+1] = $f
    }
    return $indexMap
}

function Select-Folders {
    param([string[]]$Folders)

    $indexMap = Show-FolderMenu -Folders $Folders -LinkedMap (Get-LinkedFolders)
    $selection = @()

    Write-Host "`nSelect folders to migrate (comma-separated numbers, or 'all' or 'none'):"
    $input = Read-Host "> "

    if ($input -eq 'all') {
        return $Folders
    }
    if ($input -eq 'none') {
        return @()
    }

    $choices = $input -split ',' | ForEach-Object { $_.Trim() }
    foreach ($choice in $choices) {
        if ($indexMap.ContainsKey([int]$choice)) {
            $selection += $indexMap[[int]$choice]
        }
    }
    return $selection
}

# ---------- Unlink/Reverse Migration ----------

function Undo-Migration {
    param([string[]]$Folders, [bool]$RemoveTarget)

    Write-Section "Reversing migration (unlink)"
    $linked = Get-LinkedFolders
    $reversed = 0

    foreach ($folder in $Folders) {
        if (-not $linked.ContainsKey($folder)) { continue }

        $sourcePath = Join-Path $UserHome $folder
        $targetPath = $linked[$folder]

        Write-Log "[UNLINK] $folder -> $targetPath" "Yellow"

        if (-not $DryRun) {
            try {
                $targetItems = Get-ChildItem -Path $targetPath -Force -ErrorAction SilentlyContinue

                Remove-Item -Path $sourcePath -Force -ErrorAction Stop

                $restorePath = Join-Path $UserHome $folder
                if ($targetItems) {
                    Move-Item -Path $targetPath -Destination $restorePath -ErrorAction Stop
                }

                if ($RemoveTarget) {
                    Remove-Item -Path $targetPath -Recurse -Force -ErrorAction SilentlyContinue
                }
                $reversed++
                Write-Log "  [OK] Restored $folder to original location" "Green"
            } catch {
                Write-Log "  [FAIL] Could not unlink $folder`: $($_.Exception.Message)" "Red"
            }
        }
    }
    Write-Log "Reversed $reversed folders."
}

# ---------- Main Execution ----------

$FolderMap = @{
    ".vscode"          = @{ NamePatterns=@("Microsoft Visual Studio Code"); CommandNames=@("code"); PathHints=@("D:\WindowsPrograms\Microsoft VS Code") }
    ".vscode-shared"   = @{ NamePatterns=@("Microsoft Visual Studio Code"); CommandNames=@("code"); PathHints=@("D:\WindowsPrograms\Microsoft VS Code") }
    ".antigravity-ide" = @{ NamePatterns=@("Antigravity"); CommandNames=@("antigravity"); PathHints=@("D:\WindowsPrograms\Antigravity IDE") }
    ".docker"          = @{ NamePatterns=@("Docker Desktop"); CommandNames=@("docker"); PathHints=@("D:\WindowsPrograms\Docker\program") }
    ".gemini"          = @{ NamePatterns=@("Gemini CLI","Google Gemini"); CommandNames=@("gemini"); PathHints=@() }
    ".codex"           = @{ NamePatterns=@("OpenAI Codex","Codex CLI"); CommandNames=@("codex"); PathHints=@() }
    ".copilot"         = @{ NamePatterns=@("GitHub Copilot"); CommandNames=@("copilot","gh"); PathHints=@() }
    ".codeium"         = @{ NamePatterns=@("Codeium","Windsurf"); CommandNames=@("codeium"); PathHints=@() }
    ".openshot_qt"     = @{ NamePatterns=@("OpenShot Video Editor"); CommandNames=@("openshot-qt"); PathHints=@() }
    ".ssh"             = @{ NamePatterns=@("OpenSSH"); CommandNames=@("ssh","git"); PathHints=@() }
    ".cache"           = @{ NamePatterns=@(); CommandNames=@("npm","pip","node","python"); PathHints=@() }
    ".config"          = @{ NamePatterns=@(); CommandNames=@("npm","node","git"); PathHints=@() }
    ".local"           = @{ NamePatterns=@(); CommandNames=@("pip","python"); PathHints=@() }
    ".ms-ad"           = @{ NamePatterns=@("Microsoft Entra","Azure AD"); CommandNames=@(); PathHints=@() }
    ".npm"             = @{ NamePatterns=@(); CommandNames=@("npm"); PathHints=@() }
    ".pip"             = @{ NamePatterns=@(); CommandNames=@("pip"); PathHints=@() }
}
$NeverDelete = @(".ssh", ".config", ".cache", ".local", ".ms-ad")

# Handle -Status (show comprehensive status)
if ($Status) {
    Write-Section "UserData Migration Status"
    
    $dotFolders = Get-DotFolders
    $linked = Get-LinkedFolders
    $totalSize = 0
    
    Write-Log "User home: $UserHome"
    Write-Log "Target root: $TargetRoot"
    Write-Host ""
    
    $readyToMigrate = @()
    $alreadyLinked = @()
    $protected = @()
    
    foreach ($f in $dotFolders) {
        $sourcePath = Join-Path $UserHome $f
        $srcStats = Get-FolderStats -Path $sourcePath
        $size = $srcStats.Size
        $totalSize += $size
        
        if ($linked.ContainsKey($f)) {
            $alreadyLinked += [PSCustomObject]@{ Folder = $f; Target = $linked[$f]; Size = $size }
        } elseif ($NeverDelete -contains $f) {
            $protected += [PSCustomObject]@{ Folder = $f; Size = $size }
        } else {
            $readyToMigrate += [PSCustomObject]@{ Folder = $f; Size = $size }
        }
    }
    
    if ($alreadyLinked.Count -gt 0) {
        Write-Log "Already linked ($($alreadyLinked.Count) folders, $([math]::Round(($alreadyLinked | Measure-Object -Property Size -Sum).Sum/1MB,2)) MB):" "Green"
        $alreadyLinked | Sort-Object Folder | ForEach-Object { Write-Log "  $($_.Folder) -> $($_.Target)" }
    }
    
    if ($readyToMigrate.Count -gt 0) {
        Write-Log "`nReady to migrate ($($readyToMigrate.Count) folders, $([math]::Round(($readyToMigrate | Measure-Object -Property Size -Sum).Sum/1MB,2)) MB):" "Cyan"
        $readyToMigrate | Sort-Object Folder | ForEach-Object { Write-Log "  $($_.Folder)" }
    }
    
    if ($protected.Count -gt 0) {
        Write-Log "`nProtected (skipped) ($($protected.Count) folders, $([math]::Round(($protected | Measure-Object -Property Size -Sum).Sum/1MB,2)) MB):" "Yellow"
        $protected | Sort-Object Folder | ForEach-Object { Write-Log "  $($_.Folder)" }
    }
    
    Write-Log "`nTotal dot folder size: $([math]::Round($totalSize/1GB,4)) GB"
    exit 0
}

# Handle -WhatIf (dry-run show plans only)
if ($WhatIf) {
    $dotFolders = Get-DotFolders
    Write-Section "WhatIf: Migration plans (no changes will be made)"
    if ($dotFolders.Count -eq 0) {
        Write-Log "No dot folders found in user profile." "DarkGray"
    } else {
        $linked = Get-LinkedFolders
        foreach ($f in $dotFolders) {
            $sourcePath = Join-Path $UserHome $f
            $destPath = Join-Path $TargetRoot $f
            $srcStats = Get-FolderStats -Path $sourcePath
            if ($linked.ContainsKey($f)) {
                Write-Log "[SKIP] $f - already linked to $($linked[$f])" "DarkGray"
            } elseif ($NeverDelete -contains $f) {
                Write-Log "[KEEP] $f - protected folder (would skip)" "Yellow"
            } else {
                Write-Log "[MIGRATE] $f - $($srcStats.Count) files, $([math]::Round($srcStats.Size/1MB,2)) MB -> $destPath" "Green"
            }
        }
    }
    exit 0
}

# Handle -ListLinks (show all linked dot folders)
if ($ListLinks) {
    $linked = Get-LinkedFolders
    Write-Section "Linked dot folders"
    if ($linked.Count -eq 0) {
        Write-Log "No linked dot folders found." "DarkGray"
    } else {
        $linked.GetEnumerator() | Sort-Object Key | ForEach-Object {
            Write-Log "  $($_.Key) -> $($_.Value)"
        }
    }
    exit 0
}

# Handle -Unlink (reverse migration - restore linked folders to original location)
if ($Unlink) {
    $linked = Get-LinkedFolders
    if ($linked.Count -eq 0) {
        Write-Log "No linked folders to unlink." "DarkGray"
    } else {
        $toUnlink = if ($Folders -and $Folders.Count -gt 0) {
            $linked.Keys | Where-Object { $Folders -contains $_ }
        } else {
            $linked.Keys | Where-Object { $NeverDelete -notcontains $_ }
        }
        Undo-Migration -Folders $toUnlink -RemoveTarget $false
    }
    exit 0
}

# Pre-flight check (only require admin for actual operations)
Write-Section "Pre-flight checks"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Log "[ABORT] Must run as Administrator for actual migration." "Red"; exit 1
}
Write-Log "Running as Administrator: $(if($isAdmin){'Yes'}else{'No (dry-run mode)'})" "Green"
Write-Log "Target root: $TargetRoot"
Write-Log "Dry run: $DryRun"

# Interactive mode (skip if -Folders specified or dry-running)
$dotFolders = Get-DotFolders
$linked = Get-LinkedFolders
if ($dotFolders.Count -eq 0 -and $linked.Count -eq 0) {
    Write-Log "No dot folders found in user profile." "DarkGray"
    exit 0
}

# Build list of all dot folders (both regular and linked)
$allDotFolders = Get-ChildItem -Path $UserHome -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like ".*" -and $_.PsIsContainer } |
    Select-Object -ExpandProperty Name | Sort-Object

if ($Folders -and $Folders.Count -gt 0) {
    $selectedFolders = @()
    foreach ($f in $Folders) {
        $normalized = if ($f.StartsWith(".")) { $f } else { ".$f" }
        $allDotFolders | Where-Object { $_ -ieq $normalized } | ForEach-Object { $selectedFolders += $_ }
    }
$selectedFolders = $selectedFolders | Sort-Object -Unique
} elseif ($DryRun) {
    $selectedFolders = $dotFolders
    Write-Log "Dry-run mode: processing all eligible folders" "Yellow"
} else {
    $selectedFolders = Select-Folders -Folders $dotFolders
}
if ($selectedFolders.Count -eq 0) {
    Write-Log "No folders selected. Exiting." "DarkGray"
    exit 0
}

Write-Section "Migrating selected folders ($($selectedFolders.Count) folders)"
$results = @{}
$total = $selectedFolders.Count
$current = 0

foreach ($folderName in $selectedFolders) {
    $current++
    Show-ProgressBar -Current $current -Total $total -Activity "Migrating dot folders"

    $sourcePath = Join-Path $UserHome $folderName
    $rules = $FolderMap[$folderName]

    $isInstalled = if ($rules) {
        Test-AppInstalled -NamePatterns $rules.NamePatterns -CommandNames $rules.CommandNames -PathHints $rules.PathHints
    } else {
        $true
    }

    if (-not $isInstalled) {
        if ($folderName -in $NeverDelete) {
            Write-Log "[KEEP] $folderName - protected folder." "Yellow"
        } else {
            Write-Log "[ORPHAN] $folderName - no matching app installed." "Red"
            if ($AutoRemoveOrphans -and -not $DryRun) {
                Remove-Item -Path $sourcePath -Recurse -Force
                Write-Log "         Removed orphaned folder." "Red"
            }
        }
        continue
    }

    Stop-BlockingProcess -FolderPath $sourcePath
    $destPath = Join-Path $TargetRoot $folderName
    $ok = Move-FolderSafely -SourcePath $sourcePath -DestPath $destPath -FolderName $folderName
    $results[$folderName] = $ok
}

Write-Progress -Activity "Migrating dot folders" -Completed

Write-Section "Summary"
foreach ($k in $results.Keys) {
    $stat = if ($results[$k]) { "SUCCESS" } else { "FAILED" }
    Write-Log "$k : $stat"
}
Write-Log "Full log saved to $LogFile"