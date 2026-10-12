#!/usr/bin/env bats
#
# claudestatus billing parser + date cache (dotfiles-linux-dev#733). The logic lives in
# ai_clients/claude/lib/claudestatus_billing.mjs; the assertions are in the node test beside it.

@test "billing parser and cache pass the node self-check" {
    command -v node >/dev/null 2>&1 || skip "node not installed"
    run node "$BATS_TEST_DIRNAME/claudestatus_billing.test.mjs"
    [ "$status" -eq 0 ]
    [[ "$output" == *ok* ]]
}
