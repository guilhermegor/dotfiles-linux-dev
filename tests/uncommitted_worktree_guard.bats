#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/uncommitted_worktree_guard.sh (dotfiles-linux-dev#167,
# parked-owner declaration #1139).
#
# The hook is a stdin->exit-code filter: exit 2 blocks the stop, exit 1 surfaces stderr without
# blocking, exit 0 passes silently. Run it as a real subprocess against a throwaway git repo.
#
# Run locally:  bats tests/uncommitted_worktree_guard.bats

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HOOK="$ROOT/ai_clients/claude/hooks/uncommitted_worktree_guard.sh"
    LIB="$ROOT/ai_clients/claude/hooks/lib/dispatch_claims.sh"
    REPO="$(mktemp -d)"
    export TMPDIR="$REPO/tmp"
    mkdir -p "$TMPDIR"
    WT="$REPO/wt"
    mkdir -p "$WT"
    cd "$WT" || return 1
    git init -q -b main .
    git config user.email t@t && git config user.name t
    echo one >f.txt && git add f.txt && git commit -q -m init
    echo two >>f.txt
}

teardown() {
    rm -rf "$REPO"
}

run_hook() { # [SESSION_ID]
    run bash -c "jq -nc --arg c '$WT' --arg s '${1:-sess}' '{cwd: \$c, session_id: \$s}' | '$HOOK'"
}

park() { # REASON  (parks the worktree at its current HEAD)
    (cd "$WT" && source "$LIB" && park_owner worktree "$WT" "$(git rev-parse HEAD)" "$1" /tmp/b.patch)
}

@test "a clean worktree passes" {
    git -C "$WT" checkout -q -- f.txt
    run_hook
    [ "$status" -eq 0 ]
}

@test "should-fail witness: uncommitted changes with NO parked entry still block the stop (#1139)" {
    run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"uncommitted changes"* ]]
}

@test "a live parked entry is reported once per session instead of blocking (#1139)" {
    park "owner-only commit"
    run_hook
    [ "$status" -eq 1 ]
    [[ "$output" == *"owner-only commit"* ]]
    [[ "$output" == *"/tmp/b.patch"* ]]
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the once-per-session report is per session: a new session hears it again (#1139)" {
    park "owner-only commit"
    run_hook s1
    [ "$status" -eq 1 ]
    run_hook s2
    [ "$status" -eq 1 ]
}

@test "an entry expires when the worktree HEAD moves, and the stop blocks again (#1139)" {
    park "owner-only commit"
    git -C "$WT" commit -q -am "moved"
    echo three >>"$WT/f.txt"
    run_hook
    [ "$status" -eq 2 ]
    [[ "$output" != *"owner-only commit"* ]]
}

@test "an entry for another worktree does not park this one (#1139)" {
    (cd "$WT" && source "$LIB" && park_owner worktree /elsewhere "$(git rev-parse HEAD)" why /tmp/b.patch)
    run_hook
    [ "$status" -eq 2 ]
}

@test "an unreadable parked-owner.tsv fails closed: the stop blocks (#1139)" {
    mkdir "$WT/.git/parked-owner.tsv"
    run_hook
    [ "$status" -eq 2 ]
}

@test "stop_hook_active still passes without reading anything" {
    run bash -c "jq -nc --arg c '$WT' '{cwd: \$c, stop_hook_active: true}' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "new dirt outside the set recorded at park time blocks the stop (#1141)" {
    park "owner-only commit"
    echo new >"$WT/unrelated.txt"
    run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"unrelated.txt"* ]]
}

@test "a further edit to an already-parked path stays parked (#1141)" {
    park "owner-only commit"
    echo more >>"$WT/f.txt"
    run_hook
    [ "$status" -eq 1 ]
}
