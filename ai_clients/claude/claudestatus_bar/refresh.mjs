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

const kind = process.argv[2];
if (!["usage", "billing"].includes(kind)) {
    console.error("usage: refresh.mjs usage|billing");
    process.exit(2);
}

const bin = fs.realpathSync(execFileSync("which", ["claudestatus"], { encoding: "utf8" }).trim());
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
} else {
    await api.fetchAllBilling(names);
}
