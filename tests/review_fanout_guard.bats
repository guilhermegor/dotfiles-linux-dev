#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/review_fanout_guard.sh — the Stop hook that refuses
# to end a dev-loop round which had open PRs needing a reviewer and started no review agent
# (dotfiles-linux-dev#480).
#
# Two properties are asserted, and the second is the one that keeps a guard alive:
#
#   1. it BLOCKS when there is work — dispatchable non-empty and no dispatch of this
#      session's own unresolved;
#   2. it FAILS OPEN on everything it cannot resolve — no transcript, a session that never
#      ran the loop, a cwd that is not a repo. A guard that blocks unrelated sessions gets
#      switched off, and a switched-off guard is worth less than the prose it replaced.
#
# The one deliberate exception to (2) is BLINDNESS ABOUT ITS OWN INPUT: an unreadable plan, a
# missing planner, or a reviewer rung whose status is `unknown` all block with their own
# distinct wording. That asymmetry is the #396/#433 lesson — a gate that fails closed and is
# then read as routine silence is a disabled feature nobody can see.
#
# The planner is stubbed through REVIEW_FANOUT_PLANNER: this suite tests the hook's reading of
# the contract, not the planner's own answers (tests/review_fanout_plan.bats owns those).
#
# Run locally: bats tests/review_fanout_guard.bats

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/review_fanout_guard.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP" || return 1
    /usr/bin/git init -q -b main .
    /usr/bin/git config user.email t@t
    /usr/bin/git config user.name t
    /usr/bin/git commit -q --allow-empty -m init

    # announce_no_rung writes its once-per-session marker under $TMPDIR. Scope it to this
    # test's tmpdir so teardown removes it — a marker surviving into the next test would
    # silently convert a real announcement into a pass, which is the one failure this
    # suite's announce cases exist to catch.
    TMPDIR="$TEST_TMP"
    export TMPDIR

    TRANSCRIPT="$TEST_TMP/transcript.jsonl"
    : >"$TRANSCRIPT"
    PLAN="$TEST_TMP/plan.json"

    # A planner stub that prints whatever $PLAN holds. Real file, real python3 — the guard
    # shells out, so a bats function would be invisible to the child.
    REVIEW_FANOUT_PLANNER="$TEST_TMP/stub_planner.py"
    cat >"$REVIEW_FANOUT_PLANNER" <<'STUB'
import os
import sys

with open(os.environ["PLAN"], encoding="utf-8") as handle:
    sys.stdout.write(handle.read())
STUB
    export REVIEW_FANOUT_PLANNER PLAN
}

teardown() {
    cd /
    rm -rf "$TEST_TMP"
    unset REVIEW_FANOUT_PLANNER PLAN
}

# --- transcript fixtures -----------------------------------------------------------

loop_invoked() {
    printf '%s\n' \
        '{"message":{"content":[{"type":"tool_use","name":"Skill","id":"s1","input":{"skill":"dev-loop"}}]}}' \
        >>"$TRANSCRIPT"
}

loop_invoked_via_slash_command() {
    printf '%s\n' \
        '{"type":"user","message":{"content":"<command-name>/dev-loop</command-name>"}}' \
        >>"$TRANSCRIPT"
}

# agent_dispatched ID [AGENT_NAME] — a dispatch with no tool_result yet, i.e. still in flight.
# AGENT_NAME defaults to a REVIEW dispatch name (`review-pr-<something>`), because most cases
# here are about resolution mechanics rather than classification; the classification cases pass
# a non-review name explicitly.
agent_dispatched() {
    local id="$1" name="${2:-review-pr-520}"
    printf '%s\n' \
        "{\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Agent\",\"id\":\"$id\",\"input\":{\"name\":\"$name\"}}]}}" \
        >>"$TRANSCRIPT"
}

agent_result() {
    printf '%s\n' \
        "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":\"$2\"}]}}" \
        >>"$TRANSCRIPT"
}

task_notification() {
    printf '%s\n' \
        "{\"content\":\"<task-notification><tool-use-id>$1</tool-use-id><status>$2</status></task-notification>\"}" \
        >>"$TRANSCRIPT"
}

# --- teammate-style shapes (#694) — every string below is copied from a real transcript ---

# transcript_text_record CONTENT [TS] — a bare-string user record, which is how a teammate's
# message is delivered.
transcript_text_record() {
    jq -cn --arg c "$1" --arg ts "${2:-}" \
        '{type: "user", message: {role: "user", content: $c}} + (if $ts == "" then {} else {timestamp: $ts} end)' \
        >>"$TRANSCRIPT"
}

# teammate_spawned ID EFFECTIVE_NAME — the mailbox spawn result; `name:` is the EFFECTIVE name.
teammate_spawned() {
    local text
    text="$(printf 'Spawned successfully. (This tool result is internal metadata — never quote or paste any part of it, including the ID below, into a user-facing reply.)\nagent_id: a%s-0123456789abcdef\nname: %s\nThe agent is now running and will receive instructions via mailbox.' "$2" "$2")"
    jq -cn --arg id "$1" --arg t "$text" \
        '{message: {content: [{type: "tool_result", tool_use_id: $id, content: [{type: "text", text: $t}]}]}}' \
        >>"$TRANSCRIPT"
}

# send_message ID TO [TS] — a SendMessage tool_use, then its delivery receipt.
send_message() {
    local id="$1" to="$2" ts="${3:-}" receipt
    jq -cn --arg id "$id" --arg to "$to" --arg ts "$ts" \
        '{message: {content: [{type: "tool_use", name: "SendMessage", id: $id, input: {to: $to, summary: "resume", message: "go"}}]}} + (if $ts == "" then {} else {timestamp: $ts} end)' \
        >>"$TRANSCRIPT"
    receipt="$(printf '{"success":true,"message":"Message sent to %s'"'"'s inbox","msg_id":"8f18dc9f","routing":{"sender":"team-lead","target":"@%s","summary":"resume"}}' "$to" "$to")"
    jq -cn --arg id "$id" --arg t "$receipt" \
        '{message: {content: [{type: "tool_result", tool_use_id: $id, content: [{type: "text", text: $t}]}]}}' \
        >>"$TRANSCRIPT"
}

# teammate_idle NAME REASON TS — the teammate-message carrying an idle_notification.
# REASON is `available` (finished its turn) or `failed` (killed, e.g. a session limit).
teammate_idle() {
    local name="$1" reason="$2" ts="$3" body
    body="$(printf '{"type":"idle_notification","from":"%s","timestamp":"%s","idleReason":"%s","result":"done"}' "$name" "$ts" "$reason")"
    transcript_text_record "Another Claude session sent a message:
<teammate-message teammate_id=\"$name\" color=\"blue\">
$body
</teammate-message>" "$ts"
}

plan_with_work() {
    cat >"$PLAN" <<'EOF'
{"rung":{"status":"ok","runtime":"qwen","model":"qwen3-coder-plus","signal":"configured-default"},
 "dispatchable":[{"pr":520,"head":"e1319925c49d","checks":{"failing":["yamllint"],"running":["bats (unit tests)"],"ambiguous":["Review threads answered"]}}],
 "excluded":[{"pr":453,"reason":"already reviewed at the current head"}]}
EOF
}

plan_all_excluded() {
    cat >"$PLAN" <<'EOF'
{"rung":{"status":"ok","runtime":"qwen","model":"qwen3-coder-plus","signal":"configured-default"},
 "dispatchable":[],
 "excluded":[{"pr":453,"reason":"already reviewed at the current head"},
             {"pr":520,"reason":"merge conflict (mergeStateStatus DIRTY)"}]}
EOF
}

# run_guard [STOP_HOOK_ACTIVE] [SESSION_ID] — feeds the hook a Stop payload naming this repo.
# SESSION_ID is explicit because announce_no_rung's once-per-session marker is keyed on it;
# the default is per-test (setup points TMPDIR at $TEST_TMP too), so no marker can leak from
# one test into the next and turn a real announcement into a silent pass.
run_guard() {
    local active="${1:-false}" session="${2:-$BATS_TEST_NAME}"
    run bash "$GUARD" <<EOF
{"cwd":"$TEST_TMP","transcript_path":"$TRANSCRIPT","stop_hook_active":$active,"session_id":"$session"}
EOF
}

# --- it blocks when there is work --------------------------------------------------

@test "blocks a round with dispatchable PRs and no review agent" {
    loop_invoked
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"#520"* ]]
    [[ "$output" == *"do not stop here without dispatching"* ]]
}

@test "the block message names the reason each excluded PR was excluded" {
    loop_invoked
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"#453  already reviewed at the current head"* ]]
}

@test "the block message keeps failing checks apart from still-running ones" {
    # A running check reported as failed is the `conclusion != "SUCCESS"` bug leaking into
    # the operator's view; the planner splits them and the message must preserve the split.
    loop_invoked
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"failing: yamllint"* ]]
    [[ "$output" == *"still running: bats (unit tests)"* ]]
    [[ "$output" == *"ambiguous check name: Review threads answered"* ]]
}

@test "the block message states the scheduling/judgement boundary" {
    # #480's hard boundary: determinism schedules the review, it never accepts a finding.
    # The message an operator actually reads is where that has to be said.
    loop_invoked
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"never accepts a finding for you"* ]]
}

@test "a /dev-loop slash command counts as running the loop" {
    # Shape 3: content is a bare STRING, so the tool_use walk sees nothing and the miss is
    # silent unless it is tested for.
    loop_invoked_via_slash_command
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
}

@test "reports a failed background agent as the RESCUE case, not free capacity" {
    # The agent is named explicitly so the label assertion below is unambiguous: the guard
    # reports `.input.name`, and this fixture previously set that to the bare tool-use id
    # (`a1`), which made the assertion pass for the wrong reason — it could not tell the label
    # from the id. Asserting on a distinct name pins that the LABEL is what reaches the
    # operator. Behaviour unchanged; the fixture was the weak part.
    loop_invoked
    agent_dispatched a1 "review-pr-777"
    agent_result a1 "Async agent launched successfully, id=a1"
    task_notification a1 failed
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESCUE case"* ]]
    [[ "$output" == *"review-pr-777"* ]]
}

# --- it passes when the board is genuinely covered ---------------------------------

@test "passes when every PR is excluded with its own named reason" {
    loop_invoked
    plan_all_excluded
    run_guard
    [ "$status" -eq 0 ]
}

@test "passes while a REVIEW dispatch of this session's own is still unresolved" {
    loop_invoked
    agent_dispatched a1
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

# --- the selector: only a REVIEW dispatch suppresses (review finding on this file) ---

@test "an unresolved NON-review agent does NOT suppress the guard" {
    # 🔴 THE REPORTED DEFECT. The first cut selected every `Agent` tool_use, so an agent
    # dispatched for something unrelated — in an orchestrating session, most of them — let a
    # Stop pass with dispatchable non-empty and no review agent ever started. That is the
    # inverse of this guard's contract, and it failed OPEN, where its sibling
    # dispatch_free_surface_guard.sh fails closed. A guard suppressed by normal operation is
    # not a guard.
    loop_invoked
    agent_dispatched a1 "implement-issue-405"
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"#520"* ]]
}

@test "the block names the in-flight non-review agents rather than ignoring them" {
    # Naming them is what makes the block actionable instead of a shrug — the operator needs
    # to know the agents they can see are not covering the fan-out.
    loop_invoked
    agent_dispatched a1 "implement-issue-405"
    agent_dispatched a2 "greenfield-backlog"
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"none of them a review dispatch"* ]]
    [[ "$output" == *"implement-issue-405"* ]]
    [[ "$output" == *"greenfield-backlog"* ]]
}

@test "a review dispatch in flight suppresses even alongside unrelated agents" {
    # The converse: the presence of unrelated agents must not stop a genuine review dispatch
    # from counting, or the guard nags through the whole fan-out it just asked for.
    loop_invoked
    agent_dispatched a1 "implement-issue-405"
    agent_dispatched a2 "review-pr-520"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "a resolved review dispatch does not suppress a later round" {
    # Classification must not become a permanent excuse: once the review agent has finished,
    # an outstanding dispatchable list blocks again.
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    agent_result a1 "done, posted the review"
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
}

@test "the block message states the review-pr name convention" {
    # The guard keys on a name the dispatcher must write, so the message has to say what it is
    # — a marker nothing emits would make the predicate always false.
    loop_invoked
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"review-pr-520"* ]]
}

@test "a launch acknowledgement alone does not resolve a background dispatch" {
    # The ack is delivered synchronously ON LAUNCH. Treating its presence as "resolved" makes
    # every background dispatch read as finished the instant it starts (#404) — so with only
    # an ack and no task-notification the dispatch is still in flight and the hook passes.
    loop_invoked
    agent_dispatched a1
    agent_result a1 "Async agent launched successfully, id=a1"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "a completed background dispatch no longer counts as running" {
    loop_invoked
    agent_dispatched a1
    agent_result a1 "Async agent launched successfully, id=a1"
    task_notification a1 completed
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
}

# --- teammate spawns, name suffixes, SendMessage resumes (#694) --------------------

@test "a mailbox spawn ack alone does not resolve a review dispatch" {
    # 🔴 THE REPORTED DEFECT. `Spawned successfully … via mailbox` is not the async ack, so it
    # was classed `done` and the dispatch read as resolved the instant it started — the guard
    # then blocked every Stop of a PR with a live reviewer.
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "a teammate idle_notification settles a mailbox-spawned review as completed" {
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    teammate_idle "review-pr-520" available "2026-10-09T10:19:35.963Z"
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"#520"* ]]
}

@test "a failed idle_notification is the RESCUE case, not still-running" {
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    teammate_idle "review-pr-520" failed "2026-10-09T10:19:35.963Z"
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESCUE case"* ]]
}

@test "an idle_notification from another teammate does not settle this one" {
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    teammate_idle "review-pr-521" available "2026-10-09T10:19:35.963Z"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "a name-collision suffix is a review name" {
    loop_invoked
    agent_dispatched a1 "review-pr-520-2"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "the spawn result's effective name is what the idle_notification must carry" {
    # The Agent INPUT name stays `review-pr-520`; the harness renamed the teammate
    # `review-pr-520-2`. Its idle arrives `from` the suffixed name, and an idle from the
    # unsuffixed (original) teammate is somebody else's and must not settle it.
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520-2"
    teammate_idle "review-pr-520" available "2026-10-09T10:19:35.963Z"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
    teammate_idle "review-pr-520-2" available "2026-10-09T10:20:35.963Z"
    run_guard
    [ "$status" -eq 2 ]
}

@test "a SendMessage resume of a review teammate counts as in flight" {
    # Resuming the original teammate produces no Agent tool_use at all — the resume is the
    # dispatch. The first spawn is already settled, so only the SendMessage can suppress.
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    teammate_idle "review-pr-520" available "2026-10-09T10:19:35.963Z"
    send_message m1 "review-pr-520" "2026-10-09T10:30:00.000Z"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "a SendMessage to a suffixed review teammate counts too" {
    loop_invoked
    send_message m1 "review-pr-520-2" "2026-10-09T10:30:00.000Z"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "the teammate's next idle_notification settles the SendMessage resume" {
    loop_invoked
    send_message m1 "review-pr-520" "2026-10-09T10:30:00.000Z"
    teammate_idle "review-pr-520" available "2026-10-09T10:45:00.000Z"
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
}

@test "a re-delivered older idle copy does not settle a later SendMessage resume" {
    # The blob is re-delivered in several records. Ordered by file position the stale copy
    # below would settle the resume; ordered by its embedded timestamp it predates it.
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    send_message m1 "review-pr-520" "2026-10-09T10:30:00.000Z"
    teammate_idle "review-pr-520" available "2026-10-09T10:19:35.963Z"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "a SendMessage to a non-review recipient is not a review dispatch" {
    loop_invoked
    send_message m1 "issue-694-guard-gap" "2026-10-09T10:30:00.000Z"
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
}

# idle_envelope NAME BODY — one teammate envelope, as it sits inside a delivered message.
idle_envelope() {
    printf '<teammate-message teammate_id="%s" color="blue">\n%s\n</teammate-message>' "$1" "$2"
}

# send_message_raw ID TO TS RECEIPT — a SendMessage with a caller-supplied receipt text.
send_message_raw() {
    jq -cn --arg id "$1" --arg to "$2" --arg ts "$3" \
        '{timestamp: $ts, message: {content: [{type: "tool_use", name: "SendMessage", id: $id, input: {to: $to, summary: "resume", message: "go"}}]}}' \
        >>"$TRANSCRIPT"
    jq -cn --arg id "$1" --arg t "$4" \
        '{message: {content: [{type: "tool_result", tool_use_id: $id, content: [{type: "text", text: $t}]}]}}' \
        >>"$TRANSCRIPT"
}

@test "a batched idle record attributes each verdict to its own teammate" {
    # Several envelopes share one string. `from` and `idleReason` must come from the SAME
    # body: a failed 520 sitting behind an available 521 is the RESCUE case for 520.
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    local first second
    first="$(idle_envelope review-pr-521 '{"type":"idle_notification","from":"review-pr-521","timestamp":"2026-10-09T10:19:00.000Z","idleReason":"available"}')"
    second="$(idle_envelope review-pr-520 '{"type":"idle_notification","from":"review-pr-520","timestamp":"2026-10-09T10:19:35.963Z","idleReason":"failed","failureReason":"session limit"}')"
    transcript_text_record "Another Claude session sent a message:
$first
$second" "2026-10-09T10:19:36.000Z"
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESCUE case"* ]]
}

@test "a batched idle record settles only the teammates it names" {
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    local first second
    first="$(idle_envelope review-pr-521 '{"type":"idle_notification","from":"review-pr-521","timestamp":"2026-10-09T10:19:00.000Z","idleReason":"failed"}')"
    second="$(idle_envelope review-pr-522 '{"type":"idle_notification","from":"review-pr-522","timestamp":"2026-10-09T10:19:35.963Z","idleReason":"available"}')"
    transcript_text_record "Another Claude session sent a message:
$first
$second" "2026-10-09T10:19:36.000Z"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "an idle with no timestamp settles the same under every locale" {
    # Under en_US/pt_BR collation punctuation is ignored, so a bare byte-order `<` against
    # the `-` placeholder flipped with the caller's locale. The hook pins LC_ALL=C.
    local locales=(C) loc
    for loc in en_US.UTF-8 pt_BR.UTF-8 en_US.utf8 pt_BR.utf8; do
        if locale -a 2>/dev/null | grep -qix "${loc}"; then
            locales+=("$loc")
        fi
    done
    loop_invoked
    send_message m1 "review-pr-520" "2026-10-09T10:30:00.000Z"
    transcript_text_record "Another Claude session sent a message:
$(idle_envelope review-pr-520 '{"type":"idle_notification","from":"review-pr-520","idleReason":"available"}')"
    plan_with_work
    for loc in "${locales[@]}"; do
        LC_ALL="$loc" run_guard
        [ "$status" -eq 2 ]
    done
}

@test "an idle quoted inside a tool_result does not settle a review" {
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    local body
    body="$(idle_envelope review-pr-520 '{"type":"idle_notification","from":"review-pr-520","timestamp":"2026-10-09T10:19:35.963Z","idleReason":"available"}')"
    jq -cn --arg t "Another Claude session sent a message:
$body" \
        '{type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: "r1", content: [{type: "text", text: $t}]}]}}' \
        >>"$TRANSCRIPT"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "an idle quoted inside a non-envelope user message does not settle a review" {
    # A compaction summary carries the idle text verbatim; it is a user record too.
    loop_invoked
    agent_dispatched a1 "review-pr-520"
    teammate_spawned a1 "review-pr-520"
    transcript_text_record "This session is being continued from a previous conversation. It held:
$(idle_envelope review-pr-520 '{"type":"idle_notification","from":"review-pr-520","timestamp":"2026-10-09T10:19:35.963Z","idleReason":"available"}')" "2026-10-09T10:20:00.000Z"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "a pretty-printed SendMessage receipt still counts as a delivery receipt" {
    loop_invoked
    send_message_raw m1 "review-pr-520" "2026-10-09T10:30:00.000Z" '{
  "success": true,
  "message": "Message sent to review-pr-520'"'"'s inbox",
  "msg_id": "8f18dc9f"
}'
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "a failed SendMessage result is not a delivery receipt" {
    loop_invoked
    send_message_raw m1 "review-pr-520" "2026-10-09T10:30:00.000Z" '{"success":false,"message":"Message sent to nobody"}'
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
}

@test "a PR number with a collision suffix is still one review name" {
    # The `-<k>` suffix cannot be told apart from more PR digits; both are review names.
    loop_invoked
    agent_dispatched a1 "review-pr-12-3"
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

# --- it fails open on what it cannot resolve ---------------------------------------

@test "fails open when the session never ran the loop" {
    plan_with_work
    run_guard
    [ "$status" -eq 0 ]
}

@test "fails open when a hook already caused this stop" {
    loop_invoked
    plan_with_work
    run_guard true
    [ "$status" -eq 0 ]
}

@test "fails open with no transcript path in the payload" {
    plan_with_work
    run bash "$GUARD" <<EOF
{"cwd":"$TEST_TMP","stop_hook_active":false}
EOF
    [ "$status" -eq 0 ]
}

@test "fails open when the cwd is not a git work tree" {
    loop_invoked
    plan_with_work
    local outside="$TEST_TMP/../not-a-repo-$$"
    mkdir -p "$outside"
    run bash "$GUARD" <<EOF
{"cwd":"$outside","transcript_path":"$TRANSCRIPT","stop_hook_active":false}
EOF
    rm -rf "$outside"
    [ "$status" -eq 0 ]
}

# --- but NEVER open about its own blindness ----------------------------------------

@test "blocks on an unreadable plan rather than reading it as nothing to do" {
    loop_invoked
    printf 'not json at all\n' >"$PLAN"
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
}

@test "blocks on a plan whose keys are present but malformed" {
    # Both keys exist, the object formats to nothing, and a key-only check would exit 0 here
    # as a false "no PR needs a reviewer".
    loop_invoked
    printf '%s\n' '{"rung":{"status":"ok"},"dispatchable":null,"excluded":{}}' >"$PLAN"
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
}

@test "blocks on an exclusion carrying no reason" {
    # An exclusion with an empty reason IS the silent skip this hook exists to refuse.
    loop_invoked
    printf '%s\n' '{"rung":{"status":"ok"},"dispatchable":[],"excluded":[{"pr":453,"reason":""}]}' >"$PLAN"
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREADABLE"* ]]
}

@test "blocks when the reviewer rung status is unknown" {
    loop_invoked
    printf '%s\n' '{"rung":{"status":"unknown"},"dispatchable":[],"excluded":[{"pr":453,"reason":"reviewer rung UNKNOWN"}]}' >"$PLAN"
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"rung UNKNOWN"* ]]
}

@test "rung none ANNOUNCES and does not block, naming what was not evaluated" {
    # ⚠️ EXPECTATION CORRECTED (was: asserts exit 0, silent pass). The original
    # expectation was provably wrong, not merely different: it conflated "every PR carries
    # its own named reason" (the planner ran and judged each PR — legitimately passes) with
    # "no rung resolved" (the mechanism that produces those reasons was never available, so
    # nothing was judged at all). A silent pass there asserts "nothing needed asking" when
    # the honest statement is "I could not tell" — the same shape as an empty `conclusion`
    # read as "failing". Blocking is equally wrong: nobody should be unable to end a turn
    # for not having signed into qwen or codex. Announce once, exit non-zero-but-not-2.
    loop_invoked
    printf '%s\n' '{"rung":{"status":"none"},"dispatchable":[],"excluded":[{"pr":453,"reason":"no reviewer rung is assignable"}]}' >"$PLAN"
    run_guard
    # 1, never 2: surfaced to the operator, but the stop is NOT blocked.
    [ "$status" -eq 1 ]
    # "not evaluated" is the load-bearing half — "no rung resolved" alone reads like a shrug.
    [[ "$output" == *"NOT evaluated"* ]]
    [[ "$output" == *"qwen/codex"* ]]
}

@test "rung none is announced ONCE per session, then quiet" {
    # A notice repeated every turn is noise, and noise is how a gate gets disabled — the
    # same once-per-session contract announce_no_planner already set.
    loop_invoked
    printf '%s\n' '{"rung":{"status":"none"},"dispatchable":[],"excluded":[{"pr":453,"reason":"no reviewer rung is assignable"}]}' >"$PLAN"
    run_guard
    [ "$status" -eq 1 ]
    run_guard
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rung none announces again for a DIFFERENT session" {
    # Keyed on session_id, so a fresh session is told once too rather than inheriting
    # another session's marker and never hearing it at all.
    loop_invoked
    printf '%s\n' '{"rung":{"status":"none"},"dispatchable":[],"excluded":[{"pr":453,"reason":"no reviewer rung is assignable"}]}' >"$PLAN"
    run_guard false session-one
    [ "$status" -eq 1 ]
    run_guard false session-two
    [ "$status" -eq 1 ]
}

@test "rung none never blocks even when PRs would otherwise be dispatchable" {
    # A planner that reports `none` should not produce a dispatchable list, but if a future
    # change ever let it, the rung verdict must still win: dispatching a reviewer with no
    # runtime to review with is worse than announcing.
    loop_invoked
    cat >"$PLAN" <<'EOF'
{"rung":{"status":"none"},"dispatchable":[{"pr":520,"head":"e1319925","checks":{"failing":[],"running":[],"ambiguous":[]}}],"excluded":[]}
EOF
    run_guard
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT evaluated"* ]]
}

@test "blocks on a rung status the hook has not been taught, naming the value" {
    # The planner's contract could grow a value (gate_pr_thread_state grew `unreviewed` in
    # #520). An unrecognised value must be loud, never fall through a missing else arm.
    loop_invoked
    printf '%s\n' '{"rung":{"status":"degraded"},"dispatchable":[],"excluded":[]}' >"$PLAN"
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"degraded"* ]]
}

@test "blocks when the planner is missing rather than passing quietly" {
    loop_invoked
    REVIEW_FANOUT_PLANNER="$TEST_TMP/absent.py"
    export REVIEW_FANOUT_PLANNER
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"no review fan-out planner"* ]]
}

@test "the block message surfaces the ladder tag so the reader routes it without asking" {
    loop_invoked
    cat >"$PLAN" <<'EOF'
{"rung":{"status":"ok","runtime":"qwen","model":"qwen3-coder-plus","signal":"configured-default"},
 "dispatchable":[{"pr":620,"head":"e1319925c49d","checks":{},"ladder":"bot-skipped"},
                 {"pr":621,"head":"abcdef0123456","checks":{},"ladder":null}],
 "excluded":[]}
EOF
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"#620"*"[ladder: bot-skipped]"*"run_fallback_review"* ]]
    [[ "$output" != *"#621"*"[ladder:"* ]]
}

# --- dotfiles-linux-dev#646: serial drain ------------------------------------------

plan_serial() {
    cat >"$PLAN" <<'PLAN_EOF'
{"rung":{"status":"ok","runtime":"qwen","model":"qwen3-coder-plus","signal":"configured-default"},
 "serial":true,
 "dispatchable":[{"pr":520,"head":"e1319925c49d","checks":{}}],
 "excluded":[{"pr":521,"reason":"serial drain: #520 is next in the queue"}]}
PLAN_EOF
}

@test "a serial plan blocks with the one queue head and says it is a serial drain" {
    loop_invoked
    plan_serial
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" == *"Serial drain"* ]]
    [[ "$output" == *"#520"* ]]
    [[ "$output" == *"#521  serial drain"* ]]
}

@test "a serial plan with the queue head's review agent in flight passes" {
    loop_invoked
    plan_serial
    agent_dispatched toolu_1 review-pr-520
    run_guard
    [ "$status" -eq 0 ]
}

@test "a non-serial plan carries no serial-drain note" {
    loop_invoked
    plan_with_work
    run_guard
    [ "$status" -eq 2 ]
    [[ "$output" != *"Serial drain"* ]]
}
