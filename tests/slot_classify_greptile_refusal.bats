#!/usr/bin/env bats
#
# dotfiles-linux-dev#804: the hosted Greptile rung must treat a trial-credit refusal as
# "rung unavailable" -- log once, post no ask, fall through. Same stubbing pattern as
# greptile_rung.bats: no network, every forge read goes through the lib's override hooks.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
    CLASSIFY="$LIB/slot_classify.py"
    source "$LIB/reviewer_ladder.sh"
    HEAD_SHA='4117bcf7aa00aabbccdd'
    REFUSAL='`guilhermegor` has reached the 50-credit limit for trial accounts. To continue receiving code reviews, [upgrade your plan](https://app.greptile.com/review/github).'

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
    _fake_author() { echo "owner-login"; }
    export -f _fake_head _fake_comments _fake_reviews _fake_ask_post _claim_granted _fake_author
    export REVIEWER_LADDER_ASK_AUTHOR_CMD=_fake_author
    export REVIEWER_LADDER_HEAD_SHA_CMD=_fake_head
    export REVIEWER_LADDER_COMMENTS_CMD=_fake_comments
    export REVIEWER_LADDER_REVIEWS_CMD=_fake_reviews
    export REVIEWER_LADDER_ASK_POST_CMD=_fake_ask_post
    export REVIEWER_LADDER_CLAIM_CMD=_claim_granted
}

# put_review <login> <submitted_at> <body>: the PR's only review.
put_review() {
    jq -nc --arg l "$1" --arg t "$2" --arg b "$3" --arg h "$HEAD_SHA" \
        '[{user:{login:$l,type:"Bot"},state:"COMMENTED",submitted_at:$t,body:$b,commit_id:$h}]' \
        >"$BATS_TEST_TMPDIR/reviews.json"
}

@test "classifier: newest Greptile item being the refusal reads REFUSED (both login forms)" {
    put_review 'greptile-apps[bot]' 2026-10-17T10:00:00Z "$REFUSAL"
    run bash -c "jq -nc --slurpfile r '$BATS_TEST_TMPDIR/reviews.json' '{reviews:\$r[0],comments:[]}' | python3 '$CLASSIFY' greptile-refused"
    [ "$output" = "REFUSED" ]
    put_review 'greptile-apps' 2026-10-17T10:00:00Z "$REFUSAL"
    run bash -c "jq -nc --slurpfile r '$BATS_TEST_TMPDIR/reviews.json' '{reviews:\$r[0],comments:[]}' | python3 '$CLASSIFY' greptile-refused"
    [ "$output" = "REFUSED" ]
}

@test "classifier: a real review newer than the refusal reads OK" {
    run bash -c "echo '{\"reviews\":[
      {\"user\":{\"login\":\"greptile-apps[bot]\"},\"submitted_at\":\"2026-10-17T09:00:00Z\",\"body\":\"$REFUSAL\"},
      {\"user\":{\"login\":\"greptile-apps[bot]\"},\"submitted_at\":\"2026-10-17T11:00:00Z\",\"body\":\"<!-- greptile_summary -->\"}],
      \"comments\":[]}' | python3 '$CLASSIFY' greptile-refused"
    [ "$output" = "OK" ]
}

@test "classifier: a long real review quoting a refusal phrase reads OK (#832)" {
    put_review 'greptile-apps[bot]' 2026-10-17T10:00:00Z "<!-- greptile_summary --> $(printf 'x%.0s' {1..500}) your trial has ended"
    run bash -c "jq -nc --slurpfile r '$BATS_TEST_TMPDIR/reviews.json' '{reviews:\$r[0],comments:[]}' | python3 '$CLASSIFY' greptile-refused"
    [ "$output" = "OK" ]
}

@test "classifier: the real trial-ended notice reads REFUSED (#832)" {
    put_review 'greptile-apps[bot]' 2026-10-17T10:00:00Z 'Your trial has ended. [Reactivate Greptile](https://app.greptile.com/-/pull-requests) to resume code reviews.'
    run bash -c "jq -nc --slurpfile r '$BATS_TEST_TMPDIR/reviews.json' '{reviews:\$r[0],comments:[]}' | python3 '$CLASSIFY' greptile-refused"
    [ "$output" = "REFUSED" ]
}

@test "classifier: the refusal phrase from another login is ignored" {
    put_review coderabbitai[bot] 2026-10-17T10:00:00Z "$REFUSAL"
    run bash -c "jq -nc --slurpfile r '$BATS_TEST_TMPDIR/reviews.json' '{reviews:\$r[0],comments:[]}' | python3 '$CLASSIFY' greptile-refused"
    [ "$output" = "OK" ]
}

@test "ladder: a refusal review makes the rung unavailable -- one log line, no ask, falls through" {
    put_review 'greptile-apps[bot]' 2026-10-17T10:00:00Z "$REFUSAL"
    run run_hosted_rungs o r 7
    [ "$status" -eq 1 ]
    [[ "$output" == *"rung greptile skipped: trial credits exhausted"* ]]
    [[ "$output" != *"CONFIGURATION DEFECT"* ]]
    [ ! -s "$ASK_LOG" ]
}

@test "ladder: a real Greptile review newest still engages the rung (ask not suppressed)" {
    put_review 'greptile-apps[bot]' 2026-10-17T10:00:00Z '<!-- greptile_summary -->'
    run run_hosted_rungs o r 7
    [[ "$output" != *"trial credits exhausted"* ]]
}

@test "classifier: an unreadable phrase file fails closed to UNKNOWN, never OK" {
    run python3 -I -c "
import importlib.util, pathlib
s = importlib.util.spec_from_file_location('sc', '$CLASSIFY')
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.REFUSAL_PHRASES_FILE = pathlib.Path('/nonexistent/phrases.txt')
print(m.greptile_refused({'reviews': [], 'comments': []}))"
    [ "$output" = "UNKNOWN" ]
}

@test "ladder: a classifier that prints nothing skips the rung (fails closed)" {
    put_review 'greptile-apps[bot]' 2026-10-17T10:00:00Z '<!-- greptile_summary -->'
    LIB_DIR="$BATS_TEST_TMPDIR/emptylib"
    mkdir -p "$LIB_DIR"
    printf 'print()\n' >"$LIB_DIR/slot_classify.py"
    run run_hosted_rungs o r 7
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusal check unreadable"* ]]
    [ ! -s "$ASK_LOG" ]
}

@test "ladder: LADDER_SKIP_RUNGS=greptile skips the rung without any forge read or ask" {
    LADDER_SKIP_RUNGS="qwen greptile" run run_hosted_rungs o r 7
    [ "$status" -eq 1 ]
    [[ "$output" == *"rung greptile excluded earlier this run"* ]]
    [ ! -s "$ASK_LOG" ]
}
