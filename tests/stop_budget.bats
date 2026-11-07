#!/usr/bin/env bats
#
# Tests for ai_clients/claude/hooks/lib/stop_budget.sh and its three Stop-guard callers
# (dotfiles-linux-dev#814): a latched/low budget prints BUDGET-LOW and PASSES without calling
# gh; a planner result is reused inside one TTL window and invalidated by a push or Agent.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HOOKS="$ROOT/ai_clients/claude/hooks"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP" || return 1
    git init -q -b main . && git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init
    export TMPDIR="$TEST_TMP" GH_BUDGET_LATCH_FILE="$TEST_TMP/latch"
    GH_LOG="$TEST_TMP/gh.log"
    PLAN_LOG="$TEST_TMP/plan.log"
    export GH_LOG PLAN_LOG
    mkdir -p "$TEST_TMP/bin"
    # gh stub: logs every call; reports $GQL_REMAINING graphql points left.
    cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >>"$GH_LOG"
# GraphQL's own rateLimit probe (#918): GQL_PROBE=refuse errors like a spent account, GQL_PROBE=<n>
# answers n with a resetAt; unset leaves the probe unreadable so only rate_limit is read.
if [ "$1 $2" = "api graphql" ] && [ -n "${GQL_PROBE:-}" ]; then
    if [ "$GQL_PROBE" = refuse ]; then
        echo '{"errors":[{"type":"RATE_LIMIT","message":"API rate limit already exceeded for user ID 1."}]}'
        exit 1
    fi
    echo "{\"data\":{\"rateLimit\":{\"remaining\":$GQL_PROBE,\"resetAt\":\"2100-01-01T00:00:00Z\"}}}"
    exit 0
fi
echo "{\"resources\":{\"graphql\":{\"remaining\":${GQL_REMAINING:-5000},\"reset\":4102444800}}}"
STUB
    chmod +x "$TEST_TMP/bin/gh"
    export PATH="$TEST_TMP/bin:$PATH"
    : >"$GH_LOG"
    # Planner stub: counts its own runs; one dispatchable issue.
    export DISPATCH_GUARD_PLANNER="$TEST_TMP/plan.py" ROUND_DISPATCH_PLANNER="$TEST_TMP/plan.py"
    cat >"$DISPATCH_GUARD_PLANNER" <<'STUB'
import os
open(os.environ["PLAN_LOG"], "a").write("run\n")
print('{"dispatchable":[{"issue":7,"surface":["a"]}],"excluded":[]}')
STUB
    TRANSCRIPT="$TEST_TMP/t.jsonl"
    printf '{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"dev-loop"}}]}}\n' >"$TRANSCRIPT"
}

teardown() {
    rm -rf "$TEST_TMP"
}

payload() {
    printf '{"stop_hook_active":false,"session_id":"s","cwd":"%s","transcript_path":"%s"}' \
        "$TEST_TMP" "$TRANSCRIPT"
}

plan_runs() { wc -l <"$PLAN_LOG" 2>/dev/null || echo 0; }

@test "round guard: two Stops in one TTL window run the planner once" {
    run bash -c "$(declare -f payload); TEST_TMP=$TEST_TMP TRANSCRIPT=$TRANSCRIPT; payload | bash $HOOKS/round_dispatch_guard.sh"
    [ "$status" -eq 2 ]
    run bash -c "$(declare -f payload); TEST_TMP=$TEST_TMP TRANSCRIPT=$TRANSCRIPT; payload | bash $HOOKS/round_dispatch_guard.sh"
    [ "$status" -eq 2 ]
    [ "$(plan_runs)" -eq 1 ]
}

@test "round guard: a push in the transcript invalidates the cached plan" {
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git push origin x"}}]}}\n' >>"$TRANSCRIPT"
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    [ "$(plan_runs)" -eq 2 ]
}

@test "round guard: a latched budget prints BUDGET-LOW once, passes, calls no gh" {
    echo $(($(date +%s) + 600)) >"$GH_BUDGET_LATCH_FILE"
    run bash -c "$(declare -f payload); TEST_TMP=$TEST_TMP TRANSCRIPT=$TRANSCRIPT; payload | bash $HOOKS/round_dispatch_guard.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BUDGET-LOW (resets "* ]]
    run bash -c "$(declare -f payload); TEST_TMP=$TEST_TMP TRANSCRIPT=$TRANSCRIPT; payload | bash $HOOKS/round_dispatch_guard.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"BUDGET-LOW"* ]]
    [ ! -s "$GH_LOG" ]
    [ "$(plan_runs)" -eq 0 ]
}

@test "dispatch guard: GraphQL under the floor latches, passes, never runs the planner" {
    GQL_REMAINING=3 run bash -c "$(declare -f payload); TEST_TMP=$TEST_TMP TRANSCRIPT=$TRANSCRIPT; payload | bash $HOOKS/dispatch_free_surface_guard.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BUDGET-LOW"* ]]
    [ "$(plan_runs)" -eq 0 ]
    [ -s "$GH_BUDGET_LATCH_FILE" ]
}

@test "review fan-out guard: a latched budget passes before any gh call" {
    echo $(($(date +%s) + 600)) >"$GH_BUDGET_LATCH_FILE"
    run bash -c "$(declare -f payload); TEST_TMP=$TEST_TMP TRANSCRIPT=$TRANSCRIPT; payload | bash $HOOKS/review_fanout_guard.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BUDGET-LOW"* ]]
    [ ! -s "$GH_LOG" ]
}

@test "planners refuse with BUDGET-LOW while the latch is active" {
    echo $(($(date +%s) + 600)) >"$GH_BUDGET_LATCH_FILE"
    run python3 "$HOOKS/lib/dispatch_plan.py"
    [ "$status" -eq 3 ]
    [[ "$output" == *"BUDGET-LOW"* ]]
    run python3 "$HOOKS/lib/review_fanout_plan.py"
    [ "$status" -eq 3 ]
    [[ "$output" == *"BUDGET-LOW"* ]]
    [ ! -s "$GH_LOG" ]
}

@test "plan cache is keyed per session: another transcript does not reuse it" {
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    cp "$TRANSCRIPT" "$TEST_TMP/other.jsonl"
    TRANSCRIPT="$TEST_TMP/other.jsonl"
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    [ "$(plan_runs)" -eq 2 ]
}

@test "plan cache: a new claim in the registry (another session) invalidates it" {
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    sleep 1
    : >"$TEST_TMP/.git/dispatch-claims.tsv"
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    [ "$(plan_runs)" -eq 2 ]
}

@test "plan cache: gh issue create/edit in the transcript invalidates it" {
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh issue edit 7 --add-label x"}}]}}\n' >>"$TRANSCRIPT"
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    [ "$(plan_runs)" -eq 2 ]
}

@test "gh_latch.py creates ~/.cache like the bash side instead of falling to /tmp" {
    mkdir "$TEST_TMP/home"
    run env -u XDG_RUNTIME_DIR -u GH_BUDGET_LATCH_FILE HOME="$TEST_TMP/home" python3 -c \
        "import sys; sys.path.insert(0,'$HOOKS/lib'); import gh_latch; print(gh_latch.latch_path())"
    [ "$output" = "$TEST_TMP/home/.cache/dotfiles-dev-sweep-403-until" ]
}

@test "plan cache: a gh pr edit in the transcript invalidates it" {
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr edit 3 --body x"}}]}}\n' >>"$TRANSCRIPT"
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    [ "$(plan_runs)" -eq 2 ]
}

@test "plan cache: a lapsed TTL forces a re-plan" {
    STOP_PLAN_CACHE_TTL=0 payload | STOP_PLAN_CACHE_TTL=0 bash "$HOOKS/round_dispatch_guard.sh" || true
    STOP_PLAN_CACHE_TTL=0 payload | STOP_PLAN_CACHE_TTL=0 bash "$HOOKS/round_dispatch_guard.sh" || true
    [ "$(plan_runs)" -eq 2 ]
}

@test "plan cache: the round guard's plan is reused by the dispatch guard" {
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    payload | bash "$HOOKS/dispatch_free_surface_guard.sh" || true
    [ "$(plan_runs)" -eq 1 ]
}

@test "plan cache: a plan with UNKNOWN exclusions is not cached" {
    cat >"$DISPATCH_GUARD_PLANNER" <<'STUB'
import os
open(os.environ["PLAN_LOG"], "a").write("run\n")
print('{"dispatchable":[],"excluded":[{"issue":7,"reason":"UNKNOWN: read failed"}]}')
STUB
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    payload | bash "$HOOKS/round_dispatch_guard.sh" || true
    [ "$(plan_runs)" -eq 2 ]
}

@test "a planner exit 3 (latch written after the gate) passes instead of blocking" {
    cat >"$DISPATCH_GUARD_PLANNER" <<'STUB'
import sys
sys.exit(3)
STUB
    run bash -c "$(declare -f payload); TEST_TMP=$TEST_TMP TRANSCRIPT=$TRANSCRIPT; payload | bash $HOOKS/round_dispatch_guard.sh"
    [ "$status" -eq 0 ]
    run bash -c "$(declare -f payload); TEST_TMP=$TEST_TMP TRANSCRIPT=$TRANSCRIPT; payload | bash $HOOKS/dispatch_free_surface_guard.sh"
    [ "$status" -eq 0 ]
}

@test "the claims-registry path stop_budget.sh checks is the one dispatch_claims.sh writes" {
    run bash -c "source $HOOKS/lib/dispatch_claims.sh; dispatch_claims_file $TEST_TMP"
    [ "$output" = "$TEST_TMP/.git/dispatch-claims.tsv" ]
}

@test "a latch written by gh_budget_latch_write is read by gh_latch.py" {
    run bash -c "source $HOOKS/lib/gh_budget.sh; gh_budget_latch_write 600"
    [ "$status" -eq 0 ]
    run python3 -c "import sys; sys.path.insert(0,'$HOOKS/lib'); import gh_latch; sys.exit(0 if gh_latch.refuse_if_latched('t') else 1)"
    [ "$status" -eq 0 ]
}

gate() {
    bash -c "source $HOOKS/lib/stop_budget.sh; stop_budget_gate" 2>&1
}

@test "gate refuses when rate_limit says 2842 but GraphQL itself says 0 (#918)" {
    GQL_REMAINING=2842 GQL_PROBE=0 run gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"BUDGET-LOW (resets 00:00Z)"* ]]
    [[ "$output" == *"rate_limit says 2842, GraphQL says 0"* ]]
}

@test "gate treats a RATE_LIMIT refusal of the probe as low, with the reset unknown (#918)" {
    GQL_REMAINING=2842 GQL_PROBE=refuse run gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"BUDGET-LOW (reset unknown, rechecking after "* ]]
    # rate_limit's own reset (year 2100) must not be printed as if it were real
    [[ "$output" != *"resets 00:00Z"* ]]
    run python3 "$HOOKS/lib/dispatch_plan.py"
    [ "$status" -eq 3 ]
    [[ "$output" == *"reset unknown"* ]]
}

@test "gate prints GraphQL's own resetAt, not rate_limit's reset (#918)" {
    GQL_REMAINING=5 GQL_PROBE=7 run gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"BUDGET-LOW (resets 00:00Z)"* ]]
    [ "$(cat "$GH_BUDGET_LATCH_FILE")" -eq 4102444800 ]
}

@test "gate passes when GraphQL's probe and rate_limit are both healthy" {
    GQL_REMAINING=4000 GQL_PROBE=3900 run gate
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "poll_allowed refuses on a refused probe even when rate_limit is full (#918)" {
    GQL_REMAINING=5000 GQL_PROBE=refuse run bash -c "source $HOOKS/lib/gh_budget.sh; gh_budget_poll_allowed; echo \"\$GH_BUDGET_POLL_REASON\""
    [[ "$output" == *"GraphQL budget 0 < 100"* ]]
}

@test "spend log: summary names the top callers by points, window-bound (#918)" {
    export GH_BUDGET_SPEND_LOG="$TEST_TMP/spend.tsv"
    now=$(date +%s)
    printf '%s\tsweep\t30\n%s\tgate\t5\n%s\tsweep\t20\n%s\tplanner\t40\n%s\told\t999\n' \
        "$now" "$now" "$now" "$now" "$((now - 7200))" >"$GH_BUDGET_SPEND_LOG"
    run bash "$HOOKS/lib/gh_spend_summary.sh"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "sweep: 50 points, 2 calls" ]
    [ "${lines[1]}" = "planner: 40 points, 1 calls" ]
    [ "${lines[2]}" = "gate: 5 points, 1 calls" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "spend log: gh_budget_with_backoff records the response's cost, and the log is capped" {
    export GH_BUDGET_SPEND_LOG="$TEST_TMP/spend.tsv" GH_BUDGET_SPEND_LOG_MAX=10 GH_BUDGET_CALLER=unit
    cat >"$TEST_TMP/bin/costly" <<'STUB'
#!/bin/bash
echo '{"data":{"rateLimit":{"cost":3}}}'
STUB
    chmod +x "$TEST_TMP/bin/costly"
    for _ in $(seq 1 12); do
        bash -c "source $HOOKS/lib/gh_budget.sh; gh_budget_with_backoff 1 costly" >/dev/null
    done
    [ "$(wc -l <"$GH_BUDGET_SPEND_LOG")" -le 10 ]
    [ "$(awk -F'\t' '$2 != "unit" || $3 != 3' "$GH_BUDGET_SPEND_LOG" | wc -l)" -eq 0 ]
}

@test "spend log: an append waits for a trim holding the lock (#925 CodeRabbit)" {
    export GH_BUDGET_SPEND_LOG="$TEST_TMP/spend.tsv"
    : >"$GH_BUDGET_SPEND_LOG"
    # A stand-in trim: holds the lock, then replaces the log the way tail+mv does.
    (
        flock 9
        touch "$TEST_TMP/held"
        sleep 1
        : >"$GH_BUDGET_SPEND_LOG.new"
        mv -f "$GH_BUDGET_SPEND_LOG.new" "$GH_BUDGET_SPEND_LOG"
    ) 9>>"$GH_BUDGET_SPEND_LOG.lock" &
    for _ in $(seq 1 100); do [ -e "$TEST_TMP/held" ] && break; sleep 0.05; done
    [ -e "$TEST_TMP/held" ]
    bash -c "source $HOOKS/lib/gh_budget.sh; gh_budget_log_spend 4 waited"
    wait
    run grep -c waited "$GH_BUDGET_SPEND_LOG"
    [ "$output" = "1" ]
}

@test "spend log: the default caller is the script, or the outermost function under bash -c" {
    export GH_BUDGET_SPEND_LOG="$TEST_TMP/spend.tsv"
    unset GH_BUDGET_CALLER
    printf '%s\n' "source $HOOKS/lib/gh_budget.sh" 'main() { gh_budget_log_spend 1; }' 'main' >"$TEST_TMP/entry.sh"
    bash "$TEST_TMP/entry.sh"
    bash -c "source $HOOKS/lib/gh_budget.sh; my_outer() { gh_budget_log_spend 1; }; my_outer"
    run cut -f2 "$GH_BUDGET_SPEND_LOG"
    [ "${lines[0]}" = "entry.sh" ]
    [ "${lines[1]}" = "fn:my_outer" ]
}

@test "gate: a guessed reset's marker carries the latch's own expiry (#925 CodeRabbit)" {
    # A clock that ticks one second per `date +%s`, so two separately computed expiries differ.
    printf '%s\n' '#!/bin/bash' \
        'if [ "$1" = "+%s" ]; then n=$(cat "$TEST_TMP/clock" 2>/dev/null || echo 1700000000)' \
        '  echo $((n + 1)) >"$TEST_TMP/clock"; echo "$n"; exit 0; fi' \
        'exec /bin/date "$@"' >"$TEST_TMP/bin/date"
    chmod +x "$TEST_TMP/bin/date"
    TEST_TMP="$TEST_TMP" GQL_REMAINING=2842 GQL_PROBE=refuse run gate
    [ "$status" -eq 1 ]
    [ "$(cat "$GH_BUDGET_LATCH_FILE.guess")" = "$(cat "$GH_BUDGET_LATCH_FILE")" ]
}
