#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/stale_local_ref_gate.sh and its
# PreToolUse caller, ai_clients/claude/hooks/stale_local_ref_guard.sh
# (dotfiles-linux-dev#410).
#
# Strategy: a real, hermetic git repo built with `mktemp -d` — no gh, no
# network. A remote-tracking ref is faked with `git update-ref
# refs/remotes/origin/<branch> <sha>` rather than an actual clone/push, which
# is equivalent for what the gate reads and far cheaper. This reproduces the
# measured defect directly: `git worktree add <path> fix/precommit-ci-parity-
# 384` (blueprintx#512) checked out a local ref 3 commits behind the real PR
# head and a review pass refuted real findings as "not in this PR".
#
# Per ai_clients/CLAUDE.md's gate contract, both halves are covered:
#   - success returns a usable, non-empty answer on fixtures that provably
#     differ (fresh / ahead / stale / no_remote), and
#   - the unreadable path is exercised deliberately (no branch name, and a
#     directory that is not a git repo at all), asserting STALE_REF_STATUS
#     never reads "clean"/"fresh" and STALE_REF_DETAIL says why.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    GATE="$REPO_ROOT/ai_clients/claude/hooks/lib/stale_local_ref_gate.sh"
    HOOK="$REPO_ROOT/ai_clients/claude/hooks/stale_local_ref_guard.sh"
    TEST_TMP="$(mktemp -d)"
    REPO="$TEST_TMP/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init --quiet -b master
    git -C "$REPO" config user.email t@t.example
    git -C "$REPO" config user.name t
    write_commit "base"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# write_commit MESSAGE — one commit on the current branch in $REPO.
write_commit() {
    echo "$1" >>"$REPO/f.txt"
    git -C "$REPO" add f.txt
    git -C "$REPO" commit --quiet -m "$1"
}

# new_branch NAME — branch off current HEAD in $REPO.
new_branch() {
    git -C "$REPO" checkout --quiet -b "$1"
}

# track_origin NAME — point refs/remotes/origin/<NAME> at its current tip,
# faking "already pushed" without a real remote.
track_origin() {
    local sha
    sha="$(git -C "$REPO" rev-parse "$1")"
    git -C "$REPO" update-ref "refs/remotes/origin/$1" "$sha"
}

run_gate() {
    run bash -c "
        cd '$REPO' || exit 1
        source '$GATE'
        gate_stale_local_ref '$1'
        echo \"status=\$STALE_REF_STATUS\"
        echo \"detail=\$STALE_REF_DETAIL\"
    "
}

run_extract() {
    run bash -c 'source "$1"; stale_ref_target "$2"' _ "$GATE" "$1"
}

run_hook() {
    local json
    json="$(jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}')"
    run bash -c "cd '$REPO' && printf '%s' '$json' | '$HOOK'"
}

# --- gate_stale_local_ref: the decision table -----------------------------------------------

@test "gate: local == origin -> fresh, empty detail" {
    new_branch feature
    write_commit f1
    track_origin feature
    run_gate feature
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "status=fresh" ]
    [ "${lines[1]}" = "detail=" ]
}

@test "gate: local ahead of origin -> allowed, names it ordinary unpushed work" {
    new_branch feature
    write_commit f1
    track_origin feature
    write_commit f2
    run_gate feature
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "status=ahead" ]
    [[ "$output" == *"ordinary unpushed work"* ]]
}

@test "gate: local behind origin -> stale, the measured defect (blueprintx#512)" {
    new_branch feature
    write_commit f1
    write_commit f2
    track_origin feature
    git -C "$REPO" reset --quiet --hard HEAD~1
    run_gate feature
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "status=stale" ]
    [[ "$output" == *"local ref is behind origin"* ]]
    [[ "$output" == *"origin/feature"* ]]
}

@test "gate: no remote counterpart -> no_remote, nothing to compare" {
    new_branch scratch
    write_commit f1
    run_gate scratch
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "status=no_remote" ]
    [[ "$output" == *"no such remote branch"* ]]
}

@test "gate: not a local branch at all -> no_local" {
    run_gate does-not-exist
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "status=no_local" ]
}

# --- the unreadable path, exercised deliberately (gate contract, ai_clients/CLAUDE.md) --------

@test "gate: no branch name given -> unreadable, never a fresh/stale verdict" {
    run_gate ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=unreadable"* ]]
    [[ "$output" != *"status=fresh"* ]]
    [[ "$output" != *"status=stale"* ]]
    [[ "$output" == *"could not read either ref"* ]]
}

@test "gate: not inside a git working tree -> unreadable, says so" {
    local outside="$TEST_TMP/not-a-repo"
    mkdir -p "$outside"
    run bash -c "
        cd '$outside' || exit 1
        source '$GATE'
        gate_stale_local_ref anything
        echo \"status=\$STALE_REF_STATUS\"
        echo \"detail=\$STALE_REF_DETAIL\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=unreadable"* ]]
    [[ "$output" == *"could not read either ref"* ]]
}

# --- stale_ref_target: extraction must not cross into branch-CREATION commands ----------------

@test "extract: git checkout <branch>" {
    run_extract "git checkout feature"
    [ "$status" -eq 0 ]
    [ "$output" = "feature" ]
}

@test "extract: git switch <branch>" {
    run_extract "git switch feature"
    [ "$status" -eq 0 ]
    [ "$output" = "feature" ]
}

@test "extract: rtk-prefixed checkout" {
    run_extract "rtk git checkout feature"
    [ "$status" -eq 0 ]
    [ "$output" = "feature" ]
}

@test "extract: git worktree add <path> <branch>" {
    run_extract "git worktree add /tmp/wt feature"
    [ "$status" -eq 0 ]
    [ "$output" = "feature" ]
}

@test "extract: skips checkout -b (branch creation, a different guard's job)" {
    run_extract "git checkout -b newbranch"
    [ "$status" -eq 1 ]
}

@test "extract: skips switch -c (branch creation)" {
    run_extract "git switch -c newbranch"
    [ "$status" -eq 1 ]
}

@test "extract: skips worktree add -b (branch creation from a start-point)" {
    run_extract "git worktree add /tmp/wt -b newbranch master"
    [ "$status" -eq 1 ]
}

@test "extract: skips a checkout with a trailing pathspec" {
    run_extract "git checkout feature -- file.txt"
    [ "$status" -eq 1 ]
}

@test "extract: skips a dynamically-expanded branch name" {
    run_extract 'git checkout $BRANCH'
    [ "$status" -eq 1 ]
}

@test "extract: matches a checkout chained after another command" {
    run_extract "git status && git checkout feature"
    [ "$status" -eq 0 ]
    [ "$output" = "feature" ]
}

# --- the hook: PreToolUse contract, block/allow by exit code ----------------------------------

@test "hook: blocks a stale checkout, names the origin-qualified form" {
    new_branch feature
    write_commit f1
    write_commit f2
    track_origin feature
    git -C "$REPO" reset --quiet --hard HEAD~1
    run_hook "git checkout feature"
    [ "$status" -eq 2 ]
    [[ "$output" == *"BLOCKED"* ]]
    [[ "$output" == *"behind origin"* ]]
    [[ "$output" == *"origin/feature"* ]]
}

@test "hook: allows an ahead checkout" {
    new_branch feature
    write_commit f1
    track_origin feature
    write_commit f2
    run_hook "git checkout feature"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook: allows a fresh checkout" {
    new_branch feature
    write_commit f1
    track_origin feature
    run_hook "git checkout feature"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook: escape hatch bypasses a stale block" {
    new_branch feature
    write_commit f1
    write_commit f2
    track_origin feature
    git -C "$REPO" reset --quiet --hard HEAD~1
    run_hook "ALLOW_STALE_LOCAL_REF=1 git checkout feature"
    [ "$status" -eq 0 ]
}

@test "hook: never blocks worktree add -b (branch creation)" {
    run_hook "git worktree add /tmp/wt-410 -b newbranch master"
    [ "$status" -eq 0 ]
}

@test "hook: ignores a non-Bash tool call" {
    run bash -c "cd '$REPO' && printf '%s' '{\"tool_name\":\"Read\"}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
