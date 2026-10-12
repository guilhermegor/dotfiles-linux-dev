// Runnable check for claudestatus billing parsing + cache (node tests/claudestatus_billing.test.mjs).
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

// --- parsing: PT and EN, renew vs cancel, relative banner --------------------------------
const cases = [
    ["Plano Pro Mensal. Sua assinatura será renovada automaticamente em 5 de nov. de 2026.", "2026-11-05", true],
    ["Próxima cobrança: 15 de dezembro de 2026\nR$ 100,00", "2026-12-15", true],
    ["Sua assinatura será cancelada em 20 de out. de 2026", "2026-10-20", false],
    ["Your subscription will auto-renew on November 5, 2026.", "2026-11-05", true],
    ["Next billing date\nNov 5, 2026", "2026-11-05", true],
    ["Your subscription cancels on Oct 30, 2026", "2026-10-30", false],
    ["Your plan will not renew. Ends on 3 Nov 2026", "2026-11-03", false],
];
for (const [text, day, auto] of cases) {
    const p = m.parseBillingText(text, NOW);
    assert.equal(p.renewalAt?.slice(0, 10), day, text);
    assert.equal(p.autoRenew, auto, text);
}
// negation placed before the keyword; a past "paid on" date must not hide the next renewal
for (const t of ["Your subscription will not renew on November 5, 2026",
                 "Sua assinatura não será renovada em 5 de nov. de 2026"]) {
    assert.equal(m.parseBillingText(t, NOW).autoRenew, false, t);
}
const hist = m.parseBillingText("Paid on Oct 5, 2026. Next billing date Nov 5, 2026", NOW);
assert.equal(hist.renewalAt.slice(0, 10), "2026-11-05");
assert.equal(hist.autoRenew, true);
// a past API reset must not overwrite a future cached one
const wc = {};
m.recordWeeklyReset(wc, "a", "2026-10-15T09:00:00Z", NOW);
m.recordWeeklyReset(wc, "a", "2026-10-01T09:00:00Z", NOW);
assert.equal(wc.a.weeklyResetAt.value, "2026-10-15T09:00:00.000Z");
assert.equal(m.effectiveWeeklyReset(wc.a, "2026-10-01T09:00:00Z", NOW), "2026-10-15T09:00:00.000Z");
const rel = m.parseBillingText("Seu plano termina em 12 dias", NOW);
assert.equal(rel.renewalAt, "2026-10-24T12:00:00.000Z");
const none = m.parseBillingText("Settings Billing Plan Upgrade plan Fazer upgrade", NOW);
assert.deepEqual([none.renewalAt, none.autoRenew], [null, null]);

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

assert.equal(m.needsScrape(back.work, NOW), false);
assert.equal(m.needsScrape(undefined, NOW), true);
assert.equal(m.needsScrape(back.work, new Date("2026-11-06T00:00:00Z")), true, "past renewal");
assert.equal(m.needsScrape({ renewalAt: back.work.renewalAt }, NOW), true, "auto-renew never read");
const fromCache = m.billingFromCache(back.work, NOW);
assert.equal(fromCache.daysLeft, 24);
assert.equal(fromCache.autoRenew, true);

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

fs.rmSync(tmp, { recursive: true });
console.log("ok");
