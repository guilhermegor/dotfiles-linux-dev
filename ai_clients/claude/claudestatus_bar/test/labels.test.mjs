import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
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

test("addCommand builds the claudestatus add line with the trimmed name", () => {
    assert.deepEqual(addCommand(" work2 "), { cmd: "claudestatus", args: ["add", "work2"] });
});
