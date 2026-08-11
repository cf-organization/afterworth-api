-- db/tests/preamble_real_auth.sql
--
-- Dependency stand-ins for the SQL AUTHORIZATION harness.
--
-- ★ THE DIFFERENCE FROM THE EARLIER SCRATCH PREAMBLE IS THE WHOLE POINT. That one stubbed
-- `is_estate_owner()` to `true`, which proved only that each RPC *calls* the gate — it could not
-- prove the gate REFUSES anyone, because nothing was ever refused. Every "owner-gated" claim rested
-- on a function that returned true for the world.
--
-- This file installs the REAL `is_estate_owner` verbatim from `db/functions/is_estate_owner.sql`, and
-- a real `auth.uid()` that reads the JWT `sub` claim exactly as Supabase's does. Caller identity is
-- therefore switchable, and a non-owner is genuinely a non-owner.
--
-- ★ RLS ONLY APPLIES TO A NON-SUPERUSER. Postgres bypasses row security for the table owner, so a
-- harness that stays `postgres` measures nothing about a policy. Every scenario runs under
-- `SET ROLE authenticated` — the role PostgREST actually assumes — which is what makes an RLS
-- assertion mean something.
--
-- Everything below that is NOT an authorization primitive (audit sink, taxonomy counter) is a stub,
-- and is stubbed because it is not the boundary under test.

create extension if not exists pgcrypto;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;

create schema if not exists auth;
create table if not exists auth.users (id uuid primary key default gen_random_uuid());

-- ★ THE REAL SHAPE. Supabase's `auth.uid()` reads the `sub` claim of the request JWT. Reading it from
-- the same GUC makes caller identity switchable per transaction, which is what lets one harness
-- exercise owner / non-owner / foreign-owner / anonymous against the SAME deployed logic.
create or replace function auth.uid() returns uuid
 language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create table if not exists public.estates (
  id       uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id)
);
alter table public.estates enable row level security;

-- ★ VERBATIM FROM db/functions/is_estate_owner.sql — NOT a stub, NOT a paraphrase. If the deployed
-- definition changes, this harness must be updated in the same commit or it stops testing the thing
-- it names. `authorizationHarness.test.ts` asserts the two bodies still agree.
create or replace function public.is_estate_owner(p_estate_id uuid)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select exists (
    select 1 from estates
    where id = p_estate_id and owner_id = auth.uid()
  )
$function$;


create table if not exists public.document_sensitivity (
  value        text primary key,
  display_name text not null,
  is_active    boolean not null default true
);
insert into public.document_sensitivity (value, display_name) values
  ('low','Low'),('medium','Medium'),('high','High'),('restricted','Restricted'),('sealed','Sealed')
on conflict (value) do nothing;

create table if not exists public.documents (
  id          uuid primary key default gen_random_uuid(),
  estate_id   uuid not null references public.estates(id) on delete cascade,
  sensitivity text not null default 'sealed' references public.document_sensitivity(value)
);
alter table public.documents enable row level security;
drop policy if exists documents_read on public.documents;
create policy documents_read on public.documents
  for select to authenticated using (public.is_estate_owner(estate_id));
grant select on public.documents to authenticated;

create table if not exists public.taxonomy_version (
  id                 int primary key,
  schema_version     int not null default 1,
  vocabulary_version int not null default 1,
  updated_at         timestamptz not null default now()
);
insert into public.taxonomy_version (id) values (1) on conflict (id) do nothing;

-- Not the boundary under test: an audit sink that records and returns.
create or replace function public.write_audit(
  p_action text, p_entity text, p_entity_id uuid, p_estate uuid, p_metadata jsonb
) returns void language plpgsql as $$ begin return; end $$;

create or replace function public.bump_taxonomy_vocabulary_version()
returns trigger language plpgsql as $$
begin
  update public.taxonomy_version set vocabulary_version = vocabulary_version + 1 where id = 1;
  return null;
end $$;
