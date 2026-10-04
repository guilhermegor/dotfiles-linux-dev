#!/usr/bin/env bash
# Session-profile launcher for Claude Code (dotfiles-linux-dev#151).
#
# ANTHROPIC_BASE_URL is process-level: it swaps the model for the WHOLE
# session, subagents included, because a subagent inherits the parent
# process's endpoint. "Premium orchestrator + cheap subagents" in one
# process is therefore not possible — run two sessions instead:
#   - a premium session for the work that needs the strong model
#   - a cheap-brain session (this launcher) for delegated/AFK work
# and hand off between them with:
#   gh issue list --label afk --label oracle:strong
#
# Usage:
#   claude-profile <name> [claude args...]   e.g. claude-profile deepseek

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "profile_functions.sh is meant to be sourced, not executed." >&2
    exit 1
fi

claude-profile() {
    local profile_name="$1"
    if [ -z "$profile_name" ]; then
        echo "Usage: claude-profile <name> [claude args...]  (e.g. deepseek)" >&2
        return 1
    fi
    shift

    local settings_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.${profile_name}.json"
    if [ ! -f "$settings_file" ]; then
        echo "No profile settings at $settings_file" >&2
        echo "Run 'make ai_clients' (profiles step) to deploy it first." >&2
        return 1
    fi

    claude --settings "$settings_file" "$@"
}
