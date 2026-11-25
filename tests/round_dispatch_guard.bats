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
    # Own repo: the plan cache lives under the cwd's git common dir (#814), and must never be
    # the real checkout's. Latch file scoped likewise, and a gh stub reporting a healthy quota.
    cd "$TEST_TMP" || return 1
    git init -q -b main . && git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init
    export GH_BUDGET_LATCH_FILE="$TEST_TMP/latch"
    mkdir -p "$TEST_TMP/bin"
    printf '#!/bin/bash\necho "gh $*" >>"%s/gh.log"\necho '"'"'{"resources":{"graphql":{"remaining":5000,"reset":4102444800}}}'"'"'\n' \
        "$TEST_TMP" >"$TEST_TMP/bin/gh"
    chmod +x "$TEST_TMP/bin/gh"
    export PATH="$TEST_TMP/bin:$PATH"
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

# --- the repo judged is the one the loop ran for, not the cwd (dotfiles-linux-dev#1125) ---------

# other_repo NAME -> a second git checkout under DEV_LOOP_REPOS_ROOT; the Stop payload's cwd stays
# in the first repo (TEST_TMP), which is the orchestrator having `cd`'d away from the loop's repo.
other_repo() {
    export DEV_LOOP_REPOS_ROOT="$TEST_TMP/repos"
    mkdir -p "$DEV_LOOP_REPOS_ROOT/$1"
    git -C "$DEV_LOOP_REPOS_ROOT/$1" init -q -b main
    git -C "$DEV_LOOP_REPOS_ROOT/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# dev_loop_args ARGS -> a Skill call on dev-loop carrying ARGS. This guard's own round_events only
# counts the Skill shape as a loop invocation; the slash-command shape is covered by the guards
# that read it (dispatch_free_surface_guard.bats, review_fanout_guard.bats).
dev_loop_args() {
    tool_use Skill "$(jq -nc --arg a "$1" '{skill: "dev-loop", args: $a}')"
}

# planner_per_repo -> a stub planner whose answer depends on the repo it is run in:
# alpha has #111 dispatchable, beta #333, anything else #222.
planner_per_repo() {
    cat >"$ROUND_DISPATCH_PLANNER" <<'PY'
import os
issue = {"alpha": 111, "beta": 333}.get(os.path.basename(os.getcwd()), 222)
print('{"dispatchable":[{"issue":%d,"surface":["x"]}],"excluded":[]}' % issue)
PY
}

@test "judges the repo named by /dev-loop, not the repo the orchestrator cd'd into" {
    other_repo alpha
    dev_loop_args alpha
    planner_per_repo
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"#111"* ]]
    [[ "$output" != *"#222"* ]]
    [[ "$output" == *"repo judged: $DEV_LOOP_REPOS_ROOT/alpha (from the /dev-loop invocation"* ]]
}

@test "a Skill call with a path in its args names the repo too" {
    other_repo alpha
    tool_use Skill "{\"skill\":\"dev-loop\",\"args\":\"$DEV_LOOP_REPOS_ROOT/alpha — resolve the open issue\"}"
    planner_per_repo
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"#111"* ]]
    [[ "$output" != *"#222"* ]]
}

@test "the LAST dev-loop invocation decides the repo" {
    other_repo alpha
    other_repo beta
    dev_loop_args alpha
    dev_loop_args beta
    planner_per_repo
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"#333"* ]]
    [[ "$output" == *"/beta (from the /dev-loop invocation"* ]]
}

@test "a bare dev-loop names no repo: falls back to the cwd and says so" {
    other_repo alpha
    tool_use Skill '{"skill":"dev-loop"}'
    planner_per_repo
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"#222"* ]]
    [[ "$output" == *"repo judged: $TEST_TMP (cwd fallback: the last /dev-loop invocation named no repo)"* ]]
}

@test "a named path that is no git checkout is UNKNOWN, never a pass on the cwd repo" {
    other_repo alpha
    dev_loop_args "$TEST_TMP/no-such-repo"
    planner_per_repo
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNKNOWN"* ]]
    [[ "$output" != *"#222"* ]]
}

@test "one malformed transcript line does not hide a later dev-loop invocation" {
    other_repo alpha
    other_repo beta
    dev_loop_args alpha
    echo '{"message":{"content":[{"type":"tex' >>"$TRANSCRIPT"
    dev_loop_args beta
    planner_per_repo
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"#333"* ]]
}

@test "a plugin-namespaced /s:dev-loop slash command names the repo too" {
    other_repo alpha
    dev_loop_args ""
    jq -nc '{type: "user", message: {content:
        "<command-name>/s:dev-loop</command-name>\n<command-args>alpha</command-args>"}}' >>"$TRANSCRIPT"
    planner_per_repo
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"#111"* ]]
}

@test "a .git directory is no work tree: UNKNOWN, not a checkout" {
    other_repo alpha
    dev_loop_args "$DEV_LOOP_REPOS_ROOT/alpha/.git"
    planner_per_repo
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNKNOWN"* ]]
}

@test "a ./relative first word is not looked up under the repos root" {
    other_repo alpha
    dev_loop_args "./alpha"
    planner_per_repo
    run run_hook
    [ "$status" -eq 2 ]
    [[ "$output" == *"#222"* ]]
    [[ "$output" == *"cwd fallback"* ]]
}
