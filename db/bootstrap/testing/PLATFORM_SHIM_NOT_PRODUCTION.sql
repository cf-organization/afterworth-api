-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ███  LOCAL TEST SHIM — NOT PRODUCTION DDL — NEVER APPLY THIS TO A SUPABASE PROJECT  ███
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- This file fakes the SUPABASE-PLATFORM-OWNED surface so the canonical bootstrap can be executed
-- against a disposable vanilla Postgres container. Supabase creates all of this itself.
--
-- ★ IT IS DELIBERATELY IN A `testing/` SUBDIRECTORY WITH A SHOUTING FILENAME. The one thing that
--   must never happen to a current-state bootstrap is for a stand-in auth.users to be mistaken for
--   the real one and shipped. Nothing in db/bootstrap/*.sql references this file.
--
-- ★ A SUCCESSFUL RUN AGAINST THIS SHIM IS NOT HOSTED SUPABASE COMPATIBILITY. Vanilla Postgres
--   grants the bootstrap role superuser; hosted Supabase does not. CREATE EVENT TRIGGER in
--   particular succeeds here and may not succeed there. Local success does not clear
--   HOSTED_COMPATIBILITY_PROOF_REQUIRED.

create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then create role supabase_admin nologin; end if;
end $$;

create table if not exists auth.users (
  id uuid primary key default extensions.gen_random_uuid(),
  email text
);

-- Stand-ins. Real Supabase reads the JWT; these return NULL/empty, which is correct fail-closed
-- behaviour for a schema-shape test and deliberately useless for an authorization test.
create or replace function auth.uid() returns uuid language sql stable as $fn$ select null::uuid $fn$;
create or replace function auth.role() returns text language sql stable as $fn$ select 'authenticated'::text $fn$;
create or replace function auth.jwt() returns jsonb language sql stable as $fn$ select '{}'::jsonb $fn$;

create table if not exists storage.buckets (
  id text primary key,
  name text not null
);
create table if not exists storage.objects (
  id uuid primary key default extensions.gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid
);
alter table storage.objects enable row level security;

create or replace function storage.foldername(name text) returns text[]
  language sql immutable as $fn$ select string_to_array(name, '/') $fn$;

grant usage on schema auth, storage, extensions to anon, authenticated, service_role;
