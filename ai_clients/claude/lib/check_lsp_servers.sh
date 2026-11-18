#!/bin/bash
# Fails when an enabled *-lsp plugin's declared server command is not on PATH
# (dotfiles-linux-dev#1026). Sourced for its helpers or run directly.
#
#   check_lsp_servers.sh [settings.json]
#
# The command comes from the plugin's own manifest, never from its name:
#   1. <marketplace>/.claude-plugin/marketplace.json  (plugins[].lspServers)
#   2. cache/<marketplace>/<plugin>/<ver>/.claude-plugin/plugin.json
# An enabled plugin with no resolvable manifest fails too: it declares no
# server, so nothing can ever start it.

_LSP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F print_status >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_LSP_LIB_DIR/../../../lib/common.sh"
fi

lsp_claude_dir() {
    echo "${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
}

# Prints "name@marketplace" for every plugin enabled with a -lsp name.
lsp_enabled_plugins() {
    jq -r '.enabledPlugins // {} | to_entries[]
           | select(.value == true and (.key | test("-lsp@"))) | .key' "$1"
}

# Prints the server command(s) a plugin declares, one per line (none if unknown).
lsp_declared_commands() {
    local plugin_key="$1"
    local name="${plugin_key%@*}" market="${plugin_key#*@}"
    local dir
    dir="$(lsp_claude_dir)/plugins"
    local filter='(.lspServers? | objects) | .[] | .command'
    local manifest
    manifest="$dir/marketplaces/$market/.claude-plugin/marketplace.json"
    if [ -f "$manifest" ]; then
        jq -r --arg n "$name" ".plugins[]? | select(.name == \$n) | $filter" "$manifest"
    fi
    for manifest in "$dir/cache/$market/$name"/*/.claude-plugin/plugin.json; do
        if [ -f "$manifest" ]; then
            jq -r "$filter" "$manifest"
        fi
    done
}

check_lsp_servers() {
    local settings="${1:-$(lsp_claude_dir)/settings.json}"
    local plugin_key str_cmds str_cmd int_bad=0
    if [ ! -f "$settings" ]; then
        print_status "error" "settings file not found: $settings"
        return 1
    fi
    while IFS= read -r plugin_key; do
        str_cmds="$(lsp_declared_commands "$plugin_key" | sort -u)"
        if [ -z "$str_cmds" ]; then
            print_status "error" "$plugin_key is enabled but declares no server (no manifest)"
            int_bad=$((int_bad + 1))
            continue
        fi
        while IFS= read -r str_cmd; do
            if command -v "$str_cmd" >/dev/null 2>&1; then
                print_status "success" "$plugin_key -> $str_cmd"
            else
                print_status "error" "$plugin_key is enabled but '$str_cmd' is not on PATH"
                int_bad=$((int_bad + 1))
            fi
        done <<< "$str_cmds"
    done < <(lsp_enabled_plugins "$settings")
    [ "$int_bad" -eq 0 ]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    check_lsp_servers "$@"
fi
