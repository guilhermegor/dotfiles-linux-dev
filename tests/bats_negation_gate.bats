#!/usr/bin/env bats
#
# Unit tests for tests/bats_negation_gate.sh (dotfiles-linux-dev#380).
#
# Strategy: run the gate script directly against two fixtures under
# tests/fixtures/bats_negation_gate/ -- one holding the dead `! <cmd>`
# pattern, one already converted to the safe run+status shape. Neither
# fixture is executed by `bats tests/` itself (that globs only tests/*.bats,
# not tests/fixtures/**), only scanned by the gate.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    GATE="$REPO_ROOT/tests/bats_negation_gate.sh"
    FIXTURES="$REPO_ROOT/tests/fixtures/bats_negation_gate"
}

@test "gate exits non-zero and cites the line for a bad fixture" {
    run bash "$GATE" "$FIXTURES/bad.bats"
    [ "$status" -ne 0 ]
    [[ "$output" == *"bad.bats:10:"* ]]
}

@test "gate exits zero for a clean fixture" {
    run bash "$GATE" "$FIXTURES/clean.bats"
    [ "$status" -eq 0 ]
}
