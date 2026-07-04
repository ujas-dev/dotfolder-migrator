<#
.SYNOPSIS
    Interactive migration tool for user dot folders with selective selection and reverse operations.

.DESCRIPTION
    Migrates user dot folders from $HOME to a target location with symlinks.
    Menu-driven interface with all features in one unified script.

.NOTES
    - Run as Administrator for actual migration.
    - ALWAYS run with -WhatIf or -DryRun first.
#>

param(
    [string]$TargetRoot = "D:\UserData",
    [int]$LogLevel = 1
)

$ErrorActionPreference = "Stop"
$UserHome = $env:USERPROFILE
$LogFile = Join-Path $TargetRoot "migration_log.txt"

# ---------- UI Helpers ----------
function Write-Log {
    param([string]$msg, [string]$color = "White", [int]$level = 1)
    if ($level -le $LogLevel) { Write-Host $msg -ForegroundColor $color }
    if ($LogFile) {
        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        "$(Get-Date -Format u)  $msg" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

function Write-Section($msg) { Write-Log "`n=== $msg ===" "Cyan" }

# ---------- Detection Functions ----------
function Get-LinkedFolders {
    $linked = @{}
    Get-ChildItem -Path $UserHome -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like ".*" -and $_.PsIsContainer -and $_.LinkType -in @("SymbolicLink", "Junction")
    } | ForEach-Object {
        $target = try { $_.Target } catch { "" }
        $linked[$_.Name] = $target
    }
    return $linked
}

function Get-RegularFolders {
    return Get-ChildItem -Path $UserHome -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ".*" -and $_.PsIsContainer -and $_.LinkType -eq $null } |
        Select-Object -ExpandProperty Name | Sort-Object
}

function Get-FolderStats {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @{ Count = 0; Size = 0 } }
    $files = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue
    return @{ Count = $files.Count; Size = ($files | Measure-Object -Property Length -Sum).Sum }
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
}
$NeverDelete = @(".ssh", ".config", ".cache", ".local")

# ---------- Core Migration Functions ----------
function Move-FolderSafely {
    param([string]$SourcePath, [string]$DestPath, [string]$FolderName, [bool]$DryRun)
    
    $srcStats = Get-FolderStats -Path $SourcePath
    Write-Log "  Source: $($srcStats.Count) files, $([math]::Round($srcStats.Size/1MB,2)) MB"
    
    if (Test-Path $DestPath) {
        Write-Log "  Target exists - skipping (use -Force to overwrite)" "Yellow"
        return $true
    }
    
    if (-not $DryRun) {
        Copy-Item -Path $SourcePath -Destination $DestPath -Recurse -Force
        $destStats = Get-FolderStats -Path $DestPath
    } else {
        Write-Log "  [DRY-RUN] Would copy to $DestPath" "Cyan"
        $destStats = $srcStats
    }
    Write-Log "  Copied: $($destStats.Count) files, $([math]::Round($destStats.Size/1MB,2)) MB"
    
    if ($destStats.Count -ne $srcStats.Count) {
        Write-Log "  [FAIL] Copy verification mismatch for $FolderName." "Red"
        if (-not $DryRun) { Remove-Item -Path $DestPath -Recurse -Force }
        return $false
    }
    
    if (-not $DryRun) {
        Rename-Item -Path $SourcePath -NewName "$SourcePath.bak_pending" -ErrorAction Stop
        try {
            New-Item -ItemType SymbolicLink -Path $SourcePath -Target $DestPath -ErrorAction Stop | Out-Null
            Remove-Item -Path "$SourcePath.bak_pending" -Recurse -Force
            Write-Log "  [OK] $FolderName migrated -> $DestPath" "Green"
        } catch {
            Write-Log "  [FAIL] Symlink creation failed. Restoring." "Red"
            Rename-Item -Path "$SourcePath.bak_pending" -NewName $SourcePath -ErrorAction SilentlyContinue
            Remove-Item -Path $DestPath -Recurse -Force
            return $false
        }
    } else {
        Write-Log "  [DRY-RUN] Would rename and create symlink" "Green"
    }
    return $true
}

function Stop-BlockingProcess {
    param([string]$FolderPath, [bool]$DryRun)
    $procs = Get-ProcessesUsingFolder -FolderPath $FolderPath
    if ($procs) {
        foreach ($p in $procs) {
            Write-Log "  Stopping process '$($p.ProcessName)' (PID $($p.Id))..." "Yellow"
            if (-not $DryRun) { Stop-Process -Id $p.Id -Force }
        }
        Start-Sleep -Seconds 2
    }
}

function Undo-Migration {
    param([string[]]$Folders, [bool]$DryRun)
    Write-Section "Reversing migration (unlink)"
    $linked = Get-LinkedFolders
    $reversed = 0
    
    foreach ($folder in $Folders) {
        if (-not $linked.ContainsKey($folder)) { continue }
        $sourcePath = Join-Path $UserHome $folder
        $targetPath = $linked[$folder]
        
        Write-Log "[UNLINK] $folder -> $targetPath" "Yellow"
        
        if (-not $DryRun) {
            Stop-BlockingProcess -FolderPath $sourcePath -DryRun $false
            Start-Sleep -Seconds 3
            
            Remove-Item -Path $sourcePath -Force -ErrorAction SilentlyContinue
            
            if (Test-Path $targetPath) {
                try {
                    robocopy "$targetPath" "$sourcePath" /E /MOVE /R:2 /W:2 | Out-Null
                    $reversed++
                    Write-Log "  [OK] Restored $folder to original location" "Green"
                } catch {
                    Write-Log "  [FAIL] Could not restore $folder - file may be locked. Retry manually." "Red"
                }
            } else {
                Write-Log "  [WARN] Target already moved or missing for $folder" "Yellow"
            }
        }
    }
    Write-Log "Reversed $reversed folders."
}

# ---------- Menu Functions ----------
function Show-LinkedFoldersList {
    $linked = Get-LinkedFolders
    if ($linked.Count -eq 0) {
        Write-Log "No linked dot folders found." "DarkGray"
        return @{}
    }
    Write-Log "Linked dot folders:"
    $index = 1
    $indexMap = @{}
    foreach ($kvp in $linked.GetEnumerator()) {
        Write-Log "  [$index] $($kvp.Key) -> $($kvp.Value)"
        $indexMap[$index] = $kvp.Key
        $index++
    }
    return $indexMap
}

function Select-FromList {
    param([hashtable]$IndexMap, [string]$Prompt)
    Write-Host ""
    $input = Read-Host "$Prompt (comma-separated numbers, 'all', 'none', or 'menu')"
    
    if ($input -eq "menu") { return "menu" }
    if ($input -eq "none") { return @() }
    if ($input -eq "all") { return $IndexMap.Values }
    
    $selection = @()
    $input -split ',' | ForEach-Object {
        $num = [int]($_.Trim())
        if ($IndexMap.ContainsKey($num)) { $selection += $IndexMap[$num] }
    }
    return $selection
}

function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "=== UserData Migration Menu ===" -ForegroundColor Cyan
        Write-Host "  1) WhatIf      - Show migration plans (no changes)"
        Write-Host "  2) DryRun      - Simulate migration on all folders"
        Write-Host "  3) ListLinks   - Show all linked dot folders"
        Write-Host "  4) Unlink      - Restore linked folders to original location"
        Write-Host "  5) Status      - Show comprehensive status"
        Write-Host "  6) FixBroken   - Fix broken symlinks"
        Write-Host "  7) RemoveEmpty - Remove empty dot folders"
        Write-Host "  8) Migrate     - Start interactive migration"
        Write-Host "  9) Exit"
        $choice = Read-Host "Select option (1-9)"
        
        # Ask for target root on first run
        if (-not (Get-Variable -Name TargetRootAsked -ErrorAction SilentlyContinue)) {
            $custom = Read-Host "Enter target root path (press Enter for default: D:\UserData)"
            if ($custom) { $script:TargetRoot = $custom }
            $script:LogFile = Join-Path $script:TargetRoot "migration_log.txt"
            $script:TargetRootAsked = $true
        }
        
        switch ($choice) {
            "1" { 
                Write-Section "WhatIf: Migration plans (no changes will be made)"
                $folders = Get-RegularFolders
                $linked = Get-LinkedFolders
                foreach ($f in $folders) {
                    $stats = Get-FolderStats -Path (Join-Path $UserHome $f)
                    if ($linked.ContainsKey($f)) {
                        Write-Log "[SKIP] $f - already linked" "DarkGray"
                    } elseif ($NeverDelete -contains $f) {
                        Write-Log "[KEEP] $f - protected folder" "Yellow"
                    } else {
                        Write-Log "[MIGRATE] $f - $($stats.Count) files -> $TargetRoot\$f" "Green"
                    }
                }
            }
            
            "2" { 
                Write-Section "Dry-run: Processing all eligible folders"
                $folders = Get-RegularFolders
                $linked = Get-LinkedFolders
                foreach ($f in $folders) {
                    if ($linked.ContainsKey($f) -or $NeverDelete -contains $f) { continue }
                    $rules = $FolderMap[$f]
                    if ($rules -and -not (Test-AppInstalled -NamePatterns $rules.NamePatterns -CommandNames $rules.CommandNames -PathHints $rules.PathHints)) { continue }
                    $stats = Get-FolderStats -Path (Join-Path $UserHome $f)
                    Write-Log "  [DRY-RUN] $f - $($stats.Count) files -> $TargetRoot\$f" "Cyan"
                }
            }
            
            "3" { 
                Write-Section "Linked dot folders"
                Show-LinkedFoldersList | Out-Null
            }
            
            "4" { 
                Write-Section "Unlink: Select folders to restore"
                $indexMap = Show-LinkedFoldersList
                if ($indexMap.Count -gt 0) {
                    $selection = Select-FromList -IndexMap $indexMap -Prompt "Select folders to unlink"
                    if ($selection -eq "menu") { continue }
                    Undo-Migration -Folders $selection -DryRun $false
                }
            }
            
            "5" { 
                Write-Section "UserData Migration Status"
                Write-Log "User home: $UserHome"
                Write-Log "Target root: $TargetRoot"
                
                $regular = Get-RegularFolders
                $linked = Get-LinkedFolders
                $totalSize = 0
                
                $ready = @(); $already = @(); $protected = @()
                foreach ($f in $regular) {
                    $stats = Get-FolderStats -Path (Join-Path $UserHome $f)
                    $totalSize += $stats.Size
                    if ($linked.ContainsKey($f)) { $already += $f }
                    elseif ($NeverDelete -contains $f) { $protected += $f }
                    else { $ready += $f }
                }
                
                if ($already.Count -gt 0) { Write-Log "Already linked: $($already -join ', ')" "Green" }
                if ($ready.Count -gt 0) { Write-Log "Ready to migrate: $($ready -join ', ')" "Cyan" }
                if ($protected.Count -gt 0) { Write-Log "Protected: $($protected -join ', ')" "Yellow" }
                Write-Log "Total size: $([math]::Round($totalSize/1MB,2)) MB"
            }
            
            "6" { 
                Write-Section "Fixing broken symlinks"
                $allFolders = Get-ChildItem -Path $UserHome -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ".*" -and $_.PsIsContainer }
                $broken = 0
                foreach ($f in $allFolders) {
                    if ($f.LinkType -in @("SymbolicLink", "Junction")) {
                        $target = try { $f.Target } catch { "" }
                        if ($target -and -not (Test-Path $target)) {
                            Write-Log "[BROKEN] $($f.Name) -> $target (target missing)" "Red"
                            Remove-Item -Path $f.FullName -Force
                            Write-Log "  Removed broken symlink" "Green"
                            $broken++
                        }
                    }
                }
                Write-Log "Fixed $broken broken symlinks."
            }
            
            "7" { 
                Write-Section "Removing empty dot folders"
                $allFolders = Get-ChildItem -Path $UserHome -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ".*" -and $_.PsIsContainer -and $_.LinkType -eq $null }
                $removed = 0
                foreach ($f in $allFolders) {
                    $itemCount = (Get-ChildItem -Path $f.FullName -Force -ErrorAction SilentlyContinue | Measure-Object).Count
                    if ($itemCount -eq 0) {
                        Write-Log "[EMPTY] $($f.Name) - removing" "Yellow"
                        Remove-Item -Path $f.FullName -Force
                        $removed++
                    }
                }
                Write-Log "Removed $removed empty dot folders."
            }
            
            "8" { 
                Write-Section "Interactive Migration"
                $folders = Get-RegularFolders
                $linked = Get-LinkedFolders
                $indexMap = @{}
                $index = 1
                Write-Host ""
                Write-Host "Available dot folders:"
                foreach ($f in $folders) {
                    if ($linked.ContainsKey($f) -or $NeverDelete -contains $f) { continue }
                    
                    $rules = $FolderMap[$f]
                    $appDetected = $true
                    if ($rules) {
                        $appDetected = Test-AppInstalled -NamePatterns $rules.NamePatterns -CommandNames $rules.CommandNames -PathHints $rules.PathHints
                    }
                    
                    if ($appDetected) {
                        Write-Host "[$index] $f (app detected)"
                    } else {
                        Write-Host "[$index] $f (unknown/orphan - will migrate anyway)" -ForegroundColor Yellow
                    }
                    $indexMap[$index] = $f
                    $index++
                }
                if ($indexMap.Count -eq 0) {
                    Write-Log "No folders available for migration." "DarkGray"
                    continue
                }
                $selection = Select-FromList -IndexMap $indexMap -Prompt "Select folders to migrate"
                if ($selection -eq "menu") { continue }
                
                foreach ($f in $selection) {
                    $source = Join-Path $UserHome $f
                    $dest = Join-Path $TargetRoot $f
                    Stop-BlockingProcess -FolderPath $source -DryRun $false
                    Move-FolderSafely -SourcePath $source -DestPath $dest -FolderName $f -DryRun $false
                }
            }
            
            "9" { return }
            default { Write-Log "Invalid option. Try again." "Red" }
        }
    }
}

# Run menu
Show-Menu