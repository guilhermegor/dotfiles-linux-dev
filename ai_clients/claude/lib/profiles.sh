#!/bin/bash
# Deploys cheap-brain Claude Code session profiles (dotfiles-linux-dev#151).
#
# A profile is a small `--settings` overlay (just `env`, not a full
# settings.json) that points ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN at an
# Anthropic-compatible endpoint, so the harness (skills/hooks/gates) survives
# but the model is a cheaper one. The token is never committed: the source
# file ships a placeholder and this step resolves it from the project root
# .env, same pattern as _install_context7/_install_tavily in mcp_servers.sh.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "profiles.sh is meant to be sourced, not executed." >&2
    exit 1
fi

install_profiles() {
    print_status "section" "INSTALLING SESSION PROFILES"

    local project_root
    project_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
    local env_file="$project_root/.env"

    _install_deepseek_profile "$env_file"
    _install_profile_launcher
}

_install_deepseek_profile() {
    local env_file="$1"
    local src="$SCRIPT_DIR/settings.deepseek.json"
    local dst="$CLAUDE_DIR/settings.deepseek.json"

    if [ ! -f "$env_file" ]; then
        print_status "warning" "No .env file — skipping deepseek profile (needs DEEPSEEK_API_KEY)"
        return 0
    fi

    local deepseek_key
    deepseek_key=$(grep -E '^DEEPSEEK_API_KEY=' "$env_file" | head -1 | cut -d'=' -f2-)

    if [ -z "$deepseek_key" ]; then
        print_status "warning" "DEEPSEEK_API_KEY not found in .env — skipping deepseek profile"
        return 0
    fi

    mkdir -p "$CLAUDE_DIR"
    sed "s|KEY-GOES-HERE|$deepseek_key|" "$src" > "$dst"
    print_status "success" "deepseek profile written to $dst"
}

_install_profile_launcher() {
    local src="$SCRIPT_DIR/profile_functions.sh"
    local dst="$CLAUDE_DIR/profile_functions.sh"

    mkdir -p "$CLAUDE_DIR"
    cp "$src" "$dst"
    print_status "success" "profile launcher copied to $dst"

    local bashrc="$HOME/.bashrc"
    local source_line="source \"$dst\""
    if [ ! -f "$bashrc" ]; then
        print_status "info" "No ~/.bashrc found — source $dst manually"
    elif grep -qF "$source_line" "$bashrc"; then
        print_status "info" "\$HOME/.bashrc already sources the profile launcher"
    else
        {
            echo ""
            echo "# Claude Code session profiles (dotfiles-linux-dev#151)"
            echo "$source_line"
        } >> "$bashrc"
        print_status "success" "Appended profile launcher source line to $bashrc"
    fi
}
