-- public.estates — CAPTURED FROM LIVE 2026-07-09. LIVE IS AUTHORITATIVE.
--
-- Was live-only. Pattern-B root: an estate has ONE owner (owner_id) + memberships in
-- estate_memberships. `is_primary` marks the owner's own estate. FK rebuild order: needs
-- auth.users; estate_memberships/invitations reference this table, so create estates first.

create table if not exists public.estates (
  id           uuid        not null default uuid_generate_v4(),
  owner_id     uuid        not null,
  name         text        not null,
  description  text,
  jurisdiction text,
  status       text        not null default 'active',
  created_at   timestamptz default now(),
  updated_at   timestamptz default now(),
  is_primary   boolean     not null default false,
  constraint estates_pkey primary key (id),
  constraint estates_status_check
    check (status = any (array['active','locked','archived','in_claim'])),
  constraint estates_owner_id_fkey
    foreign key (owner_id) references auth.users(id) on delete cascade
);

create index if not exists estates_owner_id_idx on public.estates using btree (owner_id);
-- one PRIMARY estate per owner (partial unique)
create unique index if not exists estates_primary_per_owner_idx
  on public.estates using btree (owner_id) where (is_primary = true);

-- RLS: enabled, not forced. Policies are DEFENSE-IN-DEPTH (no client-role grant — RPC-only access
-- via resolve_membership DEFINER). estates_member_read calls public.is_estate_member(id) — a
-- LIVE-ONLY helper NOT yet captured in db/functions/ (referenced here + by invitations policies);
-- capture it in a follow-up (same invisible-object class).
alter table public.estates enable row level security;
drop policy if exists estates_owner_all on public.estates;
create policy estates_owner_all on public.estates
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists estates_member_read on public.estates;
create policy estates_member_read on public.estates
  for select using (public.is_estate_member(id));

-- Trigger: estates_ensure_primary_user_membership AFTER INSERT ->
--   public.ensure_primary_user_membership()  (see db/functions/ensure_primary_user_membership.sql)
--   auto-provisions the owner's primary_user membership on estate creation.

-- GRANTS (as intended): NO anon/authenticated/service_role grants — RPC-only. Only postgres (owner).
-- Post-0012 sweep: no TRUNCATE/REFERENCES/TRIGGER/MAINTAIN for the client roles.
