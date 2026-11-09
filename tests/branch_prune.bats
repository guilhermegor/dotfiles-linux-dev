#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/branch_prune.sh (dotfiles-linux-dev#948).
# Real fixture repos (a local bare origin); the forge PR list is the one stubbed seam.
# Nothing here touches a real repository.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/worktree_prune.sh"
    PR_ROWS=""
    PR_OK=1
    branch_prune_pr_list() { [ "$PR_OK" = 1 ] || return 1; printf '%s' "$PR_ROWS"; }
    # Live re-check seam: open when LIVE_OPEN is set, else derived from the snapshot rows.
    LIVE_OPEN=""
    prune_pr_state() {
        [ -z "$LIVE_OPEN" ] || { echo open; return 0; }
        if branch_prune_has_open_pr "$PR_ROWS" "$2"; then echo open; else echo none; fi
    }

    bare="$BATS_TEST_TMPDIR/origin.git"
    work="$BATS_TEST_TMPDIR/work"
    git init --quiet --bare -b master "$bare"
    git clone --quiet "$bare" "$work" 2>/dev/null
    git -C "$work" config user.email test@example.com
    git -C "$work" config user.name test
    printf 'one\n' >"$work/file.txt"
    git -C "$work" add file.txt
    git -C "$work" commit --quiet -m 'chore: initial'
    git -C "$work" push --quiet origin master
    git -C "$work" remote set-head origin -a >/dev/null
}

# branch_at <name> <file> <content>: a pushed branch adding <file>; returns to master.
branch_at() {
    git -C "$work" checkout --quiet -b "$1" origin/master
    printf '%s\n' "$3" >"$work/$2"
    git -C "$work" add "$2"
    git -C "$work" commit --quiet -m "feat: $2"
    git -C "$work" push --quiet -u origin "$1" 2>/dev/null
    git -C "$work" checkout --quiet master
}

# squash <file> <content>: the same content reaches master under another commit.
squash() {
    printf '%s\n' "$2" >"$work/$1"
    git -C "$work" add "$1"
    git -C "$work" commit --quiet -m "feat: squash $1"
    git -C "$work" push --quiet origin master
}

@test "squash-merged branch with a merged PR head is deleted locally and on origin" {
    branch_at b1 f1.txt hello
    squash f1.txt hello
    git -C "$bare" update-ref refs/pull/7/head "$(git -C "$work" rev-parse b1)"
    PR_ROWS="$(printf 'b1\tmerged\tmaster\t%s\t7\n' "$(git -C "$work" rev-parse b1)")"
    run prune_branches "$work" 0
    [[ "$output" == *"WOULD-DELETE-LOCAL b1"* ]]
    git -C "$work" rev-parse --verify --quiet refs/heads/b1
    run prune_branches "$work" 1
    [[ "$output" == *"DELETED-LOCAL b1"* ]]
    [[ "$output" == *"DELETED-REMOTE b1"* ]]
    run git -C "$work" rev-parse --verify --quiet refs/heads/b1
    [ "$status" -ne 0 ]
    [ -z "$(git -C "$bare" for-each-ref refs/heads/b1)" ]
}

@test "fetched PR-head refs are removed after the pass" {
    git -C "$bare" update-ref refs/pull/9/head "$(git -C "$work" rev-parse master)"
    run prune_branches "$work" 0
    [ -z "$(git -C "$work" for-each-ref refs/prune-pr)" ]
}

@test "an ordinary origin pr/topic branch is examined, not swallowed by the PR-head cleanup" {
    branch_at pr/topic ft.txt topic-only
    PR_ROWS="$(printf 'pr/topic\topen\tmaster\t%s\t3\n' "$(git -C "$work" rev-parse pr/topic)")"
    run prune_branches "$work" 0
    [[ "$output" == *"KEEP-REMOTE pr/topic: PR is OPEN"* ]]
    git -C "$work" rev-parse --verify --quiet refs/remotes/origin/pr/topic
}

@test "an added line that starts with ++ is checked, not mistaken for a diff header" {
    branch_at b7 f7.txt '++attempts;'
    PR_ROWS="$(printf 'b7\tclosed\tmaster\t%s\t6\n' "$(git -C "$work" rev-parse b7)")"
    run prune_branches "$work" 1
    [[ "$output" == *"REPORT-REMOTE b7"* ]]
    [[ "$output" == *"f7.txt: ++attempts;"* ]]
    [ -n "$(git -C "$bare" for-each-ref refs/heads/b7)" ]
}

@test "a changed binary file keeps the remote branch" {
    git -C "$work" checkout --quiet -b b8 origin/master
    printf '\000\001\002bin' >"$work/blob.bin"
    git -C "$work" add blob.bin
    git -C "$work" commit --quiet -m 'feat: binary'
    git -C "$work" push --quiet -u origin b8 2>/dev/null
    git -C "$work" checkout --quiet master
    PR_ROWS="$(printf 'b8\tclosed\tmaster\t%s\t2\n' "$(git -C "$work" rev-parse b8)")"
    run prune_branches "$work" 1
    [[ "$output" == *"REPORT-REMOTE b8"* ]]
    [[ "$output" == *"blob.bin: binary content differs"* ]]
    [ -n "$(git -C "$bare" for-each-ref refs/heads/b8)" ]
}

@test "a failing diff keeps the remote branch instead of reading as shipped" {
    branch_at b9 f9.txt gone
    PR_ROWS="$(printf 'b9\tclosed\tmaster\t%s\t1\n' "$(git -C "$work" rev-parse b9)")"
    bp_git() { case "$3" in diff) return 128 ;; esac; /usr/bin/git "$@"; }
    run prune_branches "$work" 1
    [[ "$output" == *"KEEP-REMOTE b9: diff unreadable"* ]]
    [ -n "$(git -C "$bare" for-each-ref refs/heads/b9)" ]
}

@test "a remote branch held by a retained worktree is kept" {
    branch_at b10 f10.txt held
    squash f10.txt held
    git -C "$work" worktree add --quiet "$BATS_TEST_TMPDIR/wt-b10" b10
    run prune_branches "$work" 1
    [[ "$output" == *"KEEP-REMOTE b10: held by a worktree"* ]]
    [ -n "$(git -C "$bare" for-each-ref refs/heads/b10)" ]
}

@test "a PR opened after the snapshot keeps the branch on both sides" {
    branch_at b11 f11.txt late
    git -C "$work" push --quiet origin b11:master
    git -C "$work" fetch --quiet origin
    LIVE_OPEN=1
    run prune_branches "$work" 1
    [[ "$output" == *"KEEP-LOCAL b11: PR opened since the snapshot"* ]]
    [[ "$output" == *"KEEP-REMOTE b11: PR opened since the snapshot"* ]]
    git -C "$work" rev-parse --verify --quiet refs/heads/b11
    [ -n "$(git -C "$bare" for-each-ref refs/heads/b11)" ]
}

@test "a local branch whose tip moved after classification is not deleted" {
    branch_at b12 f12.txt first
    git -C "$work" push --quiet origin b12:master
    git -C "$work" fetch --quiet origin
    branch_prune_recheck_pr() {
        git -C "$work" checkout --quiet b12
        printf 'newer\n' >"$work/f12b.txt"
        git -C "$work" add f12b.txt
        git -C "$work" commit --quiet -m 'feat: newer'
        git -C "$work" checkout --quiet master
    }
    run prune_branches "$work" 1
    [[ "$output" == *"KEEP-LOCAL b12: tip moved"* ]]
    git -C "$work" rev-parse --verify --quiet refs/heads/b12
}

@test "the real pr list reader survives pipefail-free PIPESTATUS handling" {
    unset -f branch_prune_pr_list
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/branch_prune.sh"
    fanout_repo_slug() { echo me/repo; }
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/bash\nprintf %%s %s\n' "'[{\"head\":{\"ref\":\"x\",\"sha\":\"abc\",\"repo\":{\"full_name\":\"me/repo\"}},\"state\":\"open\",\"merged_at\":null,\"base\":{\"ref\":\"master\"},\"number\":5}]'" >"$BATS_TEST_TMPDIR/bin/gh"
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run branch_prune_pr_list "$work"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'x\topen\tmaster\tabc\t5')" ]
}

@test "closed-unmerged remote branch with missing lines is reported, not deleted" {
    branch_at b2 f2.txt unique-line
    PR_ROWS="$(printf 'b2\tclosed\tmaster\t%s\t8\n' "$(git -C "$work" rev-parse b2)")"
    run prune_branches "$work" 1
    [[ "$output" == *"REPORT-REMOTE b2"* ]]
    [[ "$output" == *"f2.txt: unique-line"* ]]
    [ -n "$(git -C "$bare" for-each-ref refs/heads/b2)" ]
}

@test "closed-unmerged remote branch whose lines are all on master is deleted" {
    branch_at b3 f3.txt same
    squash f3.txt same
    PR_ROWS="$(printf 'b3\tclosed\tmaster\t%s\t5\n' "$(git -C "$work" rev-parse b3)")"
    run prune_branches "$work" 1
    [[ "$output" == *"DELETED-REMOTE b3: every added line is on origin/master"* ]]
    [ -z "$(git -C "$bare" for-each-ref refs/heads/b3)" ]
}

@test "branch with an OPEN PR is kept on both sides" {
    branch_at b4 f4.txt open-work
    PR_ROWS="$(printf 'b4\topen\tmaster\t%s\t4\n' "$(git -C "$work" rev-parse b4)")"
    run prune_branches "$work" 1
    [[ "$output" == *"KEEP-LOCAL b4: PR is OPEN"* ]]
    [[ "$output" == *"KEEP-REMOTE b4: PR is OPEN"* ]]
    git -C "$work" rev-parse --verify --quiet refs/heads/b4
    [ -n "$(git -C "$bare" for-each-ref refs/heads/b4)" ]
}

@test "an unreadable forge list skips the pass and deletes nothing" {
    branch_at b5 f5.txt x
    squash f5.txt x
    PR_OK=0
    run prune_branches "$work" 1
    [ "$status" -eq 2 ]
    [[ "$output" == *"forge PR list unreadable"* ]]
    git -C "$work" rev-parse --verify --quiet refs/heads/b5
    [ -n "$(git -C "$bare" for-each-ref refs/heads/b5)" ]
}

@test "a branch checked out by a worktree is never deleted locally" {
    branch_at b6 f6.txt y
    squash f6.txt y
    git -C "$work" worktree add --quiet "$BATS_TEST_TMPDIR/wt-b6" b6
    run prune_branches "$work" 1
    git -C "$work" rev-parse --verify --quiet refs/heads/b6
}

@test "default branch and gh-pages are never touched" {
    git -C "$work" push --quiet origin master:gh-pages
    run prune_branches "$work" 1
    [ -n "$(git -C "$bare" for-each-ref refs/heads/gh-pages)" ]
    [ -n "$(git -C "$bare" for-each-ref refs/heads/master)" ]
}
