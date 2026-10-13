import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import test, { after } from "node:test";
import { fileURLToPath } from "node:url";
import { addCommand, labelsPath, readLabels, setLabel, validateName } from "../labels.mjs";

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "labels-"));
after(() => fs.rmSync(dir, { recursive: true, force: true }));
const file = (n) => path.join(dir, n, "sub", "labels.json");

test("missing file reads as no labels", () => {
    assert.deepEqual(readLabels(file("missing")), {});
});

test("malformed or non-object file reads as no labels; non-string values dropped", () => {
    const f = file("bad");
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, "{oops");
    assert.deepEqual(readLabels(f), {});
    fs.writeFileSync(f, '["a"]');
    assert.deepEqual(readLabels(f), {});
    fs.writeFileSync(f, '{"a":"x","b":3}');
    assert.deepEqual(readLabels(f), { a: "x" });
});

test("write creates the directory, round-trips and keeps other labels", () => {
    const f = file("rw");
    setLabel("work", " company email ", f);
    setLabel("home", "personal", f);
    assert.deepEqual(readLabels(f), { work: "company email", home: "personal" });
});

test("empty label clears the entry", () => {
    const f = file("clear");
    setLabel("work", "x", f);
    setLabel("work", "  ", f);
    assert.deepEqual(readLabels(f), {});
});

test("labelsPath honours XDG_CONFIG_HOME", () => {
    const prev = process.env.XDG_CONFIG_HOME;
    process.env.XDG_CONFIG_HOME = "/tmp/xdg";
    try {
        assert.equal(labelsPath(), "/tmp/xdg/claudestatus-bar/labels.json");
    } finally {
        if (prev === undefined) delete process.env.XDG_CONFIG_HOME;
        else process.env.XDG_CONFIG_HOME = prev;
    }
});

test("validateName rejects empty, slash and existing; accepts a fresh name", () => {
    assert.match(validateName("", []), /required/);
    assert.match(validateName("   ", []), /required/);
    assert.match(validateName("a/b", []), /'\/'/);
    assert.match(validateName("work", ["work"]), /already exists/);
    assert.equal(validateName("new", ["work"]), null);
});

test("a save waits for the lock and gives up with a clear error", () => {
    const f = file("locked");
    fs.mkdirSync(`${f}.lock`, { recursive: true });
    assert.throws(() => setLabel("a", "x", f, 60), /locked by another save/);
    assert.deepEqual(readLabels(f), {});
});

test("a stale lock left by a crashed save is broken", () => {
    const f = file("stale");
    fs.mkdirSync(`${f}.lock`, { recursive: true });
    const old = new Date(Date.now() - 60_000);
    fs.utimesSync(`${f}.lock`, old, old);
    assert.deepEqual(setLabel("a", "x", f, 60), { a: "x" });
});

test("the lock and temp file are gone after a save", () => {
    const f = file("clean");
    setLabel("a", "x", f);
    assert.deepEqual(fs.readdirSync(path.dirname(f)), ["labels.json"]);
});

const script = fileURLToPath(new URL("../labels.mjs", import.meta.url));

test("CLI set exits 1 with the reason when the file cannot be written", () => {
    const blocker = path.join(dir, "blocker");
    fs.writeFileSync(blocker, "");
    const r = spawnSync(process.execPath, [script, "set", "a", "x"], {
        env: { ...process.env, XDG_CONFIG_HOME: blocker },
        encoding: "utf8",
    });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /Could not save the label: .*ENOTDIR/);
});

test("overlapping saves from separate processes keep every label", async () => {
    const env = { ...process.env, XDG_CONFIG_HOME: path.join(dir, "race") };
    await Promise.all(Array.from({ length: 8 }, (_, i) => new Promise((resolve) => {
        spawn(process.execPath, [script, "set", `acc${i}`, `l${i}`], { env }).on("close", resolve);
    })));
    const got = readLabels(path.join(env.XDG_CONFIG_HOME, "claudestatus-bar", "labels.json"));
    assert.equal(Object.keys(got).length, 8);
});

test("addCommand builds the claudestatus add line with the trimmed name", () => {
    assert.deepEqual(addCommand(" work2 "), { cmd: "claudestatus", args: ["add", "work2"] });
});
