-- db/migrations/0002_20260620_access_grants.sql
--
-- Access-grant model slice (the visibility-policy backend foundation under Vault).
-- Idempotent; safe to re-run on a DB reset.
--
-- DESIGN RECORD: docs/live-data-migration.md "Appendix A — Access-Grant Model" (iOS
-- repo). Read it before changing anything here; the decisions below are not
-- re-litigated in this file.
--
-- Captured here, in build order:
--   STEP 1 — documents.sensitivity column (5-level ladder, default 'sealed')
--   STEP 2 — access_grants table (scope-polymorphic: document_id XOR category) + indexes
--   STEP 3 — document_grantable() ceiling fn + write-time ceiling trigger
--   STEP 4 — access_grants RLS (owner-manages / grantee-reads-own)
--   STEP 5 — can_access_document() + documents_read rewrite (the row-level gate)
--
-- Captured in its own source-of-truth file (NOT duplicated here):
--   - GRANT select,insert,update on public.access_grants to authenticated -> db/grants.sql
--
-- SECURITY BOUNDARY (Appendix A.6): ROW visibility is enforced by RLS (HARD — cannot
-- be bypassed by the authed client). FIELD masking (title, derived fileName per
-- visibility_tier) is enforced by the ENDPOINT (SOFT — relies on /api/vault/documents
-- being the ONLY read path on public.documents for `authenticated`). True today; a
-- SECOND read path silently bypasses field masking unless it re-applies it. Row
-- visibility is safe regardless.

-- =============================================================================
-- STEP 1 — documents.sensitivity (5-level monotonic ladder)
-- =============================================================================
-- Default 'sealed' (owner-only until consciously reclassified DOWN). Safe-by-default
-- backstop: a grant-layer gap exposes nothing until each doc is deliberately made
-- grantable. Distinct from per-category ResourceSensitivity (low|medium|high|critical)
-- — DO NOT conflate. Split into add/backfill/default/not-null/constraint so re-running
-- is safe even if the column already exists without the CHECK.
alter table public.documents
  add column if not exists sensitivity text;

update public.documents set sensitivity = 'sealed' where sensitivity is null;

alter table public.documents alter column sensitivity set default 'sealed';
alter table public.documents alter column sensitivity set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'documents_sensitivity_check'
  ) then
    alter table public.documents
      add constraint documents_sensitivity_check
      check (sensitivity in ('low','medium','high','restricted','sealed'));
  end if;
end $$;

comment on column public.documents.sensitivity is
  'Document-sensitivity ceiling (5-level monotonic ladder), DISTINCT from per-category '
  'ResourceSensitivity. Default sealed = owner-only until reclassified down. '
  'low/medium/high grantable to beneficiary + professional_delegate; restricted '
  'excludes beneficiaries (professional-only); sealed excludes all non-owners (owner '
  'always inherent). low/medium/high are equally grantable today — informational only; '
  'real floors are restricted + sealed. See docs/live-data-migration.md Appendix A.3.';

-- =============================================================================
-- STEP 2 — access_grants (scope-polymorphic grant unit)
-- =============================================================================
-- Exactly one of document_id (per-document, Vault) XOR category (category-level,
-- everything else) is populated. Owner access is NEVER a grant row — owners are
-- inherent via is_ownership_role() membership; grants govern non-owners only.
create table if not exists public.access_grants (
  id                  uuid primary key default gen_random_uuid(),
  estate_id           uuid not null,                         -- RLS scoping (Pattern B)
  -- grantee_user_id: BARE uuid, NO FK (mirrors estate_memberships.user_id /
  -- beneficiaries.user_id = auth.uid()). MUST be stored LOWERCASE to match the live
  -- comparison format (Swift UUID.uuidString is UPPERCASE; Postgres/auth.uid() is
  -- lowercase). If the endpoint/RPC ever takes this id from a Swift UUID, .lowercased()
  -- at that boundary. (Same UUID-case discipline as the beneficiaries slice.)
  grantee_user_id     uuid not null,
  grantee_role        text not null
                        check (grantee_role in ('beneficiary','professional_delegate')),
  professional_type   text,                                  -- metadata only (A.2); meaningful when role=professional_delegate
  -- scope: exactly one of document_id / category is non-null (XOR below)
  document_id         uuid references public.documents(id) on delete cascade,
  -- category mirrors ProtectedDataCategory raw values (Vault slice only writes 'estate_documents').
  -- TODO: add full ProtectedDataCategory CHECK when the category (assets/tax/claims)
  -- path is exercised — an unconstrained text column lets a typo'd category silently
  -- never match (drift risk).
  category            text,
  visibility_tier     text not null
                        check (visibility_tier in
                          ('hidden','range_only','category_summary','limited_detail','full_detail')),
  release_condition   text not null
                        check (release_condition in
                          ('never','immediately','after_owner_approval','after_identity_verification',
                           'after_access_request_approval','after_verified_death_or_incapacity',
                           'after_claim_case_approval')),
  requires_step_up    boolean not null default false,
  status              text not null default 'active'
                        check (status in ('active','revoked')),
  granted_by_user_id  uuid not null,                         -- auth.uid() of the owner who created it (audit)
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  revoked_at          timestamptz,
  revoked_by_user_id  uuid,
  constraint access_grants_scope_xor
    check ((document_id is not null) <> (category is not null))  -- exactly one scope
);

comment on table public.access_grants is
  'Scope-polymorphic access grants for NON-OWNERS (beneficiary, professional_delegate). '
  'Owners are inherent via membership and have no grant row. document_id XOR category. '
  'See docs/live-data-migration.md Appendix A.';

-- One active grant per grantee per scope -> deterministic resolution (per-doc, category).
create unique index if not exists access_grants_uniq_doc
  on public.access_grants (estate_id, grantee_user_id, document_id)
  where document_id is not null and status = 'active';

create unique index if not exists access_grants_uniq_cat
  on public.access_grants (estate_id, grantee_user_id, category)
  where category is not null and status = 'active';

create index if not exists access_grants_lookup
  on public.access_grants (estate_id, grantee_user_id, status);

-- =============================================================================
-- STEP 3 — sensitivity ceiling: helper fn + write-time trigger
-- =============================================================================
-- Pure matrix function (A.3). Reused by the write-time trigger AND the read-time
-- re-check in can_access_document() (STEP 5).
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

-- Write-time guard: reject a PER-DOCUMENT grant that violates the ceiling. Category
-- grants span docs of varying sensitivity, so they are ceiling-checked only at read
-- (STEP 5), never here.
create or replace function public.enforce_grant_ceiling()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_sens text;
begin
  -- Only enforce for a grant that will be ACTIVE. A transition to 'revoked' must
  -- always succeed, even if the doc's sensitivity was raised above the ceiling after
  -- the grant was created — otherwise a sealed-reclassified doc could not be revoked.
  if new.status = 'active' and new.document_id is not null then
    select sensitivity into v_sens from public.documents where id = new.document_id;
    if not public.document_grantable(new.grantee_role, v_sens) then
      raise exception 'grant ceiling violation: % cannot be granted a % document',
        new.grantee_role, v_sens
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists access_grants_ceiling on public.access_grants;
create trigger access_grants_ceiling
  before insert or update on public.access_grants
  for each row execute function public.enforce_grant_ceiling();

-- =============================================================================
-- STEP 4 — access_grants RLS (owner-manages / grantee-reads-own)
-- =============================================================================
-- Mirrors beneficiaries_read care: owner sees all grants in the estate (Pattern B),
-- grantee sees ONLY their own grants, creator sees grants they made (belt-and-
-- suspenders). Writes are owner-scoped (is_estate_owner). NO delete policy — revoke
-- is a status change (audit rows retained). NOTE: self-grant prevention + category
-- validation are intentionally NOT enforced here; they move into the planned
-- create_document_grant() RPC (Appendix A.2).
alter table public.access_grants enable row level security;

drop policy if exists access_grants_read on public.access_grants;
create policy access_grants_read
  on public.access_grants
  for select
  to authenticated
  using (
    granted_by_user_id = auth.uid()
    or grantee_user_id = auth.uid()
    or public.is_estate_owner(estate_id)
  );

drop policy if exists access_grants_insert on public.access_grants;
create policy access_grants_insert
  on public.access_grants
  for insert
  to authenticated
  with check (
    public.is_estate_owner(estate_id)
    and granted_by_user_id = auth.uid()
  );

drop policy if exists access_grants_update on public.access_grants;
create policy access_grants_update
  on public.access_grants
  for update
  to authenticated
  using (public.is_estate_owner(estate_id))
  with check (public.is_estate_owner(estate_id));

-- =============================================================================
-- STEP 5 — documents row-level gate
-- =============================================================================
-- Encapsulates resolution (A.5): owner inherent -> per-document grant -> category
-- 'estate_documents' fallback -> default-deny. Re-applies the sensitivity ceiling
-- against the document's CURRENT sensitivity (authoritative — sensitivity can be
-- raised after a grant exists). SECURITY DEFINER so the inner reads bypass RLS (no
-- recursion); auth.uid() still resolves to the caller's JWT inside a definer fn.
--
-- SLICE 1: only release_condition='immediately' passes. 'never' and all signal-based
-- conditions (after_owner_approval / after_identity_verification /
-- after_verified_death_or_incapacity / ...) are DEFAULT-DENY until their signal
-- sources are built (Appendix A.4). The release_condition column EXPRESSES them now;
-- the gate just doesn't honor them yet.
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
  select grantee_role, visibility_tier, release_condition
    into g
  from public.access_grants
  where estate_id = v_estate
    and grantee_user_id = v_uid
    and status = 'active'
    and document_id = p_document_id
  limit 1;

  -- ...then category 'estate_documents' fallback.
  if not found then
    select grantee_role, visibility_tier, release_condition
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

  -- Ceiling re-check against the document's CURRENT sensitivity (A.3).
  if not public.document_grantable(g.grantee_role, v_sens) then
    return false;
  end if;

  if g.visibility_tier = 'hidden' then
    return false;
  end if;

  -- SLICE 1: signal-based + 'never' conditions stay dormant-deny (A.4).
  return g.release_condition = 'immediately';
end;
$$;

-- Rewrite documents_read: this TIGHTENS the prior over-broad policy
-- (was: owner_id = auth.uid() OR is_estate_member(estate_id) — which let ANY estate
-- member, including a beneficiary, read EVERY document row). Non-owners now see a
-- document only through a covering, released, ceiling-satisfied grant. Same spirit as
-- the beneficiaries_read fix.
drop policy if exists documents_read on public.documents;
create policy documents_read
  on public.documents
  for select
  to authenticated
  using (
    public.is_estate_owner(estate_id)
    or public.can_access_document(id)
  );
