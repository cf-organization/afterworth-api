-- 0042_20260731_owner_invitation_management — owner-facing invitation list / create / revoke /
-- extend / redelivery, plus the delivery outbox that lets creation happen WITHOUT ever handing a
-- raw token to a client.
--
-- WHY THIS EXISTS. 0016 gave the operator console create/revoke/extend, but a customer-facing
-- owner has no way to LIST their invitations (there is no client grant on public.invitations and
-- admin_list_invitations is admin-gated). Without a list, revoke and extend take an id the owner
-- cannot obtain — an owner could create estate access they can never withdraw. This closes that.
--
-- THREE INVARIANTS THIS MIGRATION IS BUILT AROUND:
--
--   1. RAW TOKENS NEVER REACH A CLIENT, AND NEVER REST IN PLAINTEXT. create stores the hash of a
--      DISCARDED value, so a freshly created invitation is not yet usable. The real secret is
--      minted at DELIVERY time by issue_invitation_delivery(), granted to service_role ONLY, and
--      returned to that trusted caller transiently. The outbox carries no secret at all.
--      (No pgsodium/Vault exists in this project, so encrypting a secret at rest is not an option.)
--
--   2. PLATFORM ADMIN IS NOT AN ESTATE OWNER HERE. The 0016 gate is `owner OR admin`, which is
--      right for the console. These are CONSUMER functions, so they use is_estate_owner ALONE —
--      admin status must not silently confer authority over a customer's estate through a phone.
--
--   3. NOTHING CLAIMS DELIVERY. delivery_state ∈ (none, queued, issued, failed). There is no
--      `delivered`, because no subsystem can confirm it. SQL cannot send mail; a worker must be
--      deployed before any invitation reaches anyone.
--
-- Additive and backward-compatible: no existing function is altered, no response shape consumed by
-- the operator console or the pending mobile recipient work changes, and no client grant is added
-- to public.invitations.

begin;

-- ============================================================================================
-- 1 · Lifecycle columns the owner surface needs
-- ============================================================================================
-- Deliberately NOT added: delivered_at / opened_at / viewed_at. Nothing can confirm them, and a
-- column that cannot be kept truthful becomes a lie the UI will eventually render.

alter table public.invitations add column if not exists declined_at  timestamptz;
alter table public.invitations add column if not exists revoked_at   timestamptz;
alter table public.invitations add column if not exists revoked_by   uuid references auth.users(id);
alter table public.invitations add column if not exists extended_at  timestamptz;
alter table public.invitations add column if not exists extended_by  uuid references auth.users(id);

comment on column public.invitations.revoked_by is
  'Owner (or console admin) who revoked. Never returned to a client — actor identity is audit data.';

-- ============================================================================================
-- 2 · Duplicate policy (design record D5)
-- ============================================================================================
-- A partial unique index cannot reference now() (not immutable), so "active" is defined by STATUS
-- and the create function sweeps overdue rows to 'expired' in the same transaction BEFORE
-- inserting. A genuinely stale invitation therefore never blocks a re-invitation, while a live one
-- does. proposed_role is part of the key on purpose: the same person may hold one beneficiary AND
-- one professional-delegate invitation, because those are different relationships.

create unique index if not exists invitations_one_active_per_recipient_role
  on public.invitations (estate_id, lower(invitee_email), proposed_role)
  where status in ('pending', 'matched') and invitee_email is not null;

create unique index if not exists invitations_one_active_per_phone_role
  on public.invitations (estate_id, invitee_phone, proposed_role)
  where status in ('pending', 'matched') and invitee_phone is not null;

-- ============================================================================================
-- 3 · Delivery outbox — modelled exactly on storage_deletion_outbox (0039)
-- ============================================================================================
-- Born clean: RLS on, NO anon/authenticated grants, no policies. Owners reach it only through the
-- DEFINER functions below; the trusted worker drains it as service_role.
--
-- ★ IT HOLDS NO SECRET. Only an invitation_id. The raw token is minted at issue time and never
-- persisted, so a leak of this table discloses nothing usable.

create table if not exists public.invitation_delivery_outbox (
  id            uuid        primary key default uuid_generate_v4(),
  invitation_id uuid        not null references public.invitations(id) on delete cascade,
  -- Denormalized so ownership checks and audit survive independently of the invitation row.
  estate_id     uuid        not null references public.estates(id) on delete cascade,
  reason        text        not null check (reason in ('invitation_created', 'invitation_redelivery')),
  requested_by  uuid        not null references auth.users(id),
  requested_at  timestamptz not null default now(),
  status        text        not null default 'pending' check (status in ('pending', 'issued', 'failed')),
  attempts      int         not null default 0,
  last_error    text,
  issued_at     timestamptz
);

create index if not exists invitation_delivery_outbox_unissued_idx
  on public.invitation_delivery_outbox (requested_at) where status = 'pending';
create index if not exists invitation_delivery_outbox_invitation_idx
  on public.invitation_delivery_outbox (invitation_id, requested_at desc);

alter table public.invitation_delivery_outbox enable row level security;
grant select, update on public.invitation_delivery_outbox to service_role;

comment on table public.invitation_delivery_outbox is
  'Durable queue of invitation deliveries. Holds NO secret — the raw token is minted at issue time '
  'by issue_invitation_delivery() and never persisted. Drained by a trusted worker as service_role.';

-- ============================================================================================
-- 4 · Shared projection — the ONE place effective status is derived
-- ============================================================================================
-- public.invitations' own header warns that `expired` is BOTH a stored status and a read-time
-- `expires_at < now()` derivation, and that a listing must filter both. Deriving it once here
-- means the list, the action flags, and every guard agree by construction.

create or replace function public.invitation_effective_status(p_status text, p_expires_at timestamptz)
 returns text
 language sql
 immutable
 set search_path to 'public'
as $function$
  select case
    when p_status in ('pending', 'matched') and p_expires_at <= now() then 'expired'
    else p_status
  end;
$function$;
revoke execute on function public.invitation_effective_status(text, timestamptz) from public, anon;

-- ============================================================================================
-- 5 · Owner gate — ownership ONLY (design record D2)
-- ============================================================================================

create or replace function public.estate_owner_gate(p_estate uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  -- NOT `owner OR admin`. See design record D2: these are consumer-mobile functions, and platform
  -- admin must never confer estate-owner authority over a customer's estate through this path.
  if not public.is_estate_owner(p_estate) then
    raise exception 'owner_required' using errcode = '42501';
  end if;
end;
$function$;
revoke execute on function public.estate_owner_gate(uuid) from public, anon, authenticated;

-- ============================================================================================
-- 6 · list_estate_invitations — the missing owner read (design record D1)
-- ============================================================================================
-- Returns actionable invitations plus terminal ones settled within 90 days, newest first, capped.
-- DISPLAY-SAFE ONLY: masked hints, never invitee_email/phone; a derived fingerprint, never
-- token_hash; no invited_by/accepted_by/revoked_by, which are audit data rather than owner data.

create or replace function public.list_estate_invitations(
  p_estate uuid,
  p_limit  int default 50
)
 returns table(
   invitation_id      uuid,
   kind               text,
   proposed_role      text,
   status             text,          -- EFFECTIVE status (expiry projected)
   invitee_email_hint text,
   invitee_phone_hint text,
   token_fingerprint  text,          -- substr(hash,1,12) — an identifier, not a secret
   created_at         timestamptz,
   expires_at         timestamptz,
   accepted_at        timestamptz,
   declined_at        timestamptz,
   revoked_at         timestamptz,
   delivery_state     text,          -- none | queued | issued | failed  (never 'delivered')
   can_revoke         boolean,
   can_extend         boolean,
   can_redeliver      boolean
 )
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare v_limit int;
begin
  perform public.estate_owner_gate(p_estate);
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 100);

  return query
  with projected as (
    select
      i.id,
      i.kind,
      i.proposed_role,
      public.invitation_effective_status(i.status, i.expires_at) as eff_status,
      i.invitee_email_hint,
      i.invitee_phone_hint,
      substr(i.token_hash, 1, 12) as fingerprint,
      i.created_at,
      i.expires_at,
      i.accepted_at,
      i.declined_at,
      i.revoked_at,
      coalesce(
        (select o.status from public.invitation_delivery_outbox o
          where o.invitation_id = i.id
          order by o.requested_at desc limit 1),
        'none'
      ) as raw_delivery
    from public.invitations i
    where i.estate_id = p_estate
  )
  select
    p.id, p.kind, p.proposed_role, p.eff_status,
    p.invitee_email_hint, p.invitee_phone_hint, p.fingerprint,
    p.created_at, p.expires_at, p.accepted_at, p.declined_at, p.revoked_at,
    case p.raw_delivery when 'pending' then 'queued' else p.raw_delivery end,
    -- Action flags are derived from the EFFECTIVE status, so an expired-by-time row never offers
    -- an action the mutation would refuse.
    (p.eff_status in ('pending', 'matched')),
    (p.eff_status in ('pending', 'matched')),
    (p.eff_status in ('pending', 'matched'))
  from projected p
  -- Actionable rows always; terminal rows only while recent. 90 days matches the invitation
  -- lifetime ceiling already enforced by extend_invitation, so no new retention concept appears.
  where p.eff_status in ('pending', 'matched')
     or coalesce(p.revoked_at, p.declined_at, p.accepted_at, p.expires_at) > now() - interval '90 days'
  order by p.created_at desc, p.id desc
  limit v_limit;
end;
$function$;
revoke execute on function public.list_estate_invitations(uuid, int) from public, anon;
grant  execute on function public.list_estate_invitations(uuid, int) to authenticated;

-- ============================================================================================
-- 7 · create_estate_invitation — creates WITHOUT returning a secret (design record D3)
-- ============================================================================================

create or replace function public.create_estate_invitation(
  p_estate            uuid,
  p_proposed_role     text,
  p_invitee_email     text    default null,
  p_invitee_phone     text    default null,
  p_show_estate_name  boolean default false,
  p_show_inviter_name boolean default false,
  p_expires_in_days   int     default 14
)
 returns table(invitation_id uuid, token_fingerprint text, expires_at timestamptz, delivery_state text)
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_pending int; v_id uuid; v_expires timestamptz;
  v_estate_name text; v_inviter_name text;
  v_email text; v_phone text; v_email_hint text; v_phone_hint text;
  v_unissued_hash text; v_outbox uuid;
begin
  perform public.estate_owner_gate(p_estate);

  v_email := nullif(btrim(lower(coalesce(p_invitee_email, ''))), '');
  v_phone := nullif(btrim(coalesce(p_invitee_phone, '')), '');
  if v_email is null and v_phone is null then
    raise exception 'invitee_contact_required' using errcode = 'P0001';
  end if;

  -- Bounded to the verified product vocabulary. Ownership and fiduciary roles are unrepresentable
  -- here AND at the schema level (invitations_proposed_role_check), so an invitation can never
  -- grant executor, trustee, or owner. `kind` is set equal to the role: this consumer path does
  -- not expose the broader kind vocabulary the console uses.
  if p_proposed_role not in ('beneficiary', 'professional_delegate') then
    raise exception 'role_not_supported' using errcode = 'P0001';
  end if;
  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001';
  end if;

  -- Self-invitation is rejected: an owner is already the estate's owner, and inviting themselves
  -- would create a second membership row for the same person.
  if v_email is not null and v_email = (select lower(p.email) from public.profiles p where p.id = auth.uid()) then
    raise exception 'cannot_invite_self' using errcode = 'P0001';
  end if;

  -- Already an approved member of this estate → nothing to invite them to.
  if v_email is not null and exists (
    select 1 from public.estate_memberships m
    join public.profiles pr on pr.id = m.user_id
    where m.estate_id = p_estate and lower(pr.email) = v_email and m.status = 'approved'
  ) then
    raise exception 'already_member' using errcode = 'P0001';
  end if;

  -- ★ ATOMIC EXPIRY SWEEP, then the duplicate check (design record D5). A partial unique index
  -- cannot use now(), so overdue rows are settled to their true status first — otherwise a stale
  -- invitation would block re-inviting the same person forever.
  update public.invitations
     set status = 'expired', updated_at = now()
   where estate_id = p_estate and status in ('pending', 'matched') and expires_at <= now();

  if v_email is not null and exists (
    select 1 from public.invitations i
    where i.estate_id = p_estate and lower(i.invitee_email) = v_email
      and i.proposed_role = p_proposed_role and i.status in ('pending', 'matched')
  ) then
    raise exception 'active_invitation_exists' using errcode = 'P0001';
  end if;

  select count(*) into v_pending
    from public.invitations inv
   where inv.estate_id = p_estate and inv.status in ('pending', 'matched') and inv.expires_at > now();
  if v_pending >= 20 then
    raise exception 'pending_invitation_cap' using errcode = 'P0001';
  end if;

  select e.name into v_estate_name from public.estates e where e.id = p_estate;
  select coalesce(nullif(pr.full_name, ''), pr.email) into v_inviter_name
    from public.profiles pr where pr.id = auth.uid();

  v_email_hint := case when v_email is not null
    then left(v_email, 1) || '•••@' || split_part(v_email, '@', 2) else null end;
  v_phone_hint := case when v_phone is not null then '•••' || right(v_phone, 4) else null end;

  -- ★ THE SECRET IS NOT MINTED HERE. token_hash is NOT NULL, so a hash of an immediately-discarded
  -- random value is stored. The invitation therefore exists but is NOT YET USABLE: no token that
  -- hashes to this value has ever existed outside this statement. The real secret is minted by
  -- issue_invitation_delivery() at delivery time. Fail-closed: an invitation nobody has been told
  -- about cannot be accepted.
  v_unissued_hash := encode(digest(encode(gen_random_bytes(32), 'hex'), 'sha256'), 'hex');
  v_expires := now() + make_interval(days => p_expires_in_days);

  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_phone, invitee_email_hint, invitee_phone_hint,
     estate_display_name, inviter_display_name, preview_visibility, token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), p_estate, auth.uid(), p_proposed_role, p_proposed_role, 'pending', v_expires,
     v_email, v_phone, v_email_hint, v_phone_hint, v_estate_name, v_inviter_name,
     jsonb_build_object('showEstateName', p_show_estate_name, 'showInviterName', p_show_inviter_name),
     v_unissued_hash, now(), now())
  returning id into v_id;

  -- Same transaction: the invitation and its delivery request commit together or not at all.
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_id, p_estate, 'invitation_created', auth.uid())
  returning id into v_outbox;

  perform public.write_audit('invitation.created', 'invitations', v_id, p_estate,
    jsonb_build_object('invitation_id', v_id, 'proposed_role', p_proposed_role,
                       'invitee_email_hint', v_email_hint, 'expires_at', v_expires,
                       'delivery_outbox_id', v_outbox));

  -- 'queued' — NOT 'sent'. Nothing has been delivered; a worker must still run.
  return query select v_id, substr(v_unissued_hash, 1, 12), v_expires, 'queued'::text;
end;
$function$;
revoke execute on function public.create_estate_invitation(uuid, text, text, text, boolean, boolean, int) from public, anon;
grant  execute on function public.create_estate_invitation(uuid, text, text, text, boolean, boolean, int) to authenticated;

-- ============================================================================================
-- 8 · revoke_estate_invitation — estate-scoped, owner-gated
-- ============================================================================================

create or replace function public.revoke_estate_invitation(p_estate uuid, p_invitation uuid)
 returns table(invitation_id uuid, status text, revoked_at timestamptz)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_inv record; v_eff text;
begin
  perform public.estate_owner_gate(p_estate);

  select * into v_inv from public.invitations
   where id = p_invitation and estate_id = p_estate for update;
  -- Cross-estate and unknown ids are indistinguishable: an owner must not be able to probe for
  -- the existence of another estate's invitations.
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- Idempotent on already-revoked: repeating the operation returns the authoritative revoked row
  -- rather than an error, so a retried request is safe.
  if v_inv.status = 'revoked' then
    return query select v_inv.id, v_inv.status, v_inv.revoked_at;
    return;
  end if;

  v_eff := public.invitation_effective_status(v_inv.status, v_inv.expires_at);
  if v_eff not in ('pending', 'matched') then
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  update public.invitations
     set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), updated_at = now()
   where id = v_inv.id;

  -- Any queued delivery for a revoked invitation must not go out.
  update public.invitation_delivery_outbox
     set status = 'failed', last_error = 'invitation_revoked'
   where invitation_id = v_inv.id and status = 'pending';

  perform public.write_audit('invitation.revoked', 'invitations', v_inv.id, p_estate,
    jsonb_build_object('invitation_id', v_inv.id, 'prior_status', v_inv.status));

  return query select v_inv.id, 'revoked'::text, now();
end;
$function$;
revoke execute on function public.revoke_estate_invitation(uuid, uuid) from public, anon;
grant  execute on function public.revoke_estate_invitation(uuid, uuid) to authenticated;

-- ============================================================================================
-- 9 · extend_estate_invitation (design record D6)
-- ============================================================================================
-- The client supplies an interval, never a timestamp, so an "extend" can never shorten.

create or replace function public.extend_estate_invitation(
  p_estate uuid, p_invitation uuid, p_expires_in_days int default 14
)
 returns table(invitation_id uuid, expires_at timestamptz)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_inv record; v_new timestamptz;
begin
  perform public.estate_owner_gate(p_estate);
  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001';
  end if;

  select * into v_inv from public.invitations
   where id = p_invitation and estate_id = p_estate for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;
  if v_inv.created_at + interval '90 days' <= now() then
    raise exception 'invitation_lifetime_exceeded' using errcode = 'P0003';  -- mint a new one
  end if;

  v_new := least(now() + make_interval(days => p_expires_in_days), v_inv.created_at + interval '90 days');
  -- Never shorten, even if the cap would.
  if v_new <= v_inv.expires_at then
    raise exception 'extension_would_not_lengthen' using errcode = 'P0001';
  end if;

  update public.invitations
     set expires_at = v_new, extended_at = now(), extended_by = auth.uid(), updated_at = now()
   where id = v_inv.id;

  perform public.write_audit('invitation.extended', 'invitations', v_inv.id, p_estate,
    jsonb_build_object('invitation_id', v_inv.id, 'old_expires_at', v_inv.expires_at, 'new_expires_at', v_new));

  return query select v_inv.id, v_new;
end;
$function$;
revoke execute on function public.extend_estate_invitation(uuid, uuid, int) from public, anon;
grant  execute on function public.extend_estate_invitation(uuid, uuid, int) to authenticated;

-- ============================================================================================
-- 10 · request_invitation_redelivery (design record D7)
-- ============================================================================================
-- NOT "resend": nothing is re-sent. A new secret is issued at drain time, which invalidates the
-- previous link — the correct behaviour, and it needs no separate revocation step.

create or replace function public.request_invitation_redelivery(p_estate uuid, p_invitation uuid)
 returns table(invitation_id uuid, delivery_state text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_inv record; v_recent int;
begin
  perform public.estate_owner_gate(p_estate);

  select * into v_inv from public.invitations
   where id = p_invitation and estate_id = p_estate for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  -- DB-resident throttle, matching 0016's approach: PostgREST bypasses the Vercel rate limiter, so
  -- the abuse control has to live here.
  select count(*) into v_recent from public.invitation_delivery_outbox o
   where o.invitation_id = v_inv.id and o.requested_at > now() - interval '1 hour';
  if v_recent >= 3 then
    raise exception 'redelivery_rate_limited' using errcode = 'P0004';
  end if;

  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv.id, p_estate, 'invitation_redelivery', auth.uid());

  perform public.write_audit('invitation.delivery_requested', 'invitations', v_inv.id, p_estate,
    jsonb_build_object('invitation_id', v_inv.id, 'reason', 'invitation_redelivery'));

  return query select v_inv.id, 'queued'::text;
end;
$function$;
revoke execute on function public.request_invitation_redelivery(uuid, uuid) from public, anon;
grant  execute on function public.request_invitation_redelivery(uuid, uuid) to authenticated;

-- ============================================================================================
-- 11 · TRUSTED WORKER SURFACE — service_role ONLY, never granted to authenticated
-- ============================================================================================
-- ★ issue_invitation_delivery is the ONLY function in this project that returns a raw invitation
-- token, and it is reachable only by a server-side worker holding the service-role key. It mints a
-- fresh secret, stores only its SHA-256 hash, and returns the raw value transiently so a link can
-- be built. The secret never rests anywhere.
--
-- Rotation is inherent: issuing again overwrites the hash, so any previously issued link stops
-- working. That is the desired behaviour for redelivery.

create or replace function public.issue_invitation_delivery(p_outbox_id uuid)
 returns table(
   invitation_id      uuid,
   raw_token          text,     -- transient; NEVER persisted, NEVER returned to a client
   invitee_email      text,
   invitee_phone      text,
   estate_display_name  text,
   inviter_display_name text,
   preview_visibility jsonb,
   expires_at         timestamptz
 )
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare v_out record; v_inv record; v_raw text; v_hash text;
begin
  select * into v_out from public.invitation_delivery_outbox
   where id = p_outbox_id and status = 'pending' for update skip locked;
  if not found then raise exception 'outbox_entry_not_claimable' using errcode = 'P0002'; end if;

  select * into v_inv from public.invitations where id = v_out.invitation_id for update;
  if not found then
    update public.invitation_delivery_outbox
       set status = 'failed', attempts = attempts + 1, last_error = 'invitation_missing'
     where id = p_outbox_id;
    raise exception 'invitation_not_found' using errcode = 'P0002';
  end if;

  -- Never issue a secret for an invitation that is no longer actionable.
  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    update public.invitation_delivery_outbox
       set status = 'failed', attempts = attempts + 1, last_error = 'invitation_not_actionable'
     where id = p_outbox_id;
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  v_raw  := encode(gen_random_bytes(32), 'hex');       -- 64 hex chars, within bind/preview's 16..512
  v_hash := encode(digest(v_raw, 'sha256'), 'hex');    -- ONLY the hash is stored

  update public.invitations set token_hash = v_hash, updated_at = now() where id = v_inv.id;
  update public.invitation_delivery_outbox
     set status = 'issued', attempts = attempts + 1, issued_at = now()
   where id = p_outbox_id;

  -- The audit records the FINGERPRINT, never the token.
  perform public.write_audit('invitation.delivery_issued', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'token_fingerprint', substr(v_hash, 1, 12)));

  return query select v_inv.id, v_raw, v_inv.invitee_email, v_inv.invitee_phone,
                      v_inv.estate_display_name, v_inv.inviter_display_name,
                      v_inv.preview_visibility, v_inv.expires_at;
end;
$function$;
revoke execute on function public.issue_invitation_delivery(uuid) from public, anon, authenticated;
grant  execute on function public.issue_invitation_delivery(uuid) to service_role;

create or replace function public.record_invitation_delivery_failure(p_outbox_id uuid, p_error text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_out record;
begin
  select * into v_out from public.invitation_delivery_outbox where id = p_outbox_id for update;
  if not found then return; end if;
  update public.invitation_delivery_outbox
     set status = 'failed', attempts = attempts + 1, last_error = left(coalesce(p_error, 'unknown'), 500)
   where id = p_outbox_id;
  perform public.write_audit('invitation.delivery_failed', 'invitations', v_out.invitation_id, v_out.estate_id,
    jsonb_build_object('invitation_id', v_out.invitation_id, 'outbox_id', p_outbox_id));
end;
$function$;
revoke execute on function public.record_invitation_delivery_failure(uuid, text) from public, anon, authenticated;
grant  execute on function public.record_invitation_delivery_failure(uuid, text) to service_role;

commit;
