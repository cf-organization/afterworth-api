-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- R-02 · READ-ONLY HOSTED CAPABILITY CHECK
--
-- TARGET PROJECT : afterworth-nonprod
-- TARGET REF     : qxzeougbaarecaiiqsay
-- TARGET REGION  : us-west-2 (West US, Oregon)
--
-- RUN BY   : the operator, manually, in THAT project's Supabase SQL Editor.
-- RUN BY AI: never. Nothing here has been executed.
-- WRITES   : none. Every statement is a SELECT over pg_catalog / information_schema.
--
-- ★ NEVER RUN AGAINST yiaavvkulrpqkkbqhwit (application-facing) OR rpjjwkoezuihpobotbjh (paused,
--   retained). Read-only SQL is harmless there, but evidence labelled for the wrong project is
--   worse than no evidence.
--
-- ★ IDENTITY IS ALREADY ESTABLISHED (R02_2) and is NOT repeated here. This pack asks only what the
--   session is ALLOWED to do and what the project already contains.
--
-- ★ NOTHING HERE CREATES ANYTHING. Extension availability is read from pg_available_extensions;
--   event triggers are read from pg_event_trigger. No CREATE EXTENSION, no CREATE EVENT TRIGGER.
--   Whether those would SUCCEED is a separate, separately-authorized question — inspecting the
--   role's attributes tells us what to expect, not what happened.
--
-- Run each query separately: the Supabase SQL Editor shows only the last statement's result.
-- ════════════════════════════════════════════════════════════════════════════════════════════════


-- ── Q1 · EXECUTION ROLE CAPABILITIES ────────────────────────────────────────────────────────────
-- Purpose : what the bootstrap identity may do. rolsuper is the CREATE EVENT TRIGGER question.
-- Expect  : one row per named role that exists; current_user should be present.
-- Zero rows: would be a blocker — it would mean the catalog is unreadable.
select
  r.rolname,
  (r.rolname = current_user)                        as is_current_user,
  r.rolsuper,
  r.rolcreaterole,
  r.rolcreatedb,
  r.rolcanlogin,
  r.rolreplication,
  r.rolbypassrls,
  array(select b.rolname
          from pg_catalog.pg_auth_members m
          join pg_catalog.pg_roles b on b.oid = m.roleid
         where m.member = r.oid
         order by b.rolname)                        as member_of
from pg_catalog.pg_roles r
where r.rolname in (current_user, session_user, 'postgres', 'anon', 'authenticated',
                    'service_role', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin')
order by r.rolname;


-- ── Q2 · EXTENSIONS: INSTALLED vs AVAILABLE ─────────────────────────────────────────────────────
-- Purpose : can Model C phase 10 create pgcrypto and uuid-ossp; are the platform ones present.
-- Expect  : four rows. installed=false for some is normal on a fresh project.
-- Blocker : pgcrypto or uuid-ossp missing from AVAILABLE entirely.
select
  a.name,
  a.default_version                                 as available_version,
  i.extversion                                      as installed_version,
  (i.extname is not null)                           as installed,
  n.nspname                                         as installed_schema
from pg_catalog.pg_available_extensions a
left join pg_catalog.pg_extension i on i.extname = a.name
left join pg_catalog.pg_namespace n on n.oid = i.extnamespace
where a.name in ('pgcrypto', 'uuid-ossp', 'pg_stat_statements', 'supabase_vault')
order by a.name;


-- ── Q3 · EVENT TRIGGERS — PLATFORM vs APPLICATION ───────────────────────────────────────────────
-- Purpose : inventory what already exists, separated by owner.
-- Expect  : Supabase's own platform triggers (owner supabase_admin). ZERO application triggers is
--           the EXPECTED and DESIRED result — automatic RLS was deliberately left disabled at
--           project creation, and Model C has not run.
-- Blocker : an application-owned trigger named ensure_rls already present would mean the project is
--           not virgin for this purpose.
select
  et.evtname,
  et.evtevent,
  et.evtenabled,
  et.evttags,
  pg_catalog.pg_get_userbyid(et.evtowner)           as owner,
  case when pg_catalog.pg_get_userbyid(et.evtowner) = 'supabase_admin'
       then 'PLATFORM' else 'NON_PLATFORM' end      as owner_class,
  n.nspname                                         as function_schema,
  p.proname                                         as function_name
from pg_catalog.pg_event_trigger et
left join pg_catalog.pg_proc      p on p.oid = et.evtfoid
left join pg_catalog.pg_namespace n on n.oid = p.pronamespace
order by et.evtname;


-- ── Q4 · THE APPLICATION AUTO-RLS BINDING, ASKED DIRECTLY ───────────────────────────────────────
-- Purpose : distinguish (a) platform triggers, (b) an ensure_rls binding, (c) the rls_auto_enable
--           function — three different things that must not be conflated.
-- Expect  : all three counts ZERO on a fresh project with automatic RLS left disabled.
-- Blocker : non-zero for ensure_rls or rls_auto_enable before Model C has run.
select
  (select count(*) from pg_catalog.pg_event_trigger)                                        as total_event_triggers,
  (select count(*) from pg_catalog.pg_event_trigger
     where pg_catalog.pg_get_userbyid(evtowner) = 'supabase_admin')                         as platform_owned,
  (select count(*) from pg_catalog.pg_event_trigger where evtname = 'ensure_rls')           as ensure_rls_binding,
  (select count(*) from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'rls_auto_enable')                           as rls_auto_enable_function;


-- ── Q5 · PLATFORM CONTRACT (existence only — no rows are read) ──────────────────────────────────
-- Purpose : exactly what db/bootstrap/00_platform_contract.sql demands before it will proceed.
-- Expect  : every column true.
-- Blocker : any false — the bootstrap would refuse.
select
  to_regclass('auth.users')                is not null as auth_users,
  to_regclass('storage.objects')           is not null as storage_objects,
  to_regclass('storage.buckets')           is not null as storage_buckets,
  to_regprocedure('auth.uid()')            is not null as auth_uid,
  to_regprocedure('auth.jwt()')            is not null as auth_jwt,
  to_regnamespace('extensions')            is not null as extensions_schema,
  exists (select 1 from pg_catalog.pg_roles where rolname = 'anon')          as role_anon,
  exists (select 1 from pg_catalog.pg_roles where rolname = 'authenticated') as role_authenticated,
  exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role')  as role_service_role;


-- ── Q6 · MIGRATION METADATA (read-only; nothing is seeded) ──────────────────────────────────────
-- Purpose : does the CLI's history table exist, and does it hold anything.
-- Expect  : schema may or may not exist on a fresh project; row count 0 if it does.
-- Blocker : none by itself. AfterWorth has NOT adopted the CLI migration workflow, so this table is
--           informational only and MUST NOT be written to.
select
  to_regnamespace('supabase_migrations')                       is not null as schema_exists,
  to_regclass('supabase_migrations.schema_migrations')         is not null as table_exists,
  (select count(*) from pg_catalog.pg_class c
     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'supabase_migrations')                              as objects_in_schema;


-- ── Q7 · VIRGINITY — AFTERWORTH-SPECIFIC, NOT "public must be empty" ────────────────────────────
-- Purpose : does this project already contain AfterWorth application state?
-- ★ A FRESH SUPABASE PROJECT IS NOT AN EMPTY POSTGRES SERVER. Supabase creates platform schemas and
--   objects of its own, so asserting public = 0 objects would be wrong and would fail on a perfectly
--   good target. The real question is whether any of the 41 Model C application tables already
--   exists.
-- Expect  : afterworth_tables_present = 0.
-- Blocker : any non-zero value — HALT capability adjudication and report it.
select
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_type = 'BASE TABLE'
      and table_name in ('access_grants', 'access_requests', 'admins', 'assets', 'audit_logs', 'beneficiaries', 'claim_packets', 'connection_secrets', 'connections', 'consent_records', 'death_verification_cases', 'death_verification_evidence', 'document_sensitivity', 'document_subtype', 'document_type', 'documents', 'encrypted_instructions', 'estate_asset_category', 'estate_asset_documents', 'estate_asset_subtype', 'estate_assets', 'estate_designations', 'estate_lifecycle', 'estate_memberships', 'estates', 'invitation_delivery_outbox', 'invitations', 'jurisdiction_policy', 'legal_holds', 'mfa_recovery_attempts', 'normalized_assets', 'notifications', 'outbox_purge_audit', 'owner_notice_outbox', 'profiles', 'recovery_codes', 'release_authorizations', 'release_safety_policy', 'storage_deletion_outbox', 'taxonomy_version', 'upload_policy'))                                          as afterworth_tables_present,
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_type = 'BASE TABLE')            as total_public_tables,
  (select count(*) from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public')                                            as total_public_functions,
  (select count(*) from pg_catalog.pg_policies where schemaname = 'public') as total_public_policies,
  (select coalesce(string_agg(table_name, ', ' order by table_name), '(none)')
     from information_schema.tables
    where table_schema = 'public' and table_type = 'BASE TABLE')            as public_table_names;


-- ── Q8 · STORAGE METADATA (no object rows are read) ─────────────────────────────────────────────
-- Purpose : storage.objects/buckets exist, their RLS state, and whether AfterWorth's two
--           application-owned storage policies already exist.
-- Expect  : both tables present; afterworth_storage_policies = 0 before Model C.
-- Blocker : afterworth_storage_policies non-zero before bootstrap.
select
  c.relname                                          as table_name,
  c.relrowsecurity                                   as rls_enabled,
  c.relforcerowsecurity                              as rls_forced,
  (select count(*) from pg_catalog.pg_policies pp
    where pp.schemaname = 'storage' and pp.tablename = c.relname)          as policies_on_table,
  (select count(*) from pg_catalog.pg_policies pp
    where pp.schemaname = 'storage'
      and pp.policyname in ('documents_estate_read', 'documents_estate_insert'))
                                                                            as afterworth_storage_policies
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'storage' and c.relname in ('objects', 'buckets')
order by c.relname;
