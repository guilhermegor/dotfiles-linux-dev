// Shapes the stored claudestatus data into the stacked popover model (#734).
//
// Pure read: usage.json (written by refresh.mjs usage) + the billing cache (#733). Opening the
// popover runs this and nothing else, so it never calls an API or scrapes. Both prototypes
// (GNOME extension, AppIndicator window) only display what render() returns, so the two cannot
// differ in content.
//
//   node model.mjs            -> JSON { bar, accounts: [{ name, text }] }

import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";
import { cachePath, effectiveWeeklyReset, loadCache } from "../lib/claudestatus_billing.mjs";

const BAR_WIDTH = 10;
const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export function usagePath() {
    return process.env.CLAUDESTATUS_USAGE_FILE || path.join(path.dirname(cachePath()), "usage.json");
}

export function claudeJsonPath() {
    if (process.env.CLAUDE_JSON_FILE) return process.env.CLAUDE_JSON_FILE;
    // Claude Code keeps .claude.json inside CLAUDE_CONFIG_DIR when set, else directly in $HOME.
    // ponytail: gnome-shell sees one environment, so per-terminal config dirs are not detectable.
    const dir = process.env.CLAUDE_CONFIG_DIR;
    return dir ? path.join(dir, ".claude.json") : path.join(os.homedir(), ".claude.json");
}

// Name of the claudestatus account Claude Code is logged in as, or null. Read-only; matches only
// on the stable org UUID (~/.claude.json oauthAccount.organizationUuid vs usage orgUuid) and
// returns null on a missing/unreadable file, missing oauthAccount, no match or an ambiguous match.
export function detectActive(accounts, file = claudeJsonPath()) {
    let org;
    try {
        org = JSON.parse(fs.readFileSync(file, "utf8")).oauthAccount?.organizationUuid;
    } catch {
        return null;
    }
    if (!org) return null;
    const hits = accounts.filter((a) => a.orgUuid === org);
    return hits.length === 1 ? hits[0].name : null;
}

function loadUsage() {
    try {
        return JSON.parse(fs.readFileSync(usagePath(), "utf8"));
    } catch {
        return { at: null, accounts: [] };
    }
}

export function countdown(iso, now) {
    const ms = Date.parse(iso) - now.getTime();
    if (!(ms > 0)) return "now";
    if (ms < HOUR) return `${Math.floor(ms / MINUTE)}m`;
    if (ms < DAY) return `${Math.floor(ms / HOUR)}h${String(Math.floor((ms % HOUR) / MINUTE)).padStart(2, "0")}m`;
    return `${Math.floor(ms / DAY)}d${Math.floor((ms % DAY) / HOUR)}h`;
}

// Local absolute reset time: "Mon 21:44", plus the date from 7 days out ("Mon 19 Oct 21:44").
export function resetAt(iso, now) {
    const d = new Date(iso);
    const p = Object.fromEntries(
        new Intl.DateTimeFormat("en-GB", {
            weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
        }).formatToParts(d).map((x) => [x.type, x.value]),
    );
    const far = d.getTime() - now.getTime() >= 7 * DAY;
    // Local calendar-day gap (not elapsed hours): 00:05 tomorrow is "tomorrow" even 10 min away.
    const dayNo = (x) => Date.UTC(x.getFullYear(), x.getMonth(), x.getDate()) / DAY;
    const gap = dayNo(d) - dayNo(now);
    const label = far ? `${p.weekday} ${p.day} ${p.month}` : gap === 0 ? "today" : gap === 1 ? "tomorrow" : p.weekday;
    return `${label} ${p.hour}:${p.minute}`;
}

export function ago(iso, now) {
    const ms = now.getTime() - Date.parse(iso);
    if (!(ms >= 0)) return "never";
    if (ms < MINUTE) return "just now";
    if (ms < HOUR) return `${Math.floor(ms / MINUTE)} min ago`;
    if (ms < DAY) return `${Math.floor(ms / HOUR)} h ago`;
    return `${Math.floor(ms / DAY)} d ago`;
}

function bar(pct) {
    const filled = Math.round((pct / 100) * BAR_WIDTH);
    return "█".repeat(filled) + "░".repeat(BAR_WIDTH - filled);
}

function limitLine(label, limit, resetsAt, now) {
    if (!limit) return `${label}  —`;
    // A malformed timestamp would make Intl throw and blank the whole popover.
    const reset = Number.isFinite(Date.parse(resetsAt)) ? `resets in ${countdown(resetsAt, now)} (${resetAt(resetsAt, now)})` : "reset unknown";
    return `${label}  ${bar(limit.utilization)} ${String(limit.utilization).padStart(3)}%  ${reset}`;
}

function renewalLine(entry, now) {
    const at = entry?.renewalAt ? Date.parse(entry.renewalAt.value) : NaN;
    if (!(at > now.getTime())) return entry?.managedByAdmin?.value ? "Billing managed by team admin" : "Renewal unknown";
    const date = new Date(at).toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });
    return entry.autoRenew?.value === false ? `Ends ${date}` : `Renews ${date}`;
}

// Same rule as claudestatus's pickNextAccount (display.js), reduced to what the bar needs: skip
// errored and Free accounts; among accounts usable now take the lowest session+weekly sum; when
// all are exhausted take the one that frees up first (the LATER of its exhausted resets).
export function recommend(accounts, now = new Date()) {
    const score = (a) => (a.usage?.five_hour?.utilization ?? 0) + (a.usage?.seven_day?.utilization ?? 0);
    const waitMs = (a) => {
        const waits = [a.usage?.seven_day, a.usage?.five_hour]
            .filter((l) => l && l.utilization >= 100)
            .map((l) => {
                const t = Date.parse(l.resets_at);
                return Number.isNaN(t) ? Infinity : Math.max(0, t - now.getTime());
            });
        return waits.length ? Math.max(...waits) : 0;
    };
    const scored = accounts
        .filter((a) => !a.error && a.plan !== "free")
        .map((a) => ({ a, score: score(a), wait: waitMs(a) }));
    const open = scored.filter((x) => x.wait <= 0);
    const pool = open.length ? open : scored;
    const best = pool.reduce((m, x) => {
        if (!m) return x;
        if (!open.length && x.wait !== m.wait) return x.wait < m.wait ? x : m;
        return m.score <= x.score ? m : x;
    }, null);
    return best?.a ?? null;
}

function accountText(account, entry, usageAt, now, active) {
    const plan = account.plan === "unknown" ? "?" : account.plan[0].toUpperCase() + account.plan.slice(1);
    const badge = (account.plan === "free" ? "  ⚠ unpaid" : "") + (active ? "  ● active" : "");
    if (account.error) return `${account.name}  ${plan}${badge}\n✗ ${account.error.split(".")[0]}`;
    const weeklyReset = effectiveWeeklyReset(entry, account.usage?.seven_day?.resets_at, now);
    return [
        `${account.name}  ${plan}${badge}`,
        limitLine("Session", account.usage?.five_hour, account.usage?.five_hour?.resets_at, now),
        limitLine("Weekly ", account.usage?.seven_day, weeklyReset, now),
        `${renewalLine(entry, now)}  ·  updated ${usageAt ? ago(usageAt, now) : "never"}`,
    ].join("\n");
}

// The top bar shows the ACTIVE account ("name pct%") because it answers "what am I burning right
// now"; when the active account is unknown it falls back to the recommended account's percent.
export function buildModel(usage, cache, now = new Date(), activeName = null) {
    const accounts = usage.accounts ?? [];
    const best = recommend(accounts, now);
    const act = accounts.find((a) => a.name === activeName);
    // An active account without usage data (errored) falls back to the recommended percent.
    const named = act?.usage?.five_hour ? act : null;
    const pct = (named ?? best)?.usage?.five_hour?.utilization;
    return {
        bar: pct === undefined ? "—" : named ? `${named.name} ${pct}%` : `${pct}%`,
        recommended: best?.name ?? null,
        active: act?.name ?? null,
        activeLine: act ? `active: ${act.name}` : "active: unknown",
        accounts: accounts.map((a) => ({ name: a.name, text: accountText(a, cache[a.name], usage.at, now, a === act) })),
    };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const usage = loadUsage();
    console.log(JSON.stringify(buildModel(usage, loadCache(), new Date(), detectActive(usage.accounts ?? []))));
}
