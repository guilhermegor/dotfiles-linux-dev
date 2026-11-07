#!/bin/bash
# Deploys the claude-profile session launcher (dotfiles-linux-dev#151).
#
# A profile is a small `--settings` overlay (just `env`, not a full
# settings.json) at ~/.claude/settings.<name>.json that points
# ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN at an Anthropic-compatible
# endpoint. No profile ships from source any more (the DeepSeek one was
# removed in dotfiles-linux-dev#935); the launcher stays for hand-made ones.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "profiles.sh is meant to be sourced, not executed." >&2
    exit 1
fi

install_profiles() {
    print_status "section" "INSTALLING SESSION PROFILES"

    _install_profile_launcher
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
