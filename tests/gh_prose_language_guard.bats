#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/gh_prose_language_guard.sh
#
# Strategy:
#   - Pure stdin->exit-code filter: feed a PreToolUse JSON payload, assert 0 (allow) / 2 (block).
#   - The guard reads the repo's own README to decide the doc language, so tests run inside a
#     throwaway git repo whose README.md is English.
#
# dotfiles-linux-dev#187 measured a false positive distinct from the mandated-Portuguese-template bug:
# a body that is entirely English prose, but that quotes non-English literals (Gherkin keywords,
# UI strings) inside single-backtick spans so they stay verbatim and greppable, was blocked
# anyway because count_pt_words() only stripped FENCED (```) code blocks, never inline `code`
# spans. The fix strips inline backtick spans too, before counting function-word hits.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/gh_prose_language_guard.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP" || exit 1
    git init -q
    printf '# test repo\n\nAn English readme.\n' > README.md
}

teardown() {
    cd / || true
    rm -rf "$TEST_TMP"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

run_guard() {
    payload "$1" | "$GUARD"
}

# --- dotfiles-linux-dev#187: quoted non-English literals are data, not prose ---------------------------

@test "accepts an English body that only quotes non-English literals in backticks" {
    body='This adds BDD keyword parsing for Gherkin: `Quando` maps to When, `Então` maps to Then,
and duplicate keyword aliases `quando` and `entao` are normalized to the same rule. All prose
here is English; only the quoted identifiers are Portuguese source keywords that must stay
verbatim so they remain greppable in the parser table.'
    run run_guard "gh issue create --title x --body \"$body\""
    [ "$status" -eq 0 ]
}

@test "still rejects a body that is genuinely non-English prose" {
    body='Isso nao e uma mudanca simples, mas tambem exige que a documentacao seja atualizada
para todos os casos, porque senao fica incompleto.'
    run run_guard "gh issue create --title x --body \"$body\""
    [ "$status" -eq 2 ]
}
