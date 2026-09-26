#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/commands/greenfield-new.md
#
# Static content checks pinning dotfiles-dev#363: /greenfield-new must file
# backlog items from named keys, never from a positional prompt list (the
# same defect class as guilhermegor/blueprintx#481, where an unattended
# scaffold run pipes answers by POSITION and a new prompt silently shifts
# every answer after it). These are plain grep assertions over the shipped
# markdown, mirroring tests/validate_contracts.sh's approach for
# ai_clients/claude artifacts.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    CMD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/commands/greenfield-new.md"
}

@test "command file exists at the documented path" {
    [ -f "$CMD" ]
}

@test "frontmatter name carries the c: command prefix" {
    run grep -m1 '^name:' "$CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == "name: c:greenfield-new" ]]
}

@test "allowed-tools never uses the over-broad Bash(*)" {
    run grep -c 'Bash(\*)' "$CMD"
    [ "$status" -ne 0 ]
}

@test "targets guilhermegor/greenfield explicitly on every gh issue/project call" {
    run grep -c -- '--repo guilhermegor/greenfield' "$CMD"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    run grep -c -- '--owner guilhermegor' "$CMD"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "answers are gathered as a key: value map, not a prompt list" {
    run grep -c 'key: value' "$CMD"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "per-skeleton keys are scoped by skeleton, not offered flat" {
    run grep -c 'Never offer a key from a different skeleton' "$CMD"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "derives kind/lang/registry/repo/state instead of asking every one" {
    for key in kind lang registry repo state; do
        run grep -c -- "- \`$key\`:" "$CMD"
        [ "$status" -eq 0 ]
        [ "$output" -ge 1 ]
    done
}

@test "never maps answers to positional \$1/\$2/\$3 args (the #481 anti-pattern)" {
    run grep -Ec '\$[0-9]' "$CMD"
    [ "$status" -ne 0 ]
}

@test "step 4 confirms the full map before anything is filed" {
    run grep -c 'Confirm the full map' "$CMD"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}
