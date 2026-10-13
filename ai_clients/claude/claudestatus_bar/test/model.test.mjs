import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { buildModel, countdown, resetAt } from "../model.mjs";

const fx = JSON.parse(fs.readFileSync(new URL("./fixture.json", import.meta.url), "utf8"));
const now = new Date(fx.now);
const model = buildModel(fx.usage, fx.cache, now);
const text = (name) => model.accounts.find((a) => a.name === name).text;

test("top bar shows the recommended account's session percent", () => {
    // work is exhausted weekly, lapsed is Free, broken errored -> personal is the only pick
    assert.equal(model.recommended, "personal");
    assert.equal(model.bar, "54%");
});

test("four stacked blocks, in input order", () => {
    assert.deepEqual(model.accounts.map((a) => a.name), ["personal", "work", "lapsed", "broken"]);
});

test("active account shows both bars, countdowns, renewal and data age", () => {
    const t = text("personal");
    assert.match(t, /^personal {2}Pro\n/);
    assert.match(t, /Session {2}█████░░░░░\s+54%\s+resets in 4h39m/);
    assert.match(t, /Weekly\s+███░░░░░░░\s+30%\s+resets in 3d0h/);
    assert.match(t, /Renews 5 Nov {2}· {2}updated 3 min ago/);
});

test("auto-renew off reads Ends, not Renews", () => {
    assert.match(text("work"), /Ends 5 Nov/);
});

test("free plan gets the unpaid badge and a cached weekly reset", () => {
    const t = text("lapsed");
    assert.match(t, /⚠ unpaid/);
    assert.match(t, /Weekly .*resets in 5d0h/);
    assert.match(t, /Renewal unknown/);
});

test("errored account shows the error and no bars", () => {
    assert.match(text("broken"), /✗ Session expired/);
    assert.doesNotMatch(text("broken"), /Session {2}/);
});

test("no usage snapshot yet renders an empty, safe model", () => {
    assert.deepEqual(buildModel({ at: null, accounts: [] }, {}, now), { bar: "—", recommended: null, active: null, activeLine: "active: unknown", accounts: [] });
});

test("countdown clamps a past time to now", () => {
    assert.equal(countdown("2026-10-12T11:00:00Z", now), "now");
});

test("all exhausted: recommends the account that frees up first, like pickNextAccount", async () => {
    const { recommend } = await import("../model.mjs");
    const now = new Date("2026-10-12T12:00:00Z");
    const at = (h) => new Date(now.getTime() + h * 3600e3).toISOString();
    const accounts = [
        { name: "slow", plan: "pro", usage: { five_hour: { utilization: 0 }, seven_day: { utilization: 100, resets_at: at(10) } } },
        { name: "fast", plan: "pro", usage: { five_hour: { utilization: 100, resets_at: at(1) }, seven_day: { utilization: 100, resets_at: at(1) } } },
    ];
    assert.equal(recommend(accounts, now).name, "fast");
});

test("resetAt shows local weekday and 24h time, date only from 7 days out", () => {
    const prev = process.env.TZ;
    process.env.TZ = "UTC";
    try {
        const n = new Date("2026-10-12T10:00:00Z"); // Monday
        assert.equal(resetAt("2026-10-12T21:44:00Z", n), "Mon 21:44");
        assert.equal(resetAt("2026-10-13T00:05:00Z", n), "Tue 00:05");
        assert.equal(resetAt("2026-10-15T08:00:00Z", n), "Thu 08:00");
        assert.equal(resetAt("2026-10-19T10:00:00Z", n), "Mon 19 Oct 10:00");
        process.env.TZ = "America/Sao_Paulo"; // UTC-3
        assert.equal(resetAt("2026-10-12T21:44:00Z", n), "Mon 18:44");
    } finally {
        if (prev === undefined) delete process.env.TZ; else process.env.TZ = prev;
    }
});

test("limit line pairs the countdown with the absolute time; unknown stays unknown", () => {
    assert.match(text("personal"), /resets in 4h39m \(\w{3} \d{2}:\d{2}\)/);
    const m = buildModel({ at: fx.now, accounts: [{ name: "x", plan: "Pro", usage: { five_hour: { utilization: 5, resets_at: null } } }] }, fx.cache, now);
    assert.match(m.accounts[0].text, /reset unknown/);
    const bad = buildModel({ at: fx.now, accounts: [{ name: "x", plan: "Pro", usage: { five_hour: { utilization: 5, resets_at: "not-a-date" } } }] }, fx.cache, now);
    assert.match(bad.accounts[0].text, /reset unknown/);
});

test("team member without billing access reads the admin note, not unknown", () => {
    const cache = { ...fx.cache, lapsed: { ...fx.cache.lapsed, managedByAdmin: { value: true, readAt: fx.now } } };
    const t = buildModel(fx.usage, cache, now).accounts.find((a) => a.name === "lapsed").text;
    assert.match(t, /Billing managed by team admin/);
    assert.doesNotMatch(t, /Renewal unknown/);
});
