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

// Empty (or whitespace) label removes the entry.
export function setLabel(name, label, file = labelsPath()) {
    const labels = readLabels(file);
    const text = String(label ?? "").trim();
    if (text) labels[name] = text;
    else delete labels[name];
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(labels, null, 2) + "\n");
    return labels;
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
    else if (op === "set" && name) setLabel(name, label);
    else {
        console.error("usage: labels.mjs get | set <name> <label>");
        process.exit(2);
    }
}
