#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/worktree_prune.sh (dotfiles-linux-dev#882).
# Real fixture repos (a local bare origin plus real worktrees), never the user's worktrees.
# The forge read is the one stubbed seam: prune_pr_state is redefined after sourcing.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/worktree_prune.sh"
    export WORKTREE_PRUNE_MIN_AGE=0
    PR_STATE=merged
    GATE_OK=1
    stub_forge

    bare="$BATS_TEST_TMPDIR/origin.git"
    work="$BATS_TEST_TMPDIR/work"
    git init --quiet --bare -b master "$bare"
    git clone --quiet "$bare" "$work" 2>/dev/null
    git -C "$work" config user.email test@example.com
    git -C "$work" config user.name test
    echo one >"$work/file.txt"
    git -C "$work" add file.txt
    git -C "$work" commit --quiet -m 'chore: initial'
    git -C "$work" push --quiet origin master
    git -C "$work" remote set-head origin -a >/dev/null
}

stub_gate() {
    gate_live_agent_surface() {
        if [ "$GATE_OK" = 1 ]; then LIVE_AGENT_STATUS=ok; LIVE_AGENT_PATHS=""; return 0; fi
        LIVE_AGENT_STATUS=unknown
        return 1
    }
}

stub_forge() {
    stub_gate
    prune_pr_state() {
        [ "$PR_STATE" = unreadable ] && return 1
        echo "$PR_STATE"
    }
    # Emits "<branch><TAB><sha>" for the sha in MERGED_HEAD_SHA (a command); default none.
    MERGED_HEAD_SHA=""
    prune_merged_heads() {
        [ "$PR_STATE" = unreadable ] && return 1
        [ -z "$MERGED_HEAD_SHA" ] || printf '%s\t%s\n' "$2" "$(eval "$MERGED_HEAD_SHA")"
        return 0
    }
}

# make_branch <name> <file> : worktree on a pushed branch adding <file>.
make_branch() {
    local name="$1" file="$2" wt="$BATS_TEST_TMPDIR/wt-$1"
    git -C "$work" worktree add --quiet -b "$name" "$wt" origin/master
    echo "content-$file" >"$wt/$file"
    git -C "$wt" add "$file"
    git -C "$wt" commit --quiet -m "feat: add $file"
    git -C "$wt" push --quiet -u origin "$name" 2>/dev/null
}

# land_on_master <file> : the same content reaches master under a different commit (a squash).
land_on_master() {
    echo "content-$1" >"$work/$1"
    git -C "$work" add "$1"
    git -C "$work" commit --quiet -m "feat: squash $1"
    git -C "$work" push --quiet origin master
    git -C "$work" fetch --quiet origin
}

run_prune() { run prune_worktrees "$work" "${1:-0}"; }

@test "squash-merged branch with only __pycache__ is prunable but dry-run removes nothing" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    mkdir "$BATS_TEST_TMPDIR/wt-b1/__pycache__"
    echo x >"$BATS_TEST_TMPDIR/wt-b1/__pycache__/m.pyc"
    run_prune 0
    [[ "$output" == *"WOULD-PRUNE $BATS_TEST_TMPDIR/wt-b1 [b1]"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b1" ]
    git -C "$work" rev-parse --verify --quiet refs/heads/b1
}

@test "--apply removes worktree, local branch and origin branch" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    mkdir "$BATS_TEST_TMPDIR/wt-b1/.venv"
    echo x >"$BATS_TEST_TMPDIR/wt-b1/.venv/a"
    run_prune 1
    [[ "$output" == *"PRUNED $BATS_TEST_TMPDIR/wt-b1 [b1]"* ]]
    [ ! -d "$BATS_TEST_TMPDIR/wt-b1" ]
    run git -C "$work" rev-parse --verify --quiet refs/heads/b1
    [ "$status" -ne 0 ]
    [ -z "$(git -C "$work" ls-remote origin refs/heads/b1)" ]
}

@test "real staged work is kept" {
    make_branch b2 f2.txt
    land_on_master f2.txt
    echo new >"$BATS_TEST_TMPDIR/wt-b2/real.txt"
    git -C "$BATS_TEST_TMPDIR/wt-b2" add real.txt
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b2: staged work not in branch history"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b2" ]
}

@test "untracked file that is not build noise is kept" {
    make_branch b2 f2.txt
    land_on_master f2.txt
    echo new >"$BATS_TEST_TMPDIR/wt-b2/notes.txt"
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b2: untracked notes.txt"* ]]
}

@test "a stale index equal to an older commit of the branch is prunable" {
    make_branch b3 f3.txt
    local wt="$BATS_TEST_TMPDIR/wt-b3"
    echo more >"$wt/f3b.txt"
    git -C "$wt" add f3b.txt
    git -C "$wt" commit --quiet -m 'feat: add f3b'
    git -C "$wt" push --quiet origin b3 2>/dev/null
    land_on_master f3.txt
    echo more >"$work/f3b.txt"
    git -C "$work" add f3b.txt
    git -C "$work" commit --quiet -m 'feat: squash f3b'
    git -C "$work" push --quiet origin master
    git -C "$work" fetch --quiet origin
    git -C "$wt" read-tree -u --reset HEAD~1
    [ -n "$(git -C "$wt" status --porcelain)" ]
    run_prune 0
    [[ "$output" == *"WOULD-PRUNE $wt [b3]"* ]]
}

@test "content not on origin master is kept even when the PR is merged" {
    make_branch b4 f4.txt
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b4: content not on origin/master"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b4" ]
}

# master edits the squashed file afterwards, so the byte-identical test can never pass again.
edit_on_master() {
    echo "later-$1" >"$work/$1"
    git -C "$work" commit --quiet -am "fix: edit $1 later"
    git -C "$work" push --quiet origin master
    git -C "$work" fetch --quiet origin
}

@test "tip equal to the merged PR head is shipped although master moved on" {
    make_branch b4a f4a.txt
    land_on_master f4a.txt
    edit_on_master f4a.txt
    MERGED_HEAD_SHA="git -C '$BATS_TEST_TMPDIR/wt-b4a' rev-parse HEAD"
    run_prune 0
    [[ "$output" == *"WOULD-PRUNE $BATS_TEST_TMPDIR/wt-b4a [b4a]"* ]]
}

@test "tip behind the merged PR head (head moved past local) is shipped" {
    make_branch b4b f4b.txt
    local wt="$BATS_TEST_TMPDIR/wt-b4b" old newhead
    old="$(git -C "$wt" rev-parse HEAD)"
    echo x >"$wt/extra.txt"
    git -C "$wt" add extra.txt
    git -C "$wt" commit --quiet -m 'fix: later push'
    newhead="$(git -C "$wt" rev-parse HEAD)"
    git -C "$wt" reset --quiet --hard "$old"
    land_on_master f4b.txt
    edit_on_master f4b.txt
    MERGED_HEAD_SHA="echo $newhead"
    run_prune 0
    [[ "$output" == *"WOULD-PRUNE $wt [b4b]"* ]]
}

@test "local commits past the merged PR head stay KEEP" {
    make_branch b4e f4e.txt
    local wt="$BATS_TEST_TMPDIR/wt-b4e" merged
    merged="$(git -C "$wt" rev-parse HEAD)"
    land_on_master f4e.txt
    edit_on_master f4e.txt
    echo later >"$wt/later.txt"
    git -C "$wt" add later.txt
    git -C "$wt" commit --quiet -m 'feat: after the merge'
    MERGED_HEAD_SHA="echo $merged"
    run_prune 1
    [[ "$output" == *"KEEP $wt: content not on origin/master"* ]]
    [ -d "$wt" ]
}

@test "prune_merged_heads keeps only PRs merged into the default branch" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/worktree_prune.sh"
    fanout_repo_slug() { echo o/r; }
    gh() {
        cat <<'JSON'
[{"merged_at":"2026-01-01T00:00:00Z","base":{"ref":"master"},"head":{"sha":"HEADONE"}},
 {"merged_at":"2026-01-01T00:00:00Z","base":{"ref":"release"},"head":{"sha":"HEADTWO"}},
 {"merged_at":null,"base":{"ref":"master"},"head":{"sha":"HEADTHREE"}}]
JSON
    }
    run prune_merged_heads "$work" b1 master
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'b1\tHEADONE')" ]
}

@test "prune_merged_heads reports a forge failure" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/worktree_prune.sh"
    fanout_repo_slug() { echo o/r; }
    gh() { return 1; }
    run prune_merged_heads "$work" b1 master
    [ "$status" -eq 1 ]
}

@test "tip only in a closed-unmerged PR head stays KEEP" {
    make_branch b4c f4c.txt
    land_on_master f4c.txt
    edit_on_master f4c.txt
    PR_STATE=closed
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b4c: content not on origin/master"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b4c" ]
}

@test "unreadable forge on the merged-head path keeps the worktree" {
    make_branch b4d f4d.txt
    land_on_master f4d.txt
    edit_on_master f4d.txt
    PR_STATE=unreadable
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b4d: forge unreadable"* ]]
}

@test "an OPEN PR keeps the worktree" {
    make_branch b5 f5.txt
    land_on_master f5.txt
    PR_STATE=open
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b5: PR is OPEN"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b5" ]
}

@test "an unreadable forge keeps the worktree" {
    make_branch b6 f6.txt
    land_on_master f6.txt
    PR_STATE=unreadable
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b6: forge unreadable"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b6" ]
}

@test "the real forge reader fails closed on a non-GitHub origin" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/worktree_prune.sh"
    stub_gate
    make_branch b6 f6.txt
    land_on_master f6.txt
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b6: forge unreadable"* ]]
}

@test "a remote branch holding a commit the local one lacks keeps everything" {
    make_branch b7 f7.txt
    land_on_master f7.txt
    local other="$BATS_TEST_TMPDIR/other"
    git clone --quiet "$bare" "$other" 2>/dev/null
    git -C "$other" config user.email t@e.com
    git -C "$other" config user.name t
    git -C "$other" checkout --quiet b7
    echo extra >"$other/extra.txt"
    git -C "$other" add extra.txt
    git -C "$other" commit --quiet -m 'feat: extra'
    git -C "$other" push --quiet origin b7 2>/dev/null
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b7: origin/b7 sha differs"* ]]
    [ -n "$(git -C "$work" ls-remote origin refs/heads/b7)" ]
}

@test "the current worktree and the main worktree are never pruned" {
    make_branch b8 f8.txt
    land_on_master f8.txt
    run prune_worktrees "$BATS_TEST_TMPDIR/wt-b8" 1
    [ -d "$BATS_TEST_TMPDIR/wt-b8" ]
    [ -d "$work" ]
}

@test "a recently touched worktree is kept as a possible live agent" {
    make_branch b9 f9.txt
    land_on_master f9.txt
    WORKTREE_PRUNE_MIN_AGE=3600
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b9: touched within"* ]]
}

@test "WORKTREE_PRUNE_APPLY=1 turns on apply through main" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    WORKTREE_PRUNE_APPLY=1 run main "$work"
    [ ! -d "$BATS_TEST_TMPDIR/wt-b1" ]
}

@test "an UNKNOWN live-agent surface keeps every worktree and fails" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    GATE_OK=0
    run_prune 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"live-agent surface UNKNOWN"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b1" ]
}

@test "a fresh branch at origin tip with no commits is kept" {
    git -C "$work" worktree add --quiet -b fresh "$BATS_TEST_TMPDIR/wt-fresh" origin/master
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-fresh: no commits beyond merge-base"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-fresh" ]
}

@test "a locked worktree is kept" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    git -C "$work" worktree lock "$BATS_TEST_TMPDIR/wt-b1"
    run_prune 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b1: locked"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b1" ]
}

@test "an ignored .env is kept but an ignored build dir is not" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    printf '.env\nbuild/\n' >>"$work/.git/info/exclude"
    mkdir "$BATS_TEST_TMPDIR/wt-b1/build"
    echo x >"$BATS_TEST_TMPDIR/wt-b1/build/o"
    run_prune 0
    [[ "$output" == *"WOULD-PRUNE $BATS_TEST_TMPDIR/wt-b1"* ]]
    echo SECRET >"$BATS_TEST_TMPDIR/wt-b1/.env"
    run_prune 0
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b1: ignored file .env (secret-shaped)"* ]]
}

@test "a worktree reached through a symlinked path is still recognised as self" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    ln -s "$BATS_TEST_TMPDIR/wt-b1" "$BATS_TEST_TMPDIR/link"
    run prune_worktrees "$BATS_TEST_TMPDIR/link" 1
    [ -d "$BATS_TEST_TMPDIR/wt-b1" ]
}

@test "a branch name with special characters is URL-encoded" {
    enc="$(jq -rn --arg b 'me:feat/a&b#c+d' '$b|@uri')"
    [[ "$enc" == "me%3Afeat%2Fa%26b%23c%2Bd" ]]
}

@test "an unreadable origin is a failure that prunes nothing" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    git -C "$work" remote set-url origin "$BATS_TEST_TMPDIR/gone.git"
    run prune_apply_one "$work" "$BATS_TEST_TMPDIR/wt-b1" b1 "$(git -C "$BATS_TEST_TMPDIR/wt-b1" rev-parse HEAD)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"remote unreadable"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b1" ]
    [ -n "$(git -C "$work" rev-parse --verify --quiet refs/heads/b1)" ]
    [ -n "$(git -C "$bare" rev-parse --verify --quiet refs/heads/b1)" ]
}

@test "the remote delete is refused when origin moved after classification" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    local other="$BATS_TEST_TMPDIR/other"
    git clone --quiet "$bare" "$other" 2>/dev/null
    git -C "$other" config user.email t@e.com
    git -C "$other" config user.name t
    git -C "$other" checkout --quiet b1
    echo extra >"$other/extra.txt"
    git -C "$other" add extra.txt
    git -C "$other" commit --quiet -m 'feat: extra'
    git -C "$other" push --quiet origin b1 2>/dev/null
    run prune_apply_one "$work" "$BATS_TEST_TMPDIR/wt-b1" b1 "$(git -C "$BATS_TEST_TMPDIR/wt-b1" rev-parse HEAD)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"remote moved, nothing pruned"* ]]
    [ -d "$BATS_TEST_TMPDIR/wt-b1" ]
    [ -n "$(git -C "$work" rev-parse --verify --quiet refs/heads/b1)" ]
    [ -n "$(git -C "$work" ls-remote origin refs/heads/b1)" ]
}

@test "a worktree whose directory is gone is dropped by git worktree prune on apply" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    rm -rf "$BATS_TEST_TMPDIR/wt-b1"
    run_prune 0
    [[ "$output" == *"WOULD-PRUNE-ENTRY"* ]]
    run_prune 1
    [ -z "$(git -C "$work" worktree list --porcelain | grep wt-b1)" ]
}

@test "a commit landing after classification prunes nothing" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    local wt="$BATS_TEST_TMPDIR/wt-b1" classified
    classified="$(git -C "$wt" rev-parse HEAD)"
    git -C "$wt" commit --quiet --allow-empty -m 'feat: unshipped'
    run prune_apply_one "$work" "$wt" b1 "$classified"
    [ "$status" -ne 0 ]
    [[ "$output" == *"HEAD moved since classification, nothing pruned"* ]]
    [ -d "$wt" ]
    [ -n "$(git -C "$bare" rev-parse --verify --quiet refs/heads/b1)" ]
}

@test "an edit landing after classification prunes nothing" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    local wt="$BATS_TEST_TMPDIR/wt-b1"
    echo late >"$wt/late.txt"
    run prune_apply_one "$work" "$wt" b1 "$(git -C "$wt" rev-parse HEAD)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing pruned"* ]]
    [ -f "$wt/late.txt" ]
}

# Real git against an ssh:// URL, with ssh itself replaced by a script that names who called it.
fake_ssh_setup() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/bash\necho "FAKE-SSH $*" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/ssh"
    chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    unset GIT_SSH GIT_SSH_COMMAND
}

@test "the batch default is used when no ssh setting exists" {
    fake_ssh_setup
    run prune_git_remote "$work" ls-remote ssh://host/repo
    [[ "$output" == *"FAKE-SSH -oBatchMode=yes "* ]]
}

@test "a configured core.sshCommand is not overridden by the batch default" {
    fake_ssh_setup
    git -C "$work" config core.sshCommand 'echo CONFIG-SSH >&2; false'
    run prune_git_remote "$work" ls-remote ssh://host/repo
    [[ "$output" == *"CONFIG-SSH"* ]]
    [[ "$output" != *"FAKE-SSH"* ]]
}

@test "an exported empty GIT_SSH_COMMAND does not mask core.sshCommand" {
    fake_ssh_setup
    git -C "$work" config core.sshCommand 'echo CONFIG-SSH >&2; false'
    export GIT_SSH_COMMAND=""
    run prune_git_remote "$work" ls-remote ssh://host/repo
    [[ "$output" == *"CONFIG-SSH"* ]]
    [[ "$output" != *"cannot run"* ]]
    # the caller's own environment is left as it was
    [ "${GIT_SSH_COMMAND-UNSET}" = "" ]
}

@test "a configured GIT_SSH wrapper is not replaced by the batch default" {
    fake_ssh_setup
    printf '#!/bin/bash\necho "WRAPPER $*" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/wrapper"
    chmod +x "$BATS_TEST_TMPDIR/wrapper"
    export GIT_SSH="$BATS_TEST_TMPDIR/wrapper"
    run prune_git_remote "$work" ls-remote ssh://host/repo
    [[ "$output" == *"WRAPPER"* ]]
    [[ "$output" != *"FAKE-SSH"* ]]
}

@test "a probe killed with no stderr still names its exit code" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    local wt="$BATS_TEST_TMPDIR/wt-b1"
    prune_git_remote() { return 124; }
    run prune_apply_one "$work" "$wt" b1 "$(git -C "$wt" rev-parse HEAD)"
    [ "$status" -ne 0 ]
    [ "$output" = "remote unreadable (exit 124), nothing pruned" ]
}

@test "a refusal that pruned nothing is reported KEEP, never PARTIAL" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    prune_apply_one() { echo "remote moved, nothing pruned"; return 1; }
    run prune_worktrees "$work" 1
    [[ "$output" == *"KEEP $BATS_TEST_TMPDIR/wt-b1: remote moved, nothing pruned"* ]]
    [[ "$output" != *PARTIAL* ]]
}

@test "the lease refuses a push landing after the probe and keeps origin" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    local other="$BATS_TEST_TMPDIR/other" wt="$BATS_TEST_TMPDIR/wt-b1" head moved
    head="$(git -C "$wt" rev-parse HEAD)"
    git clone --quiet "$bare" "$other" 2>/dev/null
    git -C "$other" config user.email t@e.com
    git -C "$other" config user.name t
    git -C "$other" checkout --quiet b1
    git -C "$other" commit --quiet --allow-empty -m 'feat: raced'
    moved="$(git -C "$other" rev-parse HEAD)"
    # pre-push runs after the probe, so origin moves exactly inside the window the lease guards.
    # A global core.hooksPath would bypass the repo's own hooks dir: pin it to the one written below.
    git -C "$work" config core.hooksPath "$work/.git/hooks"
    printf '#!/bin/bash\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE\ngit -C "%s" push --quiet origin b1\n' "$other" \
        >"$work/.git/hooks/pre-push"
    chmod +x "$work/.git/hooks/pre-push"
    run prune_apply_one "$work" "$wt" b1 "$head"
    [ "$status" -ne 0 ]
    [[ "$output" == *"origin/b1 state unconfirmed; deleted local branch was at $head"* ]]
    [ "$(git -C "$bare" rev-parse refs/heads/b1)" = "$moved" ]
}

@test "the probe ignores a branch that only tail-matches the name" {
    make_branch b1 f1.txt
    land_on_master f1.txt
    local wt="$BATS_TEST_TMPDIR/wt-b1" head
    head="$(git -C "$wt" rev-parse HEAD)"
    git -C "$wt" push --quiet origin --delete b1 2>/dev/null
    git -C "$work" push --quiet origin "master:refs/heads/x/refs/heads/b1" 2>/dev/null
    run prune_apply_one "$work" "$wt" b1 "$head"
    [ "$status" -eq 0 ]
    [ ! -d "$wt" ]
    [ -n "$(git -C "$bare" rev-parse --verify --quiet refs/heads/x/refs/heads/b1)" ]
}

@test "a detached worktree is removed without any remote call" {
    local wt="$BATS_TEST_TMPDIR/wt-det"
    git -C "$work" worktree add --quiet --detach "$wt" origin/master
    git -C "$work" remote set-url origin "$BATS_TEST_TMPDIR/gone.git"
    run prune_apply_one "$work" "$wt" "" "$(git -C "$wt" rev-parse HEAD)"
    [ "$status" -eq 0 ]
    [ ! -d "$wt" ]
}

@test "a branch never pushed is pruned locally with no remote delete" {
    local wt="$BATS_TEST_TMPDIR/wt-lo"
    git -C "$work" worktree add --quiet -b lo "$wt" origin/master
    run prune_apply_one "$work" "$wt" lo "$(git -C "$wt" rev-parse HEAD)"
    [ "$status" -eq 0 ]
    [ ! -d "$wt" ]
    [ -z "$(git -C "$work" rev-parse --verify --quiet refs/heads/lo)" ]
}
