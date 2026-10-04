#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/claude_artifact_source_guard.sh
#
# Strategy (same as protected_branch_guard.bats):
#   - The hook is a pure stdin->exit-code filter: it reads a PreToolUse JSON payload on stdin and
#     exits 0 (allow, fail-open) or 2 (block). Every test is "feed a payload, assert the exit code".
#   - CLAUDE_CONFIG_DIR / COPILOT_HOME / KIMI_CODE_HOME are the hook's own override env vars; each
#     test points them (and, for Qwen, plain $HOME — it has no documented override) at a throwaway
#     tmpdir so real live dirs are never touched.
#   - `payload <tool> <path>` builds the harness JSON; `run_guard <tool> <path>` pipes it through the
#     hook so the pipe's exit status IS the hook's.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/claude_artifact_source_guard.sh"
    TEST_TMP="$(mktemp -d)"
    export CLAUDE_CONFIG_DIR="$TEST_TMP/dot-claude"
    export HOME="$TEST_TMP/home"                    # Qwen's dir is plain $HOME/.qwen
    export COPILOT_HOME="$TEST_TMP/dot-copilot"
    export KIMI_CODE_HOME="$TEST_TMP/dot-kimi-code"
    mkdir -p "$HOME"
}

teardown() {
    rm -rf "$TEST_TMP"
}

payload() {
    jq -nc --arg tool "$1" --arg path "$2" '{tool_name: $tool, tool_input: {file_path: $path}}'
}

run_guard() {
    payload "$1" "$2" | "$GUARD"
}

# --- Claude: existing coverage still holds ------------------------------------------------------

@test "blocks a direct Write into ~/.claude/commands/" {
    run run_guard "Write" "$CLAUDE_CONFIG_DIR/commands/foo.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"ai_clients/claude/commands/foo.md"* ]]
}

@test "blocks a direct Edit of the global CLAUDE.md" {
    run run_guard "Edit" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"ai_clients/claude/config/CLAUDE.md"* ]]
}

@test "allows a Write into ~/.claude/projects/ (project memory exemption)" {
    run run_guard "Write" "$CLAUDE_CONFIG_DIR/projects/foo/memory.md"
    [ "$status" -eq 0 ]
}

@test "allows a Write to ~/.claude/settings.json (machine-local keys exemption)" {
    run run_guard "Write" "$CLAUDE_CONFIG_DIR/settings.json"
    [ "$status" -eq 0 ]
}

# --- New: ~/.claude/AGENTS.md now routes to the shared source -----------------------------------

@test "blocks a direct Write into ~/.claude/AGENTS.md, points at the shared source" {
    run run_guard "Write" "$CLAUDE_CONFIG_DIR/AGENTS.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"ai_clients/shared/AGENTS.md"* ]]
}

# --- New: Qwen -------------------------------------------------------------------------------

@test "blocks a direct Edit of ~/.qwen/AGENTS.md, points at the shared source" {
    run run_guard "Edit" "$HOME/.qwen/AGENTS.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"ai_clients/shared/AGENTS.md"* ]]
    [[ "$output" == *"$HOME/.qwen/"* ]]
}

@test "allows a Write to ~/.qwen/settings.json (unversioned, contains a live key)" {
    run run_guard "Write" "$HOME/.qwen/settings.json"
    [ "$status" -eq 0 ]
}

# --- New: Copilot — different destination filename, same shared source --------------------------

@test "blocks a direct Write into copilot-instructions.md, points at the shared source" {
    run run_guard "Write" "$COPILOT_HOME/copilot-instructions.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"ai_clients/shared/AGENTS.md"* ]]
}

@test "allows a Write to Copilot's config.json (unversioned local state)" {
    run run_guard "Write" "$COPILOT_HOME/config.json"
    [ "$status" -eq 0 ]
}

# --- New: Kimi (unverified client, same guard shape) ---------------------------------------------

@test "blocks a direct Edit of Kimi's AGENTS.md, points at the shared source" {
    run run_guard "Edit" "$KIMI_CODE_HOME/AGENTS.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"ai_clients/shared/AGENTS.md"* ]]
}

# --- Fail-open regressions ------------------------------------------------------------------------

@test "ignores non-Write/Edit tools" {
    run run_guard "Read" "$CLAUDE_CONFIG_DIR/commands/foo.md"
    [ "$status" -eq 0 ]
}

@test "allows a path outside every guarded client dir" {
    run run_guard "Write" "$TEST_TMP/some/other/project/AGENTS.md"
    [ "$status" -eq 0 ]
}

@test "allows an unrelated file directly under ~/.qwen/" {
    run run_guard "Write" "$HOME/.qwen/tip_history.json"
    [ "$status" -eq 0 ]
}

# --- path normalization: an unnormalized path must not walk past the allowlist -------------------
#
# The routing strips the live dir's prefix and matches what remains against a literal allowlist, so
# `~/.qwen/./AGENTS.md` used to leave rel as `./AGENTS.md`, miss every arm and exit 0 (fail open)
# while the write still landed on the real file. Measured on all four client branches, the
# pre-existing Claude one included (dotfiles-linux-dev#346, PR #355 review).

@test "a './' component does not bypass the Qwen arm" {
    run run_guard Write "$HOME/.qwen/./AGENTS.md"
    [ "$status" -eq 2 ]
}

@test "a repeated separator does not bypass the Qwen arm" {
    run run_guard Write "$HOME/.qwen//AGENTS.md"
    [ "$status" -eq 2 ]
}

@test "a '..' component does not bypass the Qwen arm" {
    run run_guard Write "$HOME/.qwen/nested/../AGENTS.md"
    [ "$status" -eq 2 ]
}

@test "a './' component does not bypass the Claude arm" {
    run run_guard Edit "$CLAUDE_CONFIG_DIR/./CLAUDE.md"
    [ "$status" -eq 2 ]
}

@test "a '..' out of an allowlisted subdir still blocks on the Claude arm" {
    run run_guard Write "$CLAUDE_CONFIG_DIR/hooks/../CLAUDE.md"
    [ "$status" -eq 2 ]
}

@test "a './' component does not bypass the Copilot arm" {
    run run_guard Write "$COPILOT_HOME/./copilot-instructions.md"
    [ "$status" -eq 2 ]
}

@test "a './' component does not bypass the Kimi arm" {
    run run_guard Edit "$KIMI_CODE_HOME/./AGENTS.md"
    [ "$status" -eq 2 ]
}

@test "normalization does not turn an exempt path into a blocked one" {
    run run_guard Write "$CLAUDE_CONFIG_DIR/./projects/proj/memory/note.md"
    [ "$status" -eq 0 ]
    run run_guard Write "$HOME/.qwen/./settings.json"
    [ "$status" -eq 0 ]
}
