#!/bin/bash
#
# SYNOPSIS
#     Interactive migration tool for user dot folders with selective selection and reverse operations.
#
# DESCRIPTION
#     Migrates user dot folders from $HOME to a target location with symlinks.
#     Supports interactive folder selection, unlink/reverse operations, and comprehensive safety features.
#
# USAGE
#     ./migrate_userdata.sh -WhatIf           # Show migration plans
#     ./migrate_userdata.sh -DryRun           # Simulate migration on all eligible folders
#     ./migrate_userdata.sh -ListLinks         # Show all linked dot folders
#     ./migrate_userdata.sh -Unlink           # Reverse migration
#     ./migrate_userdata.sh -Status           # Show comprehensive status
#     ./migrate_userdata.sh -Folders .aws,.azure,.gitlab  # Specific folders only
#
# NOTES
#     - Run with sudo for actual migration (symlink creation).
#     - Always run with -WhatIf or -DryRun first.

set -euo pipefail

# ---------- Configuration ----------
TARGET_ROOT="${TARGET_ROOT:-$HOME/UserData}"
WSL_TARGET="${WSL_TARGET:-$HOME/WindowsPrograms/WSL}"
LOG_FILE="${LOG_FILE:-$TARGET_ROOT/migration_log.txt}"
LOG_LEVEL="${LOG_LEVEL:-1}"

# ---------- Folder Definitions ----------
declare -A FOLDER_MAP
FOLDER_MAP[".vscode"]="code|visual-studio-code"
FOLDER_MAP[".vscode-shared"]="code|visual-studio-code"
FOLDER_MAP[".antigravity-ide"]="antigravity"
FOLDER_MAP[".docker"]="docker"
FOLDER_MAP[".gemini"]="gemini"
FOLDER_MAP[".codex"]="codex"
FOLDER_MAP[".copilot"]="copilot|gh"
FOLDER_MAP[".codeium"]="codeium|windsurf"
FOLDER_MAP[".openshot_qt"]="openshot-qt"
FOLDER_MAP[".ssh"]="ssh|git"
FOLDER_MAP[".cache"]="npm|pip|node|python"
FOLDER_MAP[".config"]="npm|node|git"
FOLDER_MAP[".local"]="pip|python"
FOLDER_MAP[".npm"]=""
FOLDER_MAP[".pip"]=""

NEVER_DELETE=(".ssh" ".config" ".cache" ".local")

# ---------- UI Helpers ----------

write_log() {
    local msg="$1"
    local color="${2:-white}"
    local level="${3:-1}"
    
    if [[ $level -le $LOG_LEVEL ]]; then
        case "$color" in
            red) tput setaf 1 ;;
            green) tput setaf 2 ;;
            yellow) tput setaf 3 ;;
            cyan) tput setaf 6 ;;
            darkgray) tput setaf 8 ;;
            *) tput sgr0 ;;
        esac
        echo "$msg"
        tput sgr0
    fi
    
    if [[ ! -d "$TARGET_ROOT" ]]; then
        mkdir -p "$TARGET_ROOT"
    fi
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ')  $msg" >> "$LOG_FILE"
}

write_section() {
    echo ""
    write_log "=== $1 ===" "cyan" 1
}

# ---------- Detection Functions ----------

get_linked_folders() {
    find "$HOME" -maxdepth 1 -type l -name ".*" -printf "%f|%l\n" 2>/dev/null | while IFS='|' read -r name target; do
        [[ -n "$name" ]] && echo "$name|$target"
    done
}

get_dot_folders() {
    find "$HOME" -maxdepth 1 -type d -name ".*" ! -name ".*" -prune 2>/dev/null | while read -r dir; do
        [[ -L "$dir" ]] || echo "$(basename "$dir")"
    done | sort
}

get_folder_stats() {
    local path="$1"
    local count size
    count=$(find "$path" -type f 2>/dev/null | wc -l)
    size=$(du -sb "$path" 2>/dev/null | cut -f1)
    echo "$count|$size"
}

test_app_installed() {
    local patterns="$1"
    local -a cmds=()
    
    IFS='|' read -ra cmds <<< "$patterns"
    for cmd in "${cmds[@]}"; do
        [[ -n "$cmd" ]] && command -v "$cmd" &>/dev/null && return 0
    done
    return 1
}

get_processes_using_folder() {
    local folder="$1"
    local proc_name=""
    
    case "$folder" in
        .vscode|.vscode-shared) proc_name="code" ;;
        .antigravity-ide) proc_name="antigravity" ;;
        .docker) proc_name="docker" ;;
        .gemini) proc_name="gemini" ;;
        .codex) proc_name="codex" ;;
        .copilot) proc_name="copilot" ;;
        .codeium) proc_name="codeium" ;;
        .openshot_qt) proc_name="openshot-qt" ;;
    esac
    
    [[ -n "$proc_name" ]] && pgrep -x "$proc_name" 2>/dev/null || true
}

stop_blocking_process() {
    local folder="$1"
    local source_path="$2"
    local procs
    procs=$(get_processes_using_folder "$folder")
    
    if [[ -n "$procs" ]]; then
        for pid in $procs; do
            write_log "  Stopping running process (PID $pid) before migration..." "yellow" 1
            [[ "$DRY_RUN" != "1" ]] && kill -9 "$pid" 2>/dev/null || true
        done
        sleep 2
    fi
}

# ---------- Core Migration Functions ----------

move_folder_safely() {
    local source_path="$1"
    local dest_path="$2"
    local folder_name="$3"
    
    local src_stats dest_stats
    src_stats=$(get_folder_stats "$source_path")
    IFS='|' read -r src_count src_size <<< "$src_stats"
    
    write_log "  Source: $src_count files, $(echo "scale=2; $src_size/1048576" | bc) MB"
    
    if [[ -d "$dest_path" || -L "$dest_path" ]]; then
        write_log "  Target exists - skipping" "yellow" 1
        return 0
    fi
    
    if [[ "$DRY_RUN" != "1" ]]; then
        write_log "  Copying to $dest_path..." "yellow" 1
        cp -a "$source_path"/. "$dest_path/" 2>/dev/null || mkdir -p "$dest_path" && cp -a "$source_path"/. "$dest_path/"
    else
        write_log "  [DRY-RUN] Would copy to $dest_path" "cyan" 1
    fi
    
    dest_stats=$(get_folder_stats "$dest_path")
    IFS='|' read -r dest_count dest_size <<< "$dest_stats"
    
    if [[ "$src_count" -ne "$dest_count" ]]; then
        write_log "  [FAIL] Copy verification mismatch for $folder_name." "red" 1
        [[ "$DRY_RUN" != "1" ]] && rm -rf "$dest_path"
        return 1
    fi
    
    if [[ "$DRY_RUN" != "1" ]]; then
        mv "$source_path" "${source_path}.bak_pending" 2>/dev/null || return 1
        ln -s "$dest_path" "$source_path" 2>/dev/null || {
            write_log "  [FAIL] Symlink creation failed for $folder_name. Restoring original." "red" 1
            mv "${source_path}.bak_pending" "$source_path" 2>/dev/null || true
            rm -rf "$dest_path"
            return 1
        }
        write_log "  [OK] $folder_name migrated -> $dest_path" "green" 1
    else
        write_log "  [DRY-RUN] Would rename original and create symlink to $dest_path" "green" 1
    fi
    return 0
}

# ---------- Unlink/Reverse Migration ----------

undo_migration() {
    local folders=("${@}")
    local linked reversed=0
    
    write_section "Reversing migration (unlink)"
    
    for folder in "${folders[@]}"; do
        local source_path="$HOME/$folder"
        local target_path
        target_path=$(get_linked_folders | grep "^$folder|" | cut -d'|' -f2)
        
        [[ -z "$target_path" ]] && continue
        
        write_log "[UNLINK] $folder -> $target_path" "yellow" 1
        
        if [[ "$DRY_RUN" != "1" ]]; then
            rm -f "$source_path" 2>/dev/null || continue
            [[ -d "$target_path" ]] && mv "$target_path" "$source_path" 2>/dev/null || true
            ((reversed++)) || true
            write_log "  [OK] Restored $folder to original location" "green" 1
        fi
    done
    write_log "Reversed $reversed folders."
}

# ---------- Main Functions ----------

show_status() {
    write_section "UserData Migration Status"
    
    write_log "User home: $HOME"
    write_log "Target root: $TARGET_ROOT"
    echo ""
    
    local dot_folders linked ready linked_count protected_count
    dot_folders=$(get_dot_folders)
    linked=$(get_linked_folders)
    
    local -a ready_to_migrate=() already_linked=() protected=()
    
    while IFS= read -r f; do
        local target_path
        target_path=$(echo "$linked" | grep "^$f|" | cut -d'|' -f2 || true)
        
        if [[ -n "$target_path" ]]; then
            already_linked+=("$f")
        elif [[ " ${NEVER_DELETE[*]} " =~ " $f " ]]; then
            protected+=("$f")
        else
            ready_to_migrate+=("$f")
        fi
    done <<< "$dot_folders"
    
    (( ${#already_linked[@]} )) > 0 && write_log "Already linked: ${already_linked[*]}" "green" 1
    (( ${#ready_to_migrate[@]} )) > 0 && write_log "Ready to migrate: ${ready_to_migrate[*]}" "cyan" 1
    (( ${#protected[@]} )) > 0 && write_log "Protected: ${protected[*]}" "yellow" 1
}

show_whatif() {
    write_section "WhatIf: Migration plans (no changes will be made)"
    
    local dot_folders linked
    dot_folders=$(get_dot_folders)
    linked=$(get_linked_folders)
    
    while IFS= read -r f; do
        local target_path
        target_path=$(echo "$linked" | grep "^$f|" | cut -d'|' -f2 || true)
        
        if [[ -n "$target_path" ]]; then
            write_log "[SKIP] $f - already linked to $target_path" "darkgray" 1
        elif [[ " ${NEVER_DELETE[*]} " =~ " $f " ]]; then
            write_log "[KEEP] $f - protected folder (would skip)" "yellow" 1
        else
            write_log "[MIGRATE] $f -> $TARGET_ROOT/$f" "green" 1
        fi
    done <<< "$dot_folders"
}

show_list_links() {
    write_section "Linked dot folders"
    
    local linked
    linked=$(get_linked_folders)
    
    if [[ -z "$linked" ]]; then
        write_log "No linked dot folders found." "darkgray" 1
    else
        echo "$linked" | while IFS='|' read -r name target; do
            write_log "  $name -> $target" "white" 1
        done
    fi
}

# ---------- Argument Parsing ----------

DRY_RUN=0
WHATIF=0
LISTLINKS=0
UNLINK=0
STATUS=0
FOLDERS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -DryRun) DRY_RUN=1; shift ;;
        -WhatIf) WHATIF=1; shift ;;
        -ListLinks) LISTLINKS=1; shift ;;
        -Unlink) UNLINK=1; shift ;;
        -Status) STATUS=1; shift ;;
        -Folders) FOLDERS="${2:-}"; shift 2 ;;
        -TargetRoot) TARGET_ROOT="$2"; shift 2 ;;
        -Help|--help|-h) echo "Usage: $0 [-DryRun|-WhatIf|-ListLinks|-Unlink|-Status|-Folders folder1,folder2]"; exit 0 ;;
        *) shift ;;
    esac
done

# ---------- Main Execution ----------

if [[ $LISTLINKS -eq 1 ]]; then
    show_list_links
    exit 0
fi

if [[ $STATUS -eq 1 ]]; then
    show_status
    exit 0
fi

if [[ $WHATIF -eq 1 ]]; then
    show_whatif
    exit 0
fi

if [[ $UNLINK -eq 1 ]]; then
    linked=$(get_linked_folders | cut -d'|' -f1 || true)
    [[ -z "$linked" ]] && write_log "No linked folders to unlink." "darkgray" 1 && exit 0
    
    if [[ -n "$FOLDERS" ]]; then
        IFS=',' read -ra to_unlink <<< "$FOLDERS"
    else
        IFS='|' read -ra to_unlink <<< "$linked"
    fi
    undo_migration "${to_unlink[@]}"
    exit 0
fi

# Normal migration mode
write_section "Pre-flight checks"
write_log "Running as: $(if [[ $EUID -eq 0 ]]; then echo 'root'; else echo 'user (dry-run mode)'; fi)" "green" 1
write_log "Target root: $TARGET_ROOT"
write_log "Dry run: $(if [[ $DRY_RUN -eq 1 ]]; then echo 'True'; else echo 'False'; fi)"

dot_folders=$(get_dot_folders)

if [[ -z "$dot_folders" ]]; then
    write_log "No dot folders found in user profile." "darkgray" 1
    exit 0
fi

# Select folders
if [[ -n "$FOLDERS" ]]; then
    IFS=',' read -ra selected_folders <<< "$FOLDERS"
else
    selected_folders=()
    echo ""
    write_log "Available dot folders for migration:" "cyan" 1
    i=1
    while IFS= read -r f; do
        echo "[$i] $f"
        ((i++)) || true
        selected_folders+=("$f")
    done <<< "$dot_folders"
    echo ""
    read -p "Select folders to migrate (comma-separated numbers, or 'all' or 'none'): " choice
    if [[ "$choice" == "all" ]]; then
        selected_folders=("${selected_folders[@]}")
    elif [[ "$choice" == "none" ]]; then
        selected_folders=()
    else
        selected_folders=()
        IFS=',' read -ra nums <<< "$choice"
        for n in "${nums[@]}"; do
            n=$(echo "$n" | tr -d ' ')
            [[ $n -gt 0 && $n -lt $i ]] && selected_folders+=("${selected_folders[$n-1]}")
        done
    fi
fi

if [[ ${#selected_folders[@]} -eq 0 ]]; then
    write_log "No folders selected. Exiting." "darkgray" 1
    exit 0
fi

write_section "Migrating selected folders (${#selected_folders[@]} folders)"

for folder in "${selected_folders[@]}"; do
    source_path="$HOME/$folder"
    patterns="${FOLDER_MAP[$folder]:-}"
    
    if [[ ! -d "$source_path" ]]; then
        continue
    fi
    
    if [[ " ${NEVER_DELETE[*]} " =~ " $folder " ]]; then
        write_log "[KEEP] $folder - protected folder." "yellow" 1
        continue
    fi
    
    if [[ -n "$patterns" ]] && ! test_app_installed "$patterns"; then
        write_log "[ORPHAN] $folder - no matching app installed." "red" 1
        continue
    fi
    
    stop_blocking_process "$folder" "$source_path"
    dest_path="$TARGET_ROOT/$folder"
    move_folder_safely "$source_path" "$dest_path" "$folder"
done

write_section "Summary"
write_log "Full log saved to $LOG_FILE"