-- 0010_20260705_financial_aal2 — the aal2 (MFA) gate on FINANCIAL data.
-- "MFA required for account access", scoped to financial tables/paths ONLY (no regression to
-- documents/grants/non-financial). Overrides 0007's SANDBOX NOTE deferral — the gate lands NOW on
-- sandbox (a gate that's off in the env you test is a gate you haven't proven; the fixture friction
-- IS the proof). Option (b): aal2 for EXACT-value disclosure; beneficiary brackets stay aal1.
--
-- THE CRITICAL SUBTLETY: the financial reads/writes go through SECURITY DEFINER RPCs that BYPASS
-- table RLS, so the REAL gate is INLINE IN THE RPCS (require_aal2), NOT in these policies. Apply
-- ALONGSIDE this migration (functions/ — re-apply on reset):
--   db/functions/require_aal2.sql               (NEW — the shared 42501 'mfa_required' helper)
--   db/functions/create_connection.sql          (UNCONDITIONAL aal2 after the owner-gate)
--   db/functions/get_connection_access_token.sql(UNCONDITIONAL aal2 after the owner-gate)
--   db/functions/list_estate_assets.sql         (TIER-AWARE: owner branch always; non-owner only
--                                                when v_bal resolves to limited_detail/full_detail)
--   db/functions/get_estate_net_worth.sql       (TIER-AWARE: owner + professional-exact branch;
--                                                the bracketed else-branch stays aal1)
--
-- The two policy flips BELOW are the REAL gate for the TWO direct-query paths that do NOT go through
-- a DEFINER RPC (+ defense-in-depth for any future direct query):
--   connections_select_owner    -> gates /api/connections list's direct SELECT on connections
--   normalized_assets_owner_all -> gates /api/connections refresh's direct INSERT on normalized_assets
-- connection_secrets keeps NO policy/grant (RPC-only, unreachable directly — no flip needed).
--
-- Fail-closed: coalesce(auth.jwt() ->> 'aal', 'aal1') so an absent claim -> 'aal1' -> denied.

begin;

-- connections: estate OWNER + aal2. (Mirrors 0007's connections_select_owner; adds the aal2 clause.)
drop policy if exists connections_select_owner on public.connections;
create policy connections_select_owner on public.connections
  for select using (
    public.is_estate_owner(estate_id)
    and coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
  );

-- normalized_assets: estate OWNER + aal2 on BOTH using (read/delete) and with check (insert). The
-- refresh path's DIRECT INSERT is a real RLS write -> an aal1 owner's refresh insert is now denied.
drop policy if exists normalized_assets_owner_all on public.normalized_assets;
create policy normalized_assets_owner_all on public.normalized_assets
  for all using (
    public.is_estate_owner(estate_id)
    and coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
  ) with check (
    public.is_estate_owner(estate_id)
    and coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
  );

-- DEFENSE-IN-DEPTH — RESTRICTIVE aal2 guard on both financial tables. Permissive policies OR-combine;
-- RESTRICTIVE policies AND-combine with EVERY present/future permissive policy. So even a later
-- permissive policy that forgets the aal2 clause CANNOT re-open an aal1 direct read/write. This closes
-- the one residual a VC-only audit can't rule out (a stray live-only permissive policy). DEFINER RPCs
-- bypass RLS entirely (permissive AND restrictive), so they are unaffected.
drop policy if exists connections_require_aal2 on public.connections;
create policy connections_require_aal2 on public.connections
  as restrictive for all
  using (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2')
  with check (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2');

drop policy if exists normalized_assets_require_aal2 on public.normalized_assets;
create policy normalized_assets_require_aal2 on public.normalized_assets
  as restrictive for all
  using (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2')
  with check (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2');

commit;
