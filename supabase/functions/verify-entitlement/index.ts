// Verifies a StoreKit 2 signed transaction with Apple and stamps the caller's
// household(s) with their subscription tier, so guests can ride the owner's
// plan ("owner pays for the family").
//
// Flow:
//   1. Authenticate the caller via their Supabase JWT (verify_jwt = true).
//   2. Cryptographically verify the signed transaction (JWS) against Apple's
//      root CAs using @apple/app-store-server-library. This proves Apple issued
//      it — a hand-crafted or replayed body fails signature/chain validation.
//   3. Bind it to the caller: the transaction's appAccountToken must equal the
//      caller's user id (the app sets this at purchase time). This stops someone
//      from submitting a stranger's valid receipt to mark their own household
//      Premium.
//   4. Write plan_tier / plan_valid_until (Apple's real expiration + grace) onto
//      every household the caller owns. An empty/expired/revoked transaction
//      clears coverage instead.
//
// The write uses the service-role client, which is the ONLY thing allowed to
// touch those columns (see migration 0007) — clients cannot self-declare a tier.
//
// Secrets (supabase secrets set): APPLE_BUNDLE_ID, APPLE_ENVIRONMENT
// ("Production" | "Sandbox"), APPLE_APP_APPLE_ID (numeric App Store id;
// required by the verifier in Production). SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are injected by the platform.
import { createClient } from "npm:@supabase/supabase-js@2";
import {
    SignedDataVerifier,
    Environment,
} from "npm:@apple/app-store-server-library@1";

const APPLE_BUNDLE_ID = Deno.env.get("APPLE_BUNDLE_ID") ?? "com.welker.TrueSummit";
const APPLE_ENVIRONMENT = (Deno.env.get("APPLE_ENVIRONMENT") ?? "Sandbox") as
    | "Production"
    | "Sandbox";
const APPLE_APP_APPLE_ID = Deno.env.get("APPLE_APP_APPLE_ID");

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Coverage lingers this long past Apple's expiration so a guest doesn't lose
// access during the owner's normal auto-renew window (the owner's app republishes
// the new expiration next time it runs). A follow-up should replace this with
// App Store Server Notifications V2 driving expiration server-side directly.
const GRACE_MS = 3 * 24 * 60 * 60 * 1000;

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

// Apple's public root CAs, fetched once per cold start. Public certificates, so
// fetching them at runtime is safe and avoids bundling binary blobs.
let appleRootCAsPromise: Promise<Uint8Array[]> | null = null;
function loadAppleRootCAs(): Promise<Uint8Array[]> {
    if (!appleRootCAsPromise) {
        const urls = [
            "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer",
            "https://www.apple.com/certificateauthority/AppleRootCA-G2.cer",
        ];
        appleRootCAsPromise = Promise.all(
            urls.map(async (u) => new Uint8Array(await (await fetch(u)).arrayBuffer())),
        );
    }
    return appleRootCAsPromise;
}

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

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
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "Missing Authorization bearer token" }, 401);
    const { data: userData, error: userErr } = await admin.auth.getUser(token);
    if (userErr || !userData?.user) return json({ error: "Invalid session" }, 401);
    const userId = userData.user.id.toLowerCase();

    const { signedTransaction } = await req.json().catch(() => ({ signedTransaction: null }));

    // Empty payload = "I have no active subscription": clear my households' coverage.
    if (!signedTransaction || typeof signedTransaction !== "string") {
        await setCoverageForOwner(userId, null, null);
        return json({ tier: null, cleared: true });
    }

    try {
        // 2. Verify with Apple.
        const roots = await loadAppleRootCAs();
        const verifier = new SignedDataVerifier(
            roots,
            /* enableOnlineChecks */ false,
            APPLE_ENVIRONMENT === "Production" ? Environment.PRODUCTION : Environment.SANDBOX,
            APPLE_BUNDLE_ID,
            // Required by the verifier in Production; must be the numeric App Store id.
            APPLE_APP_APPLE_ID ? Number(APPLE_APP_APPLE_ID) : undefined,
        );
        const tx = await verifier.verifyAndDecodeTransaction(signedTransaction);

        // Defense in depth (the verifier already checks bundleId).
        if (tx.bundleId !== APPLE_BUNDLE_ID) {
            return json({ error: "bundleId mismatch" }, 403);
        }

        // 3. Bind the receipt to this user. The app sets appAccountToken = user id
        //    at purchase; a receipt without it (or with someone else's) is rejected.
        if (!tx.appAccountToken || tx.appAccountToken.toLowerCase() !== userId) {
            return json({ error: "Transaction is not bound to this account" }, 403);
        }

        const tier = TIER_BY_PRODUCT[tx.productId] ?? null;
        const now = Date.now();
        const expired = typeof tx.expiresDate === "number" && tx.expiresDate < now;
        const revoked = typeof tx.revocationDate === "number";

        if (!tier || expired || revoked) {
            await setCoverageForOwner(userId, null, null);
            return json({ tier: null });
        }

        // 4. Stamp Apple's real expiration (+grace) onto the caller's households.
        const validUntil = new Date((tx.expiresDate ?? now) + GRACE_MS).toISOString();
        await setCoverageForOwner(userId, tier, validUntil);
        return json({ tier, planValidUntil: validUntil });
    } catch (e) {
        console.error("verify-entitlement error:", e);
        return json({ error: (e as Error)?.message ?? "verification failed" }, 400);
    }
});
