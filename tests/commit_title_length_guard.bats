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

@test "#961: BLOCKS an over-limit -am title that follows a short heredoc title in one script" {
    printf 'git commit -F- <<MSG\nfeat: short\nMSG\ngit commit -am "%s"\n' "$LONG_TITLE" > "$TEST_TMP/c.sh"
    run run_guard "bash $TEST_TMP/c.sh"
    [ "$status" -eq 2 ]
}

@test "#961: judges each title against the limit of its own git -C repository" {
    mkdir "$TEST_TMP/other" && git -C "$TEST_TMP/other" init -q
    printf '[general]\nignore=B5,B6\n[title-max-length]\nline-length=100\n' > "$TEST_TMP/other/.gitlint"
    run run_guard "git -C $TEST_TMP/other commit -m '$LONG_TITLE' -m body"
    [ "$status" -eq 0 ]
}

@test "#961: bash -n does not block a script holding a long title" {
    printf 'git commit -m "%s"\n' "$LONG_TITLE" > "$TEST_TMP/c.sh"
    run run_guard "bash -n $TEST_TMP/c.sh"
    [ "$status" -eq 0 ]
}

@test "#961: a literal empty first -m is skipped, the second -m is the title" {
    run run_guard "git commit -m '' -m '$LONG_TITLE'"
    [ "$status" -eq 2 ]
}

@test "#961: a --author value that looks like -m is not the title" {
    run run_guard "git commit --author '-m $LONG_TITLE' -m 'feat: x'"
    [ "$status" -eq 0 ]
}

@test "#961: BLOCKS a long -F- heredoc title inside bash <script>.sh (heredoc kept for titles)" {
    printf 'git commit -F- <<MSG\n%s\n\nbody\nMSG\n' "$LONG_TITLE" > "$TEST_TMP/c.sh"
    run run_guard "bash $TEST_TMP/c.sh"
    [ "$status" -eq 2 ]
}

@test "#961: a git commit -m example inside a heredoc is not parsed as a commit" {
    run run_guard "git commit -F- <<MSG
feat: short

git commit -m '$LONG_TITLE'
MSG"
    [ "$status" -eq 0 ]
}

@test "#961: heredoc with a digits-only delimiter: title measured, body example ignored" {
    run run_guard "git commit -F- <<'123'
$LONG_TITLE
123"
    [ "$status" -eq 2 ]
    printf "cat <<'123'\ngit commit -m \"%s\"\n123\n" "$LONG_TITLE" > "$TEST_TMP/c.sh"
    run run_guard "bash $TEST_TMP/c.sh"
    [ "$status" -eq 0 ]
}

@test "#961: heredoc title limit comes from the commit that reads stdin (other repo allows 100)" {
    mkdir "$TEST_TMP/other" && git -C "$TEST_TMP/other" init -q
    printf '[general]\nignore=B5,B6\n[title-max-length]\nline-length=100\n' > "$TEST_TMP/other/.gitlint"
    run run_guard "git commit -m x; git -C $TEST_TMP/other commit -F- <<MSG
$LONG_TITLE
MSG"
    [ "$status" -eq 0 ]
}

@test "#961: heredoc title limit comes from the stdin commit (cwd repo allows 100, target default 72)" {
    mkdir "$TEST_TMP/other" && git -C "$TEST_TMP/other" init -q
    printf '[title-max-length]\nline-length=100\n' > .gitlint
    run run_guard "git commit -m x; git -C $TEST_TMP/other commit -F- <<MSG
$LONG_TITLE
MSG"
    [ "$status" -eq 2 ]
}

@test "#961: BLOCKS an attached non-empty -am<title> even when a later -m follows" {
    run run_guard "git commit -am'$LONG_TITLE' -m body"
    [ "$status" -eq 2 ]
}

@test "#961: an attached -am value is the title, so a short -am title with a long later -m passes" {
    run run_guard "git commit -am'feat: x' -m '$LONG_TITLE'"
    [ "$status" -eq 0 ]
}

@test "#961: two -F- commits make the heredoc association ambiguous, so it fails open" {
    mkdir "$TEST_TMP/ra" "$TEST_TMP/rb"
    git -C "$TEST_TMP/ra" init -q; git -C "$TEST_TMP/rb" init -q
    printf "[title-max-length]\nline-length=100\n" > "$TEST_TMP/rb/.gitlint"
    run run_guard "git -C $TEST_TMP/ra commit -F- </dev/null; git -C $TEST_TMP/rb commit -F- <<'MSG'
$LONG_TITLE
MSG"
    [ "$status" -eq 0 ]
}

@test "#961: a quoted heredoc delimiter with a space hides a commit example from the title guard" {
    run run_guard "cat <<'END WORD'
git commit -m '$LONG_TITLE'
END WORD"
    [ "$status" -eq 0 ]
}

@test "#961: BLOCKS a long title after a quoted here-string (<<< is not a heredoc)" {
    run run_guard "read x <<< \"\$y\"
git commit -m '$LONG_TITLE'"
    [ "$status" -eq 2 ]
}

@test "#961: BLOCKS a long title after a bare here-string word" {
    run run_guard "cat <<< hello
git commit -m '$LONG_TITLE'"
    [ "$status" -eq 2 ]
}

@test "#961: a real heredoc after a here-string is still stripped" {
    run run_guard "cat <<< hi
cat <<'EOT'
git commit -m '$LONG_TITLE'
EOT"
    [ "$status" -eq 0 ]
}

@test "#961: BLOCKS git commit -S -m <long title> (-S takes no separate value)" {
    run run_guard "git commit -S -m '$LONG_TITLE'"
    [ "$status" -eq 2 ]
}

@test "#961: BLOCKS git commit --gpg-sign -m <long title>" {
    run run_guard "git commit --gpg-sign -m '$LONG_TITLE'"
    [ "$status" -eq 2 ]
}

# --- #1002: gitlint B5 (body too short) / B6 (body missing) --------------------------------------

gitlint_repo() { printf '%b' "${1:-[general]\n}" > .gitlint; }

@test "#1002: BLOCKS a title-only commit (B6) when .gitlint exists" {
    gitlint_repo
    run run_guard "git commit -m 'fix: x'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"B6"* ]]
}

@test "#1002: BLOCKS a 12-char body (B5) naming '12 < 20'" {
    gitlint_repo
    run run_guard "git commit -m 'fix: x' -m 'Closes #1122'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"B5"* && "$output" == *"12 < 20"* ]]
}

@test "#1002: PASSES a body of 20+ chars" {
    gitlint_repo
    run run_guard "git commit -m 'fix: x' -m 'This explains the change well.'"
    [ "$status" -eq 0 ]
}

@test "#1002: B5 boundary matches gitlint (19 blocks, 20 passes)" {
    gitlint_repo
    run run_guard "git commit -m 'fix: x' -m '1234567890123456789'"
    [ "$status" -eq 2 ]
    run run_guard "git commit -m 'fix: x' -m '12345678901234567890'"
    [ "$status" -eq 0 ]
}

@test "#1002: gitlint joins body lines without newlines (10+10 passes, 9+9 blocks)" {
    gitlint_repo
    run run_guard "git commit -m 'fix: x' -m 'abcdefghij
abcdefghij'"
    [ "$status" -eq 0 ]
    run run_guard "git commit -m 'fix: x' -m 'abcdefghi
abcdefghi'"
    [ "$status" -eq 2 ]
}

@test "#1002: a repo with no .gitlint passes untouched (fail open)" {
    run run_guard "git commit -m 'fix: x'"
    [ "$status" -eq 0 ]
}

@test "#1002: honours a custom [body-min-length] min-length" {
    gitlint_repo '[body-min-length]\nmin-length=5\n'
    run run_guard "git commit -m 'fix: x' -m 'abcde'"
    [ "$status" -eq 0 ]
    gitlint_repo '[body-min-length]\nmin-length=40\n'
    run run_guard "git commit -m 'fix: x' -m 'This explains the change well.'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"< 40"* ]]
}

@test "#1002: B6 ignored via .gitlint skips a missing body but still checks B5" {
    gitlint_repo '[general]\nignore=body-is-missing\n'
    run run_guard "git commit -m 'fix: x'"
    [ "$status" -eq 0 ]
    run run_guard "git commit -m 'fix: x' -m 'short'"
    [ "$status" -eq 2 ]
}

@test "#1002: B6 ignored by rule id in a comma list" {
    gitlint_repo '[general]\nignore = T3, B6\n'
    run run_guard "git commit -m 'fix: x'"
    [ "$status" -eq 0 ]
}

@test "#1002: B5 ignored via .gitlint" {
    gitlint_repo '[general]\nignore=body-min-length\n'
    run run_guard "git commit -m 'fix: x' -m 'short'"
    [ "$status" -eq 0 ]
}

@test "#1002: Merge / fixup! titles are skipped like gitlint does" {
    gitlint_repo
    run run_guard "git commit -m 'Merge branch x'"
    [ "$status" -eq 0 ]
    run run_guard "git commit -m 'fixup! fix: x'"
    [ "$status" -eq 0 ]
}

@test "#1002: -F <file> is measured the same way" {
    gitlint_repo
    printf 'fix: x\n\nCloses #1122\n' > msg.txt
    run run_guard "git commit -F msg.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"B5"* && "$output" == *"12 < 20"* ]]
    printf 'fix: x\n' > msg.txt
    run run_guard "git commit -F msg.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"B6"* ]]
    printf 'fix: x\n\nThis explains the change well.\n' > msg.txt
    run run_guard "git commit -F msg.txt"
    [ "$status" -eq 0 ]
}

@test "#1002: -F - heredoc body is measured" {
    gitlint_repo
    cmd="$(printf "git commit -F- <<'MSG'\nfix: x\n\nshort\nMSG")"
    run run_guard "$cmd"
    [ "$status" -eq 2 ]
    [[ "$output" == *"B5"* ]]
    cmd="$(printf "git commit -F- <<'MSG'\nfix: x\n\nThis explains the change well.\nMSG")"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

@test "#1002: --amend --no-edit with no -m is not judged" {
    gitlint_repo
    run run_guard "git commit --amend --no-edit"
    [ "$status" -eq 0 ]
}

@test "#1002: a commit with no message flags (editor) passes" {
    gitlint_repo
    run run_guard "git commit"
    [ "$status" -eq 0 ]
}

@test "#1002: a message built from shell expansion is not judged" {
    gitlint_repo
    run run_guard 'git commit -m "fix: x" -m "$(cat body.txt)"'
    [ "$status" -eq 0 ]
}

@test "#1002: uses the .gitlint of the 'git -C' repository" {
    mkdir "$TEST_TMP/other" && git -C "$TEST_TMP/other" init -q
    run run_guard "git -C $TEST_TMP/other commit -m 'fix: x'"
    [ "$status" -eq 0 ]
    printf '[general]\n' > "$TEST_TMP/other/.gitlint"
    run run_guard "git -C $TEST_TMP/other commit -m 'fix: x'"
    [ "$status" -eq 2 ]
}

@test "#1002: uses the .gitlint of a 'cd <abs> &&' target repo" {
    mkdir "$TEST_TMP/other" && git -C "$TEST_TMP/other" init -q
    printf '[general]\n' > "$TEST_TMP/other/.gitlint"
    run run_guard "cd $TEST_TMP/other && git commit -m 'fix: x'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"B6"* ]]
}

@test "#1002: an unresolvable cd (relative) fails open" {
    gitlint_repo
    run run_guard "cd sub && git commit -m 'fix: x'"
    [ "$status" -eq 0 ]
}
