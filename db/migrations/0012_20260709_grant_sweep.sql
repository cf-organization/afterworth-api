-- 0012_20260709_grant_sweep — schema-wide non-DML grant sweep + the default-privilege cure.
--
-- CONTEXT: the TRUNCATE/REFERENCES/TRIGGER "disease" 0011 fixed for audit_logs ONLY was systemic —
-- every public table carried TRUNCATE, REFERENCES, TRIGGER (and, on this PG17 instance, MAINTAIN)
-- for anon + authenticated + service_role. RLS does NOT gate TRUNCATE, so any client role could wipe
-- an RLS-protected table. ROOT CAUSE (D1 finding, pg_default_acl): the grantor role `postgres` carried
-- a DEFAULT ACL that granted `Dxtm` (TRUNCATE/REFERENCES/TRIGGER/MAINTAIN) to the three client roles on
-- every newly-created table — so partial hardening (revoking per-table) re-acquires the disease on the
-- next `create table`. The cure is REVOKE on all existing tables PLUS an ALTER DEFAULT PRIVILEGES so
-- future tables start clean.
--
-- BEHAVIOR-PRESERVING (the hard constraint of this slice): touches ONLY TRUNCATE/REFERENCES/TRIGGER/
-- MAINTAIN. NO SELECT/INSERT/UPDATE/DELETE grant is changed on any existing table. RLS is untouched.
-- The deliberate DML grants (db/grants.sql) are unaffected — verify with the D3' before/after diff.
--
-- BEFORE (snapshot D2, captured 2026-07-09): all 18 public tables carried TRUNCATE, REFERENCES,
-- TRIGGER (+ MAINTAIN) for anon, authenticated, service_role. NOTE: MAINTAIN prints as `m` in
-- pg_class.relacl but is INVISIBLE to information_schema.role_table_grants — verify the AFTER state
-- with aclexplode(relacl), not information_schema (see 2c verification queries).
--
-- Idempotent (REVOKE of an absent privilege is a no-op; ALTER DEFAULT PRIVILEGES REVOKE is idempotent).
-- pgTAP removal is a SEPARATE migration (0013) so a RESTRICT-blocked DROP can never roll back this sweep.

begin;

-- ---- (1) strip the four non-DML privileges from client roles on all EXISTING public tables ----
-- 'maintain' is a PG17 privilege (VACUUM/ANALYZE/etc.); this instance carries it in the ACL.
revoke truncate, references, trigger, maintain
  on all tables in schema public
  from anon, authenticated, service_role;

-- ---- (2) the systemic cure: stop FUTURE tables re-acquiring anything ----
-- Scoped to grantor `postgres` (the D1 origin of the default grant). REVOKE ALL means new tables
-- created by postgres in `public` start with NO client-role grants — deliberate DML must then be
-- granted EXPLICITLY per table (db/grants.sql discipline), which is the intended forward posture.
-- supabase_admin's default privileges are PLATFORM-MANAGED and deliberately NOT altered here; the
-- gap is covered by the standing rule that every future table-creating migration self-revokes
-- TRUNCATE/REFERENCES/TRIGGER/MAINTAIN (see CLAUDE.md lesson).
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated, service_role;

commit;
