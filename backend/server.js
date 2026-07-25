import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { Configuration, PlaidApi, PlaidEnvironments, Products, CountryCode } from 'plaid';

const {
    PLAID_CLIENT_ID,
    PLAID_SECRET,
    PLAID_ENV = 'sandbox',
    PLAID_PRODUCTS = 'transactions',
    PLAID_COUNTRY_CODES = 'US',
    PLAID_LANGUAGE = 'en',
    PLAID_REDIRECT_URI,
    PORT = 8080,
} = process.env;

if (!PLAID_CLIENT_ID || !PLAID_SECRET) {
    console.error('Missing PLAID_CLIENT_ID or PLAID_SECRET. Copy .env.example to .env and fill them in.');
    process.exit(1);
}

const plaid = new PlaidApi(new Configuration({
    basePath: PlaidEnvironments[PLAID_ENV],
    baseOptions: {
        headers: {
            'PLAID-CLIENT-ID': PLAID_CLIENT_ID,
            'PLAID-SECRET': PLAID_SECRET,
        },
    },
}));

const products = PLAID_PRODUCTS.split(',').map(s => s.trim()).filter(Boolean).map(p => Products[
    Object.keys(Products).find(k => Products[k] === p) ?? p
] ?? p);

const countryCodes = PLAID_COUNTRY_CODES.split(',').map(s => s.trim()).filter(Boolean).map(c => CountryCode[
    Object.keys(CountryCode).find(k => CountryCode[k] === c) ?? c
] ?? c);

const app = express();
app.use(cors());
app.use(express.json());

app.get('/api/health', (_req, res) => {
    res.json({ ok: true, env: PLAID_ENV });
});

// 1. Create a Hosted Link token. App opens the returned hosted_link_url in a
// WKWebView and watches for redirect to PLAID_REDIRECT_URI?public_token=...
app.post('/api/link/token/create', async (req, res) => {
    try {
        const clientUserId = req.body?.clientUserId ?? 'summit-local-user';
        const response = await plaid.linkTokenCreate({
            user: { client_user_id: clientUserId },
            client_name: 'TrueSummit',
            products,
            country_codes: countryCodes,
            language: PLAID_LANGUAGE,
            redirect_uri: PLAID_REDIRECT_URI,
            hosted_link: {},
        });
        res.json({
            linkToken: response.data.link_token,
            hostedLinkUrl: response.data.hosted_link_url,
            expiration: response.data.expiration,
            redirectUri: PLAID_REDIRECT_URI,
        });
    } catch (e) {
        sendPlaidError(res, e);
    }
});

// 2. Exchange the public_token (returned by Hosted Link redirect) for an
// access_token. The app stores access_token in Keychain.
app.post('/api/item/public_token/exchange', async (req, res) => {
    try {
        const { publicToken } = req.body ?? {};
        if (!publicToken) return res.status(400).json({ error: 'publicToken required' });
        const response = await plaid.itemPublicTokenExchange({ public_token: publicToken });
        res.json({
            accessToken: response.data.access_token,
            itemId: response.data.item_id,
        });
    } catch (e) {
        sendPlaidError(res, e);
    }
});

// 3. List accounts for an item. Access token comes from the X-Plaid-Access-Token header.
app.get('/api/accounts', async (req, res) => {
    try {
        const accessToken = req.get('x-plaid-access-token');
        if (!accessToken) return res.status(401).json({ error: 'X-Plaid-Access-Token header required' });
        const response = await plaid.accountsGet({ access_token: accessToken });
        res.json({
            item: response.data.item,
            accounts: response.data.accounts,
        });
    } catch (e) {
        sendPlaidError(res, e);
    }
});

// 4. Sync transactions. Client passes its last cursor (or omits it on first
// sync) and gets back added / modified / removed plus the new cursor to store.
app.post('/api/transactions/sync', async (req, res) => {
    try {
        const accessToken = req.get('x-plaid-access-token');
        if (!accessToken) return res.status(401).json({ error: 'X-Plaid-Access-Token header required' });

        let cursor = req.body?.cursor || undefined;
        const added = [];
        const modified = [];
        const removed = [];
        let hasMore = true;

        while (hasMore) {
            const response = await plaid.transactionsSync({
                access_token: accessToken,
                cursor,
                count: 500,
            });
            added.push(...response.data.added);
            modified.push(...response.data.modified);
            removed.push(...response.data.removed);
            hasMore = response.data.has_more;
            cursor = response.data.next_cursor;
        }

        res.json({ added, modified, removed, nextCursor: cursor });
    } catch (e) {
        sendPlaidError(res, e);
    }
});

// 5. Pull holdings (positions) for any investment / retirement accounts on
// this item. Returns Plaid's `holdings` and `securities` arrays.
app.get('/api/investments/holdings', async (req, res) => {
    try {
        const accessToken = req.get('x-plaid-access-token');
        if (!accessToken) return res.status(401).json({ error: 'X-Plaid-Access-Token header required' });
        const response = await plaid.investmentsHoldingsGet({ access_token: accessToken });
        res.json({
            accounts: response.data.accounts,
            holdings: response.data.holdings,
            securities: response.data.securities,
        });
    } catch (e) {
        sendPlaidError(res, e);
    }
});

// 6. Pull investment transactions (buys, sells, dividends, fees, etc.) over a
// rolling window. Client passes `startDate` (defaults to 2 years ago) and
// `endDate` (defaults to today).
app.post('/api/investments/transactions', async (req, res) => {
    try {
        const accessToken = req.get('x-plaid-access-token');
        if (!accessToken) return res.status(401).json({ error: 'X-Plaid-Access-Token header required' });
        const today = new Date();
        const twoYearsAgo = new Date(today.getFullYear() - 2, today.getMonth(), today.getDate());
        const startDate = req.body?.startDate || twoYearsAgo.toISOString().slice(0, 10);
        const endDate = req.body?.endDate || today.toISOString().slice(0, 10);

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
            for (const security of response.data.securities) {
                securitiesById.set(security.security_id, security);
            }
            total = response.data.total_investment_transactions;
            offset += response.data.investment_transactions.length;
            if (response.data.investment_transactions.length === 0) break;
        }

        res.json({
            investmentTransactions,
            securities: Array.from(securitiesById.values()),
            startDate,
            endDate,
        });
    } catch (e) {
        sendPlaidError(res, e);
    }
});

// 7. Pull liabilities (credit cards, student loans, mortgages) for this item.
app.get('/api/liabilities', async (req, res) => {
    try {
        const accessToken = req.get('x-plaid-access-token');
        if (!accessToken) return res.status(401).json({ error: 'X-Plaid-Access-Token header required' });
        const response = await plaid.liabilitiesGet({ access_token: accessToken });
        res.json({
            accounts: response.data.accounts,
            liabilities: response.data.liabilities,
        });
    } catch (e) {
        sendPlaidError(res, e);
    }
});

// Sandbox-only convenience: fire a webhook to advance the sandbox item so
// transactions show up sooner. Useful while iterating in the simulator.
app.post('/api/sandbox/fire-webhook', async (req, res) => {
    try {
        const accessToken = req.get('x-plaid-access-token');
        if (!accessToken) return res.status(401).json({ error: 'X-Plaid-Access-Token header required' });
        const webhookCode = req.body?.webhookCode ?? 'SYNC_UPDATES_AVAILABLE';
        const response = await plaid.sandboxItemFireWebhook({
            access_token: accessToken,
            webhook_code: webhookCode,
        });
        res.json(response.data);
    } catch (e) {
        sendPlaidError(res, e);
    }
});

function sendPlaidError(res, e) {
    const data = e?.response?.data;
    const status = e?.response?.status ?? 500;
    if (data) {
        console.error('Plaid error:', data);
        res.status(status).json({ error: data });
    } else {
        console.error(e);
        res.status(500).json({ error: { message: e?.message ?? 'unknown error' } });
    }
}

app.listen(PORT, () => {
    console.log(`Summit backend listening on http://localhost:${PORT} (Plaid ${PLAID_ENV})`);
});
