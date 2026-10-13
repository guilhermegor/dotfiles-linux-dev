// Account labels for the popover (#751): a hand-editable {"<account>": "<label>"} file in
// ${XDG_CONFIG_HOME:-~/.config}/claudestatus-bar/labels.json. Never touches the claudestatus
// accounts directory.
//
//   node labels.mjs get                 -> labels JSON on stdout
//   node labels.mjs set <name> <label>  -> save (empty label clears)

import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

export function labelsPath() {
    const base = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config");
    return path.join(base, "claudestatus-bar", "labels.json");
}

// A missing, unreadable or malformed file (the owner edits it by hand) reads as no labels.
export function readLabels(file = labelsPath()) {
    try {
        const data = JSON.parse(fs.readFileSync(file, "utf8"));
        if (!data || typeof data !== "object" || Array.isArray(data)) return {};
        return Object.fromEntries(Object.entries(data).filter(([, v]) => typeof v === "string"));
    } catch {
        return {};
    }
}

const LOCK_WAIT_MS = 5000;
const LOCK_STALE_MS = 10000;

// Saves are separate processes doing read-modify-write, so they take a mkdir lock (atomic on every
// filesystem) around the whole step. A holder that crashed leaves the lock behind, so one older than
// LOCK_STALE_MS is broken. ponytail: two waiters breaking the same stale lock can both proceed;
// needs a crash plus two saves in the same 20 ms, switch to flock via a helper if it ever shows.
function withLock(file, waitMs, fn) {
    const lock = `${file}.lock`;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const deadline = Date.now() + waitMs;
    for (;;) {
        try {
            fs.mkdirSync(lock);
            break;
        } catch (e) {
            if (e.code !== "EEXIST") throw e;
            try {
                if (Date.now() - fs.statSync(lock).mtimeMs > LOCK_STALE_MS) fs.rmdirSync(lock);
            } catch { /* released meanwhile */ }
            if (Date.now() > deadline) throw new Error("labels file is locked by another save");
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
        }
    }
    try {
        return fn();
    } finally {
        fs.rmdirSync(lock);
    }
}

// Empty (or whitespace) label removes the entry. Written via rename so a reader (`get`, or a hand
// edit) never sees a half-written file, which would read as "no labels".
export function setLabel(name, label, file = labelsPath(), waitMs = LOCK_WAIT_MS) {
    return withLock(file, waitMs, () => {
        const labels = readLabels(file);
        const text = String(label ?? "").trim();
        if (text) labels[name] = text;
        else delete labels[name];
        const tmp = `${file}.${process.pid}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(labels, null, 2) + "\n");
        fs.renameSync(tmp, file);
        return labels;
    });
}

// Returns an error message, or null when the name may be added.
export function validateName(name, existing = []) {
    const n = String(name ?? "").trim();
    if (!n) return "Name is required";
    if (n.includes("/")) return "Name must not contain '/'";
    if (existing.includes(n)) return `Account '${n}' already exists`;
    return null;
}

// The existing claudestatus add/login flow; the browser login it opens is expected.
export function addCommand(name) {
    return { cmd: "claudestatus", args: ["add", String(name).trim()] };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const [op, name, label] = process.argv.slice(2);
    if (op === "get") process.stdout.write(JSON.stringify(readLabels()));
    else if (op === "set" && name) {
        try {
            setLabel(name, label);
        } catch (e) {
            console.error(`Could not save the label: ${e.message}`);
            process.exit(1);
        }
    } else {
        console.error("usage: labels.mjs get | set <name> <label>");
        process.exit(2);
    }
}
