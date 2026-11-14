#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/loop_idle.sh (dotfiles-linux-dev#1003) — the predicate
# s:dev-loop runs before disarming its own crons. `gh` is a PATH stub (never the forge), the planner
# is a stub script via LOOP_IDLE_PLANNER, and the worktree walk runs for real on a throwaway repo.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/loop_idle.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$REPO" "$BIN"
    /usr/bin/git -C "$REPO" init -q -b main
    /usr/bin/git -C "$REPO" config user.email t@t
    /usr/bin/git -C "$REPO" config user.name t
    /usr/bin/git -C "$REPO" commit -q --allow-empty -m init
    /usr/bin/git -C "$REPO" remote add origin https://github.com/o/r.git

    cat >"$BIN/gh" <<'EOF'
#!/bin/bash
case "$*" in
*"state=open"*) [ "${GH_FAIL:-}" = open ] && exit 1; echo "${OPEN_PRS:-0}" ;;
*"state=all"*) [ "${GH_FAIL:-}" = all ] && exit 1; echo '[]' ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$BIN/gh"
    export PATH="$BIN:$PATH"

    cat >"$BIN/planner.py" <<'EOF'
import os, sys
if os.environ.get("PLAN_FAIL"):
    sys.exit(3)
print(os.environ["PLAN_JSON"])
EOF
    export LOOP_IDLE_PLANNER="$BIN/planner.py"
    export PLAN_JSON='{"dispatchable":[],"live_ok":true,"live_held":[],"excluded":[
      {"issue":122,"reason":"blocked: open native dependency o/other#5"},
      {"issue":119,"reason":"HITL: '"'hitl'"' label set — needs a human, never dispatched"}]}'
}

run_idle() { run bash "$LIB" "$REPO"; }

@test "loop_idle: all conditions hold -> IDLE with one named blocker line per issue" {
    run_idle
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "IDLE" ]
    [ "${lines[1]}" = "#119: HITL: 'hitl' label set" ]
    [ "${lines[2]}" = "#122: blocked: open native dependency o/other#5" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "loop_idle: no open issues at all -> IDLE, 0 blocked" {
    export PLAN_JSON='{"dispatchable":[],"live_ok":true,"live_held":[],"excluded":[]}'
    run_idle
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "IDLE" ]
    [ "${lines[1]}" = "blocked: 0 open issues" ]
}

@test "loop_idle: an open PR -> ACTIVE" {
    export OPEN_PRS=1
    run_idle
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "ACTIVE" ]
    [[ "${lines[1]}" == open-prs:* ]]
}

@test "loop_idle: uncommitted work in a worktree -> ACTIVE with a rescue line" {
    echo x >"$REPO/new.txt"
    run_idle
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "ACTIVE" ]
    [[ "${lines[1]}" == rescue:* ]]
}

@test "loop_idle: a live agent holding files -> ACTIVE" {
    export PLAN_JSON='{"dispatchable":[],"live_ok":true,"live_held":["a.sh"],"excluded":[]}'
    run_idle
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "ACTIVE" ]
    [[ "${lines[1]}" == live-agent:* ]]
}

@test "loop_idle: a dispatchable issue -> ACTIVE naming it" {
    export PLAN_JSON='{"dispatchable":[{"issue":7,"surface":["a"]}],"live_ok":true,"live_held":[],"excluded":[]}'
    run_idle
    [ "$status" -eq 1 ]
    [ "${lines[1]}" = "dispatchable: #7" ]
}

@test "loop_idle: an open issue with no named blocker (UNDECLARED) -> ACTIVE" {
    export PLAN_JSON='{"dispatchable":[],"live_ok":true,"live_held":[],"excluded":[
      {"issue":122,"reason":"blocked: open native dependency o/other#5"},
      {"issue":9,"reason":"UNDECLARED: no declared file surface"}]}'
    run_idle
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "ACTIVE" ]
    [ "${lines[1]}" = "#9: UNDECLARED: no declared file surface" ]
}

@test "loop_idle: a parent whose children are all closed is ready to close -> ACTIVE" {
    export PLAN_JSON='{"dispatchable":[],"live_ok":true,"live_held":[],"excluded":[
      {"issue":4,"reason":"PARENT: 2 sub-issues (0 open) — dispatch the children; every child is closed — ready to close"}]}'
    run_idle
    [ "$status" -eq 1 ]
}

@test "loop_idle: unreadable open-PR count -> ACTIVE (unknown), never IDLE" {
    GH_FAIL=open run_idle
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "ACTIVE (unknown: "* ]]
}

@test "loop_idle: unreadable PR list for the worktree walk -> ACTIVE (unknown)" {
    GH_FAIL=all run_idle
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "ACTIVE (unknown: "* ]]
}

@test "loop_idle: planner failure or latch -> ACTIVE (unknown)" {
    PLAN_FAIL=1 run_idle
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "ACTIVE (unknown: "* ]]
}

@test "loop_idle: liveness unreadable -> ACTIVE (unknown)" {
    export PLAN_JSON='{"dispatchable":[],"live_ok":false,"live_held":[],"excluded":[]}'
    run_idle
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "ACTIVE (unknown: "* ]]
}

@test "loop_idle: an UNKNOWN issue reason -> ACTIVE (unknown), never a blocker" {
    export PLAN_JSON='{"dispatchable":[],"live_ok":true,"live_held":[],"excluded":[
      {"issue":3,"reason":"blocked-state UNKNOWN (native dependency read failed) — never assumed dispatchable"}]}'
    run_idle
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "ACTIVE (unknown: "* ]]
}

@test "loop_idle: no GitHub origin -> ACTIVE (unknown)" {
    /usr/bin/git -C "$REPO" remote set-url origin /tmp/nowhere
    run_idle
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "ACTIVE (unknown: "* ]]
}

@test "loop_idle: an excluded entry with a non-string reason -> ACTIVE (unknown), never IDLE" {
    export PLAN_JSON='{"dispatchable":[],"live_ok":true,"live_held":[],"excluded":[{"issue":5,"reason":null}]}'
    run_idle
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "ACTIVE (unknown: dispatch plan unreadable or budget-latched)" ]
}

@test "loop_idle: live_held not an array -> ACTIVE (unknown)" {
    export PLAN_JSON='{"dispatchable":[],"live_ok":true,"live_held":{"a":"b"},"excluded":[]}'
    run_idle
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "ACTIVE (unknown:"* ]]
}

@test "loop_idle: UNKNOWN under a blocked: prefix -> ACTIVE (unknown), not a blocker" {
    export PLAN_JSON='{"dispatchable":[],"live_ok":true,"live_held":[],"excluded":[{"issue":7,"reason":"blocked: native dependency UNKNOWN"}]}'
    run_idle
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "ACTIVE (unknown: an open issue's state could not be read)" ]
}

@test "loop_idle: a non-repo dir -> ACTIVE (unknown), never IDLE" {
    run bash "$LIB" "$BATS_TEST_TMPDIR/bin"
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "ACTIVE (unknown:"* ]]
}
