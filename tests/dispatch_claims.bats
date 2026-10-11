#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/dispatch_claims.sh — the agent-vs-agent claims
# registry (dotfiles-linux-dev#405 scope 1).
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
    # The measured batch size (dotfiles-linux-dev#405 scope 1: 8 agents in one blueprintx round).
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
    # Same rule free_classify_files enforces (dotfiles-linux-dev#340): a directory-level match
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
    # "everything is in flight" forever, and a guard that never fires is dotfiles-linux-dev#404
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

# --- the shared review-ask budget (dotfiles-linux-dev#548) --------------------------------------

@test "the first review ask is GRANTED and recorded in the shared git common dir" {
    run claim_review_ask
    [ "$status" -eq 0 ]
    [ "$output" = "GRANTED" ]
    [ -s "$TEST_TMP/.git/dispatch-review-ask.tsv" ]
}

@test "a second ask inside the TTL window is BUSY, from any reader" {
    claim_review_ask
    run claim_review_ask
    [ "$status" -ne 0 ]
    [ "$output" = "BUSY" ]
}

@test "the ask budget is shared by every worktree of the repo, not per worktree" {
    claim_review_ask
    git worktree add -q "$TEST_TMP/wt-ask" -b other-ask main
    cd "$TEST_TMP/wt-ask" || return 1
    # A subagent in its own worktree sees the orchestrator's ask and is refused too.
    run claim_review_ask
    [ "$status" -ne 0 ]
    [ "$output" = "BUSY" ]
}

@test "an ask past DISPATCH_REVIEW_ASK_TTL is GRANTED again" {
    claim_review_ask
    DISPATCH_REVIEW_ASK_TTL=0
    run claim_review_ask
    [ "$status" -eq 0 ]
    [ "$output" = "GRANTED" ]
}

@test "an undecidable ask (no flock on PATH) is UNKNOWN, never GRANTED" {
    mkdir -p "$TEST_TMP/emptybin"
    run env PATH="$TEST_TMP/emptybin" /bin/bash -c \
        'cd "$2" || exit 9; . "$1"; claim_review_ask' _ "$LIB" "$TEST_TMP"
    [ "$status" -ne 0 ]
    [ "$output" = "UNKNOWN" ]
}

@test "the review-ask TTL default is the tick cadence, and is overridable" {
    run /bin/bash -c 'unset DISPATCH_REVIEW_ASK_TTL; . "$1"; echo "$DISPATCH_REVIEW_ASK_TTL"' _ "$LIB"
    [ "$output" = "1200" ]
    run /bin/bash -c 'DISPATCH_REVIEW_ASK_TTL=60; . "$1"; echo "$DISPATCH_REVIEW_ASK_TTL"' _ "$LIB"
    [ "$output" = "60" ]
    run /bin/bash -c 'DISPATCH_REVIEW_ASK_TTL=10m; . "$1"; echo "$DISPATCH_REVIEW_ASK_TTL"' _ "$LIB"
    [ "$output" = "1200" ]
    run /bin/bash -c 'DISPATCH_REVIEW_ASK_TTL=abc; . "$1"; echo "$DISPATCH_REVIEW_ASK_TTL"' _ "$LIB"
    [ "$output" = "1200" ]
}

@test "the UNDECLARED token matches the one dispatch_plan.py emits" {
    # One word, two languages: the planner emits it in its exclusion reason and the guard greps
    # for it. Pinning both sides to the same literal here is what keeps them from drifting.
    [ "$DISPATCH_UNDECLARED_TOKEN" = "UNDECLARED" ]
    run grep -c "^UNDECLARED_TOKEN = \"$DISPATCH_UNDECLARED_TOKEN\"$" \
        "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/dispatch_plan.py"
    [ "$output" = "1" ]
}

# --- forge-aware HELD (dotfiles-linux-dev#715) ---------------------------------------------
# `gh` and `curl` are stubs on PATH driven by files in $STUB: graphql.json (cards), branches.json,
# issue-<N>.json (REST issue body), and fail-gh / fail-curl switches. Calls are counted.

forge_stub() {
    STUB="$TEST_TMP/stub"
    mkdir -p "$STUB/bin"
    cat >"$STUB/bin/gh" <<'SH'
#!/bin/bash
echo x >>"$STUB/gh-calls"
[ -e "$STUB/fail-gh" ] && exit 1
case "$*" in
*graphql*) cat "$STUB/graphql.json" ;;
*branches*) cat "$STUB/branches.json" ;;
*issues/*) cat "$STUB/issue-$(sed -E 's#.*issues/([0-9]+).*#\1#' <<<"$*").json" ;;
esac
SH
    cat >"$STUB/bin/curl" <<'SH'
#!/bin/bash
echo x >>"$STUB/curl-calls"
[ -e "$STUB/fail-curl" ] && exit 1
args="$*"
case "$args" in
*graphql*) cat "$STUB/graphql.json" ;;
*branches*) cat "$STUB/branches.json" ;;
*issues/*) cat "$STUB/issue-$(sed -E 's#.*issues/([0-9]+).*#\1#' <<<"$args").json" ;;
esac
SH
    chmod +x "$STUB/bin/gh" "$STUB/bin/curl"
    export STUB PATH="$STUB/bin:$PATH" GH_TOKEN=t
    echo '{"data":{"repository":{"issues":{"nodes":[]}}}}' >"$STUB/graphql.json"
    echo '[]' >"$STUB/branches.json"
}

card_in_progress() {
    printf '{"data":{"repository":{"issues":{"nodes":[{"number":%s,"projectItems":{"nodes":[{"fieldValueByName":{"name":"In progress"}}]}}]}}}}' \
        "$1" >"$STUB/graphql.json"
}

issue_surface() {
    # shellcheck disable=SC2016
    jq -n --arg b "$(printf '## s\n\n```surface\n%s\n```\n' "$2")" '{body:$b}' >"$STUB/issue-$1.json"
}

@test "a path in the surface of an In-progress card with no local worktree is HELD" {
    forge_stub
    card_in_progress 77
    issue_surface 77 "a/b.sh"
    run refresh_elsewhere_held_paths o r
    [ "$status" -eq 0 ]
    run claim_files 5 "a/b.sh"
    [ "$status" -ne 0 ]
    [ "$output" = "HELD:elsewhere#77:a/b.sh" ]
}

@test "a pushed branch named for an issue, with no local worktree, holds that issue's surface" {
    forge_stub
    echo '[{"name":"main"},{"name":"feat/x-78"}]' >"$STUB/branches.json"
    issue_surface 78 "c/d.sh"
    refresh_elsewhere_held_paths o r
    run claim_files 5 "c/d.sh"
    [ "$output" = "HELD:elsewhere#78:c/d.sh" ]
}

@test "an issue with a LOCAL worktree is not held as elsewhere" {
    forge_stub
    card_in_progress 79
    issue_surface 79 "e/f.sh"
    git worktree add -q -b feat/y-79 "$TEST_TMP/wt79"
    refresh_elsewhere_held_paths o r
    run claim_files 5 "e/f.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAIMED" ]
}

@test "the issue's own claim is never HELD by its own forge marker" {
    forge_stub
    card_in_progress 80
    issue_surface 80 "g/h.sh"
    refresh_elsewhere_held_paths o r
    run claim_files 80 "g/h.sh"
    [ "$output" = "CLAIMED" ]
}

@test "gh failing falls back to the REST API" {
    forge_stub
    card_in_progress 81
    issue_surface 81 "i/j.sh"
    touch "$STUB/fail-gh"
    run refresh_elsewhere_held_paths o r
    [ "$status" -eq 0 ]
    [ -s "$STUB/curl-calls" ]
    run claim_files 5 "i/j.sh"
    [ "$output" = "HELD:elsewhere#81:i/j.sh" ]
}

@test "both transports failing never blocks: local claim works and a pending marker is left" {
    forge_stub
    touch "$STUB/fail-gh" "$STUB/fail-curl"
    run refresh_elsewhere_held_paths o r
    [ "$status" -ne 0 ]
    [ -s "$TEST_TMP/.git/forge-pending" ]
    run claim_files 5 "k/l.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAIMED" ]
}

@test "a retry inside the backoff window makes no forge call; once due it reconciles" {
    forge_stub
    touch "$STUB/fail-gh" "$STUB/fail-curl"
    refresh_elsewhere_held_paths o r || true
    rm -f "$STUB/gh-calls" "$STUB/curl-calls"
    run refresh_elsewhere_held_paths o r
    [ "$output" = "BACKOFF" ]
    [ ! -e "$STUB/gh-calls" ]
    rm "$STUB/fail-gh" "$STUB/fail-curl"
    printf '1\t%s\n' "$(($(date +%s) - 3600))" >"$TEST_TMP/.git/forge-pending"
    card_in_progress 82
    issue_surface 82 "m/n.sh"
    run refresh_elsewhere_held_paths o r
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TMP/.git/forge-pending" ]
}

@test "backoff grows 1, 2, 5, 10 minutes and then holds at 10" {
    run bash -c '. "$1"; for n in 1 2 3 4 9; do _dispatch_forge_backoff "$n"; done | paste -sd" "' _ "$LIB"
    [ "$output" = "60 120 300 600 600" ]
}

@test "a cross-machine conflict is reported and the local claim is left alone" {
    forge_stub
    claim_files 5 "o/p.sh"
    card_in_progress 83
    issue_surface 83 "o/p.sh"
    run refresh_elsewhere_held_paths o r
    [[ "$output" == *"CONFLICT:#5:#83:o/p.sh"* ]]
    grep -q "$(printf '\t5\to/p.sh')" "$TEST_TMP/.git/dispatch-claims.tsv"
}

@test "no hostname is written into any registry file" {
    forge_stub
    card_in_progress 84
    issue_surface 84 "q/r.sh"
    refresh_elsewhere_held_paths o r
    claim_files 5 "s/t.sh"
    run grep -rlF "$(hostname)" "$TEST_TMP/.git/dispatch-claims.tsv" "$TEST_TMP/.git/elsewhere-held-paths.tsv"
    [ "$status" -ne 0 ]
}
