-- 0066_20261119_beneficiary_connector_disclosure.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- BENEFICIARY CONNECTOR DISCLOSURE — scope every financial read to the selected estate, and make each
-- sharing choice return what its name says.
--
-- ★ WHAT WAS FOUND, 2026-11-18/19, ON NONPROD (pilot, synthetic data only).
--
--   A projection applied to nonprod by hosted SQL on 2026-11-18 (never in this repository) made
--   get_estate_discovery emit a PER-ACCOUNT bracket for connected balances at BOTH beneficiary tiers:
--   "Categories only" (range_only) and "Category totals" (category_summary) rendered identically, and
--   "Category totals" disclosed more per-account precision than the Estate-financials reader
--   (list_estate_assets) ever did. list_estate_assets itself returned per-account rows, with brackets,
--   to any non-owner holding ANY account_balances grant — including a grant at tier `hidden`.
--   get_estate_net_worth suppressed the estate total whenever an account_balances grant merely EXISTED,
--   so an owner who withdrew balances with "No access" also silently withdrew the total.
--
--   Possible disclosure: any beneficiary of a nonprod estate holding a connector grant, since 2026-11-18.
--   Evidence of viewing: the owner's own pilot account on an Android device (owner-reported), and the
--   repository's fixture persona under the Detox harness. No production project carries connectors.
--
-- ★ THE PILOT DECISIONS THIS IMPLEMENTS.
--
--   1. SCOPE. Every non-owner read resolves role and grants for THE REQUESTED ESTATE ONLY, before any
--      grouping or total. Ownership or a more generous grant elsewhere confers nothing. A missing grant,
--      a NULL tier, an unknown estate: nothing. AAL2 satisfies an authentication requirement; it never
--      creates a grant. All three readers already took p_estate; this migration makes the per-estate
--      resolution ONE helper (`connector_disclosure_tier`) so the three cannot drift apart again.
--
--   2. WHAT EACH CHOICE RETURNS, for connected (aggregator-sourced) balances, non-owner:
--        hidden / none      → nothing for that category. No presence, no rows, no amounts.
--        range_only         → "Categories only": WHICH connector categories exist. No amounts, no
--                             per-account brackets, no rows through this grant.
--        category_summary   → "Category totals": ONE bracket per connector category = the bracket of the
--                             SUM of that category's accounts in this estate. No rows, ids, names, exact
--                             amounts or per-account brackets through this grant. ★ A category holding
--                             ONE account: its bracket IS that account's bracket — stated, not promised
--                             away.
--        limited_detail /   → professional only (ceiling). Exact per-account balances and exact per-
--        full_detail          category totals, aal2 required, as today. Holdings: never through
--                             discovery; through list_estate_assets only at full+full, as today.
--      Descriptive fields (institution_names, linked_account_details) are boolean grants: any tier
--      above hidden discloses the field, on rows that exist ONLY because a descriptive grant (or an
--      exact balances tier) discloses something row-level.
--
--   3. ESTATE TOTAL is its own grant (total_asset_value). An account_balances grant at `hidden`
--      neither grants a total nor suppresses one. ★ THE PRECISION TEST decides suppression: the total
--      is withheld only when combining it with the disclosed breakdown could pin a disclosed figure
--      inside a NARROWER range than its own tier allows. That is exactly the category_summary case
--      (worked example, asserted by the harness: cash $48k→[10k,50k], investments $4k→[0,10k], total
--      $52k→[50k,100k]; total_low − inv_high = $40k, so cash is pinned to [40k,50k] ⊂ [10k,50k]).
--      range_only discloses no amounts, so nothing can be combined and the total co-appears. Exact
--      tiers already disclose every figure, so a sum adds nothing and the total co-appears.
--
--   4. HOLDINGS ARE OWNER-ONLY FOR THIS PILOT, across every connector reader. A professional keeps exact
--      balances with an eligible grant and a CURRENT aal2 session; position-level data does not leave
--      the owner's own surfaces.
--   5. ACCOUNT DETAILS (masked identifier) disclose at limited_detail / full_detail only — on both
--      non-owner readers, with the same threshold. An institution-name grant by itself never reveals
--      an account's ending.
--   6. ONE EFFECTIVE BALANCE TIER PER SESSION. Discovery and the total reader resolve the balances tier
--      through the same helper, which degrades an exact tier to the category bracket when the session
--      is not currently aal2 — so the anti-inference rule is applied to the breakdown the person can
--      ACTUALLY see, through either reader.
--   7. NO ESTATE METADATA BEFORE THE GRANT. The total reader checks the total grant before it reads a
--      single row of the estate: an ungranted caller receives no currency and no amount, and a
--      nonexistent estate answers identically.
--
-- ★ MUTATION SURFACE. TWO NEW FUNCTIONS (connector_disclosure_tier, effective_balance_tier). THREE FUNCTION BODIES REPLACED
--   (list_estate_assets, get_estate_net_worth, get_estate_discovery). Four grant/revoke statements.
--   No table, column, index, constraint, policy or DML. Bracket thresholds unchanged. Inventory
--   (estate_assets) semantics unchanged. No existing grant is widened: every non-owner path returns a
--   subset of what it returned before, except the estate total for a viewer whose balances grant is
--   `hidden` or `range_only` — which the pilot decision names explicitly.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- connector_disclosure_tier(p_estate, p_uid, p_category) -> text
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- THE ONE per-estate resolution every connector reader uses. Returns the EFFECTIVE tier for this
-- viewer, this estate, this category: the active grant's tier under the canonical release predicate
-- (asset surfaces honour `immediately` and only `immediately`), clamped by the read-time ceiling for
-- the grant's own role. Anything it cannot resolve is 'hidden' — never NULL, never a default.
--
-- ★ IT TAKES THE ESTATE AS AN ARGUMENT AND NOTHING ELSE SUPPLIES IT. There is no fallback to "the
--   viewer's primary estate" and no cross-estate lookup; a grant on another estate is simply not in
--   the predicate. Ownership is NOT consulted here — callers branch on is_estate_owner first, so an
--   owner is never resolved through grants and a grantee is never resolved through ownership.
create or replace function public.connector_disclosure_tier(p_estate uuid, p_uid uuid, p_category text)
 returns text
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare v_tier text; v_role text;
begin
  if p_uid is null or p_estate is null then return 'hidden'; end if;

  select g.visibility_tier, g.grantee_role into v_tier, v_role
    from public.access_grants g
   where g.estate_id = p_estate
     and g.grantee_user_id = p_uid
     and g.category = p_category
     and g.status = 'active'
     and public.release_condition_satisfied(g.release_condition, g.approved_at, 'legacy_immediate_only',
                                            public.estate_lifecycle_state(p_estate))
   limit 1;

  if v_tier is null then return 'hidden'; end if;
  -- Read-time ceiling clamp (authoritative): a grant above its role's ceiling discloses nothing.
  if not public.asset_category_grantable(v_role, p_category, v_tier) then return 'hidden'; end if;
  return v_tier;
end;
$function$;
revoke execute on function public.connector_disclosure_tier(uuid, uuid, text) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- effective_balance_tier(p_estate, p_uid) -> text
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- THE ONE ANSWER PER SESSION for the balances tier, used by discovery AND the total reader. An exact
-- tier (professional) without a CURRENT aal2 session degrades to the category bracket — it never raises
-- here, so the estate summary keeps working, and it never differs between readers, so the anti-inference
-- rule is evaluated against the breakdown the viewer can actually see.
create or replace function public.effective_balance_tier(p_estate uuid, p_uid uuid)
 returns text
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare v_bal text := public.connector_disclosure_tier(p_estate, p_uid, 'account_balances');
begin
  if v_bal in ('limited_detail', 'full_detail') and not public.aal2_is_current() then
    return 'category_summary';
  end if;
  return v_bal;
end;
$function$;
revoke execute on function public.effective_balance_tier(uuid, uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- list_estate_assets(p_estate_id) -> SETOF redacted asset rows
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- Owner: full rows, aal2. Non-owner: rows ONLY when something row-level is disclosed to them on THIS
-- estate — an exact balances tier (professional, aal2) or a descriptive grant. Per-account brackets
-- are no longer emitted to any non-owner: the bracket surfaces are per CATEGORY and live in
-- get_estate_discovery. A beneficiary holding only "Category totals" therefore receives NO rows here.
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
  v_det_shows boolean;
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
  -- ★ ACCOUNT DETAILS DISCLOSE AT limited_detail / full_detail ONLY — the same threshold discovery uses.
  v_det_shows := v_det in ('limited_detail', 'full_detail');

  -- ★ ROWS EXIST ONLY WHEN SOMETHING ROW-LEVEL IS DISCLOSED. A balances grant at a bracket tier
  --   discloses categories (elsewhere), not accounts; a details grant below its threshold discloses
  --   nothing; neither produces rows here.
  if v_bal not in ('limited_detail', 'full_detail') and v_inst = 'hidden' and not v_det_shows then
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
      case when v_det_shows then a.masked_identifier else '••••' end,
      -- Exact ONLY at an exact tier; otherwise NULL. Never a bracket per account.
      case when v_bal in ('limited_detail', 'full_detail') then a.balance_cents else null end,
      a.currency,
      -- ★ HOLDINGS ARE OWNER-ONLY FOR THIS PILOT. Position-level data leaves only the owner's branch
      --   above; no grant combination reaches it here.
      '[]'::jsonb,
      a.refresh_timestamp, a.last_sync_status, a.confidence_level, a.verification_status, a.created_at,
      v_bal,
      null::bigint,   -- ★ per-account brackets are no longer a non-owner field on this surface
      null::bigint
    from public.normalized_assets a
    where a.estate_id = p_estate_id
    order by a.created_at desc;
end;
$function$;
revoke execute on function public.list_estate_assets(uuid) from public, anon;
grant  execute on function public.list_estate_assets(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- get_estate_net_worth(p_estate_id) -> ONE row: the estate total, redacted
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
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
  v_tot text;   -- total_asset_value, effective for THIS estate
  v_bal text;   -- account_balances, EFFECTIVE for this session (the breakdown that may conflict)
begin
  if v_uid is null then return; end if;

  -- OWNER FIRST: inherent exact total, aal2 unconditionally, never suppressed.
  if public.is_estate_owner(p_estate_id) then
    perform public.require_aal2();
    select coalesce(sum(a.balance_cents), 0)::bigint, coalesce(max(a.currency), 'USD')
      into v_sum, v_cur
    from public.normalized_assets a
    where a.estate_id = p_estate_id;
    return query select v_sum, null::bigint, null::bigint, 'full_detail'::text, v_cur, false;
    return;
  end if;

  -- NON-OWNER: the total is ITS OWN grant on THIS estate. Nothing else grants it — not balances, not
  -- membership, not ownership elsewhere, not aal2.
  -- ★ THE GRANT IS CHECKED BEFORE ONE ROW OF THE ESTATE IS READ. An ungranted caller — or a caller
  --   naming an estate that does not exist — receives no currency and no amount: the row is identical
  --   either way. Currency is estate-derived metadata and is emitted only beside a disclosed figure.
  v_tot := public.connector_disclosure_tier(p_estate_id, v_uid, 'total_asset_value');
  if v_tot = 'hidden' then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, null::text, false;
    return;
  end if;

  -- ★ THE PRECISION TEST, not the existence test. The total is withheld only when the breakdown this
  --   viewer actually RECEIVES could be combined with it to pin a disclosed figure inside a narrower
  --   range than its tier allows. That is the per-category BRACKET breakdown (category_summary):
  --   total_low − Σ(other categories' highs) can exceed a category's own low bound.
  --     hidden      → no breakdown; nothing to combine.                       total shows
  --     range_only  → categories only, no amounts; nothing to combine.        total shows
  --     exact tiers → every figure already disclosed; a sum adds nothing.     total shows
  --     category_summary → brackets that a total can narrow.                  total withheld
  --   ★ THE SAME EFFECTIVE TIER DISCOVERY USES — an exact tier without a current aal2 session IS a
  --     category-bracket breakdown to this session, and is treated as one here too.
  v_bal := public.effective_balance_tier(p_estate_id, v_uid);
  if v_bal = 'category_summary' then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, null::text, true;  -- suppressed
    return;
  end if;

  -- Only now — a figure WILL be disclosed — is the estate read.
  select coalesce(sum(a.balance_cents), 0)::bigint, coalesce(max(a.currency), 'USD')
    into v_sum, v_cur
  from public.normalized_assets a
  where a.estate_id = p_estate_id;

  -- Emit per the TOTAL grant's own tier: bracketed below limited_detail; exact (aal2) at or above.
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
revoke execute on function public.get_estate_net_worth(uuid) from public, anon;
grant  execute on function public.get_estate_net_worth(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- get_estate_discovery(p_estate) -> jsonb — THE PROJECTION
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- Inventory (estate_assets) semantics UNCHANGED from 0049. Connector keys, all per THIS estate:
--   connected_categories   ABSENT when account_balances resolves hidden. Otherwise one object per
--                          connector category present in the estate: { asset_group, total_cents,
--                          range_low_cents, range_high_cents } — all three amounts NULL at range_only
--                          (presence only); the SUM's bracket at category_summary; the exact sum at an
--                          exact tier with aal2 (degraded to the bracket without aal2).
--   connected_institutions ABSENT when nothing row-level is disclosed. Otherwise rows carrying only the
--                          descriptive fields their own grants disclose, plus balance_cents at an exact
--                          tier with aal2. NEVER a per-account bracket. NEVER holdings.
--   connected_total        get_estate_net_worth's row for this viewer, verbatim; NULL when the reader
--                          refused for want of aal2. Its suppression rule is the reader's.
create or replace function public.get_estate_discovery(p_estate uuid)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid        uuid := auth.uid();
  v_tier       text;
  v_is_owner   boolean;
  v_member     boolean;
  v_categories jsonb;
  v_items      jsonb;
  v_docs       int;
  v_bal        text;
  v_inst       text;
  v_det        text;
  v_tot_gate   text;
  v_aal2       boolean;
  v_exact      boolean;
  v_det_shows  boolean;
  v_groups     jsonb := null;
  v_conn       jsonb := null;
  v_total      jsonb := null;
begin
  if v_uid is null then
    return jsonb_build_object('authorized', false);
  end if;

  v_is_owner := public.is_estate_owner(p_estate);
  v_member   := public.is_estate_member(p_estate);
  v_tier     := public.inventory_disclosure_tier(p_estate, v_uid);

  -- ── connector tiers, resolved for THIS estate only ─────────────────────────────────────────────
  if v_is_owner then
    v_bal := 'full_detail'; v_inst := 'full_detail'; v_det := 'full_detail'; v_tot_gate := 'full_detail';
  else
    -- ★ THE SAME EFFECTIVE TIER THE TOTAL READER USES (exact degrades to the bracket without aal2).
    v_bal      := public.effective_balance_tier(p_estate, v_uid);
    v_inst     := public.connector_disclosure_tier(p_estate, v_uid, 'institution_names');
    v_det      := public.connector_disclosure_tier(p_estate, v_uid, 'linked_account_details');
    v_tot_gate := public.connector_disclosure_tier(p_estate, v_uid, 'total_asset_value');  -- gate only
  end if;
  -- ★ ACCOUNT DETAILS DISCLOSE AT limited_detail / full_detail ONLY — the threshold list_estate_assets uses.
  v_det_shows := v_det in ('limited_detail', 'full_detail');

  -- ★ aal2 satisfies an authentication requirement; it never creates a grant. The owner's exact view
  --   degrades to the category bracket without a current aal2 session — it never raises.
  v_aal2 := public.aal2_is_current();
  if v_is_owner and not v_aal2 then
    v_bal := 'category_summary';
  end if;
  v_exact := v_bal in ('limited_detail', 'full_detail');

  -- ★ THE GATE: a grant on THIS estate alone is sufficient; nothing elsewhere is.
  if not v_is_owner and not v_member and v_tier = 'hidden'
     and v_bal = 'hidden' and v_inst = 'hidden' and not v_det_shows and v_tot_gate = 'hidden' then
    return jsonb_build_object('authorized', false);
  end if;

  -- ── connected categories (the ONLY place a non-owner sees a connector amount) ───────────────────
  if v_bal <> 'hidden' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'asset_group',      g.asset_group,
             'total_cents',      case when v_exact then g.sum_cents end,
             'range_low_cents',  case when v_bal = 'category_summary'
                                      then public.asset_bracket_low(g.sum_cents) end,
             'range_high_cents', case when v_bal = 'category_summary'
                                      then public.asset_bracket_high(g.sum_cents) end
           ) order by g.asset_group), '[]'::jsonb) into v_groups
      from (select n.asset_group, coalesce(sum(n.balance_cents), 0)::bigint as sum_cents
              from public.normalized_assets n
             where n.estate_id = p_estate
             group by n.asset_group) g;
  end if;

  -- ── connected institutions (rows exist only because a descriptive grant or an exact tier says so)
  if v_exact or v_inst <> 'hidden' or v_det_shows then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',                n.id,
             'asset_group',       n.asset_group,
             'currency',          n.currency,
             'last_sync_status',  n.last_sync_status,
             'institution',       case when v_inst <> 'hidden' then n.institution_name end,
             'masked_identifier', case when v_det_shows then n.masked_identifier end,
             'balance_cents',     case when v_exact then n.balance_cents end,
             -- ★ COMPATIBILITY KEYS, ALWAYS NULL. The pilot client installed before this migration
             --   REQUIRES these two keys on a row (its decoder refuses the whole payload without them)
             --   and renders nothing for a null. They carry no figure and will be dropped once that
             --   client is retired.
             'range_low_cents',   null,
             'range_high_cents',  null
           ) order by n.institution_name nulls last, n.id), '[]'::jsonb) into v_conn
      from public.normalized_assets n
     where n.estate_id = p_estate;
  end if;

  -- ── estate total — the reader's row, verbatim; its suppression rule is its own ─────────────────
  begin
    select jsonb_build_object(
             'total_cents',             w.total_cents,
             'range_low_cents',         w.range_low_cents,
             'range_high_cents',        w.range_high_cents,
             'resolved_tier',           w.resolved_tier,
             'currency',                w.currency,
             'suppressed_by_breakdown', w.suppressed_by_breakdown
           ) into v_total
      from public.get_estate_net_worth(p_estate) w
     limit 1;
  exception
    when insufficient_privilege then   -- the reader's aal2 refusal, and ONLY that
      v_total := null;
  end;

  select count(*) into v_docs
    from public.documents d
   where d.estate_id = p_estate
     and (v_is_owner or public.can_access_document(d.id));

  if v_tier = 'hidden' then
    -- ★ ABSENT, NOT NULL, for an undisclosed connector key — appended conditionally, never by
    --   stripping nulls globally, which would also erase the nested nulls the client relies on.
    return jsonb_build_object(
      'authorized', true,
      'is_owner', v_is_owner,
      'inventory_tier', 'hidden',
      'release_state', public.estate_release_state(p_estate),
      'document_count', v_docs,
      'connected_total', v_total
    )
    || case when v_groups is null then '{}'::jsonb else jsonb_build_object('connected_categories', v_groups) end
    || case when v_conn   is null then '{}'::jsonb else jsonb_build_object('connected_institutions', v_conn) end;
  end if;

  -- ── inventory categories (UNCHANGED from 0049) ─────────────────────────────────────────────────
  select coalesce(jsonb_agg(x order by x->>'sort_order'), '[]'::jsonb) into v_categories
  from (
    select jsonb_build_object(
             'category',     a.category,
             'display_name', c.display_name,
             'sort_order',   lpad(c.sort_order::text, 4, '0'),
             'item_count',   case when v_tier = 'range_only' then null else count(*) end,
             'total_cents',  case when v_tier = 'full_detail'
                                  then coalesce(sum(a.approximate_value_cents), 0) else null end,
             'range_low_cents',  case when v_tier in ('category_summary','limited_detail')
                                      then public.asset_bracket_low(coalesce(sum(a.approximate_value_cents), 0)::bigint) end,
             'range_high_cents', case when v_tier in ('category_summary','limited_detail')
                                      then public.asset_bracket_high(coalesce(sum(a.approximate_value_cents), 0)::bigint) end
           ) as x
      from public.estate_assets a
      join public.estate_asset_category c on c.value = a.category
     where a.estate_id = p_estate
       and a.archived_at is null
     group by a.category, c.display_name, c.sort_order
  ) s;

  -- ── inventory items (UNCHANGED from 0049) ──────────────────────────────────────────────────────
  if v_tier in ('limited_detail','full_detail') then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',            a.id,
             'category',      a.category,
             'subtype',       a.subtype,
             'label',         a.label,
             'institution',   a.institution_name,
             'jurisdiction',  case when v_tier = 'full_detail' then a.jurisdiction end,
             'country_code',  case when v_tier = 'full_detail' then a.country_code end,
             'reference_hint', case when v_tier = 'full_detail' then a.reference_hint end,
             'value_cents',   case when v_tier = 'full_detail' then a.approximate_value_cents end,
             'currency',      a.currency,
             'verification_status', a.verification_status,
             'document_count', (select count(*) from public.estate_asset_documents l where l.asset_id = a.id)
           ) order by a.created_at desc), '[]'::jsonb) into v_items
      from public.estate_assets a
     where a.estate_id = p_estate
       and a.archived_at is null;
  else
    v_items := '[]'::jsonb;
  end if;

  -- ★ ABSENT, NOT NULL, for an undisclosed connector key — appended conditionally, never by
  --   stripping nulls globally, which would also erase the nested nulls the client relies on.
  return jsonb_build_object(
    'authorized', true,
    'is_owner', v_is_owner,
    'inventory_tier', v_tier,
    'release_state', public.estate_release_state(p_estate),
    'document_count', v_docs,
    'categories', v_categories,
    'items', v_items,
    'connected_total', v_total
  )
  || case when v_groups is null then '{}'::jsonb else jsonb_build_object('connected_categories', v_groups) end
  || case when v_conn   is null then '{}'::jsonb else jsonb_build_object('connected_institutions', v_conn) end;
end;
$function$;
revoke execute on function public.get_estate_discovery(uuid) from public, anon;
grant  execute on function public.get_estate_discovery(uuid) to authenticated;
