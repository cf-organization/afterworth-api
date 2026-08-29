-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- R-02 · ISOLATED HOSTED EVENT-TRIGGER MUTATION PROBE  ·  probe version v1
--
-- TARGET PROJECT : afterworth-nonprod
-- TARGET REF     : qxzeougbaarecaiiqsay
-- TARGET REGION  : us-west-2
--
-- STATUS         : DESIGN ONLY — NOT AUTHORIZED FOR EXECUTION.
--                  mutation_test_authorized = false. This file must not be run until R02_4.
--
-- ★ NEVER RUN AGAINST yiaavvkulrpqkkbqhwit (application-facing) OR rpjjwkoezuihpobotbjh
--   (paused, retained). Unlike the read-only packs, this one contains DDL.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- THE ONE QUESTION
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
--   Can the hosted execution context create the class of event trigger that Model C bootstrap
--   phase 120 requires?
--
-- Not "is Model C compatible". Not "can we do arbitrary DDL". One privilege boundary.
--
-- ★ REFUSAL IS A VALID RESULT, AND IS THE LIKELY ONE.
--
--   Q1 observed `postgres.rolsuper = false` on the hosted target. Local validation against
--   PostgreSQL 17 reproduced the boundary exactly: a role with rolcreaterole + rolcreatedb +
--   bypassrls but WITHOUT superuser is refused with
--
--     ERROR:  permission denied to create event trigger "..."
--     HINT:   Must be superuser to create an event trigger.
--
--   That is evidence about vanilla PostgreSQL, not about Supabase, which may grant the capability
--   by other means. The probe exists precisely because the two can differ. If it is refused, that
--   is the ANSWER — it is recorded and the unit stops. NO WORKAROUND IS AUTHORIZED: no SET ROLE,
--   no supabase_admin, no GRANT, no RPC, no alternative connection path.
--
-- ★ LOCAL VALIDATION ALSO SHOWED CREATE FUNCTION SUCCEEDS FOR A NON-SUPERUSER. So the likely path
--   is step 2 succeeding and step 3 failing, which is exactly why cleanup of the function is
--   pre-authorized and specified rather than improvised at the point of failure.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- CLEANUP MODEL: EXPLICIT (Model B), NOT TRANSACTIONAL ROLLBACK (Model A)
--
--   Local validation confirmed both CREATE FUNCTION and CREATE EVENT TRIGGER *are* transactional —
--   a ROLLBACK removed both. Model A is therefore technically viable, and is still NOT chosen:
--
--   1. The Supabase SQL Editor's transaction handling is UNVERIFIED. It may auto-commit per
--      statement. A probe whose safety depends on an unverified property of the tool running it is
--      not a safe probe.
--   2. When a statement fails inside a transaction, PostgreSQL aborts it and every later statement
--      in the block returns "current transaction is aborted" — so the FAILURE path, which is the
--      likely one here, becomes the least legible one. Explicit statements keep each result
--      readable.
--   3. Explicit DROPs are auditable after the fact: POST checks prove the objects are gone
--      regardless of how the session behaved.
--
--   Emergency cleanup is at the bottom of this file and is idempotent.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- Run each numbered step SEPARATELY and record its result before continuing.


-- ══ STEP 1 · PRE CHECK (SELECT only) ════════════════════════════════════════════════════════════
-- Purpose : prove the probe objects do not already exist, the canonical Model C objects do not
--           exist, and the project is still an AfterWorth virgin.
-- Expect  : every column 0.
-- BLOCKER : any non-zero. Do not proceed.
select
  (select count(*) from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'r02_probe_event_fn_v1')      as probe_function_present,
  (select count(*) from pg_catalog.pg_event_trigger
    where evtname = 'r02_probe_event_trigger_v1')                           as probe_trigger_present,
  (select count(*) from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'rls_auto_enable')            as canonical_function_present,
  (select count(*) from pg_catalog.pg_event_trigger
    where evtname = 'ensure_rls')                                           as canonical_trigger_present,
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_type = 'BASE TABLE')            as public_tables_present;


-- ══ STEP 2 · CREATE THE DISPOSABLE FUNCTION ═════════════════════════════════════════════════════
-- ★ NO SIDE EFFECTS BY CONSTRUCTION. Empty body: no writes, no DDL, no network, no auth or storage
--   access, no logging. NOT SECURITY DEFINER — local validation confirmed it is unnecessary, and an
--   unnecessary DEFINER on a probe is an escalation nobody asked for.
-- Expect  : CREATE FUNCTION
-- If this FAILS: HALT. Classify FUNCTION_CREATION_REFUSED. Do not attempt step 3.
create function public.r02_probe_event_fn_v1()
  returns event_trigger
  language plpgsql
  set search_path to 'pg_catalog'
  as $probe$ begin end $probe$;


-- ══ STEP 3 · THE ACTUAL PRIVILEGE BOUNDARY ══════════════════════════════════════════════════════
-- ★ THIS IS THE ENTIRE POINT OF THE PROBE. Same event and tag class as Model C phase 120, under a
--   disposable name. No table is created to trigger it: the question is whether the event trigger
--   OBJECT can be created, not whether it fires. Firing verification, if ever needed, is a separate
--   later sub-step and is deliberately not bundled in here.
-- Expect  : CREATE EVENT TRIGGER  — or a permission-denied error.
-- If this FAILS: run STEP 6 (function cleanup) then HALT. Classify EVENT_TRIGGER_CREATION_REFUSED.
--                Record the exact error text. DO NOT RETRY BY ANY MEANS.
create event trigger r02_probe_event_trigger_v1
  on ddl_command_end
  when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function public.r02_probe_event_fn_v1();


-- ══ STEP 4 · VERIFY (SELECT only) ═══════════════════════════════════════════════════════════════
-- Purpose : if step 3 succeeded, capture exactly what was created.
-- Expect  : one row, evtname = r02_probe_event_trigger_v1, evtevent = ddl_command_end,
--           function_name = r02_probe_event_fn_v1.
select
  et.evtname,
  et.evtevent,
  et.evtenabled,
  et.evttags,
  pg_catalog.pg_get_userbyid(et.evtowner)  as owner,
  n.nspname                                as function_schema,
  p.proname                                as function_name
from pg_catalog.pg_event_trigger et
left join pg_catalog.pg_proc      p on p.oid = et.evtfoid
left join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where et.evtname = 'r02_probe_event_trigger_v1';


-- ══ STEP 5 · DROP THE DISPOSABLE EVENT TRIGGER ══════════════════════════════════════════════════
-- Skip only if step 3 failed (nothing was created).
drop event trigger if exists r02_probe_event_trigger_v1;


-- ══ STEP 6 · DROP THE DISPOSABLE FUNCTION ═══════════════════════════════════════════════════════
-- ★ RUN THIS EVEN IF STEP 3 FAILED. Local validation showed CREATE FUNCTION succeeds for a
--   non-superuser, so the function very likely exists even when the trigger does not.
drop function if exists public.r02_probe_event_fn_v1();


-- ══ STEP 7 · POST CHECK (SELECT only) ═══════════════════════════════════════════════════════════
-- Purpose : prove the environment is back to its PRE state.
-- Expect  : identical to STEP 1 — every column 0.
-- BLOCKER : any non-zero. Run the emergency cleanup below and re-check.
select
  (select count(*) from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'r02_probe_event_fn_v1')      as probe_function_present,
  (select count(*) from pg_catalog.pg_event_trigger
    where evtname = 'r02_probe_event_trigger_v1')                           as probe_trigger_present,
  (select count(*) from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'rls_auto_enable')            as canonical_function_present,
  (select count(*) from pg_catalog.pg_event_trigger
    where evtname = 'ensure_rls')                                           as canonical_trigger_present,
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_type = 'BASE TABLE')            as public_tables_present,
  (select count(*) from pg_catalog.pg_policies where schemaname = 'public')  as public_policies_present,
  (select count(*) from pg_catalog.pg_event_trigger)                         as total_event_triggers,
  (select count(*) from information_schema.tables
    where table_schema = 'supabase_migrations')                             as migration_metadata_objects;


-- ══ EMERGENCY CLEANUP (idempotent — safe to run at any point) ═══════════════════════════════════
-- drop event trigger if exists r02_probe_event_trigger_v1;
-- drop function if exists public.r02_probe_event_fn_v1();
