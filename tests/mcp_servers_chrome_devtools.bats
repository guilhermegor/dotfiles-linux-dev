#!/usr/bin/env bats
#
# Unit tests for _install_chrome_devtools_mcp() in ai_clients/claude/lib/mcp_servers.sh.
#
# Strategy: stub print_status and claude BEFORE sourcing, so no real `claude`
# CLI or network call ever runs. `claude` is a function that logs every
# invocation to $CLAUDE_LOG and answers `mcp list` from $CLAUDE_MCP_LIST.

setup() {
    print_status() { echo "[$1] $2"; }

    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TEST_TMP="$(mktemp -d)"
    CLAUDE_LOG="$TEST_TMP/claude.log"
    CLAUDE_MCP_LIST=""
    : > "$CLAUDE_LOG"

    claude() {
        echo "claude $*" >> "$CLAUDE_LOG"
        if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
            printf '%s' "$CLAUDE_MCP_LIST"
        fi
    }
    export -f claude

    source "$REPO_ROOT/ai_clients/claude/lib/mcp_servers.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "_install_chrome_devtools_mcp registers a pinned version over stdio" {
    run _install_chrome_devtools_mcp
    [ "$status" -eq 0 ]
    [[ "$output" == *"chrome-devtools MCP registered (stdio transport, user scope)"* ]]
    grep -q -- "--scope user chrome-devtools npx chrome-devtools-mcp@[0-9]" "$CLAUDE_LOG"
}

@test "_install_chrome_devtools_mcp never uses @latest" {
    run _install_chrome_devtools_mcp
    [ "$status" -eq 0 ]
    run grep -q -- "@latest" "$CLAUDE_LOG"
    [ "$status" -ne 0 ]
}

@test "_install_chrome_devtools_mcp is idempotent — skips when already registered" {
    CLAUDE_MCP_LIST="chrome-devtools  npx chrome-devtools-mcp@1.12.0  stdio"

    run _install_chrome_devtools_mcp
    [ "$status" -eq 0 ]
    [[ "$output" == *"chrome-devtools MCP already registered — skipping"* ]]
    run grep -q -- "mcp add" "$CLAUDE_LOG"
    [ "$status" -ne 0 ]
}
