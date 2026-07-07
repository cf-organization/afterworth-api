-- public.get_estate_net_worth(p_estate_id uuid) -> ONE row: the estate net-worth aggregate, redacted.
--
-- Slice B — the total_asset_value disclosure surface. A DEDICATED aggregate (Option B), decoupled from
-- list_estate_assets: that RPC is UNCHANGED (its curl-proven redaction engine + account_balances ROW
-- gate are untouched — zero regression risk). A beneficiary with ONLY total_asset_value gets a headline
-- net-worth bracket here and STILL zero rows from list_estate_assets (least-disclosure — no structure).
--
-- SECURITY DEFINER so it can read normalized_assets (owner-only at the RLS layer). is_estate_owner is
-- the FIRST branch (owner -> inherent exact total); non-owners are GRANT-BASED (the total_asset_value
-- grant), never membership-gated — same discipline as list_estate_assets / can_access_document.
--
-- Redaction: total_asset_value is a $ category, so asset_category_grantable caps a beneficiary at
-- summary/range (NEVER exact) and allows a professional full_detail. Bracketing reuses the existing
-- asset_bracket_low/high knob. Read-time ceiling re-check clamps an over-ceiling grant to hidden
-- (authoritative even if a grant predates a ceiling tightening) — the B2a read-clamp discipline.
--
-- ★ THE EXCLUSION (the subtraction-attack prevention, isolated in this one small function):
--   if the caller holds an active, immediately-released account_balances grant, then list_estate_assets
--   is showing the granular per-group value breakdown, which takes PRECEDENCE — so the grand total is
--   SUPPRESSED here. Across the two surfaces a caller can read, the leaky pair (bracketed subtotals +
--   bracketed grand total) can NEVER co-appear, so the subtraction attack (back out a group from
--   total - Σ others) is impossible BY CONSTRUCTION at read time. The EXISTS predicate mirrors
--   list_estate_assets' v_bal resolution EXACTLY (category='account_balances', status='active',
--   release_condition='immediately'), so suppression fires precisely when the breakdown is disclosed.
--   The owner is returned above (exempt — inspecting their own data, not subject to inference limits).
--
-- Currency: V1 assumes a single estate currency; sums balance_cents and reports one currency
-- (coalesce -> 'USD'). Mixed-currency estates are a documented follow-up (per-currency or converted).
--
-- Return: ALWAYS exactly one row.
--   resolved_tier: 'full_detail'|'limited_detail' -> total_cents is the exact total (owner/professional)
--                  'category_summary'|'range_only' -> range_low/high_cents is the bracketed total
--                  'hidden' -> nothing disclosed (no/over-ceiling grant, OR suppressed_by_breakdown=true)
--   suppressed_by_breakdown: true only when a total grant EXISTS but is suppressed by account_balances
--                            precedence (lets the client distinguish "suppressed" from "not granted").
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

create or replace function public.get_estate_net_worth(p_estate_id uuid)
 returns table (
   total_cents bigint,
   range_low_cents bigint,
   range_high_cents bigint,
   resolved_tier text,
   currency text,
   suppressed_by_breakdown boolean
 )
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_sum bigint;
  v_cur text;
  v_tot text;        -- total_asset_value tier
  v_tot_role text;   -- grantee_role from the total grant (for the ceiling re-check)
begin
  if v_uid is null then return; end if;

  -- The exact estate total (SECURITY DEFINER reads owner-only normalized_assets). Empty estate -> 0.
  select coalesce(sum(a.balance_cents), 0)::bigint, coalesce(max(a.currency), 'USD')
    into v_sum, v_cur
  from public.normalized_assets a
  where a.estate_id = p_estate_id;

  -- OWNER FIRST: inherent exact total, never suppressed.
  if public.is_estate_owner(p_estate_id) then
    -- aal2 GATE (option b): the owner sees the EXACT total -> require MFA, UNCONDITIONALLY.
    perform public.require_aal2();
    return query select v_sum, null::bigint, null::bigint, 'full_detail'::text, v_cur, false;
    return;
  end if;

  -- NON-OWNER: grant-based. Resolve the total_asset_value grant (tier + role).
  select g.visibility_tier, g.grantee_role into v_tot, v_tot_role
  from public.access_grants g
  where g.estate_id = p_estate_id
    and g.grantee_user_id = v_uid
    and g.category = 'total_asset_value'
    and g.status = 'active'
    and g.release_condition = 'immediately'   -- signal-based conditions stay dormant-deny (A.4)
  limit 1;

  -- No total_asset_value grant -> nothing disclosed.
  if v_tot is null then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, v_cur, false;
    return;
  end if;

  -- Read-time ceiling re-check (authoritative). asset_category_grantable already caps total_asset_value
  -- like account_balances (beneficiary summary/range; professional full_detail). Over-ceiling -> hidden.
  if not public.asset_category_grantable(v_tot_role, 'total_asset_value', v_tot) then
    v_tot := 'hidden';
  end if;
  if v_tot = 'hidden' then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, v_cur, false;
    return;
  end if;

  -- ★ THE EXCLUSION — account_balances breakdown PRECEDENCE. If the caller has an active,
  --   immediately-released account_balances grant, list_estate_assets is disclosing the per-group
  --   breakdown; suppress the grand total here so the leaky pair never co-appears across surfaces.
  if exists (
    select 1 from public.access_grants g
    where g.estate_id = p_estate_id
      and g.grantee_user_id = v_uid
      and g.category = 'account_balances'
      and g.status = 'active'
      and g.release_condition = 'immediately'
  ) then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, v_cur, true;  -- suppressed
    return;
  end if;

  -- Emit the total per its tier. Beneficiary (range_only/category_summary) -> BRACKETED (never exact);
  -- professional (limited_detail/full_detail) -> exact, authorized by the ceiling.
  -- aal2 GATE (option b) — TIER-AWARE: the EXACT total emits ONLY in this branch (professional
  -- full/limited), so the gate goes HERE, not before. The bracketed else-branch stays aal1.
  if v_tot in ('limited_detail', 'full_detail') then
    perform public.require_aal2();
    return query select v_sum, null::bigint, null::bigint, v_tot, v_cur, false;
  else
    return query select null::bigint,
                        public.asset_bracket_low(v_sum),
                        public.asset_bracket_high(v_sum),
                        v_tot, v_cur, false;
  end if;
end;
$function$;
