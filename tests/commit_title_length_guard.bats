#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/commit_title_length_guard.sh
#
# Strategy (same as protected_branch_guard.bats):
#   - The hook is a pure stdin->exit-code filter: it reads a PreToolUse JSON payload on stdin and
#     exits 0 (allow) or 2 (block). Every test is "feed a payload, assert the exit code".
#   - `read_title_max_length()` resolves the limit from the repo's `.gitlint`, so each test runs
#     inside a throwaway repo (no `.gitlint` present → the 72-char default applies).
#   - `payload <cmd>` builds the harness JSON; `run_guard <cmd>` pipes it through the guard so the
#     pipe's exit status IS the guard's.
#
# These tests pin issue #140: the guard fails open on the heredoc form agents actually use
# (`-F- <<'MSG' ... MSG`) because a heredoc `<<` was blanket fail-open, and gitlint's T1 catches
# the too-long title instead — after the whole pre-commit gate has already run.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/commit_title_length_guard.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP"
    git init -q -b main .
    git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init
}

teardown() {
    rm -rf "$TEST_TMP"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

# Pipe the payload through the guard; the pipe's status is the guard's exit code.
run_guard() {
    payload "$1" | "$GUARD"
}

# --- issue #140: the heredoc-fed -F- form, unparsed before the fix -----------------------------

@test "BLOCKS a 75-char title via -F- fed by a quoted heredoc (would fail open pre-#140)" {
    cmd="$(cat <<'CMD'
rtk git commit -F- <<'MSG'
docs(backlog): every zero-review notice fails, including the successful one

body text
MSG
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 2 ]
    [[ "$output" == *"75 characters"* ]]
}

@test "PASSES a 71-char title via -F- fed by a quoted heredoc" {
    cmd="$(cat <<'CMD'
rtk git commit -F- <<'MSG'
docs(backlog): every zero-review notice fails, incl the successful one

body text
MSG
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

@test "BLOCKS via -F- fed by an unquoted heredoc delimiter" {
    cmd="$(cat <<'CMD'
git commit -F- <<MSG
docs(backlog): every zero-review notice fails, including the successful one
MSG
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 2 ]
}

@test "BLOCKS via --file=- fed by a heredoc" {
    cmd="$(cat <<'CMD'
git commit --file=- <<'MSG'
docs(backlog): every zero-review notice fails, including the successful one
MSG
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 2 ]
}

@test "PASSES a short title via -F- fed by a heredoc" {
    cmd="$(cat <<'CMD'
git commit -F- <<'MSG'
fix: short title
MSG
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

# --- fail-open controls preserved ---------------------------------------------------------------

@test "still fails open on -F path/to/file (title genuinely not in the payload)" {
    run run_guard "git commit -F /tmp/msg.txt"
    [ "$status" -eq 0 ]
}

@test "still fails open on --file path/to/file (title genuinely not in the payload)" {
    run run_guard "git commit --file /tmp/msg.txt"
    [ "$status" -eq 0 ]
}

@test "still fails open on a heredoc that does not feed -F-" {
    cmd="$(cat <<'CMD'
cat <<'EOF' > notes.md
some notes about a very long line that would exceed the title length limit easily
EOF
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

@test "fails open when -F- heredoc coexists with an -m (ambiguous source)" {
    cmd="$(cat <<'CMD'
git commit -m wip -F- <<'MSG'
docs(backlog): every zero-review notice fails, including the successful one
MSG
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

@test "fails open when more than one heredoc is present" {
    cmd="$(cat <<'CMD'
git commit -F- <<'MSG'
docs(backlog): every zero-review notice fails, including the successful one
MSG
cat <<'EOF' > notes.md
extra
EOF
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

@test "fails open on a heredoc title containing \$(...) shell expansion" {
    cmd="$(cat <<'CMD'
git commit -F- <<'MSG'
docs: $(date) some title text that is not measured statically here at all
MSG
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

# --- the existing -m tests still pass unchanged --------------------------------------------------

@test "BLOCKS a too-long -m title" {
    run run_guard 'git commit -m "docs(backlog): every zero-review notice fails, including the successful one"'
    [ "$status" -eq 2 ]
}

@test "PASSES a short -m title" {
    run run_guard "git commit -m wip"
    [ "$status" -eq 0 ]
}

@test "fails open on an -m title containing \$(...) shell expansion" {
    run run_guard 'git commit -m "$(printf x)"'
    [ "$status" -eq 0 ]
}

@test "PASSES more than one -m when the first (title) -m is short" {
    run run_guard 'git commit -m title -m body'
    [ "$status" -eq 0 ]
}

# --- issue #961: multi -m, -am cluster, and commits inside bash <script>.sh ---------------------

LONG_TITLE="docs(backlog): every zero-review notice fails, including the successful one"

@test "#961: BLOCKS a long FIRST -m even when more -m follow" {
    run run_guard "git commit -m '$LONG_TITLE' -m 'body'"
    [ "$status" -eq 2 ]
}

@test "#961: BLOCKS a long title in a -am cluster" {
    run run_guard "git commit -am '$LONG_TITLE'"
    [ "$status" -eq 2 ]
}

@test "#961: a long SECOND -m is a body, not a title" {
    run run_guard "git commit -m 'feat: x' -m '$LONG_TITLE'"
    [ "$status" -eq 0 ]
}

@test "#961: BLOCKS a long title inside bash <script>.sh" {
    printf 'git add -A\ngit commit -m "%s" -m "body"\n' "$LONG_TITLE" > "$TEST_TMP/c.sh"
    run run_guard "bash $TEST_TMP/c.sh"
    [ "$status" -eq 2 ]
}

@test "#961: BLOCKS the long commit when a script holds a short one first" {
    printf 'git commit -m "feat: x"\ngit commit -m "%s"\n' "$LONG_TITLE" > "$TEST_TMP/c.sh"
    run run_guard "sh -e $TEST_TMP/c.sh"
    [ "$status" -eq 2 ]
}

@test "#961: PASSES a script whose commit title is short" {
    printf 'git commit -m "feat: x" -m "body"\n' > "$TEST_TMP/c.sh"
    run run_guard "bash $TEST_TMP/c.sh"
    [ "$status" -eq 0 ]
}

@test "#961: PASSES (fails open) when the script is unreadable" {
    run run_guard "bash $TEST_TMP/does-not-exist.sh"
    [ "$status" -eq 0 ]
}

@test "#961: a script that merely mentions git commit in an echo is not a commit" {
    printf 'echo "run git commit -m %s"\n' "$LONG_TITLE" > "$TEST_TMP/c.sh"
    run run_guard "bash $TEST_TMP/c.sh"
    [ "$status" -eq 0 ]
}

@test "allows editor-mode commit with no inline message" {
    run run_guard "git commit --amend --no-edit"
    [ "$status" -eq 0 ]
}

@test "ignores non-Bash tools" {
    run bash -c "jq -nc '{tool_name: \"Read\", tool_input: {command: \"git commit -m wip\"}}' | '$GUARD'"
    [ "$status" -eq 0 ]
}

# --- issue #324 table: all four invocation shapes, with an over-limit -m title ------------------
# (78 chars > 72 default), so a MATCH shows up as BLOCKED (exit 2) and a MISS as ALLOWED (exit 0).

TOO_LONG_TITLE='docs(backlog): every zero-review notice fails, including the successful one!'

@test "#324 row 1/4: BLOCKS bare git commit" {
    run run_guard "git commit -m \"$TOO_LONG_TITLE\""
    [ "$status" -eq 2 ]
}

@test "#324 row 2/4: BLOCKS rtk git commit" {
    run run_guard "rtk git commit -m \"$TOO_LONG_TITLE\""
    [ "$status" -eq 2 ]
}

@test "#324 row 3/4: BLOCKS rtk proxy git commit (was a MISS pre-#324)" {
    run run_guard "rtk proxy git commit -m \"$TOO_LONG_TITLE\""
    [ "$status" -eq 2 ]
}

@test "#324 row 4/4: BLOCKS git add -A && rtk proxy git commit (was a MISS pre-#324)" {
    run run_guard "git add -A && rtk proxy git commit -m \"$TOO_LONG_TITLE\""
    [ "$status" -eq 2 ]
}

@test "#324 false positive: a mere mention of 'git commit' in an argument does not trip the guard" {
    run run_guard "gh pr create --body \"run git commit first, then push\" --title \"$TOO_LONG_TITLE\""
    [ "$status" -eq 0 ]
}
