#!/usr/bin/env bats
#
# Unit tests for prune_settings_keys() (dotfiles-linux-dev#272) — the delete path for
# stale ~/.claude/settings.json keys that configure_settings()'s additive-only
# merge (`jq '. * $base'`, in lib/settings.sh) can never remove on its own.
#
# The delicate part: the live file legitimately carries machine-local keys
# (API tokens, per-machine env vars, ...) that must survive every deploy —
# that is the whole reason the merge is additive. prune_settings_keys() must
# therefore prune ONLY inside the specific, fully source-owned subtrees named
# in SETTINGS_PRUNE_KEYS (enabledPlugins today), never a blanket live-vs-source
# diff. This suite asserts both directions so a future edit cannot silently
# widen the prune back into a blanket delete:
#   - a stale enabledPlugins entry (live, absent from source) IS removed
#   - a machine-local top-level key (live only, never in source) SURVIVES
#
# Strategy: source prune.sh against fixture source/live settings.json files
# under a temp dir — the real ~/.claude/settings.json is never touched.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP_DIR="$(mktemp -d)"
    SCRIPT_DIR="$TMP_DIR/source"   # stands in for ai_clients/claude
    CLAUDE_DIR="$TMP_DIR/live"     # stands in for ~/.claude
    mkdir -p "$SCRIPT_DIR" "$CLAUDE_DIR"

    # Real print_status lives in ai_clients/lib/utils.sh; stub it so prune.sh
    # sources standalone without pulling in the whole orchestrator.
    print_status() { :; }

    # shellcheck source=../ai_clients/claude/lib/prune.sh
    source "$REPO_ROOT/ai_clients/claude/lib/prune.sh"

    cat > "$SCRIPT_DIR/settings.json" <<'JSON'
{
  "enabledPlugins": {
    "kept-plugin@marketplace": true
  }
}
JSON

    cat > "$CLAUDE_DIR/settings.json" <<'JSON'
{
  "enabledPlugins": {
    "kept-plugin@marketplace": true,
    "stale-plugin@marketplace": true
  },
  "machineLocalToken": "keep-me"
}
JSON
}

teardown() {
    rm -rf "$TMP_DIR"
}


# NB: these call prune_settings_keys() directly (stdin redirected from a
# heredoc) rather than via `run bash -c "... | prune_settings_keys"` — a
# `bash -c` spawns a new interpreter, and bash cannot export array variables
# to a child process, which would silently empty SETTINGS_PRUNE_KEYS there.

@test "prune_settings_keys removes a stale enabledPlugins entry absent from source" {
    prune_settings_keys <<< "y"

    run jq -e '.enabledPlugins | has("stale-plugin@marketplace")' "$CLAUDE_DIR/settings.json"
    [ "$status" -ne 0 ]

    run jq -e '.enabledPlugins | has("kept-plugin@marketplace")' "$CLAUDE_DIR/settings.json"
    [ "$status" -eq 0 ]
}

@test "prune_settings_keys leaves a machine-local top-level key untouched" {
    prune_settings_keys <<< "y"

    run jq -r '.machineLocalToken' "$CLAUDE_DIR/settings.json"
    [ "$output" = "keep-me" ]
}

@test "prune_settings_keys declines without confirmation" {
    prune_settings_keys <<< "n"

    run jq -e '.enabledPlugins | has("stale-plugin@marketplace")' "$CLAUDE_DIR/settings.json"
    [ "$status" -eq 0 ]
}

@test "prune_settings_keys is a no-op when live already matches source" {
    cat > "$CLAUDE_DIR/settings.json" <<'JSON'
{
  "enabledPlugins": {
    "kept-plugin@marketplace": true
  },
  "machineLocalToken": "keep-me"
}
JSON

    run prune_settings_keys
    [ "$status" -eq 0 ]

    run jq -r '.machineLocalToken' "$CLAUDE_DIR/settings.json"
    [ "$output" = "keep-me" ]
}
