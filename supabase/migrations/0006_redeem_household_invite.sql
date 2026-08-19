-- Redeem a household invite code.
--
-- NOTE: This function already exists in the Supabase project (created by hand in the
-- dashboard, labeled "Redeem Household Invite") but was never captured as a migration.
-- This file records the deployed definition verbatim so the schema stops drifting.
-- Do NOT "improve" it here without also updating the dashboard — the running app
-- depends on the deployed behavior.
--
-- Contract (confirmed 2026-08-19):
--   * Single-use. SELECT ... FOR UPDATE locks the invite row, so a concurrent
--     redeemer of the same code blocks until the first commits, then re-reads the
--     row with used_at set and fails the "already used" check. Race-safe.
--   * Non-destructive join. The redeemer is added to the invite's household via
--     ON CONFLICT DO NOTHING and is NOT removed from their auto-created personal
--     household. The joined household becomes primary on the client because
--     refresh() orders memberships by joined_at DESC.
--   * The invite's role is trusted as-is; only owners can create invites (RLS
--     household_invites_owner_write), so it was set by an authorized user.
--
-- SECURITY DEFINER is required: the client cannot read/update household_invites for
-- a household it isn't yet a member of, nor validate-and-claim atomically under RLS.
-- The client (HouseholdService.redeemInvite) trims and uppercases the code before
-- calling, which is why no normalization is done here.

CREATE OR REPLACE FUNCTION public.redeem_household_invite(invite_code text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    inv household_invites%ROWTYPE;
BEGIN
    SELECT * INTO inv FROM household_invites WHERE code = invite_code FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid invite code' USING ERRCODE = 'P0001';
    END IF;
    IF inv.used_at IS NOT NULL THEN
        RAISE EXCEPTION 'Invite already used' USING ERRCODE = 'P0001';
    END IF;
    IF inv.expires_at < now() THEN
        RAISE EXCEPTION 'Invite expired' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO household_members (household_id, user_id, role)
    VALUES (inv.household_id, auth.uid(), inv.role)
    ON CONFLICT (household_id, user_id) DO NOTHING;

    UPDATE household_invites
    SET used_at = now(), used_by = auth.uid()
    WHERE code = invite_code;

    RETURN inv.household_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.redeem_household_invite(text) TO authenticated;
