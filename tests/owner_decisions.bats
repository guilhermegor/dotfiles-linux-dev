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
    BOARD_REPORT=$'owner/repo#7\tdecision: pick a vendor'
    run owner_decisions_collect
    [ "$status" -eq 0 ]
    [[ "$output" == *"owner/repo#7"* ]]
    [[ "$output" == *"pick a vendor"* ]]
}

# The real od_board_report against a stubbed `gh`: decision cards only, and no write call ever.
_board_fixture_gh() {
    GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    : >"$GH_LOG"
    gh() {
        printf '%s\n' "$*" >>"$GH_LOG"
        [[ "$1 $2" == "project item-list" ]] || return 1
        printf '%s' '{"items":[
          {"status":"Blocked","blocked by":"decision: pick a vendor","content":{"type":"Issue","number":7,"repository":"owner/repo","body":""}},
          {"status":"Blocked","blocked by":"","content":{"type":"Issue","number":8,"repository":"owner/repo","body":"**Blocked by:** decision: which db"}},
          {"status":"Blocked","blocked by":"owner/repo#2","content":{"type":"Issue","number":9,"repository":"owner/repo","body":""}},
          {"status":"Ready","blocked by":"decision: x","content":{"type":"Issue","number":10,"repository":"owner/repo","body":""}}]}'
    }
}

@test "should-pass: the real board source lists only decision-blocked cards" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    ROADMAP_BOARDS=("owner|1|repo")
    _board_fixture_gh
    run od_board_report
    [ "$status" -eq 0 ]
    [[ "$output" == *$'owner/repo#7\tdecision: pick a vendor'* ]]
    [[ "$output" == *"owner/repo#8"* ]]
    [[ "$output" != *"#9"* && "$output" != *"#10"* ]]
}

@test "should-fail: the board source never writes to a board" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    ROADMAP_BOARDS=("owner|1|repo")
    _board_fixture_gh
    run od_board_report
    run grep -E 'item-edit|issue edit|mutation' "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "should-fail: a failing gh is UNREADABLE for every source, never none" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    ROADMAP_BOARDS=("owner|1|repo")
    gh() { echo "HTTP 401" >&2; return 1; }
    prune_branches() { return 2; }
    run owner_decisions_collect
    [[ "$output" == *"UNREADABLE"*"open PRs of owner/repo"* ]]
    [[ "$output" == *"UNREADABLE"*"owner-decision issues of owner/repo"* ]]
    [[ "$output" == *"UNREADABLE"*"board decision blockers"* ]]
    [[ "$output" == *"UNREADABLE"*"Projects workflows"* ]]
    [[ "$output" == *"UNREADABLE"*"REPORT-REMOTE branches"* ]]
}

@test "a null project in the workflows answer is UNREADABLE, not none OFF" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    ROADMAP_BOARDS=("org|1|repo")
    gh() { printf '%s' '{"data":{"user":null}}'; }
    run od_workflows_off
    [ "$status" -ne 0 ]
}

@test "an issue that is also a decision card is listed once" {
    ISSUE_JSON='[{"number":7,"title":"a","labels":[{"name":"state:blocked"}],"body":"**Blocked by:** decision: v","pull_request":null}]'
    BOARD_REPORT=$'owner/repo#7\tdecision: v'
    run owner_decisions_collect
    [ "$(grep -c 'owner/repo#7' <<<"$output")" -eq 1 ]
}

@test "should-pass: a #N exclusion does not hide a branch whose name holds #N" {
    REMOTE=$'fix#12\n'
    printf '#12\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" == *"fix#12"* ]]
}

@test "branch: and workflow: exclusions hide their rows" {
    WORKFLOWS=$'owner/13\tAuto-add to project\n'
    REMOTE=$'feat/old\n'
    printf 'branch:feat/old\nworkflow:owner/13/Auto-add to project # never ask\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" == *"No pending owner decisions."* ]]
}

@test "a Blocked by line that merely mentions decision is not a decision blocker" {
    ISSUE_JSON='[{"number":13,"title":"c","labels":[{"name":"state:blocked"}],"body":"**Blocked by:** #12 (no decision needed)","pull_request":null}]'
    run owner_decisions_collect
    [[ "$output" != *"owner/repo#13"* ]]
}

@test "a long multibyte cell is cut on a character boundary" {
    local long
    export LC_ALL=C.UTF-8
    long="$(printf 'é%.0s' {1..250})"
    run _od_cell "$long"
    [ "${#output}" -eq 200 ]
    iconv -f UTF-8 -t UTF-8 <<<"$output" >/dev/null
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

@test "default repos come from ROADMAP_BOARDS owner and repo, each once" {
    unset OWNER_DECISIONS_REPOS
    ROADMAP_BOARDS=("acme|1|tool" "acme|2|tool" "guilhermegor|3|other")
    SEEN="$BATS_TEST_TMPDIR/repos.log"
    od_pr_json() { printf '%s\n' "$1" >>"$SEEN"; printf '[]'; }
    run owner_decisions_collect
    [ "$(cat "$SEEN")" = $'acme/tool\nguilhermegor/other' ]
}
