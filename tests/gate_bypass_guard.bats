#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/gate_bypass_guard.sh (dotfiles-linux-dev#1143)
#
# The hook is a pure stdin->exit-code filter: a PreToolUse JSON payload in, exit 0 (allow) or
# 2 (block) out. Every test feeds a payload and asserts the exit code, plus the refusal text
# for the blocked cases (owner-only wording and the `! <command>` form).

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/gate_bypass_guard.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP"
}

teardown() {
    rm -rf "$TEST_TMP"
}

payload() {
    jq -nc --arg cmd "$1" --arg cwd "$PWD" \
        '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $cmd}}'
}

run_guard() {
    payload "$1" | "$GUARD"
}

assert_refused() {
    run run_guard "$1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"OWNER-ONLY"* ]]
    [[ "$output" == *"! <command>"* ]]
}

assert_allowed() {
    run run_guard "$1"
    [ "$status" -eq 0 ]
}

# --- refusals: one per token ---------------------------------------------------------------

@test "refuses git commit --no-verify" {
    assert_refused 'git commit --no-verify -m "feat: x"'
}

@test "refuses rtk git commit -m with trailing --no-verify" {
    assert_refused 'rtk git commit -m "feat: x" --no-verify'
}

@test "refuses git push --no-verify" {
    assert_refused 'git push --no-verify origin HEAD'
}

@test "refuses git merge --no-verify" {
    assert_refused 'git merge --no-verify topic'
}

@test "refuses --no-verify on a commit chained after &&" {
    assert_refused 'git add -A && git commit --no-verify -m "x"'
}

@test "refuses GATE_CHANGE_OK= prefix" {
    assert_refused 'GATE_CHANGE_OK=1 git commit -m "x"'
}

@test "refuses exported GATE_CHANGE_OK" {
    assert_refused 'export GATE_CHANGE_OK=yes; git commit -m "x"'
}

@test "refuses SKIP= before git" {
    assert_refused 'SKIP=ruff git commit -m "x"'
}

@test "refuses SKIP= before rtk git" {
    assert_refused 'SKIP=ruff,codespell rtk git commit -m "x"'
}

@test "refuses a gate-change-ok: line in an inline -m message" {
    assert_refused 'git commit -m "chore: relax gate" -m "gate-change-ok: owner agreed"'
}

@test "refuses a gate-change-ok: line inside a heredoc message" {
    cmd="$(printf '%s\n' "git commit -F- <<'MSG'" 'chore: relax gate' '' 'gate-change-ok: because' 'MSG')"
    assert_refused "$cmd"
}

@test "refuses a gate-change-ok: line in a readable -F file" {
    printf 'chore: relax gate\n\ngate-change-ok: because\n' > msg.txt
    assert_refused 'git commit -F msg.txt'
}

# --- ordinary commands pass ----------------------------------------------------------------

@test "allows an ordinary commit" {
    assert_allowed 'git commit -m "feat: add thing"'
}

@test "allows an ordinary commit through -F file" {
    printf 'feat: add thing\n\nplain body\n' > msg.txt
    assert_allowed 'git commit -F msg.txt'
}

@test "allows an ordinary push and merge" {
    assert_allowed 'git push origin HEAD:refs/heads/feat/x'
    assert_allowed 'git merge --no-ff topic'
}

@test "allows --no-verify quoted inside a commit message" {
    assert_allowed 'git commit -m "docs: explain why --no-verify is owner-only"'
}

@test "allows --no-verify inside a grep pattern" {
    assert_allowed 'grep -rn -- "--no-verify" ai_clients/'
}

@test "allows --no-verify on a non-gated git subcommand" {
    assert_allowed 'git log --no-verify'
}

@test "allows a commit message that merely mentions gate-change-ok: mid-line" {
    assert_allowed 'git commit -m "docs: the gate-change-ok: line is owner-only"'
}

# --- CodeRabbit review of #1145 ------------------------------------------------------------

@test "refuses a quoted --no-verify option argument" {
    assert_refused 'git push "--no-verify" origin HEAD'
    assert_refused "git commit '--no-verify' -m x"
}

@test "refuses --no-verify after repeated whitespace" {
    assert_refused 'git  push --no-verify origin HEAD'
    assert_refused 'git commit   -m x  --no-verify'
    assert_refused "$(printf 'git\tpush\t--no-verify')"
}

@test "allows a gate-change-ok: pattern in grep chained before an ordinary commit" {
    assert_allowed "grep -n 'gate-change-ok:' policy.txt && git commit -m 'docs: update policy'"
}

@test "refuses the commit's -F file even when an earlier command has a -F" {
    printf 'chore: x\n\ngate-change-ok: because\n' > bypass.txt
    assert_refused 'grep -F needle README.md && git commit -F bypass.txt'
}

@test "refuses a quoted -F filename containing spaces" {
    printf 'chore: x\n\ngate-change-ok: because\n' > 'commit message.txt'
    assert_refused 'git commit -F "commit message.txt"'
}

@test "refuses --file= and -Fpath spellings" {
    printf 'chore: x\n\ngate-change-ok: because\n' > msg.txt
    assert_refused 'git commit --file=msg.txt'
    assert_refused 'git commit -Fmsg.txt'
}

@test "resolves the -F file from the commit's cd directory" {
    mkdir sub
    printf 'chore: x\n\ngate-change-ok: because\n' > sub/msg.txt
    assert_refused "cd $TEST_TMP/sub && git commit -F msg.txt"
}

@test "resolves the -F file from the commit's git -C directory" {
    mkdir sub
    printf 'chore: x\n\ngate-change-ok: because\n' > sub/msg.txt
    assert_refused 'git -C sub commit -F msg.txt'
}

@test "refuses the bypass line in the second of two commits" {
    printf 'chore: x\n\ngate-change-ok: because\n' > bad.txt
    printf 'feat: fine\n' > ok.txt
    assert_refused 'git commit -F ok.txt && git commit -F bad.txt'
}

# --- relative -F resolution: apply every literal cd in order, otherwise fail closed ----------

@test "refuses a relative -F bypass file after a relative cd" {
    mkdir sub
    printf 'chore: x\n\ngate-change-ok: because\n' > sub/msg.txt
    assert_refused 'cd sub && git commit -F msg.txt'
}

@test "applies two chained cds in order" {
    mkdir -p a/b
    printf 'chore: x\n\ngate-change-ok: because\n' > a/b/msg.txt
    assert_refused 'cd a && cd b && git commit -F msg.txt'
}

@test "allows a relative -F ordinary file after chained cds" {
    mkdir -p a/b
    printf 'feat: fine\n' > a/b/msg.txt
    assert_allowed 'cd a && cd b && git commit -F msg.txt'
}

@test "fails closed on a relative -F after a cd with shell expansion" {
    printf 'feat: fine\n' > msg.txt
    run run_guard 'cd "$X" && git commit -F msg.txt'
    [ "$status" -eq 2 ]
    [[ "$output" == *"absolute -F path"* ]]
}

@test "fails closed on a relative -F after pushd or cd -" {
    printf 'feat: fine\n' > msg.txt
    run run_guard 'pushd sub && git commit -F msg.txt'
    [ "$status" -eq 2 ]
    run run_guard 'cd - && git commit -F msg.txt'
    [ "$status" -eq 2 ]
}

@test "fails closed on a relative -F that does not resolve to a readable file" {
    run run_guard 'git commit -F missing.txt'
    [ "$status" -eq 2 ]
    [[ "$output" == *"absolute -F path"* ]]
}

@test "checks an absolute -F path even after a cd with shell expansion" {
    printf 'chore: x\n\ngate-change-ok: because\n' > "$TEST_TMP/abs.txt"
    assert_refused "cd \"\$X\" && git commit -F $TEST_TMP/abs.txt"
}

@test "allows an absolute ordinary -F path after a cd with shell expansion" {
    printf 'feat: fine\n' > "$TEST_TMP/abs.txt"
    assert_allowed "cd \"\$X\" && git commit -F $TEST_TMP/abs.txt"
}

@test "fails closed on a relative -F with an expanded git -C" {
    printf 'feat: fine\n' > msg.txt
    run run_guard 'git -C "$D" commit -F msg.txt'
    [ "$status" -eq 2 ]
}

# --- directory-changing constructs the guard did not understand: fail closed -----------------

assert_unresolved() {
    run run_guard "$1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"absolute -F path"* ]]
}

@test "fails closed on a relative -F after command/builtin/eval cd" {
    mkdir sub
    printf 'chore: x\n\ngate-change-ok: because\n' > sub/msg.txt
    printf 'feat: decoy\n' > msg.txt
    assert_unresolved 'command cd sub && git commit -F msg.txt'
    assert_unresolved 'builtin cd sub && git commit -F msg.txt'
    assert_unresolved 'eval "cd sub" && git commit -F msg.txt'
}

@test "fails closed on a relative -F after a subshell or sh -c" {
    mkdir sub
    printf 'chore: x\n\ngate-change-ok: because\n' > sub/msg.txt
    printf 'feat: decoy\n' > msg.txt
    assert_unresolved '( cd sub; git commit -F msg.txt )'
    assert_unresolved '(cd sub && git commit -F msg.txt)'
    assert_unresolved "sh -c 'cd sub' && git commit -F msg.txt"
    assert_unresolved 'env -C sub git commit -F msg.txt'
}

@test "a quoted word containing cd after the commit flags does not trip the rule" {
    printf 'feat: fine\n' > msg.txt
    assert_allowed 'git commit -F msg.txt --author "cd <a@b.c>"'
}

@test "scans the message of a commit behind a wrapper (env, command, sudo)" {
    printf 'chore: x\n\ngate-change-ok: because\n' > "$TEST_TMP/abs.txt"
    assert_refused "env FOO=1 git commit -F $TEST_TMP/abs.txt"
    assert_refused "command git commit -F $TEST_TMP/abs.txt"
    assert_refused 'sudo git commit -m x -m "gate-change-ok: y"'
}

@test "a literal cd head is still understood" {
    mkdir sub
    printf 'feat: fine\n' > sub/msg.txt
    assert_allowed 'cd sub && git commit -F msg.txt'
}

# --- option values are not flags ---------------------------------------------------------------

@test "allows --no-verify as the VALUE of a value-taking option" {
    assert_allowed 'git commit -m "--no-verify"'
    assert_allowed 'git commit --message "--no-verify"'
    assert_allowed 'git commit -am "--no-verify"'
    assert_allowed 'git commit -m x --author "--no-verify"'
    assert_allowed 'git push -o "--no-verify" origin HEAD'
    assert_allowed 'git commit --message=--no-verify'
    assert_allowed 'git commit -m--no-verify'
}

@test "still refuses the flag next to a value-taking option" {
    assert_refused 'git commit --no-verify -m x'
    assert_refused 'git commit -m x --no-verify'
    assert_refused 'git commit -am x --no-verify'
    assert_refused 'git push -o ci.skip --no-verify origin HEAD'
}

# --- -F - (stdin): scan only the commit's own heredoc and upstream pipeline --------------------

@test "allows -F - heredoc when an unrelated heredoc holds the marker" {
    cmd="$(printf '%s\n' "cat > n.txt <<'EOF'" 'gate-change-ok: doc' 'EOF' \
        "git commit -F - <<'MSG'" 'feat: fine' 'MSG')"
    assert_allowed "$cmd"
}

@test "refuses -F - heredoc whose own body holds the marker, even with another heredoc" {
    cmd="$(printf '%s\n' "cat > n.txt <<'EOF'" 'plain' 'EOF' \
        "git commit -F - <<'MSG'" 'feat: x' '' 'gate-change-ok: y' 'MSG')"
    assert_refused "$cmd"
}

assert_stdin_refused() {
    run run_guard "$1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"absolute file"* ]]
}

@test "fails closed on a here-string into -F -" {
    assert_stdin_refused "git commit -F - <<<'gate-change-ok: x'"
    assert_stdin_refused "git commit -F- <<< 'feat: fine'"
}

@test "fails closed on any pipeline into -F -, plain or transforming" {
    assert_stdin_refused "printf '%s\n' 'gate-change-ok: because' | git commit -F -"
    assert_stdin_refused "printf 'feat: fine\n' | git commit -F -"
    assert_stdin_refused "printf 'g\x61te-change-ok: x' | git commit -F -"
    assert_stdin_refused "echo Z2F0ZS1jaGFuZ2Utb2s6IHg= | base64 -d | git commit -F -"
    assert_stdin_refused 'cat msg.txt | git commit -F-'
}

@test "fails closed on a < redirect, process substitution or no identifiable source" {
    assert_stdin_refused 'git commit -F - < msg.txt'
    assert_stdin_refused 'git commit -F - < <(printf x)'
    assert_stdin_refused 'git commit -F -'
}

@test "a here-string next to a heredoc opener is still refused" {
    cmd="$(printf '%s\n' "git commit -F - <<<'x' <<'MSG'" 'feat: fine' 'MSG')"
    assert_stdin_refused "$cmd"
}

@test "an unrelated chained heredoc still does not affect a heredoc-fed commit" {
    cmd="$(printf '%s\n' "echo hi && git commit -F- <<-MSG" 'feat: fine' 'MSG')"
    assert_allowed "$cmd"
}

# --- per-subcommand options, per-commit sources, composed -C (#1145 round 3) ------------------

@test "git commit -o is --only and takes no value" {
    assert_refused 'git commit -o "--no-verify" -m x -- README'
    assert_refused 'git commit -o --no-verify -m x'
}

@test "value-taking options differ per subcommand" {
    assert_allowed 'git commit --reuse-message "--no-verify"'
    assert_allowed 'git commit --fixup "--no-verify"'
    assert_allowed 'git merge -s "--no-verify" topic'
    assert_allowed 'git merge --strategy-option "--no-verify" topic'
    assert_allowed 'git push --repo "--no-verify" origin'
    assert_refused 'git merge -s ours --no-verify topic'
    assert_refused 'git push --repo origin --no-verify'
}

@test "refuses the marker in the SECOND of two heredoc-fed commits" {
    cmd="$(printf '%s\n' "git commit -F - <<'A'" 'feat: a' 'A' \
        "git commit -F - <<'B'" 'feat: b' '' 'gate-change-ok: z' 'B')"
    assert_refused "$cmd"
}

@test "allows two clean heredoc-fed commits" {
    cmd="$(printf '%s\n' "git commit -F - <<'A'" 'feat: a' 'A' \
        "git commit -F - <<'B'" 'feat: b' 'B')"
    assert_allowed "$cmd"
}

@test "composes repeated git -C in order" {
    mkdir -p a/b
    printf 'feat: decoy\n' > a/msg.txt
    printf 'chore: x\n\ngate-change-ok: because\n' > a/b/msg.txt
    assert_refused 'git -C a -C b commit -F msg.txt'
}

@test "an absolute git -C resets earlier ones" {
    mkdir -p a
    printf 'chore: x\n\ngate-change-ok: because\n' > "$TEST_TMP/msg.txt"
    mkdir -p other
    printf 'feat: decoy\n' > a/msg.txt
    assert_refused "git -C a -C $TEST_TMP commit -F msg.txt"
}

@test "refuses git commit -n and clusters carrying n, the short --no-verify" {
    assert_refused 'git commit -n -m x'
    assert_refused 'git commit -nm x'
    assert_refused 'git commit -anm x'
    assert_allowed 'git push -n origin HEAD'
    assert_allowed 'git merge -n topic'
    assert_allowed 'git commit -am x'
}

@test "refuses an unambiguous abbreviation of --no-verify" {
    assert_refused 'git commit --no-veri -m x'
    assert_refused 'git push --no-verif origin HEAD'
}

@test "reads abbreviated --message and --file" {
    printf 'chore: x\n\ngate-change-ok: because\n' > msg.txt
    assert_refused 'git commit --fil msg.txt'
    assert_refused 'git commit --fil=msg.txt'
    assert_refused 'git commit --mess "gate-change-ok: x"'
    assert_refused 'git commit -aF msg.txt'
}

@test "git global options with values do not hide the subcommand" {
    assert_refused 'git --git-dir x --work-tree y commit --no-verify -m z'
    assert_refused 'git -c user.name=x commit --no-verify -m z'
}

@test "refuses a core.hooksPath override, which disables every hook" {
    assert_refused 'git -c core.hooksPath=/dev/null commit -m x'
    assert_refused 'git -c core.hookspath=/dev/null push origin HEAD'
}

@test "words after -- are pathspecs, not options" {
    assert_allowed 'git commit -m x -- --no-verify'
}

# --- round 4: heredoc binding, one option parse, cd option words --------------------------------

@test "a heredoc of an unrelated command on the -F- line does not feed the commit" {
    cmd="$(printf '%s\n' "cat <<'PATTERN' && git commit -F- <<'MSG'" \
        'gate-change-ok: pattern' 'PATTERN' 'feat: fine' 'MSG')"
    assert_allowed "$cmd"
}

@test "the commit's own heredoc is still read when another heredoc shares its line" {
    cmd="$(printf '%s\n' "cat <<'PATTERN' && git commit -F- <<'MSG'" \
        'plain' 'PATTERN' 'feat: x' '' 'gate-change-ok: y' 'MSG')"
    assert_refused "$cmd"
}

@test "an abbreviated --fil - pipeline commit is not masked by an earlier -F- heredoc commit" {
    cmd="$(printf '%s\n' "git commit -F- <<'A'" 'feat: a' 'A' \
        "printf 'x' | git commit --fil -")"
    assert_stdin_refused "$cmd"
}

@test "every stdin spelling reads the heredoc body" {
    for spelling in '-F -' '-F-' '--file -' '--file=-' '--fil -' '-aF -'; do
        cmd="$(printf '%s\n' "git commit $spelling <<'M'" 'feat: x' '' 'gate-change-ok: y' 'M')"
        assert_refused "$cmd"
    done
}

@test "every stdin spelling allows a clean heredoc" {
    for spelling in '-F -' '-F-' '--file -' '--file=-' '--fil -' '-aF -'; do
        cmd="$(printf '%s\n' "git commit $spelling <<'M'" 'feat: fine' 'M')"
        assert_allowed "$cmd"
    done
}

@test "fails closed on a relative -F after cd with option words" {
    mkdir sub
    printf 'chore: x\n\ngate-change-ok: because\n' > sub/msg.txt
    printf 'feat: decoy\n' > msg.txt
    assert_unresolved 'cd -P sub && git commit -F msg.txt'
    assert_unresolved 'cd -L sub && git commit -F msg.txt'
    assert_unresolved 'cd -- sub && git commit -F msg.txt'
    assert_unresolved 'cd -e sub && git commit -F msg.txt'
}

@test "an option value that looks like a message flag is not parsed as one" {
    assert_allowed 'git commit --author "-F" -m "feat: x"'
    assert_allowed 'git commit --trailer "-m" -m "feat: x"'
    assert_refused 'git commit --trailer "-m" -m "gate-change-ok: y"'
}

# --- round 5: quote-aware heredoc openers ------------------------------------------------------

@test "a quoted <<FAKE is not an opener and does not swallow the real heredoc commit" {
    cmd="$(printf '%s\n' "printf '%s\n' '<<FAKE'" \
        "git commit --allow-empty -F- <<'MSG'" 'feat: example' '' 'gate-change-ok: reason' 'MSG')"
    assert_refused "$cmd"
}

@test "double-quoted and escaped << are not openers either" {
    cmd="$(printf '%s\n' 'echo "<<FAKE" \<\<ALSO' \
        "git commit -F- <<'MSG'" 'feat: example' '' 'gate-change-ok: reason' 'MSG')"
    assert_refused "$cmd"
}

@test "a clean heredoc commit still passes next to a quoted <<" {
    cmd="$(printf '%s\n' "printf '%s\n' '<<FAKE'" \
        "git commit -F- <<'MSG'" 'feat: example' 'MSG')"
    assert_allowed "$cmd"
}

@test "a quoted pipe or redirect character does not refuse a heredoc commit" {
    cmd="$(printf '%s\n' "grep -E 'a|b' x > /dev/null; git commit -F- <<'MSG'" 'feat: fine' 'MSG')"
    assert_allowed "$cmd"
}

@test "a quoted << word on the commit line does not confuse the binding" {
    cmd="$(printf '%s\n' "git commit -F- -m '<<x' <<'MSG'" 'feat: fine' 'MSG')"
    assert_allowed "$cmd"
    cmd="$(printf '%s\n' "git commit -F- -m '<<x' <<'MSG'" 'feat: x' '' 'gate-change-ok: y' 'MSG')"
    assert_refused "$cmd"
}

@test "a heredoc on a later line binds to its own command across newlines and ;" {
    cmd="$(printf '%s\n' "cat <<'A'; echo x" 'gate-change-ok: in A' 'A' "git commit -F- <<'B'" 'feat: fine' 'B')"
    assert_allowed "$cmd"
}

# --- round 6: ANSI-C quoting and the scanner/tokenizer backstop --------------------------------

assert_desync_refused() {
    run run_guard "$1"
    [ "$status" -eq 2 ]
}

@test "ANSI-C \$'...' with an escaped quote does not desync the scanner" {
    cmd="$(printf '%s\n' "echo \$'it\\'s <<FAKE'" "git commit -F- <<'MSG'" 'feat: x' '' 'gate-change-ok: y' 'MSG')"
    assert_desync_refused "$cmd"
}

@test "an escaped quote inside ANSI-C quoting hides no real heredoc" {
    cmd="$(printf '%s\n' "echo \$'it\\'s'" "git commit -F- <<'MSG'" 'feat: x' '' 'gate-change-ok: y' 'MSG')"
    assert_desync_refused "$cmd"
}

@test "\$\"...\" is quoted like a double-quoted string" {
    cmd="$(printf '%s\n' 'echo $"a <<FAKE"' "git commit -F- <<'MSG'" 'feat: fine' 'MSG')"
    assert_allowed "$cmd"
    cmd="$(printf '%s\n' 'echo $"a <<FAKE"' "git commit -F- <<'MSG'" 'feat: x' '' 'gate-change-ok: y' 'MSG')"
    assert_refused "$cmd"
}

@test "an unterminated quote hiding a bypass flag is refused" {
    assert_desync_refused "$(printf '%s\n' "echo 'unterminated" 'git commit --no-verify -m x')"
}

@test "an apostrophe in a comment cannot hide the next command from the tokenizer" {
    assert_desync_refused "$(printf '%s\n' "# don't look" 'git commit --no-verify -m x')"
}

@test "an escaped quote inside double quotes cannot make the tokenizer absorb the commit" {
    cmd="$(printf '%s\n' "printf '%s\n' \"literal \\\"\"" \
        "git commit --allow-empty -F- <<'MSG'" 'feat: example' '' 'gate-change-ok: reason' 'MSG')"
    assert_desync_refused "$cmd"
}

@test "the same escaped-quote shape with a clean message is refused too, not allowed" {
    cmd="$(printf '%s\n' "printf '%s\n' \"literal \\\"\"" \
        "git commit --allow-empty -F- <<'MSG'" 'feat: example' 'MSG')"
    assert_desync_refused "$cmd"
}

@test "a comment with a semicolon or pipe does not make the views disagree" {
    assert_allowed 'git commit -m x # fine; ok | still fine'
}

# --- inner shell text: sh -c, bash -c, eval, xargs (dotfiles-linux-dev#1150) ---------------

@test "refuses --no-verify inside bash -c '...'" {
    assert_refused "bash -c 'git commit --no-verify -m x'"
}

@test "refuses --no-verify inside sh -c \"...\" on push" {
    assert_refused 'sh -c "git push --no-verify origin HEAD"'
}

@test "refuses git commit -n inside sh -c" {
    assert_refused "sh -c 'git commit -n -m x'"
}

@test "refuses --no-verify inside eval" {
    assert_refused 'eval "git commit --no-verify"'
}

@test "refuses GATE_CHANGE_OK= inside bash -lc" {
    assert_refused "bash -lc 'GATE_CHANGE_OK=1 git commit -m x'"
}

@test "refuses SKIP= inside bash -c" {
    assert_refused "bash -c 'SKIP=hook git commit -m x'"
}

@test "refuses a core.hooksPath override inside bash -c" {
    assert_refused "bash -c 'git -c core.hooksPath=/dev/null commit -m x'"
}

@test "refuses a bypass nested two shells deep" {
    assert_refused "bash -c \"sh -c 'git commit --no-verify -m x'\""
}

@test "refuses a bypass inside xargs sh -c" {
    assert_refused "echo x | xargs sh -c 'git commit --no-verify -m x'"
}

@test "refuses a bypass in xargs git" {
    assert_refused 'echo x | xargs git commit --no-verify -m'
}

@test "refuses a bypass in an inner shell after cd" {
    assert_refused "cd /tmp && bash -c 'git merge --no-verify topic'"
}

@test "fails closed on an inner git command built with an expansion" {
    assert_refused 'bash -c "git commit $flags -m x"'
}

@test "fails closed on an inner git command with command substitution" {
    assert_refused 'sh -c "git $(echo commit) --no-verify"'
}

@test "fails closed on shells nested past the depth bound" {
    assert_refused 'eval eval eval eval git status'
}

@test "allows a clean git command nested within the depth bound" {
    assert_allowed 'eval eval eval git status'
}

@test "refuses a bypass after a value-taking shell option (bash -o pipefail -c)" {
    assert_refused "bash -o pipefail -c 'git commit --no-verify -m x'"
    assert_refused "bash +o history -c 'git commit --no-verify -m x'"
    assert_refused "bash -co pipefail 'git commit --no-verify -m x'"
}

@test "allows a clean command after a value-taking shell option" {
    assert_allowed "bash -o pipefail -c 'git status'"
}

@test "an inner commit is judged in the directory it ran in, not one a later cd sets" {
    mkdir clean_dir
    printf 'feat: x\n\ngate-change-ok: reason\n' > msg.txt
    printf 'feat: x\n' > clean_dir/msg.txt
    assert_refused "bash -c 'git commit -F msg.txt'; cd $PWD/clean_dir"
    assert_refused "eval 'git commit -F msg.txt'; cd $PWD/clean_dir"
}

@test "a long eval chain that never mentions git finishes quickly" {
    local cmd i
    cmd='echo ok'
    for i in $(seq 20); do cmd="eval $cmd"; done
    run timeout 20 bash -c "jq -nc --arg c '$cmd' '{tool_name:\"Bash\",cwd:\"/tmp\",tool_input:{command:\$c}}' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "fails closed on an inner command whose quoted word tokenizes to git with an expansion" {
    assert_refused "bash -c 'g\"\"it commit \$flags -m x'"
}

@test "allows bash -c 'git status'" {
    assert_allowed "bash -c 'git status'"
}

@test "allows sh -c 'echo --no-verify'" {
    assert_allowed "sh -c 'echo --no-verify'"
}

@test "allows eval of a harmless command" {
    assert_allowed 'eval "echo hello"'
}

@test "allows bash -lc with a clean git commit" {
    assert_allowed "bash -lc 'git commit -m \"feat: x\"'"
}

@test "allows a bash -c script that never mentions git, expansion or not" {
    assert_allowed 'bash -c "echo $HOME"'
}

@test "allows bash script.sh with a -c later in its own arguments" {
    assert_allowed 'bash script.sh -c git'
}

@test "allows non-Bash tools and empty commands" {
    run bash -c "jq -nc '{tool_name:\"Read\",tool_input:{file_path:\"x\"}}' | '$GUARD'"
    [ "$status" -eq 0 ]
    assert_allowed ''
}
