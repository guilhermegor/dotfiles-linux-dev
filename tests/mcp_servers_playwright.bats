#!/usr/bin/env bats
#
# Unit tests for _install_playwright_mcp() and mcp_registered() in
# ai_clients/claude/lib/mcp_servers.sh.
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

@test "_install_playwright_mcp registers over stdio when nothing is listed" {
    run _install_playwright_mcp
    [ "$status" -eq 0 ]
    [[ "$output" == *"playwright MCP registered (stdio transport, user scope)"* ]]
    grep -q -- "--scope user playwright npx @playwright/mcp@latest" "$CLAUDE_LOG"
}

@test "_install_playwright_mcp skips when an exact playwright: entry is listed" {
    CLAUDE_MCP_LIST="playwright: npx @playwright/mcp@latest - Connected"

    run _install_playwright_mcp
    [ "$status" -eq 0 ]
    [[ "$output" == *"playwright MCP already registered — skipping"* ]]
    run grep -q -- "mcp add" "$CLAUDE_LOG"
    [ "$status" -ne 0 ]
}

@test "_install_playwright_mcp still registers when only playwright-local is listed" {
    CLAUDE_MCP_LIST="playwright-local  npx something  stdio"

    run _install_playwright_mcp
    [ "$status" -eq 0 ]
    grep -q -- "mcp add" "$CLAUDE_LOG"
}

@test "mcp_registered rejects a sibling name and accepts the exact one" {
    CLAUDE_MCP_LIST="playwright-local: npx x - Connected"
    run mcp_registered playwright
    [ "$status" -ne 0 ]

    CLAUDE_MCP_LIST="playwright-local: npx x - Connected
playwright: npx y - Connected"
    run mcp_registered playwright
    [ "$status" -eq 0 ]
}
