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
-- beneficiaries  (live beneficiaries listing — POST /api/beneficiaries)
-- =============================================================================
-- Confirmed live: authenticated has SELECT (read path for the RLS-scoped listing).
-- RLS policy beneficiaries_read scopes the rows: the estate owner sees ALL rows in
-- the estate; a beneficiary-role caller sees ONLY their own stamped row (user_id =
-- auth.uid()). The grant alone is NOT the security boundary — RLS is.
-- authenticated has NO insert/update/delete — live write methods would fail until
-- those are granted in a future write slice.
grant select on table public.beneficiaries to authenticated;

-- Future write slice (NOT yet live — uncomment + apply when the write path is built):
-- grant insert, update, delete on table public.beneficiaries to authenticated;

-- =============================================================================
-- access_grants  (access-grant model slice — db/migrations/0002_20260620_access_grants.sql)
-- =============================================================================
-- FIRST write slice: grant management is inherently a write (owner creates/revokes
-- grants), so unlike documents/beneficiaries this gets insert + update. Writes are
-- owner-scoped by RLS (access_grants_insert / access_grants_update WITH CHECK
-- is_estate_owner), NOT by the grant — the grant is necessary, RLS is the boundary.
-- NO delete: revoke is a status change (status -> 'revoked'); audit rows retained.
-- Read is RLS-scoped: owner sees all estate grants; grantee sees only their own.
-- NOTE: direct table writes are the SLICE-only path. The planned interface is a
-- SECURITY DEFINER create_document_grant()/revoke_document_grant() RPC (Appendix A.2);
-- when it lands, insert/update here may be revoked in favor of execute on the RPC.
grant select, insert, update on table public.access_grants to authenticated;

-- =============================================================================
-- access_requests  (access-request lifecycle — db/migrations/0004_20260624_access_requests.sql)
-- =============================================================================
-- SELECT-ONLY. Unlike access_grants, this gets NO direct insert/update grant: all writes
-- go through the SECURITY DEFINER RPCs (create_access_request member-gated;
-- approve_access_request / deny_access_request owner-gated). RPC-only from day one avoids
-- the access_grants transition-debt (the direct insert/update there is now slated for
-- revocation once iOS uses the RPCs exclusively). Read is RLS-scoped
-- (access_requests_select): requester sees only their own; owner sees all in the estate.
grant select on table public.access_requests to authenticated;

-- =============================================================================
-- estate_memberships + profiles  (members listing — POST /api/vault/members)
-- =============================================================================
-- NO new table grant. The members endpoint reads estate_memberships x profiles through the
-- owner-gated SECURITY DEFINER rpc list_estate_members (db/functions/), NOT a direct authed
-- select — the display label is the member's profiles.email, and a user cannot read another
-- user's profiles row under RLS. DEFINER bypasses RLS to do the join; the is_estate_owner
-- gate in the RPC is the boundary. So `authenticated` needs only EXECUTE on the function
-- (default PUBLIC, matching the other DEFINER RPCs) — deliberately no SELECT grant on
-- estate_memberships or profiles to authenticated (least exposure; emails stay RPC-gated).
