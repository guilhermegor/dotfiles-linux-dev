#!/usr/bin/env bats
#
# Tests for ai_clients/claude/hooks/agent_branch_push_guard.sh (dotfiles-linux-dev#715).
# Run locally:  bats tests/agent_branch_push_guard.bats

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/agent_branch_push_guard.sh"
    TEST_TMP="$(mktemp -d)"
    git init -q --bare -b main "$TEST_TMP/origin.git"
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

@test "the policy-compliant <type>/<N>-<slug> shape is a loop branch (#830)" {
    add_worktree chore/36-split-poe-tasks
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    remote_has chore/36-split-poe-tasks
}

@test "the older <type>/<slug>-<N> shape is still a loop branch (#830)" {
    add_worktree chore/split-poe-tasks-36
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    remote_has chore/split-poe-tasks-36
}

@test "is_loop_branch accepts both shapes and rejects main and feature/foo (#830)" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/loop_branch.sh"
    is_loop_branch chore/36-split-poe-tasks
    is_loop_branch chore/split-poe-tasks-36
    run is_loop_branch main
    [ "$status" -ne 0 ]
    run is_loop_branch feature/foo
    [ "$status" -ne 0 ]
}

@test "branch_list_has_issue finds the issue number in either shape, on a boundary (#830)" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/loop_branch.sh"
    local list=$'main\nchore/36-split-poe-tasks\nfix/other-thing-15'
    branch_list_has_issue "$list" 36
    branch_list_has_issue "$list" 15
    run branch_list_has_issue "$list" 5
    [ "$status" -ne 0 ]
    run branch_list_has_issue "$list" 6
    [ "$status" -ne 0 ]
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

@test "a cd inside a ( subshell ) does not move the parent shell" {
    add_worktree feat/some-thing-715
    run run_hook "$TEST_TMP" "( cd main && true ) && cd wt && git commit -m x"
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
    # Each event on its own, under its Bash matcher: a total of 2 could hide a missing event.
    run jq -e '[.hooks.PostToolUse, .hooks.PostToolUseFailure]
        | all(any(.[]; .matcher == "Bash" and any(.hooks[]; .command | test("agent_branch_push_guard"))))' "$S"
    [ "$status" -eq 0 ]
}

# --- #1074: PR-head targeting ---

add_tracking_worktree() {
    git -C "$TEST_TMP/main" worktree add -q -b "$1" "$TEST_TMP/wt" --track "$2"
    git -C "$TEST_TMP/wt" config user.email t@t
    git -C "$TEST_TMP/wt" config user.name t
    git -C "$TEST_TMP/wt" config commit.gpgsign false
    git -C "$TEST_TMP/wt" commit -q --allow-empty -m work
}

@test "a branch tracking a differently-named remote branch updates that branch (#1074)" {
    git -C "$TEST_TMP/main" push -q origin main:refs/heads/fix/pr-head-5
    git -C "$TEST_TMP/main" fetch -q origin
    add_tracking_worktree fix/9-review origin/fix/pr-head-5
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    refute_remote fix/9-review
    [ "$(git -C "$TEST_TMP/origin.git" rev-parse fix/pr-head-5)" = "$(git -C "$TEST_TMP/wt" rev-parse HEAD)" ]
}

@test "a branch cut from origin/main never pushes to main (#1074)" {
    git -C "$TEST_TMP/main" fetch -q origin
    add_tracking_worktree fix/9-thing origin/main
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    remote_has fix/9-thing
    [ "$(git -C "$TEST_TMP/origin.git" rev-parse main)" != "$(git -C "$TEST_TMP/wt" rev-parse HEAD)" ]
}

@test "no upstream and HEAD is an open PR head elsewhere: refuse, no side branch (#1074)" {
    add_worktree fix/9-review
    mkdir "$TEST_TMP/bin"
    printf '#!/bin/sh\nprintf '"'"'[{"head":{"ref":"fix/pr-head-5","sha":"%%s"}}]'"'"' "$(git rev-parse HEAD^)"\n' >"$TEST_TMP/bin/gh"
    chmod +x "$TEST_TMP/bin/gh"
    PATH="$TEST_TMP/bin:$PATH" run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fix/pr-head-5"* ]]
    refute_remote fix/9-review
}

@test "the open-PR lookup reads every page, so a PR head on page 2 is found (#1074)" {
    add_worktree fix/9-review
    mkdir "$TEST_TMP/bin"
    # Without --paginate --slurp the stub serves page 1 only (no match); with them, two pages.
    cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/bin/bash
case "$*" in
    *--paginate*--slurp*)
        printf '[[{"head":{"ref":"other","sha":"0"}}],[{"head":{"ref":"fix/pr-head-5","sha":"%s"}}]]' "$(git rev-parse HEAD^)" ;;
    *) printf '[{"head":{"ref":"other","sha":"0"}}]' ;;
esac
STUB
    chmod +x "$TEST_TMP/bin/gh"
    PATH="$TEST_TMP/bin:$PATH" run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fix/pr-head-5"* ]]
    refute_remote fix/9-review
}

@test "an upstream equal to the remote default is never pushed when origin/HEAD is absent (#1074)" {
    git -C "$TEST_TMP/origin.git" symbolic-ref HEAD refs/heads/develop
    git -C "$TEST_TMP/main" push -q origin main:refs/heads/develop
    git -C "$TEST_TMP/main" fetch -q origin
    run git -C "$TEST_TMP/main" symbolic-ref -q refs/remotes/origin/HEAD
    [ "$status" -ne 0 ]
    add_tracking_worktree fix/9-thing origin/develop
    run run_hook "$TEST_TMP/wt"
    [ "$status" -eq 0 ]
    remote_has fix/9-thing
    [ "$(git -C "$TEST_TMP/origin.git" rev-parse develop)" != "$(git -C "$TEST_TMP/wt" rev-parse HEAD)" ]
}
