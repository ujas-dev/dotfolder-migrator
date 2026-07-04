#!/bin/bash
#
# UserData Migration Toolkit - Linux/macOS Version
# Menu-driven interactive migration tool for user dot folders
#

set -euo pipefail

# ---------- Configuration ----------
TARGET_ROOT="${TARGET_ROOT:-$HOME/UserData}"
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

NEVER_DELETE=(".ssh" ".config" ".cache" ".local")

# ---------- UI Helpers ----------
write_log() {
    local msg="$1"
    local color="${2:-white}"
    local level="${3:-1}"
    
    [[ $level -le $LOG_LEVEL ]] && {
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
    }
    
    [[ ! -d "$TARGET_ROOT" ]] && mkdir -p "$TARGET_ROOT"
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ')  $msg" >> "$LOG_FILE"
}

write_section() {
    echo ""
    write_log "=== $1 ===" "cyan" 1
}

# ---------- Detection Functions ----------
get_linked_folders() {
    find "$HOME" -maxdepth 1 -type l -name ".*" -printf "%f|%l\n" 2>/dev/null || true
}

get_regular_folders() {
    find "$HOME" -maxdepth 1 -mindepth 1 -maxdepth 1 -type d -name ".*" -printf "%f\n" 2>/dev/null | while read -r name; do
        [[ ! -L "$HOME/$name" ]] && echo "$name"
    done
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
    IFS='|' read -ra cmds <<< "$patterns"
    for cmd in "${cmds[@]}"; do
        [[ -n "$cmd" ]] && command -v "$cmd" &>/dev/null && return 0
    done
    return 1
}

# ---------- Core Migration ----------
move_folder_safely() {
    local source_path="$1"
    local dest_path="$2"
    local folder_name="$3"
    
    local src_stats dest_stats
    src_stats=$(get_folder_stats "$source_path")
    IFS='|' read -r src_count src_size <<< "$src_stats"
    
    write_log "  Source: $src_count files, $(echo "scale=2; $src_size/1048576" | bc) MB"
    
    [[ -d "$dest_path" ]] && write_log "  Target exists - skipping" "yellow" && return 0
    
    if [[ "$DRY_RUN" != "1" ]]; then
        cp -a "${source_path}/." "${dest_path}/" 2>/dev/null || mkdir -p "$dest_path"
        dest_stats=$(get_folder_stats "$dest_path")
    else
        write_log "  [DRY-RUN] Would copy to $dest_path" "cyan"
        dest_stats="$src_stats"
    fi
    
    IFS='|' read -r dest_count dest_size <<< "$dest_stats"
    
    [[ "$src_count" -ne "$dest_count" ]] && write_log "  [FAIL] Copy mismatch" "red" && return 1
    
    if [[ "$DRY_RUN" != "1" ]]; then
        mv "$source_path" "${source_path}.bak_pending" 2>/dev/null || return 1
        ln -s "$dest_path" "$source_path" 2>/dev/null || {
            write_log "  [FAIL] Symlink failed" "red"
            mv "${source_path}.bak_pending" "$source_path" 2>/dev/null || true
            rm -rf "$dest_path"
            return 1
        }
        write_log "  [OK] $folder_name migrated -> $dest_path" "green"
    else
        write_log "  [DRY-RUN] Would create symlink" "green"
    fi
    return 0
}

# ---------- Menu Functions ----------
show_linked_folders() {
    write_section "Linked dot folders"
    local linked
    linked=$(get_linked_folders)
    [[ -z "$linked" ]] && write_log "No linked dot folders found." "darkgray" && return
    
    echo "$linked" | while IFS='|' read -r name target; do
        write_log "  $name -> $target" "white" 1
    done
}

show_whatif() {
    write_section "WhatIf: Migration plans (no changes will be made)"
    local linked regular
    linked=$(get_linked_folders)
    regular=$(get_regular_folders)
    
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local stats target_path
        stats=$(get_folder_stats "$HOME/$f")
        IFS='|' read -r count size <<< "$stats"
        
        target_path=$(echo "$linked" | grep "^$f|" | cut -d'|' -f2 || true)
        
        if [[ -n "$target_path" ]]; then
            write_log "[SKIP] $f - already linked" "darkgray" 1
        elif [[ " ${NEVER_DELETE[*]} " =~ " $f " ]]; then
            write_log "[KEEP] $f - protected folder" "yellow" 1
        else
            local patterns="${FOLDER_MAP[$f]:-}"
            [[ -n "$patterns" ]] && ! test_app_installed "$patterns" && continue
            write_log "[MIGRATE] $f - $count files -> $TARGET_ROOT/$f" "green" 1
        fi
    done <<< "$regular"
}

show_status() {
    write_section "UserData Migration Status"
    write_log "User home: $HOME"
    write_log "Target root: $TARGET_ROOT"
    
    local linked regular ready already protected
    linked=$(get_linked_folders)
    regular=$(get_regular_folders)
    
    ready="" already="" protected=""
    
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        target_path=$(echo "$linked" | grep "^$f|" | cut -d'|' -f2 || true)
        if [[ -n "$target_path" ]]; then
            already="$already $f"
        elif [[ " ${NEVER_DELETE[*]} " =~ " $f " ]]; then
            protected="$protected $f"
        else
            local patterns="${FOLDER_MAP[$f]:-}"
            [[ -n "$patterns" ]] && ! test_app_installed "$patterns" && continue
            ready="$ready $f"
        fi
    done <<< "$regular"
    
    [[ -n "$already" ]] && write_log "Already linked:$already" "green" 1
    [[ -n "$ready" ]] && write_log "Ready to migrate:$ready" "cyan" 1
    [[ -n "$protected" ]] && write_log "Protected:$protected" "yellow" 1
}

fix_broken_links() {
    write_section "Fixing broken symlinks"
    local broken=0
    
    find "$HOME" -maxdepth 1 -type l -name ".*" 2>/dev/null | while read -r link; do
        [[ ! -e "$link" ]] && {
            local name target
            name=$(basename "$link")
            target=$(readlink "$link" 2>/dev/null || true)
            write_log "[BROKEN] $name -> $target (target missing)" "red" 1
            rm -f "$link"
            write_log "  Removed broken symlink" "green" 1
            ((broken++)) || true
        }
    done
    write_log "Fixed $broken broken symlinks."
}

unlink_folders() {
    write_section "Unlink: Select folders to restore"
    local linked
    linked=$(get_linked_folders)
    
    if [[ -z "$linked" ]]; then
        write_log "No linked folders found." "darkgray"
        return
    fi
    
    echo "$linked" | while IFS='|' read -r name target; do
        [[ -z "$name" ]] && continue
        [[ " ${NEVER_DELETE[*]} " =~ " $name " ]] && continue
        write_log "$name -> $target" "white" 1
    done
    
    read -p "Select folders to unlink (comma-separated numbers, 'all', 'none', or 'menu'): " choice
    [[ "$choice" == "menu" ]] && return
    [[ "$choice" == "none" ]] && return
}

remove_empty_folders() {
    write_section "Removing empty dot folders"
    local removed=0
    
    find "$HOME" -maxdepth 1 -mindepth 1 -maxdepth 1 -type d -name ".*" -print0 2>/dev/null | while IFS= read -r -d '' dir; do
        local name target
        name=$(basename "$dir")
        target=$(readlink "$dir" 2>/dev/null || true)
        
        # Skip symlinks
        [[ -n "$target" ]] && continue
        
        # Skip protected
        [[ " ${NEVER_DELETE[*]} " =~ " $name " ]] && continue
        
        local count
        count=$(find "$dir" -mindepth 1 2>/dev/null | wc -l)
        if [[ $count -eq 0 ]]; then
            write_log "[EMPTY] $name - removing" "yellow" 1
            rm -rf "$dir"
            ((removed++)) || true
        fi
    done
    write_log "Removed $removed empty dot folders."
}

do_migration() {
    write_section "Interactive Migration"
    write_log "Target root: $TARGET_ROOT"
    
    local regular linked index=1 index_map=()
    regular=$(get_regular_folders)
    linked=$(get_linked_folders)
    
    echo ""
    echo "Available dot folders:"
    
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ " ${NEVER_DELETE[*]} " =~ " $f " ]] && continue
        local target=$(echo "$linked" | grep "^$f|" | cut -d'|' -f2 || true)
        [[ -n "$target" ]] && continue
        
        # Check if app is detected
        local patterns="${FOLDER_MAP[$f]:-}"
        local app_detected=1
        if [[ -n "$patterns" ]]; then
            test_app_installed "$patterns" || app_detected=0
        fi
        
        if [[ $app_detected -eq 1 ]]; then
            echo "[$index] $f (app detected)"
        else
            echo "[$index] $f (unknown/orphan - will migrate anyway)" | sed 's/^/\\033[33m/; s/$/\\033[0m/'
        fi
        index_map[$index]=$f
        ((index++)) || true
    done <<< "$regular"
    
    if [[ ${#index_map[@]} -eq 0 ]]; then
        write_log "No folders available for migration." "darkgray"
        return
    fi
    
    read -p "Select folders to migrate (comma-separated numbers, 'all', 'none', or 'menu'): " choice
    [[ "$choice" == "menu" ]] && return
    [[ "$choice" == "none" ]] && return
}

# ---------- Main Loop ----------
while true; do
    echo ""
    echo "=== UserData Migration Menu ===" | sed 's/^/\\033[36m/; s/$/\\033[0m/'
    echo "  1) WhatIf      - Show migration plans (no changes)"
    echo "  2) DryRun      - Simulate migration on all folders"
    echo "  3) ListLinks   - Show all linked dot folders"
    echo "  4) Unlink      - Restore linked folders to original location"
    echo "  5) Status      - Show comprehensive status"
    echo "  6) FixBroken   - Fix broken symlinks"
    echo "  7) RemoveEmpty - Remove empty dot folders"
    echo "  8) Migrate     - Start interactive migration"
    echo "  9) Exit"
    
    read -p "Select option (1-9): " choice
    
    case "$choice" in
        1) show_whatif ;;
        2) DRY_RUN=1; do_migration ;;
        3) show_linked_folders ;;
        4) unlink_folders ;;
        5) show_status ;;
        6) fix_broken_links ;;
        7) remove_empty_folders ;;
        8) do_migration ;;
        9) exit 0 ;;
        *) write_log "Invalid option. Try again." "red" 1 ;;
    esac
done