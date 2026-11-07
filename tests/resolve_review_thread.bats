#!/usr/bin/env bats
# resolve_review_thread.sh: resolve only threads the viewer answered, by node id.
# `gh` is stubbed on PATH; no network. The stub applies the script's real --jq filter to
# the thread JSON in $READ_JSON (build it with `thread`), so the bot filter is exercised.
# READ_RAW prints verbatim instead, READ_FAIL fails the read, and the mutation prints
# "$MUT" (default "true").

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/resolve_review_thread.sh"
    BIN="$BATS_TEST_TMPDIR/bin"
    GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    mkdir -p "$BIN"
    : > "$GH_LOG"
    cat > "$BIN/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
if [[ "$*" == *resolveReviewThread* ]]; then
[ -n "${MUT_FAIL:-}" ] && { echo "boom" >&2; exit 1; }
echo "${MUT:-true}"; exit 0
fi
[ -n "${READ_FAIL:-}" ] && { echo "rate limited" >&2; exit 1; }
[ -n "${READ_RAW:-}" ] && { echo "$READ_RAW"; exit 0; }
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--jq" ]; then jq -r "$2" <<<"$READ_JSON"; exit; fi
    shift
done
exit 1
STUB
    chmod +x "$BIN/gh"
    export PATH="$BIN:$PATH" GH_LOG
}

# thread <isResolved> <kind>...: the first kind is the thread's root comment. Kinds: Bot,
# User (the viewer, "me"), Other (another human), Null (deleted account),
# Pending (viewer, unsubmitted), Notice (CodeRabbit's chat rate-limit notice), FakeNotice
# (the same text from another bot), Edited (CodeRabbit with the notice text plus more).
thread() {
    local resolved="$1"; shift
    READ_JSON=$(printf '%s\n' "$@" | jq -R '
        ("<!-- coderabbit-ai-generated:v1 -->\n\n### Rate Limit Exceeded\n\n`@me` have exceeded the limit for the number of chat messages per hour. Please wait **0 minutes and 48 seconds** before sending another message.\n\n<!-- This is an auto-generated reply by CodeRabbit -->\n") as $notice
        | {state:(if .=="Pending" then "PENDING" else "SUBMITTED" end),
         body:(if .=="Notice" or .=="FakeNotice" or .=="UserNotice" then $notice
               elif .=="MultilineNotice" then ($notice | sub("0 minutes and 48 seconds"; "1 minute\n\nInjected text"))
               elif .=="Edited" then $notice + "Also: this finding is wrong." else "x" end),
         author:(if .=="Null" then null
                 elif .=="Notice" or .=="Edited" or .=="MultilineNotice" then {__typename:"Bot",login:"coderabbitai"}
                 elif .=="UserNotice" then {__typename:"User",login:"coderabbitai"}
                 elif .=="FakeNotice" then {__typename:"Bot",login:"other-bot"}
                 elif .=="Bot" then {__typename:"Bot",login:"bot"}
                 elif .=="Other" then {__typename:"User",login:"other"}
                 else {__typename:"User",login:"me"} end)}' | jq -s \
        --argjson r "$resolved" \
        --arg o "${PR_OWNER-me}" --arg a "${PR_AUTHOR-me}" \
        '{data:{viewer:{login:"me"},node:{isResolved:$r,
          pullRequest:{author:(if $a=="null" then null else {login:$a} end),
                       repository:{owner:(if $o=="null" then null else {login:$o} end)}},
          comments:{nodes:.}}}}')
    export READ_JSON
}

@test "no arguments is a usage error" {
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
}

@test "a non-thread id or a flag is refused without calling gh" {
    run bash "$SCRIPT" --admin
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSED"* ]]
    [ ! -s "$GH_LOG" ]
}

@test "near-miss ids are refused without calling gh" {
    run bash "$SCRIPT" PR_kwDOabc "PRRT_abc;x" PRRT_
    [ "$status" -eq 1 ]
    [ ! -s "$GH_LOG" ]
}

@test "a thread the viewer answered is resolved" {
    thread false Bot User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 0 ]
    [[ "$output" == *"PRRT_abc123: resolved"* ]]
    grep -q resolveReviewThread "$GH_LOG"
}

@test "a thread with no reply is refused and never mutated" {
    thread false Bot
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"not your submitted reply"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a thread with only a bot reply is refused and never mutated" {
    thread false Bot Bot
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"not your submitted reply"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a human-authored root comment does not count as its own reply" {
    thread false User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"not your submitted reply"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "an already-resolved thread is skipped" {
    thread true Bot User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 0 ]
    [[ "$output" == *"already resolved"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a failed read fails closed" {
    READ_FAIL=1 run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"UNKNOWN"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "an unparseable read fails closed" {
    READ_RAW="false null" run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"unexpected read"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a mutation that does not report resolved is a failure" {
    thread false Bot User
    MUT="null" run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED"* ]]
}

@test "a bot re-opening after a human reply is refused" {
    thread false Bot User Bot
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"not your submitted reply"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a missing node (wrong type or deleted id) fails closed" {
    READ_JSON='{"data":{"node":null}}' run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"UNKNOWN"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a bad id among valid ones does not stop the rest, and rc stays 1" {
    thread false Bot User
    run bash "$SCRIPT" --admin PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"PRRT_abc123: resolved"* ]]
}

@test "a human reviewer's follow-up after the agent reply is refused" {
    thread false Other User Other
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a reply by another human is refused" {
    thread false Bot Other
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "an unsubmitted pending reply is refused" {
    thread false Bot Pending
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a deleted-account last comment fails closed" {
    thread false Bot Null
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a mutation that exits non-zero is a failure" {
    thread false Bot User
    MUT_FAIL=1 run bash "$SCRIPT"  PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED"* ]]
}

@test "a viewer-started thread with a viewer reply is resolved" {
    thread false User User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 0 ]
}

refute_mutation() {
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a thread on a foreign repository is refused and never mutated" {
    PR_OWNER=someone-else thread false Bot User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"not on your own PR"* ]]
    refute_mutation
}

@test "a thread on a PR the viewer did not author is refused and never mutated" {
    PR_AUTHOR=someone-else thread false Bot User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"not on your own PR"* ]]
    refute_mutation
}

@test "an already-resolved thread on a foreign PR is refused, not reported resolved" {
    PR_OWNER=someone-else thread true Bot User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"not on your own PR"* ]]
    [[ "$output" != *"already resolved"* ]]
    refute_mutation
}

@test "a null PR owner fails closed" {
    PR_OWNER=null thread false Bot User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    refute_mutation
}

@test "a null PR author fails closed" {
    PR_AUTHOR=null thread false Bot User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    refute_mutation
}

@test "owner and author match case-insensitively" {
    PR_OWNER=ME PR_AUTHOR=Me thread false Bot User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 0 ]
    grep -q resolveReviewThread "$GH_LOG"
}

@test "an answer followed by CodeRabbit's rate-limit notice is resolved" {
    thread false Bot User Notice
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 0 ]
    [[ "$output" == *"PRRT_abc123: resolved"* ]]
    grep -q resolveReviewThread "$GH_LOG"
}

@test "several trailing rate-limit notices are all skipped" {
    thread false Bot User Notice Notice
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 0 ]
}

@test "an answer followed by a substantive CodeRabbit reply is refused" {
    thread false Bot User Bot
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    refute_mutation
}

@test "a notice plus extra text is a substantive reply and is refused" {
    thread false Bot User Edited
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    refute_mutation
}

@test "the notice text from another bot is not skipped" {
    thread false Bot User FakeNotice
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    refute_mutation
}

@test "a notice with no answer before it is refused" {
    thread false Bot Notice
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    refute_mutation
}

@test "a substantive reply before a notice is still refused" {
    thread false Bot User Bot Notice
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    refute_mutation
}

@test "a notice with a multi-line wait slot is not skipped" {
    thread false Bot User MultilineNotice
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    refute_mutation
}

@test "the notice text from a non-Bot account named coderabbitai is not skipped" {
    thread false Bot User UserNotice
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    refute_mutation
}
