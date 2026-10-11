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
