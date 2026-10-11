#!/usr/bin/env bats
#
# Tests for ai_clients/claude/hooks/agent_branch_push_guard.sh (dotfiles-linux-dev#715).
# Run locally:  bats tests/agent_branch_push_guard.bats

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/agent_branch_push_guard.sh"
    TEST_TMP="$(mktemp -d)"
    git init -q --bare "$TEST_TMP/origin.git"
    git init -q -b main "$TEST_TMP/main"
    cd "$TEST_TMP/main" || return 1
    git config user.email t@t && git config user.name t
    git config commit.gpgsign false
    git commit -q --allow-empty -m init
    git remote add origin "$TEST_TMP/origin.git"
    git push -q origin main
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_hook() {
    local cwd="$1" cmd="${2:-git commit -m x}"
    jq -n --arg c "$cwd" --arg m "$cmd" '{cwd:$c,tool_input:{command:$m}}' | bash "$HOOK"
}

add_worktree() {
    git -C "$TEST_TMP/main" worktree add -q -b "$1" "$TEST_TMP/wt" main
    git -C "$TEST_TMP/wt" config user.email t@t
    git -C "$TEST_TMP/wt" config user.name t
    git -C "$TEST_TMP/wt" config commit.gpgsign false
    git -C "$TEST_TMP/wt" commit -q --allow-empty -m work
}

remote_has() {
    git -C "$TEST_TMP/origin.git" rev-parse --verify -q "refs/heads/$1" >/dev/null
}

refute_remote() {
    run remote_has "$1"
    [ "$status" -ne 0 ]
}

@test "loop-owned branch in a linked worktree is pushed after a commit" {
    add_worktree feat/some-thing-715
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    remote_has feat/some-thing-715
}

@test "a non-commit Bash command pushes nothing" {
    add_worktree feat/some-thing-715
    run run_hook "$TEST_TMP/wt" "git status"
    [ "$status" -eq 0 ]
    refute_remote feat/some-thing-715
}

@test "a branch without the issue-number suffix is untouched" {
    add_worktree feat/adhoc-experiment
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    refute_remote feat/adhoc-experiment
}

@test "a prefix outside the dispatch set is untouched" {
    add_worktree wip/some-thing-715
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    refute_remote wip/some-thing-715
}

@test "the main checkout is untouched even on a loop-shaped branch" {
    git -C "$TEST_TMP/main" checkout -q -b fix/thing-9
    git -C "$TEST_TMP/main" commit -q --allow-empty -m work
    run run_hook "$TEST_TMP/main"
    [ "$status" -eq 0 ]
    refute_remote fix/thing-9
}

@test "an unreachable remote never blocks and leaves a pending marker" {
    add_worktree fix/thing-8
    git -C "$TEST_TMP/wt" remote set-url origin "$TEST_TMP/missing.git"
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    [ -f "$(git -C "$TEST_TMP/wt" rev-parse --absolute-git-dir)/pending-push" ]
}

@test "a pending marker is cleared once the push succeeds" {
    add_worktree fix/thing-8
    git -C "$TEST_TMP/wt" remote set-url origin "$TEST_TMP/missing.git"
    run_hook "$TEST_TMP/wt"
    git -C "$TEST_TMP/wt" remote set-url origin "$TEST_TMP/origin.git"
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    remote_has fix/thing-8
    [ ! -f "$(git -C "$TEST_TMP/wt" rev-parse --absolute-git-dir)/pending-push" ]
}

@test "an absolute git path still triggers the push" {
    add_worktree feat/some-thing-715
    run run_hook "$TEST_TMP/wt" "/usr/bin/git commit -m x"
    [ "$status" -eq 0 ]
    remote_has feat/some-thing-715
}

@test "git -C pushes the worktree it names, not the shell's cwd" {
    add_worktree feat/some-thing-715
    run run_hook "$TEST_TMP/main" "git -C $TEST_TMP/wt commit -m x"
    [ "$status" -eq 0 ]
    remote_has feat/some-thing-715
}

@test "a leading cd decides which worktree is pushed" {
    add_worktree feat/some-thing-715
    run run_hook "$TEST_TMP/main" "cd $TEST_TMP/wt && git commit -m x"
    [ "$status" -eq 0 ]
    remote_has feat/some-thing-715
}

@test "git -C from another loop worktree does not push that worktree's branch" {
    add_worktree feat/some-thing-715
    git -C "$TEST_TMP/main" worktree add -q -b fix/other-9 "$TEST_TMP/wt2" main
    run run_hook "$TEST_TMP/wt" "git -C $TEST_TMP/main commit -m x"
    [ "$status" -eq 0 ]
    refute_remote feat/some-thing-715
}

@test "chained cds resolve each relative to the last" {
    add_worktree feat/some-thing-715
    run run_hook "$TEST_TMP" "cd $TEST_TMP && cd wt && git commit -m x"
    [ "$status" -eq 0 ]
    remote_has feat/some-thing-715
}

@test "a cd after || is not applied (it may never run)" {
    add_worktree feat/some-thing-715
    run run_hook "$TEST_TMP/wt" "cd $TEST_TMP/wt || cd $TEST_TMP/main && git commit -m x"
    [ "$status" -eq 0 ]
    remote_has feat/some-thing-715
}

@test "git -C with a quoted path containing spaces is resolved" {
    git -C "$TEST_TMP/main" worktree add -q -b feat/some-thing-715 "$TEST_TMP/wt dir" main
    git -C "$TEST_TMP/wt dir" commit -q --allow-empty -m work
    run run_hook "$TEST_TMP/main" "git -C \"$TEST_TMP/wt dir\" commit -m x"
    [ "$status" -eq 0 ]
    remote_has feat/some-thing-715
}

@test "a commit followed by a failing command still pushes (PostToolUseFailure payload)" {
    add_worktree feat/some-thing-715
    run run_hook "$TEST_TMP/wt" "git commit -m x && false"
    [ "$status" -eq 0 ]
    remote_has feat/some-thing-715
}

@test "settings.json registers the guard on both PostToolUse and PostToolUseFailure" {
    S="$BATS_TEST_DIRNAME/../ai_clients/claude/settings.json"
    run jq -e '[.hooks.PostToolUse[].hooks[].command, .hooks.PostToolUseFailure[].hooks[].command] | map(select(test("agent_branch_push_guard"))) | length == 2' "$S"
    [ "$status" -eq 0 ]
}
