#!/usr/bin/env bats
#
# Private include list for ai-state-sync (dotfiles-linux-dev#1126): a work-tree file
# re-includes listed paths in info/exclude (after the whitelist, before the final denies)
# and shields them from prune. Throwaway HOME and a local bare remote only.
#
# Run locally:  bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SYNC="$REPO_ROOT/ai_clients/claude/hooks/ai_state_sync.sh"
    LIB="$REPO_ROOT/ai_clients/claude/hooks/lib/ai_state_include.sh"
    T="$BATS_TEST_TMPDIR"
    export HOME="$T/home"
    export CLAUDE_CONFIG_DIR="$HOME/.claude"
    export AI_STATE_REMOTE="$T/remote.git"
    export AI_STATE_GIT_DIR="$HOME/.ai-clients-state/claude.git"
    export AI_STATE_TIMEOUT=10
    mkdir -p "$CLAUDE_CONFIG_DIR/skills/private-example" "$CLAUDE_CONFIG_DIR/skills/other"
    export GIT_CONFIG_GLOBAL="$T/gitconfig"
    git config --global user.name tester
    git config --global user.email tester@example.invalid
    git config --global init.defaultBranch main
    git init -q --bare -b main "$AI_STATE_REMOTE"
    INC="$CLAUDE_CONFIG_DIR/ai-state-sync.include"
}

setup_sync() {
    run bash "$SYNC" setup
    [ "$status" -eq 0 ]
}

ignored() {
    git --git-dir="$AI_STATE_GIT_DIR" --work-tree="$CLAUDE_CONFIG_DIR" check-ignore -q -- "$1"
}

refute_ignored() {
    run git --git-dir="$AI_STATE_GIT_DIR" --work-tree="$CLAUDE_CONFIG_DIR" check-ignore -q -- "$1"
    [ "$status" -ne 0 ]
}

@test "an included skill is not ignored" {
    printf '# private\n\n/skills/private-example/\n' >"$INC"
    setup_sync
    refute_ignored skills/private-example/SKILL.md
}

@test "a skill outside the include stays ignored" {
    printf '/skills/private-example/\n' >"$INC"
    setup_sync
    ignored skills/other/SKILL.md
}

@test "the include file itself is synced" {
    printf '/skills/private-example/\n' >"$INC"
    setup_sync
    refute_ignored ai-state-sync.include
}

@test "final denies beat include lines" {
    printf '*.jsonl\n.env\n/skills/private-example/\n' >"$INC"
    setup_sync
    ignored skills/private-example/x.jsonl
    ignored skills/private-example/.env
}

@test "two includes under one parent both sync" {
    printf '/skills/private-example/\n/skills/other/\n' >"$INC"
    setup_sync
    refute_ignored skills/private-example/SKILL.md
    refute_ignored skills/other/SKILL.md
}

@test "bang and dotdot lines are rejected" {
    printf '!/skills/other/\n/skills/../memory/\n' >"$INC"
    run bash -c "source '$LIB'; ai_state_include_paths '$INC'"
    [ -z "${output//*ignoring*/}" ]
    run bash -c "source '$LIB'; ai_state_include_paths '$INC' 2>/dev/null"
    [ -z "$output" ]
}

@test "missing include file means the current whitelist exactly" {
    setup_sync
    ignored skills/private-example/SKILL.md
    run bash -c "source '$LIB'; ai_state_include_excludes '$T/nope'"
    [ -z "$output" ]
}

# --- prune ---------------------------------------------------------------------------

prune_run() {
    SCRIPT_DIR="$T/source"
    CLAUDE_DIR="$CLAUDE_CONFIG_DIR"
    mkdir -p "$SCRIPT_DIR/skills"
    touch "$CLAUDE_DIR/skills/private-example/SKILL.md" "$CLAUDE_DIR/skills/other/SKILL.md"
    print_status() { printf '%s\n' "$2"; }
    # shellcheck source=../ai_clients/claude/lib/prune.sh
    source "$REPO_ROOT/ai_clients/claude/lib/prune.sh"
    run _prune_file_artifacts <<<"n"
}

@test "prune skips an included skill and still lists an ordinary orphan" {
    printf '/skills/private-example/\n' >"$INC"
    prune_run
    [[ "$output" == *"skills: other"* ]]
    [[ "$output" != *"private-example"* ]]
}

@test "prune lists both when there is no include file" {
    prune_run
    [[ "$output" == *"skills: other"* ]]
    [[ "$output" == *"skills: private-example"* ]]
}
