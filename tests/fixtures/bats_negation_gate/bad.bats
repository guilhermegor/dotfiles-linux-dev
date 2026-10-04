#!/usr/bin/env bats
#
# Fixture for tests/bats_negation_gate.bats (dotfiles-linux-dev#380). Deliberately
# contains a dead `! <cmd>` negation that is NOT the test's last statement --
# the exact pattern the gate must reject. Never run directly with `bats`:
# `bats tests/` globs only tests/*.bats, not tests/fixtures/**, so this file
# is only ever consumed by the gate script itself.

@test "dead negation not last in body" {
    ! grep -q 'nonexistent-pattern' /dev/null
    true
}
