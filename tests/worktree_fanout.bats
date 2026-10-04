#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/worktree_fanout.sh's fanout_worktrees() —
# specifically the "pushed with NO PR" predicate (dotfiles-linux-dev#457). "Pushed" must mean
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
    # `@{upstream}` at all — the dotfiles-linux-dev#571 gap. One real commit, never pushed
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

    # branchF / branchG: TWO commits each, no upstream, then squash-merged into master as ONE
    # commit — the dotfiles-linux-dev#606 shape. The squashed commit's patch-id equals neither branch
    # commit, so `git cherry` marks both "+" and only the forge can say the work shipped.
    wtF="$BATS_TEST_TMPDIR/wtF"
    wtG="$BATS_TEST_TMPDIR/wtG"
    git -C "$work" worktree add --quiet -b branchF "$wtF" master
    git -C "$work" worktree add --quiet -b branchG "$wtG" master
    for pair in "$wtF:f" "$wtG:g"; do
        for n in 1 2; do
            echo "${pair#*:}$n" >"${pair%%:*}/${pair#*:}$n.txt"
            git -C "${pair%%:*}" add "${pair#*:}$n.txt"
            git -C "${pair%%:*}" commit --quiet -m "feat: add ${pair#*:}$n"
        done
        echo "${pair#*:}1" >"$work/${pair#*:}1.txt"
        echo "${pair#*:}2" >"$work/${pair#*:}2.txt"
        git -C "$work" add "${pair#*:}1.txt" "${pair#*:}2.txt"
        git -C "$work" commit --quiet -m "feat: add ${pair#*:}1 and ${pair#*:}2 (squash)"
    done
    git -C "$work" push --quiet origin master
    headF="$(git -C "$wtF" rev-parse HEAD)"
    headG="$(git -C "$wtG" rev-parse HEAD)"
}

# One `gh pr list --json ...` row, as session_start_context.sh fetches them.
pr_row() {
    printf '[{"number":9,"state":"%s","headRefName":"%s","headRefOid":"%s"}]' "$1" "$2" "$3"
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

@test "multi-commit branch squash-merged on the forge is not reported never pushed" {
    run fanout_worktrees "$work" 1 "$(pr_row MERGED branchF "$headF")"
    [ "$status" -eq 0 ]
    [[ ! "$output" == *"worktree wtF: "*"never pushed"* ]]
    [[ ! "$output" == *"RESUME"*"wtF"* ]]
}

@test "multi-commit squash-merged branch is still reported when the forge is unreadable" {
    run fanout_worktrees "$work" 0 ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtF: 2 commit(s) never pushed"* ]]
}

@test "merged PR whose headRefOid is not the local HEAD does not suppress the report" {
    run fanout_worktrees "$work" 1 "$(pr_row MERGED branchG "$headF")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtG: 2 commit(s) never pushed"* ]]
}

@test "open PR with a matching headRefOid does not suppress the report" {
    run fanout_worktrees "$work" 1 "$(pr_row OPEN branchG "$headG")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtG: 2 commit(s) never pushed"* ]]
}

@test "a merged PR for another branch does not suppress a real never-pushed branch" {
    run fanout_worktrees "$work" 1 "$(pr_row MERGED branchF "$headF")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtC: 1 commit(s) never pushed"* ]]
}

@test "merged PR whose head descends from the local HEAD suppresses the report" {
    later="$(git -C "$wtF" commit-tree 'HEAD^{tree}' -p "$headF" -m "later push")"
    run fanout_worktrees "$work" 1 "$(pr_row MERGED branchF "$later")"
    [ "$status" -eq 0 ]
    [[ ! "$output" == *"worktree wtF: "*"never pushed"* ]]
}

@test "merged PR head absent locally still reports the worktree" {
    run fanout_worktrees "$work" 1 "$(pr_row MERGED branchF "0123456789abcdef0123456789abcdef01234567")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtF: 2 commit(s) never pushed"* ]]
}

@test "merged PR head that is an ancestor of the local HEAD does not suppress the report" {
    parent="$(git -C "$wtF" rev-parse HEAD~1)"
    run fanout_worktrees "$work" 1 "$(pr_row MERGED branchF "$parent")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtF: 2 commit(s) never pushed"* ]]
}
