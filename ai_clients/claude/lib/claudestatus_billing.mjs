// Billing-page parsing and the per-account date cache for claudestatus.
//
// patch_claudestatus.sh copies this file next to the installed claudestatus as
// dist/billing_cache.js, and both the patched api.js and display.js import it. It has no
// playwright dependency, so tests/claudestatus_billing.test.mjs imports it directly.
//
// The cache stores ABSOLUTE UTC timestamps and booleans only, each with the time it was read
// (readAt) -- never cookies, tokens, emails or page text. The countdown is computed from the
// stored timestamp, so a scrape is needed only when a value is missing or already past.

import fs from "fs";
import os from "os";
import path from "path";

const DAY_MS = 86400000;
const MONTHS = {
    jan: 0, fev: 1, feb: 1, mar: 2, abr: 3, apr: 3, mai: 4, may: 4, jun: 5, jul: 6,
    ago: 7, aug: 7, set: 8, sep: 8, out: 9, oct: 9, nov: 10, dez: 11, dec: 11,
};

// PT "5 de nov. de 2026" | EN "Nov 5, 2026" | EN-GB "5 Nov 2026". The group offsets differ per
// alternative, so each is normalised by dateFromMatch().
const DATE_RE = new RegExp(
    "(\\d{1,2})\\s+de\\s+([A-Za-z\\u00C0-\\u00FF]{3,})\\.?,?\\s+de\\s+(\\d{4})" +
    "|([A-Za-z]{3,9})\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})" +
    "|(\\d{1,2})\\s+([A-Za-z]{3,9})\\.?,?\\s+(\\d{4})",
    "gi",
);
// A date belongs to the nearest keyword before it, so "cancels on <d>" and "renews on <d>" differ.
const END_RE = /cancel|encerr|termina|expir|ends?\s+on|will\s+end|acaba/gi;
const RENEW_RE = /renov|renew|pr[óo]xima\s+cobran|next\s+(?:billing|payment|charge)|billing\s+date|data\s+de\s+cobran/gi;
const NEGATED_RENEW_RE = /(?:not|n[ãa]o)\s+(?:ser[áa]\s+|be\s+|vai\s+)?renov|(?:not|n[ãa]o)\s+(?:be\s+)?renew/i;
const KEYWORD_WINDOW = 120;

function dateFromMatch(m) {
    const [day, monthStr, year] = m[1] ? [m[1], m[2], m[3]] : m[4] ? [m[5], m[4], m[6]] : [m[7], m[8], m[9]];
    const month = MONTHS[monthStr.slice(0, 3).toLowerCase()];
    if (month === undefined) return null;
    // Noon UTC: the page shows a calendar day with no zone, noon keeps it the same day in every
    // zone from UTC-12 to UTC+11.
    return new Date(Date.UTC(parseInt(year, 10), month, parseInt(day, 10), 12));
}

function lastKeywordBefore(text, index) {
    const window = text.slice(Math.max(0, index - KEYWORD_WINDOW), index);
    let best = null;
    for (const [kind, re] of [["end", END_RE], ["renew", RENEW_RE]]) {
        for (const k of window.matchAll(re)) {
            if (!best || k.index > best.index) best = { kind, index: k.index, window };
        }
    }
    return best;
}

// Returns { period, autoRenew, renewalAt, daysLeft }; renewalAt is an ISO UTC string or null.
export function parseBillingText(rawText, now = new Date()) {
    const text = rawText.replace(/\s+/g, " ");
    let period = "unknown";
    let autoRenew = null;
    let renewalAt = null;
    let daysLeft = null;

    if (/mensal|monthly/i.test(text)) period = "monthly";
    else if (/anual|annual|yearly/i.test(text)) period = "annual";

    for (const m of text.matchAll(DATE_RE)) {
        const date = dateFromMatch(m);
        if (!date) continue;
        const kw = lastKeywordBefore(text, m.index);
        if (!kw) continue;
        const between = kw.window.slice(kw.index);
        const ends = kw.kind === "end" || NEGATED_RENEW_RE.test(between);
        autoRenew = !ends;
        renewalAt = date.toISOString();
        break;
    }

    if (autoRenew === null) {
        // "Fazer upgrade" is deliberately not a lapse signal: it is an upsell on live Pro pages.
        if (/reassinar|resubscribe/i.test(text)) autoRenew = false;
        else if (/auto-?renew|renova(?:[çc][ãa]o)?\s+autom|renova\s+automaticamente/i.test(text)) autoRenew = true;
    }

    // Relative banner ("termina em 12 dias" / "ends in 12 days") becomes an absolute time now.
    const rel = text.match(/termina em (\d+)\s+dias?|ends?\s+in\s+(\d+)\s+days?/i);
    if (rel) {
        daysLeft = parseInt(rel[1] ?? rel[2], 10);
        if (!renewalAt) renewalAt = new Date(now.getTime() + daysLeft * DAY_MS).toISOString();
        if (autoRenew === null) autoRenew = false;
    }
    return { period, autoRenew, renewalAt, daysLeft };
}

// ---- cache ---------------------------------------------------------------------------------

export function cachePath() {
    if (process.env.CLAUDESTATUS_CACHE_FILE) return process.env.CLAUDESTATUS_CACHE_FILE;
    const base = process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache");
    return path.join(base, "claudestatus", "billing.json");
}

export function loadCache() {
    const file = cachePath();
    let raw;
    try {
        raw = fs.readFileSync(file, "utf8");
    } catch (err) {
        if (err.code === "ENOENT") return {};
        console.error(`claudestatus: cannot read cache ${file}: ${err.message}`);
        return {};
    }
    try {
        const parsed = JSON.parse(raw);
        return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch (err) {
        console.error(`claudestatus: ignoring corrupt cache ${file}: ${err.message}`);
        return {};
    }
}

export function saveCache(cache) {
    const file = cachePath();
    try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const tmp = `${file}.${process.pid}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(cache, null, 2) + "\n", { mode: 0o600 });
        fs.renameSync(tmp, file);
    } catch (err) {
        console.error(`claudestatus: cannot write cache ${file}: ${err.message}`);
    }
}

function stamp(value, now) {
    return { value, readAt: now.toISOString() };
}

// Records only values actually read; a null never overwrites a good cached value.
export function recordBilling(cache, name, { renewalAt, autoRenew }, now = new Date()) {
    const entry = cache[name] ?? {};
    if (renewalAt) entry.renewalAt = stamp(renewalAt, now);
    if (typeof autoRenew === "boolean") entry.autoRenew = stamp(autoRenew, now);
    cache[name] = entry;
}

export function recordWeeklyReset(cache, name, resetsAt, now = new Date()) {
    if (!resetsAt || Number.isNaN(Date.parse(resetsAt))) return;
    cache[name] = { ...(cache[name] ?? {}), weeklyResetAt: stamp(new Date(resetsAt).toISOString(), now) };
}

function futureTime(field, now) {
    const t = field ? Date.parse(field.value) : NaN;
    return t > now.getTime() ? t : null;
}

// A scrape is needed only when the renewal date is missing or past, or auto-renew was never read.
export function needsScrape(entry, now = new Date()) {
    if (!entry) return true;
    return futureTime(entry.renewalAt, now) === null || typeof entry.autoRenew?.value !== "boolean";
}

export function billingFromCache(entry, now = new Date()) {
    const t = futureTime(entry.renewalAt, now);
    return {
        billingDate: new Date(t).toISOString(),
        daysLeft: Math.ceil((t - now.getTime()) / DAY_MS),
        autoRenew: entry.autoRenew.value,
    };
}

// Prefer the live API reset when it is a future time, else the cached one, else null.
export function effectiveWeeklyReset(entry, apiResetsAt, now = new Date()) {
    const api = apiResetsAt ? Date.parse(apiResetsAt) : NaN;
    if (api > now.getTime()) return apiResetsAt;
    const cached = futureTime(entry?.weeklyResetAt, now);
    return cached === null ? null : new Date(cached).toISOString();
}
