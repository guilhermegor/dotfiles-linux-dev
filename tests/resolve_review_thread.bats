#!/usr/bin/env bats
# resolve_review_thread.sh: resolve only ANSWERED review threads, by node id.
# `gh` is stubbed on PATH; no network. The read prints "$READ" (default "false 2"),
# READ_FAIL makes it fail, and the mutation prints "$MUT" (default "true").

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
echo "${READ:-false 2}"
STUB
    chmod +x "$BIN/gh"
    export PATH="$BIN:$PATH" GH_LOG
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

@test "an answered thread is resolved" {
    run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 0 ]
    [[ "$output" == *"PRRT_abc123: resolved"* ]]
    grep -q resolveReviewThread "$GH_LOG"
}

@test "a thread with no reply is refused and never mutated" {
    READ="false 1" run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"no reply"* ]]
    run grep -q resolveReviewThread "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "an already-resolved thread is skipped" {
    READ="true 3" run bash "$SCRIPT" PRRT_abc123
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

@test "a mutation that does not report resolved is a failure" {
    MUT="null" run bash "$SCRIPT" PRRT_abc123
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED"* ]]
}
