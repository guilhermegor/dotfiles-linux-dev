#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/free_surface.sh — free_classify_files only, which is
# pure set math over FREE_HELD_PATHS (dotfiles-dev#340). The network half is exercised through
# free_dispatch_surface in subagent_stop_sweep.bats.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/free_surface.sh"
    FREE_STATUS="ok"
    FREE_HELD_PATHS='a/held.sh
b/other.sh'
}

@test "no candidate file held is free" {
    run free_classify_files a/free.sh
    [[ "$output" == "free" ]]
}

@test "every candidate file held is held" {
    run free_classify_files a/held.sh b/other.sh
    [[ "$output" == "held:a/held.sh b/other.sh" ]]
}

@test "some candidate files held is would-need-a-held-file, not held" {
    run free_classify_files a/held.sh a/free.sh
    [[ "$output" == "would-need-a-held-file:a/held.sh" ]]
}

@test "a shared directory prefix is not a collision — exact path only" {
    run free_classify_files a/held.sh.bak a/
    [[ "$output" == "free" ]]
}

# --- fail-closed on an unprimed/unset precondition (dotfiles-dev#414) ----------------------------
# Called without a prior gate_free_surface, FREE_STATUS is unset, so free_classify_files must
# refuse rather than fall through to "free" — the exact input that caused a duplicate PR.

@test "unset FREE_STATUS (no prior gate_free_surface) fails closed, never free" {
    unset FREE_STATUS
    unset FREE_HELD_PATHS
    run free_classify_files a/held.sh b/other.sh
    [ "$status" -eq 1 ]
    [[ "$output" == "UNKNOWN" ]]
    [[ ! "$output" == *free* ]]
}

@test "FREE_STATUS=unknown (a failed prior gate) fails closed, never free" {
    FREE_STATUS="unknown"
    unset FREE_HELD_PATHS
    run free_classify_files a/held.sh
    [ "$status" -eq 1 ]
    [[ "$output" == "UNKNOWN" ]]
}

@test "FREE_STATUS=ok with a legitimately empty held set (zero open PRs) is free" {
    FREE_STATUS="ok"
    FREE_HELD_PATHS=""
    run free_classify_files a/free.sh b/other.sh
    [ "$status" -eq 0 ]
    [[ "$output" == "free" ]]
}

# One non-PR branch whose compare call fails with $COMPARE_ERR.
gh() {
    case "$*" in
        "api repos/o/r --jq .default_branch") echo master ;;
        "pr list"*) echo '[]' ;;
        "api repos/o/r/branches"*) printf 'master\nside\n' ;;
        "api repos/o/r/compare/"*) echo "gh: $COMPARE_ERR" >&2; return 1 ;;
        *) return 1 ;;
    esac
}

@test "an orphan branch (no common ancestor) is skipped, not a read failure" {
    COMPARE_ERR='No common ancestor between master and side. (HTTP 404)'
    run _free_held_paths o r
    [ "$status" -eq 0 ]
}

@test "any other compare failure fails the held-path read closed" {
    COMPARE_ERR='API rate limit exceeded (HTTP 403)'
    run _free_held_paths o r
    [ "$status" -eq 1 ]
}

# --- gate_free_surface: the top-level contract, not just its sub-helpers -------------------------
# The two tests above only exercise _free_held_paths. Nothing called gate_free_surface itself, so a
# regression in how it wires _free_held_paths + _free_claimed_issues + the issue list together —
# or a partial-answer bug in that wiring — could ship with every sub-helper test green (dotfiles-
# dev#398). These assert the whole function's contract: a usable, non-empty answer on success, and
# a fully-empty, never-partial answer on the fail-closed path.

@test "gate_free_surface: success sets ok with a non-empty, parseable answer" {
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            "pr list --repo o/r --state open --json number,headRefName --limit 200") echo '[]' ;;
            "api repos/o/r/branches --paginate --jq .[].name") printf 'master\nfeature\n' ;;
            "api repos/o/r/compare/master...feature --jq .files[]?.filename") echo 'held/file.sh' ;;
            "api graphql -f query="*)
                echo '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' ;;
            "issue list --repo o/r --state open --limit 500 --json number --jq .[].number")
                printf '5\n6\n7\n' ;;
            *) return 1 ;;
        esac
    }

    gate_free_surface o r
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$FREE_STATUS" = "ok" ]
    [ "$FREE_HELD_PATHS" = "held/file.sh" ]
    # Whole records, not substrings: "15" or "567" must not pass for 5, 6, 7.
    [ "$FREE_UNCLAIMED_ISSUES" = $'5\n6\n7' ]
}

# --- live_agent_classify_files: same set math, wired to a DIFFERENT global pair (dotfiles-dev#501)
# free_classify_files and live_agent_classify_files answer two different questions (open-PR
# merge-risk vs. actual dispatch-collision blocker — see the file header). These pin that they
# stay wired to their OWN globals and never bleed into each other's.

@test "live_agent_classify_files: held against LIVE_AGENT_PATHS, ignoring FREE_HELD_PATHS" {
    LIVE_AGENT_STATUS="ok"
    LIVE_AGENT_PATHS="a/held.sh"
    FREE_STATUS="ok"
    FREE_HELD_PATHS="a/free.sh"

    run live_agent_classify_files a/held.sh
    [[ "$output" == "held:a/held.sh" ]]

    run free_classify_files a/held.sh
    [[ "$output" == "free" ]]
}

@test "live_agent_classify_files: would-need-a-held-file, not held, on partial overlap" {
    LIVE_AGENT_STATUS="ok"
    LIVE_AGENT_PATHS="a/held.sh"
    run live_agent_classify_files a/held.sh a/free.sh
    [[ "$output" == "would-need-a-held-file:a/held.sh" ]]
}

@test "live_agent_classify_files: fails closed on unset LIVE_AGENT_STATUS, never free" {
    unset LIVE_AGENT_STATUS
    unset LIVE_AGENT_PATHS
    run live_agent_classify_files a/held.sh
    [ "$status" -eq 1 ]
    [[ "$output" == "UNKNOWN" ]]
}

@test "live_agent_classify_files: FREE_STATUS=ok does not make an unprimed live-agent call free" {
    FREE_STATUS="ok"
    FREE_HELD_PATHS=""
    unset LIVE_AGENT_STATUS
    unset LIVE_AGENT_PATHS
    run live_agent_classify_files a/held.sh
    [ "$status" -eq 1 ]
    [[ "$output" == "UNKNOWN" ]]
}

@test "gate_free_surface: one failing call fails the whole gate closed, no partial answer" {
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            "pr list --repo o/r --state open --json number,headRefName --limit 200") echo '[]' ;;
            "api repos/o/r/branches --paginate --jq .[].name") echo master ;;
            "api graphql -f query="*) echo "gh: API rate limit exceeded (HTTP 403)" >&2; return 1 ;;
            "issue list --repo o/r --state open --limit 500 --json number --jq .[].number")
                printf '5\n6\n7\n' ;;
            *) return 1 ;;
        esac
    }

    local rc=0
    gate_free_surface o r || rc=$?

    [ "$rc" -eq 1 ]
    [ "$FREE_STATUS" = "unknown" ]
    [ -z "$FREE_HELD_PATHS" ]
    [ -z "$FREE_CLAIMED_ISSUES" ]
    [ -z "$FREE_UNCLAIMED_ISSUES" ]
}
