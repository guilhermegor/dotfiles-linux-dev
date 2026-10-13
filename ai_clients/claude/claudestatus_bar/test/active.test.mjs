import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { buildModel, detectActive } from "../model.mjs";

const fx = JSON.parse(fs.readFileSync(new URL("./fixture.json", import.meta.url), "utf8"));
const now = new Date(fx.now);
const accounts = fx.usage.accounts.map((a, i) => ({ ...a, orgUuid: `org-${i}` }));
const usage = { ...fx.usage, accounts };
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "active-"));
const claudeJson = (obj) => {
    const f = path.join(dir, `c${Math.random()}.json`);
    fs.writeFileSync(f, JSON.stringify(obj));
    return f;
};

test("match: org UUID maps to the account, marks its block and leads the bar", () => {
    const active = detectActive(accounts, claudeJson({ oauthAccount: { organizationUuid: "org-1" } }));
    assert.equal(active, accounts[1].name);
    const m = buildModel(usage, fx.cache, now, active);
    assert.equal(m.activeLine, `active: ${accounts[1].name}`);
    assert.match(m.accounts[1].text, /^work {2}\w+ {2}● active\n/);
    assert.doesNotMatch(m.accounts[0].text, /● active/);
    assert.match(m.bar, new RegExp(`^${accounts[1].name} \\d+%$`));
});

test("no match: unknown, bar falls back to the recommended percent", () => {
    const active = detectActive(accounts, claudeJson({ oauthAccount: { organizationUuid: "other" } }));
    assert.equal(active, null);
    const m = buildModel(usage, fx.cache, now, active);
    assert.equal(m.activeLine, "active: unknown");
    assert.equal(m.bar, "54%");
});

test("missing ~/.claude.json: unknown", () => {
    assert.equal(detectActive(accounts, path.join(dir, "nope.json")), null);
});

test("missing oauthAccount: unknown", () => {
    assert.equal(detectActive(accounts, claudeJson({ projects: {} })), null);
});

test("ambiguous org (two accounts share it): unknown, never guess", () => {
    const dup = accounts.map((a) => ({ ...a, orgUuid: "same" }));
    assert.equal(detectActive(dup, claudeJson({ oauthAccount: { organizationUuid: "same" } })), null);
});
