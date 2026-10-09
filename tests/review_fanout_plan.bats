#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/review_fanout_plan.py — the review fan-out
# planner review_fanout_guard.sh reads for its verdict (dotfiles-linux-dev#480).
#
# THE POINT OF THIS SUITE is the "needs a review?" predicate, which #480 leaves open and
# which has a measured counter-example against BOTH obvious answers. Every one of the first
# four tests below is a real PR shape measured on this repo on 2026-09-26:
#
#   #520 — 9 submitted reviews, every one against an OLDER head; `reviews | length == 0` is
#          false, and the PR is still unreviewed at the head that would merge. The repo's own
#          published check-run said so: "no reviewer has reported on this new head yet."
#   #453 — 0 submitted reviews, and two REAL fallback reviews delivered as PR comments
#          carrying reviewer_ladder.sh's attribution line, both predating the current head.
#          A count says "never reviewed"; a head-AGNOSTIC attribution match (what
#          ladder_already_covered does) says "already covered". Both are wrong.
#
# So the predicate is head coverage across BOTH channels, and the tests pin each channel
# separately plus each channel's head-scoping — a suite that only checked "some review
# exists" would pass against the bug this planner exists to remove.
#
# Strategy (same as dispatch_plan.bats): `gh` is stubbed on PATH with a real executable
# script — the planner shells out to it directly, so a bash function defined in this bats
# process would be invisible to the child. The reviewer rung is supplied through
# REVIEW_FANOUT_RUNG rather than by probing: resolve_fallback_reviewer makes LIVE model calls
# and a test must never reach a real runtime.
#
# The gate's two-halves contract (ai_clients/CLAUDE.md, dotfiles-linux-dev#398) applies here too:
#   1. success returns a USABLE answer — dispatchable/excluded are the documented shape and
#      non-empty content actually reaches them, not merely an exit-0 with nothing set;
#   2. the fail-closed path is exercised deliberately, with a stub that makes the underlying
#      gh call fail, asserting nothing parseable reaches stdout (the whole-plan failure the
#      guard reads as UNREADABLE) rather than a partial plan that reads as an answer.
#
# Run locally: bats tests/review_fanout_plan.bats

setup() {
    PLANNER="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/review_fanout_plan.py"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP" || return 1

    BIN="$TEST_TMP/bin"
    mkdir -p "$BIN"
    PATH="$BIN:$PATH"
    export PATH

    GH_LOG="$TEST_TMP/gh.log"
    : >"$GH_LOG"
    export GH_LOG

    # A rung resolved, so no predicate test is silently masked by the rung's own exclusion
    # reason (which is checked on purpose by its own tests below).
    export REVIEW_FANOUT_RUNG="qwen|qwen3-coder-plus|configured-default"
    unset REVIEW_FANOUT_RECENT_PUSH_SECONDS REVIEW_FANOUT_BACKLOG_HOURS
    unset REVIEW_FANOUT_SERIAL GH_STRICT_RULESET GH_STRICT_CLASSIC GH_GRAPHQL_FAIL GH_REST_FAIL GH_GRAPHQL_MALFORMED
}

teardown() {
    cd /
    rm -rf "$TEST_TMP"
    unset REVIEW_FANOUT_RUNG REVIEW_FANOUT_RECENT_PUSH_SECONDS REVIEW_FANOUT_BACKLOG_HOURS
    unset REVIEW_FANOUT_SERIAL GH_STRICT_RULESET GH_STRICT_CLASSIC GH_GRAPHQL_FAIL GH_REST_FAIL GH_GRAPHQL_MALFORMED
}

# ago SECONDS — an ISO-8601 UTC timestamp that many seconds in the past.
ago() {
    date -u -d "@$(($(date -u +%s) - $1))" +%Y-%m-%dT%H:%M:%SZ
}

# stub_gh_prs — reads a flat PR-array fixture on stdin and puts a gh stub on PATH that serves
# TWO calls the planner makes. `api graphql` serves the board one page at a time (dotfiles-linux-dev#600):
# it honours the planner's own `first=` and `after=` variables, re-shapes the SAME flat fixture
# into the GraphQL page the real API returns (so every fixture below stays in its flat form), and
# uses the offset as the cursor. `GH_FAIL_AFTER=<cursor>` makes the page requested after that
# cursor fail like a gateway 502. `api repos/{owner}/{repo}/commits/<oid>` (dotfiles-linux-dev#537)
# looks the oid up in the fixture's per-PR `commits` array and prints its `committedDate` —
# simulating the REST read head_commit_time() makes. Every invocation is appended to $GH_LOG so a
# test can assert the planner issues no mutation and how many pages it asked for. A fixture may
# set `reviewsTotal`/`commentsTotal` above its node count to simulate a connection the 100-node
# window truncated (the API's `totalCount` exceeds the nodes it returned).
stub_gh_prs() {
    cat >"$TEST_TMP/prs.json"
    cat >"$BIN/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_LOG"
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    after=0
    first=20
    for arg in "$@"; do
        case "$arg" in
            after=*) after="${arg#after=}" ;;
            first=*) first="${arg#first=}" ;;
        esac
    done
    if [ -n "${GH_GRAPHQL_FAIL:-}" ]; then
        echo "gh: You have exceeded a secondary rate limit" >&2
        exit 1
    fi
    if [ "$after" = "${GH_FAIL_AFTER:-none}" ]; then
        echo "gh: HTTP 502" >&2
        exit 1
    fi
    jq --argjson after "$after" --argjson first "$first" '
        . as $all | .[$after:$after + $first] as $page
        | {data: {repository: {pullRequests: {
            pageInfo: {hasNextPage: (($after + $first) < ($all | length)),
                       endCursor: (($after + $first) | tostring)},
            nodes: [$page[] | {number, headRefOid, baseRefName: (.baseRefName // "master"), mergeStateStatus, isDraft,
                reviews: {totalCount: (.reviewsTotal // ((.reviews // []) | length)),
                          nodes: (.reviews // [])},
                comments: {totalCount: (.commentsTotal // ((.comments // []) | length)),
                           nodes: (.comments // [])},
                commits: {nodes: [{commit: {statusCheckRollup:
                    {contexts: {nodes: (.statusCheckRollup // [])}}}}]}}]}}}}
        | if env.GH_GRAPHQL_MALFORMED then del(.data.repository.pullRequests.nodes[].commits) else . end' "$FIXTURE"
elif [ "$1" = "api" ] && [[ "$2" == */rules/branches/* ]]; then
    [[ " ${GH_STRICT_RULESET:-} " == *" ${2##*/rules/branches/} "* ]] && echo true || echo false
elif [ "$1" = "api" ] && [[ "$2" == */branches/*/protection/required_status_checks ]]; then
    base="${2#*/branches/}"; base="${base%/protection/*}"
    [[ " ${GH_STRICT_CLASSIC:-} " == *" $base "* ]] && echo true || echo false
elif [ "$1" = "api" ] && [[ "$2" == repos/* ]] && [ -n "${GH_REST_FAIL:-}" ]; then
    echo "gh: HTTP 403" >&2
    exit 1
elif [ "$1" = "api" ] && [[ "$2" == */pulls\?state=open* ]]; then
    # the REST fallback (#689): same flat fixture, re-shaped into REST's own field names
    [[ "$2" == *page=1 ]] && filter='[.[] | {number, head: {sha: .headRefOid},
        base: {ref: (.baseRefName // "master")}, draft: .isDraft}]' || filter='[]'
    jq "$filter" "$FIXTURE"
elif [ "$1" = "api" ] && [[ "$2" == */pulls/*/reviews* ]]; then
    n="${2#*/pulls/}"; n="${n%%/*}"
    jq --argjson n "$n" '[.[] | select(.number == $n) | (.reviews // [])[] | {commit_id: .commit.oid}]' "$FIXTURE"
elif [ "$1" = "api" ] && [[ "$2" == */issues/*/comments* ]]; then
    n="${2#*/issues/}"; n="${n%%/*}"
    jq --argjson n "$n" '[.[] | select(.number == $n) | (.comments // [])[]
        | {body, created_at: .createdAt, user: {login: .author.login}}]' "$FIXTURE"
elif [ "$1" = "api" ] && [[ "$2" == */commits/*/check-runs* ]]; then
    oid="${2#*/commits/}"; oid="${oid%%/*}"
    jq --arg oid "$oid" '{check_runs: [.[] | select(.headRefOid == $oid) | (.statusCheckRollup // [])[]
        | {name, status: (.status | ascii_downcase), conclusion: ((.conclusion // "") | ascii_downcase | if . == "" then null else . end)}]}' "$FIXTURE"
elif [ "$1" = "api" ] && [[ "$2" == */pulls/[0-9]* ]]; then
    n="${2##*/}"
    jq --argjson n "$n" '[.[] | select(.number == $n)][0]
        | {mergeable_state: (if .mergeStateStatus == "DIRTY" then "dirty" else "blocked" end)}' "$FIXTURE"
elif [ "$1" = "api" ]; then
    oid="${2##*/}"
    jq -r --arg oid "$oid" \
        '[.[].commits[]? | select(.oid == $oid) | .committedDate] | first // empty' \
        "$FIXTURE"
else
    exit 1
fi
STUB
    chmod +x "$BIN/gh"
    FIXTURE="$TEST_TMP/prs.json"
    export FIXTURE
}

stub_gh_failing() {
    cat >"$BIN/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_LOG"
echo "gh: could not authenticate" >&2
exit 1
STUB
    chmod +x "$BIN/gh"
}

# reason_for PR — the exclusion reason recorded for that PR, empty when it is not excluded.
reason_for() {
    jq -r --argjson n "$1" '.excluded[] | select(.pr == $n) | .reason' <<<"$output"
}

# --- the predicate: channel 1, a submitted review, head-scoped ---------------------

@test "9 reviews all against older heads still needs a review (#520, measured)" {
    stub_gh_prs <<EOF
[{"number":520,"headRefOid":"e1319925","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[{"commit":{"oid":"d2c181fe"}},
             {"commit":{"oid":"55c5dca2"}},
             {"commit":{"oid":"55c5dca2"}},
             {"commit":{"oid":"3958727f"}}],
  "comments":[],
  "commits":[{"oid":"e1319925","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 1 ]
    [ "$(jq -r '.dispatchable[0].pr' <<<"$output")" = "520" ]
    [ "$(jq -r '.excluded | length' <<<"$output")" -eq 0 ]
}

@test "a submitted review naming the current head is coverage" {
    stub_gh_prs <<EOF
[{"number":600,"headRefOid":"aaaa1111","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[{"commit":{"oid":"bbbb2222"}},{"commit":{"oid":"aaaa1111"}}],
  "comments":[],
  "commits":[{"oid":"aaaa1111","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 600)" == *"already reviewed at the current head"* ]]
}

@test "zero reviews is not by itself a verdict — a covered head is still excluded" {
    # The inverse of the count predicate: reviews is EMPTY and the PR is still excluded,
    # because the fallback channel covered this head. A planner keyed on the count would
    # dispatch a reviewer here forever (#453's own failure mode).
    stub_gh_prs <<EOF
[{"number":601,"headRefOid":"cccc3333","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"Fallback review — runtime: codex, model: codex-auto-review (selected by: review-specialized-slug)\nReviewed head: cccc3333","createdAt":"$(ago 1800)"}],
  "commits":[{"oid":"cccc3333","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 601)" == *"already covered at the current head by a fallback review"* ]]
}

# --- the predicate: channel 2, a ladder comment, head-scoped -----------------------

@test "a ladder comment PREDATING the head is not coverage of it (#453, measured)" {
    # #453 verbatim: 0 submitted reviews, two attribution comments, both older than the head
    # commit. ladder_already_covered would call this covered forever; head-scoping is the
    # whole difference.
    stub_gh_prs <<EOF
[{"number":453,"headRefOid":"bf46b291","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"Fallback review — runtime: codex, model: codex-auto-review (selected by: review-specialized-slug)","createdAt":"$(ago 7200)"},
              {"body":"Fallback review — runtime: codex, model: codex-auto-review (selected by: review-specialized-slug)","createdAt":"$(ago 5400)"}],
  "commits":[{"oid":"bf46b291","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 1 ]
    [ "$(jq -r '.dispatchable[0].pr' <<<"$output")" = "453" ]
}

@test "a fresh ladder comment naming a DIFFERENT head is not coverage (#564, backdated head)" {
    # The finding on #588: the marker postdates the head commit's (backdated) committer date,
    # so a time-only check calls the PR covered — but the marker's own Reviewed head: line
    # names another commit, so no reviewer has seen this head.
    stub_gh_prs <<EOF
[{"number":605,"headRefOid":"aaaa5555","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"Fallback review — runtime: codex, model: codex-auto-review (selected by: review-specialized-slug)\nReviewed head: bbbb6666","createdAt":"$(ago 60)"}],
  "commits":[{"oid":"aaaa5555","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 1 ]
    [ "$(jq -r '.dispatchable[0].pr' <<<"$output")" = "605" ]
}

@test "a legacy ladder comment with no Reviewed head line is not coverage (#564, fail closed)" {
    stub_gh_prs <<EOF
[{"number":606,"headRefOid":"aaaa7777","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"Fallback review — runtime: codex, model: codex-auto-review (selected by: review-specialized-slug)","createdAt":"$(ago 60)"}],
  "commits":[{"oid":"aaaa7777","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 1 ]
}

@test "a comment merely quoting the attribution line mid-body is not coverage" {
    # Anchored per-line, the same shape ladder_already_covered's own regex uses: any
    # commenter can type the marker, and a substring match anywhere in a body would let a
    # passer-by cancel a review (CWE-345).
    stub_gh_prs <<EOF
[{"number":602,"headRefOid":"dddd4444","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"I was expecting a Fallback review — runtime: line here but saw none","createdAt":"$(ago 60)"}],
  "commits":[{"oid":"dddd4444","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 1 ]
}

# --- eligibility ------------------------------------------------------------------

@test "a DIRTY pull request is excluded — a review cannot resolve a conflict" {
    stub_gh_prs <<EOF
[{"number":603,"headRefOid":"eeee5555","mergeStateStatus":"DIRTY","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"eeee5555","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 603)" == *"DIRTY"* ]]
}

@test "a draft pull request is excluded" {
    stub_gh_prs <<EOF
[{"number":604,"headRefOid":"ffff6666","mergeStateStatus":"BLOCKED","isDraft":true,
  "reviews":[],"comments":[],
  "commits":[{"oid":"ffff6666","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 604)" == *"draft"* ]]
}

@test "a head pushed inside the recent-push window is excluded" {
    stub_gh_prs <<EOF
[{"number":605,"headRefOid":"7777aaaa","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"7777aaaa","committedDate":"$(ago 60)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 605)" == *"already triggers a re-review"* ]]
}

@test "a head whose commit is not in the commit list is UNKNOWN, never dispatchable" {
    # Fail closed on an undecidable head: without a head timestamp the ladder channel cannot
    # be head-scoped at all, so "needs a review" is unanswerable and no reviewer is assigned.
    stub_gh_prs <<'EOF'
[{"number":606,"headRefOid":"8888bbbb","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"9999cccc","committedDate":"2026-09-01T00:00:00Z"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 606)" == *"head commit UNKNOWN"* ]]
}

# --- the rung: none and unknown are different claims -------------------------------

@test "rung none excludes every PR with a named reason and an empty dispatchable list" {
    export REVIEW_FANOUT_RUNG=none
    stub_gh_prs <<EOF
[{"number":607,"headRefOid":"aaaa0001","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa0001","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]},
 {"number":608,"headRefOid":"aaaa0002","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa0002","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.rung.status' <<<"$output")" = "none" ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [ "$(jq -r '.excluded | length' <<<"$output")" -eq 2 ]
    [[ "$(reason_for 607)" == *"no reviewer rung is assignable"* ]]
}

@test "rung unknown is reported as unknown, never as none" {
    export REVIEW_FANOUT_RUNG=unknown
    stub_gh_prs <<EOF
[{"number":609,"headRefOid":"aaaa0003","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa0003","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.rung.status' <<<"$output")" = "unknown" ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 609)" == *"reviewer rung UNKNOWN"* ]]
}

@test "a resolved rung is reported with its runtime, model and selection signal" {
    stub_gh_prs <<'EOF'
[]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.rung.status' <<<"$output")" = "ok" ]
    [ "$(jq -r '.rung.runtime' <<<"$output")" = "qwen" ]
    [ "$(jq -r '.rung.model' <<<"$output")" = "qwen3-coder-plus" ]
    [ "$(jq -r '.rung.signal' <<<"$output")" = "configured-default" ]
}

# --- statusCheckRollup: split running from failing, never resolve by name ----------

@test "two check-runs with the same name and opposite conclusions read as ambiguous" {
    # Measured on #520's head: `Review threads answered` appeared TWICE, SUCCESS and FAILURE
    # — one from the workflow job, one POSTed by the workflow. Resolving by
    # name-and-first-match returns a coin flip that reads as an authoritative verdict, which
    # is why #480's third candidate predicate (the step-4 gate's check) was rejected.
    stub_gh_prs <<EOF
[{"number":610,"headRefOid":"aaaa0004","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa0004","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"Review threads answered","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Review threads answered","status":"COMPLETED","conclusion":"FAILURE"}]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].checks.ambiguous | join(",")' <<<"$output")" = "Review threads answered" ]
    [ "$(jq -r '.dispatchable[0].checks.failing | length' <<<"$output")" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].checks.running | length' <<<"$output")" -eq 0 ]
}

@test "an IN_PROGRESS check with an empty conclusion is running, not failing" {
    # `conclusion != "SUCCESS"` would call this red: a check in flight has a populated
    # `status` and an EMPTY `conclusion`.
    stub_gh_prs <<EOF
[{"number":611,"headRefOid":"aaaa0005","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa0005","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"bats (unit tests)","status":"IN_PROGRESS","conclusion":""},
    {"__typename":"CheckRun","name":"shellcheck","status":"QUEUED","conclusion":""},
    {"__typename":"CheckRun","name":"yamllint","status":"COMPLETED","conclusion":"FAILURE"}]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].checks.running | join(",")' <<<"$output")" = "bats (unit tests),shellcheck" ]
    [ "$(jq -r '.dispatchable[0].checks.failing | join(",")' <<<"$output")" = "yamllint" ]
}

@test "a StatusContext is read with its own state vocabulary, not a CheckRun's" {
    # `.conclusion // .state` mixes the two vocabularies: a StatusContext has neither status
    # nor conclusion, and a PENDING one is running. This repo's own CodeRabbit entry is this
    # shape.
    stub_gh_prs <<EOF
[{"number":612,"headRefOid":"aaaa0006","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa0006","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[
    {"__typename":"StatusContext","context":"CodeRabbit","state":"PENDING"},
    {"__typename":"StatusContext","context":"GitGuardian","state":"SUCCESS"},
    {"__typename":"StatusContext","context":"legacy-ci","state":"FAILURE"}]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].checks.running | join(",")' <<<"$output")" = "CodeRabbit" ]
    [ "$(jq -r '.dispatchable[0].checks.failing | join(",")' <<<"$output")" = "legacy-ci" ]
}

@test "NEUTRAL and SKIPPED conclusions are not failures" {
    stub_gh_prs <<EOF
[{"number":613,"headRefOid":"aaaa0007","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa0007","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"optional-job","status":"COMPLETED","conclusion":"SKIPPED"},
    {"__typename":"CheckRun","name":"advisory","status":"COMPLETED","conclusion":"NEUTRAL"}]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].checks.failing | length' <<<"$output")" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].checks.running | length' <<<"$output")" -eq 0 ]
}

# --- contract: shape, reasons, no mutation, fail-closed ----------------------------

@test "success returns a USABLE answer, not just exit 0" {
    stub_gh_prs <<EOF
[{"number":614,"headRefOid":"aaaa0008","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa0008","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]},
 {"number":615,"headRefOid":"aaaa0009","mergeStateStatus":"DIRTY","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa0009","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    run jq -e '
        (.rung.status | type == "string")
        and (.dispatchable | type == "array") and (.excluded | type == "array")
        and ((.dispatchable | length) > 0) and ((.excluded | length) > 0)
        and all(.dispatchable[]; (.pr | type == "number") and ((.head // "") | length > 0))
        and all(.excluded[]; (.pr | type == "number") and ((.reason // "") | length > 0))
    ' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "every excluded pull request carries its own non-empty reason" {
    stub_gh_prs <<EOF
[{"number":616,"headRefOid":"bbbb0001","mergeStateStatus":"DIRTY","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"bbbb0001","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]},
 {"number":617,"headRefOid":"bbbb0002","mergeStateStatus":"BLOCKED","isDraft":true,
  "reviews":[],"comments":[],
  "commits":[{"oid":"bbbb0002","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]},
 {"number":618,"headRefOid":"bbbb0003","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[{"commit":{"oid":"bbbb0003"}}],"comments":[],
  "commits":[{"oid":"bbbb0003","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.excluded | length' <<<"$output")" -eq 3 ]
    # Distinct reasons, not one blanket string: the per-PR reason IS the escape hatch, so a
    # single reused sentence would hide which rule actually fired.
    [ "$(jq -r '[.excluded[].reason] | unique | length' <<<"$output")" -eq 3 ]
}

@test "the planner only READS — it issues no gh mutation" {
    stub_gh_prs <<EOF
[{"number":619,"headRefOid":"cccc0001","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"cccc0001","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    # Scheduling is deterministic; accepting a finding is not. Nothing here may comment,
    # review, resolve or merge (#480's boundary).
    run grep -Eq 'pr (comment|review|merge|edit)|api .*-X|--method|mutation' "$GH_LOG"
    [ "$status" -ne 0 ]
    run grep -q 'api graphql' "$GH_LOG"
    [ "$status" -eq 0 ]
}

@test "a failing gh read produces NOTHING parseable on stdout (fail closed as one unit)" {
    stub_gh_failing
    run python3 "$PLANNER"
    [ "$status" -ne 0 ]
    # Not a partial plan, and not an empty-but-valid one: either would read downstream as
    # "no PR needs a reviewer". The guard's own shape check is what turns this into a block.
    run jq -e '.dispatchable' <<<"$output"
    [ "$status" -ne 0 ]
}

# dotfiles-linux-dev#559 follow-up: `gh pr list` raising CalledProcessError used to propagate
# uncaught -- the guard's own fail-closed contract above still held (empty/unparseable
# stdout, non-zero exit), but an agent running this planner DIRECTLY during s:dev-loop step
# 4b saw a raw Python stack trace instead of a one-line, actionable message. This asserts the
# failure is caught and reported cleanly, never as an uncaught traceback.
@test "a failing gh read reports the failure cleanly, never as an uncaught traceback" {
    stub_gh_failing
    run python3 "$PLANNER"
    [ "$status" -eq 1 ]
    [[ "$output" != *"Traceback"* ]]
    [[ "$output" == *"review_fanout_plan: could not read the board"* ]]
}

# --- dotfiles-linux-dev#689: GraphQL refused by the secondary limit, REST still answers ---

# rest_fallback_board — a mixed board: a failing check, a conflict, a draft, a covered head and
# a bot-skipped PR, so the REST adapter is compared on every field the planner reads.
rest_fallback_board() {
    stub_gh_prs <<EOF
[{"number":801,"headRefOid":"aaaa8010","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[{"commit":{"oid":"zzzz0000"}}],"comments":[],
  "commits":[{"oid":"aaaa8010","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"},
                       {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":""}]},
 {"number":802,"headRefOid":"aaaa8020","mergeStateStatus":"DIRTY","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa8020","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]},
 {"number":803,"headRefOid":"aaaa8030","mergeStateStatus":"BLOCKED","isDraft":true,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa8030","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]},
 {"number":804,"headRefOid":"aaaa8040","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[{"commit":{"oid":"aaaa8040"}}],"comments":[],
  "commits":[{"oid":"aaaa8040","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]},
 {"number":805,"headRefOid":"aaaa8050","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"Review skipped\n\nBot user detected","createdAt":"$(ago 900)","author":{"login":"coderabbitai[bot]"}}],
  "commits":[{"oid":"aaaa8050","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
}

@test "GraphQL refused, REST answering: the plan equals the GraphQL path's plan (#689)" {
    rest_fallback_board
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    graphql_plan="$(jq -S . <<<"$output")"
    # sanity: the board really exercises every branch, so equality is not vacuous
    [ "$(jq -r '.dispatchable | map(.pr) | join(",")' <<<"$graphql_plan")" = "801,805" ]
    [ "$(jq -r '.dispatchable[0].checks.failing[0]' <<<"$graphql_plan")" = "lint" ]
    [ "$(jq -r '.dispatchable[0].checks.running[0]' <<<"$graphql_plan")" = "test" ]
    [ "$(jq -r '.dispatchable[1].ladder' <<<"$graphql_plan")" = "bot-skipped" ]
    [[ "$(jq -r '.excluded[] | select(.pr == 802) | .reason' <<<"$graphql_plan")" == *DIRTY* ]]

    : >"$GH_LOG"
    export GH_GRAPHQL_FAIL=1
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -S . <<<"$output")" = "$graphql_plan" ]
    run grep -q 'pulls?state=open' "$GH_LOG"
    [ "$status" -eq 0 ]
}

@test "a GraphQL node malformed below the page level still falls back to REST (#689)" {
    rest_fallback_board
    export GH_GRAPHQL_MALFORMED=1
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | map(.pr) | join(",")' <<<"$output")" = "801,805" ]
    run grep -q 'pulls?state=open' "$GH_LOG"
    [ "$status" -eq 0 ]
}

@test "the REST fallback issues no gh mutation either (#689)" {
    rest_fallback_board
    export GH_GRAPHQL_FAIL=1
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    run grep -Eq 'pr (comment|review|merge|edit)|api .*-X|--method|mutation' "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "GraphQL AND REST both refused is UNREADABLE, never an empty plan (#689)" {
    rest_fallback_board
    export GH_GRAPHQL_FAIL=1 GH_REST_FAIL=1
    run python3 "$PLANNER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"review_fanout_plan: could not read the board"* ]]
    [[ "$output" != *"dispatchable"* ]]
    [[ "$output" != *"Traceback"* ]]
    run grep -q 'pulls?state=open' "$GH_LOG"
    [ "$status" -eq 0 ]
}

@test "an empty open-PR list is a valid, complete, empty plan" {
    stub_gh_prs <<'EOF'
[]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [ "$(jq -r '.excluded | length' <<<"$output")" -eq 0 ]
}

# --- dotfiles-linux-dev#537: the request shape itself, not just the parse -----------------

@test "PR_SELECTION bounds every connection — GitHub rejects an unbounded commits one (#537, #600)" {
    # THE test that would have caught #537: every test above stubs `gh`, so it passes
    # regardless of what the real query asks for — this is the one assertion pinned against
    # the REQUEST, not the response. Measured against the live repo 2026-09-27: an unbounded
    # `commits` is rejected at --limit 200, 100, 60 and even at 50 ("requesting up to 1,000,000
    # possible nodes which exceeds the maximum limit of 500,000") — commits multiplies PRs x
    # commits x each commit's own authors connection. #600 moved the read to GraphQL pages, so
    # the same guarantee is now stated as "every connection carries first:/last:", and
    # `commits` may only be the one-commit rollup carrier.
    run python3 -c "
import re, sys
sys.path.insert(0, '$(dirname "$PLANNER")')
from review_fanout_plan import PR_SELECTION
print(PR_SELECTION)
for name in ('reviews', 'comments', 'commits', 'contexts'):
    mentioned = len(re.findall(r'\\b' + name + r'\\b', PR_SELECTION))
    bounded = len(re.findall(name + r'\\((first|last):\\d+\\)', PR_SELECTION))
    assert mentioned == bounded >= 1, (name, mentioned, bounded)
assert 'commits(last:1)' in PR_SELECTION
"
    [ "$status" -eq 0 ]
}

# --- dotfiles-linux-dev#600: the board is read in small pages, whole or not at all --------

# board_of N — a flat fixture of N open PRs, each unreviewed at a head an hour old, so every
# one of them is dispatchable and a page dropped on the way shows up as a missing number.
board_of() {
    jq -n --argjson n "$1" --arg when "$(ago 3600)" '[range(1; $n + 1) | {
        number: ., headRefOid: "head\(.)", mergeStateStatus: "BLOCKED", isDraft: false,
        reviews: [], comments: [],
        commits: [{oid: "head\(.)", committedDate: $when}],
        statusCheckRollup: [{__typename: "CheckRun", name: "lint", status: "COMPLETED",
                             conclusion: "SUCCESS"}]}]'
}

@test "a board larger than one page returns the UNION of every page (#600)" {
    stub_gh_prs <<<"$(board_of 45)"
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    # 45 PRs at 20 per page: three requests, and every PR from every page in the answer.
    [ "$(grep -c 'api graphql' "$GH_LOG")" -eq 3 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 45 ]
    [ "$(jq -r '[.dispatchable[].pr] | sort == [range(1; 46)]' <<<"$output")" = "true" ]
    # The rollup survived the re-shape on a PR from the LAST page, not just the first.
    [ "$(jq -r '.dispatchable[] | select(.pr == 45) | .checks.failing | length' <<<"$output")" -eq 0 ]
}

@test "the paged read asks for small pages with a cursor, never one big request (#600)" {
    stub_gh_prs <<<"$(board_of 45)"
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    run grep -c 'first=20' "$GH_LOG"
    [ "$output" -eq 3 ]
    run grep -c 'after=20' "$GH_LOG"
    [ "$output" -eq 1 ]
    run grep -c 'after=40' "$GH_LOG"
    [ "$output" -eq 1 ]
}

@test "a page that fails mid-pagination is UNREADABLE for the whole board, no partial plan (#600)" {
    stub_gh_prs <<<"$(board_of 45)"
    # Page one (PRs 1-20) answers; the page after cursor 20 returns a gateway 502.
    export GH_FAIL_AFTER=20
    # REST refused too: since #689 a REST-readable board falls back to a whole REST read, which
    # is the other half of this contract (whole board or UNREADABLE) and is tested below.
    export GH_REST_FAIL=1
    run python3 "$PLANNER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"review_fanout_plan: could not read the board"* ]]
    # The 20 PRs page one DID read must not leak out as a plan that reads as the whole board.
    [[ "$output" != *"dispatchable"* ]]
    [[ "$output" != *"Traceback"* ]]
    [ "$(grep -c 'api graphql' "$GH_LOG")" -eq 2 ]
}

@test "a malformed page is UNREADABLE, never read as an empty or final page (#600)" {
    cat >"$BIN/gh" <<'STUB'
#!/bin/bash
echo '{"data":{"repository":null}}'
STUB
    chmod +x "$BIN/gh"
    run python3 "$PLANNER"
    [ "$status" -ne 0 ]
    [[ "$output" != *"dispatchable"* ]]
}

@test "the stub path still yields a head time after commits left PR_FIELDS" {
    # head_commit_time() now fetches the date via `gh api repos/{owner}/{repo}/commits/<oid>`
    # instead of reading it off the list response — this pins that the fallback rung's
    # recent-push exclusion (which needs a real head time to compare against `now`) still
    # fires, proving the REST read actually lands rather than silently returning None on
    # every PR (which would misread as "head commit UNKNOWN" everywhere, not just here).
    stub_gh_prs <<EOF
[{"number":621,"headRefOid":"eeee0001","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"eeee0001","committedDate":"$(ago 60)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 621)" == *"already triggers a re-review"* ]]
    run grep -q 'api repos/{owner}/{repo}/commits/eeee0001' "$GH_LOG"
    [ "$status" -eq 0 ]
}

@test "the recent-push window is configurable and actually applied" {
    export REVIEW_FANOUT_RECENT_PUSH_SECONDS=30
    stub_gh_prs <<EOF
[{"number":620,"headRefOid":"dddd0001","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"dddd0001","committedDate":"$(ago 120)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    # 120s old, window 30s — outside it, so the push no longer excuses the missing review.
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 1 ]
}

# --- a truncated reviews/comments window is undecidable, never "not covered" ---------

@test "a truncated comment window with no coverage in view is excluded by name, not dispatched" {
    # comments(last:100) of 150: the attribution comment covering this head could be among
    # the 50 the window dropped. "Not covered" is unprovable, so the PR must not be offered
    # a reviewer on a guess (the duplicate assignment the codex review of #605 predicted).
    stub_gh_prs <<EOF
[{"number":610,"headRefOid":"dddd4444","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"unrelated","createdAt":"$(ago 900)"}],
  "commentsTotal":150,
  "commits":[{"oid":"dddd4444","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 610)" == *"comments truncated"* ]]
}

@test "a truncated review window with no coverage in view is excluded by name" {
    stub_gh_prs <<EOF
[{"number":611,"headRefOid":"eeee5555","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[{"commit":{"oid":"ffff6666"}}],
  "reviewsTotal":101,
  "comments":[],
  "commits":[{"oid":"eeee5555","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
    [[ "$(reason_for 611)" == *"reviews truncated"* ]]
}

@test "coverage found inside a truncated window still counts as covered" {
    # A positive hit is valid however much history was dropped; only the negative is not.
    stub_gh_prs <<EOF
[{"number":612,"headRefOid":"aaaa7777","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[{"commit":{"oid":"aaaa7777"}}],
  "reviewsTotal":300,
  "comments":[],
  "commits":[{"oid":"aaaa7777","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [[ "$(reason_for 612)" == *"already reviewed at the current head"* ]]
}

@test "windows that hold their whole totalCount are not truncated" {
    stub_gh_prs <<EOF
[{"number":613,"headRefOid":"bbbb8888","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[{"commit":{"oid":"cccc9999"}}],
  "comments":[],
  "commits":[{"oid":"bbbb8888","committedDate":"$(ago 3600)"}],
  "statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].pr' <<<"$output")" = "613" ]
}

@test "a 55-PR board, past the size that 502'd the single page, is read whole (dotfiles-linux-dev#616)" {
    stub_gh_prs <<<"$(board_of 55)"
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'api graphql' "$GH_LOG")" -eq 3 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 55 ]
}

# --- the ladder trigger: backlog and structural refusal, not slot state (#616) ------------

@test "an unreviewed head older than the backlog window is flagged for the ladder" {
    stub_gh_prs <<EOF
[{"number":700,"headRefOid":"aaaa7000","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa7000","committedDate":"$(ago 28800)"}],"statusCheckRollup":[]},
 {"number":701,"headRefOid":"aaaa7010","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa7010","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[] | select(.pr == 700) | .ladder' <<<"$output")" = "backlog" ]
    [ "$(jq -r '.dispatchable[] | select(.pr == 701) | .ladder' <<<"$output")" = "null" ]
}

@test "the backlog window is configurable" {
    export REVIEW_FANOUT_BACKLOG_HOURS=0.5
    stub_gh_prs <<EOF
[{"number":702,"headRefOid":"aaaa7020","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa7020","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].ladder' <<<"$output")" = "backlog" ]
}

@test "a CodeRabbit bot-skip notice is a structural refusal even on a fresh head" {
    stub_gh_prs <<EOF
[{"number":703,"headRefOid":"aaaa7030","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"Review skipped — Bot user detected","createdAt":"$(ago 900)",
               "author":{"login":"coderabbitai[bot]"}}],
  "commits":[{"oid":"aaaa7030","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].ladder' <<<"$output")" = "bot-skipped" ]
}

@test "a human typing the bot-skip phrase is not a refusal" {
    stub_gh_prs <<EOF
[{"number":704,"headRefOid":"aaaa7040","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"Review skipped — Bot user detected","createdAt":"$(ago 900)",
               "author":{"login":"someone"}}],
  "commits":[{"oid":"aaaa7040","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].ladder' <<<"$output")" = "null" ]
}

@test "a DIRTY backlog PR stays excluded, never flagged for the ladder" {
    stub_gh_prs <<EOF
[{"number":705,"headRefOid":"aaaa7050","mergeStateStatus":"DIRTY","isDraft":false,
  "reviews":[],"comments":[],
  "commits":[{"oid":"aaaa7050","committedDate":"$(ago 28800)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable | length' <<<"$output")" -eq 0 ]
}

@test "a lookalike coderabbit login cannot fake a bot-skip refusal (CWE-290)" {
    stub_gh_prs <<EOF
[{"number":706,"headRefOid":"aaaa7060","mergeStateStatus":"BLOCKED","isDraft":false,
  "reviews":[],
  "comments":[{"body":"Review skipped — Bot user detected","createdAt":"$(ago 900)",
               "author":{"login":"coderabbit-fan"}}],
  "commits":[{"oid":"aaaa7060","committedDate":"$(ago 3600)"}],"statusCheckRollup":[]}]
EOF
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.dispatchable[0].ladder' <<<"$output")" = "null" ]
}

# --- dotfiles-linux-dev#646: serial drain under strict merges -----------------------------

@test "strict ruleset: only the head of the merge queue is dispatchable (#646)" {
    stub_gh_prs <<<"$(board_of 4)"
    export GH_STRICT_RULESET=master
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.serial' <<<"$output")" = "true" ]
    [ "$(jq -c '[.dispatchable[].pr]' <<<"$output")" = "[1]" ]
    [ "$(jq -r '.excluded | length' <<<"$output")" -eq 3 ]
    [[ "$(reason_for 3)" == *"serial drain"*"#1 is next in the queue"* ]]
}

@test "classic branch protection strict is detected too (#646)" {
    stub_gh_prs <<<"$(board_of 3)"
    export GH_STRICT_CLASSIC=master
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.dispatchable[].pr]' <<<"$output")" = "[1]" ]
}

@test "non-strict repo keeps the parallel fan-out (#646)" {
    stub_gh_prs <<<"$(board_of 3)"
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.serial' <<<"$output")" = "false" ]
    [ "$(jq -c '[.dispatchable[].pr]' <<<"$output")" = "[1,2,3]" ]
}

@test "REVIEW_FANOUT_SERIAL=1 declares serial without any API signal (#646)" {
    stub_gh_prs <<<"$(board_of 3)"
    export REVIEW_FANOUT_SERIAL=1
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.dispatchable[].pr]' <<<"$output")" = "[1]" ]
}

@test "REVIEW_FANOUT_SERIAL=0 overrides a strict ruleset (#646)" {
    stub_gh_prs <<<"$(board_of 3)"
    export GH_STRICT_RULESET=master REVIEW_FANOUT_SERIAL=0
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.dispatchable[].pr]' <<<"$output")" = "[1,2,3]" ]
}

# mixed_board -- PRs 1,3 target master, PRs 2,4 target release/1.0 (all unreviewed, an hour old).
mixed_board() {
    board_of 4 | jq '[.[] | .baseRefName = (if .number % 2 == 0 then "release/1.0" else "master" end)]'
}

@test "strict release branch + non-strict default: only the release PRs drain (#646)" {
    stub_gh_prs <<<"$(mixed_board)"
    export GH_STRICT_RULESET="release/1.0"
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.dispatchable[].pr]' <<<"$output")" = "[1,2,3]" ]
    [[ "$(reason_for 4)" == *"merges into release/1.0"*"#2 is next"* ]]
}

@test "strict default + non-strict release branch: only the default's PRs drain (#646)" {
    stub_gh_prs <<<"$(mixed_board)"
    export GH_STRICT_RULESET="master"
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.dispatchable[].pr]' <<<"$output")" = "[1,2,4]" ]
    [[ "$(reason_for 3)" == *"merges into master"*"#1 is next"* ]]
}

@test "strictness is read once per distinct base, not once per PR (#646)" {
    stub_gh_prs <<<"$(mixed_board)"
    run python3 "$PLANNER"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'rules/branches/master' "$GH_LOG")" -eq 1 ]
    [ "$(grep -c 'rules/branches/release/1.0' "$GH_LOG")" -eq 1 ]
}
