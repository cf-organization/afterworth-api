-- ★ 0066 (2026-11-19): BODY MIRRORED FROM db/migrations/0066_20261119_beneficiary_connector_disclosure.sql.
-- Suppression is now the PRECISION test (withheld only beside a category-bracket breakdown), not the
-- existence of a balances grant; an account_balances grant at `hidden` neither grants nor suppresses.
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
  v_tot text;   -- total_asset_value, effective for THIS estate
  v_bal text;   -- account_balances, effective for THIS estate (the breakdown that may conflict)
begin
  if v_uid is null then return; end if;

  -- The exact estate total (DEFINER reads owner-only normalized_assets). Empty estate -> 0.
  select coalesce(sum(a.balance_cents), 0)::bigint, coalesce(max(a.currency), 'USD')
    into v_sum, v_cur
  from public.normalized_assets a
  where a.estate_id = p_estate_id;

  -- OWNER FIRST: inherent exact total, aal2 unconditionally, never suppressed.
  if public.is_estate_owner(p_estate_id) then
    perform public.require_aal2();
    return query select v_sum, null::bigint, null::bigint, 'full_detail'::text, v_cur, false;
    return;
  end if;

  -- NON-OWNER: the total is ITS OWN grant on THIS estate. Nothing else grants it — not balances, not
  -- membership, not ownership elsewhere, not aal2.
  v_tot := public.connector_disclosure_tier(p_estate_id, v_uid, 'total_asset_value');
  if v_tot = 'hidden' then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, v_cur, false;
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
  v_bal := public.connector_disclosure_tier(p_estate_id, v_uid, 'account_balances');
  if v_bal = 'category_summary' then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, v_cur, true;  -- suppressed
    return;
  end if;

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
