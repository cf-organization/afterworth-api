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

-- =================================================================================================
-- PHASE 10 DEPENDENCIES — REAL authorization primitives, extracted verbatim from their source files
-- =================================================================================================
-- ★ EXTRACTED, NOT PARAPHRASED. These are the functions the discovery projection delegates its
-- decisions to, so a paraphrase here would mean the suite tests a boundary that is not the deployed
-- one. `verifySqlAuthorization.mjs` re-extracts them from source on every run and refuses to proceed
-- if this file has drifted.

create table if not exists public.estate_memberships (
  id        uuid primary key default gen_random_uuid(),
  estate_id uuid not null references public.estates(id) on delete cascade,
  user_id   uuid not null references auth.users(id),
  role      text not null,
  status    text not null default 'approved'
);
alter table public.estate_memberships enable row level security;

create table if not exists public.access_grants (
  id                  uuid primary key default gen_random_uuid(),
  estate_id           uuid not null,
  grantee_user_id     uuid not null,
  grantee_role        text not null check (grantee_role in ('beneficiary','professional_delegate')),
  professional_type   text,
  document_id         uuid references public.documents(id) on delete cascade,
  category            text,
  visibility_tier     text not null
                        check (visibility_tier in ('hidden','range_only','category_summary','limited_detail','full_detail')),
  release_condition   text not null
                        check (release_condition in
                          ('never','immediately','after_owner_approval','after_identity_verification',
                           'after_access_request_approval','after_verified_death_or_incapacity',
                           'after_claim_case_approval')),
  requires_step_up    boolean not null default false,
  status              text not null default 'active' check (status in ('active','revoked')),
  granted_by_user_id  uuid not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  approved_at         timestamptz,
  revoked_at          timestamptz,
  revoked_by_user_id  uuid,
  constraint access_grants_scope_xor
    check ((document_id is not null) <> (category is not null))
);
alter table public.access_grants enable row level security;

create table if not exists public.claim_packets (
  id           uuid primary key default gen_random_uuid(),
  estate_id    uuid not null references public.estates(id) on delete cascade,
  requested_by uuid not null references auth.users(id),
  status       text not null default 'submitted'
                 check (status in ('submitted','under_review','approved','rejected','released')),
  submitted_at timestamptz default now()
);
alter table public.claim_packets enable row level security;

create or replace function public.is_ownership_role(p_role text)
 returns boolean
 language sql
 immutable
 set search_path to 'public', 'extensions'
as $function$
  SELECT p_role IN ('primary_user');
$function$;

create or replace function public.is_estate_member(p_estate_id uuid)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select exists (
    select 1 from estate_memberships
    where estate_id = p_estate_id
      and user_id = auth.uid()
      and status = 'approved'
  )
$function$;

create or replace function public.document_grantable(p_role text, p_sensitivity text)
returns boolean
language sql
immutable
as $$
  select case
    when p_sensitivity = 'sealed'     then false
    when p_sensitivity = 'restricted' then p_role = 'professional_delegate'
    when p_sensitivity in ('low','medium','high')
                                      then p_role in ('beneficiary','professional_delegate')
    else false                                   -- unknown sensitivity -> deny
  end;
$$;



create or replace function public.can_access_document(p_document_id uuid)
returns boolean
language plpgsql
security definer
stable
set search_path to 'public'
as $$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_sens   text;
  g        record;
begin
  if v_uid is null then
    return false;
  end if;

  select estate_id, sensitivity into v_estate, v_sens
  from public.documents
  where id = p_document_id;

  if v_estate is null then
    return false;
  end if;

  -- Owner inherent (A.1) — no grant row needed.
  if public.is_estate_owner(v_estate) then
    return true;
  end if;

  -- Non-owner: per-document grant first...
  select grantee_role, visibility_tier, release_condition, approved_at
    into g
  from public.access_grants
  where estate_id = v_estate
    and grantee_user_id = v_uid
    and status = 'active'
    and document_id = p_document_id
  limit 1;

  -- ...then category 'estate_documents' fallback (the access-request grant lands here).
  if not found then
    select grantee_role, visibility_tier, release_condition, approved_at
      into g
    from public.access_grants
    where estate_id = v_estate
      and grantee_user_id = v_uid
      and status = 'active'
      and category = 'estate_documents'
    limit 1;
  end if;

  if not found then
    return false;                                            -- default-deny (A.5)
  end if;

  -- Ceiling re-check against the document's CURRENT sensitivity (A.3). For a CATEGORY
  -- grant this is the ONLY ceiling enforcement (the write-time trigger no-ops on category
  -- grants), so a sealed/restricted doc stays hidden here even with the category grant.
  if not public.document_grantable(g.grantee_role, v_sens) then
    return false;
  end if;

  if g.visibility_tier = 'hidden' then
    return false;
  end if;

  -- Active release conditions: 'immediately' always; the two approval-based conditions
  -- once approved_at is set. after_owner_approval (owner-initiated) and
  -- after_access_request_approval (beneficiary-initiated) are the SAME gate — both mean
  -- "owner approved the access", differing only by initiator. All other signal-based
  -- conditions and 'never' still default-deny (A.4).
  return g.release_condition = 'immediately'
      or (g.release_condition in ('after_owner_approval','after_access_request_approval')
          and g.approved_at is not null);
end;
$$;
create or replace function public.asset_bracket_low(p bigint) returns bigint language sql immutable as $$
  select case
    when p < 1000000    then 0             when p < 5000000    then 1000000
    when p < 10000000   then 5000000       when p < 25000000   then 10000000
    when p < 50000000   then 25000000      when p < 100000000  then 50000000
    when p < 500000000  then 100000000     when p < 1000000000 then 500000000
    else 1000000000 end;
$$;

create or replace function public.asset_bracket_high(p bigint) returns bigint language sql immutable as $$
  select case
    when p < 1000000    then 1000000       when p < 5000000    then 5000000
    when p < 10000000   then 10000000      when p < 25000000   then 25000000
    when p < 50000000   then 50000000      when p < 100000000  then 100000000
    when p < 500000000  then 500000000     when p < 1000000000 then 1000000000
    else null end;   -- top bracket ($10M+): open-ended
$$;

-- ★ THE REAL GRANT DOOR. The discovery suite asserts that `estate_inventory` can actually be granted
-- THROUGH THIS FUNCTION, not merely stored — a table CHECK widened without the door widened would be
-- a category that storage accepts and the only writer refuses. Extracted verbatim.
--
-- `asset_category_grantable` is referenced at runtime and is supplied by the bundle (0008/0049), so
-- the order below is fine; `emit_notification` is stubbed because notification delivery is not the
-- boundary under test.
create or replace function public.emit_notification(
  p_user uuid, p_estate uuid, p_kind text, p_title text, p_body text, p_metadata jsonb default '{}'::jsonb
) returns void language plpgsql as $emit$ begin return; end $emit$;

-- asset_category_grantable is created by the bundle; a placeholder is defined first so this function
-- body can be created before it. The bundle then REPLACES it with the real ceiling.
create or replace function public.asset_category_grantable(p_role text, p_category text, p_tier text)
returns boolean language sql immutable as $acg$ select false $acg$;

create or replace function public.create_asset_grant(
  p_estate_id uuid,
  p_grantee_user_id uuid,
  p_grantee_role text,
  p_category text,
  p_visibility_tier text,
  p_release_condition text,
  p_professional_type text default null,
  p_requires_step_up boolean default false
)
 returns setof public.access_grants
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid();
  v_id uuid;
begin
  -- Auth null-guard.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- SECURITY SPINE (privilege-escalation gate). DEFINER bypasses RLS, so this explicit owner-check
  -- IS the access boundary and MUST precede any insert.
  if not public.is_estate_owner(p_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- No grants to owners (self, or any ownership-role member) — inherent access.
  if p_grantee_user_id = v_user
     or exists (
       select 1 from public.estate_memberships m
       where m.estate_id = p_estate_id
         and m.user_id = p_grantee_user_id
         and public.is_ownership_role(m.role)
     ) then
    raise exception 'cannot grant access to an owner; owners have inherent access';  -- P0001 -> 400
  end if;

  -- Category must be a real ASSET category (defense-in-depth beyond the access_grants.category CHECK;
  -- the RPC is the security boundary and may be called directly).
  if p_category not in
     ('account_balances', 'institution_names', 'total_asset_value', 'linked_account_details') then
    raise exception 'invalid asset category: %', p_category;  -- P0001 -> 400
  end if;

  -- ★ WRITE-TIME CEILING — reject an over-ceiling grant before storing it (the trigger skips category
  --   grants). Mirrors the read-time clamp in list_estate_assets: e.g. beneficiary + account_balances
  --   + full_detail -> asset_category_grantable = false -> rejected here.
  if not public.asset_category_grantable(p_grantee_role, p_category, p_visibility_tier) then
    raise exception 'asset grant ceiling: role % cannot be granted tier % for category %',
      p_grantee_role, p_visibility_tier, p_category
      using errcode = '42501';   -- ceiling violation -> 403 (mirrors document_grantable)
  end if;

  -- Insert (category-scoped: document_id NULL). Table CHECKs + the one-active-grant-per-(estate,
  -- grantee,category) unique index fire regardless of the DEFINER context. Catch the unique
  -- violation and surface a readable 409 (fail, never silent upsert — a silent tier change on a
  -- disclosure grant is dangerous; a tier change is revoke + re-create).
  begin
    insert into public.access_grants
      (estate_id, grantee_user_id, grantee_role, professional_type,
       document_id, category, visibility_tier, release_condition,
       requires_step_up, granted_by_user_id)
    values
      (p_estate_id, p_grantee_user_id, p_grantee_role, p_professional_type,
       null, p_category, p_visibility_tier, p_release_condition,
       p_requires_step_up, v_user)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception
        'an active grant already exists for this category and grantee; revoke it first'
        using errcode = '23505';   -- unique_violation -> 409 Conflict
  end;

  perform public.write_audit(
    'access_grant.created',
    'access_grants',
    v_id,
    p_estate_id,
    jsonb_build_object(
      'grantee_user_id', p_grantee_user_id,
      'grantee_role', p_grantee_role,
      'category', p_category,
      'visibility_tier', p_visibility_tier,
      'release_condition', p_release_condition
    )
  );

  -- BEST-EFFORT emit: notify the grantee they were granted access. Wrapped so a notification failure
  -- NEVER fails the grant — the grant is load-bearing; the notification is a heads-up. The grantee is
  -- PARTY to this grant (they're the recipient), so there is no cross-user leak.
  begin
    perform public.emit_notification(
      p_grantee_user_id, p_estate_id, 'accessGranted',
      'Access granted',
      'You''ve been granted access to estate assets (' || p_category || ').',
      'afterworth://accounts',
      jsonb_build_object('kind', 'grant_created', 'grant_id', v_id, 'category', p_category)
    );
  exception when others then
    null;  -- swallow: a notification error must not roll back the grant
  end;

  return query select g.* from public.access_grants g where g.id = v_id;
end;
$function$;

