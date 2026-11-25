-- 0067_20261125_resolve_membership_contact_binding.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- INVITATION CONTACT BINDING — every place an invitation is matched to the person it was addressed
-- to now reads the caller's VERIFIED contacts from the authenticated identity.
--
-- ★ WHAT CHANGES. Two new helpers. `public.invitation_phone_key(text, boolean)` reduces a phone to its
--   E.164 digit key on both sides of a match (the Auth digits and the owner's "+"-prefixed invitation
--   compare equal; a number without "+" or malformed never matches — existing rows need no backfill).
--   `public.caller_verified_contacts()` returns the GoTrue-confirmed
--   email and phone of `auth.uid()` (NULL for an unconfirmed, missing or deleted contact). Four
--   functions are re-created to use it instead of `public.profiles`, which is self-editable and is
--   copied only at sign-up: `resolve_membership` (the pending-invitation list — its `p_email` /
--   `p_phone` parameters stay for installed clients but are no longer consulted, so a supplied
--   address can never widen what the caller sees), `accept_invitation`, `decline_invitation` and
--   `bind_invitation_token`. A missing or unconfirmed phone matches nothing; a confirmed email
--   matches independently of any phone.
--
-- ★ WHAT DOES NOT CHANGE. RPC signatures and response shapes; the owner's management policy on
--   invitations; token preview (`invitation_preview`); table grants (none exist on `invitations` for
--   client roles, so the invitee read policy is reachable only through these definer functions).
--
-- ★ SCHEMA UNCHANGED. Function bodies only (six), all also under db/functions/ (source of truth).
--   Requires GoTrue's `auth.users.email_confirmed_at`, `phone`, `phone_confirmed_at`, `deleted_at`.
--
-- Idempotent: `create or replace` throughout. Re-apply on any DB reset AFTER the bootstrap.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1 · the phone comparison key ─────────────────────────────────────────────────────────────────────────────
-- public.invitation_phone_key(p_raw text, p_require_plus boolean) -> text
--
-- THE ONE comparison key for a phone number on the invitation path. Both sides of every phone match
-- (resolve_membership's pending list, accept_invitation, decline_invitation, bind_invitation_token)
-- are reduced to this key and compared with plain equality — never a raw string against a raw string.
--
-- ★ WHY. GoTrue stores a confirmed phone as international DIGITS ("15555550100"); the owner paths
--   store the invitee phone as the owner typed it, conventionally with a leading "+" ("+15555550100").
--   A raw equality never matched the two, so a confirmed phone could not see or accept an invitation
--   addressed to it. The key is the E.164 digit string, derived strictly:
--
--   · p_require_plus = true  (the INVITATION side): accepted only as "+" followed by E.164 digits
--     (`^\+[1-9][0-9]{7,14}$`). A number written without the "+" has no country-code marker and is
--     ambiguous, so it NEVER matches — existing rows written with "+" are covered without a backfill;
--   · p_require_plus = false (the AUTH side): the same digits with or without the "+", as GoTrue
--     writes them (`^\+?[1-9][0-9]{7,14}$`);
--   · anything else — spaces, dashes, parentheses, letters, a leading zero, too short, too long,
--     NULL — yields NULL, and a NULL key matches nothing.
--
-- ★ STRICT ON PURPOSE. No digit stripping, no "best effort" normalisation: a malformed value is a
--   value nobody verified, and the cost of refusing it is one re-issued invitation.
--
-- Source of truth for this function. Re-apply on any DB reset.

create or replace function public.invitation_phone_key(p_raw text, p_require_plus boolean)
 returns text
 language sql
 immutable
 strict
 parallel safe
as $function$
  select case
    when p_require_plus and p_raw ~ '^\+[1-9][0-9]{7,14}$' then substr(p_raw, 2)
    when not p_require_plus and p_raw ~ '^\+[1-9][0-9]{7,14}$' then substr(p_raw, 2)
    when not p_require_plus and p_raw ~ '^[1-9][0-9]{7,14}$' then p_raw
    else null
  end
$function$;
revoke execute on function public.invitation_phone_key(text, boolean) from public, anon;
grant  execute on function public.invitation_phone_key(text, boolean) to authenticated;

-- ── 2 · the verified-contact source ─────────────────────────────────────────────────────────────────────────────
-- public.caller_verified_contacts() -> (email text, phone text)
--
-- The ONE source of the authenticated caller's VERIFIED contacts, for every place an invitation is
-- matched to the person it was addressed to (resolve_membership's pending list, accept_invitation,
-- decline_invitation, bind_invitation_token).
--
-- ★ WHY NOT `public.profiles`. `profiles_self_update` lets a user change their own row, columns
--   included, and `handle_new_user` copies the address only at sign-up. A profile address is
--   therefore neither verified, nor immune to an ordinary edit, nor current after a contact change —
--   the three properties an invitation match needs. Four functions read it anyway; this helper
--   replaces all four reads.
--
-- ★ WHY `auth.users`. GoTrue owns it, no client role can write it, `email` and `phone` change only
--   through its own confirmation flows, and `email_confirmed_at` / `phone_confirmed_at` record that
--   the address was proven. A contact is eligible ONLY when its confirmation timestamp is set:
--   an unconfirmed email yields NULL, a missing or unconfirmed phone yields NULL, and each contact
--   is decided independently — a verified email keeps working without any phone.
--
-- ★ THE PHONE IS RETURNED AS A COMPARISON KEY, NOT A STRING (see invitation_phone_key.sql). GoTrue
--   stores E.164 digits without the "+"; the callers reduce the invitation side to the same key and
--   compare keys. A confirmed phone that is not E.164-shaped yields NULL and matches nothing.
--
-- ★ NULL MEANS "NO CONTACT", AND THE CALLERS TREAT IT AS "MATCHES NOTHING". No fallback to a profile,
--   a JWT claim, or a caller-supplied parameter. SECURITY DEFINER only so the definer can read
--   auth.users; the function returns the caller's OWN row and nothing else.
--
-- Source of truth for this function. Re-apply on any DB reset.

create or replace function public.caller_verified_contacts(out email text, out phone text)
 returns record
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_user uuid := auth.uid();
begin
  email := null;
  phone := null;
  if v_user is null then
    return;
  end if;
  select
    case when u.email_confirmed_at is not null and nullif(btrim(u.email), '') is not null
         then lower(btrim(u.email)) end,
    case when u.phone_confirmed_at is not null
         then public.invitation_phone_key(btrim(u.phone), false) end
    into email, phone
    from auth.users u
   where u.id = v_user
     and u.deleted_at is null;
  return;
end
$function$;
revoke execute on function public.caller_verified_contacts() from public, anon;
grant  execute on function public.caller_verified_contacts() to authenticated;

-- ── 3 · resolve_membership (pending list) ─────────────────────────────────────────────────────────────────────────────
-- public.resolve_membership(p_email text, p_phone text) -> jsonb
--
-- Resolves the authenticated caller's membership context: their primary estate
-- (bootstrapped on first call if none exists), pending invitations matching
-- their email/phone, and additional (non-owned) estate memberships.
--
-- Each estate context includes ownerUserId (estates.owner_id) so the iOS legacy
-- estate-context layer has the real owner for both owned and beneficiary contexts.
--
-- SECURITY DEFINER; relies on auth.uid(). Called from /api/invitations/resolve
-- with the caller's JWT forwarded (so auth.uid() is the real user).
--
-- ★ CONTACT BINDING (2026-11-25). The pending-invitation list is matched on the caller's VERIFIED
-- contacts from `caller_verified_contacts()` (GoTrue-confirmed email / phone of auth.uid()), never
-- on `p_email` / `p_phone`. The two parameters stay in the signature for installed clients and are
-- accepted but NOT consulted: a supplied address can never widen what the caller sees. A missing or
-- unconfirmed phone matches nothing; a confirmed email matches independently of any phone. Phones
-- are compared as E.164 keys on both sides (`invitation_phone_key`): the Auth digits and the owner's
-- "+"-prefixed invitation reduce to the same key; a number without "+" or malformed never matches.
--
-- Source of truth for this function. Re-apply on any DB reset.

CREATE OR REPLACE FUNCTION public.resolve_membership(p_email text, p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_user uuid := auth.uid();
  v_primary jsonb;
  v_pending jsonb;
  v_additional jsonb;
  v_primary_estate_id uuid;
  v_email text;
  v_phone text;
begin
  -- Caller must be authenticated. Resolution has no meaning otherwise.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Look for the user's primary estate (one they own and that is
  -- marked as is_primary). If none exists, bootstrap one.
  select id into v_primary_estate_id
  from public.estates
  where owner_id = v_user
    and is_primary = true
  limit 1;

  if v_primary_estate_id is null then
    v_primary_estate_id := gen_random_uuid();
    insert into public.estates
      (id, owner_id, name, status, is_primary, created_at, updated_at)
    values
      (v_primary_estate_id, v_user, 'My Estate', 'active', true,
       now(), now());

    -- Note: NO insert into estate_memberships here. The trigger
    -- estates_ensure_primary_user_membership handles it with the
    -- correct V1 'primary_user' role.

    perform public.write_audit(
      'estate.primary_created',
      'estates',
      v_primary_estate_id,
      v_primary_estate_id,
      '{}'::jsonb
    );
  end if;

  -- Primary estate context: the user's own estate.
  select jsonb_build_object(
    'id', m.id,
    'estateId', e.id,
    'estateDisplayName', e.name,
    'ownerUserId', e.owner_id,
    'roleWithinEstate', m.role,
    'membershipStatus', m.status,
    'isPrimaryEstate', true
  )
  into v_primary
  from public.estate_memberships m
  join public.estates e on e.id = m.estate_id
  where m.user_id = v_user
    and e.is_primary = true
    and m.status = 'approved'
    and public.is_ownership_role(m.role)
  limit 1;

  -- Pending invitations addressed to the caller's VERIFIED contacts (header note). The parameters
  -- p_email / p_phone are deliberately unused here.
  select c.email, c.phone into v_email, v_phone from public.caller_verified_contacts() c;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id,
    'estateId', i.estate_id,
    'estateDisplayName',
      case when (i.preview_visibility->>'showEstateName')::boolean
           then i.estate_display_name else null end,
    'inviterDisplayName',
      case when (i.preview_visibility->>'showInviterName')::boolean
           then i.inviter_display_name else null end,
    'invitationKind', i.kind,
    'proposedRole', i.proposed_role,
    'expiresAt', i.expires_at,
    'status', i.status
  )), '[]'::jsonb)
  into v_pending
  from public.invitations i
  where i.status in ('pending', 'matched')
    and i.expires_at > now()
    and (
      -- the SAME null-safe predicate the accept/decline/bind guards use
      (v_email is not null
       and lower(i.invitee_email) is not distinct from v_email)
      or
      (v_phone is not null
       and public.invitation_phone_key(i.invitee_phone, true) is not distinct from v_phone)
    );

  -- Additional contexts: approved memberships in estates the user does NOT own.
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'estateId', e.id,
    'estateDisplayName', e.name,
    'ownerUserId', e.owner_id,
    'roleWithinEstate', m.role,
    'membershipStatus', m.status,
    'isPrimaryEstate', false
  )), '[]'::jsonb)
  into v_additional
  from public.estate_memberships m
  join public.estates e on e.id = m.estate_id
  where m.user_id = v_user
    and m.status = 'approved'
    and not public.is_ownership_role(m.role);

  return jsonb_build_object(
    'primaryEstateContext', v_primary,
    'pendingInvitations', v_pending,
    'additionalContexts', v_additional
  );
end;
$function$;
revoke execute on function public.resolve_membership(text, text) from public, anon;
grant  execute on function public.resolve_membership(text, text) to authenticated;

-- ── 4 · accept_invitation ─────────────────────────────────────────────────────────────────────────────
-- public.accept_invitation(p_invitation_id uuid)
--   -> TABLE(membership_id uuid, estate_id uuid, estate_display_name text, role text, status text)
--
-- Accepts an invitation BY ID (matched-invitations screen). Validates token/expiry/status + the P0006
-- identity guard (caller's own contact must match the invitee), then delegates provisioning to the shared
-- public.provision_from_invitation helper (membership-reconcile + beneficiary self-link + executor/trustee
-- designation + audit). Idempotent: re-accept returns the existing membership and self-heals via the helper.
--
-- Error codes: 42501 unauthenticated, P0002 not_found, P0003 expired, P0004 revoked, P0005 already_accepted
-- (by someone else), P0006 not_for_caller, P0007 declined.
--
-- Captured from live 2026-07-15 (migration 0021 — refactored onto the shared helper). SECURITY DEFINER.

create or replace function public.accept_invitation(p_invitation_id uuid)
 returns table(membership_id uuid, estate_id uuid, estate_display_name text, role text, status text)
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid();
  v_inv record; v_user_email text; v_user_phone text; v_membership_id uuid;
begin
  if v_user is null then raise exception 'unauthenticated' using errcode = '42501'; end if;
  select * into v_inv from public.invitations where id = p_invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;
  if v_inv.expires_at < now() then raise exception 'invitation_expired' using errcode = 'P0003'; end if;
  if v_inv.status = 'revoked' then raise exception 'invitation_revoked' using errcode = 'P0004'; end if;
  if v_inv.status = 'declined' then raise exception 'invitation_declined' using errcode = 'P0007'; end if;

  -- ★ THE CALLER'S VERIFIED CONTACTS, NEVER THE PROFILE (2026-11-25). `profiles` is self-editable, so a
  -- profile address proves nothing about who the caller is; `caller_verified_contacts()` reads the
  -- GoTrue-confirmed email/phone, and a NULL contact matches nothing.
  select c.email, c.phone into v_user_email, v_user_phone from public.caller_verified_contacts() c;
  -- ★ NULL-SAFE, DELIBERATELY. `IS NOT DISTINCT FROM`: a NULL on either side is "no match", never a NULL
  -- that would make `not (... or ...)` NULL and silently skip this raise (three-valued logic).
  if not ((v_user_email is not null and lower(v_inv.invitee_email) is not distinct from v_user_email)
       or (v_user_phone is not null and public.invitation_phone_key(v_inv.invitee_phone, true) is not distinct from v_user_phone)) then
    raise exception 'invitation_not_for_caller' using errcode = 'P0006';
  end if;

  -- Idempotency keys on the invitation's OWN accepted_by (authoritative), NOT the membership's
  -- source_invitation_id: a reconciled membership (an executor who was already a beneficiary member) has a
  -- different/NULL source, so keying on source would (a) spuriously P0005 a same-user re-accept AND (b)
  -- NEVER self-heal a missing designation — the silent-authority-void the shared helper exists to prevent.
  if v_inv.status = 'accepted' then
    if v_inv.accepted_by = v_user then
      perform public.provision_from_invitation(v_inv.id, v_user);   -- idempotent self-heal (re-stamps a missing designation)
      select em.id into v_membership_id from public.estate_memberships em
       where em.estate_id = v_inv.estate_id and em.user_id = v_user;
          -- ★ PHASE 11-MC: A FIDUCIARY ACCEPTANCE HAS NO MEMBERSHIP, SO IT REPORTS NONE.
      -- `provision_from_invitation` no longer creates a membership for an executor/trustee invitation,
      -- so `v_membership_id` is NULL for a recipient who holds no independent access class. Returning
      -- the invitation's stale `proposed_role` and a hardcoded 'approved' would assert an approved
      -- beneficiary membership that does not exist — the exact fiction this phase removes, restated on
      -- the way out. Role and status are NULL together with the membership id; the fiduciary authority
      -- is reported by `get_my_fiduciary_estates`, which is the surface that owns it.
  return query select v_membership_id, v_inv.estate_id,
        (select e.name from public.estates e where e.id = v_inv.estate_id),
        case when v_membership_id is null then null else v_inv.proposed_role::text end,
        case when v_membership_id is null then null else 'approved'::text end;
      return;
    else
      raise exception 'invitation_already_accepted' using errcode = 'P0005';
    end if;
  end if;

  update public.invitations set status='accepted', accepted_by=v_user, accepted_at=now(), updated_at=now() where id=v_inv.id;
  v_membership_id := public.provision_from_invitation(v_inv.id, v_user);
  perform public.write_audit('invitation.accepted', 'estate_memberships', v_membership_id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'via', 'accept_by_id'));

  -- ★ PHASE 10-E — the OWNER learns their invitation was accepted. Deliberately BELOW the idempotent
  -- re-accept branch above, which returns early: a self-heal re-accept must not tell the owner a
  -- second time that someone joined.
  --
  -- The copy says "someone you invited", never who. The owner issued the invitation and already
  -- knows the invitee, so this says strictly LESS than they know — which is the correct direction
  -- for a surface whose whole job is to avoid becoming a disclosure channel. It also never names the
  -- accepted ROLE: a membership role is a relationship, and relationships are stated by the
  -- authoritative surfaces that already gate them, not by a heads-up.
  perform public.emit_lifecycle_notification(
    public.estate_owner_user_id(v_inv.estate_id),
    v_inv.estate_id,
    'invitation.accepted',
    'afterworth://owner-invitations'
  );
  return query select v_membership_id, v_inv.estate_id,
    (select e.name from public.estates e where e.id = v_inv.estate_id),
    case when v_membership_id is null then null else v_inv.proposed_role::text end,
    case when v_membership_id is null then null else 'approved'::text end;
end;
$function$;

-- ── 5 · decline_invitation ─────────────────────────────────────────────────────────────────────────────
-- public.decline_invitation(p_invitation_id uuid) -> void
--
-- Declines an invitation BY ID. Used by the in-app "matched invitations" screen.
-- Same invitee email/phone guard as accept_invitation. Sets status='declined'.
-- Does NOT create a membership.
--
-- Semantics:
--   - pending / matched -> declined (the normal case)
--   - already declined   -> no-op, returns successfully (idempotent)
--   - accepted           -> error P0005 (cannot decline what you've accepted;
--                           removing a membership is a separate operation)
--   - revoked / expired  -> P0004 / P0003 (nothing to decline)
--
-- Error codes (mapped in api/invitations/decline.ts):
--   42501 unauthenticated, P0002 not_found, P0003 expired, P0004 revoked,
--   P0005 already_accepted, P0006 not_for_caller.
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

CREATE OR REPLACE FUNCTION public.decline_invitation(p_invitation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_user uuid := auth.uid();
  v_inv record;
  v_user_email text;
  v_user_phone text;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  select * into v_inv
  from public.invitations
  where id = p_invitation_id
  for update;

  if not found then
    raise exception 'invitation_not_found' using errcode = 'P0002';
  end if;

  -- Verify the caller is the intended invitee (same guard as accept).
  -- ★ THE CALLER'S VERIFIED CONTACTS, NEVER THE PROFILE (2026-11-25) — see caller_verified_contacts.sql.
  select c.email, c.phone into v_user_email, v_user_phone from public.caller_verified_contacts() c;
  -- ★ NULL-SAFE, DELIBERATELY. `IS NOT DISTINCT FROM`: a NULL on either side is "no match", never a NULL
  -- that would make `not (... or ...)` NULL and silently skip this raise (three-valued logic).
  if not ((v_user_email is not null and lower(v_inv.invitee_email) is not distinct from v_user_email)
       or (v_user_phone is not null and public.invitation_phone_key(v_inv.invitee_phone, true) is not distinct from v_user_phone)) then
    raise exception 'invitation_not_for_caller' using errcode = 'P0006';
  end if;

  -- Idempotent: already declined is a successful no-op.
  if v_inv.status = 'declined' then
    return;
  end if;

  if v_inv.status = 'accepted' then
    raise exception 'invitation_already_accepted' using errcode = 'P0005';
  end if;

  if v_inv.status = 'revoked' then
    raise exception 'invitation_revoked' using errcode = 'P0004';
  end if;

  if v_inv.expires_at < now() then
    raise exception 'invitation_expired' using errcode = 'P0003';
  end if;

  update public.invitations
     set status = 'declined',
         updated_at = now()
   where id = v_inv.id;

  perform public.write_audit(
    'invitation.declined',
    'invitations',
    v_inv.id,
    v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id)
  );

  -- ★ PHASE 10-E — the OWNER learns an invitation was declined. Below the idempotent
  -- already-declined early-return, so a repeat decline emits nothing the second time. That
  -- placement is load-bearing and is asserted: an emitter moved above the idempotency guard would
  -- produce one notification per call rather than one per event, and nothing else would notice.
  --
  -- No deep link on this one — the invitation is finished, and there is no state to go and look at.
  perform public.emit_lifecycle_notification(
    public.estate_owner_user_id(v_inv.estate_id),
    v_inv.estate_id,
    'invitation.declined',
    null
  );
end;
$function$;

-- ── 6 · bind_invitation_token ─────────────────────────────────────────────────────────────────────────────
-- public.bind_invitation_token(p_token text)
--   -> TABLE(membership_id uuid, estate_id uuid, estate_display_name text, role text, status text)
--
-- Binds the authenticated caller to an invitation by its plaintext token (hashes it, looks up, verifies the
-- P0006 identity guard), then delegates provisioning to the shared public.provision_from_invitation helper
-- (membership-reconcile + beneficiary self-link + executor/trustee designation + audit). Idempotent.
--
-- 0021: refactored onto the shared helper. NOTE: the beneficiary self-link now runs on the TOKEN path too
-- (it previously ran only on accept-by-id — a pre-existing asymmetry, fixed here). Membership + the
-- invitation.bound audit are unchanged.
--
-- Error codes: 42501 unauthenticated, P0001 invalid_token, P0002 not_found, P0003 expired, P0004 revoked,
-- P0005 already_accepted (by someone else), P0006 not_for_caller.
--
-- Captured from live 2026-07-15. SECURITY DEFINER. Source of truth — re-apply on reset.

create or replace function public.bind_invitation_token(p_token text)
 returns table(membership_id uuid, estate_id uuid, estate_display_name text, role text, status text)
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid(); v_hash text; v_inv record; v_user_email text; v_user_phone text; v_membership_id uuid;
begin
  if v_user is null then raise exception 'unauthenticated' using errcode = '42501'; end if;
  if p_token is null or length(p_token) < 16 or length(p_token) > 512 then
    raise exception 'invalid_token' using errcode = 'P0001';
  end if;
  v_hash := encode(digest(p_token, 'sha256'), 'hex');
  select * into v_inv from public.invitations where token_hash = v_hash for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;
  if v_inv.expires_at < now() then raise exception 'invitation_expired' using errcode = 'P0003'; end if;
  if v_inv.status = 'revoked' then raise exception 'invitation_revoked' using errcode = 'P0004'; end if;

  -- ★ THE CALLER'S VERIFIED CONTACTS, NEVER THE PROFILE (2026-11-25) — see caller_verified_contacts.sql.
  select c.email, c.phone into v_user_email, v_user_phone from public.caller_verified_contacts() c;
  -- ★ NULL-SAFE, DELIBERATELY. `IS NOT DISTINCT FROM`: a NULL on either side is "no match", never a NULL
  -- that would make `not (... or ...)` NULL and silently skip this raise (three-valued logic).
  if not ((v_user_email is not null and lower(v_inv.invitee_email) is not distinct from v_user_email)
       or (v_user_phone is not null and public.invitation_phone_key(v_inv.invitee_phone, true) is not distinct from v_user_phone)) then
    raise exception 'invitation_not_for_caller' using errcode = 'P0006';
  end if;

  -- Idempotency keys on the invitation's OWN accepted_by (authoritative), NOT the membership's
  -- source_invitation_id (see accept_invitation) — a reconciled membership has a different/NULL source.
  if v_inv.status = 'accepted' then
    if v_inv.accepted_by = v_user then
      perform public.provision_from_invitation(v_inv.id, v_user);   -- idempotent self-heal (re-stamps a missing designation)
      select em.id into v_membership_id from public.estate_memberships em
       where em.estate_id = v_inv.estate_id and em.user_id = v_user;
          -- ★ PHASE 11-MC: A FIDUCIARY ACCEPTANCE HAS NO MEMBERSHIP, SO IT REPORTS NONE.
      -- `provision_from_invitation` no longer creates a membership for an executor/trustee invitation,
      -- so `v_membership_id` is NULL for a recipient who holds no independent access class. Returning
      -- the invitation's stale `proposed_role` and a hardcoded 'approved' would assert an approved
      -- beneficiary membership that does not exist — the exact fiction this phase removes, restated on
      -- the way out. Role and status are NULL together with the membership id; the fiduciary authority
      -- is reported by `get_my_fiduciary_estates`, which is the surface that owns it.
  return query select v_membership_id, v_inv.estate_id,
        (select e.name from public.estates e where e.id = v_inv.estate_id),
        case when v_membership_id is null then null else v_inv.proposed_role::text end,
        case when v_membership_id is null then null else 'approved'::text end;
      return;
    else
      raise exception 'invitation_already_accepted' using errcode = 'P0005';
    end if;
  end if;

  update public.invitations set status='accepted', accepted_by=v_user, accepted_at=now(), updated_at=now() where id=v_inv.id;
  v_membership_id := public.provision_from_invitation(v_inv.id, v_user);
  perform public.write_audit('invitation.bound', 'estate_memberships', v_membership_id, v_inv.estate_id,
    jsonb_build_object('token_fingerprint', substr(v_hash,1,12), 'invitation_id', v_inv.id));
  return query select v_membership_id, v_inv.estate_id,
    (select e.name from public.estates e where e.id = v_inv.estate_id),
    case when v_membership_id is null then null else v_inv.proposed_role::text end,
    case when v_membership_id is null then null else 'approved'::text end;
end;
$function$;

