// Subscription-API mapping and the per-account date cache for claudestatus.
//
// patch_claudestatus.sh copies this file next to the installed claudestatus as
// dist/billing_cache.js, and both the patched api.js and display.js import it. It has no
// playwright dependency, so tests/claudestatus_billing.test.mjs imports it directly.
//
// The cache stores ABSOLUTE UTC timestamps and booleans only, each with the time it was read
// (readAt) -- never cookies, tokens, emails or page text. The countdown is computed from the
// stored timestamp, so a fetch is needed only when a value is missing or already past.

import fs from "fs";
import os from "os";
import path from "path";

const DAY_MS = 86400000;

// Maps one GET /api/organizations/<org>/subscription_details response (HTTP status + parsed
// JSON body, or null) to { period, autoRenew, renewalAt, loggedOut, managedByAdmin }.
// next_charge_at is the next renewal (or the end date of a cancelled plan); plan_ending_at is
// null while the plan auto-renews. A team member who is not the billing admin gets a 403
// permission_error: that is a fact about the account, not a failure, so it is flagged.
const PERIODS = { month: "monthly", monthly: "monthly", year: "annual", yearly: "annual", annual: "annual" };

export function billingFromSubscription(status, body) {
    const none = { period: "unknown", autoRenew: null, renewalAt: null, loggedOut: false, managedByAdmin: false };
    if (status === 401) return { ...none, loggedOut: true };
    if (status === 403 && body?.error?.type === "permission_error") return { ...none, managedByAdmin: true };
    const charge = Date.parse(body?.next_charge_at);
    if (status < 200 || status >= 300 || Number.isNaN(charge)) return none;
    return {
        ...none,
        period: PERIODS[String(body.billing_interval).toLowerCase()] ?? "unknown",
        autoRenew: body.plan_ending_at == null,
        renewalAt: new Date(charge).toISOString(),
    };
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

// Records only values actually read; a null never overwrites a good cached value. The admin
// flag is dropped on a fresh date or once the account is confirmed free (paid === false); a
// failed request carries neither, so it keeps the flag.
export function recordBilling(cache, name, { renewalAt, autoRenew, managedByAdmin, paid }, now = new Date()) {
    const entry = cache[name] ?? {};
    if (renewalAt || paid === false) delete entry.managedByAdmin;
    if (renewalAt) entry.renewalAt = stamp(renewalAt, now);
    else if (managedByAdmin === true) entry.managedByAdmin = stamp(true, now);
    if (typeof autoRenew === "boolean") entry.autoRenew = stamp(autoRenew, now);
    cache[name] = entry;
}

export function recordWeeklyReset(cache, name, resetsAt, now = new Date()) {
    // Only a FUTURE reset is worth remembering; a past one must not clobber a good cached value.
    if (!resetsAt || !(Date.parse(resetsAt) > now.getTime())) return;
    cache[name] = { ...(cache[name] ?? {}), weeklyResetAt: stamp(new Date(resetsAt).toISOString(), now) };
}

function futureTime(field, now) {
    const t = field ? Date.parse(field.value) : NaN;
    return t > now.getTime() ? t : null;
}

// A fetch is needed only when the renewal date is missing or past, or auto-renew was never read.
export function needsFetch(entry, now = new Date()) {
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
