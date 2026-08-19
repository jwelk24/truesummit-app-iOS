// Verifies a StoreKit subscription with Apple and stamps the caller's
// household(s) with their tier, so guests can ride the owner's plan ("owner
// pays for the family").
//
// Verification uses the **App Store Server API** rather than local JWS/x509
// verification, because Supabase's Deno edge runtime has an incomplete
// node:crypto X509Certificate (breaks @apple/app-store-server-library). Instead:
//   1. Authenticate the caller via their Supabase JWT (verify_jwt = true).
//   2. Decode the client's signed transaction *unverified* — only to read its
//      transactionId. This value is untrusted; it's just a lookup key.
//   3. Ask Apple's App Store Server API for the authoritative transaction, over
//      TLS, authenticated with an ES256 JWT signed by our App Store key (.p8).
//      Apple's TLS response is the source of truth — no local chain verification.
//   4. Bind it to the caller: the AUTHORITATIVE transaction's appAccountToken
//      (set by the app at purchase) must equal the caller's user id. A stranger's
//      transactionId resolves to a different appAccountToken and is rejected.
//   5. Write plan_tier / plan_valid_until (Apple's real expiration + grace) onto
//      every household the caller owns. Empty/expired/revoked clears coverage.
//
// Writes use the service-role client — the only thing allowed to touch those
// columns (migration 0007). Clients cannot self-declare a tier.
//
// Secrets (supabase secrets set):
//   APPLE_BUNDLE_ID       e.g. com.welker.TrueSummit
//   APPLE_ENVIRONMENT     "Production" | "Sandbox"
//   APPLE_KEY_ID          10-char key id from App Store Connect → Keys (In-App Purchase)
//   APPLE_ISSUER_ID       issuer UUID from that same Keys page
//   APPLE_PRIVATE_KEY_B64 base64 of the downloaded AuthKey_XXXX.p8 file
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected by the platform.
import { createClient } from "npm:@supabase/supabase-js@2";
import * as jose from "npm:jose@5";

const APPLE_BUNDLE_ID = Deno.env.get("APPLE_BUNDLE_ID") ?? "com.welker.TrueSummit";
const APPLE_ENVIRONMENT = (Deno.env.get("APPLE_ENVIRONMENT") ?? "Sandbox") as
    | "Production"
    | "Sandbox";
const APPLE_KEY_ID = Deno.env.get("APPLE_KEY_ID")!;
const APPLE_ISSUER_ID = Deno.env.get("APPLE_ISSUER_ID")!;
const APPLE_PRIVATE_KEY_B64 = Deno.env.get("APPLE_PRIVATE_KEY_B64")!;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Coverage lingers this long past Apple's expiration so a guest doesn't lose
// access during the owner's normal auto-renew window (the owner's app
// republishes the new expiration next time it runs). Follow-up: App Store Server
// Notifications V2 to drive expiration server-side directly.
const GRACE_MS = 3 * 24 * 60 * 60 * 1000;

const APPLE_HOSTS = {
    Production: "https://api.storekit.itunes.apple.com",
    Sandbox: "https://api.storekit-sandbox.itunes.apple.com",
};

// productId -> tier, mirroring StoreKitService.swift.
const TIER_BY_PRODUCT: Record<string, "pro" | "premium"> = {
    "com.welker.TrueSummit.pro.monthly": "pro",
    "com.welker.TrueSummit.pro.yearly": "pro",
    "com.welker.TrueSummit.premium.monthly": "premium",
    "com.welker.TrueSummit.premium.yearly": "premium",
};

const CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...CORS, "Content-Type": "application/json" },
    });
}

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Signs the short-lived ES256 JWT that authenticates us to the App Store Server
// API. Cached until shortly before expiry to avoid re-importing the key.
let cachedToken: { jwt: string; exp: number } | null = null;
async function appStoreToken(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (cachedToken && cachedToken.exp - 60 > now) return cachedToken.jwt;

    const pem = new TextDecoder().decode(
        Uint8Array.from(atob(APPLE_PRIVATE_KEY_B64.replace(/\s+/g, "")), (c) => c.charCodeAt(0)),
    );
    const key = await jose.importPKCS8(pem, "ES256");
    const exp = now + 15 * 60;
    const jwt = await new jose.SignJWT({ bid: APPLE_BUNDLE_ID })
        .setProtectedHeader({ alg: "ES256", kid: APPLE_KEY_ID, typ: "JWT" })
        .setIssuer(APPLE_ISSUER_ID)
        .setIssuedAt(now)
        .setExpirationTime(exp)
        .setAudience("appstoreconnect-v1")
        .sign(key);
    cachedToken = { jwt, exp };
    return jwt;
}

// Fetches the authoritative transaction from Apple. Tries the configured
// environment first, then the other one (a Production app can surface sandbox
// transactions during review/testing and vice versa).
async function fetchAppleTransaction(transactionId: string): Promise<Record<string, unknown>> {
    const token = await appStoreToken();
    const order: ("Production" | "Sandbox")[] = APPLE_ENVIRONMENT === "Production"
        ? ["Production", "Sandbox"]
        : ["Sandbox", "Production"];

    let lastStatus = 0;
    for (const env of order) {
        const res = await fetch(
            `${APPLE_HOSTS[env]}/inApps/v1/transactions/${transactionId}`,
            { headers: { Authorization: `Bearer ${token}` } },
        );
        if (res.status === 404) { lastStatus = 404; continue; }
        if (!res.ok) {
            // kid/iss are not secret (kid rides in the JWT header); logging them
            // lets us confirm the right key id + issuer are actually configured.
            throw new Error(
                `App Store Server API ${env} returned ${res.status} ` +
                `(kid=${APPLE_KEY_ID}, iss=${APPLE_ISSUER_ID}): ${await res.text()}`,
            );
        }
        const { signedTransactionInfo } = await res.json();
        // Signed by Apple and delivered over TLS from Apple, so decoding without
        // local signature verification is safe — TLS is the trust anchor.
        return jose.decodeJwt(signedTransactionInfo) as Record<string, unknown>;
    }
    throw new Error(`Transaction ${transactionId} not found (last status ${lastStatus}).`);
}

async function setCoverageForOwner(
    userId: string,
    planTier: string | null,
    planValidUntil: string | null,
): Promise<void> {
    const { error } = await admin
        .from("households")
        .update({ plan_tier: planTier, plan_valid_until: planValidUntil })
        .eq("owner_user_id", userId);
    if (error) throw error;
}

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
    if (req.method !== "POST") return json({ error: "POST only" }, 405);

    // 1. Authenticate the caller.
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "Missing Authorization bearer token" }, 401);
    const { data: userData, error: userErr } = await admin.auth.getUser(token);
    if (userErr || !userData?.user) return json({ error: "Invalid session" }, 401);
    const userId = userData.user.id.toLowerCase();

    const { signedTransaction } = await req.json().catch(() => ({ signedTransaction: null }));

    // Empty payload = "no active subscription": clear my households' coverage.
    if (!signedTransaction || typeof signedTransaction !== "string") {
        await setCoverageForOwner(userId, null, null);
        return json({ tier: null, cleared: true });
    }

    try {
        // 2. Untrusted decode — only to obtain the lookup key.
        const clientClaims = jose.decodeJwt(signedTransaction) as Record<string, unknown>;
        const transactionId = String(clientClaims.transactionId ?? clientClaims.originalTransactionId ?? "");
        if (!transactionId) return json({ error: "No transactionId in transaction" }, 400);

        // 3. Authoritative lookup from Apple.
        const tx = await fetchAppleTransaction(transactionId);

        // 4. Bind to caller + sanity-check bundle, using Apple's response only.
        if (tx.bundleId !== APPLE_BUNDLE_ID) {
            return json({ error: "bundleId mismatch" }, 403);
        }
        const appAccountToken = String(tx.appAccountToken ?? "").toLowerCase();
        if (!appAccountToken || appAccountToken !== userId) {
            return json({ error: "Transaction is not bound to this account" }, 403);
        }

        const tier = TIER_BY_PRODUCT[String(tx.productId)] ?? null;
        const now = Date.now();
        const expiresDate = typeof tx.expiresDate === "number" ? tx.expiresDate : undefined;
        const expired = expiresDate !== undefined && expiresDate < now;
        const revoked = typeof tx.revocationDate === "number";

        if (!tier || expired || revoked) {
            await setCoverageForOwner(userId, null, null);
            return json({ tier: null });
        }

        // 5. Stamp Apple's real expiration (+grace) onto the caller's households.
        const validUntil = new Date((expiresDate ?? now) + GRACE_MS).toISOString();
        await setCoverageForOwner(userId, tier, validUntil);
        return json({ tier, planValidUntil: validUntil });
    } catch (e) {
        console.error("verify-entitlement error:", e);
        return json({ error: (e as Error)?.message ?? "verification failed" }, 400);
    }
});
