// Runnable check for claudestatus billing mapping + cache (node tests/claudestatus_billing.test.mjs).
// Run by tests/claudestatus_billing.bats.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "csbill-"));
process.env.CLAUDESTATUS_CACHE_FILE = path.join(tmp, "sub", "billing.json");
const here = path.dirname(fileURLToPath(import.meta.url));
const m = await import(path.join(here, "../ai_clients/claude/lib/claudestatus_billing.mjs"));

const NOW = new Date("2026-10-12T12:00:00Z");

// --- subscription_details mapping (fabricated shapes, no real account data) ---------------
const renewing = m.billingFromSubscription(200, {
    next_charge_at: "2026-11-06T09:30:00Z", plan_ending_at: null, status: "active", billing_interval: "month",
});
assert.deepEqual(renewing, {
    period: "monthly", autoRenew: true, renewalAt: "2026-11-06T09:30:00.000Z", loggedOut: false, managedByAdmin: false,
});
const cancelled = m.billingFromSubscription(200, {
    next_charge_at: "2026-10-20T09:30:00Z", plan_ending_at: "2026-10-20T09:30:00Z", status: "active", billing_interval: "year",
});
assert.equal(cancelled.autoRenew, false, "plan_ending_at set means the plan is cancelled");
assert.equal(cancelled.renewalAt, "2026-10-20T09:30:00.000Z");
assert.equal(cancelled.period, "annual");
const admin = m.billingFromSubscription(403, { error: { type: "permission_error", message: "x" } });
assert.equal(admin.managedByAdmin, true);
assert.equal(admin.renewalAt, null);
assert.equal(admin.loggedOut, false);
assert.equal(m.billingFromSubscription(403, null).managedByAdmin, false, "a Cloudflare 403 is not the admin note");
const out = m.billingFromSubscription(401, { error: { type: "authentication_error" } });
assert.equal(out.loggedOut, true);
assert.equal(out.managedByAdmin, false);
for (const [status, body] of [[500, null], [200, {}], [200, { next_charge_at: "garbage" }]]) {
    const r = m.billingFromSubscription(status, body);
    assert.deepEqual([r.renewalAt, r.autoRenew, r.loggedOut, r.managedByAdmin], [null, null, false, false]);
}

// a past API reset must not overwrite a future cached one
const wc = {};
m.recordWeeklyReset(wc, "a", "2026-10-15T09:00:00Z", NOW);
m.recordWeeklyReset(wc, "a", "2026-10-01T09:00:00Z", NOW);
assert.equal(wc.a.weeklyResetAt.value, "2026-10-15T09:00:00.000Z");
assert.equal(m.effectiveWeeklyReset(wc.a, "2026-10-01T09:00:00Z", NOW), "2026-10-15T09:00:00.000Z");

// --- cache: round-trip, no secrets, staleness ----------------------------------------------
assert.deepEqual(m.loadCache(), {});
const cache = {};
m.recordBilling(cache, "work", { renewalAt: "2026-11-05T12:00:00.000Z", autoRenew: true }, NOW);
m.recordWeeklyReset(cache, "work", "2026-10-15T09:00:00Z", NOW);
m.recordBilling(cache, "work", { renewalAt: null, autoRenew: null }, NOW); // null must not clobber
m.saveCache(cache);
assert.equal(fs.statSync(process.env.CLAUDESTATUS_CACHE_FILE).mode & 0o777, 0o600);
const back = m.loadCache();
assert.equal(back.work.renewalAt.value, "2026-11-05T12:00:00.000Z");
assert.equal(back.work.renewalAt.readAt, NOW.toISOString());
assert.deepEqual(Object.keys(back.work).sort(), ["autoRenew", "renewalAt", "weeklyResetAt"]);

assert.equal(m.needsFetch(back.work, NOW), false);
assert.equal(m.needsFetch(undefined, NOW), true);
assert.equal(m.needsFetch(back.work, new Date("2026-11-06T00:00:00Z")), true, "past renewal");
assert.equal(m.needsFetch({ renewalAt: back.work.renewalAt }, NOW), true, "auto-renew never read");
const fromCache = m.billingFromCache(back.work, NOW);
assert.equal(fromCache.daysLeft, 24);
assert.equal(fromCache.autoRenew, true);

// the team-admin flag is recorded, and dropped again once a real date is read
const team = {};
m.recordBilling(team, "w", { renewalAt: null, autoRenew: null, managedByAdmin: true }, NOW);
assert.equal(team.w.managedByAdmin.value, true);
assert.equal(m.needsFetch(team.w, NOW), true, "no date yet, so the next refresh asks again");
m.recordBilling(team, "w", { renewalAt: "2026-11-05T12:00:00.000Z", autoRenew: true }, NOW);
assert.equal(team.w.managedByAdmin, undefined);

// ...or once the account is confirmed free; a failed read (paid unknown) keeps the flag
m.recordBilling(team, "f", { renewalAt: null, autoRenew: null, managedByAdmin: true }, NOW);
m.recordBilling(team, "f", { renewalAt: null, autoRenew: null, managedByAdmin: false, paid: null }, NOW);
assert.equal(team.f.managedByAdmin.value, true, "a failed request keeps the flag");
m.recordBilling(team, "f", { renewalAt: null, autoRenew: null, managedByAdmin: false, paid: false }, NOW);
assert.equal(team.f.managedByAdmin, undefined, "a confirmed free account drops it");

// --- weekly reset: API wins when future, else cache, else null ----------------------------------
assert.equal(m.effectiveWeeklyReset(back.work, "2026-10-16T00:00:00Z", NOW), "2026-10-16T00:00:00Z");
assert.equal(m.effectiveWeeklyReset(back.work, null, NOW), "2026-10-15T09:00:00.000Z");
assert.equal(m.effectiveWeeklyReset(back.work, null, new Date("2026-10-16T00:00:00Z")), null);

// --- corrupt cache is ignored, not fatal -----------------------------------------------------
fs.writeFileSync(process.env.CLAUDESTATUS_CACHE_FILE, "{not json");
const realError = console.error;
console.error = () => {};
assert.deepEqual(m.loadCache(), {});
console.error = realError;

// --- fetchBillingForAccount against a fake `request` context -------------------------------
// The block is a fragment injected into claudestatus's api.js and leans on that file's globals,
// so stub them, append an export, and load it as a module of its own. No browser is involved:
// the fake has no chromium, so any attempt to launch one would throw.
const libDir = path.join(here, "../ai_clients/claude/lib");
const storagePath = path.join(tmp, "storage.json");
fs.writeFileSync(storagePath, JSON.stringify({ cookies: [], origins: [] }));

const routes = {};
const seen = [];
const reply = (status, body) => ({
    ok: () => status >= 200 && status < 300,
    status: () => status,
    json: async () => {
        if (body === undefined) throw new Error("not json");
        return body;
    },
});
globalThis.__csStub = {
    request: {
        async newContext() {
            return {
                async get(url) {
                    seen.push(url);
                    return routes[url] ??reply(404, {});
                },
                async dispose() {},
            };
        },
    },
    fs,
    CLAUDE_URL: "https://claude.ai",
    USER_AGENT: "test",
    getStorageStatePath: () => storagePath,
    classifyPlan: (caps) => (caps?.includes("claude_pro") ? "pro" : "unknown"),
};
const fragment = fs.readFileSync(path.join(libDir, "claudestatus_api_billing.js"), "utf8");
const harness = path.join(tmp, "api_billing_harness.mjs");
fs.writeFileSync(harness, [
    `import { billingFromCache, billingFromSubscription, loadCache, needsFetch, recordBilling, saveCache } from ${JSON.stringify(path.join(libDir, "claudestatus_billing.mjs"))};`,
    "const { request, fs, CLAUDE_URL, USER_AGENT, getStorageStatePath, classifyPlan } = globalThis.__csStub;",
    fragment,
].join("\n"));
const { fetchBillingForAccount, fetchAllBilling } = await import(harness);

const orgs = reply(200, [{ uuid: "org-1", capabilities: ["chat", "claude_pro"] }]);
const detail = reply(200, { billing_type: "stripe_subscription" });
const sub = "/api/organizations/org-1/subscription_details";
const setRoutes = (subscription, organizations = orgs) => {
    for (const k of Object.keys(routes)) delete routes[k];
    Object.assign(routes, {
        "/api/organizations": organizations,
        "/api/organizations/org-1": detail,
        [sub]: subscription,
    });
    seen.length = 0;
};
const realLog = console.error;
console.error = () => {};

setRoutes(reply(200, { next_charge_at: "2099-11-06T09:30:00Z", plan_ending_at: null, billing_interval: "month" }));
let r = await fetchBillingForAccount("a", undefined);
assert.deepEqual([r.billingDate, r.autoRenew, r.period, r.loggedOut, r.managedByAdmin],
    ["2099-11-06T09:30:00.000Z", true, "monthly", false, false]);

setRoutes(reply(200, { next_charge_at: "2099-10-20T09:30:00Z", plan_ending_at: "2099-10-20T09:30:00Z" }));
r = await fetchBillingForAccount("a", undefined);
assert.equal(r.autoRenew, false);

setRoutes(reply(403, { error: { type: "permission_error" } }));
r = await fetchBillingForAccount("a", undefined);
assert.deepEqual([r.billingDate, r.managedByAdmin, r.loggedOut], [null, true, false]);

setRoutes(reply(401, {}));
r = await fetchBillingForAccount("a", undefined);
assert.deepEqual([r.billingDate, r.managedByAdmin, r.loggedOut], [null, false, true]);

setRoutes(reply(200, {}), reply(401, {}));
r = await fetchBillingForAccount("a", undefined);
assert.equal(r.loggedOut, true, "expired session already shows on the organizations call");
assert.equal(seen.includes(sub), false);

// a cached future renewal date needs no subscription call at all
setRoutes(reply(200, {}));
const cached = {};
m.recordBilling(cached, "a", { renewalAt: "2099-11-06T09:30:00.000Z", autoRenew: true });
r = await fetchBillingForAccount("a", cached.a);
assert.equal(r.fromCache, true);
assert.equal(seen.includes(sub), false);

// the team-admin verdict reaches the cache, which is what the popover reads
setRoutes(reply(403, { error: { type: "permission_error" } }));
fs.rmSync(process.env.CLAUDESTATUS_CACHE_FILE, { force: true });
const realWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = () => true;
const realConsoleLog = console.log;
console.log = () => {};
await fetchAllBilling(["a"]);
process.stdout.write = realWrite;
console.log = realConsoleLog;
assert.equal(m.loadCache().a.managedByAdmin.value, true);

// the account later turns out free (billing_type "none"): the stale admin message must go
Object.assign(routes, { "/api/organizations/org-1": reply(200, { billing_type: "none" }) });
process.stdout.write = () => true;
console.log = () => {};
await fetchAllBilling(["a"]);
process.stdout.write = realWrite;
console.log = realConsoleLog;
assert.equal(m.loadCache().a.managedByAdmin, undefined);
console.error = realLog;

fs.rmSync(tmp, { recursive: true });
console.log("ok");
