#!/bin/bash
# Brings an installed @howells/claudestatus to the corrected state (idempotent).
# Re-run after npm (re)installs the package. This is the ONLY patcher: the installer
# (distro_config/install_coding_lib/ai_clients.sh::_claudestatus_patch_display) calls it.
#
# Sources (all beside this script):
#   claudestatus_billing.mjs      -> dist/billing_cache.js  billing-page parser + date cache
#   claudestatus_api_billing.js   -> injected into dist/api.js (between the marker comments):
#                                    API-first plan/paid, billing-page scrape only when the
#                                    cache has no future renewal date
#   claudestatus_display.js       -> dist/display.js        plan-aware usage table + billing table
#
# What it does to dist/api.js:
#   - Inserts classifyPlan() (max/pro/team/free/unknown) if missing and rewrites the usage-path
#     plan snippets to call it.
#   - Imports ./billing_cache.js and installs/replaces the marked billing block.
# What it does to dist/cli.js:
#   - Wires fetchAllBilling/displayBillingTable into the default command if missing, and
#     replaces the "browser windows will flash" billing message.
#
# The date cache lives at ${XDG_CACHE_HOME:-~/.cache}/claudestatus/billing.json (override with
# CLAUDESTATUS_CACHE_FILE): absolute UTC timestamps + booleans, each with its readAt time, no
# credentials or session data. Delete it to force a re-scrape.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../lib/common.sh"

resolve_dist_dir() {
    local bin
    # asdf shims are shell scripts, not symlinks — realpath returns the shim itself.
    # Use `asdf which` to get the real versioned binary, then follow that symlink.
    if command -v asdf >/dev/null 2>&1 && asdf which claudestatus >/dev/null 2>&1; then
        bin=$(asdf which claudestatus)
    else
        bin=$(command -v claudestatus 2>/dev/null || true)
    fi
    if [[ -z "$bin" ]]; then
        print_status "error" "claudestatus not found — install it first (npm install -g @howells/claudestatus)."
        return 1
    fi
    dirname "$(realpath "$bin")"
}

patch_api_js() {
    local api_js="$1"
    python3 - "$api_js" "$SCRIPT_DIR/claudestatus_api_billing.js" <<'PYEOF'
import re, sys, pathlib

path = pathlib.Path(sys.argv[1])
block = pathlib.Path(sys.argv[2]).read_text()
src = path.read_text()
original = src

BEGIN = "// claudestatus-billing:begin (managed by patch_claudestatus.sh)\n"
END = "// claudestatus-billing:end\n"
IMPORT = ('import { billingFromCache, isCloudflareChallenge, loadCache, needsScrape, parseBillingText, '
          'recordBilling, saveCache } '
          'from "./billing_cache.js";\n')

CLASSIFIER = r'''
// Map claude.ai org capabilities to a plan tier. Order matters: a paid org keeps
// its "chat" capability, so the paid markers must be checked before bare "chat".
//   claude_max -> max, claude_pro -> pro, raven -> team (Team/Enterprise),
//   chat only  -> free (no paid capability), else unknown.
function classifyPlan(capabilities) {
    const c = capabilities || [];
    if (c.includes("claude_max")) return "max";
    if (c.includes("claude_pro")) return "pro";
    if (c.includes("raven")) return "team";
    if (c.includes("chat")) return "free";
    return "unknown";
}
'''

# 1) classifyPlan once, right after getProfileDir().
anchor = (
    "function getProfileDir(name) {\n"
    "    return path.join(getAccountsDir(), `profile-${name}`);\n"
    "}\n"
)
if "function classifyPlan(" not in src and anchor in src:
    src = src.replace(anchor, anchor + CLASSIFIER, 1)

# 2) Usage-path plan snippets -> classifyPlan().
old_plan = (
    "        const plan = org.capabilities.includes(\"claude_max\")\n"
    "            ? \"max\"\n"
    "            : org.capabilities.includes(\"chat\")\n"
    "                ? \"pro\"\n"
    "                : \"unknown\";"
)
src = src.replace(old_plan, "        const plan = classifyPlan(org.capabilities);")

# 3) billing_cache import, after the accounts.js import. An older patch's import names a
#    different set, so drop any existing billing_cache import first: two would be a duplicate
#    binding and a SyntaxError on load.
src = re.sub(r'^import \{[^}]*\} from "\./billing_cache\.js";\n', "", src, flags=re.M)
if IMPORT not in src:
    m = re.search(r'^import \{[^}]*\} from "\./accounts\.js";\n', src, re.M)
    if not m:
        sys.exit("  api.js layout not recognised (accounts.js import missing); not patched")
    src = src[:m.end()] + IMPORT + src[m.end():]

# 4) The marked billing block: replace in place, else replace the legacy unmarked block
#    (it ran from `const PT_MONTHS` to waitForLoginSignal, or to EOF when appended), else append.
marked = BEGIN + block.rstrip("\n") + "\n" + END
if BEGIN in src and END in src:
    start = src.index(BEGIN)
    src = src[:start] + marked + src[src.index(END) + len(END):]
elif "const PT_MONTHS" in src:
    start = src.index("const PT_MONTHS")
    stop = src.find("async function waitForLoginSignal", start)
    src = src[:start] + marked + ("\n" + src[stop:] if stop != -1 else "")
else:
    src = src.rstrip("\n") + "\n" + marked

if src != original:
    path.write_text(src)
    print("  api.js patched")
else:
    print("  api.js already up to date")
PYEOF
}

patch_cli_js() {
    local cli_js="$1"
    python3 - "$cli_js" <<'PYEOF'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()
original = src

if "fetchAllBilling" not in src:
    edits = [
        ('import { addAccount, fetchAllUsage } from "./api.js";',
         'import { addAccount, fetchAllUsage, fetchAllBilling } from "./api.js";'),
        ('import { displayUsageTable, displayQuickRecommendation } from "./display.js";',
         'import { displayUsageTable, displayBillingTable, displayQuickRecommendation } from "./display.js";'),
        ('const usage = await fetchAllUsage(accounts.map((a) => a.name));',
         'const names = accounts.map((a) => a.name); const usage = await fetchAllUsage(names);'),
        ('if (options.quick) {',
         'if (options.quick) { displayQuickRecommendation(usage); return; } displayUsageTable(usage); '
         'console.log(chalk.gray("\\nFetching billing data...\\n")); '
         'const billing = await fetchAllBilling(names); displayBillingTable(billing); if (false) {'),
    ]
    # All anchors or none: a partial rewrite leaves calls to names that were never defined.
    missing = [old for old, _ in edits if old not in src]
    if missing:
        sys.exit("  cli.js layout not recognised; not patched: " + "; ".join(missing))
    for old, new in edits:
        src = src.replace(old, new, 1)

src = src.replace(
    "Fetching billing data (browser windows will flash briefly)...",
    "Fetching billing data (cached dates reused; a hidden browser only when one is missing or past)...",
)

if src != original:
    path.write_text(src)
    print("  cli.js patched")
else:
    print("  cli.js already up to date")
PYEOF
}

main() {
    local dist_dir package_json version
    dist_dir=$(resolve_dist_dir)
    package_json="$dist_dir/../package.json"
    if [[ ! -f "$dist_dir/api.js" ]]; then
        print_status "error" "api.js not found at $dist_dir/api.js"
        return 1
    fi

    version=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$package_json" 2>/dev/null || echo "unknown")
    print_status "info" "Patching @howells/claudestatus v${version} at $dist_dir ..."

    cp "$SCRIPT_DIR/claudestatus_billing.mjs" "$dist_dir/billing_cache.js"
    cp "$SCRIPT_DIR/claudestatus_display.js" "$dist_dir/display.js"
    patch_api_js "$dist_dir/api.js"
    if [[ -f "$dist_dir/cli.js" ]]; then
        patch_cli_js "$dist_dir/cli.js"
    fi

    print_status "success" "claudestatus patch complete (api.js, display.js, cli.js, billing_cache.js)"
    print_status "info" "Run 'claudestatus' to verify. Plan/paid come from the API; renewal and"
    print_status "info" "auto-renew are cached per account and re-read only when missing or past."
}

main "$@"
