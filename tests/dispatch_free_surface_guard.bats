#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/dispatch_free_surface_guard.sh
# (dotfiles-dev#396, rewritten for the coverage rule in #405)
#
# Strategy: the PLANNER is stubbed, not `gh`. The guard no longer computes the candidate set
# itself — it reads lib/dispatch_plan.py's plan, which has its own suite
# (tests/dispatch_plan.bats) covering the gh surface underneath. Stubbing the planner is the
# same seam tests/round_dispatch_guard.bats already uses for the same file, and it keeps these
# tests about the one thing this hook decides: given a plan, what is still uncovered.
#
# `gh` IS stubbed, but only to fail loudly: the guard must make zero gh calls of its own now
# that the plan is its input (a per-agent gate read is what exhausted the shared API quota
# twice on 2026-09-17, dotfiles-dev#405 scope 5). `git` is the real /usr/bin/git against a
# throwaway local repo, so the claims registry lands in a real `.git` common dir.
#
# `transcript_*` helpers build throwaway JSONL transcripts. Invoking s:dev-loop is a literal
# '"skill":"dev-loop"' substring — the same shape the Skill tool's own tool_use input serialises
# to (see any real transcript under ~/.claude/projects/*/*.jsonl). An unresolved Agent dispatch is
# a `tool_use` of name "Agent" with no later `tool_result` carrying the same `tool_use_id`.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/dispatch_free_surface_guard.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP" || return 1
    git init -q -b main .
    git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init

    BIN="$TEST_TMP/bin"
    mkdir -p "$BIN"
    # Any gh call at all is a failure of this hook's contract, and a call that exits non-zero
    # with a log line makes that visible instead of silently working.
    cat >"$BIN/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >>"$GH_LOG"
exit 1
STUB
    chmod +x "$BIN/gh"
    GH_LOG="$TEST_TMP/gh.log"
    : >"$GH_LOG"
    export GH_LOG
    PATH="$BIN:$PATH"
    export PATH

    PLAN_STUB="$TEST_TMP/plan.py"
    DISPATCH_GUARD_PLANNER="$PLAN_STUB"
    export DISPATCH_GUARD_PLANNER
}

teardown() {
    rm -rf "$TEST_TMP"
}

refute_gh_called() {
    run grep -c . "$GH_LOG"
    [ "$output" = "0" ]
}

# stub_plan JSON — the planner prints JSON verbatim on stdout.
stub_plan() {
    printf '#!/usr/bin/env python3\nprint(%s)\n' "$(printf '%s' "$1" | jq -Rs .)" >"$PLAN_STUB"
    chmod +x "$PLAN_STUB"
}

# stub_plan_broken — a planner that prints something that is not the documented object.
stub_plan_broken() {
    printf '#!/usr/bin/env python3\nprint("not a plan")\n' >"$PLAN_STUB"
}

# stub_plan_stalled — a planner that never returns, exercising the guard's own timeout.
stub_plan_stalled() {
    printf '#!/usr/bin/env python3\nimport time\ntime.sleep(60)\n' >"$PLAN_STUB"
    DISPATCH_GUARD_PLANNER_TIMEOUT=1
    export DISPATCH_GUARD_PLANNER_TIMEOUT
}

# plan_of "4 5 6" — a plan whose dispatchable set is those issues, each with one file.
plan_of() {
    local n out=""
    for n in $1; do
        out="$out{\"issue\":$n,\"surface\":[\"f$n.sh\"]},"
    done
    stub_plan "{\"dispatchable\":[${out%,}],\"excluded\":[]}"
}

claim_issue() {
    printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "held.sh" >>"$TEST_TMP/.git/dispatch-claims.tsv"
}

payload() {
    # $1 = transcript path, $2 = stop_hook_active ("true"/"false", default false)
    jq -nc --arg t "$1" --arg cwd "$TEST_TMP" --arg active "${2:-false}" \
        '{cwd: $cwd, transcript_path: $t, stop_hook_active: ($active == "true")}'
}

run_guard() {
    payload "$1" "${2:-false}" | "$HOOK"
}

transcript_no_dev_loop() {
    local f="$TEST_TMP/transcript.jsonl"
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"x1","name":"Bash","input":{"command":"ls"}}]}}' >"$f"
    printf '%s\n' "$f"
}

# transcript_dev_loop — the loop ran, no Agent dispatch of any kind.
transcript_dev_loop() {
    local f="$TEST_TMP/transcript.jsonl"
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill1","name":"Skill","input":{"skill":"dev-loop"}}]}}' >"$f"
    printf '%s\n' "$f"
}

# transcript_dev_loop_agent_on ISSUE — an unresolved dispatch whose brief names that issue.
transcript_dev_loop_agent_on() {
    local f="$TEST_TMP/transcript.jsonl"
    {
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill1","name":"Skill","input":{"skill":"dev-loop"}}]}}'
        jq -nc --arg p "Implement #$1 in a worktree" \
            '{type:"assistant",message:{content:[{type:"tool_use",id:"agent1",name:"Agent",input:{name:("i"+($p|tostring)),prompt:$p}}]}}'
    } >"$f"
    printf '%s\n' "$f"
}

transcript_dev_loop_agent_resolved() {
    local f="$TEST_TMP/transcript.jsonl"
    {
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill1","name":"Skill","input":{"skill":"dev-loop"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{"prompt":"work #4"}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent1","content":"done"}]}}'
    } >"$f"
    printf '%s\n' "$f"
}

# transcript_slash_dev_loop_agent_resolved — real shape (dotfiles-dev#404), not a Skill
# tool_use: a `/dev-loop` slash command lands as a plain-string user message. Verified against
# an actual ~/.claude/projects/*.jsonl record.
transcript_slash_dev_loop_agent_resolved() {
    local f="$TEST_TMP/transcript.jsonl"
    {
        echo '{"type":"user","message":{"role":"user","content":"<command-message>dev-loop</command-message>\n<command-name>/dev-loop</command-name>"}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{"prompt":"work #4"}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent1","content":"done"}]}}'
    } >"$f"
    printf '%s\n' "$f"
}

# transcript_dev_loop_background_agent_working — a background Agent dispatch whose immediate
# tool_result is only the launch acknowledgement (verified verbatim off a real transcript),
# with no later <task-notification> for its tool_use id: still working, not resolved.
transcript_dev_loop_background_agent_working() {
    local f="$TEST_TMP/transcript.jsonl"
    {
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill1","name":"Skill","input":{"skill":"dev-loop"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{"name":"bg-agent","prompt":"work #4"}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent1","content":[{"type":"text","text":"Async agent launched successfully. agentId: abc123"}]}]}}'
    } >"$f"
    printf '%s\n' "$f"
}

# transcript_dev_loop_background_agent_status STATUS — same launch, plus a later
# <task-notification> for the same tool_use id carrying that status.
transcript_dev_loop_background_agent_status() {
    local f
    f="$(transcript_dev_loop_background_agent_working)"
    jq -nc --arg s "$1" \
        '{type:"queue-operation",operation:"enqueue",content:("<task-notification>\n<tool-use-id>agent1</tool-use-id>\n<status>"+$s+"</status>\n</task-notification>")}' \
        >>"$f"
    printf '%s\n' "$f"
}

# --- fail-open prerequisites ---------------------------------------------------------------

@test "exits 0 when stop_hook_active is true (one nudge per turn)" {
    plan_of "4"
    run run_guard "$(transcript_dev_loop)" true
    [ "$status" -eq 0 ]
}

@test "fails open outside a git repo" {
    plan_of "4"
    local t
    t="$(transcript_dev_loop)"
    rm -rf "$TEST_TMP/.git"
    run run_guard "$t"
    [ "$status" -eq 0 ]
}

@test "exits 0 for a session that never ran the loop" {
    plan_of "4"
    run run_guard "$(transcript_no_dev_loop)"
    [ "$status" -eq 0 ]
}

@test "exits 0 on an empty plan — the legitimately clear board" {
    stub_plan '{"dispatchable":[],"excluded":[]}'
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 0 ]
}

@test "makes no gh call of its own, ever" {
    # Per-agent gate reads are what emptied the shared 5000/h quota twice (#405 scope 5).
    plan_of "4"
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    refute_gh_called
}

# --- coverage, not presence (dotfiles-dev#405) ---------------------------------------------

@test "blocks (exit 2) naming the dispatchable issue nothing is working" {
    plan_of "4"
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#4"* ]]
}

@test "exits 0 when the unresolved dispatch names the only dispatchable issue" {
    plan_of "4"
    run run_guard "$(transcript_dev_loop_agent_on 4)"
    [ "$status" -eq 0 ]
}

@test "blocks when the unresolved dispatch names a DIFFERENT issue than the candidate" {
    # THE #405 FIX. Before it, any unresolved dispatch exited 0 — one live agent excused every
    # other dispatchable issue in the round, so the batch size still depended on the model
    # remembering. Coverage is per issue.
    plan_of "4 5"
    run run_guard "$(transcript_dev_loop_agent_on 4)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#5"* ]]
    [[ ! "$output" == *"#4"* ]]
}

@test "a live claim in the shared registry covers an issue this session never dispatched" {
    # The claim is agent-vs-agent across worktrees: the agent holding #5 belongs to another
    # session, invisible in this transcript.
    plan_of "5"
    claim_issue 5
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 0 ]
}

@test "an expired claim stops covering its issue" {
    plan_of "5"
    printf '%s\t5\theld.sh\n' 1 >"$TEST_TMP/.git/dispatch-claims.tsv"
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#5"* ]]
}

# --- the cap throttles, never drops --------------------------------------------------------

@test "the cap queues the overflow instead of dropping it" {
    plan_of "4 5 6 7 8"
    DISPATCH_MAX_CONCURRENT=2
    export DISPATCH_MAX_CONCURRENT
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    # Demanded now: the two oldest (lowest-numbered) issues.
    [[ "$output" == *"Missing"* ]]
    [[ "$output" == *"#4"* ]]
    [[ "$output" == *"#5"* ]]
    # Named as queued, not silently absent: the word matters, a missing #8 would be a drop.
    [[ "$output" == *"Queued by the concurrency cap of 2"* ]]
    [[ "$output" == *"#8"* ]]
    [[ "$output" == *"NOT"* ]]
}

@test "a full cap demands nothing — throttling is not a block" {
    plan_of "5"
    claim_issue 4
    DISPATCH_MAX_CONCURRENT=1
    export DISPATCH_MAX_CONCURRENT
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 0 ]
}

# --- UNDECLARED is reported, never assumed free --------------------------------------------

@test "an undeclared surface is reported and never dispatched" {
    stub_plan '{"dispatchable":[],"excluded":[{"issue":9,"reason":"UNDECLARED: no declared file surface (no ```surface block in the issue body)"}]}'
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNDECLARED"* ]]
    [[ "$output" == *"#9"* ]]
    # Reported as something to DECLARE, never as something to dispatch.
    [[ "$output" == *"Declaring the surface"* ]]
}

@test "an undeclared surface is listed alongside the issues that are dispatchable" {
    stub_plan '{"dispatchable":[{"issue":4,"surface":["f4.sh"]}],"excluded":[{"issue":9,"reason":"UNDECLARED: no declared file surface"}]}'
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#4"* ]]
    [[ "$output" == *"UNDECLARED"* ]]
    [[ "$output" == *"#9"* ]]
}

@test "an undeclared surface with no free slot does not cry wolf" {
    stub_plan '{"dispatchable":[],"excluded":[{"issue":9,"reason":"UNDECLARED: no declared file surface"}]}'
    claim_issue 4
    DISPATCH_MAX_CONCURRENT=1
    export DISPATCH_MAX_CONCURRENT
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 0 ]
}

# --- exclusions that are data, not memory --------------------------------------------------

@test "a stacked follow-up is never demanded (excluded by the planner, not UNKNOWN)" {
    # An open PR that NAMES #6 without closing it: dispatching it risks a duplicate PR against
    # real in-review work (dotfiles-dev#413, lesson free-surface-cannot-see-an-issue-stacked-
    # on-an-open-pr). The planner excludes it; the guard must not ask for it back.
    stub_plan '{"dispatchable":[],"excluded":[{"issue":6,"reason":"referenced by open PR #514 without a closing keyword — verify by hand"}]}'
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 0 ]
}

@test "an issue already claimed by a PR is never demanded" {
    stub_plan '{"dispatchable":[],"excluded":[{"issue":6,"reason":"already claimed by an open or merged pull request"}]}'
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 0 ]
}

# --- UNREADABLE blocks, never passes quietly -----------------------------------------------

@test "blocks (exit 2) and says UNREADABLE on a plan that is not the documented object" {
    stub_plan_broken
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
    [[ "$output" == *"not the same as empty"* ]]
}

@test "blocks (exit 2) when the planner's own read failed (UNKNOWN exclusions)" {
    # The planner fails closed by excluding EVERY issue as UNKNOWN, which arrives here as an
    # empty dispatchable list — identical in shape to a clear board. Read explicitly or the
    # whole gate goes silent exactly when it cannot see (dotfiles-dev#396's own defect).
    stub_plan '{"dispatchable":[],"excluded":[{"issue":4,"reason":"free surface gate UNKNOWN (gh API failure) — verify non-collision by hand"}]}'
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
    [[ "$output" == *"UNKNOWN"* ]]
}

@test "a stalled planner times out and reports UNREADABLE, never hangs the stop" {
    stub_plan_stalled
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
}

@test "a missing planner reports UNREADABLE rather than an empty board" {
    DISPATCH_GUARD_PLANNER="$TEST_TMP/nope.py"
    export DISPATCH_GUARD_PLANNER
    run run_guard "$(transcript_dev_loop)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
}

# --- transcript shapes that decide whether the hook fires at all ---------------------------

@test "detects the dev-loop Skill event when the record is serialised with spaces" {
    # Key-value spacing is not part of the JSONL contract, so a literal '"skill":"dev-loop"'
    # grep would silently miss this and the hook would never fire.
    local f="$TEST_TMP/transcript.jsonl"
    echo '{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "s1", "name": "Skill", "input": {"skill": "dev-loop"}}]}}' >"$f"
    plan_of "4"
    run run_guard "$f"
    [ "$status" -eq 2 ]
}

@test "blocks (exit 2) on a /dev-loop slash-command invocation, not just a Skill tool_use" {
    plan_of "4 5"
    run run_guard "$(transcript_slash_dev_loop_agent_resolved)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#4"* ]]
}

@test "a resolved dispatch stops covering its issue" {
    plan_of "4"
    run run_guard "$(transcript_dev_loop_agent_resolved)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#4"* ]]
}

@test "a background agent's own launch ack is not a resolution — its issue stays covered" {
    plan_of "4"
    run run_guard "$(transcript_dev_loop_background_agent_working)"
    [ "$status" -eq 0 ]
}

@test "a completed <task-notification> resolves a background agent — its issue is demanded" {
    plan_of "4"
    run run_guard "$(transcript_dev_loop_background_agent_status completed)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#4"* ]]
}

@test "a failed <task-notification> is the RESCUE case, and the message says resume it" {
    plan_of "4"
    run run_guard "$(transcript_dev_loop_background_agent_status failed)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESCUE"* ]]
    [[ "$output" == *"bg-agent"* ]]
}
