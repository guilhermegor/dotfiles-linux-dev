#!/usr/bin/env bats
#
# Tests for ai_clients/claude/lib/check_lsp_servers.sh and install_lsp_servers.sh
# (dotfiles-linux-dev#1026).
#
# Strategy: every test builds a throwaway CLAUDE_DIR (settings.json plus a
# marketplace manifest) and a stub bin dir on PATH, so neither the real
# ~/.claude nor a real language server is ever read or installed.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/lib"
    TEST_TMP="$(mktemp -d)"
    export CLAUDE_DIR="$TEST_TMP/dot-claude"
    STUB_BIN="$TEST_TMP/bin"
    mkdir -p "$STUB_BIN" "$CLAUDE_DIR/plugins/marketplaces/mkt/.claude-plugin"
    for str_tool in bash jq sort sed dirname basename cat chmod mkdir ls tail; do
        ln -s "$(command -v "$str_tool")" "$STUB_BIN/$str_tool"
    done
    ORIG_PATH="$PATH"
    export PATH="$STUB_BIN"
    printf '{"plugins":[{"name":"demo-lsp","lspServers":{"demo":{"command":"fake-lsp-server"}}}]}' \
        > "$CLAUDE_DIR/plugins/marketplaces/mkt/.claude-plugin/marketplace.json"
}

teardown() {
    PATH="$ORIG_PATH"
    rm -rf "$TEST_TMP"
}

enable() {
    printf '{"enabledPlugins":{"%s":true}}' "$1" > "$CLAUDE_DIR/settings.json"
}

@test "fails when an enabled plugin's server binary is missing" {
    enable "demo-lsp@mkt"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'fake-lsp-server' is not on PATH"* ]]
}

@test "passes when the declared server binary is on PATH" {
    enable "demo-lsp@mkt"
    printf '#!/bin/sh\n' > "$STUB_BIN/fake-lsp-server"
    chmod +x "$STUB_BIN/fake-lsp-server"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -eq 0 ]
}

@test "fails when an enabled -lsp plugin declares no server" {
    enable "ghost-lsp@mkt"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"declares no server"* ]]
}

@test "ignores a disabled plugin and non-lsp plugins" {
    printf '{"enabledPlugins":{"demo-lsp@mkt":false,"other@mkt":true}}' \
        > "$CLAUDE_DIR/settings.json"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -eq 0 ]
}

@test "installer warns instead of guessing a recipe for an unknown command" {
    enable "demo-lsp@mkt"
    run bash "$LIB/install_lsp_servers.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no install recipe for 'fake-lsp-server'"* ]]
}

@test "installer runs npm for a known command (npm stubbed)" {
    printf '{"plugins":[{"name":"py-lsp","lspServers":{"p":{"command":"pyright-langserver"}}}]}' \
        > "$CLAUDE_DIR/plugins/marketplaces/mkt/.claude-plugin/marketplace.json"
    enable "py-lsp@mkt"
    printf '#!/bin/sh\necho "$@" > "%s/npm.args"\n' "$TEST_TMP" > "$STUB_BIN/npm"
    chmod +x "$STUB_BIN/npm"
    run bash "$LIB/install_lsp_servers.sh"
    [ "$(cat "$TEST_TMP/npm.args")" = "install -g pyright" ]
}

@test "a Bash builtin does not count as an installed server" {
    printf '{"plugins":[{"name":"demo-lsp","lspServers":{"d":{"command":"cd"}}}]}' \
        > "$CLAUDE_DIR/plugins/marketplaces/mkt/.claude-plugin/marketplace.json"
    enable "demo-lsp@mkt"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -ne 0 ]
}

@test "an unreadable settings.json fails the check and the installer" {
    printf '{' > "$CLAUDE_DIR/settings.json"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -ne 0 ]
    run bash "$LIB/install_lsp_servers.sh"
    [ "$status" -ne 0 ]
}

@test "only the installPath version's manifest is checked" {
    enable "demo-lsp@mkt"
    printf '{"plugins":[]}' > "$CLAUDE_DIR/plugins/marketplaces/mkt/.claude-plugin/marketplace.json"
    local cache="$CLAUDE_DIR/plugins/cache/mkt/demo-lsp"
    mkdir -p "$cache/1/.claude-plugin" "$cache/2/.claude-plugin"
    printf '{"lspServers":{"a":{"command":"old-ls"}}}' > "$cache/1/.claude-plugin/plugin.json"
    printf '{"lspServers":{"a":{"command":"bash"}}}' > "$cache/2/.claude-plugin/plugin.json"
    printf '{"plugins":{"demo-lsp@mkt":[{"installPath":"%s"}]}}' "$cache/2" \
        > "$CLAUDE_DIR/plugins/installed_plugins.json"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -eq 0 ]
}

@test "the user-scope record wins over a project-scope record" {
    enable "demo-lsp@mkt"
    printf '{"plugins":[]}' > "$CLAUDE_DIR/plugins/marketplaces/mkt/.claude-plugin/marketplace.json"
    local cache="$CLAUDE_DIR/plugins/cache/mkt/demo-lsp"
    mkdir -p "$cache/1/.claude-plugin" "$cache/2/.claude-plugin"
    printf '{"lspServers":{"a":{"command":"old-ls"}}}' > "$cache/1/.claude-plugin/plugin.json"
    printf '{"lspServers":{"a":{"command":"bash"}}}' > "$cache/2/.claude-plugin/plugin.json"
    printf '{"plugins":{"demo-lsp@mkt":[{"scope":"project","projectPath":"/x","installPath":"%s"},{"scope":"user","installPath":"%s"}]}}' \
        "$cache/1" "$cache/2" > "$CLAUDE_DIR/plugins/installed_plugins.json"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -eq 0 ]
}

@test "without a user-scope record the most recent record is used" {
    enable "demo-lsp@mkt"
    printf '{"plugins":[]}' > "$CLAUDE_DIR/plugins/marketplaces/mkt/.claude-plugin/marketplace.json"
    local cache="$CLAUDE_DIR/plugins/cache/mkt/demo-lsp"
    mkdir -p "$cache/1/.claude-plugin" "$cache/2/.claude-plugin"
    printf '{"lspServers":{"a":{"command":"old-ls"}}}' > "$cache/1/.claude-plugin/plugin.json"
    printf '{"lspServers":{"a":{"command":"bash"}}}' > "$cache/2/.claude-plugin/plugin.json"
    printf '{"plugins":{"demo-lsp@mkt":[{"scope":"project","lastUpdated":"2026-01-01","installPath":"%s"},{"scope":"project","lastUpdated":"2026-02-01","installPath":"%s"}]}}' \
        "$cache/1" "$cache/2" > "$CLAUDE_DIR/plugins/installed_plugins.json"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -eq 0 ]
}

@test "with no record only the newest cached version is checked" {
    enable "demo-lsp@mkt"
    printf '{"plugins":[]}' > "$CLAUDE_DIR/plugins/marketplaces/mkt/.claude-plugin/marketplace.json"
    local cache="$CLAUDE_DIR/plugins/cache/mkt/demo-lsp"
    mkdir -p "$cache/1.9/.claude-plugin" "$cache/1.10/.claude-plugin"
    printf '{"lspServers":{"a":{"command":"old-ls"}}}' > "$cache/1.9/.claude-plugin/plugin.json"
    printf '{"lspServers":{"a":{"command":"bash"}}}' > "$cache/1.10/.claude-plugin/plugin.json"
    run bash "$LIB/check_lsp_servers.sh"
    [ "$status" -eq 0 ]
}
