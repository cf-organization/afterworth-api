-- public.invitations — CAPTURED FROM LIVE 2026-07-09. LIVE IS AUTHORITATIVE.
--
-- Was live-only (its columns were previously only INFERRED from the RPCs that read it). Consume
-- path: invitation_preview (anon) / bind_invitation_token / accept_invitation / decline_invitation
-- / resolve_membership. There is NO create/revoke RPC yet (creation is manual SQL today — Slice 1).
--
-- HARD-RULE INVARIANT (upheld): the raw token is NEVER stored — only `token_hash` (a one-way
-- SHA-256 hex digest). The displayable `token_fingerprint` is DERIVED at read (substr(hash,1,12)),
-- not a column. Admin/list views must select the safe set (hints + status + fingerprint), NEVER
-- token_hash. Status is time-independent of expiry: `expired` is a stored status value AND a
-- read-time `expires_at < now()` derivation — filter BOTH in any listing.

create table if not exists public.invitations (
  id                    uuid        not null default uuid_generate_v4(),
  estate_id             uuid        not null,
  invited_by            uuid        not null,
  kind                  text        not null,
  proposed_role         text        not null,
  status                text        not null default 'pending',
  expires_at            timestamptz not null,
  invitee_email         text,
  invitee_phone         text,
  accepted_by           uuid,
  accepted_at           timestamptz,
  created_at            timestamptz default now(),
  updated_at            timestamptz default now(),
  token_hash            text        not null,   -- one-way SHA-256 hex; NEVER the raw token
  estate_display_name   text,
  inviter_display_name  text,
  invitee_email_hint    text,
  invitee_phone_hint    text,
  preview_visibility    jsonb       default '{}'::jsonb,
  constraint invitations_pkey primary key (id),
  constraint invitations_kind_check
    check (kind = any (array['beneficiary','professional_delegate','executor','trustee'])),
  constraint invitations_proposed_role_check
    check (proposed_role = any (array['beneficiary','professional_delegate'])),
  constraint invitations_status_check
    check (status = any (array['pending','matched','accepted','declined','expired','revoked'])),
  constraint invitations_estate_id_fkey
    foreign key (estate_id) references public.estates(id) on delete cascade,
  constraint invitations_invited_by_fkey
    foreign key (invited_by) references auth.users(id),
  constraint invitations_accepted_by_fkey
    foreign key (accepted_by) references auth.users(id)
);

create index if not exists invitations_estate_id_idx  on public.invitations using btree (estate_id);
create index if not exists invitations_status_idx     on public.invitations using btree (status);
create index if not exists invitations_token_hash_idx on public.invitations using btree (token_hash);
create index if not exists invitations_email_idx
  on public.invitations using btree (lower(invitee_email)) where (invitee_email is not null);
create index if not exists invitations_phone_idx
  on public.invitations using btree (invitee_phone) where (invitee_phone is not null);

-- RLS: enabled, not forced. DEFENSE-IN-DEPTH (no client-role grant — RPC-only). invitee_read is the
-- pre-accept "is this for me" gate (matches profiles.email/phone of auth.uid()); member/owner read +
-- owner_manage use the live-only is_estate_member / is_estate_owner helpers.
alter table public.invitations enable row level security;
drop policy if exists invitations_owner_manage on public.invitations;
create policy invitations_owner_manage on public.invitations
  for all using (public.is_estate_owner(estate_id)) with check (public.is_estate_owner(estate_id));
drop policy if exists invitations_member_read on public.invitations;
create policy invitations_member_read on public.invitations
  for select using (public.is_estate_member(estate_id));
drop policy if exists invitations_invitee_read on public.invitations;
create policy invitations_invitee_read on public.invitations
  for select using (
    status = any (array['pending','matched'])
    and expires_at > now()
    and (
      invitee_email = (select p.email from public.profiles p where p.id = auth.uid())
      or invitee_phone = (select p.phone from public.profiles p where p.id = auth.uid())
    )
  );

-- GRANTS (as intended): NO anon/authenticated/service_role grants — RPC-only. Only postgres (owner).
-- Post-0012 sweep: no TRUNCATE/REFERENCES/TRIGGER/MAINTAIN for the client roles.
