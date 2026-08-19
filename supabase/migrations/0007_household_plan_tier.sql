-- Household-level subscription coverage ("owner pays for the family").
--
-- The owner's verified subscription tier is stamped onto their household row so
-- that guests (members who did not create the household) can ride it without
-- holding their own subscription. plan_valid_until is Apple's real expiration
-- date (written server-side), so coverage lapses on its own if the owner stops
-- paying and never has to be guessed at.
--
-- SECURITY: these two columns must NEVER be client-writable, or an owner could
-- self-declare Premium and unlock every guest for free. Only the
-- verify-entitlement Edge Function (service_role, which bypasses grants + RLS)
-- writes them, after cryptographically verifying the signed StoreKit
-- transaction with Apple. We therefore strip the broad table-level INSERT/UPDATE
-- grants from clients and hand back only the columns they legitimately set.

ALTER TABLE public.households
    ADD COLUMN plan_tier text,               -- 'pro' | 'premium' | NULL
    ADD COLUMN plan_valid_until timestamptz; -- Apple expiration (+grace), or NULL

-- Clients may rename their household but may not touch plan_tier/plan_valid_until.
REVOKE UPDATE ON public.households FROM authenticated;
GRANT  UPDATE (name) ON public.households TO authenticated;

-- Clients may create a household (name + owner only). handle_new_user runs as a
-- SECURITY DEFINER trigger and is unaffected by these client-facing grants.
REVOKE INSERT ON public.households FROM authenticated;
GRANT  INSERT (name, owner_user_id) ON public.households TO authenticated;
