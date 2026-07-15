-- 0019_20260715_estate_designations — the executor/trustee DESIGNATION model (Slice R, commit #1).
--
-- Fiduciary CAPACITY (who may ACT for the estate) modeled as a DESIGNATION — distinct from
-- estate_memberships ROLE (access) and access_grants DISCLOSURE (per-resource). The membership role CHECK
-- STAYS primary_user/beneficiary/professional_delegate; an executor is a member (for access) PLUS an
-- estate_designations row. This reconciles the half-plumbed executor/trustee vocabulary that made the
-- encrypted_instructions executor-read policy structurally unreachable (corrected in 0020).
--
-- ADDITIVE: a new table + its own RLS + one helper. Zero existing policies change here. Grant-less by
-- design (the 0012 default-priv cure -> born clean; access is via SECURITY DEFINER RPCs -- is_estate_executor
-- now, the accept-provisioning unit next). FK rebuild order: needs estates, auth.users, invitations.

begin;

create table if not exists public.estate_designations (
  id                    uuid        not null default uuid_generate_v4(),
  estate_id             uuid        not null references public.estates(id)   on delete cascade,
  user_id               uuid        not null references auth.users(id)       on delete cascade,
  designation_type      text        not null check (designation_type in ('executor','trustee')),
  status                text        not null default 'active' check (status in ('active','revoked')),
  source_invitation_id  uuid        references public.invitations(id),
  granted_by            uuid        references auth.users(id),
  created_at            timestamptz not null default now(),
  revoked_at            timestamptz,
  constraint estate_designations_pkey primary key (id)
);

-- PARTIAL unique: AT MOST ONE active designation per (estate,user,type), while revoked rows COEXIST.
-- Rationale: a fiduciary designation is audit-sensitive; revoke-then-re-designate must PRESERVE the prior
-- (revoked) record rather than overwrite it -> an append-only history. Mirrors the existing
-- estate_memberships_one_primary_user_per_estate partial-unique precedent (Slice 0). A plain UNIQUE would
-- block re-designating a previously-revoked person.
create unique index if not exists estate_designations_one_active
  on public.estate_designations (estate_id, user_id, designation_type)
  where status = 'active';

-- "who is the executor of THIS estate" predicate (RLS + future claims).
create index if not exists estate_designations_estate_type_idx
  on public.estate_designations (estate_id, designation_type);
-- "what am I designated on".
create index if not exists estate_designations_user_idx
  on public.estate_designations (user_id);

alter table public.estate_designations enable row level security;

-- Owner of the estate manages its designations.
create policy estate_designations_owner_all on public.estate_designations
  for all using (public.is_estate_owner(estate_id)) with check (public.is_estate_owner(estate_id));

-- The designated user may read their own designation rows.
create policy estate_designations_designee_read on public.estate_designations
  for select using (user_id = auth.uid());

-- ------------------------------------------------------------------------------------------------------
-- is_estate_executor(p_estate, p_user) — the CANONICAL predicate: is p_user an ACTIVE executor/trustee
-- designee of p_estate? SECURITY DEFINER so it reads estate_designations regardless of the caller's grants
-- (the table is grant-less); STABLE; the boolean leaks nothing. Serves BOTH the encrypted_instructions RLS
-- (auth.uid()) and the future claims path (requested_by).
-- ------------------------------------------------------------------------------------------------------
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
revoke execute on function public.is_estate_executor(uuid, uuid) from public, anon;
grant  execute on function public.is_estate_executor(uuid, uuid) to authenticated;

commit;

-- NOTE: no GRANT to anon/authenticated on the TABLE (born clean under 0012). The RLS policies above are
-- defense-in-depth for a future grant; today's live gate is the DEFINER is_estate_executor helper + the
-- fact that no client role can reach the table directly. Verify born-clean with aclexplode (see the
-- Slice-R verification block).
