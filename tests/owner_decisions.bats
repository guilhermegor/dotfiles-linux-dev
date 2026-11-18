#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/owner_decisions.sh (dotfiles-linux-dev#1033).
# Every source is a provider seam replaced with a fixture; nothing here calls GitHub.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    export OWNER_DECISIONS_REPOS="owner/repo"
    export OWNER_DECISIONS_EXCLUDE_FILE="$BATS_TEST_TMPDIR/exclusions.txt"
    : >"$OWNER_DECISIONS_EXCLUDE_FILE"
    PR_JSON='[]'
    ISSUE_JSON='[]'
    BOARD_REPORT=""
    WORKFLOWS=""
    REMOTE=""
    od_pr_json() { printf '%s' "$PR_JSON"; }
    od_issue_json() { printf '%s' "$ISSUE_JSON"; }
    od_board_report() { printf '%s\n' "$BOARD_REPORT"; }
    od_workflows_off() { printf '%s' "$WORKFLOWS"; }
    od_report_remote() { printf '%s' "$REMOTE"; }
}

@test "should-fail: a decision-blocked card IS listed" {
    BOARD_REPORT='board o/1 (r): ok — 1 item line(s)
  decision blocker owner/repo#7: decision: pick a vendor — left untouched (only a person clears this) [blocker-kind: decision]'
    run owner_decisions_collect
    [ "$status" -eq 0 ]
    [[ "$output" == *"owner/repo#7"* ]]
    [[ "$output" == *"pick a vendor"* ]]
}

@test "a still-blocked internal card is not a decision" {
    BOARD_REPORT='  still blocked owner/repo#8: owner/repo#2 [blocker-kind: internal]'
    run owner_decisions_collect
    [[ "$output" == *"No pending owner decisions."* ]]
}

@test "should-pass: a routine merged PR is NOT listed" {
    PR_JSON='[{"number":5,"title":"feat: x","state":"closed","merged_at":"2026-11-01T00:00:00Z","body":"Decide whether to keep this."},
              {"number":6,"title":"chore: y","state":"open","merged_at":null,"body":"Ready to merge, then release."}]'
    run owner_decisions_collect
    [[ "$output" == *"No pending owner decisions."* ]]
    [[ "$output" != *"#5"* && "$output" != *"#6"* ]]
}

@test "an open PR flagging a judgement call is listed" {
    PR_JSON='[{"number":9,"title":"feat: y","state":"open","merged_at":null,"body":"Intro\nDecide whether to enable the surface expansion.\nBye"}]'
    run owner_decisions_collect
    [[ "$output" == *"owner/repo#9"* ]]
    [[ "$output" == *"Decide whether to enable"* ]]
}

@test "hitl issue is listed; state:blocked only when blocked by a decision" {
    ISSUE_JSON='[{"number":11,"title":"a","labels":[{"name":"hitl"}],"body":"","pull_request":null},
                 {"number":12,"title":"b","labels":[{"name":"state:blocked"}],"body":"**Blocked by:** decision: x","pull_request":null},
                 {"number":13,"title":"c","labels":[{"name":"state:blocked"}],"body":"**Blocked by:** #2","pull_request":null}]'
    run owner_decisions_collect
    [[ "$output" == *"owner/repo#11"* ]]
    [[ "$output" == *"owner/repo#12"* ]]
    [[ "$output" != *"owner/repo#13"* ]]
}

@test "should-pass: an issue named in the exclusions file is NOT listed" {
    ISSUE_JSON='[{"number":1046,"title":"blocked","labels":[{"name":"hitl"}],"body":"","pull_request":null},
                 {"number":12,"title":"other","labels":[{"name":"hitl"}],"body":"","pull_request":null}]'
    printf '# standing exclusions\n#1046 # blocked until owner says, never ask\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" != *"#1046"* ]]
    [[ "$output" == *"owner/repo#12"* ]]
}

@test "a full-ref exclusion also hides a decision-blocked card" {
    BOARD_REPORT='  decision blocker owner/repo#7: decision: v — left untouched [blocker-kind: decision]'
    printf 'owner/repo#7\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" == *"No pending owner decisions."* ]]
}

@test "OFF workflows and REPORT-REMOTE branches are listed" {
    WORKFLOWS=$'owner/13\tAuto-add to project\n'
    REMOTE=$'feat/old\n'
    run owner_decisions_collect
    [[ "$output" == *"Auto-add to project"* ]]
    [[ "$output" == *"feat/old"* ]]
}

@test "an unreadable source is reported, never read as none" {
    od_pr_json() { return 1; }
    run owner_decisions_collect
    [[ "$output" == *"UNREADABLE"*"open PRs of owner/repo"* ]]
}
