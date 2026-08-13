# Plaid Edge Function

Deno/Supabase port of `backend/server.js`. Same routes, same request/response
shapes — it's a drop-in replacement for the old Node/Render proxy.

## Deploy

```bash
# 1. Install the CLI (once)
brew install supabase/tap/supabase

# 2. Auth + link to the project
supabase login
supabase link --project-ref eebpmgilbguussctttgl

# 3. Set secrets. Copy PLAID_CLIENT_ID / PLAID_SECRET from backend/.env
#    (do NOT commit them). Start on sandbox to mirror current testing.
supabase secrets set \
  PLAID_CLIENT_ID=<from backend/.env> \
  PLAID_SECRET=<from backend/.env> \
  PLAID_ENV=sandbox \
  PLAID_PRODUCTS=transactions,investments,liabilities \
  PLAID_COUNTRY_CODES=US \
  PLAID_LANGUAGE=en \
  PLAID_REDIRECT_URI=https://summit.local/plaid-redirect \
  HOSTED_LINK_COMPLETION_URI=summit://plaid-complete

# 4. Deploy (verify_jwt=false comes from ../../config.toml)
supabase functions deploy plaid
```

## Verify

```bash
curl https://eebpmgilbguussctttgl.supabase.co/functions/v1/plaid/api/health
# -> {"ok":true,"env":"sandbox"}
```

## Point the app at it

Set the backend base URL (Info.plist `SummitPlaidBackendURL`, or the
`PLAID_BACKEND_URL` scheme env var) to:

```
https://eebpmgilbguussctttgl.supabase.co/functions/v1/plaid
```

The app appends `/api/...` to this, so the function receives
`/functions/v1/plaid/api/...` and strips the prefix when routing.

## Follow-ups (not done in this port)

- **Auth:** currently `verify_jwt = false` for parity with the old backend
  (auth is per-item via the `X-Plaid-Access-Token` header only). Gate behind the
  logged-in user's Supabase JWT and consider moving access-token storage
  server-side (Postgres + RLS) instead of device Keychain.
- **Long syncs:** `/api/transactions/sync` and `/api/investments/transactions`
  fully paginate within a single request. Fine for sandbox; watch Edge Function
  wall-clock/memory limits against very large real histories.
- **Production:** flip `PLAID_ENV=production`, real creds, and a real registered
  `PLAID_REDIRECT_URI` (the `summit.local` placeholder only works in sandbox).
