#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/commit_command_matcher.sh
#
# Direct tests of command_has_git_commit(), the matcher shared by
# commit_title_length_guard.sh, commit_body_wrap.sh and commit_secret_guard.sh
# (dotfiles-linux-dev#324). Per-hook end-to-end coverage lives in each hook's own
# .bats file; this file pins the matcher's own contract so all three hooks
# inherit it correctly.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    MATCHER="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/commit_command_matcher.sh"
}

# --- issue #324 table: the four invocation shapes -----------------------------------------------

@test "MATCH: bare git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH: rtk git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'rtk git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH (was MISS pre-#324): rtk proxy git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'rtk proxy git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH (was MISS pre-#324): git add -A && rtk proxy git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git add -A && rtk proxy git commit -m x'"
    [ "$status" -eq 0 ]
}

# --- additional chain operators the fix must also cover --------------------------------------

@test "MATCH: chained after ; " {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git add -A; git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH: chained after ||" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git add -A || git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH: chained after a single pipe" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'echo x | xargs -I{} git commit -m {}'"
    [ "$status" -eq 1 ]  # 'xargs -I{} git commit' — segment starts with xargs, not git/rtk: correctly no match
}

# --- the house-style spellings: absolute path + global flags ------------------------------------
#
# Not hypothetical. The global CLAUDE.md and the dev-loop skill both mandate `/usr/bin/git` where
# the rtk proxy must be bypassed, and discourage `cd <dir> &&` in favour of `git -C <dir>`. Their
# composition below is the exact form this repo's commits are written with — and it was a MISS
# against the first #324 fix, measured while landing that fix.

@test "MATCH (was MISS): absolute path /usr/bin/git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit '/usr/bin/git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH (was MISS): global flag between binary and subcommand -- git -C <dir> commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C /some/path commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH (was MISS): the composed house form -- /usr/bin/git -C <dir> commit -F <file>" {
    run bash -c "source '$MATCHER' && command_has_git_commit '/usr/bin/git -C /some/path commit -F /tmp/msg'"
    [ "$status" -eq 0 ]
}

@test "MATCH: a valueless global flag -- git --no-pager commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git --no-pager commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH: an inline-value global flag -- git --git-dir=/some/.git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git --git-dir=/some/.git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "NO MATCH: a global flag's VALUE is skipped, not read as the subcommand" {
    # `-C commit` names a DIRECTORY called commit and then runs `status`. Reading the flag's
    # value as the subcommand would make this a false positive.
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C commit status'"
    [ "$status" -eq 1 ]
}

# --- false positive: a mere mention must NOT match ---------------------------------------------

@test "NO MATCH: git commit merely mentioned inside an argument" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'gh pr create --body \"run git commit first\"'"
    [ "$status" -eq 1 ]
}

@test "NO MATCH: unrelated command" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git status'"
    [ "$status" -eq 1 ]
}

@test "NO MATCH: git commit-graph (word-boundary: commit is a distinct token, not a prefix match)" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git commit-graph write'"
    [ "$status" -eq 1 ]
}

# --- source-only guard -----------------------------------------------------------------------

@test "refuses direct execution (must be sourced)" {
    run bash "$MATCHER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"meant to be sourced"* ]]
}

# --- quoted -C paths (CodeRabbit, PR #325) ------------------------------------------------------
#
# `read -ra` ignores quotes, so `git -C '/tmp/repo with spaces' commit` tokenised as six words and
# the matcher read `with` as the subcommand -> MISS -> the secret guard exited before scanning.

@test "MATCH: single-quoted -C path containing spaces" {
    run bash -c "source '$MATCHER' && command_has_git_commit \"git -C '/tmp/repo with spaces' commit -m x\""
    [ "$status" -eq 0 ]
}

@test "MATCH: double-quoted -C path containing spaces" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C \"/tmp/repo with spaces\" commit -m x'"
    [ "$status" -eq 0 ]
}

# --- COMMIT_COMMAND_GIT_DIR: the effective directory a caller must honour ------------------------

@test "exports the -C directory so callers scan the repo the commit targets" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C /tmp/other commit -m x' && printf '%s' \"\$COMMIT_COMMAND_GIT_DIR\""
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp/other" ]
}

@test "exports the -C directory with spaces intact" {
    run bash -c "source '$MATCHER' && command_has_git_commit \"git -C '/tmp/repo with spaces' commit -m x\" && printf '%s' \"\$COMMIT_COMMAND_GIT_DIR\""
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp/repo with spaces" ]
}

@test "leaves the directory empty for an ordinary same-directory commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git commit -m x' && printf '[%s]' \"\$COMMIT_COMMAND_GIT_DIR\""
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "does not evaluate command substitution while tokenizing" {
    # The matcher must never execute what it inspects. If \$(...) were evaluated, the marker file
    # would exist. Reading it must stay pure text processing.
    marker="$BATS_TEST_TMPDIR/pwned"
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C \$(touch $marker) commit -m x' || true"
    [ ! -e "$marker" ]
}

# --- #1147: _strip_heredoc_bodies is quote-aware ----------------------------------------------

_strip() {
    bash -c "source '$MATCHER' && printf '%s\n' \"\$1\" | _strip_heredoc_bodies" _ "$1"
}

@test "STRIP: plain heredoc body is dropped, opener and later lines kept" {
    run _strip $'cat <<EOF\nbody\nEOF\necho after'
    [ "$output" = $'cat <<EOF\necho after' ]
}

@test "STRIP: single-quoted <<FAKE decoy does not swallow a real heredoc" {
    run _strip $'printf \'%s\\n\' \'<<FAKE\'\ngit commit -F- <<\'MSG\'\nsecret body\nMSG\necho after'
    [ "$output" = $'printf \'%s\\n\' \'<<FAKE\'\ngit commit -F- <<\'MSG\'\necho after' ]
}

@test "STRIP: double-quoted, escaped and ANSI-C <<FAKE decoys are not openers" {
    local d
    for d in '"<<FAKE"' '\<<FAKE' "\$'<<FAKE'" '$"<<FAKE"'; do
        run _strip "echo $d"$'\nkept line\nFAKE'
        [ "$output" = "echo $d"$'\nkept line\nFAKE' ]
    done
}

@test "STRIP: <<FAKE in a comment is not an opener" {
    run _strip $'echo hi # <<FAKE\nkept'
    [ "$output" = $'echo hi # <<FAKE\nkept' ]
}

@test "STRIP: a quote opened on one line hides <<FAKE on the next" {
    run _strip $'echo "a\n<<FAKE" b\nkept'
    [ "$output" = $'echo "a\n<<FAKE" b\nkept' ]
}

@test "STRIP: a heredoc inside \$(..) inside double quotes is stripped (#1148 review)" {
    run _strip $'git commit -m "$(cat <<\'EOF\'\nfix: x "quoted" --no-verify\nEOF\n)"\necho after'
    [ "$output" = $'git commit -m "$(cat <<\'EOF\'\n)"\necho after' ]
}

@test "STRIP: a backslash-quoted delimiter loses the backslash (#1148 review)" {
    run _strip $'cat <<\\EOF\nbody\nEOF\necho after'
    [ "$output" = $'cat <<\\EOF\necho after' ]
}

@test "STRIP: << inside \$((..)) arithmetic is not an opener (#1148 review)" {
    run _strip $'echo $((1<<2))\nkept\ngit commit -m x'
    [ "$output" = $'echo $((1<<2))\nkept\ngit commit -m x' ]
}

@test "STRIP: << inside \$((..)) in double quotes is not an opener either" {
    run _strip $'echo "$((1<<2))"\nkept'
    [ "$output" = $'echo "$((1<<2))"\nkept' ]
}

@test "STRIP: \$( inside single quotes is literal and a later real heredoc is still stripped" {
    run _strip $'echo \'$(\' ; git commit -F- <<\'MSG\'\nbody\nMSG\necho after'
    [ "$output" = $'echo \'$(\' ; git commit -F- <<\'MSG\'\necho after' ]
}

@test "STRIP: \$( inside \$'..' is literal and a later real heredoc is still stripped" {
    run _strip $'echo $\'$(\' ; git commit -F- <<\'MSG\'\nbody\nMSG\necho after'
    [ "$output" = $'echo $\'$(\' ; git commit -F- <<\'MSG\'\necho after' ]
}

@test "STRIP: a backslash is literal in single quotes, so 'a\\' ends there" {
    run _strip $'echo \'a\\\' ; git commit -F- <<\'MSG\'\nbody\nMSG\necho after'
    [ "$output" = $'echo \'a\\\' ; git commit -F- <<\'MSG\'\necho after' ]
}

@test "STRIP: an unbalanced \$( fails closed and prints the whole input" {
    run _strip $'echo $(cat\ncat <<EOF\nbody\nEOF'
    [ "$output" = $'echo $(cat\ncat <<EOF\nbody\nEOF' ]
}

@test "STRIP: an escaped quote inside \$'..' does not close it early" {
    run _strip $'echo $\'it\\\'s <<FAKE\'\ngit commit -F- <<\'MSG\'\nbody\nMSG\necho after'
    [ "$output" = $'echo $\'it\\\'s <<FAKE\'\ngit commit -F- <<\'MSG\'\necho after' ]
}

@test "STRIP: a quote still open at end of input prints the whole input unstripped" {
    run _strip $'cat <<EOF\nbody\nEOF\necho "unterminated'
    [ "$output" = $'cat <<EOF\nbody\nEOF\necho "unterminated' ]
}

# --- #1147: the tokenizer skips comments and fails closed on an open quote --------------------

@test "TOKENIZER: an apostrophe in a # comment does not swallow the next command" {
    run bash -c "source '$MATCHER' && command_has_git_commit \$'# don\\'t look\ngit commit -m x'"
    [ "$status" -eq 0 ]
}

@test "TOKENIZER: a plain apostrophe comment line before a commit is seen" {
    run bash -c "source '$MATCHER' && command_has_git_commit \$'echo hi # it\\'s\ngit commit -m x'"
    [ "$status" -eq 0 ]
}

@test "TOKENIZER: an unterminated quote does not hide a later commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit \$'echo \"oops\ngit commit -m x'"
    [ "$status" -eq 0 ]
}

# Walks the whole multi-line command through the split-mode tokenizer (the path commit_inline_messages
# uses) and succeeds when some simple command starts with `git`. A trailing lone quote makes the
# quote count odd, so the pre-fix tokenizer ended balanced and absorbed the commit into one word.
_has_commit() {
    run bash -c 'source "$1"
        seen() { [[ "${_CMD_WORDS[0]:-}" == git ]] && echo GIT; return 0; }
        _for_each_command "$2" seen' _ "$MATCHER" "$1"
    [[ "$output" == *GIT* ]]
}

@test "TOKENIZER: an escaped quote inside double quotes does not end the string" {
    _has_commit $'printf \'%s\\n\' "literal \\""\ngit commit --allow-empty -F- <<\'MSG\'\nt\nMSG\necho "'
}

@test "TOKENIZER: \"a \\\\\" b\" keeps the escaped backslash and closes on the next quote" {
    _has_commit $'echo "a \\\\" b\ngit commit -m x\necho "'
}

@test "TOKENIZER: an escaped dollar inside double quotes is literal and the string still closes" {
    _has_commit $'echo "cost \\$5"\ngit commit -m x\necho "'
}

@test "TOKENIZER: a backslash outside quotes escapes the next char" {
    _has_commit $'echo \\"\ngit commit -m x\necho "'
}

@test "TOKENIZER: an escaped quote inside \$'..' does not end it" {
    _has_commit $'echo $\'it\\\'s\'\ngit commit -m x\necho \''
}

@test "TOKENIZER: a # inside a string with escaped quotes is not a comment (#1148 review)" {
    _has_commit $'echo "a \\" # \\" b"; git commit -m x'
}

@test "STRIP: an escaped space before # keeps it a word char, so a later <<EOF still opens (#1148 review)" {
    run _strip $'echo a\\ #b <<EOF\nbody\nEOF\necho after'
    [ "$output" = $'echo a\\ #b <<EOF\necho after' ]
}

@test "TOKENIZER: a git commit inside an escaped-quote string is still only an argument" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo "say \\"git commit -m x\\""'
    [ "$status" -eq 1 ]
}

# --- #1152: four gaps that hid a git commit from every guard ------------------------------------
# Each case is the shape followed by a real `git commit --no-verify`; the commit must be seen.

_sees_no_verify() {
    run bash -c 'source "$1"
        seen() { [[ "${_CMD_WORDS[0]:-}" == git && " ${_CMD_WORDS[*]} " == *" --no-verify "* ]] && echo SEEN; return 0; }
        _for_each_command "$(printf "%s" "$2" | _strip_heredoc_bodies)" seen' _ "$MATCHER" "$1"
    [[ "$output" == *SEEN* ]]
}

@test "GAP1: line continuation inside the command word (git \\<NL> commit)" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'git \\\n commit --no-verify -m x'
    [ "$status" -eq 0 ]
}

@test "GAP1: an even backslash run before a newline is a real separator, not a continuation" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo \\\\\ngit commit -m x'
    [ "$status" -eq 0 ]
}

@test "GAP1: a backslash ending a #comment is comment text, not a continuation" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo hi # note \\\ngit commit --no-verify -m x'
    [ "$status" -eq 0 ]
}

@test "GAP1: a double-quote spanning lines, then a # comment ending in a backslash" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo "a\nb" # note \\\ngit commit -m x'
    [ "$status" -eq 0 ]
}

@test "GAP1: a single-quote spanning lines, then a # comment ending in a backslash" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo \'a\nb\' # note \\\ngit commit -m x'
    [ "$status" -eq 0 ]
}

@test "GAP1: a # right after a closing paren is a comment" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'(true)# note \\\ngit commit -m x'
    [ "$status" -eq 0 ]
}

@test "GAP1: an escaped apostrophe inside \$'..' before a # comment ending in a backslash" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo $\'it\\\'s\' # note \\\ngit commit -m x'
    [ "$status" -eq 0 ]
}

@test "GAP1: a quote inside \$(..) before a # comment ending in a backslash" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo "$(printf \'"\')" # note \\\ngit commit -m x'
    [ "$status" -eq 0 ]
}

@test "GAP2: a backslash inside a double-quoted heredoc delimiter part (<<E\"\\\\OF\")" {
    _sees_no_verify $'cat <<E"\\\\OF"\nE\nE\\OF\ngit commit --no-verify -m x\nE\\\\OF'
}

@test "GAP1: a # inside quotes does not stop a real continuation" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo "a # b" && git \\\n commit -m x'
    [ "$status" -eq 0 ]
}

@test "GAP2: partially quoted heredoc delimiter <<\"E\"OF" {
    _sees_no_verify $'cat <<"E"OF\nbody\nEOF\ngit commit --no-verify -m x'
}

@test "GAP2: partially quoted heredoc delimiter <<E\"OF\"" {
    _sees_no_verify $'cat <<E"OF"\nbody\nEOF\ngit commit --no-verify -m x'
}

@test "GAP2: an unterminated quote in the delimiter fails closed (input unstripped)" {
    run _strip $'cat <<E"OF\nbody\nEOF'
    [ "$output" = $'cat <<E"OF\nbody\nEOF' ]
}

@test "GAP3: bare arithmetic command ((x<<2)) is not a heredoc opener" {
    _sees_no_verify $'((x<<2))\ngit commit --no-verify -m x'
}

@test "GAP4: two heredocs on one line strip both bodies" {
    # B's body holds `cat <<Z`: unstripped, it opened a heredoc that swallowed the commit
    _sees_no_verify $'cat <<A <<B\na\nA\ncat <<Z\nB\ngit commit --no-verify -m x'
}

@test "GAP4: two heredocs on one line, plain strip drops both bodies" {
    run _strip $'cat <<A <<B\na\nA\nb\nB\necho after'
    [ "$output" = $'cat <<A <<B\necho after' ]
}
