#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/open_review_threads_nudge.sh (dotfiles-dev#397)
#
# Strategy:
#   - The hook is a stdin->exit-code filter: it reads a Stop-hook JSON payload and exits 0
#     (allow the stop) or 2 (block it), speaking only through stderr. Run it as a real
#     subprocess — `gh` is stubbed on PATH, `git`/`jq` are the real system binaries.
#   - The stub logs every `pr list` and `api graphql` call it serves, so a test can assert HOW
#     MANY calls were made (the short-circuit and cache tests), not just the final verdict.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/open_review_threads_nudge.sh"
    REPO="$(mktemp -d)"
    BIN="$REPO/bin"
    FIXTURE_DIR="$REPO/fixtures"
    mkdir -p "$BIN" "$FIXTURE_DIR"
    cd "$REPO" || return 1
    git init -q .
    git config user.email t@t.example
    git config user.name t

    export CLAUDE_CONFIG_DIR="$REPO/claude-home"
    export PRLIST_LOG="$REPO/prlist.log"
    export GRAPHQL_LOG="$REPO/graphql.log"
    export FIXTURE_DIR
    : >"$PRLIST_LOG"
    : >"$GRAPHQL_LOG"

    cat >"$BIN/gh" <<'STUB'
#!/bin/bash
case "$1 $2" in
"pr view")
    shift 2
    number="" json="" jqfilter=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --json) shift; json="$1" ;;
        --jq | -q) shift; jqfilter="$1" ;;
        --repo | -R) shift ;;
        -*) ;;
        *) number="$1" ;;
        esac
        shift
    done
    # Keyed on the --json/--jq PROJECTION, never the number/URL (dotfiles-dev#409's lesson): the
    # live re-check added for #423 asks `--json state --jq .state` for an explicit PR number,
    # which is a different call shape than the fast path's `--json number,state -q '...'` with no
    # number argument at all.
    if [ "$json" = "state" ] && [ "$jqfilter" = ".state" ]; then
        var="PR_STATE_${number}"
        printf '%s\n' "${!var:-OPEN}"
    else
        [ -n "${PR_VIEW_NUMBER:-}" ] && echo "$PR_VIEW_NUMBER"
    fi
    ;;
"repo view")
    echo "o/r"
    ;;
"pr list")
    echo call >>"$PRLIST_LOG"
    [ "${PR_LIST_FAIL:-0}" = 1 ] && exit 1
    printf '%s\n' "$PR_LIST"
    ;;
"issue view")
    shift 2
    number=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --json) shift ;;
        --jq | -q) shift ;;
        --repo | -R) shift ;;
        -*) ;;
        *) number="$1" ;;
        esac
        shift
    done
    var="ISSUE_BODY_${number}"
    printf '%s\n' "${!var:-}"
    ;;
"api graphql")
    shift 2
    num="" query=""
    while [ $# -gt 0 ]; do
        case "$1" in
        -F)
            shift
            case "$1" in number=*) num="${1#number=}" ;; esac
            shift
            ;;
        -f)
            shift
            case "$1" in query=*) query="${1#query=}" ;; esac
            shift
            ;;
        *)
            shift
            ;;
        esac
    done
    echo "$num" >>"$GRAPHQL_LOG"
    # dotfiles-dev#491's fix issues a SECOND graphql query (adds `isRequired`) to split a
    # genuinely-running CheckRun from an unbounded-PENDING StatusContext, distinct from the
    # gate's own reviewThreads/running query -- route each to its own fixture file.
    if printf '%s' "$query" | grep -q isRequired; then
        cat "$FIXTURE_DIR/$num.checks.json" 2>/dev/null || echo '{}'
    else
        cat "$FIXTURE_DIR/$num.json" 2>/dev/null || echo '{}'
    fi
    ;;
esac
STUB
    chmod +x "$BIN/gh"
    export PATH="$BIN:$PATH"
    export -f payload
}

teardown() {
    rm -rf "$REPO"
}

# payload STOP_HOOK_ACTIVE SESSION_ID TRANSCRIPT_PATH
payload() {
    jq -nc --argjson active "${1:-false}" --arg sid "${2:-}" --arg tp "${3:-}" \
        '{stop_hook_active: $active, session_id: $sid, transcript_path: $tp}'
}

# write_transcript PATH ISSUE_NAME [RESULT_TEXT]
# Writes a one-line JSONL transcript with a single dispatched Agent tool_use whose `name`
# declares ISSUE_NAME (e.g. "issue-600-fix-thing"). With no third argument the dispatch has NO
# tool_result yet -- "live" per inflight_dispatch_issues()'s own convention (dotfiles-dev#516).
# A third argument is written as the tool_result content instead (used to simulate a completed
# or failed background dispatch, which must NOT count as delegated work in flight).
write_transcript() {
    local path="$1" name="$2" result="${3:-}"
    {
        jq -nc --arg name "$name" \
            '{message: {content: [{type: "tool_use", name: "Agent", id: "toolu_1",
                                    input: {name: $name}}]}}'
        if [ -n "$result" ]; then
            jq -nc --arg r "$result" \
                '{message: {content: [{type: "tool_result", tool_use_id: "toolu_1",
                                        content: $r}]}}'
        fi
    } >"$path"
}

# append_notification PATH ID STATUS
# Appends a <task-notification> record naming ID's completed/failed status -- the shape
# _task_notification_status-style scans (`.. | strings`) find regardless of which JSON field
# carries it, so a plain top-level `content` key is enough for a test fixture.
append_notification() {
    local path="$1" id="$2" status_val="$3"
    jq -nc --arg t "<task-notification><tool-use-id>${id}</tool-use-id><status>${status_val}</status></task-notification>" \
        '{content: $t}' >>"$path"
}

# replied_unresolved_fixture NUM PATH
# A thread with a substantive HUMAN reply to a Bot finding, still unresolved -- the gate's own
# "replied — still needs RESOLVING" shape (no roster file, so __NO_ROSTER__ treats any non-Bot
# author as the reply that counts).
replied_unresolved_fixture() {
    local body
    body="$(printf 'y%.0s' {1..150})"
    jq -nc --arg path "$2" --arg body "$body" '{data: {repository: {pullRequest: {
        reviewThreads: {
            totalCount: 1,
            nodes: [{isResolved: false, path: $path, comments: {
                totalCount: 2,
                nodes: [
                    {author: {login: "coderabbitai", __typename: "Bot"}, body: $body},
                    {author: {login: "guilhermegor", __typename: "User"}, body: $body}
                ]
            }}]
        },
        comments: {totalCount: 0, nodes: []}
    }}}}' >"$FIXTURE_DIR/$1.json"
}

# dotfiles-dev#490: gate_pr_thread_state retries until the body carries a non-null `comments` key
# (the COMMENT-channel read #490 added), fail-closed on an incomplete page -- every gate-query
# fixture below must include `comments`, even empty, or the gate exhausts its retries and reports
# GATE_STATUS=unreadable instead of clean/problems/running.
clean_fixture() {
    jq -nc '{data: {repository: {pullRequest: {
        reviewThreads: {totalCount: 0, nodes: []},
        comments: {totalCount: 0, nodes: []}
    }}}}' >"$FIXTURE_DIR/$1.json"
}

# A single bot-only thread — no roster file in the test repo, so the __NO_ROSTER__ fallback
# treats any Bot author as a reviewer whose own comment never counts as an answer -> "problems".
problem_fixture() {
    local body
    body="$(printf 'x%.0s' {1..150})"
    jq -nc --arg body "$body" '{data: {repository: {pullRequest: {
        reviewThreads: {
            totalCount: 1,
            nodes: [{isResolved: false, path: "a.sh", comments: {
                totalCount: 1,
                nodes: [{author: {login: "coderabbitai", __typename: "Bot"}, body: $body}]
            }}]
        },
        comments: {totalCount: 0, nodes: []}
    }}}}' >"$FIXTURE_DIR/$1.json"
}

# running_fixture NUM STATE
# Gate-side fixture: zero threads, one StatusContext from a roster-listed creator, so
# gate_pr_thread_state reports GATE_STATUS=running -- the undifferentiated verdict dotfiles-dev#491
# is about. The caller must also write a `.review-bots.yaml` roster naming "coderabbitai[bot]",
# since the gate's running filter only counts a StatusContext whose creator is on the roster.
running_fixture() {
    jq -nc --arg state "$2" '{data: {repository: {pullRequest: {
        reviewThreads: {totalCount: 0, nodes: []},
        comments: {totalCount: 0, nodes: []},
        commits: {nodes: [{commit: {statusCheckRollup: {contexts: {totalCount: 1, nodes: [
            {__typename: "StatusContext", context: "CodeRabbit", state: $state,
             creator: {login: "coderabbitai"}}
        ]}}}}]}
    }}}}' >"$FIXTURE_DIR/$1.json"
}

roster_fixture() {
    cat >.review-bots.yaml <<'YAML'
reviewers:
  - login: coderabbitai[bot]
YAML
}

# checks_fixture NUM SHAPE
# The SECOND query's fixture (dotfiles-dev#491's own `isRequired`-bearing read). Every node
# carries the same roster-scoping fields the gate itself uses (`creator.login` /
# `checkSuite.app.slug` = "coderabbitai", matching `roster_fixture`'s "coderabbitai[bot]") and
# `totalCount` equal to the single returned node -- CodeRabbit review on PR #498 flagged both the
# missing roster scope and the missing truncation guard; `truncated-page` exercises that guard.
checks_fixture() {
    local shape="$2"
    case "$shape" in
    required-pending)
        jq -nc '{data:{repository:{pullRequest:{commits:{nodes:[{commit:{statusCheckRollup:
            {contexts:{totalCount:1,nodes:[{__typename:"StatusContext",context:"CodeRabbit",
                                state:"PENDING",isRequired:true,
                                creator:{login:"coderabbitai"}}]}}}}]}}}}}' ;;
    not-required-pending)
        jq -nc '{data:{repository:{pullRequest:{commits:{nodes:[{commit:{statusCheckRollup:
            {contexts:{totalCount:1,nodes:[{__typename:"StatusContext",context:"CodeRabbit",
                                state:"PENDING",isRequired:false,
                                creator:{login:"coderabbitai"}}]}}}}]}}}}}' ;;
    not-required-pending-unlisted)
        jq -nc '{data:{repository:{pullRequest:{commits:{nodes:[{commit:{statusCheckRollup:
            {contexts:{totalCount:1,nodes:[{__typename:"StatusContext",context:"unrelated-ci",
                                state:"PENDING",isRequired:false,
                                creator:{login:"some-other-bot"}}]}}}}]}}}}}' ;;
    checkrun-running)
        jq -nc '{data:{repository:{pullRequest:{commits:{nodes:[{commit:{statusCheckRollup:
            {contexts:{totalCount:1,nodes:[{__typename:"CheckRun",name:"build",
                                status:"IN_PROGRESS",isRequired:true,
                                checkSuite:{app:{slug:"coderabbitai"}}}]}}}}]}}}}}' ;;
    checkrun-running-unlisted)
        # Two contexts: an unrelated github-actions job still running (must be ignored -- it is
        # not a roster reviewer) alongside the real, non-required CodeRabbit status (must still
        # drive the downgrade). Proves the unrelated CheckRun cannot override the right answer.
        jq -nc '{data:{repository:{pullRequest:{commits:{nodes:[{commit:{statusCheckRollup:
            {contexts:{totalCount:2,nodes:[
                {__typename:"CheckRun",name:"lint",status:"IN_PROGRESS",isRequired:false,
                 checkSuite:{app:{slug:"github-actions"}}},
                {__typename:"StatusContext",context:"CodeRabbit",state:"PENDING",
                 isRequired:false,creator:{login:"coderabbitai"}}
            ]}}}}]}}}}}' ;;
    truncated-page)
        jq -nc '{data:{repository:{pullRequest:{commits:{nodes:[{commit:{statusCheckRollup:
            {contexts:{totalCount:2,nodes:[{__typename:"StatusContext",context:"CodeRabbit",
                                state:"PENDING",isRequired:false,
                                creator:{login:"coderabbitai"}}]}}}}]}}}}}' ;;
    esac >"$FIXTURE_DIR/$1.checks.json"
}

# --- dotfiles-dev#491: split a running CheckRun from an unbounded-PENDING StatusContext ----------

@test "a genuinely in-progress CheckRun still blocks, with the running message" {
    roster_fixture
    export PR_VIEW_NUMBER=55
    running_fixture 55 PENDING
    checks_fixture 55 checkrun-running
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"still running"* ]]
    [[ "$output" == *"build"* ]]
}

@test "a non-required PENDING commit status does not block and says why" {
    roster_fixture
    export PR_VIEW_NUMBER=56
    running_fixture 56 PENDING
    checks_fixture 56 not-required-pending
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pending (no completion expected)"* ]]
    [[ "$output" == *"CodeRabbit"* ]]
    [[ "$output" != *"still running"* ]]
}

@test "a required PENDING commit status still blocks" {
    roster_fixture
    export PR_VIEW_NUMBER=58
    running_fixture 58 PENDING
    checks_fixture 58 required-pending
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"still running"* ]]
    [[ "$output" == *"CodeRabbit"* ]]
}

@test "an unrelated non-roster CheckRun does not override the gate's downgrade to pending" {
    # PR #498 review (CodeRabbit): _classify_checks used to count ANY non-completed CheckRun,
    # so an unrelated CI job (github-actions, not a roster reviewer) still running would wrongly
    # override the gate's own "this is just a non-required CodeRabbit status" downgrade and keep
    # blocking on a check that has nothing to do with review completeness.
    roster_fixture
    export PR_VIEW_NUMBER=62
    running_fixture 62 PENDING
    checks_fixture 62 checkrun-running-unlisted
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pending (no completion expected)"* ]]
}

@test "an unrelated non-roster StatusContext is not treated as the pending one either" {
    roster_fixture
    export PR_VIEW_NUMBER=63
    running_fixture 63 PENDING
    checks_fixture 63 not-required-pending-unlisted
    run bash -c "payload | '$HOOK'"
    # Neither RUNNING_DETAIL nor PENDING_DETAIL matches (the only context on the page is not a
    # roster reviewer) -> _reclassify_running leaves the gate's original "still running" verdict.
    [ "$status" -eq 2 ]
    [[ "$output" == *"still running"* ]]
}

@test "a truncated context page keeps the gate's original running verdict, never downgrades" {
    # PR #498 review (CodeRabbit): totalCount > returned nodes means a real running check could
    # be sitting on a page this query never saw -- downgrading to pending_indefinite on an
    # incomplete read would silently drop a genuine wait.
    roster_fixture
    export PR_VIEW_NUMBER=64
    running_fixture 64 PENDING
    checks_fixture 64 truncated-page
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"still running"* ]]
}

@test "a failed re-classify query keeps the original still-running verdict (fail-safe)" {
    roster_fixture
    export PR_VIEW_NUMBER=57
    running_fixture 57 PENDING
    # No $FIXTURE_DIR/57.checks.json -> stub returns '{}' -> both RUNNING_DETAIL and
    # PENDING_DETAIL come back empty -> _reclassify_running leaves the gate's verdict alone.
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"still running"* ]]
}

@test "repo-wide scan: a non-required pending PR is skipped, a real problem further down still blocks" {
    unset PR_VIEW_NUMBER
    roster_fixture
    export PR_LIST=$'60\n61'
    running_fixture 60 PENDING
    checks_fixture 60 not-required-pending
    problem_fixture 61
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"PR #61"* ]]
}

# --- fast path: unchanged branch-scoped behaviour ------------------------------------------------

@test "fast path: a clean current-branch PR exits 0" {
    export PR_VIEW_NUMBER=42
    clean_fixture 42
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "fast path: a current-branch PR with problems blocks, referencing that PR only" {
    export PR_VIEW_NUMBER=42
    problem_fixture 42
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"PR #42"* ]]
    [[ "$output" != *"repo-wide"* ]]
}

# --- dotfiles-dev#516: delegated to a live, same-session agent covering the thread's path --------

@test "delegated: a replied-but-unresolved thread covered by a live same-session agent does not block" {
    export PR_VIEW_NUMBER=70
    replied_unresolved_fixture 70 "a/b.sh"
    export ISSUE_BODY_600=$'```surface\na/b.sh\n```'
    TRANSCRIPT="$REPO/transcript.jsonl"
    write_transcript "$TRANSCRIPT" "issue-600-fix-budget"
    run bash -c "payload false '' '$TRANSCRIPT' | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"delegated"* ]]
    [[ "$output" == *"issue-600"* ]]
}

@test "delegated: an agent whose declared surface does NOT cover the path still blocks" {
    export PR_VIEW_NUMBER=71
    replied_unresolved_fixture 71 "a/b.sh"
    export ISSUE_BODY_601=$'```surface\nother/file.sh\n```'
    TRANSCRIPT="$REPO/transcript.jsonl"
    write_transcript "$TRANSCRIPT" "issue-601-unrelated"
    run bash -c "payload false '' '$TRANSCRIPT' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"a/b.sh: replied — still needs RESOLVING"* ]]
    [[ "$output" != *"delegated"* ]]
}

@test "delegated: a COMPLETED dispatch is not in flight and still blocks" {
    export PR_VIEW_NUMBER=72
    replied_unresolved_fixture 72 "a/b.sh"
    export ISSUE_BODY_602=$'```surface\na/b.sh\n```'
    TRANSCRIPT="$REPO/transcript.jsonl"
    write_transcript "$TRANSCRIPT" "issue-602-fix-budget" "Async agent launched successfully"
    append_notification "$TRANSCRIPT" "toolu_1" "completed"
    run bash -c "payload false '' '$TRANSCRIPT' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"a/b.sh: replied — still needs RESOLVING"* ]]
    [[ "$output" != *"delegated"* ]]
}

@test "delegated: partial coverage still blocks on the uncovered thread, annotates the covered one" {
    export PR_VIEW_NUMBER=73
    jq -nc --arg body "$(printf 'y%.0s' {1..150})" '{data: {repository: {pullRequest: {
        reviewThreads: {totalCount: 2, nodes: [
            {isResolved: false, path: "a/b.sh", comments: {totalCount: 2, nodes: [
                {author: {login: "coderabbitai", __typename: "Bot"}, body: $body},
                {author: {login: "guilhermegor", __typename: "User"}, body: $body}
            ]}},
            {isResolved: false, path: "c/d.sh", comments: {totalCount: 2, nodes: [
                {author: {login: "coderabbitai", __typename: "Bot"}, body: $body},
                {author: {login: "guilhermegor", __typename: "User"}, body: $body}
            ]}}
        ]},
        comments: {totalCount: 0, nodes: []}
    }}}}' >"$FIXTURE_DIR/73.json"
    export ISSUE_BODY_604=$'```surface\na/b.sh\n```'
    TRANSCRIPT="$REPO/transcript.jsonl"
    write_transcript "$TRANSCRIPT" "issue-604-fix-one"
    run bash -c "payload false '' '$TRANSCRIPT' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"c/d.sh: replied — still needs RESOLVING"* ]]
    [[ "$output" == *"a/b.sh: delegated to issue-604"* ]]
}

@test "delegated: a thread with no reply yet is never delegated, even with a covering live agent" {
    export PR_VIEW_NUMBER=74
    problem_fixture 74
    export ISSUE_BODY_605=$'```surface\na.sh\n```'
    TRANSCRIPT="$REPO/transcript.jsonl"
    write_transcript "$TRANSCRIPT" "issue-605-fix-a"
    run bash -c "payload false '' '$TRANSCRIPT' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"needs a REPLY"* ]]
    [[ "$output" != *"delegated"* ]]
}

# --- stop_hook_active is honoured, and short-circuits before any gh call -------------------------

@test "stop_hook_active exits 0 without ever calling gh" {
    export PR_VIEW_NUMBER=42
    problem_fixture 42
    run bash -c "payload true | '$HOOK'"
    [ "$status" -eq 0 ]
    [ ! -s "$PRLIST_LOG" ]
    [ ! -s "$GRAPHQL_LOG" ]
}

# --- the regression: no PR for this branch/HEAD is exactly the silent case #397 reports ----------

@test "no PR for the current branch: a problem PR elsewhere in the repo now blocks the stop" {
    # PR_VIEW_NUMBER unset == detached HEAD / branch with no PR, exactly the orchestrator-session
    # shape #397 describes. The OLD branch-scoped code exits 0 here without ever looking further
    # -- this is the case that must now fall back to a repo-wide scan instead.
    export PR_LIST=$'10\n20'
    clean_fixture 10
    problem_fixture 20
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"repo-wide scan"* ]]
    [[ "$output" == *"PR #20"* ]]
}

@test "no PR for the current branch, every open PR clean: exits 0" {
    export PR_LIST=$'10\n20'
    clean_fixture 10
    clean_fixture 20
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "no PR for the current branch, no open PRs at all: exits 0" {
    export PR_LIST=""
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "a gh pr list failure fails open" {
    export PR_LIST=""
    export PR_LIST_FAIL=1
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 0 ]
}

# --- bound the cost: short-circuit and cache ------------------------------------------------------

@test "the repo-wide scan stops at the first non-clean PR, never querying the rest" {
    export PR_LIST=$'10\n20\n30'
    problem_fixture 10
    clean_fixture 20
    clean_fixture 30
    run bash -c "payload | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"PR #10"* ]]
    run grep -qx 10 "$GRAPHQL_LOG"
    [ "$status" -eq 0 ]
    run grep -qx 20 "$GRAPHQL_LOG"
    [ "$status" -ne 0 ]
    run grep -qx 30 "$GRAPHQL_LOG"
    [ "$status" -ne 0 ]
}

@test "a repeat scan within the cache TTL reuses the cached verdict, no second pr-list call" {
    export PR_LIST=$'10\n20'
    export OPEN_THREADS_NUDGE_CACHE_TTL=600
    clean_fixture 10
    problem_fixture 20
    run bash -c "payload false sess-1 | '$HOOK'"
    [ "$status" -eq 2 ]
    [ "$(wc -l <"$PRLIST_LOG")" -eq 1 ]

    run bash -c "payload false sess-1 | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"PR #20"* ]]
    [ "$(wc -l <"$PRLIST_LOG")" -eq 1 ]
}

@test "an expired cache entry triggers a fresh scan" {
    export PR_LIST=$'10\n20'
    export OPEN_THREADS_NUDGE_CACHE_TTL=600
    clean_fixture 10
    problem_fixture 20
    run bash -c "payload false sess-2 | '$HOOK'"
    [ "$status" -eq 2 ]
    [ "$(wc -l <"$PRLIST_LOG")" -eq 1 ]

    # Force the cached entry to look ten thousand seconds old.
    cache_file="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-2-o_r"
    [ -f "$cache_file" ]
    old_ts=$(( $(date +%s) - 10000 ))
    jq --argjson ts "$old_ts" '.ts = $ts' "$cache_file" >"$cache_file.tmp"
    mv "$cache_file.tmp" "$cache_file"

    run bash -c "payload false sess-2 | '$HOOK'"
    [ "$status" -eq 2 ]
    [ "$(wc -l <"$PRLIST_LOG")" -eq 2 ]
}

# --- PR #401 review finding: unreadable must fail OPEN in the repo-wide scan ------------------

# gate_pr_thread_state sets GATE_STATUS=unreadable when a PR's threads cannot be read. The scan
# used to treat every non-clean status as a blocking finding, so ONE transient GraphQL failure
# on an unrelated PR blocked the stop — and cached that verdict for the whole TTL. The
# branch-scoped path still fails closed on purpose; this one must not.
@test "repo-wide scan: an unreadable PR fails open instead of blocking" {
    unset PR_VIEW_NUMBER
    export PR_LIST=$'7\n8'
    problem_fixture 8   # a real finding exists further down the list
    # no fixture for 7 -> the stub returns '{}' -> that PR reads as unreadable

    run bash -c 'payload false sess-unreadable | "$0"' "$HOOK"
    [ "$status" -eq 0 ]
}

# --- dotfiles-dev#423: a cached verdict must not outlive the PR's own merge ---------------------

@test "a cached non-clean verdict for a PR that has since merged is dropped, not replayed" {
    export PR_LIST=$'10\n20'
    export OPEN_THREADS_NUDGE_CACHE_TTL=600
    clean_fixture 10
    problem_fixture 20
    run bash -c "payload false sess-423 | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"PR #20"* ]]

    # #20 merges inside the TTL window -- nothing re-scans, the cache is still "fresh".
    export PR_STATE_20=MERGED
    run bash -c "payload false sess-423 | '$HOOK'"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$PRLIST_LOG")" -eq 1 ]
}

@test "a cached non-clean verdict for a PR still open is replayed as before" {
    export PR_LIST=$'10\n20'
    export OPEN_THREADS_NUDGE_CACHE_TTL=600
    clean_fixture 10
    problem_fixture 20
    run bash -c "payload false sess-423b | '$HOOK'"
    [ "$status" -eq 2 ]

    export PR_STATE_20=OPEN
    run bash -c "payload false sess-423b | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"PR #20"* ]]
}

@test "repo-wide scan: an unreadable answer is never cached" {
    unset PR_VIEW_NUMBER
    export PR_LIST=$'7\n8'
    problem_fixture 8

    run bash -c 'payload false sess-nocache | "$0"' "$HOOK"
    [ "$status" -eq 0 ]

    run grep -rl 'unreadable' "$CLAUDE_CONFIG_DIR"
    [ "$status" -ne 0 ]
}

# --- dotfiles-dev#504 (second half): bound the cache's growth on each run -----------------------

@test "a cache entry older than the prune multiplier is deleted on the next run" {
    unset PR_VIEW_NUMBER
    export PR_LIST=""
    export OPEN_THREADS_NUDGE_CACHE_TTL=300
    export OPEN_THREADS_NUDGE_CACHE_PRUNE_MULTIPLIER=6

    mkdir -p "$CLAUDE_CONFIG_DIR/open-threads-nudge"
    stale="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-stale-o_r"
    old_ts=$(( $(date +%s) - 1801 ))   # just past 6 * 300s
    jq -nc --argjson ts "$old_ts" '{ts: $ts, number: "9", status: "problems", detail: "old"}' \
        >"$stale"

    run bash -c "payload false sess-fresh | '$HOOK'"
    [ "$status" -eq 0 ]
    [ ! -f "$stale" ]
}

@test "a cache entry still within the prune window survives another run" {
    unset PR_VIEW_NUMBER
    export PR_LIST=""
    export OPEN_THREADS_NUDGE_CACHE_TTL=300
    export OPEN_THREADS_NUDGE_CACHE_PRUNE_MULTIPLIER=6

    mkdir -p "$CLAUDE_CONFIG_DIR/open-threads-nudge"
    recent="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-recent-o_r"
    recent_ts=$(( $(date +%s) - 1000 ))   # short of 6 * 300s
    jq -nc --argjson ts "$recent_ts" '{ts: $ts, number: "9", status: "problems", detail: "old"}' \
        >"$recent"

    run bash -c "payload false sess-fresh | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -f "$recent" ]
}

@test "a cache file with an unreadable ts is pruned rather than kept" {
    unset PR_VIEW_NUMBER
    export PR_LIST=""

    mkdir -p "$CLAUDE_CONFIG_DIR/open-threads-nudge"
    corrupt="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-corrupt-o_r"
    echo "not json" >"$corrupt"

    run bash -c "payload false sess-fresh | '$HOOK'"
    [ "$status" -eq 0 ]
    [ ! -f "$corrupt" ]
}

@test "pruning runs across sessions: this session's own fresh entry is not swept" {
    export PR_LIST=$'10\n20'
    export OPEN_THREADS_NUDGE_CACHE_TTL=600
    clean_fixture 10
    problem_fixture 20

    mkdir -p "$CLAUDE_CONFIG_DIR/open-threads-nudge"
    stale="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-other-o_r"
    old_ts=$(( $(date +%s) - 100000 ))
    jq -nc --argjson ts "$old_ts" '{ts: $ts, number: "1", status: "clean", detail: ""}' \
        >"$stale"

    run bash -c "payload false sess-mine | '$HOOK'"
    [ "$status" -eq 2 ]
    [ ! -f "$stale" ]
    [ -f "$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-mine-o_r" ]
}

# --- dotfiles-dev#514 review: a knob that is not a positive integer must not disable the cache ---

@test "a prune multiplier of 0 falls back to the default instead of deleting fresh entries" {
    unset PR_VIEW_NUMBER
    export PR_LIST=""
    export OPEN_THREADS_NUDGE_CACHE_TTL=300
    export OPEN_THREADS_NUDGE_CACHE_PRUNE_MULTIPLIER=0

    mkdir -p "$CLAUDE_CONFIG_DIR/open-threads-nudge"
    fresh="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-fresh-entry-o_r"
    fresh_ts=$(( $(date +%s) - 10 ))
    jq -nc --argjson ts "$fresh_ts" '{ts: $ts, number: "9", status: "problems", detail: "new"}' \
        >"$fresh"

    run bash -c "payload false sess-other | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -f "$fresh" ]
}

@test "a non-numeric prune multiplier falls back to the default" {
    unset PR_VIEW_NUMBER
    export PR_LIST=""
    export OPEN_THREADS_NUDGE_CACHE_TTL=300
    export OPEN_THREADS_NUDGE_CACHE_PRUNE_MULTIPLIER=abc

    mkdir -p "$CLAUDE_CONFIG_DIR/open-threads-nudge"
    fresh="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-fresh-entry-o_r"
    fresh_ts=$(( $(date +%s) - 10 ))
    jq -nc --argjson ts "$fresh_ts" '{ts: $ts, number: "9", status: "problems", detail: "new"}' \
        >"$fresh"
    stale="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-stale-entry-o_r"
    old_ts=$(( $(date +%s) - 1801 ))   # past the DEFAULT 6 * 300s, proving the fallback is in use
    jq -nc --argjson ts "$old_ts" '{ts: $ts, number: "9", status: "problems", detail: "old"}' \
        >"$stale"

    run bash -c "payload false sess-other | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -f "$fresh" ]
    [ ! -f "$stale" ]
}

@test "a TTL of 0 falls back to the default rather than expiring every entry at once" {
    unset PR_VIEW_NUMBER
    export PR_LIST=""
    export OPEN_THREADS_NUDGE_CACHE_TTL=0
    export OPEN_THREADS_NUDGE_CACHE_PRUNE_MULTIPLIER=6

    mkdir -p "$CLAUDE_CONFIG_DIR/open-threads-nudge"
    fresh="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-fresh-entry-o_r"
    fresh_ts=$(( $(date +%s) - 10 ))
    jq -nc --argjson ts "$fresh_ts" '{ts: $ts, number: "9", status: "problems", detail: "new"}' \
        >"$fresh"

    run bash -c "payload false sess-other | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -f "$fresh" ]
}

@test "a future-dated cache entry is pruned, not kept forever as unusable" {
    unset PR_VIEW_NUMBER
    export PR_LIST=""
    export OPEN_THREADS_NUDGE_CACHE_TTL=300
    export OPEN_THREADS_NUDGE_CACHE_PRUNE_MULTIPLIER=6

    mkdir -p "$CLAUDE_CONFIG_DIR/open-threads-nudge"
    future="$CLAUDE_CONFIG_DIR/open-threads-nudge/sess-future-o_r"
    future_ts=$(( $(date +%s) + 99999 ))
    jq -nc --argjson ts "$future_ts" '{ts: $ts, number: "9", status: "problems", detail: "ahead"}' \
        >"$future"

    run bash -c "payload false sess-other | '$HOOK'"
    [ "$status" -eq 0 ]
    [ ! -f "$future" ]
}
