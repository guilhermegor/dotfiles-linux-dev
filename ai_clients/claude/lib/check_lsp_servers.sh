#!/bin/bash
# Fails when an enabled *-lsp plugin's declared server command is not on PATH
# (dotfiles-linux-dev#1026). Sourced for its helpers or run directly.
#
#   check_lsp_servers.sh [settings.json]
#
# The command comes from the plugin's own manifest, never from its name:
#   1. <marketplace>/.claude-plugin/marketplace.json  (plugins[].lspServers)
#   2. the plugin's user-scope installPath from installed_plugins.json (else
#      the most recent record, else the newest cache/<marketplace>/<plugin>/<ver>) + /.claude-plugin/plugin.json
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
    local installed="$dir/installed_plugins.json" path_install=""
    local -a list_dirs=()
    if [ -f "$installed" ]; then
        path_install="$(jq -r --arg k "$plugin_key" '
            (.plugins[$k] // []) | (map(select(.scope == "user")) | .[0])
            // (sort_by(.lastUpdated // "") | last) | .installPath // empty' "$installed" 2>/dev/null)"
    fi
    if [ -n "$path_install" ]; then
        list_dirs=("$path_install")
    else
        # shellcheck disable=SC2012
        list_dirs=("$(ls -d "$dir/cache/$market/$name"/*/ 2>/dev/null | sort -V | tail -n 1)")
    fi
    for path_install in "${list_dirs[@]}"; do
        manifest="$path_install/.claude-plugin/plugin.json"
        if [ -f "$manifest" ]; then
            jq -r "$filter" "$manifest"
        fi
    done
}

# True only for an executable file: a bare name is searched on PATH, a path is
# tested directly. Unlike `command -v`, a Bash builtin (cd, echo) never counts.
lsp_have_cmd() {
    type -P "$1" >/dev/null 2>&1
}

check_lsp_servers() {
    local settings="${1:-$(lsp_claude_dir)/settings.json}"
    local plugin_key str_cmds str_cmd str_plugins int_bad=0
    if [ ! -f "$settings" ]; then
        print_status "error" "settings file not found: $settings"
        return 1
    fi
    if ! str_plugins="$(lsp_enabled_plugins "$settings")"; then
        print_status "error" "cannot read enabledPlugins from $settings"
        return 1
    fi
    while IFS= read -r plugin_key; do
        [ -n "$plugin_key" ] || continue
        str_cmds="$(lsp_declared_commands "$plugin_key" | sort -u)"
        if [ -z "$str_cmds" ]; then
            print_status "error" "$plugin_key is enabled but declares no server (no manifest)"
            int_bad=$((int_bad + 1))
            continue
        fi
        while IFS= read -r str_cmd; do
            if lsp_have_cmd "$str_cmd"; then
                print_status "success" "$plugin_key -> $str_cmd"
            else
                print_status "error" "$plugin_key is enabled but '$str_cmd' is not on PATH"
                int_bad=$((int_bad + 1))
            fi
        done <<< "$str_cmds"
    done <<< "$str_plugins"
    [ "$int_bad" -eq 0 ]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    check_lsp_servers "$@"
fi
