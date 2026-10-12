import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { buildModel, countdown } from "../model.mjs";

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
    assert.deepEqual(buildModel({ at: null, accounts: [] }, {}, now), { bar: "—", recommended: null, accounts: [] });
});

test("countdown clamps a past time to now", () => {
    assert.equal(countdown("2026-10-12T11:00:00Z", now), "now");
});
