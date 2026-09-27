#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/review_thread_gate.sh
#
# Scope: mostly `_gate_problems_filter`, the jq program that decides whether a review thread
# still needs a reply or a resolve, tested against fixtures rather than through
# gate_pr_thread_state() end to end. Two tests at the bottom (dotfiles-dev#398) close that last
# gap with a stubbed `gh`: gate_pr_thread_state() itself now has a contract test on both the
# success path (a usable, non-empty GATE_DETAIL) and the fail-closed path (unreadable after 3
# attempts, never `clean`) -- a regression in the retry loop or the roster-file wiring above the
# filters could otherwise ship with every filter test still green.
#
# Why this file exists: the filter aborted with `jq: error: Cannot index array with string
# "author"` (exit 5) whenever a roster file was present AND the PR had at least one thread. The
# workflow runs the gate under `set -euo pipefail`, so the step died before printing any verdict
# -- a required check failing with no diagnostic. It stayed invisible because every PR gated
# until dotfiles-dev#325 had zero threads, and `nodes[]` over an empty list never evaluates the
# body. A fixture with one thread is all it takes to catch it, which is what these tests are.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GATE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/review_thread_gate.sh"
    # A body long enough to count as substantive (the filter's --argjson min is 100 chars).
    LONG_BODY="$(printf 'x%.0s' {1..150})"
    # shellcheck source=ai_clients/claude/hooks/lib/review_thread_gate.sh
    source "$GATE"
    MARKER="$_gate_ladder_marker_re"
}

# thread_fixture <isResolved> <human-reply-body>
# One review thread: a bot comment, then a human reply of the given body.
thread_fixture() {
    jq -nc --argjson resolved "$1" --arg bot "$LONG_BODY" --arg human "$2" '{
      data: { repository: { pullRequest: { reviewThreads: {
        totalCount: 1,
        nodes: [ { isResolved: $resolved, path: "a.sh", comments: {
          totalCount: 2,
          nodes: [
            { author: { login: "coderabbitai", __typename: "Bot"  }, body: $bot   },
            { author: { login: "guilhermegor", __typename: "User" }, body: $human }
          ] } } ] } } } }
    }'
}

# run_filter <fixture-json> <roster>
run_filter() {
    run bash -c "source '$GATE'; printf '%s' '$1' \
        | jq -r --argjson min 100 --arg roster '$2' \"\$(_gate_problems_filter)\""
}

# ladder_comment_fixture <authorAssociation> <body> [reply_author] [reply_body]
# One PR-level (issue) comment carrying the ladder's attribution line, plus an optional later
# reply from a different author -- the shape gate_pr_thread_state's COMMENT channel reads
# (dotfiles-dev#490). Zero review threads, on purpose: the whole point is that the ladder's
# finding lives ONLY here.
ladder_comment_fixture() {
    jq -nc --arg assoc "$1" --arg body "$2" --arg reply_author "${3:-}" --arg reply_body "${4:-}" '
      ({author:{login:"ci-bot"}, authorAssociation:$assoc, body:$body,
        createdAt:"2026-09-21T20:12:22Z"}) as $lc
      | ([$lc] + (if $reply_author != "" then
          [{author:{login:$reply_author}, authorAssociation:"MEMBER", body:$reply_body,
            createdAt:"2026-09-23T00:00:00Z"}]
        else [] end)) as $nodes
      | { data: { repository: { pullRequest: {
          reviewThreads: { totalCount: 0, nodes: [] },
          comments: { totalCount: ($nodes | length), nodes: $nodes } } } } }
    '
}

# run_comment_filter <fixture-json>
run_comment_filter() {
    run bash -c "source '$GATE'; printf '%s' '$1' \
        | jq -r --argjson min 100 --arg marker '$MARKER' \"\$(_gate_comment_findings_filter)\""
}

# run_reported_filter <fixture-json> <roster>
run_reported_filter() {
    run bash -c "source '$GATE'; printf '%s' '$1' \
        | jq -r --arg roster '$2' --arg marker '$MARKER' \"\$(_gate_reported_filter)\""
}

# reviewed_fixture <reviews-json-array> <comments-json-array>
# The two channels _gate_reported_filter reads: submitted review objects and PR-level comments.
# Empty reviewThreads/commits on purpose -- this fixture is only ever fed to the reported filter.
# A report counts only if it is about the CURRENT head, so every fixture needs one. Reviews and
# comments that do not pin their own head default to matching it -- a test about ROSTER matching
# should not have to restate head identity, and a test about head staleness states it explicitly.
HEAD_OID="headoid0"
HEAD_DATE="2026-01-01T00:00:00Z"

reviewed_fixture() {
    jq -nc --argjson revs "$1" --argjson cmts "$2" \
           --arg oid "$HEAD_OID" --arg date "$HEAD_DATE" '
      { data: { repository: { pullRequest: {
          reviews: { totalCount: ($revs | length),
                     nodes: ($revs | map(
                       (if has("state") then . else . + {state:"COMMENTED"} end)
                       | (if has("commit") then . else . + {commit:{oid:$oid}} end))) },
          comments: { totalCount: ($cmts | length),
                      nodes: ($cmts | map(
                        if has("createdAt") then . else . + {createdAt:$date} end)) },
          commits: { nodes: [ { commit: { oid: $oid, committedDate: $date } } ] } } } } }
    '
}

# --- the regression: a roster + a thread used to abort the whole program ------------------------

@test "roster present, thread answered and resolved: silent, exit 0 (was jq exit 5)" {
    run_filter "$(thread_fixture true "$LONG_BODY")" "coderabbitai"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "roster present: does not abort with 'Cannot index array with string'" {
    # The precise failure mode. Asserted by name so a future rewrite that reintroduces
    # `$bots | index(.author.login)` fails here with an explanatory message.
    run_filter "$(thread_fixture false "$LONG_BODY")" "coderabbitai"
    [[ "$output" != *"Cannot index array"* ]]
    [ "$status" -eq 0 ]
}

# --- the verdicts themselves --------------------------------------------------------------------

@test "answered but unresolved: asks for a RESOLVE" {
    run_filter "$(thread_fixture false "$LONG_BODY")" "coderabbitai"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a.sh"* ]]
    [[ "$output" == *"RESOLVING"* ]]
}

@test "no substantive human reply: asks for a REPLY" {
    # "ok" is under the 100-char floor, so it does not count as an answer.
    run_filter "$(thread_fixture true "ok")" "coderabbitai"
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs a REPLY"* ]]
}

@test "a roster member's own comment never counts as the answer" {
    # Only the bot speaks, at length. Resolved or not, that is not somebody answering it.
    fixture="$(jq -nc --arg bot "$LONG_BODY" '{
      data: { repository: { pullRequest: { reviewThreads: {
        totalCount: 1,
        nodes: [ { isResolved: true, path: "a.sh", comments: {
          totalCount: 1,
          nodes: [ { author: { login: "coderabbitai", __typename: "Bot" }, body: $bot } ]
        } } ] } } } }
    }')"
    run_filter "$fixture" "coderabbitai"
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs a REPLY"* ]]
}

# --- the no-roster fallback, which takes the other branch entirely -------------------------------

@test "__NO_ROSTER__ falls back to __typename and still exits 0" {
    run_filter "$(thread_fixture true "$LONG_BODY")" "__NO_ROSTER__"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "__NO_ROSTER__: a Bot comment does not count as the answer" {
    fixture="$(jq -nc --arg bot "$LONG_BODY" '{
      data: { repository: { pullRequest: { reviewThreads: {
        totalCount: 1,
        nodes: [ { isResolved: true, path: "a.sh", comments: {
          totalCount: 1,
          nodes: [ { author: { login: "somebot", __typename: "Bot" }, body: $bot } ]
        } } ] } } } }
    }')"
    run_filter "$fixture" "__NO_ROSTER__"
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs a REPLY"* ]]
}

# --- no threads at all: the shape that hid the bug for its whole lifetime ------------------------

@test "zero threads: silent, exit 0 (this is why the bug went unseen)" {
    fixture='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]}}}}}'
    run_filter "$fixture" "coderabbitai"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- dotfiles-dev#331: an aborted filter must never reach the `clean` verdict -------------------
#
# `jq ... 2>/dev/null` with the status discarded turns a program ABORT into empty output, and
# empty output is what "nothing to report" looks like — so a crashed filter used to fall through
# to `clean`. That is a silent fail-OPEN on the gate that decides whether findings were answered.
# Measured on #329: the workflow's `set -euo pipefail` turned it into a bare `exit code 5`, while
# the two hook callers — neither uses `set -e` — got `clean` from the very same broken filter.

@test "#331: a filter that aborts yields unreadable, never clean" {
    run bash -c "
        source '$GATE'
        errfile=\"\$(mktemp)\"
        # '.a.b' over an ARRAY is an abort, not an empty match — the shape of the #329 bug.
        out=\"\$(_gate_run_jq '[1,2]' '.a.b' \"\$errfile\")\" || _gate_filter_aborted \"\$errfile\" 'thread'
        echo \"status=\${GATE_STATUS:-unset} detail=\${GATE_DETAIL:-}\"
    "
    [[ "$output" == *"status=unreadable"* ]]
    [[ "$output" != *"status=clean"* ]]
}

@test "#331: the unreadable detail carries jq's own error text" {
    run bash -c "
        source '$GATE'
        errfile=\"\$(mktemp)\"
        out=\"\$(_gate_run_jq '[1,2]' '.a.b' \"\$errfile\")\" || _gate_filter_aborted \"\$errfile\" 'thread'
        echo \"\$GATE_DETAIL\"
    "
    # Without this the failure is a bare exit code — #329 needed a bisect to find.
    [[ "$output" == *"Cannot index array"* ]]
    [[ "$output" == *"not clean"* ]]
}

@test "#331: a filter that legitimately matches nothing still succeeds" {
    # The other direction: an abort and an empty result must stay distinguishable.
    run bash -c "source '$GATE'; errfile=\"\$(mktemp)\"; _gate_run_jq '{\"a\":1}' 'empty' \"\$errfile\""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- the running filter: the same index() fault, found by extracting it ------------------------

@test "running filter: reports a reviewer check still pending (was an abort)" {
    fixture='{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":1,"nodes":[{"__typename":"StatusContext","context":"CodeRabbit","state":"PENDING","creator":{"login":"coderabbitai"}}]}}}}]}}}}}'
    run bash -c "source '$GATE'; printf '%s' '$fixture' | jq -r --arg roster 'coderabbitai' \"\$(_gate_running_filter)\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"CodeRabbit"* ]]
}

@test "running filter: ignores the repo's own completed CI" {
    fixture='{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":1,"nodes":[{"__typename":"CheckRun","name":"bats","status":"COMPLETED","checkSuite":{"app":{"slug":"github-actions"}}}]}}}}]}}}}}'
    run bash -c "source '$GATE'; printf '%s' '$fixture' | jq -r --arg roster 'coderabbitai' \"\$(_gate_running_filter)\""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "truncated filter: names a page that could not hold every thread" {
    fixture='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":3,"nodes":[{"isResolved":true,"path":"a.sh","comments":{"totalCount":9,"nodes":[]}}]}}}}}'
    run bash -c "source '$GATE'; printf '%s' '$fixture' | jq -r \"\$(_gate_truncated_filter)\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 review threads exist, only 1"* ]]
    [[ "$output" == *"9 comments, only 0 read"* ]]
}

@test "truncated filter: also names a dropped page of the COMMENT channel" {
    fixture='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":150,"nodes":[]}}}}}'
    run bash -c "source '$GATE'; printf '%s' '$fixture' | jq -r \"\$(_gate_truncated_filter)\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"150 PR comments exist, only 0"*"(comment channel)"* ]]
}

# --- the comment channel (dotfiles-dev#490): the reviewer ladder's fallback review posts as a
# plain PR comment, never a review thread -- run_fallback_review ends in _post_pr_comment, an
# ordinary issue comment. reviewThreads-only tests above cannot see it by construction: this is
# the exact blind spot that reported #453 "clean" while it carried an unanswered [P2] finding.

@test "comment channel: an unanswered ladder finding is not clean, and names the channel" {
    body=$'Fallback review — runtime: codex, model: gpt-5 (selected by: probe)\n\n## Findings\n\n- [P2] unhandled error path'
    run_comment_filter "$(ladder_comment_fixture MEMBER "$body")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unanswered ladder finding (comment channel)"* ]]
}

@test "comment channel: a substantive later reply from someone else clears it" {
    body=$'Fallback review — runtime: codex, model: gpt-5 (selected by: probe)\n\n## Findings\n\n- [P2] unhandled error path'
    run_comment_filter "$(ladder_comment_fixture MEMBER "$body" guilhermegor "$LONG_BODY")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "comment channel: a short, non-substantive reply does not count as answered" {
    body=$'Fallback review — runtime: codex, model: gpt-5 (selected by: probe)\n\n## Findings\n\n- [P2] unhandled error path'
    run_comment_filter "$(ladder_comment_fixture MEMBER "$body" guilhermegor "ok")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unanswered ladder finding (comment channel)"* ]]
}

@test "comment channel: a ladder review carrying no findings is clean" {
    body=$'Fallback review — runtime: codex, model: gpt-5 (selected by: probe)\n\nNo issues found in this diff.'
    run_comment_filter "$(ladder_comment_fixture MEMBER "$body")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "comment channel: a forged marker from a NONE-association commenter is ignored (CWE-345)" {
    # Any PR commenter can type the marker line -- this is the exact hole #455 closed for the
    # merge gate, lifted here. Only OWNER/MEMBER/COLLABORATOR is trusted.
    body=$'Fallback review — runtime: codex, model: gpt-5 (selected by: probe)\n\n## Findings\n\n- [P2] unhandled error path'
    run_comment_filter "$(ladder_comment_fixture NONE "$body")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "comment channel: an ordinary comment (no marker) is ignored" {
    run_comment_filter "$(ladder_comment_fixture MEMBER "just a normal comment, nothing to see")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- gate_pr_thread_state: the top-level contract, not just the filters it runs -------------------
# Every test above exercises one jq filter directly; none call gate_pr_thread_state() itself, so a
# regression in the retry loop, the roster-file wiring, or the final status assignment could ship
# with every filter test green (dotfiles-dev#398). These two close that gap: a usable, non-empty
# answer on success, and the deliberate fail-closed path once the API truly cannot be read.

@test "gate_pr_thread_state: success reports problems with a non-empty, parseable answer" {
    local fixture
    fixture="$(mktemp)"
    cat > "$fixture" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"nodes":[{"isResolved":false,"path":"b.sh","comments":{"totalCount":0,"nodes":[]}}]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}
JSON

    run env GH_FIXTURE="$fixture" GATE_LIB="$GATE" bash -c '
        gh() {
            case "$*" in
                *"-F owner=o -F repo=r -F number=5") cat "$GH_FIXTURE" ;;
                *) return 1 ;;
            esac
        }
        source "$GATE_LIB"
        gate_pr_thread_state o r 5
        echo "status=$GATE_STATUS"
        echo "detail=$GATE_DETAIL"
    '
    rm -f "$fixture"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=problems"* ]]
    [[ "$output" == *"b.sh"* ]]
    [[ "$output" == *"needs a REPLY"* ]]
}

@test "gate_pr_thread_state: unreachable API after 3 attempts fails closed, never clean" {
    run env GATE_LIB="$GATE" bash -c '
        sleep() { return 0; }
        gh() { return 1; }
        source "$GATE_LIB"
        gate_pr_thread_state o r 5
        echo "status=$GATE_STATUS"
        echo "detail=$GATE_DETAIL"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=unreadable"* ]]
    [[ "$output" != *"status=clean"* ]]
    [[ "$output" == *"after 3 attempts"* ]]
}

# --- dotfiles-dev#490: the exact defect, end to end -----------------------------------------------
#
# Measured 2026-09-23: the gate reported `clean` for every one of 16 open PRs while #440 carried
# an unanswered [P2] ladder finding, POSTED AS A PLAIN PR COMMENT -- zero review threads, so every
# filter above saw nothing to report. This fixture reproduces that exact shape: reviewThreads is
# empty (the "clean" shape by the OLD reading) and the ladder's unanswered finding lives only in
# the comment channel. Run against the pre-fix gate (no `comments` in _gate_query, no
# _gate_comment_findings_filter call) this reports `status=clean` -- the bug. Post-fix it must
# report `status=problems` and name the channel, never silently swallow the finding.
@test "gate_pr_thread_state: #490 regression -- ladder finding only in comments is not clean" {
    local fixture
    fixture="$(mktemp)"
    cat > "$fixture" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":1,"nodes":[{"author":{"login":"ci-bot"},"authorAssociation":"MEMBER","body":"Fallback review — runtime: codex, model: gpt-5 (selected by: probe)\n\n## Findings\n\n- [P2] unhandled error path","createdAt":"2026-09-21T20:12:22Z"}]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}
JSON

    run env GH_FIXTURE="$fixture" GATE_LIB="$GATE" bash -c '
        gh() {
            case "$*" in
                *"-F owner=o -F repo=r -F number=440") cat "$GH_FIXTURE" ;;
                *) return 1 ;;
            esac
        }
        source "$GATE_LIB"
        gate_pr_thread_state o r 440
        echo "status=$GATE_STATUS"
        echo "detail=$GATE_DETAIL"
    '
    rm -f "$fixture"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=problems"* ]]
    [[ "$output" == *"unanswered ladder finding (comment channel)"* ]]
}

# --- dotfiles-dev#505: a fourth state for "nobody has reviewed this at all" ----------------------
#
# Measured 2026-09-25 across the live open-PR board: #513, #514 and #517 carried zero threads and
# zero reviews (CI's own "Review threads answered" check-run: `No submitted review, and no
# verified reviewer completion marker.`) and gate_pr_thread_state reported `clean` for all three --
# indistinguishable from a PR a reviewer actually looked at and found nothing wrong with. `clean`
# must mean "reviewed, nothing to answer", never "nobody has spoken".

@test "_gate_reported_filter: no reviews, no comments -- not reported" {
    run_reported_filter "$(reviewed_fixture '[]' '[]')" "coderabbitai"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "_gate_reported_filter: a roster bot's submitted review counts as reported" {
    run_reported_filter "$(reviewed_fixture '[{"author":{"login":"coderabbitai","__typename":"Bot"}}]' '[]')" \
        "coderabbitai"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "_gate_reported_filter: derived from the ROSTER, not review count -- the PR author's own review does not count" {
    # Same shape as a submitted review, but the account is not on the roster -- #505's own warning.
    run_reported_filter "$(reviewed_fixture '[{"author":{"login":"guilhermegor","__typename":"User"}}]' '[]')" \
        "coderabbitai"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "_gate_reported_filter: a roster bot's completion comment counts as reported" {
    run_reported_filter "$(reviewed_fixture '[]' \
        '[{"author":{"login":"coderabbitai","__typename":"Bot"},"body":"CodeRabbit full review finished"}]')" \
        "coderabbitai"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "_gate_reported_filter: a verified ladder comment counts as reported even with no findings" {
    body=$'Fallback review — runtime: codex, model: gpt-5 (selected by: probe)\n\nNo issues found.'
    fixture="$(jq -nc --arg body "$body" '
      { data: { repository: { pullRequest: {
          reviews: { totalCount: 0, nodes: [] },
          comments: { totalCount: 1, nodes: [
            { author: { login: "guilhermegor" }, authorAssociation: "MEMBER", body: $body }
          ] } } } } }
    ')"
    run_reported_filter "$fixture" "coderabbitai"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "_gate_reported_filter: __NO_ROSTER__ falls back to any Bot account" {
    run_reported_filter "$(reviewed_fixture '[{"author":{"login":"somebot","__typename":"Bot"}}]' '[]')" \
        "__NO_ROSTER__"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "gate_pr_thread_state: zero threads, zero reviews, zero comments -- unreviewed, never clean" {
    local fixture
    fixture="$(mktemp)"
    cat > "$fixture" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"reviews":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}
JSON

    run env GH_FIXTURE="$fixture" GATE_LIB="$GATE" bash -c '
        gh() {
            case "$*" in
                *"-F owner=o -F repo=r -F number=513") cat "$GH_FIXTURE" ;;
                *) return 1 ;;
            esac
        }
        source "$GATE_LIB"
        gate_pr_thread_state o r 513 ".review-bots.yaml"
        echo "status=$GATE_STATUS"
    '
    rm -f "$fixture"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=unreviewed"* ]]
    [[ "$output" != *"status=clean"* ]]
}

@test "gate_pr_thread_state: zero threads, a roster review submitted -- clean" {
    local fixture
    fixture="$(mktemp)"
    cat > "$fixture" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"state":"COMMENTED","commit":{"oid":"deadbee"}}]},"commits":{"nodes":[{"commit":{"oid":"deadbee","committedDate":"2026-01-01T00:00:00Z","statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}
JSON

    run env GH_FIXTURE="$fixture" GATE_LIB="$GATE" bash -c '
        gh() {
            case "$*" in
                *"-F owner=o -F repo=r -F number=378") cat "$GH_FIXTURE" ;;
                *) return 1 ;;
            esac
        }
        source "$GATE_LIB"
        gate_pr_thread_state o r 378 ".review-bots.yaml"
        echo "status=$GATE_STATUS"
    '
    rm -f "$fixture"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=clean"* ]]
}

# --- dotfiles-dev#511: the comment-channel answer check used author INEQUALITY, which makes a
# ladder finding posted under the operator's own token structurally unanswerable -- the operator is
# also the only account that can reply to it. Measured, PR #511's own comment ids/timestamps:
# ladder finding 5830451560 (guilhermegor, 09:55:56Z), substantive answer 5830636642
# (guilhermegor, 10:09:02Z) -- CI still reported `unanswered ladder finding (comment channel)`
# with both CodeRabbit threads already resolved. The fix: comment IDENTITY (id) plus ordering
# (createdAt), never author identity, decide whether a later comment is a real answer.

@test "comment channel: a substantive later reply from the SAME author clears it (#511)" {
    fixture="$(jq -nc '
      { data: { repository: { pullRequest: { comments: { totalCount: 2, nodes: [
          { id: "IC_1", author: { login: "guilhermegor" }, authorAssociation: "OWNER",
            body: "Fallback review — runtime: codex, model: codex-auto-review (selected by: review-ladder)\n\n## Findings\n\n- [P2] unhandled error path",
            createdAt: "2026-09-25T09:55:56Z" },
          { id: "IC_2", author: { login: "guilhermegor" }, authorAssociation: "OWNER",
            body: "Fixed in 73672c0 (pushed to this branch). Verified independently — the finding holds and is resolved by this commit, re-checked the surrounding call sites for the same pattern.",
            createdAt: "2026-09-25T10:09:02Z" }
        ] } } } } }
    ')"
    run_comment_filter "$fixture"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "comment channel: the ladder comment never counts as its own answer (id equality, not author)" {
    # Same id twice would be nonsensical for a real API response, but this is what makes the
    # discriminator explicit: a comment can never answer itself, identity-first, ordering second.
    fixture="$(jq -nc '
      { data: { repository: { pullRequest: { comments: { totalCount: 1, nodes: [
          { id: "IC_1", author: { login: "guilhermegor" }, authorAssociation: "OWNER",
            body: "Fallback review — runtime: codex, model: codex-auto-review (selected by: review-ladder)\n\n## Findings\n\n- [P2] unhandled error path",
            createdAt: "2026-09-25T09:55:56Z" }
        ] } } } } }
    ')"
    run_comment_filter "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unanswered ladder finding (comment channel)"* ]]
}

# --- The three PR #520 findings: a report must be SUBMITTED, about the CURRENT head, and read
# --- from a complete page. Each asserts the fail-closed direction, which is the one that matters:
# --- reporting `clean` for a head nobody reviewed is the defect #505 exists to remove.

@test "_gate_reported_filter: a PENDING roster review is not a report" {
    run_reported_filter \
        "$(reviewed_fixture '[{"author":{"login":"coderabbitai","__typename":"Bot"},"state":"PENDING"}]' '[]')" \
        "coderabbitai"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "_gate_reported_filter: a roster review of an OLDER commit is not a report" {
    run_reported_filter \
        "$(reviewed_fixture '[{"author":{"login":"coderabbitai","__typename":"Bot"},"state":"COMMENTED","commit":{"oid":"stale123"}}]' '[]')" \
        "coderabbitai"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "_gate_reported_filter: a completion comment PREDATING the head is not a report" {
    run_reported_filter \
        "$(reviewed_fixture '[]' '[{"author":{"login":"coderabbitai","__typename":"Bot"},"body":"Full review finished","createdAt":"2025-01-01T00:00:00Z"}]')" \
        "coderabbitai"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "truncated: reviews that do not fit one page report UNREADABLE, never 'no reviewer'" {
    local fixture
    fixture="$(mktemp)"
    cat > "$fixture" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"reviews":{"totalCount":250,"nodes":[{"author":{"login":"someone","__typename":"User"},"state":"COMMENTED","commit":{"oid":"x"}}]},"commits":{"nodes":[{"commit":{"oid":"x","committedDate":"2026-01-01T00:00:00Z","statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}
JSON

    run env GH_FIXTURE="$fixture" GATE_LIB="$GATE" bash -c '
        gh() {
            case "$*" in
                *"-F owner=o -F repo=r -F number=378") cat "$GH_FIXTURE" ;;
                *) return 1 ;;
            esac
        }
        source "$GATE_LIB"
        gate_pr_thread_state o r 378 ".review-bots.yaml"
        echo "status=$GATE_STATUS"
        echo "detail=$GATE_DETAIL"
    '
    rm -f "$fixture"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=problems"* ]]
    [[ "$output" == *"250 reviews exist"* ]]
}

@test "comment channel: a LATER ladder review never answers an earlier ladder finding" {
    # Excluding only the finding's own id let the next fallback review clear it: distinct id,
    # later timestamp, easily over the length floor. A review is a report, not an answer.
    local first second
    first=$'Fallback review — runtime: codex, model: gpt-5 (selected by: probe)\n\n## Findings\n\n- [P2] unhandled error path'
    second=$'Fallback review — runtime: qwen, model: qwen3 (selected by: probe)\n\n## Findings\n\nNo issues found in this pass, everything below the threshold was ignored deliberately.'
    run_comment_filter "$(ladder_comment_fixture MEMBER "$first" guilhermegor "$second")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unanswered ladder finding (comment channel)"* ]]
}
