#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/worktree_fanout.sh's fanout_worktrees() —
# specifically the "pushed with NO PR" predicate (dotfiles-dev#457). "Pushed" must mean
# refs/remotes/origin/<branch> exists, never merely that `@{upstream}` resolves: a worktree
# created with `git worktree add -b <name> origin/master` tracks origin/master as its upstream
# from birth, with no remote ref of its own, and that used to read as "pushed".
#
# Builds a real local bare "origin" plus two real worktrees rather than stubbing `git`, because
# the predicate under test IS git ref plumbing (rev-parse --verify against refs/remotes/origin/*)
# — the same real-repo approach subagent_stop_sweep.sh's own oracle relies on. `gh` needs no stub
# here (unlike tests/free_surface.bats): fanout_worktrees() takes github_ok/json as already-
# resolved arguments, it never shells out to `gh` itself.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/worktree_fanout.sh"

    bare="$BATS_TEST_TMPDIR/origin.git"
    work="$BATS_TEST_TMPDIR/work"
    git init --quiet --bare -b master "$bare"
    git clone --quiet "$bare" "$work"

    git -C "$work" config user.email test@example.com
    git -C "$work" config user.name test
    echo one > "$work/file.txt"
    git -C "$work" add file.txt
    git -C "$work" commit --quiet -m 'chore: initial commit'
    git -C "$work" push --quiet origin master
    git -C "$work" remote set-head origin -a

    # branchA: created the way `git worktree add -b <name> origin/master` does — upstream
    # resolves (to origin/master), but the branch has no ref of its own on the remote.
    wtA="$BATS_TEST_TMPDIR/wtA"
    git -C "$work" worktree add --quiet -b branchA "$wtA" origin/master

    # branchB: genuinely pushed — origin/branchB exists as its own ref.
    wtB="$BATS_TEST_TMPDIR/wtB"
    git -C "$work" worktree add --quiet -b branchB "$wtB" origin/master
    git -C "$wtB" push --quiet -u origin branchB

    # branchC: created from a LOCAL branch (never remote-tracking), so it has NO
    # `@{upstream}` at all — the dotfiles-dev#571 gap. One real commit, never pushed
    # anywhere.
    wtC="$BATS_TEST_TMPDIR/wtC"
    git -C "$work" worktree add --quiet -b branchC "$wtC" master
    echo two >"$wtC/file2.txt"
    git -C "$wtC" add file2.txt
    git -C "$wtC" commit --quiet -m 'feat: add file2'

    # branchD: same no-upstream shape as branchC, but its patch already landed on
    # origin/master under a different commit (a squash merge) — must NOT be reported.
    wtD="$BATS_TEST_TMPDIR/wtD"
    git -C "$work" worktree add --quiet -b branchD "$wtD" master
    echo three >"$wtD/file3.txt"
    git -C "$wtD" add file3.txt
    git -C "$wtD" commit --quiet -m 'feat: add file3'
    echo three >"$work/file3.txt"
    git -C "$work" add file3.txt
    git -C "$work" commit --quiet -m 'feat: add file3 (squash)'
    git -C "$work" push --quiet origin master

    # branchE: created from a local branch, no upstream, but zero commits ahead of
    # the default branch — must not be reported either.
    wtE="$BATS_TEST_TMPDIR/wtE"
    git -C "$work" worktree add --quiet -b branchE "$wtE" master
}

@test "branch tracking origin/master with no remote ref of its own is not reported pushed" {
    run fanout_worktrees "$work" 1 '[]'
    [ "$status" -eq 0 ]
    [[ ! "$output" == *"branch branchA pushed with NO PR"* ]]
}

@test "branch with a genuine origin/<branch> ref and no PR is reported pushed" {
    run fanout_worktrees "$work" 1 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"branch branchB pushed with NO PR"* ]]
}

@test "branch with commits and no upstream at all is reported never pushed" {
    run fanout_worktrees "$work" 1 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtC: 1 commit(s) never pushed"* ]]
}

@test "never-pushed worktree is included in the RESUME summary line" {
    run fanout_worktrees "$work" 1 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESUME"*"wtC"* ]]
}

@test "no-upstream branch already squash-merged onto default is not reported" {
    run fanout_worktrees "$work" 1 '[]'
    [ "$status" -eq 0 ]
    [[ ! "$output" == *"worktree wtD: "*"never pushed"* ]]
}

@test "no-upstream branch sitting exactly at default is not reported" {
    run fanout_worktrees "$work" 1 '[]'
    [ "$status" -eq 0 ]
    [[ ! "$output" == *"worktree wtE: "*"never pushed"* ]]
}
