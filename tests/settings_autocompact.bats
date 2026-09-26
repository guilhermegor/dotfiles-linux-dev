#!/usr/bin/env bats
#
# Unit test for CLAUDE_AUTOCOMPACT_PCT_OVERRIDE in ai_clients/claude/settings.json
# (dotfiles-dev#406). Fails if the key is absent or not set to "70" — the
# measured trigger point ("compact once 70% of the window is used", per the
# installed binary's own threshold function) documented in
# ai_clients/claude/config/CLAUDE.md's Compaction section.
#
# Run locally: bats tests/   (install with: sudo apt-get install -y bats)

setup() {
    SETTINGS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/settings.json"
}

@test "settings.json is valid JSON" {
    run jq empty "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is set to 70 in env" {
    run jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" = "70" ]
}
