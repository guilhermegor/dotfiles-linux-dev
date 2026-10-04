#!/bin/bash
# Writes ~/.claude/settings.json, merging base settings and optional statusLine.

configure_settings() {
    print_status "section" "CONFIGURING CLAUDE SETTINGS"

    local settings_file="$CLAUDE_DIR/settings.json"
    local base_settings_file="$SCRIPT_DIR/settings.json"
    mkdir -p "$CLAUDE_DIR"

    if [ ! -f "$base_settings_file" ]; then
        print_status "error" "Base settings file not found: $base_settings_file"
        return 1
    fi

    if [ -f "$settings_file" ]; then
        cp "$settings_file" "${settings_file}.backup_$(date +%Y%m%d_%H%M%S)"
        print_status "success" "Backed up existing settings.json"
    fi

    local current='{}'
    if [ -f "$settings_file" ] && jq empty "$settings_file" 2>/dev/null; then
        current=$(cat "$settings_file")
    else
        echo '{}' > "$settings_file"
        print_status "info" "Created new settings.json"
    fi

    local base_settings
    base_settings=$(cat "$base_settings_file")

    # Merge: base_settings take priority over current (preserves any extra user keys).
    # This is additive-only — it can update a key source defines but can never
    # remove a key that exists only live (jq '*' never deletes). That is exactly
    # right for machine-local keys, and exactly wrong for a key deleted from
    # source: it silently stays behind forever. The "prune" step's
    # prune_settings_keys() (lib/prune.sh) is the delete path for the specific,
    # fully source-owned subtrees where that matters (e.g. enabledPlugins) —
    # see dotfiles-linux-dev#272.
    echo "$current" | jq --argjson base "$base_settings" '. * $base' > "${settings_file}.tmp"

    # Add portable statusLine only if claude-hud cache is present.
    # Uses Python to avoid bash quoting corruption of the '"'"' awk trick when passed via jq --arg.
    local hud_cache="$CLAUDE_DIR/plugins/cache/claude-hud/claude-hud"
    if [ -d "$hud_cache" ] && ls -d "$hud_cache"/*/ &>/dev/null 2>&1; then
        python3 - "${settings_file}.tmp" "$settings_file" << 'PYEOF'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    settings = json.load(f)

sq = "'"
cmd = (
    "bash -c " + sq +
    "plugin_dir=$(ls -d \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/claude-hud/claude-hud/*/ 2>/dev/null"
    " | awk -F/ " + sq + '"' + sq + '"' + sq + "{ print $(NF-1) \"\\t\" $(0) }" + sq + '"' + sq + '"' + sq +
    " | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 | cut -f2-);"
    "node_bin=$(command -v node 2>/dev/null"
    " || ls ~/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1"
    " || echo node);"
    " exec \"$node_bin\" \"${plugin_dir}dist/index.js\"" + sq
)

settings['statusLine'] = {'type': 'command', 'command': cmd}

with open(dst, 'w') as f:
    json.dump(settings, f, indent=2)
PYEOF
        print_status "success" "statusLine configured (portable node resolution)"
    else
        mv "${settings_file}.tmp" "$settings_file"
        print_status "warning" "claude-hud cache not found — statusLine skipped (install claude-hud first)"
    fi

    rm -f "${settings_file}.tmp"
    print_status "config" "Settings written to: $settings_file"
}
