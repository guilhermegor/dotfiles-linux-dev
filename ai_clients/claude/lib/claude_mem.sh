#!/bin/bash
# Writes ~/.claude-mem/settings.json for the claude-mem plugin.
# Modes are defined in plugin/modes/ after bootstrap.

CLAUDE_MEM_DIR="$HOME/.claude-mem"
CLAUDE_MEM_SETTINGS="$CLAUDE_MEM_DIR/settings.json"

CLAUDE_MEM_MODES=("code" "code--zh" "code--ja")
CLAUDE_MEM_MODE_LABELS=(
    "code      — Default (English)"
    "code--zh  — Simplified Chinese"
    "code--ja  — Japanese"
)

configure_claude_mem() {
    print_status "section" "CONFIGURING CLAUDE-MEM"

    local existing_mode=""
    if [ -f "$CLAUDE_MEM_SETTINGS" ]; then
        existing_mode=$(jq -r '.CLAUDE_MEM_MODE // empty' "$CLAUDE_MEM_SETTINGS" 2>/dev/null || true)
    fi

    if [ -n "$existing_mode" ]; then
        print_status "info" "Current CLAUDE_MEM_MODE: $existing_mode"
        read -rp "Keep current mode? [Y/n]: " keep_current || keep_current=""
        if [[ ! "$keep_current" =~ ^[nN]$ ]]; then
            print_status "success" "Kept existing mode: $existing_mode"
            return 0
        fi
    fi

    echo ""
    print_status "info" "Select claude-mem mode:"
    for i in "${!CLAUDE_MEM_MODE_LABELS[@]}"; do
        echo "  $((i+1))) ${CLAUDE_MEM_MODE_LABELS[$i]}"
    done
    echo ""
    read -rp "Enter number [default: 1 (code)]: " choice || choice=""

    local selected_mode="code"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#CLAUDE_MEM_MODES[@]} )); then
        selected_mode="${CLAUDE_MEM_MODES[$((choice-1))]}"
    fi

    _write_claude_mem_settings "$selected_mode"
}

_write_claude_mem_settings() {
    local mode="$1"

    mkdir -p "$CLAUDE_MEM_DIR"

    if [ -f "$CLAUDE_MEM_SETTINGS" ]; then
        local backup_path
        backup_path="${CLAUDE_MEM_SETTINGS}.backup_$(date +%Y%m%d_%H%M%S)"
        cp "$CLAUDE_MEM_SETTINGS" "$backup_path"
        print_status "success" "Backed up existing settings → $(basename "$backup_path")"
    fi

    jq -n --arg mode "$mode" '{"CLAUDE_MEM_MODE": $mode}' > "$CLAUDE_MEM_SETTINGS"

    print_status "success" "CLAUDE_MEM_MODE=$mode"
    print_status "config"  "Settings written to: $CLAUDE_MEM_SETTINGS"
}
