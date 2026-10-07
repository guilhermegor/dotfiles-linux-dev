#!/bin/bash
# Step `state_sync` (dotfiles-linux-dev#655): clone the private AI-state repo and
# materialise it over ~/.claude, and install the standalone `ai-state-sync`
# command. All logic lives in hooks/ai_state_sync.sh so the deployed
# SessionStart/SessionEnd hooks, this step, and the keyboard-shortcut command
# share one implementation. A missing remote prints the
# `gh repo create --private` hint and does nothing; a live file that differs from
# the repo copy aborts the step instead of being overwritten.

install_ai_state_sync_command() {
    local bin_dir="${AI_STATE_BIN_DIR:-$HOME/.local/bin}"
    mkdir -p "$bin_dir" || return 1
    cp "$HOOKS_SRC_DIR/ai_state_sync.sh" "$bin_dir/ai-state-sync" || return 1
    chmod +x "$bin_dir/ai-state-sync"
    print_status "success" "Installed ai-state-sync -> $bin_dir/ai-state-sync (pull|push)"
}

setup_state_sync() {
    print_status "section" "AI-STATE SYNC (private repo -> $CLAUDE_DIR)"
    local sync_script="$HOOKS_SRC_DIR/ai_state_sync.sh"

    if [[ ! -f "$sync_script" ]]; then
        print_status "error" "Not found: $sync_script"
        return 1
    fi
    install_ai_state_sync_command || return 1
    CLAUDE_CONFIG_DIR="$CLAUDE_DIR" bash "$sync_script" setup </dev/null || return 1

    # Codex's memories/goals DBs (#656): same script, second client. Restores the text
    # dumps into an absent or empty DB only; a populated DB is refused, not overwritten.
    print_status "section" "AI-STATE SYNC (codex memory DBs -> ${CODEX_HOME:-$HOME/.codex})"
    AI_STATE_CLIENT=codex CLAUDE_CONFIG_DIR="$CLAUDE_DIR" bash "$sync_script" setup </dev/null
}
