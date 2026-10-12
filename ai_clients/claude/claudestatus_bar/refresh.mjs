// The two popover buttons. Both call the installed, patched claudestatus code (no scraper here).
//
//   node refresh.mjs usage    -> fetchAllUsage (API, no browser); snapshot saved to usage.json
//   node refresh.mjs billing  -> fetchAllBilling (re-scrapes only what the #733 cache lacks)
//
// The CLI prints a chalk table, so the usage snapshot is taken by importing the same api.js the
// CLI uses. dist/ is found from the `claudestatus` binary on PATH.

import fs from "fs";
import path from "path";
import { execFileSync } from "child_process";
import { pathToFileURL } from "url";
import { usagePath } from "./model.mjs";
import { loadCache, recordWeeklyReset, saveCache } from "../lib/claudestatus_billing.mjs";

const kind = process.argv[2];
if (!["usage", "billing"].includes(kind)) {
    console.error("usage: refresh.mjs usage|billing");
    process.exit(2);
}

// asdf shims are shell scripts, so realpath alone returns the shim; `asdf which` finds the real
// binary (same approach as lib/patch_claudestatus.sh).
function claudestatusBin() {
    try {
        return execFileSync("asdf", ["which", "claudestatus"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    } catch {
        return execFileSync("which", ["claudestatus"], { encoding: "utf8" }).trim();
    }
}
const bin = fs.realpathSync(claudestatusBin());
const dist = path.join(path.dirname(bin), "..", "dist");
const load = (name) => import(pathToFileURL(path.join(dist, name)).href);
const { listAccounts } = await load("accounts.js");
const api = await load("api.js");
const names = listAccounts().map((a) => a.name);

if (kind === "usage") {
    const accounts = await api.fetchAllUsage(names);
    const file = usagePath();
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify({ at: new Date().toISOString(), accounts }, null, 2) + "\n", { mode: 0o600 });
    // Same as the terminal dashboard: remember future weekly resets so a later response that
    // omits seven_day.resets_at does not lose the date.
    const cache = loadCache();
    for (const a of accounts) recordWeeklyReset(cache, a.name, a.usage?.seven_day?.resets_at);
    saveCache(cache);
} else {
    await api.fetchAllBilling(names);
}
