-- public.estate_designations — CAPTURED FROM LIVE 2026-07-15. LIVE IS AUTHORITATIVE.
--
-- Created by migration 0019 (Slice R). The executor/trustee DESIGNATION model — fiduciary CAPACITY (who may
-- ACT for the estate), distinct from estate_memberships ROLE (access) and access_grants DISCLOSURE
-- (per-resource). Born-clean VERIFIED LIVE (aclexplode: no anon/authenticated/service_role grants). Access
-- is via the DEFINER is_estate_executor helper (db/functions/is_estate_executor.sql) + future RPCs; the RLS
-- policies below are defense-in-depth for a future grant. FK rebuild order: needs estates, auth.users,
-- invitations.

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

-- AT MOST ONE active designation per (estate,user,type); revoked rows COEXIST (append-only fiduciary
-- history — verified live: dup active REJECTED, revoked+new active COEXIST). Mirrors the
-- estate_memberships_one_primary_user_per_estate partial-unique precedent.
create unique index if not exists estate_designations_one_active
  on public.estate_designations (estate_id, user_id, designation_type) where status = 'active';
create index if not exists estate_designations_estate_type_idx
  on public.estate_designations (estate_id, designation_type);
create index if not exists estate_designations_user_idx
  on public.estate_designations (user_id);

alter table public.estate_designations enable row level security;

-- Owner of the estate manages its designations.
create policy estate_designations_owner_all on public.estate_designations
  for all using (public.is_estate_owner(estate_id)) with check (public.is_estate_owner(estate_id));
-- The designated user may read their own designation rows.
create policy estate_designations_designee_read on public.estate_designations
  for select using (user_id = auth.uid());

-- NOTE: no client GRANTS (born clean, verified live). The RLS policies above are latent until a grant/RPC
-- read path is added; today's live gate is the DEFINER is_estate_executor helper.
