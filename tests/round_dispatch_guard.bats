#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/round_dispatch_guard.sh
#
# Strategy: the hook is a Stop stdin -> stderr filter. Exit 2 is a block (stderr goes back to
# the model), exit 1 is a non-blocking announcement (stderr goes to the user), exit 0 is a pass.
# Every test writes a JSONL transcript, feeds the Stop payload that points at it, and asserts on
# the exit status plus the wording.
#
# The behaviours that matter (dotfiles-linux-dev#433):
#   - a round with dispatchable candidates and no agent started must BLOCK, naming surfaces;
#   - an agent started after the last s:dev-loop call satisfies the round;
#   - an empty `dispatchable` with reasons in `excluded` is the legitimate zero case — pass;
#   - a missing planner is an ANNOUNCED no-op (exit 1, once), never silence;
#   - a planner that prints junk is UNREADABLE and blocks, because unreadable is not empty.
#
# Run locally: bats tests/round_dispatch_guard.bats

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/round_dispatch_guard.sh"
    TEST_TMP="$(mktemp -d)"
    export TMPDIR="$TEST_TMP"
    TRANSCRIPT="$TEST_TMP/transcript.jsonl"
    export ROUND_DISPATCH_PLANNER="$TEST_TMP/dispatch_plan.py"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# tool_use NAME JSON_INPUT -> one transcript line recording that tool call.
tool_use() {
    printf '{"message":{"content":[{"type":"tool_use","name":"%s","input":%s}]}}\n' "$1" "$2" \
        >> "$TRANSCRIPT"
}

# planner JSON -> a stub planner printing that JSON verbatim.
planner() {
    printf '#!/usr/bin/env python3\nprint(%s)\n' "'''$1'''" > "$ROUND_DISPATCH_PLANNER"
}

# run_hook [STOP_HOOK_ACTIVE] -> feed the Stop payload for this test's transcript to the hook.
# A bats function, not a `bash -c` string: the transcript path is a setup() variable, and a
# child shell would see it unset — the payload would then carry an empty path and every test
# would pass by accident on the hook's own fail-open branch.
run_hook() {
    printf '{"stop_hook_active":%s,"session_id":"s1","transcript_path":"%s"}' \
        "${1:-false}" "$TRANSCRIPT" | bash "$HOOK"
}

@test "blocks a round with dispatchable candidates and no agent started" {
    tool_use Skill '{"skill":"dev-loop"}'
    planner '{"dispatchable":[{"issue":433,"surface":["hooks/lib/slot_classify.py"]}],"excluded":[]}'
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"started no agent"* ]]
    [[ "$output" == *"#433"* ]]
    [[ "$output" == *"hooks/lib/slot_classify.py"* ]]
}

@test "an agent started after the last dev-loop call satisfies the round" {
    tool_use Skill '{"skill":"dev-loop"}'
    tool_use Agent '{"description":"ship 433"}'
    planner '{"dispatchable":[{"issue":433,"surface":["a"]}],"excluded":[]}'
    run run_hook
    [ "$status" -eq 0 ]
}

@test "an agent started BEFORE the last dev-loop call does not satisfy the round" {
    tool_use Agent '{"description":"an earlier round"}'
    tool_use Skill '{"skill":"dev-loop"}'
    planner '{"dispatchable":[{"issue":433,"surface":["a"]}],"excluded":[]}'
    run run_hook
    [ "$status" -eq 2 ]
}

@test "every candidate excluded with a named reason is the legitimate zero case" {
    tool_use Skill '{"skill":"dev-loop"}'
    planner '{"dispatchable":[],"excluded":[{"issue":426,"reason":"surface held by live agent"}]}'
    run run_hook
    [ "$status" -eq 0 ]
}

@test "a session that never ran dev-loop is not this hook's concern" {
    tool_use Agent '{"description":"unrelated"}'
    planner '{"dispatchable":[{"issue":433,"surface":["a"]}],"excluded":[]}'
    run run_hook
    [ "$status" -eq 0 ]
}

@test "a missing planner announces the no-op instead of passing quietly" {
    tool_use Skill '{"skill":"dev-loop"}'
    run run_hook
    [ "$status" -eq 1 ]
    [[ "$output" == *"COULD NOT EVALUATE"* ]]
    [[ "$output" == *"no-op"* ]]
}

@test "the missing-planner announcement is made once per session, not every turn" {
    tool_use Skill '{"skill":"dev-loop"}'
    run run_hook
    [ "$status" -eq 1 ]
    run run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a planner printing something other than the documented object blocks as UNREADABLE" {
    tool_use Skill '{"skill":"dev-loop"}'
    planner 'Traceback (most recent call last): boom'
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
    [[ "$output" != *"is empty"* ]]
}

@test "an excluded record with no reason is UNREADABLE, never a passing zero" {
    tool_use Skill '{"skill":"dev-loop"}'
    planner '{"dispatchable":[],"excluded":[{"issue":426}]}'
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
}

@test "a plan whose collections are not arrays is UNREADABLE, never a passing zero" {
    tool_use Skill '{"skill":"dev-loop"}'
    planner '{"dispatchable":null,"excluded":{}}'
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
}

@test "a stop already caused by a hook is never blocked twice" {
    tool_use Skill '{"skill":"dev-loop"}'
    planner '{"dispatchable":[{"issue":433,"surface":["a"]}],"excluded":[]}'
    run run_hook true
    [ "$status" -eq 0 ]
}
