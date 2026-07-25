# TrueSummit — App Store Privacy Details

This document is the source of truth for filling in **App Store Connect →
App Privacy**, plus reusable marketing copy. Keep it in sync with the code.

## Summary

- **On-device by default.** All AI (categorization, "Ask Your Money," the money
  coach, coach tips) runs on-device via Apple's Foundation Models. No transaction
  content is sent to a server for analysis, and nothing is used to train any model.
- **Cloud sync is for the user's own data**, to sync across their devices and
  share within a household — never sold, never used for advertising or tracking.
- **Local-only mode** (Privacy & Data) turns off all cloud sync so data stays
  only on the device.
- **One optional networked feature:** merchant logos (off by default), which
  sends merchant names to a logo provider only after explicit consent.
- **No tracking. No third-party analytics or advertising SDKs. No data sold.**

## App Privacy "nutrition label" answers

### Data used to track you
**None.** TrueSummit does not track users across apps/websites and has no
advertising or data-broker integrations.

### Data collected and linked to the user

Purpose for all items below: **App Functionality** (and cross-device sync). All
linked to the user's account; none used for tracking.

| Data type (Apple category) | What it is | Notes |
|---|---|---|
| Contact Info → **Email Address** | Account email (email / Sign in with Apple) | Auth only |
| Financial Info → **Other Financial Info** | Accounts, balances, transactions, budgets, goals | Synced to the user's account (Supabase) unless local-only |
| Identifiers → **User ID** | Account / household UUIDs | Sync + household sharing |

> If you add crash/diagnostics reporting later, disclose **Diagnostics → Crash
> Data** (App Functionality, not linked to identity if using Apple's default).

### Data collected but NOT linked / optional

| Data type | When | Disclosure |
|---|---|---|
| Financial Info → **Purchases** (merchant names) | Only if the user enables **Merchant Logos** | Sent to a third-party logo provider (unavatar.io) to fetch a logo. Off by default; explicit in-app consent required. Disclose as "Financial Info → shared with third parties for App Functionality." |

### Third parties that receive data

- **Supabase** (backend host) — stores the user's synced data. Processor, not a
  data broker.
- **Plaid** — used when a user links a bank; Plaid provides account/transaction
  data. Governed by Plaid's end-user privacy policy (link it in-app).
- **unavatar.io** — only when Merchant Logos is enabled; receives merchant names
  to return a logo image.

## What TrueSummit does NOT do
- No advertising SDKs, no ad identifiers (IDFA), no ad networks.
- No third-party analytics/telemetry.
- No selling or renting of user data.
- No use of financial data to train AI models (all AI is on-device).

## Marketing / positioning copy

**One-liner:** "The private budgeting app that tells you what you can spend
today — with AI that never leaves your iPhone."

**App Store description paragraph:**
> TrueSummit keeps your money private. Its insights, natural-language search, and
> money coach all run on-device with Apple Intelligence — your transactions are
> never sent to a server for analysis and are never used to train any model.
> Sync across your devices when you want it, switch to local-only when you don't,
> export or erase your data anytime. The one feature that ever uses the network —
> merchant logos — is off by default and asks first.

**Privacy nutrition-label headline (in-app "Privacy & Data" screen):**
> Private by design. On-device AI. Your data, your device.
