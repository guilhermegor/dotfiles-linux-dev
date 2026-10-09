#!/usr/bin/env bats
#
# bin/rename_checkout.sh (dotfiles-linux-dev#661): the one-time rename of the checkout dir.
#
# Every test builds a throwaway "checkout" + Claude config dir + fake /proc under
# BATS_TEST_TMPDIR and points the script at them through DOTFILES_DIR / CLAUDE_CONFIG_DIR /
# PROC_DIR / HOME. --apply is only ever run against that fixture (run_apply refuses any
# checkout outside the temp dir) -- never the real checkout or the real ~/.claude.
#
# Run locally:  bats tests/

setup() {
    SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/bin/rename_checkout.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    PARENT="$HOME/github"
    OLD="$PARENT/old-name"
    NEW="$PARENT/new-name"
    CLAUDE="$HOME/.claude"
    PROC="$BATS_TEST_TMPDIR/proc"
    export REDEPLOY_LOG="$BATS_TEST_TMPDIR/redeploy.log"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

    mkdir -p "$PROC" "$CLAUDE" "$OLD/ai_clients/claude"
    git init -q "$OLD"
    printf '.claude/worktrees/\n' > "$OLD/.gitignore"
    printf '#!/bin/bash\necho "DOTFILES_DIR=$DOTFILES_DIR args=$*" >> "$REDEPLOY_LOG"\n' \
        > "$OLD/ai_clients/claude/main.sh"
    git -C "$OLD" add -A
    git -C "$OLD" -c core.hooksPath=/dev/null commit -q -m init
    git -C "$OLD" worktree add -q "$OLD/.claude/worktrees/agent-1" -b agent-1

    KEY_OLD="$(printf '%s' "$OLD" | tr '/.' '--')"
    KEY_NEW="$(printf '%s' "$NEW" | tr '/.' '--')"
    mkdir -p "$CLAUDE/projects/$KEY_OLD/memory" "$CLAUDE/projects/${KEY_OLD}--claude-worktrees-agent-1"
    cat > "$CLAUDE/projects/$KEY_OLD/memory/note.md" <<EOF
tilde: ~/github/old-name/ai_clients
home: \$HOME/github/old-name
abs: $OLD/bin
key: $KEY_OLD/memory
name only: old-name#68 and Origin: old-name
longer name: github/old-name-tools/x
EOF
    printf 'old-name github\nother github\n' > "$CLAUDE/issue-trackers.conf"
}

# Runs from OUTSIDE the checkout, like the real thing.
run_script() {
    run env DOTFILES_DIR="$OLD" CLAUDE_CONFIG_DIR="$CLAUDE" PROC_DIR="$PROC" \
        bash -c 'cd "$HOME" && "$0" "$@"' "$SCRIPT" "$@"
}

run_apply() {
    case "$OLD" in "$BATS_TEST_TMPDIR"/*) ;; *) echo "refusing: fixture is outside the temp dir"; return 1 ;; esac
    run_script --apply "$@"
}

fake_process() {   # fake_process <pid> <cwd> <cmdline>
    mkdir -p "$PROC/$1"
    ln -s "$2" "$PROC/$1/cwd"
    printf 'claude' > "$PROC/$1/comm"
    printf '%s\0' $3 > "$PROC/$1/cmdline"
}

assert_untouched() {
    [ -d "$OLD" ] && [ ! -L "$OLD" ]
    [ ! -e "$NEW" ]
    [ -d "$CLAUDE/projects/$KEY_OLD" ]
    [ ! -e "$CLAUDE/projects/$KEY_NEW" ]
    grep -q '^old-name github' "$CLAUDE/issue-trackers.conf"
    grep -qF "~/github/old-name/ai_clients" "$CLAUDE/projects/$KEY_OLD/memory/note.md"
    [ ! -e "$REDEPLOY_LOG" ]
}

# ── dry-run is the default and changes nothing ───────────────────────────────

@test "no flag means dry-run: reports the plan with a diff and touches nothing" {
    run_script new-name
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"mode: dry-run"* ]]
    [[ "$output" == *"+tilde: ~/github/new-name/ai_clients"* ]]
    [[ "$output" == *"+new-name github"* ]]
    assert_untouched
}

@test "dry-run lists stale worktree project dirs without moving them" {
    run_script --dry-run new-name
    [[ "$output" == *"${KEY_OLD}--claude-worktrees-agent-1"* ]]
    [ -d "$CLAUDE/projects/${KEY_OLD}--claude-worktrees-agent-1" ]
}

@test "dry-run reports other repos that mention the old path" {
    git init -q "$PARENT/other-repo"
    printf 'see ~/github/old-name/x\n' > "$PARENT/other-repo/README.md"
    git -C "$PARENT/other-repo" add README.md
    run_script new-name
    [[ "$output" == *"$PARENT/other-repo"* ]]
    [[ "$output" == *"README.md"* ]]
}

# ── argument handling ────────────────────────────────────────────────────────

@test "no <new-dir> prints usage and exits 2" {
    run_script
    [ "$status" -eq 2 ]
}

@test "a <new-dir> in a different parent is refused (this is a rename, not a move)" {
    run_script /elsewhere/new-name
    [ "$status" -eq 2 ]
    [[ "$output" == *"same parent"* ]]
}

@test "an unknown option is refused" {
    run_script --force new-name
    [ "$status" -eq 2 ]
}

# ── preconditions ────────────────────────────────────────────────────────────

@test "a process with its cwd inside the checkout blocks, in dry-run and apply" {
    fake_process 4242 "$OLD/.claude/worktrees/agent-1" "claude"
    run_script new-name
    [ "$status" -eq 1 ]
    [[ "$output" == *"process 4242"*"cwd inside the checkout"* ]]

    run_apply new-name
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to --apply"* ]]
    assert_untouched
}

@test "a process whose command line names the old path blocks" {
    fake_process 4243 "/" "tail -f $OLD/some.log"
    run_script new-name
    [ "$status" -eq 1 ]
    [[ "$output" == *"process 4243 depends on the old path"* ]]
}

@test "an unrelated process does not block" {
    fake_process 4244 "/" "sleep 100"
    run_script new-name
    [ "$status" -eq 0 ]
}

@test "a worktree with uncommitted work blocks" {
    printf 'wip\n' > "$OLD/.claude/worktrees/agent-1/wip.txt"
    run_script new-name
    [ "$status" -eq 1 ]
    [[ "$output" == *"agent-1 has 1 uncommitted path"* ]]
    run_apply new-name
    [ "$status" -ne 0 ]
    assert_untouched
}

@test "uncommitted work in the checkout itself blocks" {
    printf 'wip\n' > "$OLD/wip.txt"
    run_script new-name
    [ "$status" -eq 1 ]
}

@test "running from inside the checkout blocks" {
    run env DOTFILES_DIR="$OLD" CLAUDE_CONFIG_DIR="$CLAUDE" PROC_DIR="$PROC" \
        bash -c 'cd "$1" && "$0" new-name' "$SCRIPT" "$OLD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"run from outside the checkout"* ]]
}

@test "an existing target directory blocks" {
    mkdir "$NEW"
    run_script new-name
    [ "$status" -eq 1 ]
    [[ "$output" == *"target already exists"* ]]
}

@test "an existing Claude project dir for the new name blocks (no merge)" {
    mkdir -p "$CLAUDE/projects/$KEY_NEW"
    run_script new-name
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to merge"* ]]
}

# ── --apply, against the fixture only ────────────────────────────────────────

@test "apply moves the checkout, the project memory, rewrites paths and leaves a symlink" {
    run_apply new-name
    [ "$status" -eq 0 ] || { echo "$output"; false; }

    [ -d "$NEW/.git" ]
    [ -L "$OLD" ] && [ "$(readlink "$OLD")" = "$NEW" ]

    [ ! -e "$CLAUDE/projects/$KEY_OLD" ]
    local note="$CLAUDE/projects/$KEY_NEW/memory/note.md"
    [ -f "$note" ]
    grep -qF "tilde: ~/github/new-name/ai_clients" "$note"
    grep -qF "home: \$HOME/github/new-name" "$note"
    grep -qF "abs: $NEW/bin" "$note"
    grep -qF "key: $KEY_NEW/memory" "$note"
    # paths only: bare names and a longer name are left alone
    grep -qF "name only: old-name#68 and Origin: old-name" "$note"
    grep -qF "longer name: github/old-name-tools/x" "$note"

    # stale worktree key dirs are listed, never moved
    [ -d "$CLAUDE/projects/${KEY_OLD}--claude-worktrees-agent-1" ]
    [ ! -e "$CLAUDE/projects/${KEY_NEW}--claude-worktrees-agent-1" ]
}

@test "apply repairs the linked worktrees so they resolve at the new location" {
    run_apply new-name
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run git -C "$NEW/.claude/worktrees/agent-1" rev-parse --path-format=absolute --git-common-dir
    [ "$status" -eq 0 ]
    [ "$output" = "$NEW/.git" ]
    [ -z "$(git -C "$NEW/.claude/worktrees/agent-1" status --porcelain)" ]
}

@test "apply renames only the matching issue-trackers.conf entry" {
    run_apply new-name
    [ "$status" -eq 0 ]
    [ "$(cat "$CLAUDE/issue-trackers.conf")" = "$(printf 'new-name github\nother github')" ]
}

@test "apply redeploys settings, hooks, skills and CLAUDE.md from the NEW location" {
    run_apply new-name
    [ "$status" -eq 0 ]
    [ "$(cat "$REDEPLOY_LOG")" = "DOTFILES_DIR=$NEW args=settings hooks skills claude_md" ]
}

@test "apply ends by reporting no leftover reference to the old path" {
    run_apply new-name
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 references to the old path"* ]]
}

@test "apply prints leftovers instead of hiding them" {
    mkdir -p "$CLAUDE/hooks"
    printf 'cd ~/github/old-name\n' > "$CLAUDE/hooks/stale.sh"
    run_apply new-name
    [ "$status" -eq 0 ]
    [[ "$output" == *"still reference the old path"* ]]
    [[ "$output" == *"$CLAUDE/hooks/stale.sh"* ]]
}
