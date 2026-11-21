#!/usr/bin/env bats
# gh_graphql_mutation.sh (dotfiles-linux-dev#1072): the door for GraphQL-only mutations.
# `gh` is a stub on PATH, no network. It logs every call to $GH_LOG, fails `api graphql`
# calls whose text contains "mutation" when $MUT_FAIL holds the stderr to print, and
# otherwise answers the budget probes healthily.

bats_require_minimum_version 1.5.0

setup() {
    LIB="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/gh_graphql_mutation.sh"
    BIN="$BATS_TEST_TMPDIR/bin"
    GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    mkdir -p "$BIN"
    : > "$GH_LOG"
    cat > "$BIN/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$*" in
*"rate_limit"*) echo '{"resources":{"graphql":{"remaining":4000,"reset":9999999999},"core":{"remaining":4000,"reset":9999999999}}}' ;;
*rateLimit*) echo '{"data":{"rateLimit":{"remaining":4000,"resetAt":"2099-01-01T00:00:00Z"}}}' ;;
*mutation*)
    [ -n "${MUT_FAIL:-}" ] && { echo "$MUT_FAIL" >&2; exit 1; }
    echo '{"ok":true}' ;;
*) exit 1 ;;
esac
STUB
    chmod +x "$BIN/gh"
    export PATH="$BIN:$PATH" GH_LOG
    export GH_BUDGET_LATCH_FILE="$BATS_TEST_TMPDIR/latch"
    export GH_BUDGET_SPEND_LOG="$BATS_TEST_TMPDIR/spend.tsv"
    # shellcheck source=/dev/null
    source "$LIB"
}

mutate() { gh_graphql_mutation resolveReviewThread -f query='mutation{x}'; }

@test "healthy budget: the mutation runs and its output is returned" {
    run mutate
    [ "$status" -eq 0 ]
    [[ "$output" == *'"ok":true'* ]]
    grep -q 'mutation' "$GH_LOG"
}

@test "latch active: deferred status 75, one line naming op and UI path, no mutation sent" {
    gh_budget_latch_write 600
    run --separate-stderr mutate
    [ "$status" -eq 75 ]
    [ "${#lines[@]}" -eq 0 ]
    [ "${#stderr_lines[@]}" -eq 1 ]
    [[ "$stderr" == *"DEFERRED resolveReviewThread"* ]]
    [[ "$stderr" == *"Resolve conversation"* ]]
    run grep -c 'mutation' "$GH_LOG"
    [ "$output" = "0" ]
}

@test "deferred is distinct from a generic failure" {
    gh_budget_latch_write 600
    run mutate
    [ "$status" -ne 1 ]
    [ "$status" -eq "$GH_GQL_DEFERRED" ]
}

@test "GitHub refusing the call itself defers and writes the latch" {
    MUT_FAIL='GraphQL: API rate limit already exceeded for user ID 1.' run --separate-stderr mutate
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"DEFERRED resolveReviewThread"* ]]
    gh_budget_latch_active
}

@test "a non-rate-limit failure is the call's own failure, not deferred" {
    MUT_FAIL='GraphQL: Could not resolve to a node' run --separate-stderr mutate
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Could not resolve"* ]]
    run gh_budget_latch_active
    [ "$status" -ne 0 ]
}

@test "an op outside the table is refused with 2 and no gh call" {
    run gh_graphql_mutation mergePullRequest -f query='mutation{x}'
    [ "$status" -eq 2 ]
    [ ! -s "$GH_LOG" ]
}

@test "each registered op has a UI path" {
    for op in enablePullRequestAutoMerge resolveReviewThread updateProjectV2ItemFieldValue addProjectV2ItemById; do
        run gh_graphql_ui_path "$op"
        [ "$status" -eq 0 ]
        [ -n "$output" ]
    done
}

@test "the door never launches a browser" {
    run grep -Eic '^[^#]*(xdg-open|google-chrome|chromium|playwright)' "$LIB"
    [ "$output" = "0" ]
}
