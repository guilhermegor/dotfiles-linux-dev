#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/collision_rerun.sh (dotfiles-linux-dev#1096).
# collision_hits is pure; the REST wrapper is exercised through a stubbed `gh`.
# COLLISION_LIB lets a mutation run point the suite at a broken copy of the lib.

setup() {
    LIB="${COLLISION_LIB:-$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/collision_rerun.sh}"
    source "$LIB"
    GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    : > "$GH_LOG"
}

@test "a merge touching a.py selects only the PRs touching a.py" {
    run bash -c 'source "$1"; collision_hits "a.py" < <(printf "1\ta.py\n2\tb.py\n3\ta.py\n3\tz.py\n")' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = $'1\n3' ]
}

@test "the PR touching only b.py is not selected" {
    run bash -c 'source "$1"; collision_hits "a.py" < <(printf "1\ta.py\n2\tb.py\n")' _ "$LIB"
    [[ "$output" != *2* ]]
}

@test "no overlap prints nothing" {
    run bash -c 'source "$1"; collision_hits "x.py" < <(printf "1\ta.py\n2\tb.py\n")' _ "$LIB"
    [ -z "$output" ]
}

@test "a multi-file merge selects each PR once" {
    run bash -c 'source "$1"; collision_hits $'"'"'a.py\nb.py'"'"' < <(printf "1\ta.py\n1\tb.py\n2\tb.py\n3\tc.py\n")' _ "$LIB"
    [ "$output" = $'1\n2' ]
}

# wrapper, with gh stubbed: merge touches a.py; PR 7 touches a.py, PR 8 only b.py
gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
        *"commits/abc"*) echo a.py ;;
        *"pulls?state=open"*) printf '7\n8\n' ;;
        *"pulls/7/files"*) echo a.py ;;
        *"pulls/8/files"*) echo b.py ;;
        *"-X PUT"*) return 0 ;;
        *) return 1 ;;
    esac
}

@test "wrapper updates the colliding PR only" {
    run collision_rerun o r abc
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]
    grep -q 'pulls/7/update-branch' "$GH_LOG"
    run grep -q 'pulls/8/update-branch' "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "wrapper treats an unreadable PR file list as a hit" {
    gh() {
        case "$*" in
            *"commits/abc"*) echo a.py ;;
            *"pulls?state=open"*) echo 9 ;;
            *"-X PUT"*) echo "$*" >> "$GH_LOG" ;;
            *) return 1 ;;
        esac
    }
    run collision_rerun o r abc
    [ "$output" = "9" ]
    grep -q 'pulls/9/update-branch' "$GH_LOG"
}

@test "ruleset_strict reads true, false and unknown" {
    gh() {
        case "$*" in
            *"rulesets/5"*) echo "$STRICT" ;;
            *"rulesets"*) echo 5 ;;
        esac
    }
    STRICT=true;  run ruleset_strict o r; [ "$output" = true ]
    STRICT=false; run ruleset_strict o r; [ "$output" = false ]
    STRICT=none;  run ruleset_strict o r; [ "$output" = unknown ]
    gh() { return 1; }
    run ruleset_strict o r; [ "$output" = unknown ]
}
