#!/usr/bin/env bats
#
# Tests for ai_clients/claude/hooks/ai_state_sync.sh (dotfiles-linux-dev#655): the private
# AI-state repo sync behind the SessionStart/SessionEnd hooks, the `state_sync` step, and the
# standalone `ai-state-sync` command. Every test uses a throwaway HOME and a LOCAL bare repo as
# the remote -- never the real ~/.claude, never a real remote.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SYNC="$REPO_ROOT/ai_clients/claude/hooks/ai_state_sync.sh"
    T="$BATS_TEST_TMPDIR"
    export HOME="$T/home"
    export CLAUDE_CONFIG_DIR="$HOME/.claude"
    export AI_STATE_REMOTE="$T/remote.git"
    export AI_STATE_GIT_DIR="$HOME/.ai-clients-state/claude.git"
    export AI_STATE_TIMEOUT=10
    mkdir -p "$CLAUDE_CONFIG_DIR" "$T/bin"
    export GIT_CONFIG_GLOBAL="$T/gitconfig"
    git config --global user.name tester
    git config --global user.email tester@example.invalid
    git config --global init.defaultBranch main

    # notify-send stub: record instead of popping a real desktop notification.
    printf '#!/bin/bash\nprintf "%%s | %%s\\n" "$1" "$2" >> "%s/notify.log"\n' "$T" >"$T/bin/notify-send"
    chmod +x "$T/bin/notify-send"
    export PATH="$T/bin:$PATH"

    git init -q --bare -b main "$AI_STATE_REMOTE"
}

# Put one file into the remote's main branch via a scratch clone.
seed_remote() {
    local path="$1" content="$2"
    git clone -q "$AI_STATE_REMOTE" "$T/seed" 2>/dev/null
    mkdir -p "$T/seed/$(dirname "$path")"
    printf '%s\n' "$content" >"$T/seed/$path"
    git -C "$T/seed" add -A
    git -C "$T/seed" commit -q -m seed
    git -C "$T/seed" push -q origin HEAD:main
    rm -rf "$T/seed"
}

remote_files() {
    git --git-dir="$AI_STATE_REMOTE" ls-tree -r --name-only main 2>/dev/null
}

# A 36-char token body built at runtime so no scannable literal sits in this file.
fake_token() { printf 'ghp_%s' "$(printf 'A%.0s' $(seq 1 36))"; }

# --- setup step ---------------------------------------------------------------------

@test "setup on a fresh machine clones the repo and materialises its files" {
    seed_remote "memory/lessons.md" "remote lesson"
    run bash "$SYNC" setup
    [ "$status" -eq 0 ]
    [ "$(cat "$CLAUDE_CONFIG_DIR/memory/lessons.md")" = "remote lesson" ]
    [ -d "$AI_STATE_GIT_DIR" ]
}

@test "setup refuses to overwrite a live file that differs from the repo copy" {
    seed_remote "tasks/lessons.md" "from the repo"
    mkdir -p "$CLAUDE_CONFIG_DIR/tasks"
    printf 'my local edits\n' >"$CLAUDE_CONFIG_DIR/tasks/lessons.md"
    run bash "$SYNC" setup
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSING"* ]]
    [[ "$output" == *"tasks/lessons.md"* ]]
    [ "$(cat "$CLAUDE_CONFIG_DIR/tasks/lessons.md")" = "my local edits" ]
    [ ! -d "$AI_STATE_GIT_DIR" ]
}

@test "setup accepts a live file that is identical to the repo copy" {
    seed_remote "tasks/lessons.md" "same"
    mkdir -p "$CLAUDE_CONFIG_DIR/tasks"
    printf 'same\n' >"$CLAUDE_CONFIG_DIR/tasks/lessons.md"
    run bash "$SYNC" setup
    [ "$status" -eq 0 ]
    [ -d "$AI_STATE_GIT_DIR" ]
}

@test "setup with no remote prints the gh repo create hint and does nothing" {
    export AI_STATE_REMOTE="$T/does-not-exist.git"
    run bash "$SYNC" setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"gh repo create"*"--private"* ]]
    [ ! -d "$AI_STATE_GIT_DIR" ]
}

@test "the state_sync step installs the standalone ai-state-sync command" {
    export AI_STATE_BIN_DIR="$T/localbin"
    run bash -c "
        print_status() { :; }
        CLAUDE_DIR='$CLAUDE_CONFIG_DIR'
        source '$REPO_ROOT/ai_clients/claude/lib/hooks.sh'
        source '$REPO_ROOT/ai_clients/claude/lib/state_sync.sh'
        setup_state_sync
    "
    [ "$status" -eq 0 ]
    [ -x "$T/localbin/ai-state-sync" ]
}

# --- whitelist ----------------------------------------------------------------------

@test "push commits whitelisted state and never a credential, env file, plugin, or transcript" {
    run bash "$SYNC" setup
    [ "$status" -eq 0 ]
    mkdir -p "$CLAUDE_CONFIG_DIR"/{memory,tasks,specs,plans,plugins,cache}
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/-home-u-repo/memory"
    printf 'm\n' >"$CLAUDE_CONFIG_DIR/memory/a.md"
    printf 't\n' >"$CLAUDE_CONFIG_DIR/tasks/lessons.md"
    printf 's\n' >"$CLAUDE_CONFIG_DIR/specs/s.md"
    printf 'p\n' >"$CLAUDE_CONFIG_DIR/plans/p.md"
    printf 'c\n' >"$CLAUDE_CONFIG_DIR/issue-trackers.conf"
    printf 'pm\n' >"$CLAUDE_CONFIG_DIR/projects/-home-u-repo/memory/MEMORY.md"
    printf 'cred\n' >"$CLAUDE_CONFIG_DIR/.credentials.json"
    printf 'e\n' >"$CLAUDE_CONFIG_DIR/.env"
    printf 'plug\n' >"$CLAUDE_CONFIG_DIR/plugins/x.json"
    printf 'cache\n' >"$CLAUDE_CONFIG_DIR/cache/y"
    printf 'transcript\n' >"$CLAUDE_CONFIG_DIR/projects/-home-u-repo/abc.jsonl"
    printf 'transcript\n' >"$CLAUDE_CONFIG_DIR/projects/-home-u-repo/memory/leak.jsonl"

    run bash "$SYNC" push
    [ "$status" -eq 0 ]
    run remote_files
    [[ "$output" == *"memory/a.md"* ]]
    [[ "$output" == *"tasks/lessons.md"* ]]
    [[ "$output" == *"specs/s.md"* ]]
    [[ "$output" == *"plans/p.md"* ]]
    [[ "$output" == *"issue-trackers.conf"* ]]
    [[ "$output" == *"projects/-home-u-repo/memory/MEMORY.md"* ]]
    [[ "$output" != *".credentials.json"* ]]
    [[ "$output" != *".env"* ]]
    [[ "$output" != *"plugins/"* ]]
    [[ "$output" != *"cache/"* ]]
    [[ "$output" != *".jsonl"* ]]
}

# --- push subcommand ----------------------------------------------------------------

@test "push with nothing changed is a no-op that says so" {
    run bash "$SYNC" setup
    mkdir -p "$CLAUDE_CONFIG_DIR/memory"
    printf 'm\n' >"$CLAUDE_CONFIG_DIR/memory/a.md"
    run bash "$SYNC" push
    [ "$status" -eq 0 ]
    run bash "$SYNC" push
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to push"* ]]
}

@test "push without a TTY reports through notify-send" {
    run bash "$SYNC" setup
    mkdir -p "$CLAUDE_CONFIG_DIR/memory"
    printf 'm\n' >"$CLAUDE_CONFIG_DIR/memory/a.md"
    run bash "$SYNC" push
    [ "$status" -eq 0 ]
    grep -q "pushed" "$T/notify.log"
}

@test "secret guard holds back a planted token, never commits it, and reports it" {
    run bash "$SYNC" setup
    mkdir -p "$CLAUDE_CONFIG_DIR/memory"
    printf 'fine\n' >"$CLAUDE_CONFIG_DIR/memory/ok.md"
    printf 'token=%s\n' "$(fake_token)" >"$CLAUDE_CONFIG_DIR/memory/leaky.md"
    run bash "$SYNC" push
    [ "$status" -ne 0 ]
    [[ "$output" == *"leaky.md"* ]]
    [[ "$output" != *"$(fake_token)"* ]]
    run remote_files
    [[ "$output" == *"memory/ok.md"* ]]
    [[ "$output" != *"leaky.md"* ]]
    run git --git-dir="$AI_STATE_GIT_DIR" log --all -p
    [[ "$output" != *"$(fake_token)"* ]]
}

# --- hooks never block --------------------------------------------------------------

@test "hook push exits 0 and stays silent when the remote is unreachable" {
    run bash "$SYNC" setup
    mkdir -p "$CLAUDE_CONFIG_DIR/memory"
    printf 'm\n' >"$CLAUDE_CONFIG_DIR/memory/a.md"
    git --git-dir="$AI_STATE_GIT_DIR" remote set-url origin "$T/gone.git"
    run bash "$SYNC" push --hook </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook push exits 0 when the secret guard trips" {
    run bash "$SYNC" setup
    mkdir -p "$CLAUDE_CONFIG_DIR/memory"
    printf 'token=%s\n' "$(fake_token)" >"$CLAUDE_CONFIG_DIR/memory/leaky.md"
    run bash "$SYNC" push --hook </dev/null
    [ "$status" -eq 0 ]
    [ -f "$CLAUDE_CONFIG_DIR/session-audit/ai-state-sync.md" ]
}

@test "hook push exits 0 when the repo was never set up" {
    run bash "$SYNC" push --hook </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- pull subcommand ----------------------------------------------------------------

@test "pull brings in a change another machine pushed" {
    run bash "$SYNC" setup
    seed_remote "memory/from-other.md" "hello"
    run bash "$SYNC" pull
    [ "$status" -eq 0 ]
    [ "$(cat "$CLAUDE_CONFIG_DIR/memory/from-other.md")" = "hello" ]
}

@test "hook pull fails open and silent when offline" {
    run bash "$SYNC" setup
    git --git-dir="$AI_STATE_GIT_DIR" remote set-url origin "$T/gone.git"
    run bash "$SYNC" pull --hook </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pull on a conflict refuses, reports, and never resolves it" {
    seed_remote "memory/MEMORY.md" "base"
    run bash "$SYNC" setup
    printf 'mine\n' >"$CLAUDE_CONFIG_DIR/memory/MEMORY.md"
    run bash "$SYNC" push
    [ "$status" -eq 0 ]
    # a second machine rewrites the same line, then this machine edits and commits locally
    git --git-dir="$AI_STATE_GIT_DIR" reset -q --soft HEAD~1
    git --git-dir="$AI_STATE_GIT_DIR" --work-tree="$CLAUDE_CONFIG_DIR" checkout -q -- memory/MEMORY.md
    git clone -q "$AI_STATE_REMOTE" "$T/other"
    printf 'theirs\n' >"$T/other/memory/MEMORY.md"
    git -C "$T/other" commit -q -am theirs
    git -C "$T/other" push -q origin HEAD:main --force
    printf 'ours\n' >"$CLAUDE_CONFIG_DIR/memory/MEMORY.md"
    git --git-dir="$AI_STATE_GIT_DIR" --work-tree="$CLAUDE_CONFIG_DIR" commit -q -am ours
    run bash "$SYNC" pull
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONFLICT"* ]]
    [[ "$output" == *"memory/MEMORY.md"* ]]
    [ -f "$CLAUDE_CONFIG_DIR/session-audit/ai-state-sync.md" ]
    grep -q '<<<<<<<' "$CLAUDE_CONFIG_DIR/memory/MEMORY.md"
}

@test "pull without the repo set up says how to set it up" {
    run bash "$SYNC" pull
    [ "$status" -ne 0 ]
    [[ "$output" == *"state_sync"* ]]
}
