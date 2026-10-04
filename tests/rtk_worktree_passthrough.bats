#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/rtk_worktree_passthrough.sh (dotfiles-linux-dev#417).
#
# Strategy:
#   - The hook is a pure stdin->stdout/exit-code filter: feed a PreToolUse payload, assert what
#     it prints (or stays silent) and its exit code.
#   - A fake `rtk` shell script shadows the real binary on PATH so these tests never depend on
#     rtk being installed, or on its actual rewrite table — only on whether OUR hook calls it.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/rtk_worktree_passthrough.sh"
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BIN"
    cat >"$FAKE_BIN/rtk" <<'EOF'
#!/bin/bash
# Fake rtk: proves the hook forwarded to it, without depending on the real rewrite table.
echo "FAKE_RTK_CALLED:$*"
EOF
    chmod +x "$FAKE_BIN/rtk"
}

payload() {
    jq -nc --arg cwd "$1" --arg cmd "$2" '{cwd: $cwd, tool_input: {command: $cmd}}'
}

run_hook() {
    run bash -c "PATH='$FAKE_BIN:$PATH' bash '$HOOK'" <<<"$(payload "$1" "$2")"
}

# --- isolated worktree (agent-<id>): git passes through unrewritten ----------------------------

@test "bare git in an isolated worktree is allowed silently, never reaches rtk" {
    run_hook '/x/.claude/worktrees/agent-abc123' 'git status'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rtk git in an isolated worktree is rewritten back to bare git" {
    run_hook '/x/.claude/worktrees/agent-abc123' 'rtk git status'
    [ "$status" -eq 0 ]
    [[ "$output" != *FAKE_RTK_CALLED* ]]
    updated="$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$output")"
    [ "$updated" = "git status" ]
}

@test "rtk proxy git in an isolated worktree is rewritten back to bare git" {
    run_hook '/x/.claude/worktrees/agent-abc123' 'rtk proxy git commit -m x'
    [ "$status" -eq 0 ]
    updated="$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$output")"
    [ "$updated" = "git commit -m x" ]
}

@test "git worktree add in an isolated worktree passes through like any other git subcommand" {
    run_hook '/x/.claude/worktrees/agent-abc123' 'git worktree add /tmp/y -b z'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- guard still fires everywhere else ----------------------------------------------------------

@test "bare git OUTSIDE an isolated worktree still goes through rtk" {
    run_hook '/x/.claude/worktrees/i417' 'git status'
    [ "$status" -eq 0 ]
    [[ "$output" == *FAKE_RTK_CALLED* ]]
}

@test "a non-git command inside an isolated worktree still goes through rtk" {
    run_hook '/x/.claude/worktrees/agent-abc123' 'npm run test'
    [ "$status" -eq 0 ]
    [[ "$output" == *FAKE_RTK_CALLED* ]]
}

@test "a worktree an agent named itself (not agent-<id>) is not treated as isolated" {
    run_hook '/x/.claude/worktrees/my-feature' 'git status'
    [ "$status" -eq 0 ]
    [[ "$output" == *FAKE_RTK_CALLED* ]]
}
