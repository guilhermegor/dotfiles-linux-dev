#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/dispatch_free_surface_guard.sh (dotfiles-dev#396)
#
# Strategy (same as subagent_stop_sweep.bats): `gh` is stubbed on PATH with a real executable
# script written per-test, so gate_free_surface (lib/free_surface.sh) and the hook's own
# `gh repo view` never hit the network. `git` is the real `/usr/bin/git` against a throwaway
# local repo. The hook is invoked as an external process (it is a Stop hook script, not sourced),
# so the stub has to be a real file on PATH, not a shell function.
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
    PATH="$BIN:$PATH"
    export PATH
}

teardown() {
    rm -rf "$TEST_TMP"
}

# stub_gh ISSUES [FAIL_DEFAULT_BRANCH]
# ISSUES = newline-separated open issue numbers. No open PRs and no graphql claims, so every
# listed issue comes back unclaimed. FAIL_DEFAULT_BRANCH=1 makes the very first gate call fail,
# exercising the UNKNOWN path (gate_free_surface returns 1).
stub_gh() {
    local issues="$1" fail="${2:-0}"
    cat >"$BIN/gh" <<STUB
#!/bin/bash
case "\$*" in
"repo view --json nameWithOwner -q .nameWithOwner") echo "acme/widgets" ;;
"api repos/acme/widgets --jq .default_branch")
    [ "$fail" = 1 ] && exit 1
    echo main
    ;;
"pr list --repo acme/widgets"*) echo '[]' ;;
"api repos/acme/widgets/branches"*) echo main ;;
"api graphql"*) echo '{"data":{"search":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}' ;;
"issue list --repo acme/widgets"*) printf '%s\n' '$issues' ;;
*) exit 1 ;;
esac
STUB
    chmod +x "$BIN/gh"
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

transcript_dev_loop_agent_running() {
    local f="$TEST_TMP/transcript.jsonl"
    {
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill1","name":"Skill","input":{"skill":"dev-loop"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{}}]}}'
    } >"$f"
    printf '%s\n' "$f"
}

transcript_dev_loop_agent_resolved() {
    local f="$TEST_TMP/transcript.jsonl"
    {
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill1","name":"Skill","input":{"skill":"dev-loop"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{}}]}}'
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
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{}}]}}'
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
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{"name":"bg-agent"}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent1","content":[{"type":"text","text":"Async agent launched successfully. agentId: abc123"}]}]}}'
    } >"$f"
    printf '%s\n' "$f"
}

# transcript_dev_loop_background_agent_completed — same launch, but a later <task-notification>
# for the same tool_use id reports status=completed: genuinely resolved.
transcript_dev_loop_background_agent_completed() {
    local f="$TEST_TMP/transcript.jsonl"
    {
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill1","name":"Skill","input":{"skill":"dev-loop"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{"name":"bg-agent"}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent1","content":[{"type":"text","text":"Async agent launched successfully. agentId: abc123"}]}]}}'
        echo '{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>t1</task-id>\n<tool-use-id>agent1</tool-use-id>\n<status>completed</status>\n<summary>done</summary>\n</task-notification>"}'
    } >"$f"
    printf '%s\n' "$f"
}

# transcript_dev_loop_background_agent_failed — the RESCUE case: the notification says
# status=failed (a quota kill). Not "running", but also not a plain resolved dispatch.
transcript_dev_loop_background_agent_failed() {
    local f="$TEST_TMP/transcript.jsonl"
    {
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill1","name":"Skill","input":{"skill":"dev-loop"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{"name":"bg-agent"}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent1","content":[{"type":"text","text":"Async agent launched successfully. agentId: abc123"}]}]}}'
        echo '{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>t1</task-id>\n<tool-use-id>agent1</tool-use-id>\n<status>failed</status>\n<summary>quota</summary>\n</task-notification>"}'
    } >"$f"
    printf '%s\n' "$f"
}

# --- fail-open prerequisites ---------------------------------------------------------------

@test "exits 0 when stop_hook_active is true (one nudge per turn)" {
    stub_gh '42'
    t="$(transcript_dev_loop_agent_resolved)"
    run run_guard "$t" "true"
    [ "$status" -eq 0 ]
}

@test "fails open outside a git repo" {
    cd "$(mktemp -d)"
    t="$TEST_TMP/does-not-matter.jsonl"
    echo '{"type":"assistant"}' >"$t"
    run run_guard "$t"
    [ "$status" -eq 0 ]
}

@test "exits 0 when this session never invoked s:dev-loop" {
    stub_gh '42'
    t="$(transcript_no_dev_loop)"
    run run_guard "$t"
    [ "$status" -eq 0 ]
}

@test "exits 0 when a subagent of this session is still unresolved" {
    stub_gh '42'
    t="$(transcript_dev_loop_agent_running)"
    run run_guard "$t"
    [ "$status" -eq 0 ]
}

# --- the guard's actual job: block when free surface has unclaimed work --------------------

@test "blocks (exit 2) when free issues exist and no subagent is running" {
    stub_gh '42'
    t="$(transcript_dev_loop_agent_resolved)"
    run run_guard "$t"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#42"* ]]
    [[ "$output" == *"do not stop here without dispatching"* ]]
}

@test "exits 0 when the gate is readable and nothing is unclaimed" {
    stub_gh ''
    t="$(transcript_dev_loop_agent_resolved)"
    run run_guard "$t"
    [ "$status" -eq 0 ]
}

@test "blocks (exit 2) and says UNREADABLE, never silently allows, on a gate failure" {
    stub_gh '42' 1
    t="$(transcript_dev_loop_agent_resolved)"
    run run_guard "$t"
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
    [[ "$output" != *"do not stop here without dispatching"* ]]
}

# --- the two PR #400 review findings, pinned ------------------------------------------------

# Key-value spacing is not part of the JSONL contract, so the Skill event is parsed, never
# grepped as a literal. A `grep -qF '"skill":"dev-loop"'` implementation passes every other
# test in this file and fails only this one.
@test "detects the dev-loop Skill event when the record is serialised with spaces" {
    stub_gh '42'
    local t="$TEST_TMP/spaced.jsonl"
    {
        echo '{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "s1", "name": "Skill", "input": {"skill": "dev-loop"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a1","content":"done"}]}}'
    } >"$t"

    run run_guard "$t"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#42"* ]]
}

# --- dotfiles-dev#404: the guard was blind to /dev-loop and to background agents ------------

# THE DEFECT (half 1): dev_loop_invoked only ever matched a Skill tool_use. A real /dev-loop
# slash-command invocation (or a CronCreate replay of one) carries no Skill tool_use at all —
# it is a plain-string user message — so the pre-fix guard read this session as "never ran
# dev-loop" and exited 0 without ever checking the free surface. Reverting the dev_loop_invoked
# fix (dropping the second jq check) turns this test red — that IS the mutation check.
@test "blocks (exit 2) on a /dev-loop slash-command invocation, not just a Skill tool_use" {
    stub_gh '42'
    t="$(transcript_slash_dev_loop_agent_resolved)"
    run run_guard "$t"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#42"* ]]
    [[ "$output" == *"do not stop here without dispatching"* ]]
}

@test "recognises the fully-qualified s:dev-loop Skill form too" {
    stub_gh '42'
    local t="$TEST_TMP/fq.jsonl"
    {
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill1","name":"Skill","input":{"skill":"s:dev-loop"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent1","name":"Agent","input":{}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent1","content":"done"}]}}'
    } >"$t"
    run run_guard "$t"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#42"* ]]
}

# THE DEFECT (half 2): a background Agent's own tool_result is only the launch acknowledgement
# ("Async agent launched successfully..."), delivered the instant it starts, not when it
# finishes. The pre-fix subagents_running treated ANY tool_result as "resolved", so a genuinely
# still-working background agent read as idle and the guard blocked on top of live work.
@test "does not block while a background agent's own launch ack is its only tool_result" {
    stub_gh '42'
    t="$(transcript_dev_loop_background_agent_working)"
    run run_guard "$t"
    [ "$status" -eq 0 ]
}

@test "a completed <task-notification> resolves a background agent — guard blocks on free surface" {
    stub_gh '42'
    t="$(transcript_dev_loop_background_agent_completed)"
    run run_guard "$t"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#42"* ]]
}

@test "a failed <task-notification> is the RESCUE case: not running, message says resume it" {
    stub_gh '42'
    t="$(transcript_dev_loop_background_agent_failed)"
    run run_guard "$t"
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESCUE case"* ]]
    [[ "$output" == *"Resume it"* ]]
    [[ "$output" == *"bg-agent"* ]]
    [[ "$output" == *"#42"* ]]
}

# A Stop hook is synchronous and settings.json declares no timeout, so an unbounded gh call
# would hang the stop forever. A stalled call must land on the fail-closed path instead.
@test "a stalled gh call times out and reports UNREADABLE, never hangs the stop" {
    cat >"$BIN/gh" <<'STUB'
#!/bin/bash
case "$*" in
"repo view --json nameWithOwner -q .nameWithOwner") echo "acme/widgets" ;;
*) sleep 30 ;;
esac
STUB
    chmod +x "$BIN/gh"
    t="$(transcript_dev_loop_agent_resolved)"

    # Elapsed time is the assertion, not the exit code: an UNBOUNDED call also ends in
    # UNREADABLE (a slept-out stub returns empty output, which the gate reads as a failed
    # read), so exit 2 alone passes even with no timeout at all. Only the clock separates
    # "bounded" from "hung" — each stubbed call sleeps 30s, so an unwrapped gh cannot
    # finish inside this budget.
    local started=$SECONDS
    DISPATCH_GUARD_GH_TIMEOUT=1 run run_guard "$t"
    local elapsed=$(( SECONDS - started ))

    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
    [ "$elapsed" -lt 15 ]
}
