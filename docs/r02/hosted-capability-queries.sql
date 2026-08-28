-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- R-02 HOSTED CAPABILITY PREFLIGHT — READ-ONLY
--
-- RUN BY:   the user, manually, in the Supabase SQL Editor of the NON-PRODUCTION project only.
-- RUN BY AI: never. Nothing here has been executed against any project.
-- WRITES:   none. Every statement is a SELECT.
--
-- ★ DO NOT RUN AGAINST yiaavvkulrpqkkbqhwit. Despite its Supabase name ("afterworth-dev"), that is
--   the database the deployed application connects to (README.md pins its URL for Vercel). These
--   queries are read-only and would not damage it, but the preflight is meaningless there: R-02
--   needs a VIRGIN project, and that one is fully populated.
--
-- Answers, in order: who am I, what may I do, what is installed, what platform surface exists,
-- and what does the migration history table look like.
-- ════════════════════════════════════════════════════════════════════════════════════════════════


-- ── A · IDENTITY AND VERSION ────────────────────────────────────────────────────────────────────
select
  current_user                        as current_user,
  session_user                        as session_user,
  current_database()                  as current_database,
  version()                           as pg_version,
  current_setting('server_version_num') as server_version_num;


-- ── B · ROLE CAPABILITIES ───────────────────────────────────────────────────────────────────────
-- ★ THIS IS THE EVENT-TRIGGER QUESTION IN DISGUISE. CREATE EVENT TRIGGER conventionally requires
--   superuser. If rolsuper is false for the identity that will run the bootstrap, phase 120 cannot
--   be applied as written and needs its own adjudication — which is exactly what R-02 must learn
--   BEFORE attempting any mutation.
select
  r.rolname,
  r.rolsuper,
  r.rolcreatedb,
  r.rolcreaterole,
  r.rolbypassrls,
  r.rolcanlogin,
  r.rolreplication,
  array(select b.rolname from pg_auth_members m join pg_roles b on b.oid = m.roleid where m.member = r.oid) as member_of
from pg_catalog.pg_roles r
where r.rolname in (current_user, session_user, 'postgres', 'anon', 'authenticated', 'service_role', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin')
order by r.rolname;


-- ── C · EXTENSIONS: INSTALLED vs AVAILABLE ──────────────────────────────────────────────────────
-- Installed is what exists; available is what COULD be created. Model C phase 10 creates pgcrypto
-- and uuid-ossp; pg_stat_statements and supabase_vault are recorded as platform prerequisites.
select
  a.name,
  a.default_version                      as available_version,
  i.extversion                           as installed_version,
  (i.extname is not null)                as installed,
  n.nspname                              as installed_schema
from pg_catalog.pg_available_extensions a
left join pg_catalog.pg_extension i on i.extname = a.name
left join pg_catalog.pg_namespace n on n.oid = i.extnamespace
where a.name in ('pgcrypto', 'uuid-ossp', 'pg_stat_statements', 'supabase_vault', 'pg_graphql', 'pgjwt')
order by a.name;


-- ── D · EVENT-TRIGGER CONTEXT (inventory only — no creation attempted) ──────────────────────────
select
  et.evtname,
  et.evtevent,
  et.evtenabled,
  et.evttags,
  pg_catalog.pg_get_userbyid(et.evtowner) as owner,
  n.nspname                               as function_schema,
  p.proname                               as function_name
from pg_catalog.pg_event_trigger et
left join pg_catalog.pg_proc      p on p.oid = et.evtfoid
left join pg_catalog.pg_namespace n on n.oid = p.pronamespace
order by et.evtname;

-- Control: distinguishes "no event triggers" from "cannot read the catalog".
select count(*) as total_event_triggers, current_user as observed_as from pg_catalog.pg_event_trigger;


-- ── E · PLATFORM PREREQUISITES (exactly what 00_platform_contract.sql demands) ───────────────────
select
  to_regclass('auth.users')       is not null as auth_users,
  to_regclass('storage.objects')  is not null as storage_objects,
  to_regclass('storage.buckets')  is not null as storage_buckets,
  to_regprocedure('auth.uid()')   is not null as auth_uid,
  to_regprocedure('auth.jwt()')   is not null as auth_jwt,
  to_regnamespace('extensions')   is not null as extensions_schema,
  exists (select 1 from pg_roles where rolname = 'anon')          as role_anon,
  exists (select 1 from pg_roles where rolname = 'authenticated') as role_authenticated,
  exists (select 1 from pg_roles where rolname = 'service_role')  as role_service_role;


-- ── F · MIGRATION METADATA ──────────────────────────────────────────────────────────────────────
-- ★ READ ONLY. Nothing is seeded. Whether 0001-0060 should be recorded as applied is an open
--   adjudication (see docs/r02/README.md), and the answer depends on whether R-02 also adopts the
--   Supabase CLI's supabase/migrations/ layout — which AfterWorth has never used.
select
  to_regnamespace('supabase_migrations') is not null as schema_exists,
  to_regclass('supabase_migrations.schema_migrations') is not null as table_exists;

select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'supabase_migrations' and table_name = 'schema_migrations'
order by ordinal_position;

select version, name, statements is not null as has_statements
from supabase_migrations.schema_migrations
order by version;


-- ── G · VIRGINITY CHECK ─────────────────────────────────────────────────────────────────────────
-- A "virgin" target must have an empty public schema. If this is non-zero, the project is NOT a
-- clean R-02 target and the preflight must stop rather than adapt.
select
  (select count(*) from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE') as public_tables,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public')    as public_functions,
  (select count(*) from pg_policies where schemaname = 'public')                                              as public_policies;
