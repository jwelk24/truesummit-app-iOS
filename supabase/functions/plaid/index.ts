// Supabase Edge Function port of backend/server.js — the Plaid proxy that
// holds the client_secret and passes through Plaid calls. The app only ever
// holds per-item access tokens (in Keychain) and short-lived link tokens.
//
// Routes (suffix after the function name):
//   GET  /api/health
//   POST /api/link/token/create
//   POST /api/link/token/get
//   POST /api/item/public_token/exchange
//   GET  /api/accounts
//   POST /api/transactions/sync
//   GET  /api/investments/holdings
//   POST /api/investments/transactions
//   GET  /api/liabilities
//   POST /api/sandbox/fire-webhook
//
// Secrets (set via `supabase secrets set`): PLAID_CLIENT_ID, PLAID_SECRET,
// PLAID_ENV, PLAID_PRODUCTS, PLAID_COUNTRY_CODES, PLAID_LANGUAGE,
// PLAID_REDIRECT_URI, HOSTED_LINK_COMPLETION_URI, PLAID_ANDROID_PACKAGE_NAME.
import {
    Configuration,
    PlaidApi,
    PlaidEnvironments,
    Products,
    CountryCode,
    LinkTokenCreateRequest,
} from "npm:plaid@28";

const PLAID_CLIENT_ID = Deno.env.get("PLAID_CLIENT_ID");
const PLAID_SECRET = Deno.env.get("PLAID_SECRET");
const PLAID_ENV = Deno.env.get("PLAID_ENV") ?? "sandbox";
// Required products. Anything listed here gates account selection in Link: with
// investments required, Link rejects a checking account for "not being an
// investment account". Keep this to what the app cannot work without.
const PLAID_PRODUCTS = Deno.env.get("PLAID_PRODUCTS") ?? "transactions";
// Fetched when the institution and the chosen accounts support them, and
// silently skipped otherwise — so holdings and liabilities still populate for
// brokerage and card accounts without blocking a plain checking link.
const PLAID_OPTIONAL_PRODUCTS =
    Deno.env.get("PLAID_OPTIONAL_PRODUCTS") ?? "investments,liabilities";
const PLAID_COUNTRY_CODES = Deno.env.get("PLAID_COUNTRY_CODES") ?? "US";
const PLAID_LANGUAGE = Deno.env.get("PLAID_LANGUAGE") ?? "en";
const PLAID_REDIRECT_URI = Deno.env.get("PLAID_REDIRECT_URI");
const HOSTED_LINK_COMPLETION_URI =
    Deno.env.get("HOSTED_LINK_COMPLETION_URI") ?? "summit://plaid-complete";
// Android's native Link SDK returns from OAuth via the app's package name.
// Kept server-side (not read from the request body) on purpose: a client-
// supplied package name would let anyone mint a link token pointing at their
// own app.
const PLAID_ANDROID_PACKAGE_NAME = Deno.env.get("PLAID_ANDROID_PACKAGE_NAME");

if (!PLAID_CLIENT_ID || !PLAID_SECRET) {
    console.error("Missing PLAID_CLIENT_ID or PLAID_SECRET secrets.");
}

const plaid = new PlaidApi(
    new Configuration({
        basePath: PlaidEnvironments[PLAID_ENV],
        baseOptions: {
            headers: {
                "PLAID-CLIENT-ID": PLAID_CLIENT_ID,
                "PLAID-SECRET": PLAID_SECRET,
            },
        },
    }),
);

// String-keyed views of the enums so the lookups below index by string
// without a noImplicitAny error under `deno check`. Runtime behaviour is
// unchanged — the enum values already equal the Plaid product/country strings.
const productsByKey = Products as unknown as Record<string, Products>;
const countryCodesByKey = CountryCode as unknown as Record<string, CountryCode>;
const products = PLAID_PRODUCTS.split(",").map((s) => s.trim()).filter(Boolean)
    .map((p) => productsByKey[Object.keys(Products).find((k) => productsByKey[k] === p) ?? p] ?? (p as Products));
const optionalProducts = PLAID_OPTIONAL_PRODUCTS.split(",").map((s) => s.trim()).filter(Boolean)
    .map((p) => productsByKey[Object.keys(Products).find((k) => productsByKey[k] === p) ?? p] ?? (p as Products));
const countryCodes = PLAID_COUNTRY_CODES.split(",").map((s) => s.trim()).filter(Boolean)
    .map((c) => countryCodesByKey[Object.keys(CountryCode).find((k) => countryCodesByKey[k] === c) ?? c] ?? (c as CountryCode));

const CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-plaid-access-token",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...CORS, "Content-Type": "application/json" },
    });
}

function sendPlaidError(e: any): Response {
    const data = e?.response?.data;
    const status = e?.response?.status ?? 500;
    if (data) {
        console.error("Plaid error:", data);
        return json({ error: data }, status);
    }
    console.error(e);
    return json({ error: { message: e?.message ?? "unknown error" } }, 500);
}

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

    const url = new URL(req.url);
    // Strip the Supabase function prefix (/functions/v1/plaid or /plaid) so we
    // route on the app's original path, e.g. /api/link/token/create.
    const path = url.pathname.replace(/^\/(functions\/v1\/)?plaid/, "") || "/";
    const accessToken = req.headers.get("x-plaid-access-token") ?? undefined;
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};

    try {
        if (req.method === "GET" && path === "/api/health") {
            return json({ ok: true, env: PLAID_ENV });
        }

        if (req.method === "POST" && path === "/api/link/token/create") {
            // Accept either spelling: iOS sends clientUserId, Android currently
            // sends user_id. Before this, a non-clientUserId body was discarded
            // and every such user was created as the same Plaid user. The
            // fallback keeps older clients working so this deploys ahead of any
            // app release.
            const clientUserId = body?.clientUserId ?? body?.user_id ?? "summit-local-user";

            // The apps drive different Plaid flows, and the parameters are
            // mutually exclusive:
            //   iOS     — Hosted Link in a web view: redirect_uri plus
            //             hosted_link.completion_redirect_uri.
            //   Android — the native Link SDK, whose OAuth handoff returns via
            //             the package name. Plaid rejects redirect_uri sent
            //             alongside android_package_name.
            // Platform is absent on older clients, which keeps the previous iOS
            // behaviour, so this deploys safely ahead of any app release.
            const isAndroid = String(body?.platform ?? "").toLowerCase() === "android";
            if (isAndroid && !PLAID_ANDROID_PACKAGE_NAME) {
                return json({ error: "PLAID_ANDROID_PACKAGE_NAME secret is not set." }, 500);
            }

            // Typed (not Record<string, unknown>) so TypeScript still validates
            // field names against Plaid's request shape after the dynamic
            // branching below — a typo like `andriod_package_name` fails to
            // compile rather than at runtime against production Plaid.
            const linkRequest: LinkTokenCreateRequest = {
                user: { client_user_id: clientUserId },
                client_name: "TrueSummit",
                products,
                country_codes: countryCodes,
                language: PLAID_LANGUAGE,
            };
            if (optionalProducts.length) linkRequest.optional_products = optionalProducts;

            if (isAndroid) {
                linkRequest.android_package_name = PLAID_ANDROID_PACKAGE_NAME;
            } else {
                linkRequest.redirect_uri = PLAID_REDIRECT_URI;
                linkRequest.hosted_link = {
                    completion_redirect_uri: HOSTED_LINK_COMPLETION_URI,
                    is_mobile_app: true,
                };
            }

            const response = await plaid.linkTokenCreate(linkRequest);
            return json({
                linkToken: response.data.link_token,
                // Absent on Android: that flow creates no hosted link.
                hostedLinkUrl: response.data.hosted_link_url ?? null,
                expiration: response.data.expiration,
                completionRedirectUri: isAndroid ? null : HOSTED_LINK_COMPLETION_URI,
            });
        }

        if (req.method === "POST" && path === "/api/link/token/get") {
            const { linkToken } = body ?? {};
            if (!linkToken) return json({ error: "linkToken required" }, 400);
            let publicToken = null;
            let finishedAt = null;
            for (let attempt = 0; attempt < 5; attempt++) {
                const response = await plaid.linkTokenGet({ link_token: linkToken });
                const session = response.data.link_sessions?.[0];
                finishedAt = session?.finished_at ?? null;
                publicToken = session?.results?.item_add_results?.[0]?.public_token ??
                    session?.on_success?.public_token ?? null;
                if (publicToken || finishedAt) break;
                await new Promise((r) => setTimeout(r, 1000));
            }
            return json({ publicToken, finishedAt });
        }

        if (req.method === "POST" && path === "/api/item/public_token/exchange") {
            const { publicToken } = body ?? {};
            if (!publicToken) return json({ error: "publicToken required" }, 400);
            const response = await plaid.itemPublicTokenExchange({ public_token: publicToken });
            return json({ accessToken: response.data.access_token, itemId: response.data.item_id });
        }

        if (req.method === "GET" && path === "/api/accounts") {
            if (!accessToken) return json({ error: "X-Plaid-Access-Token header required" }, 401);
            const response = await plaid.accountsGet({ access_token: accessToken });
            return json({ item: response.data.item, accounts: response.data.accounts });
        }

        if (req.method === "POST" && path === "/api/transactions/sync") {
            if (!accessToken) return json({ error: "X-Plaid-Access-Token header required" }, 401);
            let cursor = body?.cursor || undefined;
            const added = [], modified = [], removed = [];
            let hasMore = true;
            while (hasMore) {
                const response = await plaid.transactionsSync({ access_token: accessToken, cursor, count: 500 });
                added.push(...response.data.added);
                modified.push(...response.data.modified);
                removed.push(...response.data.removed);
                hasMore = response.data.has_more;
                cursor = response.data.next_cursor;
            }
            return json({ added, modified, removed, nextCursor: cursor });
        }

        if (req.method === "GET" && path === "/api/investments/holdings") {
            if (!accessToken) return json({ error: "X-Plaid-Access-Token header required" }, 401);
            const response = await plaid.investmentsHoldingsGet({ access_token: accessToken });
            return json({
                accounts: response.data.accounts,
                holdings: response.data.holdings,
                securities: response.data.securities,
            });
        }

        if (req.method === "POST" && path === "/api/investments/transactions") {
            if (!accessToken) return json({ error: "X-Plaid-Access-Token header required" }, 401);
            const today = new Date();
            const twoYearsAgo = new Date(today.getFullYear() - 2, today.getMonth(), today.getDate());
            const startDate = body?.startDate || twoYearsAgo.toISOString().slice(0, 10);
            const endDate = body?.endDate || today.toISOString().slice(0, 10);
            const investmentTransactions = [];
            const securitiesById = new Map();
            let offset = 0;
            const count = 500;
            let total = Infinity;
            while (offset < total) {
                const response = await plaid.investmentsTransactionsGet({
                    access_token: accessToken,
                    start_date: startDate,
                    end_date: endDate,
                    options: { count, offset },
                });
                investmentTransactions.push(...response.data.investment_transactions);
                for (const security of response.data.securities) securitiesById.set(security.security_id, security);
                total = response.data.total_investment_transactions;
                offset += response.data.investment_transactions.length;
                if (response.data.investment_transactions.length === 0) break;
            }
            return json({
                investmentTransactions,
                securities: Array.from(securitiesById.values()),
                startDate,
                endDate,
            });
        }

        if (req.method === "GET" && path === "/api/liabilities") {
            if (!accessToken) return json({ error: "X-Plaid-Access-Token header required" }, 401);
            const response = await plaid.liabilitiesGet({ access_token: accessToken });
            return json({ accounts: response.data.accounts, liabilities: response.data.liabilities });
        }

        if (req.method === "POST" && path === "/api/sandbox/fire-webhook") {
            if (!accessToken) return json({ error: "X-Plaid-Access-Token header required" }, 401);
            const webhookCode = body?.webhookCode ?? "SYNC_UPDATES_AVAILABLE";
            const response = await plaid.sandboxItemFireWebhook({
                access_token: accessToken,
                webhook_code: webhookCode,
            });
            return json(response.data);
        }

        return json({ error: `Not found: ${req.method} ${path}` }, 404);
    } catch (e) {
        return sendPlaidError(e);
    }
});
