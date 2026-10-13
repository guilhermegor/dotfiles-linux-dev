// Injected into claudestatus dist/api.js by patch_claudestatus.sh (between the marker comments).
// Relies on api.js's own imports (chromium, request, fs), CLAUDE_URL, USER_AGENT,
// getProfileDir(), getStorageStatePath() and classifyPlan(); parsing and the date cache come
// from ./billing_cache.js (claudestatus_billing.mjs).
//
// Plan + paid come from the JSON API (no browser). The renewal date and auto-renew state come
// from the billing page, and only when the cache has no future renewal date for the account.
const BILLING_WAIT_MS = 25000;

// Cloudflare-free: read plan + paid status straight from the JSON API.
async function fetchBillingMetaViaApi(storagePath) {
    if (!fs.existsSync(storagePath))
        return { plan: "unknown", paid: null };
    const api = await request.newContext({
        baseURL: CLAUDE_URL,
        storageState: storagePath,
        extraHTTPHeaders: { "User-Agent": USER_AGENT, Accept: "application/json" },
    });
    try {
        const orgsRes = await api.get("/api/organizations");
        if (!orgsRes.ok())
            return { plan: "unknown", paid: null };
        const orgs = await orgsRes.json();
        const org = orgs.find((o) => o.capabilities?.includes("chat")) || orgs[0];
        const plan = classifyPlan(org?.capabilities);
        let paid = plan === "free" ? false : null;
        if (org?.uuid) {
            const detail = await api.get(`/api/organizations/${org.uuid}`);
            if (detail.ok()) {
                const d = await detail.json();
                if (typeof d.billing_type === "string")
                    paid = d.billing_type !== "none";
            }
        }
        return { plan, paid };
    }
    catch {
        return { plan: "unknown", paid: null };
    }
    finally {
        await api.dispose();
    }
}
// Opens the billing page directly. Headless first (nothing on screen); the caller retries
// headed-but-minimized only when Cloudflare blocks the headless run. The off-screen window
// position is a hint the window manager may ignore (Wayland does), so a window can flash.
async function readBillingPage(profileDir, storagePath, headless) {
    const contextOpts = {
        headless,
        channel: "chrome",
        args: [
            "--disable-blink-features=AutomationControlled",
            "--disable-extensions",
            "--window-size=800,600",
            ...(headless ? [] : ["--start-minimized", "--window-position=-32000,-32000"]),
        ],
        ignoreDefaultArgs: ["--enable-automation"],
        viewport: { width: 800, height: 600 },
    };
    const context = await chromium.launchPersistentContext(profileDir, contextOpts);
    try {
        // storageState is ignored by persistent contexts, so add the saved session by hand.
        if (fs.existsSync(storagePath))
            await context.addCookies(cookiesFromStorageState(fs.readFileSync(storagePath, "utf8")));
        const page = context.pages()[0] || (await context.newPage());
        await page.goto(`${CLAUDE_URL}/settings/billing`, { waitUntil: "domcontentloaded", timeout: 30000 });
        if (isLoginPage(page.url()))
            return { text: "", blocked: false, loggedOut: true };
        try {
            await page.getByRole("button", { name: /reject all|accept all/i }).first().click({ timeout: 3000 });
        }
        catch {
            // No cookie banner shown.
        }
        // Wait for the billing card itself (a parseable date), not for words the page chrome
        // already contains ("plan", "billing") -- that returned before the card rendered.
        let text = "";
        let blocked = false;
        const deadline = Date.now() + BILLING_WAIT_MS;
        while (Date.now() < deadline) {
            text = await page.evaluate(() => document.body.innerText || "");
            blocked = isCloudflareChallenge(await page.content());
            if (!blocked && parseBillingText(text).renewalAt)
                break;
            await page.waitForTimeout(1000);
        }
        // The Cloudflare interstitial clears on its own, so only a page STILL showing it at the
        // deadline counts as blocked. Checked on the markup: the visible text is localised.
        return { text, blocked };
    }
    finally {
        // Read-only flow -- never persist storageState (would clobber the session).
        await context.close().catch(() => { });
    }
}
async function scrapeBilling(name, profileDir, storagePath) {
    let text = "";
    for (const headless of [true, false]) {
        try {
            const page = await readBillingPage(profileDir, storagePath, headless);
            if (page.loggedOut) {
                console.error(`claudestatus: session expired for ${name}; run \`claudestatus add ${name}\` again`);
                return { ...parseBillingText(""), loggedOut: true };
            }
            text = page.text;
            // A fully loaded, unblocked page is final even when no date parsed: a headed retry
            // would read the same text. Retry only when blocked or the browser failed.
            if (!page.blocked)
                break;
        }
        catch {
            // Navigation / launch failure: fall through to the headed retry, then give up.
        }
    }
    const parsed = parseBillingText(text);
    if (!parsed.renewalAt && text) {
        // Always keep the page text when nothing parsed, so the regexes can be fixed from it.
        try {
            fs.writeFileSync(`/tmp/claudestatus_billing_${name}.txt`, text, { mode: 0o600 });
        }
        catch (err) {
            console.error(`claudestatus: cannot write billing dump for ${name}: ${err.message}`);
        }
    }
    return parsed;
}
export async function fetchBillingForAccount(name, cachedEntry) {
    const profileDir = getProfileDir(name);
    const storagePath = getStorageStatePath(name);
    if (!fs.existsSync(profileDir) && !fs.existsSync(storagePath)) {
        return { plan: "unknown", paid: null, period: "unknown", autoRenew: null, billingDate: null, daysLeft: null };
    }
    const meta = await fetchBillingMetaViaApi(storagePath);
    const base = { plan: meta.plan, paid: meta.paid, period: "unknown", autoRenew: null, billingDate: null, daysLeft: null };
    // Free accounts have no subscription to read -- done, no browser needed.
    if (meta.plan === "free" || meta.paid === false) {
        return { ...base, paid: false, period: "free" };
    }
    const paid = meta.paid === null ? true : meta.paid;
    if (!needsScrape(cachedEntry)) {
        return { ...base, ...billingFromCache(cachedEntry), paid, fromCache: true };
    }
    const parsed = await scrapeBilling(name, profileDir, storagePath);
    return {
        ...base,
        period: parsed.period,
        autoRenew: parsed.autoRenew,
        billingDate: parsed.renewalAt,
        daysLeft: parsed.renewalAt ? Math.ceil((Date.parse(parsed.renewalAt) - Date.now()) / 86400000) : null,
        paid,
        fromCache: false,
        loggedOut: parsed.loggedOut === true,
    };
}
export async function fetchAllBilling(accountNames) {
    const cache = loadCache();
    const results = [];
    for (const name of accountNames) {
        process.stdout.write(`  Billing ${name}...`);
        const billing = await fetchBillingForAccount(name, cache[name]);
        if (!billing.fromCache)
            recordBilling(cache, name, { renewalAt: billing.billingDate, autoRenew: billing.autoRenew });
        console.log(billing.fromCache ? " cached" : " done");
        results.push({ name, ...billing });
    }
    saveCache(cache);
    return results;
}
