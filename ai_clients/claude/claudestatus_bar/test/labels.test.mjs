import assert from "node:assert/strict";
import test from "node:test";
import { addCommand, validateName } from "../labels.mjs";

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
