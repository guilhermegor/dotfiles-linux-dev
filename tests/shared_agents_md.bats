#!/usr/bin/env bats
#
# Unit tests for ai_clients/lib/shared_agents_md.sh
#
# Strategy (stub print_status, sandbox HOME):
#   - Stub `print_status` BEFORE sourcing the helper so no real lib/common.sh
#     dependency is needed, and its output is captured for assertions.
#   - The helper resolves its own source file relative to its OWN location
#     (ai_clients/lib/shared_agents_md.sh -> ../shared/AGENTS.md), so sourcing
#     it from the real repo tree exercises the real ai_clients/shared/AGENTS.md
#     with no faking required.
#   - Every install writes to a throwaway destination under a tmpdir — never
#     a real client config dir.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    print_status() { echo "[$1] $2"; }

    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SRC_AGENTS_MD="$REPO_ROOT/ai_clients/shared/AGENTS.md"
    source "$REPO_ROOT/ai_clients/lib/shared_agents_md.sh"

    TEST_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "copies the shared AGENTS.md content byte-for-byte to the destination" {
    dest="$TEST_TMP/claude/AGENTS.md"
    run install_shared_agents_md "$dest"
    [ "$status" -eq 0 ]
    [ -f "$dest" ]
    diff -q "$SRC_AGENTS_MD" "$dest"
}

@test "creates the destination's parent directory if it does not exist" {
    dest="$TEST_TMP/does/not/exist/yet/AGENTS.md"
    [ ! -d "$(dirname "$dest")" ]
    run install_shared_agents_md "$dest"
    [ "$status" -eq 0 ]
    [ -f "$dest" ]
}

@test "installs under a different destination filename (e.g. copilot-instructions.md)" {
    dest="$TEST_TMP/copilot/copilot-instructions.md"
    run install_shared_agents_md "$dest"
    [ "$status" -eq 0 ]
    diff -q "$SRC_AGENTS_MD" "$dest"
}

@test "reports success including the destination path" {
    dest="$TEST_TMP/kimi/AGENTS.md"
    run install_shared_agents_md "$dest"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installed AGENTS.md"* ]]
    [[ "$output" == *"$dest"* ]]
}

@test "fails with a clear error when called without a destination" {
    run install_shared_agents_md ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"destination path required"* ]]
}

@test "overwrites an existing destination file with the current source content" {
    dest="$TEST_TMP/qwen/AGENTS.md"
    mkdir -p "$(dirname "$dest")"
    echo "stale hand-edited content" > "$dest"

    run install_shared_agents_md "$dest"
    [ "$status" -eq 0 ]
    diff -q "$SRC_AGENTS_MD" "$dest"
}
