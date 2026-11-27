#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/protected_branch_guard.sh
#
# Strategy (same as destructive_command_guard.bats):
#   - The hook is a pure stdin->exit-code filter: it reads a PreToolUse JSON payload on stdin and
#     exits 0 (allow) or 2 (block). Every test is "feed a payload, assert the exit code".
#   - The guard resolves the CURRENT branch from the CWD via `git symbolic-ref`, so each test runs
#     inside a throwaway repo whose HEAD we place on the branch under test.
#   - `payload <cmd>` builds the harness JSON; `run_guard <cmd>` pipes it through the guard so the
#     pipe's exit status IS the guard's.
#
# These tests pin the two false-positives from issue #54:
#   Defect 1 — refspec-blind: `git push origin --delete <other>` on main is a valid post-merge
#              cleanup that writes nothing to main, yet was blocked.
#   Defect 2 — `grep`'s `^` is per-LINE: a `git push` mentioned inside a heredoc body (an issue/PR
#              body) is prose, not a command, yet tripped the guard.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/protected_branch_guard.sh"
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

# --- regression: the core block still fires on a protected branch ------------------------------

@test "blocks a plain git push on main" {
    run run_guard "git push"
    [ "$status" -eq 2 ]
}

@test "blocks git commit on main" {
    run run_guard "git commit -m wip"
    [ "$status" -eq 2 ]
}

@test "blocks an explicit git push origin main" {
    run run_guard "git push origin main"
    [ "$status" -eq 2 ]
}

@test "blocks git push on master too" {
    git checkout -q -b master
    run run_guard "git push"
    [ "$status" -eq 2 ]
}

@test "blocks rtk-prefixed git push on main" {
    run run_guard "rtk git push"
    [ "$status" -eq 2 ]
}

# --- regression: a feature branch is never our concern -----------------------------------------

@test "allows git push on a feature branch" {
    git checkout -q -b feat/x
    run run_guard "git push"
    [ "$status" -eq 0 ]
}

@test "allows git commit on a feature branch" {
    git checkout -q -b feat/x
    run run_guard "git commit -m wip"
    [ "$status" -eq 0 ]
}

# --- Defect 1: refspec-blind — deleting ANOTHER branch from main is valid cleanup --------------

@test "allows deleting a non-protected branch from main (--delete)" {
    run run_guard "git push origin --delete fix/release-pypi-dist-glob-102"
    [ "$status" -eq 0 ]
}

@test "allows deleting a non-protected branch from main (-d short flag)" {
    run run_guard "git push origin -d feat/foo"
    [ "$status" -eq 0 ]
}

@test "allows deleting a non-protected branch from main (colon refspec)" {
    run run_guard "git push origin :feat/foo"
    [ "$status" -eq 0 ]
}

@test "STILL blocks deleting the protected branch itself (--delete main)" {
    run run_guard "git push origin --delete main"
    [ "$status" -eq 2 ]
}

@test "STILL blocks deleting the protected branch itself (colon refspec)" {
    run run_guard "git push origin :main"
    [ "$status" -eq 2 ]
}

@test "STILL blocks a src:dst push that writes the protected branch (HEAD:main)" {
    run run_guard "git push origin HEAD:main"
    [ "$status" -eq 2 ]
}

# --- Defect 2: heredoc body prose is not a command ---------------------------------------------

@test "allows gh issue create with a git push inside a heredoc body (on main)" {
    cmd="$(cat <<'CMD'
gh issue create --title x --body "$(cat <<'EOF'
   git push origin archive/49-retry-strategy
EOF
)"
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

@test "allows a doc write that mentions git commit in a heredoc body (on main)" {
    cmd="$(cat <<'CMD'
cat <<'EOF' > notes.md
git commit -m "example from the docs"
EOF
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

@test "still blocks a real git push that FOLLOWS a heredoc block (on main)" {
    cmd="$(cat <<'CMD'
cat <<'EOF' > notes.md
some notes
EOF
git push
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 2 ]
}

@test "blocks git push after a quoted '<<FAKE' that is not a heredoc (#1157)" {
    run run_guard "printf '%s\n' '<<FAKE'
git push"
    [ "$status" -eq 2 ]
}

# --- fail-open: states the guard cannot resolve to a protected branch --------------------------

@test "ignores non-Bash tools" {
    run bash -c "jq -nc '{tool_name: \"Read\", tool_input: {command: \"git push\"}}' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "fails open outside a git repo" {
    cd "$(mktemp -d)"
    run run_guard "git push"
    [ "$status" -eq 0 ]
}

@test "fails open on a detached HEAD" {
    git checkout -q --detach HEAD
    run run_guard "git push"
    [ "$status" -eq 0 ]
}

# --- issue #97: resolve the TARGET repo, not the session's cwd ---------------------------------
#
# `git symbolic-ref --short HEAD` (no -C) always reads $PWD, which is the session's checkout
# (TEST_TMP, here). These pin the fix: a command that redirects at ANOTHER repo (`git -C <path>`,
# `cd <path> &&`) must be judged against THAT repo's HEAD, not the session's.

@test "false positive (#97): session on main, target on a feature branch -> allows" {
    OTHER="$(mktemp -d)"
    git init -q -b feat/other "$OTHER"
    git -C "$OTHER" config user.email t@t && git -C "$OTHER" config user.name t
    git -C "$OTHER" commit -q --allow-empty -m init
    # session (TEST_TMP, cwd) is on main from setup() -- unchanged.
    run run_guard "git -C $OTHER commit -m wip"
    [ "$status" -eq 0 ]
    rm -rf "$OTHER"
}

@test "false negative (#97): session on feature, target on main (git -C) -> blocks" {
    OTHER="$(mktemp -d)"
    git init -q -b main "$OTHER"
    git -C "$OTHER" config user.email t@t && git -C "$OTHER" config user.name t
    git -C "$OTHER" commit -q --allow-empty -m init
    git checkout -q -b feat/x            # session moves OFF main
    run run_guard "git -C $OTHER commit -m wip"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Target repo: $OTHER"* ]]
    rm -rf "$OTHER"
}

@test "false negative (#97): session on feature, target on main (cd && git) -> blocks" {
    OTHER="$(mktemp -d)"
    git init -q -b main "$OTHER"
    git -C "$OTHER" config user.email t@t && git -C "$OTHER" config user.name t
    git -C "$OTHER" commit -q --allow-empty -m init
    git checkout -q -b feat/x            # session moves OFF main
    run run_guard "cd $OTHER && git commit -m wip"
    [ "$status" -eq 2 ]
    rm -rf "$OTHER"
}

@test "false negative (#97): session on feature, target on main (multi-line cd) -> blocks" {
    OTHER="$(mktemp -d)"
    git init -q -b main "$OTHER"
    git -C "$OTHER" config user.email t@t && git -C "$OTHER" config user.name t
    git -C "$OTHER" commit -q --allow-empty -m init
    git checkout -q -b feat/x            # session moves OFF main
    cmd="$(printf 'cd %s\ngit commit -m wip' "$OTHER")"
    run run_guard "$cmd"
    [ "$status" -eq 2 ]
    rm -rf "$OTHER"
}

@test "irresolvable target (#97): nonexistent -C path fails open, never blames session branch" {
    # session (TEST_TMP) is on main from setup() -- would block a same-repo commit.
    run run_guard "git -C /nonexistent/path/xyz commit -m wip"
    [ "$status" -eq 0 ]
}

# --- issue #141: a `\`-newline shell line continuation is ONE logical statement -----------------
#
# `git push origin \`<newline>`--delete <ref>` is a single statement split across two physical
# lines by a real shell line continuation. Before the fix, the per-line loop in main() treated the
# continuation as a SEPARATE statement: verb detection saw only line 1 (`push`, no flag), and
# push_is_safe_deletion -- reading the same truncated statement -- never saw `--delete`/the ref
# either, so this legitimate cleanup was falsely BLOCKED. These pin both directions: the safe
# delete must be ALLOWED, and a real push (or a delete of the protected branch itself) written the
# same way must still be BLOCKED -- widening the tokeniser must never open a hole.

@test "issue #141: allows a backslash-continued safe deletion on main" {
    cmd=$'git push origin \\\n    --delete fix/release-pypi-dist-glob-102'
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

@test "issue #141: allows a backslash-continued safe deletion (-d short flag)" {
    cmd=$'git push origin \\\n    -d feat/foo'
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

@test "issue #141: STILL blocks a backslash-continued push that targets main" {
    cmd=$'git push origin \\\n    main'
    run run_guard "$cmd"
    [ "$status" -eq 2 ]
}

@test "issue #141: STILL blocks a backslash-continued delete of the protected branch itself" {
    cmd=$'git push origin \\\n    --delete main'
    run run_guard "$cmd"
    [ "$status" -eq 2 ]
}

@test "issue #141: allows a backslash-continued rtk-prefixed safe deletion" {
    cmd=$'rtk git push origin \\\n    --delete fix/foo'
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}
