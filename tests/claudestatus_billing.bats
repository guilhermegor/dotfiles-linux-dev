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

# patch_api_js on a fixture api.js that already carries the OLD billing_cache import (#747):
# the patcher is laid out under $T/a/b/c/ so its ../../../lib/common.sh resolves to $T/lib/,
# and main is dropped so nothing touches the installed claudestatus.
patch_fixture() {
    local repo="$BATS_TEST_DIRNAME/.."
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/a/b/c" "$T/lib"
    cp "$repo/lib/common.sh" "$T/lib/common.sh"
    cp "$repo/ai_clients/claude/lib/claudestatus_api_billing.js" "$T/a/b/c/"
    sed '$d' "$repo/ai_clients/claude/lib/patch_claudestatus.sh" > "$T/a/b/c/patch.sh"
    cat > "$T/api.js" <<'JS'
import fs from "fs";
import { getAccountsDir } from "./accounts.js";
import { billingFromCache, loadCache, needsScrape, parseBillingText, recordBilling, saveCache } from "./billing_cache.js";
export const x = 1;
JS
}

@test "re-patching replaces the old billing_cache import with one updated import" {
    command -v node >/dev/null 2>&1 || skip "node not installed"
    patch_fixture
    run bash -c "source '$T/a/b/c/patch.sh'; patch_api_js '$T/api.js'; patch_api_js '$T/api.js'"
    [ "$status" -eq 0 ]
    run grep -c '^import .*from "\./billing_cache\.js";' "$T/api.js"
    [ "$output" = "1" ]
    grep -q '^import {[^}]*isCloudflareChallenge[^}]*} from "\./billing_cache\.js";' "$T/api.js"
    run grep -c 'just a moment' "$T/api.js"
    [ "$output" = "0" ]
    cp "$T/api.js" "$T/api.mjs"
    run node --check "$T/api.mjs"
    [ "$status" -eq 0 ]
}
