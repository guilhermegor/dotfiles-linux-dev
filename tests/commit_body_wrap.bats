#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/commit_body_wrap.sh
#
# Focus: the shared matcher integration (dotfiles-linux-dev#324) — does the hook actually reflow the
# message file for all four `git commit` invocation shapes, and does it correctly leave a mere
# mention of "git commit" alone? The reflow mechanics themselves are exercised implicitly (a
# rewrite only happens when the matcher lets the hook past its early exit).
#
# Strategy: write a message file whose body has one line > 72 chars, run the hook with `-F
# <file>`, and check whether the file was rewritten (MATCH) or left untouched (MISS / no match).
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/commit_body_wrap.sh"
    TEST_TMP="$(mktemp -d)"
    MSG_FILE="$TEST_TMP/msg.txt"
}

teardown() {
    rm -rf "$TEST_TMP"
}

write_long_body() {
    cat > "$MSG_FILE" <<'MSG'
subject line

This single body line is deliberately long enough that it exceeds the seventy two character wrap limit and must be reflowed by the hook.
MSG
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

run_guard() {
    payload "$1" | "$GUARD"
}

# --- issue #324 table: all four invocation shapes -----------------------------------------------

@test "#324 row 1/4: reflows body for bare git commit -F <file>" {
    write_long_body
    run run_guard "git commit -F $MSG_FILE"
    [ "$status" -eq 0 ]
    run grep -c '.\{73,\}' "$MSG_FILE"
    [ "$output" -eq 0 ]
}

@test "#324 row 2/4: reflows body for rtk git commit -F <file>" {
    write_long_body
    run run_guard "rtk git commit -F $MSG_FILE"
    [ "$status" -eq 0 ]
    run grep -c '.\{73,\}' "$MSG_FILE"
    [ "$output" -eq 0 ]
}

@test "#324 row 3/4: reflows body for rtk proxy git commit -F <file> (was a MISS pre-#324)" {
    write_long_body
    run run_guard "rtk proxy git commit -F $MSG_FILE"
    [ "$status" -eq 0 ]
    run grep -c '.\{73,\}' "$MSG_FILE"
    [ "$output" -eq 0 ]
}

@test "#324 row 4/4: reflows body for git add -A && rtk proxy git commit -F <file> (was a MISS pre-#324)" {
    write_long_body
    run run_guard "git add -A && rtk proxy git commit -F $MSG_FILE"
    [ "$status" -eq 0 ]
    run grep -c '.\{73,\}' "$MSG_FILE"
    [ "$output" -eq 0 ]
}

@test "#324 false positive: a mere mention of 'git commit' in an argument leaves the file untouched" {
    write_long_body
    before="$(cat "$MSG_FILE")"
    run run_guard "gh pr create --body \"run git commit first\" -F $MSG_FILE"
    [ "$status" -eq 0 ]
    after="$(cat "$MSG_FILE")"
    [ "$before" = "$after" ]
}

# --- issue #961: inline -m bodies are blocked, and commits inside `bash <script>.sh` are seen ----
# 127 chars of two-letter words: over the 72 target, and wrappable (so not exempt as one token).

LONG_BODY="$(printf 'ab %.0s' $(seq 1 42))"

@test "#961: BLOCKS a multi -m commit whose body paragraph is over the limit" {
    run run_guard "git commit -m 'feat: x' -m '$LONG_BODY'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"126 chars"* ]]
    [[ "$output" == *"72"* ]]
}

@test "#961: BLOCKS a single -m whose own body lines (after the title) are over the limit" {
    run run_guard "git commit -m 'feat: x

$LONG_BODY'"
    [ "$status" -eq 2 ]
}

@test "#961: PASSES a multi -m commit with a short body" {
    run run_guard "git commit -m 'feat: x' -m 'short body line'"
    [ "$status" -eq 0 ]
}

@test "#961: a long TITLE alone is not a body problem (the title guard owns it)" {
    run run_guard "git commit -m '$LONG_BODY'"
    [ "$status" -eq 0 ]
}

@test "#961: PASSES an over-long single token (URL) in the body, which cannot be wrapped" {
    run run_guard "git commit -m 'feat: x' -m 'https://example.com/$(printf 'a%.0s' $(seq 1 90))'"
    [ "$status" -eq 0 ]
}

@test "#961: BLOCKS a long -m body inside bash <script>.sh" {
    printf 'git add -A\ngit commit -m "feat: x" -m "%s"\n' "$LONG_BODY" > "$TEST_TMP/c.sh"
    run run_guard "bash $TEST_TMP/c.sh"
    [ "$status" -eq 2 ]
}

@test "#961: PASSES a bash <script>.sh whose commit body is short" {
    printf 'git commit -m "feat: x" -m "short"\n' > "$TEST_TMP/c.sh"
    run run_guard "bash $TEST_TMP/c.sh"
    [ "$status" -eq 0 ]
}

@test "#961: PASSES (fails open) when the script is unreadable" {
    run run_guard "bash $TEST_TMP/does-not-exist.sh"
    [ "$status" -eq 0 ]
}

@test "#961: PASSES a -m body built from shell expansion (cannot be measured)" {
    run run_guard "git commit -m 'feat: x' -m \"\$(printf '%0100d' 0)\""
    [ "$status" -eq 0 ]
}
