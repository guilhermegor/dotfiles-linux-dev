#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/dispatch_claims.sh — the agent-vs-agent claims
# registry (dotfiles-dev#405 scope 1).
#
# Strategy: the lib is SOURCED (it is a library, not a hook), against a throwaway real git repo
# so `git rev-parse --git-common-dir` has a real answer and the registry lands in a real, shared
# directory. No `gh` stub is needed anywhere in this suite — `claim_files` makes zero API calls
# by design (scope 5), and the one function that does read the gate (`refresh_pr_held_paths`)
# takes it via `declare -F gate_free_surface`, so a plain shell function stands in for it.
#
# The race test is the load-bearing one and it is a REAL race: N background subshells, each a
# separate process calling claim_files on the same path, joined with `wait`. A sequential
# "claim twice" test would pass against a check-then-append implementation with no lock at all.
#
# Run locally:  bats tests/dispatch_claims.bats

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/dispatch_claims.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP" || return 1
    git init -q -b main .
    git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init
    # shellcheck source=/dev/null
    source "$LIB"
}

teardown() {
    rm -rf "$TEST_TMP"
}

refute() {
    run "$@"
    [ "$status" -ne 0 ]
}

# --- the registry's happy path -------------------------------------------------------------

@test "a free path is CLAIMED and recorded in the shared git common dir" {
    run claim_files 405 "a/b.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAIMED" ]
    [ -s "$TEST_TMP/.git/dispatch-claims.tsv" ]
    run cut -f2,3 "$TEST_TMP/.git/dispatch-claims.tsv"
    [ "$output" = "405	a/b.sh" ]
}

@test "the registry is shared by every worktree of the repo, not per worktree" {
    claim_files 405 "a/b.sh"
    git worktree add -q "$TEST_TMP/wt" -b other main
    cd "$TEST_TMP/wt" || return 1
    # A second worktree resolves the same common dir, so it sees the first agent's claim.
    run dispatch_claimed_issues
    [ "$output" = "405" ]
    run claim_files 406 "a/b.sh"
    [ "$status" -ne 0 ]
    [ "$output" = "HELD:#405:a/b.sh" ]
}

@test "re-claiming a path this same issue already holds is idempotent" {
    claim_files 405 "a/b.sh"
    run claim_files 405 "a/b.sh" "a/c.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAIMED" ]
    run cut -f2,3 "$TEST_TMP/.git/dispatch-claims.tsv"
    [ "${#lines[@]}" -eq 2 ]
}

@test "release_claims frees the path for another issue" {
    claim_files 405 "a/b.sh"
    release_claims 405
    run dispatch_claimed_issues
    [ -z "$output" ]
    run claim_files 406 "a/b.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAIMED" ]
}

@test "release_claims leaves every other issue's claims alone" {
    claim_files 405 "a/b.sh"
    claim_files 406 "c/d.sh"
    release_claims 405
    run dispatch_claimed_issues
    [ "$output" = "406" ]
}

# --- the race: exactly one winner ----------------------------------------------------------

@test "a two-agent race on one path produces exactly one CLAIMED" {
    # Two real processes, started together, both claiming the same path.
    ( claim_files 405 "a/b.sh" >"$TEST_TMP/out.405" 2>&1 ) &
    ( claim_files 406 "a/b.sh" >"$TEST_TMP/out.406" 2>&1 ) &
    wait

    run grep -lx CLAIMED "$TEST_TMP/out.405" "$TEST_TMP/out.406"
    [ "${#lines[@]}" -eq 1 ]
    run grep -h '^HELD:' "$TEST_TMP/out.405" "$TEST_TMP/out.406"
    [ "${#lines[@]}" -eq 1 ]
    # And the registry holds the winner only — never both.
    run cut -f2 "$TEST_TMP/.git/dispatch-claims.tsv"
    [ "${#lines[@]}" -eq 1 ]
}

@test "an eight-agent race on one path still produces exactly one CLAIMED" {
    # The measured batch size (dotfiles-dev#405 scope 1: 8 agents in one blueprintx round).
    local i
    for i in 1 2 3 4 5 6 7 8; do
        ( claim_files "50$i" "a/b.sh" >"$TEST_TMP/out.$i" 2>&1 ) &
    done
    wait
    run grep -lx CLAIMED "$TEST_TMP"/out.*
    [ "${#lines[@]}" -eq 1 ]
    run cut -f2 "$TEST_TMP/.git/dispatch-claims.tsv"
    [ "${#lines[@]}" -eq 1 ]
}

@test "a racer that loses on the SECOND path claims nothing at all" {
    # All-or-nothing: a partial claim would leave the loser holding one path of a surface it
    # was refused, which is a deadlock nobody releases.
    claim_files 405 "second.sh"
    run claim_files 406 "first.sh" "second.sh"
    [ "$status" -ne 0 ]
    [ "$output" = "HELD:#405:second.sh" ]
    refute grep -qF "406" "$TEST_TMP/.git/dispatch-claims.tsv"
}

# --- a path an open PR already holds -------------------------------------------------------

@test "a path held by an open PR is refused, naming the holder" {
    printf 'open-pr\t%s\n' "a/b.sh" >"$TEST_TMP/.git/pr-held-paths.tsv"
    run claim_files 405 "a/b.sh"
    [ "$status" -ne 0 ]
    [ "$output" = "HELD:open-pr:a/b.sh" ]
}

@test "the PR held-paths read is exact-path, never a prefix match" {
    # Same rule free_classify_files enforces (dotfiles-dev#340): a directory-level match
    # reported 9 of 11 candidates as colliding when the exact recount said 97% free.
    printf 'open-pr\t%s\n' "a/b.sh" >"$TEST_TMP/.git/pr-held-paths.tsv"
    run claim_files 405 "a/b.sh.orig"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAIMED" ]
}

@test "refresh_pr_held_paths writes the gate's held union once, with no per-agent gh call" {
    gate_free_surface() {
        FREE_STATUS=ok
        FREE_HELD_PATHS="$(printf 'x/y.sh\nz/w.py\n')"
        GATE_CALLS=$((${GATE_CALLS:-0} + 1))
    }
    GATE_CALLS=0
    refresh_pr_held_paths acme widgets
    [ "$GATE_CALLS" -eq 1 ]
    run cut -f2 "$TEST_TMP/.git/pr-held-paths.tsv"
    [ "${#lines[@]}" -eq 2 ]
    # Every subsequent claim reads that file and never the gate again.
    run claim_files 405 "x/y.sh"
    [ "$output" = "HELD:open-pr:x/y.sh" ]
}

@test "refresh_pr_held_paths fails closed when the gate itself fails" {
    gate_free_surface() {
        FREE_STATUS=unknown
        FREE_HELD_PATHS=""
        return 1
    }
    refute refresh_pr_held_paths acme widgets
    # Never a written-but-empty file, which every later claim would read as "nothing is held".
    [ ! -e "$TEST_TMP/.git/pr-held-paths.tsv" ]
}

# --- fail-closed and self-healing ----------------------------------------------------------

@test "a claim with no paths is UNKNOWN, never a granted empty claim" {
    run claim_files 405
    [ "$status" -ne 0 ]
    [ "$output" = "UNKNOWN" ]
}

@test "an undecidable claim (no flock on PATH) is UNKNOWN, never CLAIMED" {
    # Fail CLOSED: a claim that cannot be proven exclusive must not read as granted — that is
    # the input that puts two agents in one file. PATH is emptied for the CALL only, in a child
    # process: emptying it in the test body itself takes mkdir/rm down with it, including
    # teardown's.
    mkdir -p "$TEST_TMP/emptybin"
    run env PATH="$TEST_TMP/emptybin" /bin/bash -c \
        'cd "$2" || exit 9; . "$1"; claim_files 405 a/b.sh' _ "$LIB" "$TEST_TMP"
    [ "$status" -ne 0 ]
    [ "$output" = "UNKNOWN" ]
}

@test "a claim outside a git repo is UNKNOWN, never CLAIMED" {
    # A directory under $TEST_TMP would resolve upward to its repo, so this one is a sibling
    # temp dir with no repo above it at all.
    NOREPO="$(mktemp -d)"
    cd "$NOREPO" || return 1
    run claim_files 405 "a/b.sh"
    rm -rf "$NOREPO"
    [ "$status" -ne 0 ]
    [ "$output" = "UNKNOWN" ]
}

@test "a claim past its TTL stops holding its paths" {
    # A killed agent never calls release_claims. Without expiry the registry reads
    # "everything is in flight" forever, and a guard that never fires is dotfiles-dev#404
    # with a different cause.
    claim_files 405 "a/b.sh"
    DISPATCH_CLAIM_TTL=0
    run dispatch_claimed_issues
    [ -z "$output" ]
    run claim_files 406 "a/b.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAIMED" ]
}

@test "a live claim is not expired by a generous TTL" {
    claim_files 405 "a/b.sh"
    DISPATCH_CLAIM_TTL=7200
    run dispatch_claimed_issues
    [ "$output" = "405" ]
}

@test "the concurrency cap default is the measured 8, and is overridable" {
    # Sourced with the variable explicitly unset, so an ambient DISPATCH_MAX_CONCURRENT in the
    # runner's own environment cannot make this assert something other than the default.
    run /bin/bash -c 'unset DISPATCH_MAX_CONCURRENT; . "$1"; echo "$DISPATCH_MAX_CONCURRENT"' _ "$LIB"
    [ "$output" = "8" ]
    run /bin/bash -c 'DISPATCH_MAX_CONCURRENT=3; . "$1"; echo "$DISPATCH_MAX_CONCURRENT"' _ "$LIB"
    [ "$output" = "3" ]
}

@test "the blueprintx#314 surface-label prefix is one empty constant, not an invented format" {
    # Empty means "the label convention has not shipped", never "the issue declared nothing".
    [ -z "$DISPATCH_SURFACE_LABEL_PREFIX" ]
    [ "$DISPATCH_UNDECLARED_TOKEN" = "UNDECLARED" ]
}
