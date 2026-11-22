#!/usr/bin/env bats
#
# dotfiles-linux-dev#1081: primary_checkout_subagent_guard.sh and the core.bare check in
# worktree_fanout.sh. Real repos, no git stubs: the predicates ARE git plumbing.

setup() {
    GUARD="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/primary_checkout_subagent_guard.sh"
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/worktree_fanout.sh"
    bare="$BATS_TEST_TMPDIR/origin.git"
    work="$BATS_TEST_TMPDIR/work"
    wt="$BATS_TEST_TMPDIR/wt"
    git init --quiet --bare -b master "$bare"
    git clone --quiet "$bare" "$work" 2>/dev/null
    git -C "$work" config user.email t@example.com
    git -C "$work" config user.name t
    echo one >"$work/f"
    git -C "$work" add f
    git -C "$work" commit --quiet -m 'chore: init'
    git -C "$work" push --quiet origin master
    git -C "$work" worktree add --quiet -b feat "$wt" master
}

payload() { # <cwd> <command> [agent_id]
    jq -nc --arg cwd "$1" --arg c "$2" --arg a "${3:-}" \
        '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}} + (if $a=="" then {} else {agent_id:$a} end)'
}

@test "subagent reset in primary on default branch is blocked" {
    run bash "$GUARD" <<<"$(payload "$work" 'git reset --hard origin/feat' agent1)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"PRIMARY checkout"* ]]
}

@test "subagent checkout of a branch in primary is blocked" {
    run bash "$GUARD" <<<"$(payload "$work" 'git checkout feat' agent1)"
    [ "$status" -eq 2 ]
}

@test "main session (no agent_id) is not blocked" {
    run bash "$GUARD" <<<"$(payload "$work" 'git reset --hard HEAD' '')"
    [ "$status" -eq 0 ]
}

@test "subagent in its own worktree is not blocked" {
    run bash "$GUARD" <<<"$(payload "$wt" 'git reset --hard HEAD' agent1)"
    [ "$status" -eq 0 ]
}

@test "file-restoring checkout in primary is allowed" {
    run bash "$GUARD" <<<"$(payload "$work" 'git checkout -- f' agent1)"
    [ "$status" -eq 0 ]
}

@test "escape hatch stands the guard aside" {
    run bash "$GUARD" <<<"$(payload "$work" 'ALLOW_PRIMARY_CHECKOUT_MOVE=1 git reset --hard HEAD' agent1)"
    [ "$status" -eq 0 ]
}

@test "unrelated git command is not blocked" {
    run bash "$GUARD" <<<"$(payload "$work" 'git status' agent1)"
    [ "$status" -eq 0 ]
}

@test "fanout reports a primary checkout whose core.bare flipped to true" {
    git -C "$work" config core.bare true
    run fanout_primary_bare_check "$wt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PRIMARY CHECKOUT BROKEN"* ]]
    [[ "$output" == *"core.bare false"* ]]
}

@test "fanout is silent on a healthy primary checkout" {
    run fanout_primary_bare_check "$wt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "absolute git executable is recognised" {
    run bash "$GUARD" <<<"$(payload "$work" '/usr/bin/git reset --hard HEAD~1' agent1)"
    [ "$status" -eq 2 ]
}

@test "file-restoring checkout does not exempt a chained reset" {
    run bash "$GUARD" <<<"$(payload "$work" 'git checkout -- f && git reset --hard HEAD~1' agent1)"
    [ "$status" -eq 2 ]
}

@test "git -C naming the primary from a worktree cwd is blocked" {
    run bash "$GUARD" <<<"$(payload "$wt" "git -C $work reset --hard HEAD~1" agent1)"
    [ "$status" -eq 2 ]
}

@test "cd into the primary then a move is blocked" {
    run bash "$GUARD" <<<"$(payload "$wt" "cd $work && git checkout feat" agent1)"
    [ "$status" -eq 2 ]
}

@test "git -C naming the agent's own worktree from the primary cwd is allowed" {
    run bash "$GUARD" <<<"$(payload "$work" "git -C $wt reset --hard HEAD" agent1)"
    [ "$status" -eq 0 ]
}

@test "fanout is silent for a deliberately bare repo with worktrees" {
    git -C "$bare" worktree add --quiet -b g "$BATS_TEST_TMPDIR/bwt" master
    run fanout_primary_bare_check "$BATS_TEST_TMPDIR/bwt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
