#!/bin/bash
# Installs the user-level ~/.claude/CLAUDE.md with global programming preferences.
# Source file: ai_clients/claude/config/CLAUDE.md

# shellcheck source=../hooks/lib/dotfiles_dir.sh
source "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib/dotfiles_dir.sh"

install_claude_md() {
    print_status "section" "INSTALLING GLOBAL CLAUDE.MD"

    local src
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/CLAUDE.md"

    if [[ ! -f "$src" ]]; then
        print_status "error" "Source not found: $src"
        return 1
    fi

    mkdir -p "$CLAUDE_DIR"
    install_with_dotfiles_dir "$src" "$CLAUDE_DIR/CLAUDE.md" || {
        print_status "error" "Could not resolve the dotfiles checkout dir"
        return 1
    }

    print_status "success" "Installed CLAUDE.md → $CLAUDE_DIR/CLAUDE.md"
}
