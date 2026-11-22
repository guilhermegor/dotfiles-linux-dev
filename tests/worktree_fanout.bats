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

    # branchF: TWO commits, no upstream, then squash-merged into master as ONE commit — the
    # dotfiles-linux-dev#606/#837 shape. The squashed commit's patch-id equals neither branch
    # commit, so `git cherry` marks both "+"; only a content comparison (or the forge) says the
    # work shipped. branchG: the same two commits but NEVER merged — real unshipped work.
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
    done
    echo f1 >"$work/f1.txt"
    echo f2 >"$work/f2.txt"
    git -C "$work" add f1.txt f2.txt
    git -C "$work" commit --quiet -m "feat: add f1 and f2 (squash)"
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

@test "multi-commit squash-merged branch is not reported even when the forge is unreadable" {
    run fanout_worktrees "$work" 0 ""
    [ "$status" -eq 0 ]
    [[ ! "$output" == *"worktree wtF: "*"never pushed"* ]]
    [[ ! "$output" == *"RESUME"*"wtF"* ]]
}

@test "multi-commit branch never merged is reported when the forge is unreadable" {
    run fanout_worktrees "$work" 0 ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtG: 2 commit(s) never pushed"* ]]
}

@test "squash-merged branch whose files changed again on default is still reported" {
    echo later >"$work/f1.txt"
    git -C "$work" commit --quiet -am "fix: touch f1 again"
    git -C "$work" push --quiet origin master
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
    later="$(git -C "$wtG" commit-tree 'HEAD^{tree}' -p "$headG" -m "later push")"
    run fanout_worktrees "$work" 1 "$(pr_row MERGED branchG "$later")"
    [ "$status" -eq 0 ]
    [[ ! "$output" == *"worktree wtG: "*"never pushed"* ]]
}

@test "merged PR head absent locally still reports the worktree" {
    run fanout_worktrees "$work" 1 "$(pr_row MERGED branchG "0123456789abcdef0123456789abcdef01234567")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtG: 2 commit(s) never pushed"* ]]
}

@test "merged PR head that is an ancestor of the local HEAD does not suppress the report" {
    parent="$(git -C "$wtG" rev-parse HEAD~1)"
    run fanout_worktrees "$work" 1 "$(pr_row MERGED branchG "$parent")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtG: 2 commit(s) never pushed"* ]]
}

# --- dotfiles-linux-dev#1080 gap 1: local branches checked out in no worktree ---

make_unattached_commit() {
    # one real commit (a new file) on <branch>, then drop the worktree: the branch stays,
    # checked out nowhere
    local branch="$1" tmp="$BATS_TEST_TMPDIR/tmp-$1"
    git -C "$work" worktree add --quiet "$tmp" "$branch"
    echo "$branch" >"$tmp/$branch.txt"
    git -C "$tmp" add "$branch.txt"
    git -C "$tmp" commit --quiet -m "feat: unattached work on $branch"
    git -C "$work" worktree remove --force "$tmp"
}

@test "unattached branch ahead of its upstream is reported with [ahead N]" {
    git -C "$work" branch --quiet --track ahead1 origin/master
    make_unattached_commit ahead1
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"branch ahead1 (no worktree): 1 commit(s) not pushed"* ]]
}

@test "unattached branch in sync with its upstream is not reported" {
    git -C "$work" branch --quiet --track synced1 origin/master
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" != *"branch synced1"* ]]
}

@test "unattached branch with no upstream and unshipped commits is reported" {
    git -C "$work" branch --quiet noup1 master
    make_unattached_commit noup1
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"branch noup1 (no worktree): 1 commit(s) never pushed — no upstream"* ]]
}

@test "unattached no-upstream branch with zero commits ahead is not reported" {
    git -C "$work" branch --quiet noup2 master
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" != *"branch noup2"* ]]
}

@test "unattached branch whose upstream is [gone] is still reported" {
    git -C "$work" branch --quiet gone1 master
    git -C "$work" push --quiet -u origin gone1
    make_unattached_commit gone1
    git -C "$bare" branch --quiet -D gone1
    git -C "$work" fetch --quiet --prune
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"branch gone1 (no worktree): 1 commit(s) never pushed"* ]]
}

@test "unattached branch ahead of its own origin ref with no upstream is reported" {
    git -C "$work" branch --quiet noup3 master
    git -C "$work" push --quiet origin noup3
    make_unattached_commit noup3
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"branch noup3 (no worktree): 1 commit(s) not pushed"* ]]
}

@test "unattached branch in sync with its own origin ref is not reported" {
    git -C "$work" branch --quiet noup5 master
    git -C "$work" push --quiet origin noup5
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" != *"branch noup5"* ]]
}

@test "branch of a worktree whose directory was deleted is reported as unattached" {
    wtP="$BATS_TEST_TMPDIR/wtP"
    git -C "$work" worktree add --quiet -b prune1 "$wtP" master
    echo prune >"$wtP/prune.txt"
    git -C "$wtP" add prune.txt
    git -C "$wtP" commit --quiet -m 'feat: work in a worktree that then vanished'
    rm -rf "$wtP"
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"branch prune1 (no worktree): 1 commit(s) never pushed"* ]]
}

@test "a merged PR for the head suppresses an unattached branch" {
    git -C "$work" branch --quiet noup4 master
    make_unattached_commit noup4
    head4="$(git -C "$work" rev-parse refs/heads/noup4)"
    run fanout_worktrees "$work" 1 "$(pr_row MERGED noup4 "$head4")"
    [ "$status" -eq 0 ]
    [[ "$output" != *"branch noup4"* ]]
}

@test "unattached branch tracking origin/master whose content shipped is not reported" {
    git -C "$work" branch --quiet --track sq1 origin/master
    make_unattached_commit sq1
    echo sq1 >"$work/sq1.txt"
    git -C "$work" add sq1.txt
    git -C "$work" commit --quiet -m 'feat: squash of sq1'
    git -C "$work" push --quiet origin master
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" != *"branch sq1"* ]]
}

# --- dotfiles-linux-dev#1080 gap 2: phantom dirty index ---

# Worktree wtS sits on branch stale1 at commit S1; a second (throwaway) worktree then
# advances the same branch to S2, so wtS keeps an index that is the reverse of S2.
advance_branch_elsewhere() {
    local branch="$1" other="$BATS_TEST_TMPDIR/other-$1"
    git -C "$work" worktree add --quiet --detach "$other" "$branch"
    echo newer >"$other/newer.txt"
    git -C "$other" add newer.txt
    git -C "$other" commit --quiet -m 'feat: newer commit'
    git -C "$work" update-ref "refs/heads/$branch" "$(git -C "$other" rev-parse HEAD)"
    git -C "$work" worktree remove --force "$other"
}

@test "index equal to an ancestor commit's tree is a stale-index, not interrupted work" {
    wtS="$BATS_TEST_TMPDIR/wtS"
    git -C "$work" worktree add --quiet -b stale1 "$wtS" master
    s1="$(git -C "$wtS" rev-parse --short HEAD)"
    advance_branch_elsewhere stale1
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtS: 1 uncommitted file(s) — stale-index (== $s1)"* ]]
    [[ "$output" != *"INTERRUPTED WORK"* ]]
}

# --- dotfiles-linux-dev#1080 gap 3: content test, not counts ---

@test "dirty edit that reverse-applies to origin/<default> is already shipped" {
    wtH="$BATS_TEST_TMPDIR/wtH"
    git -C "$work" worktree add --quiet --detach "$wtH" origin/master
    echo plus >>"$wtH/file.txt"
    echo plus >>"$work/file.txt"
    git -C "$work" commit --quiet -am 'feat: ship the same edit'
    git -C "$work" push --quiet origin master
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtH: 1 uncommitted file(s) — already on origin/master"* ]]
    [[ "$output" != *"INTERRUPTED WORK"* ]]
}

@test "dirty edit absent from origin/<default> stays interrupted work" {
    wtH="$BATS_TEST_TMPDIR/wtH"
    git -C "$work" worktree add --quiet --detach "$wtH" origin/master
    echo plus >>"$wtH/file.txt"
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtH: 1 uncommitted file(s) — INTERRUPTED WORK"* ]]
}

@test "a worktree whose path no longer exists is skipped without error" {
    wtX="$BATS_TEST_TMPDIR/wtX"
    git -C "$work" worktree add --quiet --detach "$wtX" origin/master
    rm -rf "$wtX"
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" != *"wtX"* ]]
}

@test "stale-index detection works while the worktree's index.lock is held and leaves the index alone" {
    wtS="$BATS_TEST_TMPDIR/wtS"
    git -C "$work" worktree add --quiet -b stale3 "$wtS" master
    advance_branch_elsewhere stale3
    idx="$(git -C "$wtS" rev-parse --path-format=absolute --git-path index)"
    before="$(stat -c %Y-%s "$idx")"
    : >"$idx.lock"
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtS: 1 uncommitted file(s) — stale-index"* ]]
    [ "$(stat -c %Y-%s "$idx")" = "$before" ]
}

@test "genuine staged work is not mistaken for a stale-index" {
    wtS="$BATS_TEST_TMPDIR/wtS"
    git -C "$work" worktree add --quiet -b stale2 "$wtS" master
    echo real >"$wtS/real.txt"
    git -C "$wtS" add real.txt
    run fanout_worktrees "$work" 0 '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree wtS: 1 uncommitted file(s) — INTERRUPTED WORK"* ]]
    [[ "$output" != *"stale-index"* ]]
}
