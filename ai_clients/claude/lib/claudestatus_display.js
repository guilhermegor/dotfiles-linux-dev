import chalk from "chalk";
import Table from "cli-table3";
import { effectiveWeeklyReset, loadCache, recordWeeklyReset, saveCache } from "./billing_cache.js";

function formatResetTime(isoString) {
    const date = new Date(isoString);
    const now = new Date();
    const diffMs = date.getTime() - now.getTime();
    if (diffMs < 0) return "now";
    const diffMins = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMins / 60);
    const diffDays = Math.floor(diffHours / 24);
    if (diffMins < 60) {
        return `${diffMins}m`;
    } else if (diffHours < 24) {
        const mins = diffMins % 60;
        return mins > 0 ? `${diffHours}h ${mins}m` : `${diffHours}h`;
    } else {
        const hours = diffHours % 24;
        return hours > 0 ? `${diffDays}d ${hours}h` : `${diffDays}d`;
    }
}

function usageBar(percent, width = 8) {
    const filled = Math.round((percent / 100) * width);
    const empty = width - filled;
    let color = chalk.green;
    if (percent >= 90) color = chalk.red;
    else if (percent >= 70) color = chalk.yellow;
    return color("█".repeat(filled)) + chalk.gray("░".repeat(empty));
}

function formatUsageCell(limit) {
    if (!limit) return chalk.gray("—");
    const bar = usageBar(limit.utilization);
    const pct = limit.utilization.toString().padStart(3) + "%";
    const reset = chalk.gray("   ↻" + formatResetTime(limit.resets_at));
    return `${bar} ${pct}${reset}`;
}

function planLabel(plan) {
    if (plan === "max") return chalk.magenta("Max");
    if (plan === "team") return chalk.blue("Team");
    if (plan === "free") return chalk.red("Free");
    if (plan === "pro") return chalk.cyan("Pro");
    return chalk.gray("—");
}

function formatStatusCell(account) {
    if (account.error) return chalk.red("✗ Error");
    if (account.plan === "free") return chalk.red("✗ Free");
    if (account.plan === "unknown") return chalk.yellow("? Unknown");
    return chalk.green("✓ Active");
}

function getAvailability(account) {
    if (account.error) {
        return { status: "error", waitLabel: account.error, waitMs: Number.POSITIVE_INFINITY, reason: "none" };
    }
    // A Free account cannot run Claude Code work — never recommend it.
    if (account.plan === "free") {
        return { status: "unusable", waitLabel: "Upgrade", waitMs: Number.POSITIVE_INFINITY, reason: "free" };
    }
    const weekly = account.usage.seven_day;
    const session = account.usage.five_hour;
    // Every exhausted limit must reset before the account is usable, so the LATER reset decides.
    // An exhausted limit with no readable reset time is an unknown (infinite) wait, never NaN.
    const exhausted = [["weekly", weekly], ["session", session]].filter(([, l]) => l && l.utilization >= 100);
    if (exhausted.length > 0) {
        const waits = exhausted.map(([reason, l]) => {
            const t = new Date(l.resets_at).getTime();
            const waitMs = Number.isNaN(t) ? Number.POSITIVE_INFINITY : Math.max(0, t - Date.now());
            return { reason, waitMs, waitLabel: Number.isNaN(t) ? "?" : formatResetTime(l.resets_at) };
        });
        const worst = waits.reduce((a, b) => (b.waitMs > a.waitMs ? b : a));
        return { status: worst.waitMs <= 0 ? "available" : "wait", ...worst };
    }
    return { status: "available", waitLabel: "now", waitMs: 0, reason: "none" };
}

function formatNextUseLabel(availability) {
    if (availability.status === "unusable") return chalk.red("Upgrade req.");
    if (availability.status === "available" || availability.waitLabel === "now") return chalk.green("Use now");
    if (availability.reason === "weekly") return chalk.yellow(`Wait until ${availability.waitLabel}`);
    return chalk.yellow(`Wait ${availability.waitLabel}`);
}

function pickNextAccount(accounts) {
    // Exclude error rows and Free accounts (Free cannot be used for Pro work).
    const available = accounts.filter((a) => !a.error && a.plan !== "free");
    if (available.length === 0) return null;
    const scored = available.map((account) => ({
        account,
        availability: getAvailability(account),
        score: (account.usage.five_hour?.utilization ?? 0) + (account.usage.seven_day?.utilization ?? 0),
    }));
    const usable = scored.filter((entry) => entry.availability.status === "available");
    if (usable.length > 0) return usable.reduce((a, b) => (a.score <= b.score ? a : b));
    return scored.reduce((a, b) => {
        if (a.availability.waitMs === b.availability.waitMs) return a.score <= b.score ? a : b;
        return a.availability.waitMs <= b.availability.waitMs ? a : b;
    });
}

// The weekly reset is an absolute time: remember the API's value, and when the API omits or
// has already passed it, count down from the remembered one instead of showing "now".
function cacheWeeklyReset(cache, account) {
    const weekly = account.usage.seven_day;
    if (!weekly) return;
    recordWeeklyReset(cache, account.name, weekly.resets_at);
    const resetsAt = effectiveWeeklyReset(cache[account.name], weekly.resets_at);
    if (resetsAt) weekly.resets_at = resetsAt;
}

export function displayUsageTable(accounts) {
    console.log();
    console.log(chalk.bold("  Claude Usage Dashboard"));
    console.log(chalk.gray("  Note: 'Days left' shows rate-limit window resets, not billing renewal dates."));
    console.log();
    const table = new Table({
        head: [chalk.bold("Account"), chalk.bold("Plan"), chalk.bold("Status"), chalk.bold("Session (5h)"), chalk.bold("Weekly (7d)"), chalk.bold("Next Use")],
        style: { head: [], border: [] },
        colWidths: [14, 6, 12, 30, 30, 20],
    });
    const cache = loadCache();
    for (const account of accounts) {
        if (!account.error) cacheWeeklyReset(cache, account);
        const availability = getAvailability(account);
        if (account.error) {
            table.push([chalk.yellow(account.name), chalk.gray("—"), chalk.red("✗ Error"), chalk.gray("—"), chalk.gray("—"), chalk.red(account.error.split(".")[0])]);
            continue;
        }
        table.push([
            account.name,
            planLabel(account.plan),
            formatStatusCell(account),
            formatUsageCell(account.usage.five_hour),
            formatUsageCell(account.usage.seven_day),
            formatNextUseLabel(availability),
        ]);
    }
    saveCache(cache);
    console.log(table.toString());
    console.log();
    const next = pickNextAccount(accounts);
    if (next) {
        const nextUseLabel = next.availability.status === "available" ? "Use now" : `Wait ${next.availability.waitLabel}`;
        console.log(chalk.cyan("  💡 Recommendation: ") + chalk.bold(next.account.name) + chalk.gray(` (${nextUseLabel})`));
        console.log();
    }
}

export function displayBillingTable(billingData) {
    console.log(chalk.bold("  Billing Status"));
    console.log();
    const table = new Table({
        head: [chalk.bold("Account"), chalk.bold("Plan"), chalk.bold("Paid"), chalk.bold("Renewal"), chalk.bold("Auto-Renew")],
        style: { head: [], border: [] },
        colWidths: [14, 8, 9, 21, 13],
    });
    for (const b of billingData) {
        const paidLabel = b.paid === true ? chalk.green("✓ Paid") : b.paid === false ? chalk.gray("Free") : chalk.gray("—");
        let renewal = chalk.gray("—");
        if (b.billingDate) {
            const d = new Date(b.billingDate);
            // Count down from the absolute date so a cached value stays correct between scrapes.
            const days = Math.ceil((d.getTime() - Date.now()) / 86400000);
            const dateStr = d.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
            renewal = `${days <= 0 ? chalk.red("expired") : days + "d"} · ${dateStr}`;
        } else if (b.daysLeft != null) {
            renewal = b.daysLeft <= 0 ? chalk.red("expired") : `~${b.daysLeft}d`;
        } else if (b.error) {
            renewal = chalk.yellow(b.error.split("—")[0].trim());
        }
        const autoRenewLabel = b.autoRenew === true ? chalk.green("✓ Auto") : b.autoRenew === false ? chalk.red("✗ Expires") : chalk.gray("—");
        table.push([b.name, planLabel(b.plan), paidLabel, renewal, autoRenewLabel]);
    }
    console.log(table.toString());
    console.log();
}

export function displayQuickRecommendation(accounts) {
    // Quick mode skips displayUsageTable, so apply the cached weekly reset here too.
    const cache = loadCache();
    for (const account of accounts) if (!account.error) cacheWeeklyReset(cache, account);
    saveCache(cache);
    const next = pickNextAccount(accounts);
    if (!next) {
        console.log(chalk.red("No accounts available. Run: claudestatus add <name>"));
        return;
    }
    const nextUseLabel = next.availability.status === "available" ? "Use now" : `Wait ${next.availability.waitLabel}`;
    console.log(`${next.account.name} (${nextUseLabel})`);
}
