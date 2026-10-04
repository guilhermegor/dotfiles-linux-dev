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
