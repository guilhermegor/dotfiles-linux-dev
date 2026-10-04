#!/usr/bin/env bats
#
# Fixture for tests/bats_negation_gate.bats (dotfiles-linux-dev#380). The safe
# equivalent of bad.bats in this same directory -- run + status check
# instead of an inverted command -- which must make the gate exit 0.

@test "safe negation via run + status check" {
    run grep -q 'nonexistent-pattern' /dev/null
    [ "$status" -ne 0 ]
}
