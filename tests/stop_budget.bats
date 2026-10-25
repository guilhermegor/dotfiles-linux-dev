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
