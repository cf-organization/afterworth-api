-- public.estate_memberships — CAPTURED FROM LIVE 2026-07-09. LIVE IS AUTHORITATIVE.
--
-- Was live-only (no CREATE TABLE in version control — the handle_new_user/audit_logs invisible-
-- object class). This file is the VC record; re-apply on a DB reset. Pattern-B pivot: ALL estate
-- access flows through this table (never estates.owner_id directly). Legacy object names are
-- `estate_members_*` (the table was renamed to estate_memberships; constraint/index names kept).
--
-- ★ RECON CORRECTION (load-bearing): this table HAS `UNIQUE (estate_id, user_id)`
--   (estate_members_estate_id_user_id_key) AND a partial-unique index
--   estate_memberships_one_primary_user_per_estate (estate_id WHERE role='primary_user' AND
--   status='approved'). The admin-recon + the CLAUDE.md invariant claim "estate_memberships has NO
--   (estate,user) uniqueness / a user may hold MULTIPLE approved rows per estate" — that is
--   CONTRADICTED BY LIVE. A user holds AT MOST ONE membership per estate, and an estate has AT MOST
--   ONE approved primary_user. The multi-membership "filter role in WHERE, never LIMIT-1" concern is
--   moot for (estate,user) lookups (there is only one row). Correct the CLAUDE.md invariant.
--
-- FK rebuild order: profiles/auth.users, estates, invitations must exist first (this table FKs all).

create table if not exists public.estate_memberships (
  id                    uuid        not null default uuid_generate_v4(),
  estate_id             uuid        not null,
  user_id               uuid        not null,
  role                  text        not null,
  status                text        not null default 'pending',
  invited_by            uuid,
  approved_at           timestamptz,
  created_at            timestamptz default now(),
  source_invitation_id  uuid,
  constraint estate_members_pkey primary key (id),
  constraint estate_members_estate_id_user_id_key unique (estate_id, user_id),
  constraint estate_memberships_role_check
    check (role = any (array['primary_user','beneficiary','professional_delegate'])),
  constraint estate_memberships_status_check
    check (status = any (array['pending','approved','revoked','expired'])),
  constraint estate_members_estate_id_fkey
    foreign key (estate_id) references public.estates(id) on delete cascade,
  constraint estate_members_user_id_fkey
    foreign key (user_id) references auth.users(id) on delete cascade,
  constraint estate_members_invited_by_fkey
    foreign key (invited_by) references auth.users(id),
  constraint estate_memberships_source_invitation_id_fkey
    foreign key (source_invitation_id) references public.invitations(id) on delete set null
);

create index if not exists estate_members_estate_id_idx on public.estate_memberships using btree (estate_id);
create index if not exists estate_members_user_id_idx   on public.estate_memberships using btree (user_id);
create unique index if not exists estate_memberships_one_primary_user_per_estate
  on public.estate_memberships using btree (estate_id) where (role = 'primary_user' and status = 'approved');
create index if not exists estate_memberships_source_invitation_idx
  on public.estate_memberships using btree (source_invitation_id) where (source_invitation_id is not null);

-- RLS: enabled, not forced. Policies below are DEFENSE-IN-DEPTH — there is NO client-role table
-- grant (see grants note), so client access is RPC-only (resolve_membership / list_estate_members
-- DEFINER); the policies would apply only if a SELECT grant were ever added.
alter table public.estate_memberships enable row level security;
drop policy if exists members_owner_manage on public.estate_memberships;
create policy members_owner_manage on public.estate_memberships
  for all using (public.is_estate_owner(estate_id)) with check (public.is_estate_owner(estate_id));
drop policy if exists members_self_read on public.estate_memberships;
create policy members_self_read on public.estate_memberships
  for select using (user_id = auth.uid());

-- Trigger: estate_memberships_check_primary_user BEFORE INSERT OR UPDATE ->
--   public.check_primary_user_matches_owner()  (see db/functions/check_primary_user_matches_owner.sql)

-- GRANTS (as intended): NO anon/authenticated/service_role grants — RPC-only (emails stay RPC-gated;
-- see db/grants.sql). Only the owner role (postgres) holds grants. Post-0012 sweep: no TRUNCATE/
-- REFERENCES/TRIGGER/MAINTAIN for the client roles.
