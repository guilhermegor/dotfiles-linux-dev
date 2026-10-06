#!/usr/bin/env bats
#
# EOF-on-stdin guards for the ai_clients setup prompts (dotfiles-dev#617).
#
# An unattended run (stdin closed or not a terminal) makes `read` return 1, which
# `set -e` turns into an abort of the whole run. Every prompt below must treat EOF
# as an empty answer and take its stated default; the destructive [y/N] prompts
# (prune, restore) must stay "No" so nothing is removed or replaced.
#
# Strategy: call each function with `</dev/null` under `set -e` (eof_run), with all
# side effects redirected to a temp dir or stubbed.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP_DIR="$(mktemp -d)"
    HOME="$TMP_DIR/home"
    CLAUDE_DIR="$HOME/.claude"
    SCRIPT_DIR="$TMP_DIR/source"
    mkdir -p "$HOME" "$CLAUDE_DIR" "$SCRIPT_DIR"

    print_status() { echo "[$1] $2"; }
}

teardown() {
    rm -rf "$TMP_DIR"
}

# Sources lib $1 in a fresh `set -e` shell (bats' own context would silently ignore
# errexit), evals $STUBS, then runs "${@:2}" with stdin at EOF.
eof_run() {
    export HOME CLAUDE_DIR SCRIPT_DIR REPO_ROOT TMP_DIR STUBS
    bash -c '
        set -e
        print_status() { echo "[$1] $2"; }
        source "$1"
        eval "$STUBS"
        shift
        "$@"
    ' _ "$REPO_ROOT_REAL/$1" "${@:2}" </dev/null
}

# ── claude_mem.sh ────────────────────────────────────────────────────────────

@test "configure_claude_mem keeps the existing mode on EOF" {
    STUBS=:
    export CLAUDE_MEM_DIR="$HOME/.claude-mem"
    export CLAUDE_MEM_SETTINGS="$CLAUDE_MEM_DIR/settings.json"
    mkdir -p "$CLAUDE_MEM_DIR"
    echo '{"CLAUDE_MEM_MODE":"code--ja"}' > "$CLAUDE_MEM_SETTINGS"

    run eof_run ai_clients/claude/lib/claude_mem.sh configure_claude_mem
    [ "$status" -eq 0 ]
    [[ "$output" == *"Kept existing mode: code--ja"* ]]
    [ "$(jq -r .CLAUDE_MEM_MODE "$CLAUDE_MEM_SETTINGS")" = "code--ja" ]
}

@test "configure_claude_mem picks mode 1 (code) on EOF" {
    STUBS=:
    export CLAUDE_MEM_DIR="$HOME/.claude-mem"
    export CLAUDE_MEM_SETTINGS="$CLAUDE_MEM_DIR/settings.json"

    run eof_run ai_clients/claude/lib/claude_mem.sh configure_claude_mem
    [ "$status" -eq 0 ]
    [ "$(jq -r .CLAUDE_MEM_MODE "$CLAUDE_MEM_SETTINGS")" = "code" ]
}

# ── mcp_servers.sh ───────────────────────────────────────────────────────────

@test "_install_notesnook takes the default sync folder on EOF" {
    STUBS='claude() { return 0; }; node() { echo v22.0.0; }; npm() { return 0; }
        xdg-user-dir() { echo "$HOME/Docs"; }'
    local install_dir="$HOME/.local/share/notesnook-mcp"
    mkdir -p "$install_dir/dist" "$HOME/.config"
    touch "$install_dir/dist/index.js"

    run eof_run ai_clients/claude/lib/mcp_servers.sh _install_notesnook "$TMP_DIR/no-such.env"
    [ "$status" -eq 0 ]
    [ -d "$HOME/Docs/Notesnook/export" ]
}

# ── prune.sh ─────────────────────────────────────────────────────────────────

@test "prune_orphans removes nothing on EOF" {
    STUBS=:
    mkdir -p "$SCRIPT_DIR/commands" "$CLAUDE_DIR/commands"
    touch "$CLAUDE_DIR/commands/orphan.md"
    echo '{"enabledPlugins":{"a@m":true,"stale@m":true}}' > "$CLAUDE_DIR/settings.json"
    echo '{"enabledPlugins":{"a@m":true}}' > "$SCRIPT_DIR/settings.json"

    run eof_run ai_clients/claude/lib/prune.sh prune_orphans
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing removed"* ]]
    [ -f "$CLAUDE_DIR/commands/orphan.md" ]
    [ "$(jq -r '.enabledPlugins | has("stale@m")' "$CLAUDE_DIR/settings.json")" = "true" ]
}
