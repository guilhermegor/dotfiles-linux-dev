// Injected into claudestatus dist/api.js by patch_claudestatus.sh (between the marker comments).
// Relies on api.js's own imports (request, fs), CLAUDE_URL, USER_AGENT,
// getStorageStatePath() and classifyPlan(); parsing and the date cache come
// from ./billing_cache.js (claudestatus_billing.mjs).
//
// Plan, paid, renewal date and auto-renew all come from claude.ai's JSON API over the saved
// session (no browser, so no window ever opens); the subscription call runs only when the cache
// has no future renewal date for the account.
function newApiContext(storagePath) {
    return request.newContext({
        baseURL: CLAUDE_URL,
        storageState: storagePath,
        extraHTTPHeaders: { "User-Agent": USER_AGENT, Accept: "application/json" },
    });
}
// Plan + paid status straight from the JSON API; orgUuid is only passed on to the next call.
async function fetchBillingMetaViaApi(storagePath) {
    const api = await newApiContext(storagePath);
    try {
        const orgsRes = await api.get("/api/organizations");
        if (orgsRes.status() === 401)
            return { plan: "unknown", paid: null, loggedOut: true };
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
        return { plan, paid, orgUuid: org?.uuid };
    }
    catch {
        return { plan: "unknown", paid: null };
    }
    finally {
        await api.dispose();
    }
}
// Renewal date + auto-renew from the subscription endpoint; the mapping is billingFromSubscription.
async function fetchSubscriptionViaApi(storagePath, orgUuid) {
    const api = await newApiContext(storagePath);
    try {
        const res = await api.get(`/api/organizations/${orgUuid}/subscription_details`);
        const body = await res.json().catch(() => null);
        return billingFromSubscription(res.status(), body);
    }
    catch {
        return billingFromSubscription(0, null);
    }
    finally {
        await api.dispose();
    }
}
export async function fetchBillingForAccount(name, cachedEntry) {
    const storagePath = getStorageStatePath(name);
    if (!fs.existsSync(storagePath)) {
        return { plan: "unknown", paid: null, period: "unknown", autoRenew: null, billingDate: null, daysLeft: null };
    }
    const meta = await fetchBillingMetaViaApi(storagePath);
    const base = { plan: meta.plan, paid: meta.paid, period: "unknown", autoRenew: null, billingDate: null, daysLeft: null };
    if (meta.loggedOut) {
        console.error(`claudestatus: session expired for ${name}; run \`claudestatus add ${name}\` again`);
        return { ...base, fromCache: false, loggedOut: true };
    }
    // Free accounts have no subscription to read.
    if (meta.plan === "free" || meta.paid === false) {
        return { ...base, paid: false, period: "free" };
    }
    const paid = meta.paid === null ? true : meta.paid;
    if (!needsFetch(cachedEntry)) {
        return { ...base, ...billingFromCache(cachedEntry), paid, fromCache: true };
    }
    const sub = meta.orgUuid ? await fetchSubscriptionViaApi(storagePath, meta.orgUuid) : billingFromSubscription(0, null);
    if (sub.loggedOut) {
        console.error(`claudestatus: session expired for ${name}; run \`claudestatus add ${name}\` again`);
    }
    return {
        ...base,
        period: sub.period,
        autoRenew: sub.autoRenew,
        billingDate: sub.renewalAt,
        daysLeft: sub.renewalAt ? Math.ceil((Date.parse(sub.renewalAt) - Date.now()) / 86400000) : null,
        paid,
        fromCache: false,
        loggedOut: sub.loggedOut === true,
        managedByAdmin: sub.managedByAdmin === true,
    };
}
export async function fetchAllBilling(accountNames) {
    const cache = loadCache();
    const results = [];
    for (const name of accountNames) {
        process.stdout.write(`  Billing ${name}...`);
        const billing = await fetchBillingForAccount(name, cache[name]);
        if (!billing.fromCache)
            recordBilling(cache, name, { renewalAt: billing.billingDate, autoRenew: billing.autoRenew, managedByAdmin: billing.managedByAdmin, paid: billing.paid });
        console.log(billing.fromCache ? " cached" : " done");
        results.push({ name, ...billing });
    }
    saveCache(cache);
    return results;
}
