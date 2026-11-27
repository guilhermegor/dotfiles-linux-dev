#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/gate_bypass_guard.sh (dotfiles-linux-dev#1143)
#
# The hook is a pure stdin->exit-code filter: a PreToolUse JSON payload in, exit 0 (allow) or
# 2 (block) out. Every test feeds a payload and asserts the exit code, plus the refusal text
# for the blocked cases (owner-only wording and the `! <command>` form).

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/gate_bypass_guard.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP"
}

teardown() {
    rm -rf "$TEST_TMP"
}

payload() {
    jq -nc --arg cmd "$1" --arg cwd "$PWD" \
        '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $cmd}}'
}

run_guard() {
    payload "$1" | "$GUARD"
}

assert_refused() {
    run run_guard "$1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"OWNER-ONLY"* ]]
    [[ "$output" == *"! <command>"* ]]
}

assert_allowed() {
    run run_guard "$1"
    [ "$status" -eq 0 ]
}

# --- refusals: one per token ---------------------------------------------------------------

@test "refuses git commit --no-verify" {
    assert_refused 'git commit --no-verify -m "feat: x"'
}

@test "refuses rtk git commit -m with trailing --no-verify" {
    assert_refused 'rtk git commit -m "feat: x" --no-verify'
}

@test "refuses git push --no-verify" {
    assert_refused 'git push --no-verify origin HEAD'
}

@test "refuses git merge --no-verify" {
    assert_refused 'git merge --no-verify topic'
}

@test "refuses --no-verify on a commit chained after &&" {
    assert_refused 'git add -A && git commit --no-verify -m "x"'
}

@test "refuses GATE_CHANGE_OK= prefix" {
    assert_refused 'GATE_CHANGE_OK=1 git commit -m "x"'
}

@test "refuses exported GATE_CHANGE_OK" {
    assert_refused 'export GATE_CHANGE_OK=yes; git commit -m "x"'
}

@test "refuses SKIP= before git" {
    assert_refused 'SKIP=ruff git commit -m "x"'
}

@test "refuses SKIP= before rtk git" {
    assert_refused 'SKIP=ruff,codespell rtk git commit -m "x"'
}

@test "refuses a gate-change-ok: line in an inline -m message" {
    assert_refused 'git commit -m "chore: relax gate" -m "gate-change-ok: owner agreed"'
}

@test "refuses a gate-change-ok: line inside a heredoc message" {
    cmd="$(printf '%s\n' "git commit -F- <<'MSG'" 'chore: relax gate' '' 'gate-change-ok: because' 'MSG')"
    assert_refused "$cmd"
}

@test "refuses a gate-change-ok: line in a readable -F file" {
    printf 'chore: relax gate\n\ngate-change-ok: because\n' > msg.txt
    assert_refused 'git commit -F msg.txt'
}

# --- ordinary commands pass ----------------------------------------------------------------

@test "allows an ordinary commit" {
    assert_allowed 'git commit -m "feat: add thing"'
}

@test "allows an ordinary commit through -F file" {
    printf 'feat: add thing\n\nplain body\n' > msg.txt
    assert_allowed 'git commit -F msg.txt'
}

@test "allows an ordinary push and merge" {
    assert_allowed 'git push origin HEAD:refs/heads/feat/x'
    assert_allowed 'git merge --no-ff topic'
}

@test "allows --no-verify quoted inside a commit message" {
    assert_allowed 'git commit -m "docs: explain why --no-verify is owner-only"'
}

@test "allows --no-verify inside a grep pattern" {
    assert_allowed 'grep -rn -- "--no-verify" ai_clients/'
}

@test "allows --no-verify on a non-gated git subcommand" {
    assert_allowed 'git log --no-verify'
}

@test "allows a commit message that merely mentions gate-change-ok: mid-line" {
    assert_allowed 'git commit -m "docs: the gate-change-ok: line is owner-only"'
}

@test "allows non-Bash tools and empty commands" {
    run bash -c "jq -nc '{tool_name:\"Read\",tool_input:{file_path:\"x\"}}' | '$GUARD'"
    [ "$status" -eq 0 ]
    assert_allowed ''
}
