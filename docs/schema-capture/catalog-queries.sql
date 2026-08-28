-- CANONICAL SCHEMA SNAPSHOT — read-only catalog queries.
--
-- METHOD C: the zero-credential fallback, and the supplement to method A.
--
-- Every statement here is a SELECT against a catalog view. There is no CREATE, ALTER, DROP,
-- INSERT, UPDATE, DELETE, GRANT or function call that writes. Nothing here reads table DATA --
-- these read the catalog's description OF the tables, never their rows.
--
-- Run in: Supabase Dashboard -> SQL Editor. No new credential is required; the dashboard session
-- already authenticates. This is the same manual pattern as
-- docs/invitations/owner-invitation-migration-runbook.md.
--
-- Run C2 ALWAYS. Run C1/C3/C4 only if method A was not used or its dry run showed a gap.

-- ── C1 · every application table and column ────────────────────────────────────────────────────
select table_name, ordinal_position, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
order by table_name, ordinal_position;

-- ── C2 · RLS POLICIES, INCLUDING THE ONES IN storage.* ─────────────────────────────────────────
-- ★ THIS IS THE ONE THAT MATTERS MOST. Migration 0030 creates documents_estate_read and
--   documents_estate_insert on storage.objects -- application-owned policies living in a
--   platform schema, which a dump scoped to `public` would silently omit. Their absence from a
--   snapshot would look exactly like a clean capture.
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname in ('public', 'storage')
order by schemaname, tablename, policyname;

-- ── C3 · which tables have RLS enabled at all ──────────────────────────────────────────────────
-- A table with policies but rowsecurity=false enforces nothing. Presence of a policy and
-- enforcement of it are two properties; check both.
select schemaname, tablename, rowsecurity, forcerowsecurity
from pg_tables
where schemaname in ('public', 'storage')
order by schemaname, tablename;

-- ── C4 · functions, with their security posture ────────────────────────────────────────────────
select n.nspname as schema, p.proname as name,
       pg_get_function_identity_arguments(p.oid) as args,
       p.prosecdef as security_definer, l.lanname as language
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_language  l on l.oid = p.prolang
where n.nspname = 'public'
order by p.proname;

-- ── C5 · constraints and indexes ───────────────────────────────────────────────────────────────
select conrelid::regclass as table_name, conname, contype,
       pg_get_constraintdef(oid) as definition
from pg_constraint
where connamespace = 'public'::regnamespace
order by conrelid::regclass::text, conname;

select tablename, indexname, indexdef
from pg_indexes
where schemaname = 'public'
order by tablename, indexname;
