#!/bin/bash
# Installs the language servers that enabled *-lsp plugins start
# (dotfiles-linux-dev#1026). Which commands are needed is read from the
# plugins' manifests (check_lsp_servers.sh); only the command -> package map
# below is ours. A declared command with no entry is reported, never guessed.

_LSP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_LSP_LIB_DIR/check_lsp_servers.sh"

# Prints the npm package(s) providing a server command; fails when unknown.
lsp_npm_packages() {
    case "$1" in
        pyright-langserver) echo "pyright" ;;
        typescript-language-server) echo "typescript-language-server typescript" ;;
        *) return 1 ;;
    esac
}

install_lsp_servers() {
    local settings="${1:-$(lsp_claude_dir)/settings.json}"
    local plugin_key str_cmd str_pkgs
    local -a list_missing=()
    if [ ! -f "$settings" ]; then
        print_status "error" "settings file not found: $settings"
        return 1
    fi
    while IFS= read -r plugin_key; do
        while IFS= read -r str_cmd; do
            if [ -n "$str_cmd" ] && ! command -v "$str_cmd" >/dev/null 2>&1; then
                list_missing+=("$str_cmd")
            fi
        done < <(lsp_declared_commands "$plugin_key" | sort -u)
    done < <(lsp_enabled_plugins "$settings")

    for str_cmd in $(printf '%s\n' "${list_missing[@]}" | sort -u); do
        if ! str_pkgs="$(lsp_npm_packages "$str_cmd")"; then
            print_status "warning" "no install recipe for '$str_cmd'; disable its plugin"
            continue
        fi
        if ! command -v npm >/dev/null 2>&1; then
            print_status "error" "npm not found; cannot install '$str_cmd'"
            return 1
        fi
        print_status "info" "Installing $str_pkgs for '$str_cmd' ..."
        # shellcheck disable=SC2086
        npm install -g $str_pkgs || return 1
    done
    check_lsp_servers "$settings"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    install_lsp_servers "$@"
fi
