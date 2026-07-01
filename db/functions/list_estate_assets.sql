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
    and g.release_condition = 'immediately'   -- signal-based conditions stay dormant-deny (A.4)
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
  v_role  text;
  v_bal   text;   -- account_balances tier
  v_inst  text;   -- institution_names tier
  v_det   text;   -- linked_account_details tier
begin
  if v_uid is null then return; end if;

  -- OWNER: inherent full value, no redaction.
  if public.is_estate_owner(p_estate_id) then
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

  -- NON-OWNER: GRANT-BASED, like can_access_document — NOT membership-gated. A grantee reads via
  -- their grant even without an estate_memberships row (the documents precedent; a beneficiary can
  -- hold grants before/without a membership). grantee_role comes from the GRANT (explicit, singular),
  -- not the membership — so no multi-membership role-derivation ambiguity. The account_balances
  -- grant is the primary gate + the role source.
  select g.visibility_tier, g.grantee_role into v_bal, v_role
  from public.access_grants g
  where g.estate_id = p_estate_id
    and g.grantee_user_id = v_uid
    and g.category = 'account_balances'
    and g.status = 'active'
    and g.release_condition = 'immediately'   -- signal-based conditions stay dormant-deny (A.4)
  limit 1;

  -- No account_balances grant -> the non-owner sees NO asset rows (default-deny, safe).
  if v_bal is null then return; end if;

  v_inst := public.asset_grant_tier(p_estate_id, v_uid, 'institution_names');
  v_det  := public.asset_grant_tier(p_estate_id, v_uid, 'linked_account_details');

  -- Read-time ceiling re-check (authoritative), applied to EVERY resolved tier uniformly: an
  -- over-ceiling grant collapses to hidden, even if the grant predates a ceiling tightening. This
  -- is what makes exact value UNREACHABLE for a beneficiary — asset_category_grantable caps
  -- 'account_balances' at category_summary for role 'beneficiary', so v_bal can never become
  -- limited_detail/full_detail for them (the balance_cents AND holdings gates both key off v_bal).
  if not public.asset_category_grantable(v_role, 'account_balances', v_bal) then
    v_bal := 'hidden';
  end if;
  if v_inst is not null and not public.asset_category_grantable(v_role, 'institution_names', v_inst) then
    v_inst := 'hidden';
  end if;
  if v_det is not null and not public.asset_category_grantable(v_role, 'linked_account_details', v_det) then
    v_det := 'hidden';
  end if;

  return query
    select
      a.id, a.estate_id, a.connection_id,
      -- institution name gated by institution_names (hidden/none -> masked)
      case when coalesce(v_inst, 'hidden') = 'hidden' then 'Protected Institution' else a.institution_name end,
      a.provider_name, a.asset_group, a.asset_category, a.asset_subtype, a.source_type,
      -- masked account identifier gated by linked_account_details
      case when coalesce(v_det, 'hidden') in ('limited_detail', 'full_detail') then a.masked_identifier else '••••' end,
      -- ★ THE VALUE: exact ONLY at limited/full; otherwise NULL (raw never leaves)
      case when v_bal in ('limited_detail', 'full_detail') then a.balance_cents else null end,
      a.currency,
      -- holdings only when BOTH balances=full_detail AND linked_account_details=full_detail
      case when v_bal = 'full_detail' and coalesce(v_det, 'hidden') = 'full_detail' then a.holdings else '[]'::jsonb end,
      a.refresh_timestamp, a.last_sync_status, a.confidence_level, a.verification_status, a.created_at,
      v_bal,
      -- The value bracket — ALWAYS coarse, never exact. range_only brackets the per-asset value;
      -- category_summary brackets the per-GROUP total (sum over asset_group, then bracketed) so a
      -- single-asset group can't leak its lone balance. Nothing exact leaves for a non-owner.
      case
        when v_bal = 'range_only'       then public.asset_bracket_low(a.balance_cents)
        -- sum(bigint) returns numeric -> cast back to bigint (asset_bracket_low takes bigint)
        when v_bal = 'category_summary' then public.asset_bracket_low((sum(a.balance_cents) over (partition by a.asset_group))::bigint)
        else null
      end,
      case
        when v_bal = 'range_only'       then public.asset_bracket_high(a.balance_cents)
        when v_bal = 'category_summary' then public.asset_bracket_high((sum(a.balance_cents) over (partition by a.asset_group))::bigint)
        else null
      end
    from public.normalized_assets a
    where a.estate_id = p_estate_id
    order by a.created_at desc;
end;
$function$;
