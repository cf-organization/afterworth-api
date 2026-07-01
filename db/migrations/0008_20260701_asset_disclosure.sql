-- db/migrations/0008_20260701_asset_disclosure.sql
--
-- B2a — beneficiary/professional disclosure tiers for CONNECTED FINANCIAL DATA.
-- Extends the access-grant model (0002) to the asset CATEGORY path, and adds the asset
-- sensitivity ceiling. The read-time redaction itself lives in the list_estate_assets DEFINER RPC
-- (db/functions/list_estate_assets.sql) — this migration is the grant-model + ceiling only.
--
-- SECURITY MODEL (STRONGER than documents): documents rely on "the endpoint is the only read path"
-- for FIELD masking (soft). For assets the sensitive thing is the VALUE, so normalized_assets stays
-- OWNER-ONLY for direct SELECT (raw balance_cents/holdings are never in a non-owner-readable row);
-- the redaction happens inside a SECURITY DEFINER RPC. A direct PostgREST SELECT by a beneficiary
-- returns nothing — the balance is structurally unreachable (the connection_secrets discipline
-- applied to the balance). Idempotent; safe to re-run.
--
-- Broad-category granularity (decision): grants are per ProtectedDataCategory
-- (account_balances / institution_names / total_asset_value / linked_account_details), NOT per
-- asset_group. Per-group is a later refinement addable without restructuring.

-- =============================================================================
-- STEP 1 — access_grants.category CHECK (close the typo-silently-fails gap from 0002's TODO)
-- =============================================================================
-- category is a bare text column today (0002 left it unconstrained). Add a CHECK for the categories
-- actually in use: estate_documents (Vault, existing) + the four B2a asset categories. A NULL
-- category (per-document grants) is unaffected — CHECK passes on NULL. Existing 'estate_documents'
-- rows satisfy it. Split add so re-running is safe.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'access_grants_category_check') then
    alter table public.access_grants
      add constraint access_grants_category_check
      check (category is null or category in (
        'estate_documents',            -- Vault (0002, existing)
        'account_balances',            -- per-account balance value
        'institution_names',           -- which institutions are connected
        'total_asset_value',           -- the estate aggregate net worth
        'linked_account_details'       -- per-account detail: masked number + holdings
      ));
  end if;
end $$;

-- =============================================================================
-- STEP 2 — asset category sensitivity ceiling (mirrors document_grantable, per-CATEGORY)
-- =============================================================================
-- Assets have no per-row sensitivity column (unlike documents), so the ceiling is per-CATEGORY:
-- which tier may a given role be granted for a given asset category. Conservative default (THE
-- POLICY KNOB — adjust per product decision):
--   * account_balances / total_asset_value (the $ categories): beneficiary capped at
--     category_summary (NO exact figure); professional_delegate up to full_detail.
--   * institution_names / linked_account_details: both roles up to full_detail.
--   * 'hidden' is always grantable (it discloses nothing — the safe floor).
-- Re-checked at READ time in the RPC (authoritative — a later ceiling tightening applies to
-- already-created grants), and at WRITE time in the grant-creation RPC (B2b).
create or replace function public.asset_category_grantable(p_role text, p_category text, p_tier text)
returns boolean
language sql
immutable
as $$
  select case
    when p_tier = 'hidden' then true
    when p_category in ('account_balances', 'total_asset_value') then
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
  'Asset-disclosure ceiling (B2a): max grantable visibility_tier per (role, category). The $ '
  'categories cap beneficiaries below exact value; professionals may reach full_detail. THE POLICY '
  'KNOB — adjust per product decision. Mirrors document_grantable (0002) for the category path.';
