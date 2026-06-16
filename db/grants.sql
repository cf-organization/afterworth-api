-- db/grants.sql
--
-- Version-controlled record of table-level GRANTs that the live database relies on.
-- These grants exist in the live Supabase instance but were not previously captured
-- anywhere, so a fresh DB rebuild would silently lack them. Re-running this file is
-- safe: GRANT is idempotent.
--
-- Convention: each table gets one block. The minimum grant needed for an
-- RLS-protected read endpoint is `SELECT to authenticated` — RLS policies (not
-- grants) do the row-level membership scoping. Writes are intentionally NOT granted
-- to `authenticated` until a write slice needs them.
--
-- Source of truth for what is currently live:
--   select grantee, privilege_type
--   from information_schema.role_table_grants
--   where table_schema = 'public' and table_name = '<table>'
--   order by grantee, privilege_type;
--
-- NOTE: information_schema.role_table_grants shows table-level GRANTs only, not RLS
-- policies. RLS policy definitions live in pg_policies and are captured separately.

-- =============================================================================
-- documents  (live Vault listing — POST /api/vault/documents)
-- =============================================================================
-- Confirmed live: authenticated has SELECT (read path for the RLS-scoped listing).
-- authenticated has NO insert/update/delete — live write methods (upload, delete,
-- archive) would fail until those are granted in a future write slice.
grant select on table public.documents to authenticated;

-- Future write slice (NOT yet live — uncomment + apply when the write path is built):
-- grant insert, update, delete on table public.documents to authenticated;

-- =============================================================================
-- assets  (TODO: next read slice — capture live grants before wiring)
-- =============================================================================
-- grant select on table public.assets to authenticated;

-- =============================================================================
-- beneficiaries  (TODO: next read slice — capture live grants before wiring)
-- =============================================================================
-- grant select on table public.beneficiaries to authenticated;
