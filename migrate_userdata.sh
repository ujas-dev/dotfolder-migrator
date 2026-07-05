#!/bin/bash
#
# UserData Migration Toolkit - Linux/macOS Version
# Menu-driven interactive migration tool for user dot folders
# NOTE: Run with sudo if symlinks require elevated permissions.
#       ALWAYS try --dry-run first.
#

set -euo pipefail

# ---------- Configuration ----------
usage() {
    echo "Usage: $0 [--target-root PATH] [--log-level N] [--dry-run]"
    echo ""
    echo "  --target-root PATH   Target directory for migrated data (default: \$HOME/UserData)"
    echo "  --log-level N        Logging verbosity 0-2 (default: 1)"
    echo "  --dry-run            Simulate without making changes"
    echo ""
    echo "Examples:"
    echo "  $0                                  # Interactive menu"
    echo "  $0 --dry-run                        # Simulate first"
    echo "  $0 --target-root /mnt/data/UserData  # Custom target"
    exit 1
}

TARGET_ROOT="${HOME}/UserData"
LOG_LEVEL=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-root) TARGET_ROOT="$2"; shift 2 ;;
        --log-level)   LOG_LEVEL="$2";   shift 2 ;;
        --dry-run)     DRY_RUN=1;        shift 1 ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

LOG_FILE="${TARGET_ROOT}/migration_log.txt"

# ---------- Folder Definitions ----------
declare -A FOLDER_MAP
declare -A FOLDER_PATH_HINTS
FOLDER_MAP[".vscode"]="code|visual-studio-code"
FOLDER_PATH_HINTS[".vscode"]="/usr/share/code /usr/local/share/code"
FOLDER_MAP[".vscode-shared"]="code|visual-studio-code"
FOLDER_PATH_HINTS[".vscode-shared"]="/usr/share/code /usr/local/share/code"
FOLDER_MAP[".antigravity-ide"]="antigravity"
FOLDER_PATH_HINTS[".antigravity-ide"]="/opt/Antigravity /usr/local/bin/antigravity"
FOLDER_MAP[".docker"]="docker"
FOLDER_PATH_HINTS[".docker"]="/usr/bin/docker /var/lib/docker"
FOLDER_MAP[".gemini"]="gemini"
FOLDER_PATH_HINTS[".gemini"]=""
FOLDER_MAP[".codex"]="codex"
FOLDER_PATH_HINTS[".codex"]=""
FOLDER_MAP[".copilot"]="copilot|gh"
FOLDER_PATH_HINTS[".copilot"]=""
FOLDER_MAP[".codeium"]="codeium|windsurf"
FOLDER_PATH_HINTS[".codeium"]=""
FOLDER_MAP[".openshot_qt"]="openshot-qt"
FOLDER_PATH_HINTS[".openshot_qt"]=""
FOLDER_MAP[".ssh"]="ssh|git"
FOLDER_PATH_HINTS[".ssh"]=""
FOLDER_MAP[".cache"]="npm|pip|node|python"
FOLDER_PATH_HINTS[".cache"]=""
FOLDER_MAP[".config"]="npm|node|git"
FOLDER_PATH_HINTS[".config"]=""
FOLDER_MAP[".local"]="pip|python"
FOLDER_PATH_HINTS[".local"]=""

NEVER_DELETE=(".ssh" ".cache" ".local")

# ---------- Process Map (processes that lock dot folders) ----------
declare -A PROCESS_MAP
PROCESS_MAP[".vscode"]="code"
PROCESS_MAP[".vscode-shared"]="code"
PROCESS_MAP[".antigravity-ide"]="antigravity"
PROCESS_MAP[".docker"]="docker"
PROCESS_MAP[".gemini"]="gemini"
PROCESS_MAP[".codex"]="codex"
PROCESS_MAP[".copilot"]="copilot"
PROCESS_MAP[".codeium"]="codeium"
PROCESS_MAP[".openshot_qt"]="openshot-qt"

# ---------- UI Helpers ----------
write_log() {
    local msg="$1"
    local color="${2:-white}"
    local level="${3:-1}"

    if [[ "$level" -le "$LOG_LEVEL" ]]; then
        case "$color" in
            red)      echo -e "\033[31m$msg\033[0m" ;;
            green)    echo -e "\033[32m$msg\033[0m" ;;
            yellow)   echo -e "\033[33m$msg\033[0m" ;;
            cyan)     echo -e "\033[36m$msg\033[0m" ;;
            darkgray) echo -e "\033[90m$msg\033[0m" ;;
            *)        echo "$msg" ;;
        esac
    fi

    if [[ ! -d "$TARGET_ROOT" ]]; then
        mkdir -p "$TARGET_ROOT" 2>/dev/null || true
    fi
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ')  $msg" >> "$LOG_FILE"
}

write_section() {
    echo ""
    write_log "=== $1 ===" "cyan" 1
}

# ---------- Detection Functions ----------
get_linked_folders() {
    # Returns tab-separated: name<TAB>target (one per line)
    local name target
    for entry in "$HOME"/.*; do
        [[ ! -e "$entry" ]] && continue
        [[ ! -L "$entry" ]] && continue
        name=$(basename "$entry")
        target=$(readlink "$entry" 2>/dev/null || echo "")
        echo -e "${name}\t${target}"
    done
}

get_regular_folders() {
    for entry in "$HOME"/.*; do
        [[ ! -e "$entry" ]] && continue
        [[ ! -d "$entry" ]] && continue
        [[ -L "$entry" ]] && continue
        basename "$entry"
    done | sort
}

get_folder_stats() {
    local path="$1"
    local count size
    if [[ ! -d "$path" ]]; then
        echo "0|0"
        return
    fi
    count=$(find "$path" -type f 2>/dev/null | wc -l)
    size=$(du -sb "$path" 2>/dev/null | cut -f1)
    size=${size:-0}
    echo "$count|$size"
}

test_app_installed() {
    local folder_name="$1"
    local patterns="${FOLDER_MAP[$folder_name]:-}"
    local path_hints="${FOLDER_PATH_HINTS[$folder_name]:-}"

    # Check path hints first
    if [[ -n "$path_hints" ]]; then
        for hint in $path_hints; do
            [[ -e "$hint" ]] && return 0
        done
    fi

    # Check commands
    if [[ -n "$patterns" ]]; then
        local saved_ifs="$IFS"
        IFS='|'
        for cmd in $patterns; do
            [[ -n "$cmd" ]] && command -v "$cmd" &>/dev/null && IFS="$saved_ifs" && return 0
        done
        IFS="$saved_ifs"
    fi

    return 1
}

get_processes_using_folder() {
    local folder_name="$1"
    local proc_name="${PROCESS_MAP[$folder_name]:-}"
    if [[ -n "$proc_name" ]]; then
        pgrep -f "$proc_name" 2>/dev/null || true
    fi
}

# ---------- Core Migration ----------
move_folder_safely() {
    local source_path="$1"
    local dest_path="$2"
    local folder_name="$3"

    local src_stats dest_stats src_count src_size dest_count dest_size
    src_stats=$(get_folder_stats "$source_path")
    IFS='|' read -r src_count src_size <<< "$src_stats"
    src_size_mb=$(awk "BEGIN {printf \"%.2f\", $src_size/1048576}")

    write_log "  Source: $src_count files, ${src_size_mb} MB"

    if [[ -d "$dest_path" ]]; then
        write_log "  Target exists - skipping (use -Force to overwrite)" "yellow"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        write_log "  [DRY-RUN] Would copy to $dest_path" "cyan"
        write_log "  [DRY-RUN] Would rename and create symlink" "green"
        return 0
    fi

    cp -a "${source_path}" "${dest_path}" 2>/dev/null
    dest_stats=$(get_folder_stats "$dest_path")
    IFS='|' read -r dest_count dest_size <<< "$dest_stats"
    dest_size_mb=$(awk "BEGIN {printf \"%.2f\", $dest_size/1048576}")
    write_log "  Copied: $dest_count files, ${dest_size_mb} MB"

    if [[ "$src_count" -ne "$dest_count" ]]; then
        write_log "  [FAIL] Copy verification mismatch for $folder_name." "red"
        rm -rf "$dest_path" 2>/dev/null || true
        return 1
    fi

    mv "$source_path" "${source_path}.bak_pending" 2>/dev/null || {
        write_log "  [FAIL] Could not rename source folder for $folder_name." "red"
        rm -rf "$dest_path" 2>/dev/null || true
        return 1
    }

    if ln -s "$dest_path" "$source_path" 2>/dev/null; then
        rm -rf "${source_path}.bak_pending"
        write_log "  [OK] $folder_name migrated -> $dest_path" "green"
    else
        write_log "  [FAIL] Symlink creation failed. Restoring." "red"
        mv "${source_path}.bak_pending" "$source_path" 2>/dev/null || true
        rm -rf "$dest_path" 2>/dev/null || true
        return 1
    fi

    return 0
}

stop_blocking_process() {
    local folder_name="$1"
    local pids
    pids=$(get_processes_using_folder "$folder_name")
    if [[ -n "$pids" ]]; then
        for pid in $pids; do
            local pname
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            write_log "  Stopping process '$pname' (PID $pid)..." "yellow"
            if [[ "$DRY_RUN" != "1" ]]; then
                kill "$pid" 2>/dev/null || true
            fi
        done
        sleep 2
    fi
}

# ---------- Undo Migration ----------
undo_migration() {
    local folders=("$@")
    local reversed=0

    write_section "Reversing migration (unlink)"

    declare -A linked_map
    while IFS=$'\t' read -r name target; do
        [[ -n "$name" ]] && linked_map["$name"]="$target"
    done < <(get_linked_folders)

    for folder in "${folders[@]}"; do
        [[ -z "${linked_map[$folder]:-}" ]] && continue
        local source_path="$HOME/$folder"
        local target_path="${linked_map[$folder]}"

        write_log "[UNLINK] $folder -> $target_path" "yellow"

        if [[ "$DRY_RUN" != "1" ]]; then
            stop_blocking_process "$folder"
            sleep 3

            rm -f "$source_path" 2>/dev/null || true

            if [[ -d "$target_path" ]]; then
                if mv "$target_path" "$source_path" 2>/dev/null; then
                    reversed=$((reversed + 1))
                    write_log "  [OK] Restored $folder to original location" "green"
                else
                    # Fallback: copy then remove
                    if cp -a "${target_path}/." "${source_path}/" 2>/dev/null && rm -rf "$target_path" 2>/dev/null; then
                        reversed=$((reversed + 1))
                        write_log "  [OK] Restored $folder to original location (copy+remove)" "green"
                    else
                        write_log "  [FAIL] Could not restore $folder - file may be locked. Retry manually." "red"
                    fi
                fi
            else
                write_log "  [WARN] Target already moved or missing for $folder" "yellow"
            fi
        else
            write_log "  [DRY-RUN] Would restore $folder to original location" "green"
        fi
    done
    write_log "Reversed $reversed folders."
}

# ---------- Menu Functions ----------
show_linked_folders_list() {
    declare -A linked_map
    local index_map=()
    local index=1

    write_log "Linked dot folders:"
    while IFS=$'\t' read -r name target; do
        if [[ -n "$name" ]]; then
            linked_map["$name"]="$target"
            echo "  [$index] $name -> $target"
            index_map[$index]="$name"
            index=$((index + 1))
        fi
    done < <(get_linked_folders)

    if [[ ${#index_map[@]} -eq 0 ]]; then
        write_log "No linked dot folders found." "darkgray"
    fi

    # Return index_map and linked_map via global variables
    LINKED_INDEX_MAP=("${index_map[@]}")
    declare -gA LINKED_NAME_MAP
    for key in "${!linked_map[@]}"; do
        LINKED_NAME_MAP["$key"]="${linked_map[$key]}"
    done

    # Also store index->name mapping in global associative array
    declare -gA LINKED_IDX_TO_NAME
    for i in "${!index_map[@]}"; do
        LINKED_IDX_TO_NAME[$((i+1))]="${index_map[$i]}"
    done
}

select_from_list() {
    local prompt="$1"
    shift
    local valid_names=("$@")

    echo ""
    read -r -p "$prompt (comma-separated numbers, 'all', 'none', or 'menu'): " choice

    case "$choice" in
        menu) echo "MENU" ;;
        none) echo "" ;;
        all)
            for n in "${valid_names[@]}"; do
                echo "$n"
            done
            ;;
        *)
            local saved_ifs="$IFS"
            IFS=','
            for num in $choice; do
                num=$(echo "$num" | tr -d ' ')
                local idx=$((num))
                if [[ -n "${LINKED_IDX_TO_NAME[$idx]:-}" ]]; then
                    echo "${LINKED_IDX_TO_NAME[$idx]}"
                fi
            done
            IFS="$saved_ifs"
            ;;
    esac
}

show_menu() {
    local target_root_asked=0

    while true; do
        echo ""
        echo -e "\033[36m=== UserData Migration Menu ===\033[0m"
        echo "  1) WhatIf      - Show migration plans (no changes)"
        echo "  2) DryRun      - Simulate migration on all folders"
        echo "  3) ListLinks   - Show all linked dot folders"
        echo "  4) Unlink      - Restore linked folders to original location"
        echo "  5) Status      - Show comprehensive status"
        echo "  6) FixBroken   - Fix broken symlinks"
        echo "  7) RemoveEmpty - Remove empty dot folders"
        echo "  8) Migrate     - Start interactive migration"
        echo "  9) Exit"

        # Ask for target root on first run
        if [[ "$target_root_asked" == "0" ]]; then
            read -r -p "Enter target root path (press Enter for default: $HOME/UserData): " custom
            if [[ -n "$custom" ]]; then
                TARGET_ROOT="$custom"
                LOG_FILE="${TARGET_ROOT}/migration_log.txt"
            fi
            target_root_asked=1
        fi

        read -r -p "Select option (1-9): " choice

        case "$choice" in
            1) show_whatif ;;
            2)
                DRY_RUN=1
                show_dryrun
                DRY_RUN=0
                ;;
            3) show_linked_folders_list ;;
            4)
                show_linked_folders_list
                if [[ ${#LINKED_IDX_TO_NAME[@]} -gt 0 ]]; then
                    local selected
                    selected=$(select_from_list "Select folders to unlink" "${LINKED_IDX_TO_NAME[@]}")
                    if [[ "$selected" == "MENU" ]]; then
                        continue
                    fi
                    local folders_to_unlink=()
                    while IFS= read -r name; do
                        [[ -n "$name" ]] && folders_to_unlink+=("$name")
                    done <<< "$selected"
                    undo_migration "${folders_to_unlink[@]}"
                fi
                ;;
            5) show_status ;;
            6) fix_broken_links ;;
            7) remove_empty_folders ;;
            8)
                DRY_RUN=0
                do_migration
                ;;
            9) exit 0 ;;
            *) write_log "Invalid option. Try again." "red" 1 ;;
        esac
    done
}

show_whatif() {
    write_section "WhatIf: Migration plans (no changes will be made)"
    local regular linked_names

    # Get linked folder names only
    linked_names=""
    while IFS=$'\t' read -r name target; do
        [[ -n "$name" ]] && linked_names="$linked_names $name"
    done < <(get_linked_folders)

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local stats source_path
        source_path="$HOME/$f"
        stats=$(get_folder_stats "$source_path")
        IFS='|' read -r count size <<< "$stats"

        if echo "$linked_names" | grep -qw "$f"; then
            write_log "[SKIP] $f - already linked" "darkgray" 1
        elif [[ " ${NEVER_DELETE[*]} " =~ " $f " ]]; then
            write_log "[KEEP] $f - protected folder" "yellow" 1
        else
            write_log "[MIGRATE] $f - $count files -> $TARGET_ROOT/$f" "green" 1
        fi
    done <<< "$(get_regular_folders)"
}

show_dryrun() {
    write_section "Dry-run: Processing all eligible folders"
    local linked_names

    linked_names=""
    while IFS=$'\t' read -r name target; do
        [[ -n "$name" ]] && linked_names="$linked_names $name"
    done < <(get_linked_folders)

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if echo "$linked_names" | grep -qw "$f" || [[ " ${NEVER_DELETE[*]} " =~ " $f " ]]; then
            continue
        fi
        local patterns="${FOLDER_MAP[$f]:-}"
        if [[ -n "$patterns" ]] && ! test_app_installed "$f"; then
            continue
        fi
        local stats
        stats=$(get_folder_stats "$HOME/$f")
        IFS='|' read -r count size <<< "$stats"
        write_log "  [DRY-RUN] $f - $count files -> $TARGET_ROOT/$f" "cyan"
    done <<< "$(get_regular_folders)"
}

show_status() {
    write_section "UserData Migration Status"
    write_log "User home: $HOME"
    write_log "Target root: $TARGET_ROOT"

    local linked_names
    linked_names=""
    while IFS=$'\t' read -r name target; do
        [[ -n "$name" ]] && linked_names="$linked_names $name"
    done < <(get_linked_folders)

    local ready="" already="" protected="" total_size=0

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local stats
        stats=$(get_folder_stats "$HOME/$f")
        IFS='|' read -r count size <<< "$stats"
        total_size=$((total_size + size))

        if echo "$linked_names" | grep -qw "$f"; then
            already="$already $f"
        elif [[ " ${NEVER_DELETE[*]} " =~ " $f " ]]; then
            protected="$protected $f"
        else
            ready="$ready $f"
        fi
    done <<< "$(get_regular_folders)"

    local total_mb
    total_mb=$(awk "BEGIN {printf \"%.2f\", $total_size/1048576}")

    [[ -n "$already" ]]   && write_log "Already linked: $(echo $already | tr ' ' ', ')" "green" 1
    [[ -n "$ready" ]]     && write_log "Ready to migrate: $(echo $ready | tr ' ' ', ')" "cyan" 1
    [[ -n "$protected" ]] && write_log "Protected: $(echo $protected | tr ' ' ', ')" "yellow" 1
    write_log "Total size: ${total_mb} MB"
}

fix_broken_links() {
    write_section "Fixing broken symlinks"
    local broken=0

    for entry in "$HOME"/.*; do
        [[ ! -e "$entry" ]] && continue
        [[ ! -L "$entry" ]] && continue
        local name target
        name=$(basename "$entry")
        target=$(readlink "$entry" 2>/dev/null || echo "")

        if [[ -n "$target" ]] && [[ ! -e "$entry" ]]; then
            write_log "[BROKEN] $name -> $target (target missing)" "red" 1
            rm -f "$entry"
            write_log "  Removed broken symlink" "green" 1
            broken=$((broken + 1))
        fi
    done
    write_log "Fixed $broken broken symlinks."
}

remove_empty_folders() {
    write_section "Removing empty dot folders"
    local removed=0

    for entry in "$HOME"/.*; do
        [[ ! -e "$entry" ]] && continue
        [[ ! -d "$entry" ]] && continue
        [[ -L "$entry" ]] && continue

        local name
        name=$(basename "$entry")

        [[ " ${NEVER_DELETE[*]} " =~ " $name " ]] && continue

        local count
        count=$(find "$entry" -mindepth 1 2>/dev/null | wc -l)
        if [[ "$count" -eq 0 ]]; then
            write_log "[EMPTY] $name - removing" "yellow" 1
            rm -rf "$entry"
            removed=$((removed + 1))
        fi
    done
    write_log "Removed $removed empty dot folders."
}

do_migration() {
    write_section "Interactive Migration"

    local linked_names
    linked_names=""
    while IFS=$'\t' read -r name target; do
        [[ -n "$name" ]] && linked_names="$linked_names $name"
    done < <(get_linked_folders)

    local index=1
    declare -A MIGRATE_INDEX_MAP
    MIGRATE_INDEX_MAP=()

    echo ""
    echo "Available dot folders:"

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if echo "$linked_names" | grep -qw "$f" || [[ " ${NEVER_DELETE[*]} " =~ " $f " ]]; then
            continue
        fi

        local patterns="${FOLDER_MAP[$f]:-}"
        local app_detected=1
        if [[ -n "$patterns" ]]; then
            test_app_installed "$f" || app_detected=0
        fi

        if [[ "$app_detected" -eq 1 ]]; then
            echo "[$index] $f (app detected)"
        else
            echo -e "\033[33m[$index] $f (unknown/orphan - will migrate anyway)\033[0m"
        fi
        MIGRATE_INDEX_MAP[$index]="$f"
        index=$((index + 1))
    done <<< "$(get_regular_folders)"

    if [[ ${#MIGRATE_INDEX_MAP[@]} -eq 0 ]]; then
        write_log "No folders available for migration." "darkgray"
        return
    fi

    # Collect valid names for select_from_list
    local valid_names=()
    local sorted_indices
    sorted_indices=$(for k in "${!MIGRATE_INDEX_MAP[@]}"; do echo "$k"; done | sort -n)
    for idx in $sorted_indices; do
        valid_names+=("${MIGRATE_INDEX_MAP[$idx]}")
    done

    # Temporarily override LINKED_IDX_TO_NAME for select_from_list
    declare -gA LINKED_IDX_TO_NAME
    LINKED_IDX_TO_NAME=()
    local sorted_idx_arr=($sorted_indices)
    for i in "${!sorted_idx_arr[@]}"; do
        LINKED_IDX_TO_NAME[$((i+1))]="${MIGRATE_INDEX_MAP[${sorted_idx_arr[$i]}]}"
    done

    local selected
    selected=$(select_from_list "Select folders to migrate" "${valid_names[@]}")
    if [[ "$selected" == "MENU" ]]; then
        return
    fi

    local folders_to_migrate=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && folders_to_migrate+=("$name")
    done <<< "$selected"

    for f in "${folders_to_migrate[@]}"; do
        local source="$HOME/$f"
        local dest="$TARGET_ROOT/$f"
        stop_blocking_process "$f"
        move_folder_safely "$source" "$dest" "$f"
    done
}

# ---------- Main ----------
show_menu