#!/usr/bin/env bats
#
# Hosted Greptile rung (dotfiles-linux-dev#713): slot_classify.py's `greptile` and
# `greptile-unsolicited` modes, and reviewer_ladder.sh's run_hosted_rungs.
# Fixture-driven: no network; every forge read, the ask post and the shared
# claim_review_ask are stubbed through the lib's own override hooks.
#
# Greptile's allowance-exhausted notice has never been observed, so the classifier
# fails CLOSED: any greptile issue comment that is not one of the two measured review
# shapes reads BUSY until a known review lands after it.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
    CLASSIFY="$LIB/slot_classify.py"
    source "$LIB/reviewer_ladder.sh"
    NOW_EPOCH="$(date -u +%s)"
    HEAD_SHA='4117bcf7aa00aabbccdd'

    export REVIEWER_LADDER_BASE_FETCH_CMD=true
    ASK_LOG="$BATS_TEST_TMPDIR/ask.log"
    : >"$ASK_LOG"
    echo '[]' >"$BATS_TEST_TMPDIR/comments.json"
    echo '[]' >"$BATS_TEST_TMPDIR/reviews.json"
    export ASK_LOG HEAD_SHA BATS_TEST_TMPDIR
    _fake_head() { echo "$HEAD_SHA"; }
    _fake_comments() { cat "$BATS_TEST_TMPDIR/comments.json"; }
    _fake_reviews() { cat "$BATS_TEST_TMPDIR/reviews.json"; }
    _fake_ask_post() { printf '%s\n---\n' "$4" >>"$ASK_LOG"; }
    _claim_granted() { echo GRANTED; }
    _claim_busy() { echo BUSY; return 1; }
    export -f _fake_head _fake_comments _fake_reviews _fake_ask_post _claim_granted _claim_busy
    _fake_author() { echo "owner-login"; }
    _no_author() { return 1; }
    export -f _fake_author _no_author
    export REVIEWER_LADDER_ASK_AUTHOR_CMD=_fake_author
    export REVIEWER_LADDER_HEAD_SHA_CMD=_fake_head
    export REVIEWER_LADDER_COMMENTS_CMD=_fake_comments
    export REVIEWER_LADDER_REVIEWS_CMD=_fake_reviews
    export REVIEWER_LADDER_ASK_POST_CMD=_fake_ask_post
    export REVIEWER_LADDER_CLAIM_CMD=_claim_granted
}

ts() {
    date -u -d "@$((NOW_EPOCH - $1 * 60))" +%Y-%m-%dT%H:%M:%SZ
}

# --- slot_classify.py greptile -------------------------------------------------

@test "classify: an empty page is FREE" {
    run bash -c "printf '[]' | python3 '$CLASSIFY' greptile"
    [ "$status" -eq 0 ]
    [ "$output" = "FREE|no-greptile-comment-on-this-page" ]
}

@test "classify: only measured review comments is FREE" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY' greptile
[
  {\"user\": {\"login\": \"greptile-apps[bot]\"}, \"created_at\": \"$(ts 5)\",
   \"body\": \"<!-- greptile_summary -->\\n<h2>Confidence Score: 4/5</h2>\"},
  {\"user\": {\"login\": \"greptile-apps[bot]\"}, \"created_at\": \"$(ts 4)\",
   \"body\": \"<!-- greptile_outside_diff -->\\n<h3>Comments Outside Diff</h3>\"}
]
JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "FREE|only-known-review-comments" ]
}

@test "classify: an unrecognised notice is BUSY, never FREE" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY' greptile
[
  {\"user\": {\"login\": \"greptile-apps[bot]\"}, \"created_at\": \"$(ts 5)\",
   \"body\": \"You have used all of your review credits this month.\"}
]
JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "BUSY|unrecognised-greptile-notice" ]
}

@test "classify: a known review newer than the notice clears it" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY' greptile
[
  {\"user\": {\"login\": \"greptile-apps[bot]\"}, \"created_at\": \"$(ts 9)\", \"body\": \"credits exhausted\"},
  {\"user\": {\"login\": \"greptile-apps[bot]\"}, \"created_at\": \"$(ts 2)\",
   \"body\": \"<!-- greptile_summary -->\"}
]
JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == FREE\|* ]]
}

@test "classify: another bot's notice does not make the greptile slot BUSY" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY' greptile
[
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 2)\", \"body\": \"Rate limit exceeded\"}
]
JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == FREE\|* ]]
}

@test "classify: a GraphQL-shaped page and a forge error body are UNKNOWN" {
    run bash -c "printf '[{\"author\":{\"login\":\"x\"},\"createdAt\":\"t\"}]' | python3 '$CLASSIFY' greptile"
    [ "$output" = "UNKNOWN" ]
    run bash -c "printf '{\"message\":\"rate limited\"}' | python3 '$CLASSIFY' greptile"
    [ "$output" = "UNKNOWN" ]
}

@test "classify: the default (coderabbit) mode is unchanged by the new modes" {
    run bash -c "printf '[]' | python3 '$CLASSIFY'"
    [ "$output" = "FREE|no-notice-on-this-page" ]
}

@test "unsolicited: a review on an asked head is OK, on any other head is reported" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY' greptile-unsolicited
{\"ask_author\": \"owner\", \"comments\": [{\"user\": {\"login\": \"owner\"}, \"body\": \"@greptileai review\\n\\n<!-- ladder-ask:greptile head=aaaaaaaaaaaa1111 -->\"}],
 \"reviews\": [{\"user\": {\"login\": \"greptile-apps[bot]\"}, \"commit_id\": \"aaaaaaaaaaaa1111\"}]}
JSON"
    [ "$output" = "OK" ]
    run bash -c "cat <<JSON | python3 '$CLASSIFY' greptile-unsolicited
{\"ask_author\": \"owner\", \"comments\": [{\"user\": {\"login\": \"owner\"}, \"body\": \"<!-- ladder-ask:greptile head=aaaaaaaaaaaa1111 -->\"}],
 \"reviews\": [{\"user\": {\"login\": \"greptile-apps[bot]\"}, \"commit_id\": \"bbbbbbbbbbbb2222\"},
               {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"commit_id\": \"cccccccccccc3333\"}]}
JSON"
    [ "$output" = "UNSOLICITED|bbbbbbbbbbbb" ]
}

# --- reviewer_ladder.sh run_hosted_rungs ---------------------------------------

@test "hosted: a free slot with a granted claim posts one ask carrying the head marker" {
    run run_hosted_rungs o r 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"requested, verdict pending"* ]]
    [ "$(grep -c '@greptileai review' "$ASK_LOG")" -eq 1 ]
    grep -q "ladder-ask:greptile head=$HEAD_SHA" "$ASK_LOG"
}

@test "hosted: a spent ask budget falls through and posts nothing" {
    export REVIEWER_LADDER_CLAIM_CMD=_claim_busy
    run run_hosted_rungs o r 7
    [ "$status" -eq 1 ]
    [ ! -s "$ASK_LOG" ]
}

@test "hosted: an unrecognised greptile notice reads BUSY and falls through unasked" {
    echo '[{"user":{"login":"greptile-apps[bot]"},"created_at":"2026-10-11T10:00:00Z","body":"out of credits"}]' \
        >"$BATS_TEST_TMPDIR/comments.json"
    run run_hosted_rungs o r 7
    [ "$status" -eq 1 ]
    [[ "$output" == *"BUSY"* ]]
    [ ! -s "$ASK_LOG" ]
}

@test "hosted: an ask already posted for this head is pending, not re-asked" {
    echo "[{\"user\":{\"login\":\"owner-login\"},\"created_at\":\"2026-10-11T10:00:00Z\",\"body\":\"<!-- ladder-ask:greptile head=$HEAD_SHA -->\"}]" \
        >"$BATS_TEST_TMPDIR/comments.json"
    run run_hosted_rungs o r 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"already posted"* ]]
    [ ! -s "$ASK_LOG" ]
}

@test "spoof: a non-ladder account typing the ask marker does not suppress the ask" {
    echo "[{\"user\":{\"login\":\"mallory\"},\"created_at\":\"2026-10-11T10:00:00Z\",\"body\":\"<!-- ladder-ask:greptile head=$HEAD_SHA -->\"}]" \
        >"$BATS_TEST_TMPDIR/comments.json"
    run run_hosted_rungs o r 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"requested, verdict pending"* ]]
    [ "$(grep -c '@greptileai review' "$ASK_LOG")" -eq 1 ]
}

@test "spoof: an unknown ask identity credits no marker (fail closed)" {
    export REVIEWER_LADDER_ASK_AUTHOR_CMD=_no_author
    echo "[{\"user\":{\"login\":\"owner-login\"},\"created_at\":\"2026-10-11T10:00:00Z\",\"body\":\"<!-- ladder-ask:greptile head=$HEAD_SHA -->\"}]" \
        >"$BATS_TEST_TMPDIR/comments.json"
    run run_hosted_rungs o r 7
    [[ "$output" != *"already posted"* ]]
}

@test "spoof: a forged ask marker does not hide an unsolicited review" {
    echo '[{"user":{"login":"greptile-apps[bot]"},"commit_id":"deadbeefcafe0000"}]' >"$BATS_TEST_TMPDIR/reviews.json"
    echo '[{"user":{"login":"mallory"},"created_at":"2026-10-11T10:00:00Z","body":"<!-- ladder-ask:greptile head=deadbeefcafe0000 -->"}]' \
        >"$BATS_TEST_TMPDIR/comments.json"
    run run_hosted_rungs o r 7
    [[ "$output" == *"CONFIGURATION DEFECT"* ]]
}

@test "spoof: a human whose login merely contains greptile cannot clear a BUSY slot" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY' greptile
[
  {\"user\": {\"login\": \"greptile-apps[bot]\", \"type\": \"Bot\"}, \"created_at\": \"$(ts 9)\", \"body\": \"credits exhausted\"},
  {\"user\": {\"login\": \"not-greptile-apps\", \"type\": \"User\"}, \"created_at\": \"$(ts 2)\",
   \"body\": \"<!-- greptile_summary -->\"}
]
JSON"
    [ "$output" = "BUSY|unrecognised-greptile-notice" ]
}

@test "spoof: the exact bot login with a non-Bot type is ignored" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY' greptile
[
  {\"user\": {\"login\": \"greptile-apps[bot]\", \"type\": \"User\"}, \"created_at\": \"$(ts 2)\", \"body\": \"credits exhausted\"}
]
JSON"
    [[ "$output" == FREE\|* ]]
}

@test "spoof: a human quoting a notice cannot force the greptile slot BUSY" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY' greptile
[
  {\"user\": {\"login\": \"mallory\", \"type\": \"User\"}, \"created_at\": \"$(ts 2)\", \"body\": \"credits exhausted\"}
]
JSON"
    [[ "$output" == FREE\|* ]]
}

@test "hosted: a greptile review on a head never asked about is a configuration defect" {
    echo '[{"user":{"login":"greptile-apps[bot]"},"commit_id":"deadbeefcafe0000"}]' >"$BATS_TEST_TMPDIR/reviews.json"
    run run_hosted_rungs o r 7
    [[ "$output" == *"CONFIGURATION DEFECT"* ]]
    [[ "$output" == *"deadbeefcafe"* ]]
}

@test "hosted: unreadable comments fail closed into fall-through" {
    _no_comments() { return 1; }
    export -f _no_comments
    export REVIEWER_LADDER_COMMENTS_CMD=_no_comments
    run run_hosted_rungs o r 7
    [ "$status" -eq 1 ]
    [ ! -s "$ASK_LOG" ]
}
