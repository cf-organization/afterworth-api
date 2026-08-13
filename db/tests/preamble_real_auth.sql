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
-- ★ `email` MODELLED SINCE PHASE 11-F. It is not decoration: `dispatch_owner_safety_notice` resolves
-- the owner's INDEPENDENTLY REACHABLE channel from `auth.users.email` — the address the account
-- authenticates with, which a claimant cannot repoint — and REFUSES the whole transition when it is
-- absent. Without the column the harness could not exercise either half of that: the dispatch that
-- succeeds, or the `owner_channel_unreachable` refusal that keeps an unreachable owner's estate at
-- `death_verified` where nothing can release.
create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text
);
alter table auth.users add column if not exists email text;

-- ★ THE REAL SHAPE. Supabase's `auth.uid()` reads the `sub` claim of the request JWT. Reading it from
-- the same GUC makes caller identity switchable per transaction, which is what lets one harness
-- exercise owner / non-owner / foreign-owner / anonymous against the SAME deployed logic.
create or replace function auth.uid() returns uuid
 language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

-- ★ `auth.jwt()` — ADDED IN PHASE 11-B, AND ITS ABSENCE WAS LOAD-BEARING.
--
-- `require_aal2()` reads `auth.jwt() ->> 'aal'`, and every financial RPC calls it. Without this
-- function the financial surfaces could not be loaded into the harness at all — which is exactly
-- what had happened: `get_estate_net_worth` was in no bundle and in no PARTS list, so TWO of the
-- seven release-condition evaluation sites had never executed in any test. A third,
-- `list_estate_assets`, was created by the estate bundle and called by no assertion.
--
-- Fail-closed the same way the real one does: an absent claim coalesces to aal1 in `require_aal2`,
-- so a harness caller is un-stepped-up unless a scenario says otherwise. That matters here — the
-- OWNER branch of `get_estate_net_worth` requires aal2 unconditionally, so a stand-in that returned
-- aal2 by default would quietly disable an MFA gate inside the suite that is supposed to prove it.
create or replace function auth.jwt() returns jsonb
 language sql stable
as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;

create table if not exists public.estates (
  id       uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  -- ★ `name`, NOT `display_name`. The WIRE calls it `estateDisplayName` (`resolve_membership`) and
  -- the COLUMN is `name`; a harness that spelled it the wire's way would let a function referencing
  -- the wrong column pass here and fail on the deployed schema, which is the same shape of miss as
  -- a stub that is "a different schema, not a smaller one".
  name     text not null default 'Fixture Estate',
  -- ★ ADDED IN PHASE 11-C. `required_verification_level` reads this; without the column the policy
  -- engine could not even be loaded — the exact shape of the 11-B `normalized_assets` finding, one
  -- table over. Nullable free text, like live: NULL is the common, fail-closed-to-maximum case.
  jurisdiction text
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
  -- ★ `title` IS NOT DECORATION HERE. The readiness projection reads it, and the first version of
  -- this stub omitted it — `column d.title does not exist`. A harness that is missing a column the
  -- code under test reads is not a smaller version of the schema, it is a different one.
  title       text not null default 'Fixture document',
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

-- =================================================================================================
-- PHASE 11-C DEPENDENCIES — audit persistence, the admin gate's table, and the verification-policy
-- schema. Real shapes, faithful to their migrations, because 11-C ASSERTS on all three.
-- =================================================================================================

-- ★ `audit_logs`, VERBATIM SHAPE FROM MIGRATION 0011 (+ the 0014 source widening). Until 11-C the
-- harness stubbed `write_audit` to a no-op because "audit persistence is not what any assertion is
-- about" — true then, false now: the 11-C suite asserts that every case mutation writes an audit
-- row with actor and estate attribution, and that a DENIED mutation writes no success row. A no-op
-- sink cannot answer either question.
create table if not exists public.audit_logs (
  id            bigserial primary key,
  actor_id      uuid references auth.users(id),
  estate_id     uuid,
  action        text not null,
  target_table  text,
  target_id     uuid,
  ip            inet,
  user_agent    text,
  metadata      jsonb default '{}'::jsonb,
  created_at    timestamptz default now()
);
alter table public.audit_logs add column if not exists source text not null default 'server';
alter table public.audit_logs drop constraint if exists audit_logs_source_check;
alter table public.audit_logs add constraint audit_logs_source_check
  check (source in ('server', 'ios_forward', 'admin'));
alter table public.audit_logs enable row level security;

-- ★ `admins`, VERBATIM SHAPE FROM MIGRATION 0014 — deny-all RLS, zero policies, zero grants; the
-- only reader is the DEFINER `is_admin()` (loaded from source by the suite, not copied here).
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id),
  created_at timestamptz not null default now(),
  note       text
);
alter table public.admins enable row level security;

-- ★ THE VERIFICATION-POLICY SCHEMA, VERBATIM SHAPES FROM MIGRATION 0026. The enum's DECLARATION
-- ORDER IS ITS RANK (attestation < kyc < enhanced_kyc) — `required_verification_level` leans on
-- native enum comparison, and 0052 types the case columns to the same enum so a second ladder
-- cannot exist to drift. The policy table ships EMPTY like live: "unmapped = maximum" is a CODE
-- invariant in the engine, not a seed row, and the 11-C suite proves the empty table answers
-- `enhanced_kyc`.
do $$ begin
  if not exists (select 1 from pg_type where typname = 'verification_level') then
    create type public.verification_level as enum ('attestation', 'kyc', 'enhanced_kyc');
  end if;
end $$;

create table if not exists public.jurisdiction_policy (
  jurisdiction        text        not null,
  floor_level         public.verification_level not null,
  is_counsel_approved boolean     not null default false,
  notes               text,
  updated_by          uuid        references auth.users(id),
  updated_at          timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  constraint jurisdiction_policy_pkey primary key (jurisdiction)
);
alter table public.jurisdiction_policy enable row level security;

-- ★ VERBATIM FROM db/functions/write_audit.sql — a REAL audit writer as of 11-C, not a stub. The
-- verifier's PREAMBLE_DISPOSITION holds this copy to the source file; if the deployed definition
-- changes, this harness must change in the same commit or it stops testing the thing it names.
create or replace function public.write_audit(
  p_action text,
  p_table  text,
  p_target uuid,
  p_estate uuid,
  p_meta   jsonb default '{}'::jsonb
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  insert into audit_logs(actor_id, estate_id, action, target_table, target_id, metadata)
  values (auth.uid(), p_estate, p_action, p_table, p_target, p_meta);
end $function$;

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
  status    text not null default 'approved',
  -- ★ PHASE 10-F — THE REAL SCHEMA HAS THIS, AND ITS ABSENCE HERE LET A TEST PROVE SOMETHING FALSE.
  --
  -- `db/tables/estate_memberships.sql` carries a RECON CORRECTION recorded when the table was
  -- captured from live: it HAS `unique (estate_id, user_id)`, and a user holds AT MOST ONE
  -- membership per estate. Several comments elsewhere in the codebase still repeat the older,
  -- contradicted belief that a user may hold multiple rows.
  --
  -- Without the constraint, this harness accepted a second membership row for one (estate, user) —
  -- and the Phase 10-D suite used exactly that to construct "an owner who ALSO holds an approved
  -- professional_delegate row", calling it "a reachable data state". It is not reachable: the
  -- database forbids it. The assertion was real, the refusal was real, and the STATE was fictional.
  --
  -- `provision_from_invitation` proves the constraint exists in production independently of the
  -- captured file: it uses `on conflict (estate_id, user_id)`, which Postgres rejects at runtime
  -- unless a matching unique constraint is present — and invitations are accepted in production.
  constraint estate_members_estate_id_user_id_key unique (estate_id, user_id),
  source_invitation_id uuid,
  approved_at          timestamptz,
  created_at           timestamptz not null default now()
);
alter table public.estate_memberships enable row level security;

-- ★ AND THE PARTIAL UNIQUE THAT MAKES "ONE OWNER PER ESTATE" A SCHEMA FACT rather than a convention.
create unique index if not exists estate_memberships_one_primary_user_per_estate
  on public.estate_memberships (estate_id)
  where role = 'primary_user' and status = 'approved';

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

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- ★ `normalized_assets` — ADDED IN PHASE 11-B, AND ITS ABSENCE HAD SILENCED TWO WHOLE SURFACES.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- This is the aggregator-sourced financial table (migration 0007) that `list_estate_assets` and
-- `get_estate_net_worth` read. The harness did not model it, with two consequences nothing reported:
--
--   · `get_estate_net_worth` could not be loaded at all, so the TWO release-condition evaluations
--     inside it had never executed in any test;
--   · `list_estate_assets` WAS created by the estate bundle, and calling it would have raised — so
--     no assertion ever did. Its two evaluations had never executed either.
--
-- Four of the seven copies of the release rule, unexercised, while the suite reported 160 passing
-- assertions. That is the "a green audit and an audit that inspects nothing are indistinguishable
-- from the outside" failure, in the one place Phase 11 is about to change.
--
-- ★ THE SHAPE IS THE REAL ONE, columns and defaults copied from 0007 rather than reduced to what the
-- current assertions happen to touch. A narrowed stand-in is how a function referencing a column
-- that exists in production passes here and fails there — the `name` vs `display_name` note above,
-- one table over. It is a TABLE, not a production function body, so no anti-shadow rule applies; the
-- rows in it are fixture data and belong to whichever suite creates them.
create table if not exists public.normalized_assets (
  id                  uuid primary key default gen_random_uuid(),
  estate_id           uuid not null references public.estates(id) on delete cascade,
  connection_id       uuid,
  institution_name    text,
  provider_name       text,
  asset_group         text not null,
  asset_category      text,
  asset_subtype       text,
  source_type         text not null default 'aggregator',
  masked_identifier   text,
  balance_cents       bigint not null default 0,
  currency            text not null default 'USD',
  holdings            jsonb not null default '[]'::jsonb,
  refresh_timestamp   timestamptz,
  last_sync_status    text not null default 'live_connected',
  confidence_level    text not null default 'high',
  verification_status text not null default 'verified',
  created_at          timestamptz not null default now()
);
alter table public.normalized_assets enable row level security;
-- Owner-only at the RLS layer, mirroring 0010. Both RPCs above are SECURITY DEFINER and bypass this;
-- it is here so a DIRECT select under `authenticated` is refused, which is what makes "the RPC is
-- the boundary" a testable claim rather than an assumption.
drop policy if exists normalized_assets_owner_all on public.normalized_assets;
create policy normalized_assets_owner_all on public.normalized_assets
  for all to authenticated
  using (public.is_estate_owner(estate_id))
  with check (public.is_estate_owner(estate_id));

-- ★ FIDUCIARY CAPACITY LIVES HERE AND NOWHERE ELSE. `get_professional_workspace` reads this table
-- directly, and `is_estate_executor` is the canonical predicate over it. A harness that omitted it
-- would let a function claiming "executor and trustee come only from designations" pass without any
-- designation ever existing — the assertion would be true and vacuous.
create table if not exists public.estate_designations (
  id               uuid primary key default gen_random_uuid(),
  estate_id        uuid not null references public.estates(id) on delete cascade,
  user_id          uuid not null references auth.users(id),
  designation_type text not null check (designation_type in ('executor','trustee')),
  status           text not null default 'active' check (status in ('active','revoked')),
  -- ★ 10-F: the columns and index `provision_from_invitation` writes through. Its
  -- `on conflict (estate_id, user_id, designation_type) where status = 'active'` needs a MATCHING
  -- partial unique index or Postgres refuses the statement outright.
  source_invitation_id uuid,
  granted_by           uuid
);
create unique index if not exists estate_designations_one_active
  on public.estate_designations (estate_id, user_id, designation_type)
  where status = 'active';
alter table public.estate_designations enable row level security;

create or replace function public.is_estate_executor(p_estate uuid, p_user uuid)
 returns boolean
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select exists (
    select 1 from public.estate_designations d
    where d.estate_id = p_estate
      and d.user_id    = p_user
      and d.designation_type in ('executor','trustee')
      and d.status = 'active'
  );
$function$;

-- ★ THE DELEGATE'S ONE REAL MUTATION LEAVES A ROW HERE, and the workspace reports its state back to
-- the caller who created it. Only the columns the projection reads are modelled.
create table if not exists public.access_requests (
  id                uuid primary key default gen_random_uuid(),
  estate_id         uuid not null references public.estates(id) on delete cascade,
  requester_user_id uuid not null,
  category          text not null check (category in ('estate_documents')),
  status            text not null default 'pending' check (status in ('pending','approved','denied')),
  created_at        timestamptz not null default now()
);
alter table public.access_requests enable row level security;

-- ★ PHASE 10-E — the columns the REAL request RPCs write. The workspace projection reads only
-- status and created_at, so the table above modelled only those; `create_access_request`,
-- `approve_access_request` and `deny_access_request` are now loaded from source and write the rest.
-- Added as separate ALTERs so the table definition above stays the shape the 10-D suite documents.
alter table public.access_requests add column if not exists requester_role     text;
alter table public.access_requests add column if not exists reason             text;
alter table public.access_requests add column if not exists resolved_at        timestamptz;
alter table public.access_requests add column if not exists resolved_by_user_id uuid;
alter table public.access_requests add column if not exists resulting_grant_id  uuid;

-- ★ THE ONE-PENDING INDEX IS LOAD-BEARING FOR A 10-E ASSERTION, not decoration. "A second request
-- emits nothing" is only a real test if the second request actually fails the way production does.
-- Without this index the duplicate would succeed and the assertion would pass by proving nothing.
create unique index if not exists access_requests_one_pending
  on public.access_requests (estate_id, requester_user_id, category)
  where status = 'pending';

-- `approve_access_request` stamps the approver. The 10-D suite never called that RPC, so the column
-- was never needed; 10-E does call it, for real, because "the requester and only the requester is
-- notified" is not a claim a hand-inserted grant row can support.
alter table public.access_grants add column if not exists approved_by_user_id uuid;

-- Same reasoning for grants: `create_asset_grant`'s 409 path, and therefore "a rejected grant emits
-- no notification", depend on these existing.
create unique index if not exists access_grants_one_active_category
  on public.access_grants (estate_id, grantee_user_id, category)
  where status = 'active' and category is not null;
create unique index if not exists access_grants_one_active_document
  on public.access_grants (estate_id, grantee_user_id, document_id)
  where status = 'active' and document_id is not null;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ THE REAL NOTIFICATIONS TABLE — because a stub here would make every 10-E assertion vacuous.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- This harness previously defined `emit_notification` as `begin return; end` — a no-op — on the
-- reasoning that "notification delivery is not the boundary under test". That was true until Phase
-- 10-E, at which point emission BECAME the boundary under test, and a suite asserting "the owner
-- receives exactly one notification" against a function that writes nothing would have passed with
-- every recipient check deleted.
--
-- The stub had also silently rotted: it took six parameters (`…, p_metadata jsonb`) while the real
-- function takes seven (`…, p_deep_link text, p_payload jsonb`) and the harness copy of
-- `create_asset_grant` called it with seven. No overload matched, the call raised, and the call
-- site's `exception when others then null` swallowed it. The notification path in this harness had
-- therefore been dead for as long as it existed, while looking exercised.
--
-- Shape and access model are migration 0009's, including the anti-forge posture: RLS self-scoped,
-- and NO insert grant to `authenticated` — so the suite can prove the DEFINER function is the only
-- writer rather than assuming it.
create table if not exists public.notifications (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  estate_id           uuid,
  kind                text not null,
  title               text not null,
  body                text,
  channel             text not null default 'inApp',
  action_deep_link    text,
  related_document_id uuid,
  payload             jsonb not null default '{}'::jsonb,
  read                boolean not null default false,
  created_at          timestamptz not null default now()
);
alter table public.notifications enable row level security;

drop policy if exists notifications_select_self on public.notifications;
create policy notifications_select_self on public.notifications
  for select to authenticated using (user_id = auth.uid());

drop policy if exists notifications_update_self on public.notifications;
create policy notifications_update_self on public.notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke insert, delete on public.notifications from authenticated;
grant select, update on public.notifications to authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ INVITATIONS — modelled so the invitation NOTIFICATION EMITTER can be exercised for real.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- Nine functions emit lifecycle notifications; without these two tables, two of them
-- (`accept_invitation`, `decline_invitation`) had no runtime assertion at all — their coverage was
-- the bundle's positive control that the event NAME appears in the source, which proves a string is
-- typed and nothing about who receives what.
--
-- `decline_invitation` is now genuinely exercised: it needs only these columns, and it is the one
-- that carries the idempotency question (already-declined is a successful no-op, so an emitter
-- placed above that guard would notify the owner on every repeat call).
--
-- `accept_invitation` remains uncovered here and is recorded as such rather than papered over: it
-- delegates to `provision_from_invitation`, which reconciles memberships and stamps
-- executor/trustee designations. Modelling that faithfully is a larger piece of harness than this
-- phase should invent, and a SHALLOW fake of it would be worse than the gap — it would report
-- coverage of a path that does not resemble production.
create table if not exists public.profiles (
  id    uuid primary key references auth.users(id),
  email text,
  phone text
);
alter table public.profiles enable row level security;

-- ★ PHASE 10-F — `beneficiaries` exists so `accept_invitation` can be exercised for real.
--
-- 10-E closed `decline_invitation` and left `accept_invitation` uncovered, recording the reason as
-- "it delegates to provision_from_invitation, which reconciles memberships and stamps designations;
-- modelling that faithfully is a larger harness than this phase should invent."
--
-- 10-F traced it instead of inheriting the estimate. `provision_from_invitation` touches exactly
-- four tables — `invitations`, `estate_memberships`, `estate_designations` and this one — and the
-- first three were already modelled. The gap was ONE table. The earlier estimate was honest and
-- wrong, which is a good reason to re-derive a deferral rather than carry it forward.
create table if not exists public.beneficiaries (
  id        uuid primary key default gen_random_uuid(),
  estate_id uuid not null references public.estates(id) on delete cascade,
  user_id   uuid,
  email     text,
  phone     text
);
alter table public.beneficiaries enable row level security;

create table if not exists public.invitations (
  id            uuid primary key default gen_random_uuid(),
  estate_id     uuid not null references public.estates(id) on delete cascade,
  invitee_email text,
  invitee_phone text,
  proposed_role text not null default 'beneficiary',
  -- `provision_from_invitation` stamps an executor/trustee designation when `kind` names one.
  kind          text,
  invited_by    uuid,
  status        text not null default 'pending'
                  check (status in ('pending','matched','accepted','declined','revoked')),
  accepted_by   uuid,
  accepted_at   timestamptz,
  expires_at    timestamptz not null default now() + interval '30 days',
  updated_at    timestamptz not null default now()
);
alter table public.invitations enable row level security;

create table if not exists public.claim_packets (
  id           uuid primary key default gen_random_uuid(),
  estate_id    uuid not null references public.estates(id) on delete cascade,
  requested_by uuid not null references auth.users(id),
  status       text not null default 'submitted'
                 check (status in ('submitted','under_review','approved','rejected','released')),
  submitted_at timestamptz default now(),
  -- ★ MIRRORS PRODUCTION. `db/tables/claim_packets.sql` (captured live) carries `decided_at`, and
  -- the harness omitted it — so a projection reading a real production column failed here while
  -- being perfectly correct against the deployed schema. A harness table narrower than production
  -- makes every test run against a schema nobody ships.
  -- KNOWN REMAINING DRIFT, deliberately not added because no suite-loaded routine reads them:
  -- death_certificate_doc_id, executor_id_doc_id, reviewer_id, review_notes. If a routine under
  -- test ever reads one, add it here in the same commit.
  decided_at   timestamptz
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

  -- ★ THE CANONICAL RELEASE PREDICATE (Phase 11-B) — was seven scattered copies, now one call.
  -- Since 11-D it consumes the AUTHORITATIVE lifecycle for THIS document's estate, resolved through
  -- the one sanctioned reader: `after_verified_death` opens exactly while the estate is
  -- death_verified. 'never', incapacity, the legacy fused value, identity and claim conditions stay
  -- dormant-deny (A.4), and an unknown condition or lifecycle refuses. No comparison happens here —
  -- the lifecycle is an ARGUMENT, and the policy stays in the predicate.
  return public.release_condition_satisfied(
    g.release_condition, g.approved_at, 'standard', public.estate_lifecycle_state(v_estate));
end;
$$;
-- ★ THE TWO BODIES ABOVE ARE HELD VERBATIM AGAINST `db/functions/` (Phase 11-B), and until this
-- phase they were held against NOTHING. `verifySqlAuthorization.mjs` resolved a production
-- counterpart by searching `db/functions/` only, so `can_access_document` and `document_grantable` —
-- whose sole definitions lived inside migrations 0004 and 0002 — resolved to null and were skipped
-- as "pure harness fixtures". The estate's document gate and its disclosure ceiling were exempt from
-- the drift guard written to catch exactly this. They happened to agree; nothing said so.
--
-- They stay HERE rather than arriving from a bundle for the `is_estate_owner` reason: the
-- `documents_read` policy below names `can_access_document`, and a policy cannot reference a
-- function that does not yet exist. `release_conditions_bundle.sql` re-creates both a few files
-- later with the same bytes, so the suite ends up exercising what an operator pastes.
--
-- The forward reference to `public.release_condition_satisfied` is safe: a plpgsql body is not
-- resolved at CREATE time, and the predicate is installed by the first bundle, long before any
-- assertion calls this gate. `db/tests/release_condition_authorization.sql` proves it resolved
-- rather than assuming it.

-- ★ THE BRACKET FUNCTIONS ARE NO LONGER COPIED HERE (10-F).
--
-- They used to be defined in this file AND inside `db/functions/list_estate_assets.sql`, and nothing
-- compared the two: the drift guard resolved a function to `db/functions/<name>.sql`, and these live
-- in a file named after something else. They are the ANTI-ORACLE mechanism — what stops a category
-- aggregate from republishing an exact value — so a silent divergence there would have meant the
-- suite proving its brackets were wide while production's were not.
--
-- `list_estate_assets.sql` is now part of the estate bundle, so the real definitions arrive with
-- everything else and this copy is redundant. The guard also searches by CONTENT now, so a future
-- copy would be caught rather than exempted.

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ THE HAND-COPIED `create_asset_grant` AND THE `emit_notification` STUB BOTH LIVED HERE. BOTH ARE
--   GONE, AND THE REASON IS THE SAME ONE.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- The removed copy was introduced as "extracted verbatim" so the discovery suite could assert that
-- `estate_inventory` is grantable THROUGH THE REAL DOOR rather than merely storable. The intent was
-- right; the mechanism was a second copy of a SECURITY DEFINER body, and a second copy of an
-- authorization gate is a thing that drifts. It did: Phase 10-E changed the real function's emission
-- and the harness would have gone on exercising the old one, green, forever.
--
-- `emit_notification` was stubbed to `begin return; end` because "notification delivery is not the
-- boundary under test". In Phase 10-E it IS the boundary, and a no-op writer would let "the owner
-- receives exactly one notification" pass with every recipient check deleted. Worse, the stub had
-- already rotted out of signature agreement with its only caller and had been raising-and-being-
-- swallowed for its whole life — exercised in appearance only.
--
-- Both now load from `db/functions/` through `db/bundles/lifecycle_notifications_bundle.sql`, and
-- `scripts/verifySqlAuthorization.mjs` REFUSES TO RUN if this preamble ever again defines a function
-- that also exists under `db/functions/`. That guard is the durable fix — this comment is only the
-- explanation.
--
-- `asset_category_grantable` keeps its placeholder below: it must exist before bodies that reference
-- it are created, and the estate bundle then REPLACES it with the real ceiling.
create or replace function public.asset_category_grantable(p_role text, p_category text, p_tier text)
returns boolean language sql immutable as $acg$ select false $acg$;

-- ★ REMOVE ANY LEGACY SIX-ARG STUB before the real seven-arg function is loaded. Postgres would keep
-- both as overloads, and a stub that still matched some call shape would silently win.
drop function if exists public.emit_notification(uuid, uuid, text, text, text, jsonb);


-- (The hand-copied `create_asset_grant` that stood here is deleted — see the note above. The real
--  body now arrives from db/functions/create_asset_grant.sql via the lifecycle bundle.)

