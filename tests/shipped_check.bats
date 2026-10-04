#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/shipped_check.sh (dotfiles-linux-dev#427).
#
# Both halves of a gate's contract (ai_clients/CLAUDE.md, "A gate's contract"):
#   1. Success returns a usable answer -- SHIPPED_STATUS/SHIPPED_DETAIL are set
#      and non-empty on a fixture that provably has the deliverable present
#      (and, separately, provably missing).
#   2. The fail-closed path is exercised deliberately -- a stubbed `gh` failure
#      must leave SHIPPED_STATUS=UNKNOWN, never SHIPPED or OPEN.
#
# The content probe runs against a real, throwaway git repo (not a stub) --
# it's the one part of the gate that must actually exercise `git cat-file`/
# `git show` against a genuine `origin/master` ref, faked here via
# `update-ref refs/remotes/origin/master` with no real remote required.
#
# Run locally: bats tests/shipped_check.bats

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/shipped_check.sh"
    REPO_DIR="$(mktemp -d)"
    git -C "$REPO_DIR" init -q -b master
    git -C "$REPO_DIR" config user.email "test@example.com"
    git -C "$REPO_DIR" config user.name "test"
    echo "shipped content" > "$REPO_DIR/present.txt"
    git -C "$REPO_DIR" add present.txt
    git -C "$REPO_DIR" commit -q -m "seed"
    git -C "$REPO_DIR" update-ref refs/remotes/origin/master master
    git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
}

teardown() {
    rm -rf "$REPO_DIR"
}

# gh_stub_merged_link JSON: a merged PR whose closingIssuesReferences names issue 1.
gh_stub_merged_link() {
    jq -nc '[{number:9,state:"MERGED",closingIssuesReferences:[{number:1}]}]'
}

@test "shipped_check: all deliverables present -> SHIPPED with usable, non-empty detail" {
    local fixture
    fixture="$(mktemp)"
    gh_stub_merged_link > "$fixture"

    run env REPO_DIR="$REPO_DIR" LIB="$LIB" GH_FIXTURE="$fixture" bash -c '
        cd "$REPO_DIR"
        gh() { cat "$GH_FIXTURE"; }
        source "$LIB"
        shipped_check 1 o/r "present.txt"
        echo "status=$SHIPPED_STATUS"
        echo "detail=$SHIPPED_DETAIL"
    '
    rm -f "$fixture"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=SHIPPED"* ]]
    [[ "$output" == *"PRESENT present.txt"* ]]
    [[ "$output" == *"present=1 missing=0 of 1"* ]]
    [[ "$output" == *"merged PR #9 links this issue"* ]]
}

@test "shipped_check: one missing deliverable -> OPEN, names the missing one" {
    local fixture
    fixture="$(mktemp)"
    jq -nc '[]' > "$fixture"

    run env REPO_DIR="$REPO_DIR" LIB="$LIB" GH_FIXTURE="$fixture" bash -c '
        cd "$REPO_DIR"
        gh() { cat "$GH_FIXTURE"; }
        source "$LIB"
        shipped_check 1 o/r "present.txt" "missing.txt"
        echo "status=$SHIPPED_STATUS"
        echo "detail=$SHIPPED_DETAIL"
    '
    rm -f "$fixture"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=OPEN"* ]]
    [[ "$output" == *"PRESENT present.txt"* ]]
    [[ "$output" == *"MISSING missing.txt"* ]]
    [[ "$output" == *"present=1 missing=1 of 2"* ]]
    [[ "$output" == *"no merged PR linked this issue"* ]]
}

@test "shipped_check: no origin/HEAD symref -> UNKNOWN, never guesses origin/master" {
    local no_head_repo
    no_head_repo="$(mktemp -d)"
    git -C "$no_head_repo" init -q -b master
    git -C "$no_head_repo" config user.email "test@example.com"
    git -C "$no_head_repo" config user.name "test"
    echo x > "$no_head_repo/present.txt"
    git -C "$no_head_repo" add present.txt
    git -C "$no_head_repo" commit -q -m "seed"
    git -C "$no_head_repo" update-ref refs/remotes/origin/master master
    # deliberately no `git symbolic-ref refs/remotes/origin/HEAD` -- the
    # unconfigured-remote-HEAD case this fix guards against.

    run env REPO_DIR="$no_head_repo" LIB="$LIB" bash -c '
        cd "$REPO_DIR"
        gh() { echo should-not-be-called; return 1; }
        source "$LIB"
        shipped_check 1 o/r "present.txt"
        echo "status=$SHIPPED_STATUS"
        echo "detail=$SHIPPED_DETAIL"
    '
    rm -rf "$no_head_repo"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=UNKNOWN"* ]]
    [[ "$output" == *"origin/HEAD not resolvable"* ]]
}

@test "shipped_check: gh failure fails closed to UNKNOWN, never SHIPPED/OPEN" {
    run env REPO_DIR="$REPO_DIR" LIB="$LIB" bash -c '
        cd "$REPO_DIR"
        gh() { return 1; }
        source "$LIB"
        shipped_check 1 o/r "present.txt"
        echo "status=$SHIPPED_STATUS"
        echo "detail=$SHIPPED_DETAIL"
    '

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=UNKNOWN"* ]]
    [[ "$output" != *"status=SHIPPED"* ]]
    [[ "$output" != *"status=OPEN"* ]]
    [[ "$output" == *"gh pr list failed"* ]]
}
