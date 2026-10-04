#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/commit_secret_guard.sh
#
# Focus: the shared matcher integration (dotfiles-linux-dev#324) — does the hook actually scan the
# staged diff for all four `git commit` invocation shapes, and does it correctly leave a mere
# mention of "git commit" alone? A staged secret makes the signal unambiguous: BLOCKED (exit 2)
# means the matcher let the hook past its early exit and it found the secret; ALLOWED (exit 0)
# with the secret still staged means the matcher's early exit fired (a MISS).
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/commit_secret_guard.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP"
    git init -q -b main .
    git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init

    printf 'aws_key = "AKIAABCDEFGHIJKLMNOP"\n' > secret.txt
    git add secret.txt
}

teardown() {
    cd /
    rm -rf "$TEST_TMP"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

run_guard() {
    payload "$1" | "$GUARD"
}

# --- issue #324 table: all four invocation shapes -----------------------------------------------

@test "#324 row 1/4: BLOCKS bare git commit over a staged secret" {
    run run_guard 'git commit -m wip'
    [ "$status" -eq 2 ]
}

@test "#324 row 2/4: BLOCKS rtk git commit over a staged secret" {
    run run_guard 'rtk git commit -m wip'
    [ "$status" -eq 2 ]
}

@test "#324 row 3/4: BLOCKS rtk proxy git commit over a staged secret (was a MISS pre-#324)" {
    run run_guard 'rtk proxy git commit -m wip'
    [ "$status" -eq 2 ]
}

@test "#324 row 4/4: BLOCKS git add -A && rtk proxy git commit over a staged secret (was a MISS pre-#324)" {
    run run_guard 'git add -A && rtk proxy git commit -m wip'
    [ "$status" -eq 2 ]
}

@test "#324 false positive: a mere mention of 'git commit' in an argument does not trip the guard" {
    run run_guard 'gh pr create --body "run git commit first"'
    [ "$status" -eq 0 ]
}

# --- cross-repository commits (CodeRabbit, PR #325) ---------------------------------------------
#
# `git -C <other> commit` stages into <other>. Scanning the caller's repo instead is wrong in both
# directions: it misses a secret staged in <other>, and it blocks a clean commit to <other> because
# the CALLER happens to have a secret staged. setup() stages a secret in TEST_TMP, so both
# directions are observable from here.

@test "scans the repo named by -C, not the caller's: blocks a secret staged THERE" {
    other="$TEST_TMP/other"
    git init -q -b main "$other"
    git -C "$other" config user.email t@t
    git -C "$other" config user.name t
    git -C "$other" commit -q --allow-empty -m init
    printf 'aws_key = "AKIAABCDEFGHIJKLMNOP"\n' > "$other/leak.txt"
    git -C "$other" add leak.txt

    # Unstage the caller's own secret so only the other repo can be the source of a block.
    git rm -q --cached secret.txt

    run run_guard "git -C $other commit -m wip"
    [ "$status" -eq 2 ]
    [[ "$output" == *"leak.txt"* ]]
}

@test "does not block a clean cross-repo commit because the CALLER has a secret staged" {
    other="$TEST_TMP/clean"
    git init -q -b main "$other"
    git -C "$other" config user.email t@t
    git -C "$other" config user.name t
    git -C "$other" commit -q --allow-empty -m init
    printf 'nothing sensitive\n' > "$other/ok.txt"
    git -C "$other" add ok.txt

    # secret.txt is still staged HERE (setup), and must not be attributed to the other repo.
    run run_guard "git -C $other commit -m wip"
    [ "$status" -eq 0 ]
}
