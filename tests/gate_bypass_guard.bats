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

# --- CodeRabbit review of #1145 ------------------------------------------------------------

@test "refuses a quoted --no-verify option argument" {
    assert_refused 'git push "--no-verify" origin HEAD'
    assert_refused "git commit '--no-verify' -m x"
}

@test "refuses --no-verify after repeated whitespace" {
    assert_refused 'git  push --no-verify origin HEAD'
    assert_refused 'git commit   -m x  --no-verify'
    assert_refused "$(printf 'git\tpush\t--no-verify')"
}

@test "allows a gate-change-ok: pattern in grep chained before an ordinary commit" {
    assert_allowed "grep -n 'gate-change-ok:' policy.txt && git commit -m 'docs: update policy'"
}

@test "refuses the commit's -F file even when an earlier command has a -F" {
    printf 'chore: x\n\ngate-change-ok: because\n' > bypass.txt
    assert_refused 'grep -F needle README.md && git commit -F bypass.txt'
}

@test "refuses a quoted -F filename containing spaces" {
    printf 'chore: x\n\ngate-change-ok: because\n' > 'commit message.txt'
    assert_refused 'git commit -F "commit message.txt"'
}

@test "refuses --file= and -Fpath spellings" {
    printf 'chore: x\n\ngate-change-ok: because\n' > msg.txt
    assert_refused 'git commit --file=msg.txt'
    assert_refused 'git commit -Fmsg.txt'
}

@test "resolves the -F file from the commit's cd directory" {
    mkdir sub
    printf 'chore: x\n\ngate-change-ok: because\n' > sub/msg.txt
    assert_refused "cd $TEST_TMP/sub && git commit -F msg.txt"
}

@test "resolves the -F file from the commit's git -C directory" {
    mkdir sub
    printf 'chore: x\n\ngate-change-ok: because\n' > sub/msg.txt
    assert_refused 'git -C sub commit -F msg.txt'
}

@test "refuses the bypass line in the second of two commits" {
    printf 'chore: x\n\ngate-change-ok: because\n' > bad.txt
    printf 'feat: fine\n' > ok.txt
    assert_refused 'git commit -F ok.txt && git commit -F bad.txt'
}

# --- relative -F resolution: apply every literal cd in order, otherwise fail closed ----------

@test "refuses a relative -F bypass file after a relative cd" {
    mkdir sub
    printf 'chore: x\n\ngate-change-ok: because\n' > sub/msg.txt
    assert_refused 'cd sub && git commit -F msg.txt'
}

@test "applies two chained cds in order" {
    mkdir -p a/b
    printf 'chore: x\n\ngate-change-ok: because\n' > a/b/msg.txt
    assert_refused 'cd a && cd b && git commit -F msg.txt'
}

@test "allows a relative -F ordinary file after chained cds" {
    mkdir -p a/b
    printf 'feat: fine\n' > a/b/msg.txt
    assert_allowed 'cd a && cd b && git commit -F msg.txt'
}

@test "fails closed on a relative -F after a cd with shell expansion" {
    printf 'feat: fine\n' > msg.txt
    run run_guard 'cd "$X" && git commit -F msg.txt'
    [ "$status" -eq 2 ]
    [[ "$output" == *"absolute -F path"* ]]
}

@test "fails closed on a relative -F after pushd or cd -" {
    printf 'feat: fine\n' > msg.txt
    run run_guard 'pushd sub && git commit -F msg.txt'
    [ "$status" -eq 2 ]
    run run_guard 'cd - && git commit -F msg.txt'
    [ "$status" -eq 2 ]
}

@test "fails closed on a relative -F that does not resolve to a readable file" {
    run run_guard 'git commit -F missing.txt'
    [ "$status" -eq 2 ]
    [[ "$output" == *"absolute -F path"* ]]
}

@test "checks an absolute -F path even after a cd with shell expansion" {
    printf 'chore: x\n\ngate-change-ok: because\n' > "$TEST_TMP/abs.txt"
    assert_refused "cd \"\$X\" && git commit -F $TEST_TMP/abs.txt"
}

@test "allows an absolute ordinary -F path after a cd with shell expansion" {
    printf 'feat: fine\n' > "$TEST_TMP/abs.txt"
    assert_allowed "cd \"\$X\" && git commit -F $TEST_TMP/abs.txt"
}

@test "fails closed on a relative -F with an expanded git -C" {
    printf 'feat: fine\n' > msg.txt
    run run_guard 'git -C "$D" commit -F msg.txt'
    [ "$status" -eq 2 ]
}

@test "allows non-Bash tools and empty commands" {
    run bash -c "jq -nc '{tool_name:\"Read\",tool_input:{file_path:\"x\"}}' | '$GUARD'"
    [ "$status" -eq 0 ]
    assert_allowed ''
}
