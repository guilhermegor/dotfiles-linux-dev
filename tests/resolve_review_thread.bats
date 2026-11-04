#!/usr/bin/env bats
# resolve_review_thread.sh: resolve only threads a human answered, by node id.
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
if [[ "$*" == *resolveReviewThread* ]]; then echo "${MUT:-true}"; exit 0; fi
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

# thread <isResolved> <author typename>...: the first author is the thread's root comment.
thread() {
    local resolved="$1"; shift
    READ_JSON=$(printf '%s\n' "$@" | jq -R '{author:{__typename:.}}' | jq -s \
        --argjson r "$resolved" '{data:{node:{isResolved:$r,comments:{nodes:.}}}}')
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

@test "a thread a human answered is resolved" {
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
    [[ "$output" == *"no non-bot reply"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a thread with only a bot reply is refused and never mutated" {
    thread false Bot Bot
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"no non-bot reply"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "a human-authored root comment does not count as its own reply" {
    thread false User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"no non-bot reply"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "an already-resolved thread is skipped" {
    thread true Bot User
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 0 ]
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
    [[ "$output" == *"no non-bot reply"* ]]
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
