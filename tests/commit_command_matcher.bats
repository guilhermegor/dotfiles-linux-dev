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
    # xargs runs its command line (#1173): bash commits here, so the old "no match" expectation was wrong
    [ "$status" -eq 0 ]
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

@test "GAP1: \$'\\'' (escaped apostrophe only) before a # comment ending in a backslash" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo $\'\\\'\' # c \\\ngit commit -m x'
    [ "$status" -eq 0 ]
}

@test "GAP1: a quote inside a nested \$(..) before a # comment ending in a backslash" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'echo "$(echo \'"\')" # c \\\ngit commit -m x'
    [ "$status" -eq 0 ]
}

@test "GAP1: an apostrophe in a heredoc body does not hide a later # comment continuation" {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" $'cat <<E\nit\'s\nE\necho a # c \\\ngit commit -m x'
    [ "$status" -eq 0 ]
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

# --- #1158: four more ways to hide a commit --------------------------------------------------
# Each shape was run in real bash with `git` stubbed as a function that prints its argv: every one
# of them commits. The $'..' and $".." delimiter shapes were checked against GNU bash 5.2.21.
# _strip_sees_commit reads the stripped text the way the inline-message guards do.

_strip_sees_commit() {
    run bash -c 'source "$1"
        seen() { _words_invoke_commit && echo SEEN; return 0; }
        _for_each_command "$(printf "%s" "$2" | _strip_heredoc_bodies)" seen' _ "$MATCHER" "$1"
    [[ "$output" == *SEEN* ]]
}

_matcher_has_commit() {
    run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" "$1"
    [ "$status" -eq 0 ]
}

@test "GAP5: ANSI-C heredoc delimiter <<\$'EOF' does not swallow the commit after its terminator" {
    _strip_sees_commit $'cat <<$\'EOF\'\nbody\nEOF\ngit commit -m x\n$EOF'
}

@test "GAP5: locale-quoted heredoc delimiter <<\$\"EOF\" does not swallow the commit" {
    _strip_sees_commit $'cat <<$"EOF"\nbody\nEOF\ngit commit -m x\n$EOF'
}

@test "GAP5: ANSI-C delimiter plain strip drops the body" {
    run _strip $'cat <<$\'EOF\'\nbody\nEOF\necho after'
    [ "$output" = $'cat <<$\'EOF\'\necho after' ]
}

@test "GAP5: an escape inside an ANSI-C delimiter cannot be read, so the input is left unstripped" {
    run _strip $'cat <<$\'E\\x41\'\nbody\nEA\necho after'
    [ "$output" = $'cat <<$\'E\\x41\'\nbody\nEA\necho after' ]
}

@test "GAP5: an escaped quote inside an ANSI-C delimiter fails closed, the commit stays visible" {
    run _strip $'cat <<$\'a\\\'b\'\nbody\nab\ngit commit -m x'
    [ "$output" = $'cat <<$\'a\\\'b\'\nbody\nab\ngit commit -m x' ]
    _strip_sees_commit $'cat <<$\'a\\\'b\'\nbody\nab\ngit commit -m x'
}

@test "GAP6: a continuation after a heredoc opener (cat <<EOF \\<NL>&& git commit)" {
    _strip_sees_commit $'cat <<EOF \\\n&& git commit -m x\nbody\nEOF'
}

@test "GAP6: a continuation after a heredoc opener leaves the input unstripped" {
    run _strip $'cat <<EOF \\\n&& echo a\nbody\nEOF\necho after'
    [ "$output" = $'cat <<EOF \\\n&& echo a\nbody\nEOF\necho after' ]
}

@test "GAP6: an even backslash run after an opener is no continuation, body still stripped" {
    run _strip $'cat <<EOF \\\\\nbody\nEOF\necho after'
    [ "$output" = $'cat <<EOF \\\\\necho after' ]
}

@test "GAP7: a continuation inside the delimiter word (<<EO\\<NL>F)" {
    _strip_sees_commit $'cat <<EO\\\nF\nbody\nEOF\ngit commit -m x\nEO'
}

@test "GAP7: a continuation right after << leaves the input unstripped" {
    run _strip $'cat <<\\\nEOF\nbody\nEOF\necho after'
    [ "$output" = $'cat <<\\\nEOF\nbody\nEOF\necho after' ]
}

@test "GAP8: output redirection before the command word (>/dev/null git commit)" {
    _matcher_has_commit '>/dev/null git commit -m x'
}

@test "GAP8: separated redirection before the command word (> /dev/null git commit)" {
    _matcher_has_commit '> /dev/null git commit -m x'
}

@test "GAP8: fd, append, input, dup and herestring redirections before the command word" {
    local c
    for c in '2>/dev/null git commit -m x' '>>f git commit -m x' '<f git commit -m x' \
             '2>&1 git commit -m x' '>&2 git commit -m x' '<<<word git commit -m x' \
             '<<E git commit -m x' '&>f git commit -m x' '{fd}>f git commit -m x' \
             '>f 2>&1 rtk git commit -m x' '2> f < g /usr/bin/git -C d commit -m x'; do
        echo "case: $c"
        _matcher_has_commit "$c"
    done
}

@test "GAP8: redirections before the command word reach the split-mode readers too" {
    local c
    for c in '>&2 git commit -m x' '2>&1 git commit -m x' '&>f git commit -m x' '>f git commit -m x' \
             '>|f git commit -m x' '2>| f git commit -m x'; do
        echo "case: $c"
        _strip_sees_commit "$c"
    done
}

@test "GAP8: <<\$'E' <<\"E\" \\<NL>git commit, once the lines are joined" {
    _matcher_has_commit $'<<$\'E\' <<"E" \\\ngit commit -m x\nbody\nE\nbody\nE'
    _strip_sees_commit $'<<$\'E\' <<"E" \\\ngit commit -m x\nbody\nE\nbody\nE'
}

@test "GAP8: clobber redirection >| before the command word" {
    _matcher_has_commit '>|f git commit -m x'
    _matcher_has_commit '2>| f git commit -m x'
}

# The >| re-reading must never make a commit appear twice: callbacks that count commits would
# read the second one as another commit (COMMIT_SOURCE_FOUND fell to 0, messages doubled).
_source_found() {
    run bash -c 'source "$1"; commit_source_dir "$2" "$3"; echo "found=$COMMIT_SOURCE_FOUND"' _ "$MATCHER" "$1" "$2"
    [[ "$output" == *"found=1"* ]]
}

@test "GAP8: >| after a stdin commit does not double it (2>|)" {
    _source_found $'git commit -F - 2>|/tmp/err <<\'EOF\'\nmsg\nEOF' stdin
}

@test "GAP8: >| after a stdin commit does not double it (>|)" {
    _source_found $'git commit -F - >|/tmp/o <<\'EOF\'\nmsg\nEOF' stdin
}

@test "GAP8: >| inside a commit's own message does not double it" {
    _source_found "git commit -F msg.txt -m 'a >| b'" file
}

@test "GAP8: >| inside a commit's message gives one message set, not two" {
    run bash -c 'source "$1"; commit_inline_messages "$2"; echo "sets=${#COMMIT_MESSAGE_SETS[@]}"' _ "$MATCHER" "git commit -m 'a >| b'"
    [[ "$output" == *"sets=1"* ]]
}

@test "GAP8: >| inside a commit's message does not make a later cd read as a cd before it" {
    run bash -c 'source "$1"; commit_cd_dir "$2"; echo "ok=$COMMIT_CD_OK"' _ "$MATCHER" "git commit -m 'a >| b'; cd /x"
    [[ "$output" == *"ok=1"* ]]
}

@test "GAP8: a commit found only by the >| re-reading still counts for the source reader" {
    _source_found $'>|f git commit -F - <<\'EOF\'\nmsg\nEOF' stdin
}

@test "GAP8: a leading redirection plus a later >| or 2>&1 is still one commit" {
    local c
    for c in '>o git commit -m x 2>|e' '2>&1 git commit -m x >|e' '>|f git commit -m x 2>|e'; do
        echo "case: $c"
        run bash -c 'source "$1"; commit_inline_messages "$2"; echo "sets=${#COMMIT_MESSAGE_SETS[@]}"' _ "$MATCHER" "$c"
        [[ "$output" == *"sets=1"* ]]
    done
}

@test "GAP8: a leading redirection plus a later >| gives COMMIT_SOURCE_FOUND=1" {
    _source_found $'>o git commit -F - 2>|e <<\'EOF\'\nmsg\nEOF' stdin
    _source_found $'2>&1 git commit -F - >|e <<\'EOF\'\nmsg\nEOF' stdin
}

# split-mode commit count: how many simple commands the inline-message readers would see
_split_commits() {
    run bash -c 'source "$1"
        seen() { _words_invoke_commit && echo SEEN; return 0; }
        _for_each_command "$(printf "%s" "$2" | _strip_heredoc_bodies)" seen' _ "$MATCHER" "$1"
}

@test "GAP8: a quoted > before a real pipe is no clobber redirect, both commits stay visible" {
    _split_commits "git commit -m 'a>'|git commit --no-verify -m b"
    [ "$output" = $'SEEN\nSEEN' ]
}

@test "GAP8: an escaped > before a real pipe is no clobber redirect" {
    _split_commits 'git commit -m a\>|git commit --no-verify -m b'
    [ "$output" = $'SEEN\nSEEN' ]
}

@test "GAP8: command_has_git_commit sees a >|f commit after a quoted, double-quoted or escaped > pipe" {
    local c
    for c in "echo 'a>'|>|f git commit --no-verify -m x" 'echo "a>"|>|f git commit --no-verify -m x' \
             'echo a\>|>|f git commit --no-verify -m x'; do
        echo "case: $c"
        _matcher_has_commit "$c"
    done
}

@test "GAP8: a >|f commit after a pipe that follows a quoted or escaped > is seen by the split reader" {
    local c
    for c in "echo 'a>'|>|f git commit --no-verify -m x" 'echo "a>"|>|f git commit --no-verify -m x' \
             'echo a\>|>|f git commit --no-verify -m x'; do
        echo "case: $c"
        _split_commits "$c"
        [ "$output" = SEEN ]
    done
}

_cd_dir_of() {
    run bash -c 'source "$1"; commit_cd_dir "$2"; echo "ok=$COMMIT_CD_OK dir=$COMMIT_CD_DIR"' _ "$MATCHER" "$1"
}

@test "GAP8: a cd after a >| commit does not change the directory the commit ran in" {
    _cd_dir_of 'cd /b; >|f git commit -m x; cd /c'
    [[ "$output" == *"ok=1 dir=/b"* ]]
}

@test "GAP8: a cd with >| before a commit never reports a wrong directory" {
    # a cd carrying a redirection is not a lone `cd <path>`: unknown (ok=0) is the answer, exactly
    # what master gives
    _cd_dir_of 'cd /a 2>|e && git commit -m x'
    [[ "$output" == *"ok=0 dir="* ]]
}

@test "GAP8: two >| in one command are still one commit" {
    run bash -c 'source "$1"; commit_inline_messages "$2"; echo "sets=${#COMMIT_MESSAGE_SETS[@]}"' _ "$MATCHER" '>|a git commit -m x >|git commit'
    [[ "$output" == *"sets=1"* ]]
}

@test "GAP8: two >| in one -F - commit still give COMMIT_SOURCE_FOUND=1" {
    _source_found $'>|a git commit -F - >|git commit <<\'EOF\'\nmsg\nEOF' stdin
}

@test "GAP8: a literal \\x1e byte in the input does not make a commit fire twice" {
    run bash -c 'source "$1"; commit_inline_messages "$2"; echo "sets=${#COMMIT_MESSAGE_SETS[@]}"' _ "$MATCHER" $'git -c $\'x=\x1e\' commit -m m; echo >|f'
    [[ "$output" == *"sets=1"* ]]
}

@test "GAP8: a quoted word that looks like a redirection does not hide the real commit after it" {
    _strip_sees_commit "'>f git' commit --no-verify -m x; >|f git commit --no-verify -m x"
}

@test "GAP8: a commit found by the >| re-reading keeps its message text as written" {
    run bash -c 'source "$1"; commit_inline_messages "$2"; echo "msg=${COMMIT_MESSAGE_SETS[0]}"' _ "$MATCHER" ">|f git commit -m 'x >| y'"
    [[ "$output" == *"msg=x >| y"* ]]
}

@test "GAP8: a redirection before a non-git command word is still not a commit" {
    local c
    for c in '>/dev/null echo git commit' 'git status >/dev/null' '>f cat git commit' '2>&1 echo "git commit"'; do
        echo "case: $c"
        run bash -c 'source "$1" && command_has_git_commit "$2"' _ "$MATCHER" "$c"
        [ "$status" -ne 0 ]
    done
}

# --- #1168: a continuation inside an UNQUOTED heredoc body joins into the delimiter ---------------
# Each shape was run in GNU bash 5.2.21 with `git` stubbed as a function. A trailing `EOF` line
# makes the later `git commit` stripped on master (without one the heredoc runs to end of input and
# the stripper already fails closed).

# both readers: the text as written (command_has_git_commit) and the stripped split reader
_both_readers_see_commit() {
    _matcher_has_commit "$1"
    _strip_sees_commit "$1"
}

# the stripped split reader, no assertion: the caller checks $output
_split_run() {
    run bash -c 'source "$1"
        seen() { _words_invoke_commit && echo SEEN; return 0; }
        _for_each_command "$(printf "%s" "$2" | _strip_heredoc_bodies)" seen' _ "$MATCHER" "$1"
}

@test "GAP9: EO\\<NL>F in an unquoted body ends the heredoc, the next line commits" {
    _both_readers_see_commit $'cat <<EOF\nx\nEO\\\nF\ngit commit --no-verify -m x\nEOF'
}

@test "GAP9: the same join with <<- and a tab-indented body" {
    _both_readers_see_commit $'cat <<-EOF\n\tx\n\tEO\\\nF\ngit commit --no-verify -m x\nEOF'
}

@test "GAP9: a join across three lines (EO\\<NL>\\<NL>F)" {
    _both_readers_see_commit $'cat <<EOF\nx\nEO\\\n\\\nF\ngit commit --no-verify -m x\nEOF'
}

@test "GAP9: <<- with the joined delimiter split after the tab" {
    _both_readers_see_commit $'cat <<-EOF\n\tx\n\tE\\\nOF\ngit commit --no-verify -m x\nEOF'
}

@test "GAP9: an even backslash run does not join, so the commit stays in the body" {
    _split_run $'cat <<EOF\nx\nEO\\\\\nF\ngit commit --no-verify -m x\nEOF'
    [[ "$output" != *SEEN* ]]
}

@test "GAP9: <<- with tabs leaves EO<TAB>F after the join: no delimiter, body stays stripped" {
    _split_run $'cat <<-EOF\n\tx\n\tEO\\\n\tF\ngit commit --no-verify -m x\nEOF'
    [[ "$output" != *SEEN* ]]
}

@test "GAP9: quoted delimiters do not join, the body (commit included) stays stripped" {
    local d
    for d in "'EOF'" '"EOF"' '\EOF'; do
        echo "delim: $d"
        _split_run $'cat <<'"$d"$'\nx\nEO\\\nF\ngit commit --no-verify -m x\nEOF'
        [[ "$output" != *SEEN* ]]
    done
}

@test "GAP9: a quoted heredoc with a trailing backslash line still ends at its own delimiter" {
    _both_readers_see_commit $'cat <<\'EOF\'\nx\\\nEOF\ngit commit --no-verify -m x'
}

@test "GAP9: an unquoted body whose continuation does not form the delimiter stays stripped" {
    _split_run $'cat <<EOF\nline \\\nmore\nEOF\ngit commit --no-verify -m x'
    [[ "$output" == *SEEN* ]]
    _split_run $'cat <<EOF\nline \\\nmore\nEOF'
    [[ "$output" != *SEEN* ]]
}

@test "GAP9: opener-line comment ending in a backslash (bash: no join, commit after the body)" {
    _both_readers_see_commit $'cat <<EOF # C:\\\nx\nEOF\ngit commit --no-verify -m x'
}

@test "GAP9: <\\<NL><EOF joins into an opener, the commit after its body is seen" {
    _both_readers_see_commit $'cat <\\\n<EOF\nx\nEOF\ngit commit --no-verify -m x'
}

@test "GAP9: <\\<NL>EOF is a plain redirect from a file, the next line commits" {
    _both_readers_see_commit $'cat <\\\nEOF\ngit commit --no-verify -m x'
}

# --- #1168 review (CodeRabbit): leading tabs are stripped only for <<- ---------------------------
# Plain <<EOF: a joined TAB+EOF is no delimiter, so the heredoc runs on and `cat <<:` is body text.
# Measured in bash 5.2.21: the plain shape commits, the <<- shape (tab stripped, EOF closes early,
# `cat <<:` opens a second heredoc that swallows the commit line) does not.

_inline_sets() {
    run bash -c 'source "$1"; commit_inline_messages "$2"; echo "sets=${#COMMIT_MESSAGE_SETS[@]}"' _ "$MATCHER" "$1"
}

@test "GAP9: plain << keeps a leading tab on a joined line, so TAB+EOF does not close the heredoc" {
    local c=$'cat <<EOF\n\tEO\\\nF\ncat <<:\nEOF\ngit commit --no-verify -m x\n:'
    _both_readers_see_commit "$c"
    _inline_sets "$c"
    [[ "$output" == *"sets=1"* ]]
}

@test "GAP9: <<- strips the tab off the joined line, bash runs no commit and none is read" {
    local c=$'cat <<-EOF\n\tEO\\\nF\ncat <<:\nEOF\ngit commit --no-verify -m x\n:'
    _split_run "$c"
    [[ "$output" != *SEEN* ]]
    _inline_sets "$c"
    [[ "$output" == *"sets=0"* ]]
}

# --- #1166: assignments, wrapper words and mid-command redirections before the subcommand -------
# Every shape runs a commit in bash; both readers (command_has_git_commit and the split-mode
# _for_each_command + _words_invoke_commit) must see each one.

@test "GAP10: leading NAME=value assignments, quoted values included" {
    local c
    for c in 'FOO=1 git commit -m x' 'GIT_DIR=. git commit -m x' "FOO='a b' git commit -m x" \
             'FOO="a b" BAR=2 git commit -m x' 'A+=x git commit -m x' 'FOO= git commit -m x'; do
        echo "case: $c"
        _both_readers_see_commit "$c"
    done
}

@test "GAP10: wrapper words with their own options" {
    local c
    for c in 'env FOO=1 git commit -m x' 'env -i git commit -m x' 'env -u X git commit -m x' \
             'env -i -u X FOO=1 git commit -m x' '/usr/bin/env FOO=1 git commit -m x' \
             'command git commit -m x' 'command -p git commit -m x' 'builtin git commit -m x' \
             'exec git commit -m x' 'exec -c git commit -m x' 'time git commit -m x' \
             'time -p git commit -m x' 'nohup git commit -m x' 'sudo git commit -m x' \
             'sudo -E git commit -m x' 'sudo -u root git commit -m x' 'sudo -n -H git commit -m x' \
             'nice git commit -m x' 'nice -n 5 git commit -m x' 'nice -5 git commit -m x' \
             'ionice -c 3 git commit -m x' 'ionice -c2 -n 7 git commit -m x' \
             'sudo env FOO=1 nice -n 1 rtk git commit -m x' 'FOO=1 sudo -u x git -C d commit -m x'; do
        echo "case: $c"
        _both_readers_see_commit "$c"
    done
}

@test "GAP10: redirections after the command word and mixed with assignments" {
    local c
    for c in 'git 2>/dev/null commit -m x' 'git -C d >f commit -m x' 'rtk >f git commit -m x' \
             'FOO=1 >f git commit -m x' '>f GIT_DIR=x git commit -m x' 'rtk proxy >f git commit -m x' \
             'git > f commit -m x' 'git -c k=v 2>f -C d commit -m x' 'env FOO=1 >f git commit -m x' \
             'sudo >f git commit -m x' 'git --git-dir=d <f commit -m x' 'git >&2 commit -m x' \
             'git -C d &>f commit -m x' 'rtk git 2>&1 commit -m x' 'FOO=1 git <&3 -c k=v commit -m x'; do
        echo "case: $c"
        _both_readers_see_commit "$c"
    done
}

@test "GAP10: a commit after |& is seen by both readers" {
    _both_readers_see_commit 'git status |& git commit -m x'
    _both_readers_see_commit 'FOO=1 git status |& sudo git commit -m x'
}

@test "GAP10: -C directory is still captured through wrappers and redirections" {
    run bash -c 'source "$1"; command_has_git_commit "$2"; echo "dir=$COMMIT_COMMAND_GIT_DIR"' \
        _ "$MATCHER" 'FOO=1 sudo git >f -C /tmp/r commit -m x'
    [[ "$output" == *"dir=/tmp/r"* ]]
}

@test "GAP10: the tokenizer leaks no globals and carries no _SEGMENT_SOFT between calls" {
    run bash -c 'source "$1"
        _tokenize_segment "cat a>|b; echo '"'"'open" split
        [[ " ${_SEGMENT_SOFT[*]} " == *" 3 "* ]] || { echo "first call lost its own cut"; exit 1; }
        _tokenize_segment "echo '"'"'open" split
        echo "second=${#_SEGMENT_SOFT[@]}"
        for v in soft_keep prev_lt prev_gt lt gt; do declare -p "$v" 2>/dev/null && echo "leak $v"; done
        exit 0' _ "$MATCHER"
    [[ "$output" == *"second=0"* ]]
    [[ "$output" != *leak* ]]
}

@test "GAP10: a quoted value that starts with > or < is a value, not a redirection" {
    local c
    for c in "git -C '>d' commit -m x" 'git -C ">d" commit -m x' "git -C '<d' commit -m x" \
             "git -c '>k=v' commit -m x" "git --git-dir '>g' commit -m x" \
             "env -u '>f' git commit -m x" "sudo -u '>x' git commit -m x" \
             "nice -n '>5' git commit -m x" 'git -C \>d commit -m x'; do
        echo "case: $c"
        _both_readers_see_commit "$c"
    done
    run bash -c 'source "$1"; command_has_git_commit "$2"; echo "dir=$COMMIT_COMMAND_GIT_DIR"' _ "$MATCHER" "git -C '>d' commit -m x"
    [[ "$output" == *"dir=>d"* ]]
}

@test "GAP10: a quoted redirection target is still a redirection" {
    local c
    for c in '>"f" git commit -m x' "> 'f' git commit -m x" "2>'f g' git commit -m x" \
             'git >"f" commit -m x' "git -C '>d' >'f' commit -m x"; do
        echo "case: $c"
        _both_readers_see_commit "$c"
    done
}

@test "GAP10: redirections between a wrapper and its options keep the option state" {
    local c
    for c in 'env > /dev/null -u X git commit -m x' 'env -u > f X git commit -m x' \
             'sudo >f -u root git commit -m x' 'sudo -u >f root git commit -m x' \
             'nice 2>/dev/null -n 5 git commit -m x' 'time >f -p git commit -m x' \
             'ionice <in -c 3 git commit -m x' 'env -i >f FOO=1 git commit -m x' \
             'command >f -p git commit -m x'; do
        echo "case: $c"
        _both_readers_see_commit "$c"
    done
}

@test "GAP10: command -v / -V only looks git up, no commit runs" {
    local c
    for c in 'command -v git commit -m x' 'command -p -v git commit -m x' 'command -V git commit' \
             'command -pv git commit' 'command >f -v git commit -m x'; do
        echo "case: $c"
        run bash -c 'source "$1"; command_has_git_commit "$2"' _ "$MATCHER" "$c"
        [ "$status" -ne 0 ]
        _split_run "$c"
        [[ "$output" != *SEEN* ]]
    done
    _both_readers_see_commit 'command -p git commit -m x'
}

@test "GAP10: redirections between a git value option and its value" {
    local c
    for c in 'git -C > /dev/null /tmp commit -m x' 'git -c >f k=v commit -m x' \
             'git --git-dir >f .git commit -m x' 'git --work-tree 2>/dev/null d commit -m x'; do
        echo "case: $c"
        _both_readers_see_commit "$c"
    done
}

@test "GAP10: git -C value is the directory, not the redirection, through every reader" {
    local c='git -C > /dev/null /tmp commit -F msg'
    run bash -c 'source "$1"; command_has_git_commit "$2"; echo "dir=$COMMIT_COMMAND_GIT_DIR"' _ "$MATCHER" "$c"
    [[ "$output" == *"dir=/tmp"* ]]
    run bash -c 'source "$1"; commit_source_dir "$2" file; echo "found=$COMMIT_SOURCE_FOUND dir=$COMMIT_SOURCE_DIR"' _ "$MATCHER" "$c"
    [[ "$output" == *"found=1 dir=/tmp"* ]]
    run bash -c 'source "$1"; commit_inline_messages "$2"; echo "dirs=${COMMIT_MESSAGE_DIRS[*]}"' _ "$MATCHER" 'git -C > /dev/null /tmp commit -m x'
    [[ "$output" == *"dirs=/tmp"* ]]
}

@test "GAP10: obvious non-commits stay misses" {
    local c
    for c in 'echo git commit' "FOO='git commit' true" 'env | grep commit' 'sudo -u x git status' \
             'env FOO=1 git status' 'command -v git commit' 'nice -n 1 echo git commit' \
             'FOO=1 echo git commit' 'git 2>f status'; do
        echo "case: $c"
        run bash -c 'source "$1"; command_has_git_commit "$2"' _ "$MATCHER" "$c"
        [ "$status" -ne 0 ]
        _split_run "$c"
        [[ "$output" != *SEEN* ]]
    done
}

# --- #1173: reserved words, more wrappers, glued redirects, dir through wrappers -----------------
# Every shape below makes bash run `git commit` (or, for sudo/doas, would if the wrapper ran).

_both_see_each() {
    local c
    for c in "$@"; do
        echo "case: $c"
        _matcher_has_commit "$c"
        _split_run "$c"
        [[ "$output" == *SEEN* ]]
    done
}

@test "GAP11: reserved words in command position" {
    _both_see_each '! git commit -m x' 'if git commit -m x; then :; fi' '{ git commit -m x; }' \
        'while git commit -m x; do :; done' 'until git commit -m x; do :; done' \
        'if :; then git commit -m x; fi' 'if :; then :; else git commit -m x; fi' \
        'if :; then :; elif git commit -m x; then :; fi' 'for i in 1; do git commit -m x; done' \
        '( git commit -m x )' '(git commit -m x)' '! rtk git commit -m x' 'if ! git commit -m x; then :; fi'
}

@test "GAP11: wrappers with their options and positionals" {
    _both_see_each 'timeout 10 git commit -m x' 'timeout -s KILL 10 git commit -m x' \
        'timeout --signal=KILL --foreground 10s git commit -m x' 'echo x | xargs git commit -m' \
        'xargs -n 1 -I {} git commit -m {}' 'doas -u root git commit -m x' 'stdbuf -oL git commit -m x' \
        'stdbuf -o L git commit -m x' 'setsid git commit -m x' 'setsid -w git commit -m x' \
        'taskset 0x1 git commit -m x' 'taskset -c 0-3 git commit -m x' 'chrt -f 10 git commit -m x' \
        'chrt --reset-on-fork -r 5 git commit -m x' 'flock /tmp/l git commit -m x' \
        'flock -w 5 /tmp/l git commit -m x' 'strace -o /tmp/t git commit -m x' \
        'strace -c -U name git commit -m x' \
        'timeout 10 sudo -u x nice -n 3 git commit -m x'
}

@test "GAP11: sudo long options, both spellings, and bundled short options" {
    _both_see_each 'sudo --user root git commit -m x' 'sudo --user=root git commit -m x' \
        'sudo -h git commit -m x' 'sudo -Eu root git commit -m x' 'sudo -uroot git commit -m x' \
        'sudo --prompt p --group g git commit -m x' 'env -iu X git commit -m x' \
        'env -i -u X git commit -m x' 'sudo -EH -u root -g g git commit -m x' 'nice -n5 git commit -m x'
}

@test "GAP11: env -S / --split-string re-split the value as a command" {
    _both_see_each "env -S 'git commit -m x'" "env --split-string='git commit -m x'" \
        "env --split-string 'git commit -m x'" "env -S'git commit -m x'" "env -iS 'git commit -m x'" \
        "env -S 'env -S \"git commit -m x\"'" "env -S 'FOO=1 git commit'"
}

@test "GAP11: env -S takes an empty value, and its value may follow a spaced redirect" {
    # GNU env ignores an empty split string and runs the rest (#1174 review)
    _both_see_each "env -S '' git commit -m x" "env -u X -S '' git commit -m x" \
        "env -S > /dev/null 'git commit -m x'" "env -S 2> /dev/null 'git commit -m x'" \
        "env -u X -S > /dev/null 'git commit -m x'"
}

@test "GAP11: a redirect glued to the word before it" {
    _both_see_each 'git>/dev/null commit -m x' 'env>/dev/null git commit -m x' 'env>f git commit -m x' \
        "git -C ''>/dev/null commit -m x" 'git commit>/dev/null -m x' 'git<f commit -m x' \
        'git 2>/dev/null commit -m x' 'git -C /tmp>/dev/null commit -m x' 'sudo>f git commit -m x'
}

@test "GAP11: a glued redirect does not become the -C directory, and fd prefixes stay whole" {
    run bash -c 'source "$1"; command_has_git_commit "$2"; echo "dir=[$COMMIT_COMMAND_GIT_DIR]"' _ "$MATCHER" "git -C ''>/dev/null commit -m x"
    [[ "$output" == *"dir=[]"* ]]
    run bash -c 'source "$1"; _tokenize_segment "$2"; printf "<%s>" "${_SEGMENT_WORDS[@]}"' _ "$MATCHER" "git 2>f 10>g {fd}>h commit '2'>i a>j"
    [ "$output" = "<git><2>f><10>g><{fd}>h><commit><2><>i><a><>j>" ]
}

@test "GAP11: -C directory is followed through env, sudo and GIT_DIR / GIT_WORK_TREE" {
    local c want
    while IFS='|' read -r c want; do
        echo "case: $c"
        run bash -c 'source "$1"; command_has_git_commit "$2" && echo "dir=[$COMMIT_COMMAND_GIT_DIR]"' _ "$MATCHER" "$c"
        [[ "$output" == *"dir=[$want]"* ]]
    done <<'CASES'
env -C /tmp/r git commit -m x|/tmp/r
env --chdir /tmp/r git commit -m x|/tmp/r
env --chdir=/tmp/r git commit -m x|/tmp/r
env -C/tmp/r git commit -m x|/tmp/r
sudo -D /tmp/r git commit -m x|/tmp/r
sudo -R /tmp/r git commit -m x|
sudo --chroot=/tmp/r git commit -m x|
sudo --chdir=/tmp/r git commit -m x|/tmp/r
GIT_DIR=/tmp/r/.git git commit -m x|
env GIT_DIR=/tmp/r/.git git commit -m x|
GIT_DIR=/tmp/a/.git GIT_WORK_TREE=/tmp/w git commit -m x|
GIT_WORK_TREE=/tmp/w git commit -m x|
env -C /tmp/target -S 'git commit -m x'|/tmp/target
env -C /tmp/p env -C child git commit -m x|/tmp/p/child
env -C /tmp/p env -C /abs git commit -m x|/abs
sudo -D /tmp/p env -C child git -C sub commit -m x|/tmp/p/child/sub
env -C /tmp/r git -C sub commit -m x|/tmp/r/sub
env -C /tmp/r git -C /abs commit -m x|/abs
git -C /abs commit -m x|/abs
CASES
}

@test "GAP11: a directory the shell would expand is never published as literal text" {
    # `git -C '$PWD'` fails in the secret guard, which then skips its scan: publish no dir
    # (scan the cwd) unless the text is literal; a leading `~` / `~/` is $HOME.
    local c want
    while IFS='|' read -r c want; do
        echo "case: $c"
        run bash -c 'source "$1"; command_has_git_commit "$2" && echo "dir=[$COMMIT_COMMAND_GIT_DIR]"' _ "$MATCHER" "$c"
        [[ "$output" == *"dir=[${want//@HOME@/$HOME}]"* ]]
    done <<'CASES'
env -C "$PWD" git commit -m x|
git -C "$PWD" commit -m x|
git -C "${PWD}/sub" commit -m x|
env -C /tmp/r git -C "$SUB" commit -m x|
sudo -D `pwd` git commit -m x|
git -C ~user/r commit -m x|
env -C /tmp/target* git commit -m x|
git -C /tmp/r? commit -m x|
sudo -D /tmp/[ab] git commit -m x|
git -C ~/r commit -m x|@HOME@/r
env -C /tmp git -C ~/r commit -m x|@HOME@/r
env -C /tmp env -C ~/x git commit -m x|@HOME@/x
env -C ~ git -C sub commit -m x|@HOME@/sub
env -C /tmp git -C ~u/r commit -m x|
env -C "$X" git -C /abs commit -m x|/abs
env -C ~ git commit -m x|@HOME@
git -C '/tmp/a b' commit -m x|/tmp/a b
CASES
}

@test "GAP11: FOO=\$(a b) and backtick assignments before the command" {
    _both_see_each 'FOO=$(a b) git commit -m x' 'FOO=$(a $(b c) d) git commit -m x' 'FOO=$((1 + 2)) git commit -m x' \
        'FOO=`a b` git commit -m x' 'A=1 FOO=$(a "b c") git commit -m x'
}

@test "GAP11: an unbalanced \$( stays fail-closed, later commands remain visible" {
    _both_see_each 'FOO=$(a b; git commit -m x' 'echo `a b; git commit -m x'
    run bash -c 'source "$1"; _tokenize_segment "$2"; printf "<%s>" "${_SEGMENT_WORDS[@]}"' _ "$MATCHER" 'FOO=$(a b c'
    [ "$output" = '<FOO=$(a><b><c>' ]
}

@test "GAP11: words after an env -S value keep their blanks (the message reaches the guards)" {
    run bash -c 'source "$1"; commit_inline_messages "$2"; echo "n=${#COMMIT_MESSAGE_SETS[@]} m=${COMMIT_MESSAGE_SETS[0]}"' _ "$MATCHER" "env -S 'git commit' -m 'a  b *'"
    [ "$output" = "n=1 m=a  b *" ]
}

@test "GAP11: a backslash at the end of a # comment line does not continue it" {
    _both_see_each $'echo x # note \\\ngit commit -m x' $'# note \\\ngit commit -m x' \
        $'true # c \\\n\\\ngit commit -m x'
}

@test "GAP11 review: env -S keeps the enclosing env words, so its options still apply" {
    _both_see_each "env -S '-u HOME git commit -m x'" "env -u HOME -S 'git commit -m x'" \
        "env -i -S 'git commit -m x' -- ignored"
}

@test "GAP11 review: an env -S before a later quoted-> command leaves that command readable" {
    local c="env -S 'git status'; git -C '>d' commit -m x"
    _split_run "$c"
    [[ "$output" == *SEEN* ]]
    run bash -c 'source "$1"; commit_inline_messages "$2"; echo "n=${#COMMIT_MESSAGE_SETS[@]} m=${COMMIT_MESSAGE_SETS[0]} d=${COMMIT_MESSAGE_DIRS[0]}"' _ "$MATCHER" "$c"
    [ "$output" = "n=1 m=x d=>d" ]
}

@test "GAP11 review: xargs options with an optional argument take no separate value" {
    _both_see_each "printf 'x\\n' | env -u HOME xargs --replace git commit -m '{}'" \
        'xargs --eof git commit -m x' 'xargs --max-lines git commit -m x' 'xargs -i git commit -m x' \
        'xargs -e git commit -m x' 'xargs -l git commit -m x' 'xargs --replace=R git commit -m x' \
        'xargs -I R git commit -m x' 'xargs -E EOF git commit -m x'
}

@test "GAP11 review: only an unquoted, unescaped & joins a glued >" {
    local c m
    for c in "git commit -m 'a&'>/dev/null" 'git commit -m a\&>/dev/null' 'git commit -m "a&">/dev/null'; do
        run bash -c 'source "$1"; commit_inline_messages "$2"; echo "m=${COMMIT_MESSAGE_SETS[0]}"' _ "$MATCHER" "$c"
        echo "case: $c -> $output"
        [ "$output" = "m=a&" ]
    done
    run bash -c 'source "$1"; _tokenize_segment "$2"; printf "<%s>" "${_SEGMENT_WORDS[@]}"' _ "$MATCHER" 'git commit &>f -m x'
    [ "$output" = "<git><commit><&>f><-m><x>" ]
}

@test "GAP11: new prefixes are still misses when no git commit follows" {
    local c
    for c in '! git status' 'if git status; then :; fi' 'timeout 10 git status' 'echo x | xargs git status' \
             'sudo --user root git status' 'env -S "git status"' 'git>/dev/null status' \
             'env -C /tmp git status' 'flock /tmp/l git log' 'echo commit' 'if true; then echo git commit; fi' \
             'FOO=$(a b) git status' 'chrt 10 echo git commit'; do
        echo "case: $c"
        run bash -c 'source "$1"; command_has_git_commit "$2"' _ "$MATCHER" "$c"
        [ "$status" -ne 0 ]
        _split_run "$c"
        [[ "$output" != *SEEN* ]]
    done
}

# --- #1175: which directory the commit lands in --------------------------------------------------
# Oracle: bash with a git stub that records its cwd and GIT_DIR (shapes and output in the PR).
# Each row is `command|published dir|unresolved flag`. An empty dir with flag 0 means "the cwd";
# an empty dir with flag 1 means "somewhere the matcher cannot name", which a guard must not
# answer by scanning the cwd as if it were known.

_dir_cases() {
    local c want unres
    while IFS='|' read -r c want unres; do
        echo "case: $c"
        run env HOME=/home/t bash -c 'source "$1"; command_has_git_commit "$2" && echo "dir=[$COMMIT_COMMAND_GIT_DIR] unres=[$COMMIT_COMMAND_GIT_DIR_UNRESOLVED]"' _ "$MATCHER" "$c"
        [[ "$output" == *"dir=[${want//@HOME@//home/t}] unres=[$unres]"* ]]
    done
}

@test "#1175: an absolute GIT_DIR or --git-dir wins over -C and over a wrapper cwd" {
    _dir_cases <<'CASES'
GIT_DIR=/tmp/a/.git git -C /tmp/b commit -m x||1
env -C /tmp/b GIT_DIR=/tmp/a/.git git commit -m x||1
env GIT_DIR=/tmp/a/.git git -C /tmp/b commit -m x||1
GIT_DIR=~/x git -C /tmp/b commit -m x||1
GIT_DIR=$X/.git git -C /tmp/b commit -m x||1
git --git-dir=/tmp/a/.git -C /tmp/b commit -m x||1
git --git-dir /tmp/a/.git -C /tmp/b commit -m x||1
GIT_DIR=rel/.git git -C /tmp/b commit -m x||1
GIT_DIR=rel/.git git commit -m x||1
git --git-dir=rel/.git commit -m x||1
GIT_DIR=/tmp/a/.git GIT_DIR=rel git -C /tmp/b commit -m x||1
GIT_DIR= git -C /tmp/b commit -m x|/tmp/b|0
git --git-dir=rel -C /tmp/b commit -m x||1
CASES
}

@test "#1175: repeated git -C compose like cd, and an absolute one replaces" {
    _dir_cases <<'CASES'
git -C /tmp/a -C b commit -m x|/tmp/a/b|0
git -C /tmp/a -C /tmp/b commit -m x|/tmp/b|0
git -C a -C b commit -m x|a/b|0
env -C /tmp/p git -C a -C b commit -m x|/tmp/p/a/b|0
git -C /tmp/a -C "$X" commit -m x||1
CASES
}

@test "#1175: an env -S value is read as options, and its directory wins over the raw reading" {
    _dir_cases <<'CASES'
env -S '-C /tmp/target' git commit -m x|/tmp/target|0
env -S '-C /tmp/p' git -C sub commit -m x|/tmp/p/sub|0
env -S '-C ~/b' git commit -m x|~/b|0
env -S x git commit -m x||0
env -C /tmp/target -S 'git commit -m x'|/tmp/target|0
CASES
}

@test "#1175: quote state decides what is literal: a quoted ~ stays, an unquoted ~ is HOME" {
    _dir_cases <<'CASES'
git -C ~/r commit -m x|@HOME@/r|0
git -C ~ commit -m x|@HOME@|0
git -C '~/r' commit -m x|~/r|0
git -C "~/r" commit -m x|~/r|0
git -C '~' commit -m x|~|0
git -C ~"/r" commit -m x|~/r|0
git -C ~/'r s' commit -m x|@HOME@/r s|0
git -C ~user/r commit -m x||1
env -C '~' git commit -m x|~|0
env -C /tmp/p env -C '~/x' git commit -m x|/tmp/p/~/x|0
env -C /tmp/p git -C ~/x commit -m x|@HOME@/x|0
CASES
}

@test "#1175: a single-quoted \$ is literal, any other expansion is unresolved" {
    _dir_cases <<'CASES'
git -C '$OTHER' commit -m x|$OTHER|0
git -C "$OTHER" commit -m x||1
git -C $OTHER commit -m x||1
git -C "${OTHER}/sub" commit -m x||1
git -C `pwd` commit -m x||1
git -C '/tmp/a?b' commit -m x|/tmp/a?b|0
git -C /tmp/a?b commit -m x||1
git -C "/tmp/a b" commit -m x|/tmp/a b|0
git -C /tmp/'a*b' commit -m x|/tmp/a*b|0
git -C /tmp/a\$b commit -m x|/tmp/a$b|0
env -C "$X" git -C /abs commit -m x|/abs|0
CASES
}

@test "#1175: a sudo chroot never publishes a directory: the jail's paths are not the host's" {
    # was pinned as `/repo`, then as <root>/repo: `..` and absolute symlinks inside the jail make any
    # lexical join a guess, so the target is unresolved
    _dir_cases <<'CASES'
sudo -R /tmp/jail git -C /repo commit -m x||1
sudo --chroot=/tmp/jail git -C /repo commit -m x||1
sudo -R /tmp/jail git -C /../repo commit -m x||1
sudo -R /tmp/jail git commit -m x||1
sudo -R /tmp/jail git -C rel commit -m x||1
sudo -R "$J" git -C /repo commit -m x||1
CASES
}

@test "#1175: one env invocation keeps its LAST -C (relative to where env started); separate ones compose" {
    # measured with real env and a git stub: `env -C /w -C t` and `env -C /w -S '-C t'` both chdir to
    # `t` relative to the cwd, `env -C /w env -C t` ends in /w/t
    _dir_cases <<'CASES'
env -C /tmp/work -C target git commit -m x|target|0
env -C /tmp/work -S '-C target' git commit -m x|target|0
env -S '-C /tmp/work' -C target git commit -m x|target|0
env -C /tmp/work env -C target git commit -m x|/tmp/work/target|0
env -C /tmp/work -C /abs git commit -m x|/abs|0
sudo -D /tmp/w -D t git commit -m x|t|0
CASES
}

@test "#1175: sudo -c / -a and doas -a take a value, so the command behind them is seen" {
    _both_see_each 'sudo -c class git commit -m x' 'sudo -a type git commit -m x' \
        'doas -a style git commit -m x' 'sudo -u root -c class git commit -m x'
}

@test "#1175: an unquoted expansion in the option prefix poisons a later absolute -C" {
    # X="/tmp --git-dir=/other" splits into an injected option, so the -C that follows is not the target
    _dir_cases <<'CASES'
git -C $X -C /abs commit -m x||1
git $X -C /abs commit -m x||1
git -C /abs $X commit -m x||1
env $X git -C /abs commit -m x||1
env -C $X git -C /abs commit -m x||1
env -C $X env -C /abs git commit -m x||1
git -C "$X" -C /abs commit -m x|/abs|0
git -C /abs commit -m "$X" $Y|/abs|0
CASES
}

@test "#1175: the unresolved reason names the cause" {
    local c want
    while IFS='|' read -r c want; do
        echo "case: $c"
        run bash -c 'source "$1"; command_has_git_commit "$2" && echo "reason=[$COMMIT_COMMAND_GIT_DIR_REASON]"' _ "$MATCHER" "$c"
        [[ "$output" == *"reason=[$want]"* ]]
    done <<'CASES'
git -C "$X" commit -m x|expansion
GIT_DIR=rel git commit -m x|gitdir
git --git-dir=/a -C "$X" commit -m x|gitdir
sudo -R /j git -C /r commit -m x|chroot
git -C /abs commit -m x|
CASES
}

@test "#1175: an unquoted expansion in an env/sudo argument (option or NAME=value) is unresolved" {
    # measured: `env FOO=$X git` and `env --chdir=$X git` both word-split ($X may carry GIT_DIR=..),
    # while a shell prefix `FOO=$X git` does not
    _dir_cases <<'CASES'
env --chdir=$X git -C /safe commit -m x||1
env FOO=$X git -C /safe commit -m x||1
env A=1 B=$X git -C /safe commit -m x||1
sudo FOO=$X git -C /safe commit -m x||1
FOO=$X git -C /safe commit -m x|/safe|0
FOO=$X env A=1 git -C /safe commit -m x|/safe|0
env FOO="$X" git -C /safe commit -m x|/safe|0
CASES
}

@test "#1175: an env -S value with escapes or \${VAR} the tokenizer does not model is unresolved" {
    # GNU env turns \_ inside double quotes into a space, so the split value names another directory
    _dir_cases <<'CASES'
env -C '/tmp/repo name' -S '-C "/tmp/repo\_name"' git commit -m x||1
env -S '-C /tmp/a\_b' git commit -m x||1
env -S '-C ${D}' git commit -m x||1
env -S '-C /tmp/target' git commit -m x|/tmp/target|0
CASES
}

@test "#1175: the env -S retry keeps the raw reading's prefix-expansion state" {
    _dir_cases <<'CASES'
env -S -C$X git -C /safe commit -m x||1
env -S '-C /tmp/t' $X git -C /safe commit -m x||1
CASES
}

@test "#1175: an unresolved commit's relative -F is not found, absolute -F and resolved dirs are" {
    local c want
    while IFS='|' read -r c want; do
        echo "case: $c"
        run bash -c 'source "$1"; commit_source_dir "$2" file; echo "found=$COMMIT_SOURCE_FOUND dir=[$COMMIT_SOURCE_DIR]"' _ "$MATCHER" "$c"
        [[ "$output" == *"$want"* ]]
    done <<'CASES'
git --git-dir=/t/.git -C /t commit -F msg|found=0
git -C "$X" commit -F msg|found=0
sudo -R /j git -C /r commit -F msg|found=0
git --git-dir=/t/.git commit -F /abs/msg|found=1
git -C /t commit -F msg|found=1 dir=[/t]
git commit -F msg|found=1 dir=[]
CASES
}
