#!/usr/bin/env bats
#
# Tests for the Codex client of ai_clients/claude/hooks/ai_state_sync.sh
# (dotfiles-linux-dev#656): ~/.codex's WAL-mode SQLite DBs are exported as text dumps (never
# the binary files) into the private state repo, and restored only into an absent or empty DB.
# Throwaway HOME, temp SQLite DBs, a LOCAL bare repo as remote -- never the real ~/.codex.

setup() {
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SYNC="$REPO_ROOT/ai_clients/claude/hooks/ai_state_sync.sh"
    T="$BATS_TEST_TMPDIR"
    export HOME="$T/home"
    export CLAUDE_CONFIG_DIR="$HOME/.claude"
    export CODEX_HOME="$HOME/.codex"
    export AI_STATE_CLIENT=codex
    export AI_STATE_REMOTE="$T/remote.git"
    export AI_STATE_TIMEOUT=10
    mkdir -p "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" "$T/bin"
    export GIT_CONFIG_GLOBAL="$T/gitconfig"
    git config --global user.name tester
    git config --global user.email tester@example.invalid
    git config --global init.defaultBranch main
    export PATH="$T/bin:$PATH"
    git init -q --bare -b main "$AI_STATE_REMOTE"
}

# A WAL-mode DB with one row, held open elsewhere is not needed: WAL mode is the point.
make_db() {
    local db="$1" value="$2"
    sqlite3 "$db" "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS memories(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO memories(body) VALUES ('$value');" >/dev/null
}

remote_files() {
    git --git-dir="$AI_STATE_REMOTE" ls-tree -r --name-only codex 2>/dev/null
}

@test "export then restore on a fresh machine reproduces the rows" {
    make_db "$CODEX_HOME/memories_1.sqlite" "remember the milk"
    make_db "$CODEX_HOME/goals_1.sqlite" "ship it"
    run bash "$SYNC" setup
    [ "$status" -eq 0 ]
    run bash "$SYNC" push
    [ "$status" -eq 0 ]
    [[ "$(remote_files)" == *"state-dump/memories_1.sql"* ]]
    [[ "$(remote_files)" == *"state-dump/goals_1.sql"* ]]

    # Second machine: new HOME, new CODEX_HOME, nothing there yet.
    export HOME="$T/home2"
    export CODEX_HOME="$HOME/.codex"
    mkdir -p "$HOME" "$CODEX_HOME"
    run bash "$SYNC" setup
    [ "$status" -eq 0 ]
    [ "$(sqlite3 "$CODEX_HOME/memories_1.sqlite" 'select body from memories')" = "remember the milk" ]
    [ "$(sqlite3 "$CODEX_HOME/goals_1.sqlite" 'select body from memories')" = "ship it" ]
}

@test "restore refuses a target DB that already holds data" {
    make_db "$CODEX_HOME/memories_1.sqlite" "from machine A"
    bash "$SYNC" setup
    bash "$SYNC" push

    export HOME="$T/home2"
    export CODEX_HOME="$HOME/.codex"
    mkdir -p "$CODEX_HOME"
    make_db "$CODEX_HOME/memories_1.sqlite" "local only"
    run bash "$SYNC" setup
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSING to restore memories_1.sqlite"* ]]
    [ "$(sqlite3 "$CODEX_HOME/memories_1.sqlite" 'select body from memories')" = "local only" ]
}

@test "restore fills a zero-byte target DB" {
    make_db "$CODEX_HOME/memories_1.sqlite" "row"
    bash "$SYNC" setup
    bash "$SYNC" push

    export HOME="$T/home2"
    export CODEX_HOME="$HOME/.codex"
    mkdir -p "$CODEX_HOME"
    : >"$CODEX_HOME/memories_1.sqlite"
    run bash "$SYNC" setup
    [ "$status" -eq 0 ]
    [ "$(sqlite3 "$CODEX_HOME/memories_1.sqlite" 'select body from memories')" = "row" ]
}

@test "binary sqlite files and credentials never reach the remote" {
    make_db "$CODEX_HOME/memories_1.sqlite" "row"
    printf '{"token":"not-a-real-secret"}\n' >"$CODEX_HOME/auth.json"
    printf 'x\n' >"$CODEX_HOME/installation_id"
    printf '{}\n' >"$CODEX_HOME/models_cache.json"
    printf 'log\n' >"$CODEX_HOME/logs_1.sqlite"
    bash "$SYNC" setup
    run bash "$SYNC" push
    [ "$status" -eq 0 ]
    local files
    files="$(remote_files)"
    [ "$files" = "state-dump/memories_1.sql" ]
}

@test "the secret guard holds back a dump that contains a token" {
    make_db "$CODEX_HOME/memories_1.sqlite" "ghp_$(printf 'A%.0s' $(seq 1 36))"
    bash "$SYNC" setup
    run bash "$SYNC" push
    [ "$status" -ne 0 ]
    [[ "$output" == *"Secret guard"* ]]
    [ -z "$(remote_files)" ]
}
