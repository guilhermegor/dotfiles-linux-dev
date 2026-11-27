#!/usr/bin/env bats
#
# Every guard that sources lib/commit_command_matcher.sh must fail CLOSED (exit 2, stderr naming
# the missing file) when the lib cannot be sourced (dotfiles-linux-dev#1160). A bare `source`
# fails silently, leaves the matcher functions undefined, and the guard exits 0.
#
# Each case copies the guard (plus any sibling lib it needs, but NOT the matcher) to a temp dir.

HOOKS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/lib"
    cd "$TEST_TMP"
    git init -q -b main .
    git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init
}

teardown() {
    cd /
    rm -rf "$TEST_TMP"
}

run_without_matcher() {
    local guard="$1" cmd="$2"
    cp "$HOOKS/$guard" "$TEST_TMP/$guard"
    cp "$HOOKS/lib/stale_local_ref_gate.sh" "$TEST_TMP/lib/"
    run bash -c 'jq -nc --arg c "$1" "{tool_name:\"Bash\",tool_input:{command:\$c}}" | bash "$2"' _ "$cmd" "$TEST_TMP/$guard"
}

assert_closed() {
    [ "$status" -eq 2 ]
    [[ "$output" == *commit_command_matcher.sh* ]]
}

@test "#1160 protected_branch_guard blocks when the matcher lib is missing" {
    run_without_matcher protected_branch_guard.sh "git push origin main"
    assert_closed
}

@test "#1160 branch_requires_issue_guard blocks when the matcher lib is missing" {
    run_without_matcher branch_requires_issue_guard.sh "git checkout -b feature/x"
    assert_closed
}

@test "#1160 gate_bypass_guard blocks when the matcher lib is missing" {
    run_without_matcher gate_bypass_guard.sh "git commit --no-verify -m x"
    assert_closed
}

@test "#1160 commit_body_wrap blocks when the matcher lib is missing" {
    run_without_matcher commit_body_wrap.sh "git commit -m x"
    assert_closed
}

@test "#1160 commit_secret_guard blocks when the matcher lib is missing" {
    run_without_matcher commit_secret_guard.sh "git commit -m x"
    assert_closed
}

@test "#1160 commit_title_length_guard blocks when the matcher lib is missing" {
    run_without_matcher commit_title_length_guard.sh "git commit -m x"
    assert_closed
}

@test "#1160 stale_local_ref_gate (sourced lib) makes its caller block when the matcher is missing" {
    mkdir -p "$TEST_TMP/lib"
    cp "$HOOKS/stale_local_ref_guard.sh" "$TEST_TMP/"
    cp "$HOOKS/lib/stale_local_ref_gate.sh" "$TEST_TMP/lib/"
    run bash -c 'jq -nc "{tool_name:\"Bash\",tool_input:{command:\"git checkout main\"}}" | bash "$1"' _ "$TEST_TMP/stale_local_ref_guard.sh"
    assert_closed
}
