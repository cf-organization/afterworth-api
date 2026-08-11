-- db/migrations/0049_20260811_estate_discovery.sql
--
-- PHASE 10 — the SERVER-AUTHORITATIVE estate discovery projection.
--
-- The question this answers, for a survivor rather than an owner:
--   "What exists in this estate, what am I allowed to know about it right now,
--    and what is waiting on something before I can know more?"
--
-- ★ THE CLIENT IS NEVER SENT THE ESTATE AND ASKED TO HIDE THINGS. Everything below decides, in the
-- database, what a specific viewer may learn — and returns only that. A category the viewer holds no
-- grant for is not returned as `hidden`; it is not returned AT ALL, because "there is a category here
-- you may not see" is itself a disclosure.
--
-- ★ NO NEW DISCLOSURE VOCABULARY IS INVENTED. `access_grants.visibility_tier` already expresses the
-- ladder (hidden → range_only → category_summary → limited_detail → full_detail) and
-- `release_condition` already expresses "not yet". Phase 10 reuses both. Inventing a parallel
-- level 0..4 enum would have created a second disclosure authority to keep in step with the first.
--
-- ★ MANUAL ASSETS JOIN THE EXISTING GRANT MODEL — WITHOUT TOUCHING ITS SCOPE XOR. Phase 9 refused to
-- add an `asset_id` scope to `access_grants`, because that means altering the document_id/category XOR
-- and the ceiling trigger keyed on it — the security-critical centre of the disclosure model. Instead
-- the manual inventory becomes one more CATEGORY (`estate_inventory`) in a column that already exists
-- and is already ceiling-checked. Three contained edits (CHECK, ceiling fn, the RPC's inline list),
-- no structural change.
--
-- ★ DEATH-BASED RELEASE STAYS DORMANT, DELIBERATELY. `after_verified_death_or_incapacity` remains
-- default-deny exactly as migration 0002 left it. `estate_release_state()` below is the SEAM that a
-- future activation would drive, and it currently reports what the claims machinery already knows —
-- it flips nothing. Death activation is Phase 11 ("Death Activation & Survivor Mode"); wiring it here
-- would be inventing an irreversible disclosure trigger inside a discovery slice.
--
-- Idempotent; safe to re-run.

begin;

-- =============================================================================================
-- 1 · `estate_inventory` becomes a grantable category
-- =============================================================================================
-- The CHECK is rebuilt rather than amended in place — Postgres has no "add a value to a CHECK".
alter table public.access_grants drop constraint if exists access_grants_category_check;
alter table public.access_grants
  add constraint access_grants_category_check
  check (category is null or category in (
    'estate_documents',            -- Vault (0002)
    'account_balances',            -- per-account balance value (0008)
    'institution_names',           -- which institutions are connected (0008)
    'total_asset_value',           -- the estate aggregate net worth (0008)
    'linked_account_details',      -- per-account detail: masked number + holdings (0008)
    'estate_inventory'             -- ★ 0049: the MANUAL asset inventory (estate_assets)
  ));

-- =============================================================================================
-- 2 · the ceiling for the new category
-- =============================================================================================
-- ★ THE BENEFICIARY CAP MATCHES THE MONEY CATEGORIES, ON PURPOSE. A manual asset carries an
-- `approximate_value_cents`, so `estate_inventory` is a $ category in every sense that matters. The
-- established policy is that a beneficiary never receives an exact figure — capping here at
-- `category_summary` keeps one rule for estate value rather than two that will drift.
create or replace function public.asset_category_grantable(p_role text, p_category text, p_tier text)
returns boolean
language sql
immutable
as $$
  select case
    when p_tier = 'hidden' then true
    when p_category in ('account_balances', 'total_asset_value', 'estate_inventory') then
      case p_role
        when 'professional_delegate' then true                          -- up to full_detail
        when 'beneficiary'           then p_tier in ('range_only', 'category_summary')
        else false
      end
    when p_category in ('institution_names', 'linked_account_details') then
      p_role in ('beneficiary', 'professional_delegate')                -- up to full_detail
    else false                                                          -- unknown category -> deny
  end;
$$;

comment on function public.asset_category_grantable(text, text, text) is
  'Asset-disclosure ceiling: max grantable visibility_tier per (role, category). The $ categories — '
  'including estate_inventory (0049) — cap beneficiaries below exact value; professionals may reach '
  'full_detail. THE POLICY KNOB. Mirrors document_grantable for the category path.';

commit;

-- =============================================================================================
-- 3 · RPCs — APPLY db/functions/estate_discovery_rpcs.sql IMMEDIATELY AFTER THIS FILE
-- =============================================================================================
-- The bodies live in ONE place. `scripts/buildEstateDiscoveryBundle.mjs` concatenates this file and
-- that one into a single paste-ready artifact, so the SQL editor still gets one paste.
--
-- NOTE: `create_asset_grant` also carries an INLINE category list which must include
-- `estate_inventory`, or the new category is accepted by the table and rejected by the only door that
-- writes to it. That edit ships in the same functions file, and the authorization suite asserts a
-- grant can actually be created for the new category — a CHECK widened without the door widened would
-- otherwise look correct and be unusable.
