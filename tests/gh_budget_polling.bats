#!/usr/bin/env bats
#
# Poll-loop budget helpers in hooks/lib/gh_budget.sh (dotfiles-linux-dev#875): exponential back-off on
# both rate-limit error texts, the "refuse to start a poll loop on a thin budget" check, and the
# sweep's use of it. `gh` is a stub on PATH; nothing touches the network.

HOOKS="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks"

setup() {
    source "$HOOKS/lib/gh_budget.sh"
    DIR="$(mktemp -d)"
    export GH_BUDGET_LATCH_FILE="$DIR/latch"
    export GH_BUDGET_BACKOFF_BASE=0 # no real sleeping in the suite
    BIN="$DIR/bin"
    mkdir -p "$BIN"
    export PATH="$BIN:$PATH"
    CALLS="$DIR/calls"
}

teardown() {
    rm -rf "$DIR"
}

# stub_failing_cmd TEXT [SUCCEED_ON_CALL] -- a command that appends to $CALLS, prints TEXT on stderr
# and fails, until call number SUCCEED_ON_CALL (default: never).
stub_failing_cmd() {
    cat >"$BIN/flaky" <<STUB
#!/bin/bash
echo x >>"$CALLS"
n=\$(wc -l <"$CALLS")
if [ "\$n" -ge "${2:-999}" ]; then echo ok; exit 0; fi
echo '$1' >&2
exit 1
STUB
    chmod +x "$BIN/flaky"
}

stub_rate_limit() { # $1 = graphql remaining
    cat >"$BIN/gh" <<STUB
#!/bin/bash
[ "\$*" = "api rate_limit" ] && echo '{"resources":{"core":{"remaining":5000,"reset":1},"graphql":{"remaining":$1,"reset":1}}}'
STUB
    chmod +x "$BIN/gh"
}

@test "backoff seconds double per attempt and stop at the cap" {
    unset GH_BUDGET_BACKOFF_BASE
    [ "$(gh_budget_backoff_seconds 1)" = 3 ]
    [ "$(gh_budget_backoff_seconds 2)" = 6 ]
    [ "$(gh_budget_backoff_seconds 3)" = 12 ]
    [ "$(gh_budget_backoff_seconds 30)" = 60 ]
}

@test "backoff seconds honour an overridden base and cap" {
    GH_BUDGET_BACKOFF_BASE=1 GH_BUDGET_BACKOFF_CAP=5 run gh_budget_backoff_seconds 4
    [ "$output" = 5 ]
}

@test "with_backoff retries on the primary rate-limit text, then latches and returns 75" {
    stub_failing_cmd 'GraphQL: API rate limit already exceeded for user ID 1.'
    run gh_budget_with_backoff 3 flaky
    [ "$status" -eq 75 ]
    [ "$(wc -l <"$CALLS")" -eq 3 ]
    [ -f "$GH_BUDGET_LATCH_FILE" ]
}

@test "with_backoff retries on the secondary rate-limit text too" {
    stub_failing_cmd 'You have exceeded a secondary rate limit. Please wait a few minutes.'
    run gh_budget_with_backoff 3 flaky
    [ "$status" -eq 75 ]
    [ "$(wc -l <"$CALLS")" -eq 3 ]
}

@test "with_backoff stops retrying as soon as the call succeeds, and prints its stdout" {
    stub_failing_cmd 'API rate limit exceeded' 2
    run gh_budget_with_backoff 5 flaky
    [ "$status" -eq 0 ]
    [ "$output" = ok ]
    [ "$(wc -l <"$CALLS")" -eq 2 ]
    [ ! -f "$GH_BUDGET_LATCH_FILE" ]
}

@test "with_backoff does not retry a failure that is not a rate limit" {
    stub_failing_cmd 'HTTP 404: Not Found'
    run gh_budget_with_backoff 5 flaky
    [ "$status" -eq 1 ]
    [ "$(wc -l <"$CALLS")" -eq 1 ]
    [ ! -f "$GH_BUDGET_LATCH_FILE" ]
}

@test "poll_allowed refuses below the threshold" {
    stub_rate_limit 150
    run gh_budget_poll_allowed 200
    [ "$status" -eq 1 ]
}

@test "poll_allowed refusal names the budget" {
    stub_rate_limit 150
    gh_budget_poll_allowed 200 || true
    [[ "$GH_BUDGET_POLL_REASON" == *"GraphQL budget 150 < 200"* ]]
}

@test "poll_allowed allows at the threshold and warns a full budget proves nothing about the secondary limit" {
    stub_rate_limit 200
    gh_budget_poll_allowed 200
    [[ "$GH_BUDGET_POLL_REASON" == *"does not prove the secondary limit is clear"* ]]
}

@test "poll_allowed refuses while the 403 latch is active, even with a full budget" {
    stub_rate_limit 5000
    gh_budget_latch_write 600
    run gh_budget_poll_allowed
    [ "$status" -eq 1 ]
}

@test "poll_allowed refuses a non-numeric floor instead of allowing the loop" {
    stub_rate_limit 10
    GH_POLL_GRAPHQL_FLOOR=abc run gh_budget_poll_allowed
    [ "$status" -eq 1 ]
}

@test "poll_allowed default floor is the Stop guards' 100" {
    stub_rate_limit 150
    run gh_budget_poll_allowed
    [ "$status" -eq 0 ]
    stub_rate_limit 99
    run gh_budget_poll_allowed
    [ "$status" -eq 1 ]
}

@test "poll_allowed fails open when rate_limit is unreadable" {
    printf '#!/bin/bash\nexit 1\n' >"$BIN/gh"
    chmod +x "$BIN/gh"
    run gh_budget_poll_allowed
    [ "$status" -eq 0 ]
}

@test "the sweep's review gate reports UNKNOWN and makes no thread query on a thin budget" {
    cat >"$BIN/gh" <<STUB
#!/bin/bash
echo "\$*" >>"$DIR/gh.log"
case "\$*" in
"api rate_limit") echo '{"resources":{"graphql":{"remaining":10,"reset":1}}}' ;;
"api repos/o/r/pulls?state=open"*) echo 7 ;;
*) exit 1 ;;
esac
STUB
    chmod +x "$BIN/gh"
    head -n -1 "$HOOKS/subagent_stop_sweep.sh" >"$DIR/funcs.sh"
    mkdir -p "$DIR/lib"
    cp "$HOOKS"/lib/*.sh "$DIR/lib/"
    source "$DIR/funcs.sh"
    run sweep_review_gate o r o/r /dev/null
    [[ "$output" == *"UNKNOWN"*"GraphQL budget 10 < 100"* ]]
    # The only graphql call allowed is the free rateLimit probe (#918); no thread query.
    run bash -c "grep graphql '$DIR/gh.log' | grep -vc 'rateLimit{remaining resetAt}'"
    [ "$output" = 0 ]
}

@test "gh_budget_log_spend survives a missing log dir under set -e" {
    run bash -c 'set -e; source "$1/lib/gh_budget.sh"; GH_BUDGET_SPEND_LOG=/nonexistent/d/x gh_budget_log_spend 1 t; echo survived' _ "$HOOKS"
    [ "$status" -eq 0 ]
    [[ "$output" == *survived* ]]
}
