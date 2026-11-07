#!/usr/bin/env bats
#
# Memory index derivation and drift hook (dotfiles-linux-dev#956). Temp dirs only.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    LIB="$REPO_ROOT/ai_clients/claude/hooks/lib/memory_index.sh"
    HOOK="$REPO_ROOT/ai_clients/claude/hooks/memory_index_drift.sh"
    MEM="$BATS_TEST_TMPDIR/proj/memory"
    mkdir -p "$MEM"
    printf -- '---\nname: Triage protocol\ndescription: resolve once genuinely settled\ntype: feedback\n---\nbody\n' > "$MEM/triage.md"
}

@test "generate emits the canonical line from frontmatter" {
    run bash -c "source '$LIB'; memory_index_generate '$MEM'"
    [ "$status" -eq 0 ]
    [ "$output" = "- [Triage protocol](triage.md) — resolve once genuinely settled" ]
}

@test "generated index has no drift" {
    bash -c "source '$LIB'; memory_index_generate '$MEM'" > "$MEM/MEMORY.md"
    run bash -c "source '$LIB'; memory_index_drift '$MEM'"
    [ -z "$output" ]
}

@test "stale hook text is flagged" {
    echo '- [Triage protocol](triage.md) — NEVER resolve one without the call' > "$MEM/MEMORY.md"
    run bash -c "source '$LIB'; memory_index_drift '$MEM'"
    [[ "$output" == *"triage.md: index line differs"* ]]
}

@test "unlisted file and dangling entry are flagged" {
    echo '- [Gone](gone.md) — x' > "$MEM/MEMORY.md"
    run bash -c "source '$LIB'; memory_index_drift '$MEM'"
    [[ "$output" == *"gone.md: indexed but the file does not exist"* ]]
    [[ "$output" == *"triage.md: not listed"* ]]
}

@test "hook reports drift as additionalContext and exits 0" {
    echo '- [Triage protocol](triage.md) — stale' > "$MEM/MEMORY.md"
    run bash -c "echo '{\"tool_input\":{\"file_path\":\"$MEM/triage.md\"}}' | bash '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MEMORY.md DRIFT"* ]]
}

@test "hook is silent when in sync or outside a memory dir" {
    bash -c "source '$LIB'; memory_index_generate '$MEM'" > "$MEM/MEMORY.md"
    run bash -c "echo '{\"tool_input\":{\"file_path\":\"$MEM/triage.md\"}}' | bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run bash -c "echo '{\"tool_input\":{\"file_path\":\"/x/other.md\"}}' | bash '$HOOK'"
    [ -z "$output" ]
}
