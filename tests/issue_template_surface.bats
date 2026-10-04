#!/usr/bin/env bats
#
# Asserts .github/ISSUE_TEMPLATE/ exists and requires the declared file surface
# dispatch_plan.py reads (dotfiles-linux-dev#535). Without this template no issue filed here ever
# carries a ```surface block, which is what made every open issue read UNDECLARED at once.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TEMPLATE="$ROOT/.github/ISSUE_TEMPLATE/feature_or_fix.md"
}

@test "the issue template exists" {
    [ -f "$TEMPLATE" ]
}

@test "the issue template declares the What/Why and File surface sections" {
    grep -q '^## What / Why$' "$TEMPLATE"
    grep -q '^## File surface$' "$TEMPLATE"
}

@test "the issue template contains a fenced surface block" {
    grep -Fq '```surface' "$TEMPLATE"
}
