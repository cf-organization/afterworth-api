-- ★ 0066 (2026-11-19): BODY MIRRORED FROM db/migrations/0066_20261119_beneficiary_connector_disclosure.sql.
-- Non-owner rows exist only when something row-level is disclosed on THIS estate; per-account brackets
-- are no longer emitted to any non-owner (category brackets live in get_estate_discovery). The helpers
-- above (asset_grant_tier, asset_bracket_low/high) are unchanged. Header comments below predate 0066
-- where they describe range_only/category_summary rows — the body is the authority.
-- public.list_estate_assets(p_estate_id uuid) -> SETOF (redacted asset rows)
--
-- B2a — the SERVER-SIDE asset redaction (the security core). Owner -> full rows; non-owner ->
-- rows redacted to the caller's per-category grant tiers. SECURITY DEFINER so it reads
-- normalized_assets (which is OWNER-ONLY at the RLS layer — a beneficiary cannot SELECT it
-- directly, so the RAW balance is structurally unreachable outside this function). The RAW
-- balance_cents / holdings are NEVER returned for a non-owner below the disclosing tiers — they
-- are nulled/bucketed/summarized IN this function before any bytes leave the backend.
--
-- Tiers (per the account_balances grant, the primary value gate):
--   full_detail    -> exact balance + holdings (holdings also need linked_account_details=full_detail)
--   limited_detail -> exact balance, NO holdings
--   category_summary -> per-asset balance NULL; range_low/high_cents = BRACKETED group total
--                       (sum over asset_group, THEN bracketed — never an exact figure, so a
--                        single-asset group cannot leak its lone balance)
--   range_only     -> per-asset balance NULL; range_low/high_cents = per-asset coarse bracket
--   hidden         -> account row shows, NO value at all
--   (no grant)     -> the beneficiary sees NO asset rows (default-deny, safe)
-- INVARIANT: for a non-owner, NO returned field ever holds an exact value below limited_detail —
-- balance_cents is NULL, and the only value signal (range_low/high) is always a coarse bracket.
-- institution_names grant gates institution_name; linked_account_details gates masked_identifier +
-- holdings. Read-time ceiling re-check (asset_category_grantable) clamps an over-ceiling grant to
-- hidden (authoritative even if a grant predates a ceiling tightening).
--
-- Error model: unauthenticated / non-member -> empty set (never an error, never data).

-- --- helper: resolve a beneficiary's active tier for one asset category (SLICE 1: immediate only) ---
create or replace function public.asset_grant_tier(p_estate uuid, p_uid uuid, p_category text)
 returns text
 language sql
 stable
 security definer
 set search_path to 'public'
as $$
  select g.visibility_tier
  from public.access_grants g
  where g.estate_id = p_estate
    and g.grantee_user_id = p_uid
    and g.category = p_category
    and g.status = 'active'
    -- ★ PHASE 11-B — the canonical predicate. `legacy_immediate_only` is this surface's answer
    -- carried forward verbatim: the asset-value paths have never honoured an approval-conditioned
    -- grant, and 11-B centralizes the AUTHORITY without spending a product decision on the POLICY.
    -- 11-D wires the authoritative lifecycle through as an argument like every consumer — and under
    -- THIS policy it changes nothing: death-conditioned grants stay dormant on the asset surfaces
    -- even at death_verified (R12 keeps the policies distinct). Signal-based conditions and 'never'
    -- stay dormant-deny (A.4); an unknown condition or lifecycle refuses.
    and public.release_condition_satisfied(g.release_condition, g.approved_at, 'legacy_immediate_only',
                                           public.estate_lifecycle_state(p_estate))
  limit 1;
$$;

-- --- helper: coarse value brackets for range_only (THE POLICY KNOB — tune the brackets) ---
create or replace function public.asset_bracket_low(p bigint) returns bigint language sql immutable as $$
  select case
    when p < 1000000    then 0             when p < 5000000    then 1000000
    when p < 10000000   then 5000000       when p < 25000000   then 10000000
    when p < 50000000   then 25000000      when p < 100000000  then 50000000
    when p < 500000000  then 100000000     when p < 1000000000 then 500000000
    else 1000000000 end;
$$;
create or replace function public.asset_bracket_high(p bigint) returns bigint language sql immutable as $$
  select case
    when p < 1000000    then 1000000       when p < 5000000    then 5000000
    when p < 10000000   then 10000000      when p < 25000000   then 25000000
    when p < 50000000   then 50000000      when p < 100000000  then 100000000
    when p < 500000000  then 500000000     when p < 1000000000 then 1000000000
    else null end;   -- top bracket ($10M+): open-ended
$$;

-- --- the redaction RPC ---
create or replace function public.list_estate_assets(p_estate_id uuid)
 returns table (
   id uuid, estate_id uuid, connection_id uuid, institution_name text, provider_name text,
   asset_group text, asset_category text, asset_subtype text, source_type text,
   masked_identifier text, balance_cents bigint, currency text, holdings jsonb,
   refresh_timestamp timestamptz, last_sync_status text, confidence_level text,
   verification_status text, created_at timestamptz,
   resolved_tier text, range_low_cents bigint, range_high_cents bigint
 )
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid   uuid := auth.uid();
  v_bal   text;   -- account_balances, effective for THIS estate
  v_inst  text;   -- institution_names
  v_det   text;   -- linked_account_details
begin
  if v_uid is null then return; end if;

  -- OWNER: inherent full value, no redaction. aal2 UNCONDITIONALLY (exact figures + holdings).
  if public.is_estate_owner(p_estate_id) then
    perform public.require_aal2();
    return query
      select a.id, a.estate_id, a.connection_id, a.institution_name, a.provider_name,
             a.asset_group, a.asset_category, a.asset_subtype, a.source_type,
             a.masked_identifier, a.balance_cents, a.currency, a.holdings,
             a.refresh_timestamp, a.last_sync_status, a.confidence_level,
             a.verification_status, a.created_at,
             'full_detail'::text, null::bigint, null::bigint
      from public.normalized_assets a
      where a.estate_id = p_estate_id
      order by a.created_at desc;
    return;
  end if;

  -- NON-OWNER: grant-based, scoped to p_estate_id, never membership-derived, never cross-estate.
  v_bal  := public.connector_disclosure_tier(p_estate_id, v_uid, 'account_balances');
  v_inst := public.connector_disclosure_tier(p_estate_id, v_uid, 'institution_names');
  v_det  := public.connector_disclosure_tier(p_estate_id, v_uid, 'linked_account_details');

  -- ★ ROWS EXIST ONLY WHEN SOMETHING ROW-LEVEL IS DISCLOSED. A balances grant at a bracket tier
  --   discloses categories (elsewhere), not accounts; it does not produce rows here.
  if v_bal not in ('limited_detail', 'full_detail') and v_inst = 'hidden' and v_det = 'hidden' then
    return;
  end if;

  -- aal2 GATE — TIER-AWARE. Only an exact balances tier emits an exact figure, and only a professional
  -- can hold one (the ceiling). Descriptive rows stay aal1.
  if v_bal in ('limited_detail', 'full_detail') then
    perform public.require_aal2();
  end if;

  return query
    select
      a.id, a.estate_id, a.connection_id,
      case when v_inst = 'hidden' then 'Protected Institution' else a.institution_name end,
      a.provider_name, a.asset_group, a.asset_category, a.asset_subtype, a.source_type,
      case when v_det = 'hidden' then '••••' else a.masked_identifier end,
      -- Exact ONLY at an exact tier; otherwise NULL. Never a bracket per account.
      case when v_bal in ('limited_detail', 'full_detail') then a.balance_cents else null end,
      a.currency,
      -- Holdings: unchanged — full balances AND full account details, professional only.
      case when v_bal = 'full_detail' and v_det = 'full_detail' then a.holdings else '[]'::jsonb end,
      a.refresh_timestamp, a.last_sync_status, a.confidence_level, a.verification_status, a.created_at,
      v_bal,
      null::bigint,   -- ★ per-account brackets are no longer a non-owner field on this surface
      null::bigint
    from public.normalized_assets a
    where a.estate_id = p_estate_id
    order by a.created_at desc;
end;
$function$;
