// Add-account helpers shared by refresh.mjs (#751). The file keeps its name although the account
// labels it used to store are gone (#803): install_claudestatus_bar copies it by name.

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
