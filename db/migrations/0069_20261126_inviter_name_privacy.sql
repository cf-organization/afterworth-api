-- 0069_20261126_inviter_name_privacy.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- INVITER NAME PRIVACY — an owner's email address is never released to a recipient as their "name",
-- and a recipient sees an inviter name only where the owner chose to show one AND the stored value is one.
--
-- ★ THE DEFECT. Both invitation create paths persisted
--       inviter_display_name = coalesce(nullif(profiles.full_name, ''), profiles.email)
--   so an owner whose profile carried no name — an account created outside the app, a name cleared
--   later — had their EMAIL ADDRESS stored as the inviter display name. Every recipient surface then
--   gated that column on the owner's `showInviterName` choice but released its CONTENT unexamined:
--   the invitation email printed "<address> has invited you to …", the token preview and the pending-
--   invitation list returned it as `inviterDisplayName`. The owner had chosen "show my name"; the
--   product disclosed their address. Only the post-acceptance membership cue (0068) sanitized.
--
-- ★ WHAT CHANGES (four function bodies, no table, no grant):
--   · public.create_estate_invitation(…)  — the owner path: stores `safe_inviter_display_name(full_name)`,
--     never the email. A missing or unusable name stores NULL and the invitation is still created.
--   · public.create_invitation(…)         — the console / tooling path: the same rule.
--   · public.invitation_preview(text)     — the link preview releases the name through the sanitizer.
--   · public.resolve_membership(text,text) — the pending-invitation list releases the name through the
--     sanitizer. The body is 0068's with that one branch changed: the membership cue and 0067's
--     verified-contact matching are carried unchanged.
--   Email delivery is enforced in the worker (lib/invitations/delivery.ts + lib/email/invitationTemplate.ts,
--   same deploy): the owner's choice gates, the sanitizer decides, on the immediate attempt and on every
--   queued retry alike, because both run the same orchestrator.
--
-- ★ WHAT DOES NOT CHANGE. The recipient's delivery address (invitee_email / invitee_phone) and its hints;
--   the separate `showEstateName` choice and the estate name; RPC signatures, grants and response shapes;
--   `preview_visibility` as the owner set it; the post-acceptance cue rules of 0068 (bound to this
--   membership, this estate, this caller's own acceptance, released only where shown, sanitized);
--   0067's contact binding. HISTORICAL ROWS ARE NOT REWRITTEN: a row already holding an address keeps
--   it, and every release point now returns NULL for it — the sanitizer is applied on the way out, so
--   no backfill is needed and the audit trail of what was stored stays intact.
--
-- ★ A HIDDEN OR UNUSABLE NAME MEANS NO NAME, NEVER A SUBSTITUTE. No neutral phrase is produced here; the
--   recipient-facing neutral wording ("You have been invited to …", "An estate owner invited you") is
--   the email template's and the client's. NULL on the wire; neutral copy at the surface.
--
-- ★ LANDS AFTER 0067 AND 0068. This file re-creates resolve_membership with 0068's body (which already
--   carries 0067's binding) plus the sanitized pending branch, and it CALLS `safe_inviter_display_name`,
--   which 0068 creates. Apply 0067, 0068, then 0069; applying 0069 first would fail on the missing
--   sanitizer (a loud failure, not a silent one). Re-applying 0069 is a no-op.
--
-- ★ SCHEMA UNCHANGED. Function bodies only. The three that have a db/functions/ mirror
--   (create_invitation, invitation_preview, resolve_membership) are updated there too and held
--   identical by test/inviterNamePrivacy.test.ts; create_estate_invitation has never had a mirror and
--   its latest body is this file (0045 before it).
--
-- ★ ROLLOUT. Safe in either order relative to the API deploy: the worker change only withholds more,
--   the SQL change only withholds more, and neither depends on a client change. The installed mobile
--   clients already sanitize what they render; this closes the surfaces that did not (the email) and
--   stops the address being stored at all for new invitations.
--
-- Idempotent: `create or replace` throughout. Re-apply on any DB reset AFTER the bootstrap, 0067 and 0068.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0 · prerequisites — stop here, before any definition changes, if 0067 or 0068 is missing ──────
-- Every function below either CALLS `safe_inviter_display_name` (0068) or carries 0067's verified-contact
-- matching (`caller_verified_contacts`, `invitation_phone_key`). PL/pgSQL resolves calls at RUN time, so
-- without this check a 0069 pasted over a database missing 0068 would be ACCEPTED and then fail on the
-- first invitation created or previewed. The check names the missing prerequisite and raises, which
-- aborts the paste (the SQL editor runs it as one transaction; psql with ON_ERROR_STOP stops at this
-- statement) before the first `create or replace` runs. Proven in scripts/verifyInviterNamePrivacy.mjs §P.
do $prereq$
declare
  v_missing text := null;
begin
  if to_regprocedure('public.invitation_phone_key(text, boolean)') is null then
    v_missing := '0067 (resolve_membership contact binding): public.invitation_phone_key(text, boolean)';
  elsif to_regprocedure('public.caller_verified_contacts()') is null then
    v_missing := '0067 (resolve_membership contact binding): public.caller_verified_contacts()';
  elsif to_regprocedure('public.safe_inviter_display_name(text)') is null then
    v_missing := '0068 (membership invitation cue): public.safe_inviter_display_name(text)';
  end if;
  if v_missing is not null then
    raise exception '0069_prerequisite_missing: apply migration % before 0069. Nothing has been changed.', v_missing
      using errcode = 'P0001', hint = 'Apply 0067, then 0068, then re-run 0069.';
  end if;
end;
$prereq$;

-- ── 1 · the owner path: create_estate_invitation ──────────────────────────────────────────────────
-- public.create_estate_invitation(p_estate, p_proposed_role, p_invitee_email, p_invitee_phone,
--                                 p_show_estate_name, p_show_inviter_name, p_expires_in_days)
--   -> TABLE(invitation_id uuid, token_fingerprint text, expires_at timestamptz, delivery_state text)
--
-- Body = 0045's (the deployed definition) with ONE change: the inviter name is
-- `safe_inviter_display_name(pr.full_name)`, never `coalesce(nullif(full_name,''), email)`.
-- The 0045 fix (alias-qualified `inv.expires_at`) is kept. Source of truth for this function.

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
  update public.invitations as inv
     set status = 'expired', updated_at = now()
   where inv.estate_id = p_estate and inv.status in ('pending', 'matched') and inv.expires_at <= now();

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
  -- ★ THE INVITER NAME IS A NAME OR NOTHING (0069). The profile full name passes the one server
  --   sanitizer; blank, address-shaped or over-long → NULL. Never the owner's email address: the old
  --   `coalesce(nullif(full_name, ''), email)` persisted an ADDRESS whenever the profile had no name,
  --   and that address was then printed to the recipient wherever the owner had chosen "show my name".
  --   A missing name does not block sending — the invitation simply carries no inviter name.
  select public.safe_inviter_display_name(pr.full_name) into v_inviter_name
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

-- ── 2 · the console / tooling path: create_invitation ─────────────────────────────────────────────
-- public.create_invitation(p_estate, p_kind, p_proposed_role, p_invitee_email, p_invitee_phone,
--                          p_show_estate_name, p_show_inviter_name, p_expires_in_days)
--   -> TABLE(invitation_id uuid, raw_token text, token_fingerprint text, expires_at timestamptz)
--
-- Body = the deployed definition (0021 + the 11-MC comment) with the same ONE change. Also under
-- db/functions/create_invitation.sql.

create or replace function public.create_invitation(
  p_estate uuid, p_kind text, p_proposed_role text,
  p_invitee_email text default null, p_invitee_phone text default null,
  p_show_estate_name boolean default false, p_show_inviter_name boolean default false,
  p_expires_in_days int default 14
)
 returns table(invitation_id uuid, raw_token text, token_fingerprint text, expires_at timestamptz)
 language plpgsql security definer set search_path to 'public', 'extensions'
as $function$
declare
  v_pending int; v_raw text; v_hash text;
  v_estate_name text; v_inviter_name text; v_email_hint text; v_phone_hint text;
  v_expires timestamptz; v_id uuid;
begin
  perform public.invitation_write_gate(p_estate);

  if p_invitee_email is null and p_invitee_phone is null then
    raise exception 'invitee_contact_required' using errcode = 'P0001';
  end if;

  if p_kind not in ('beneficiary','professional_delegate','executor','trustee') then
    raise exception 'kind_not_supported' using errcode = 'P0001';
  end if;
  -- ════════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ PHASE 11-MC — THIS LINE STAYS, AND IT IS NOW INERT. BOTH HALVES OF THAT MATTER.
  -- ════════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- WHY IT CANNOT BE REMOVED: `invitations.proposed_role` is `text NOT NULL` with
  -- `check (proposed_role = any (array['beneficiary','professional_delegate']))`. There is no value that
  -- honestly means "no access class", and inventing one is DDL on a live table plus a migration. So an
  -- executor/trustee invitation must still persist one of two disclosure-class words it does not mean.
  --
  -- WHY REMOVING IT WOULD HAVE BEEN WORSE THAN LEAVING IT: the defect was never this value. It was that
  -- `provision_from_invitation` created a membership AT this value for every acceptance. Drop the force
  -- and an executor invitation minted with `p_proposed_role = 'professional_delegate'` would have
  -- provisioned a PROFESSIONAL DELEGATE membership instead — a different manufactured disclosure class,
  -- and a worse one, because nothing in the product expects a fiduciary to arrive as a delegate.
  --
  -- WHERE THE FIX ACTUALLY LIVES: `provision_from_invitation` now gates membership creation on `kind`,
  -- the authoritative and immutable statement of what the invitation is. That also fixes every
  -- OUTSTANDING invitation — this column is written at CREATE time, so rows minted before the correction
  -- already carry 'beneficiary', and a provisioner keyed on `proposed_role` would have kept honouring it
  -- forever.
  --
  -- WHAT IT STILL AFFECTS: nothing in provisioning. It remains visible as `proposedRole` in
  -- `resolve_membership`'s pending-invitation payload, where the client maps it to a presentation-only
  -- `accessClass` label — `features/invitations/model.ts` states outright that nothing gates on it. So a
  -- fiduciary invitation card can still show the wrong relationship WORD. That is a real accuracy defect
  -- and it is recorded rather than silently tolerated: fixing it means surfacing `kind` in that payload,
  -- which is a separate backend+client slice. Making the column nullable belongs with it.
  if p_kind in ('executor','trustee') then
    p_proposed_role := 'beneficiary';
  elsif p_proposed_role not in ('beneficiary','professional_delegate') then
    raise exception 'invalid_proposed_role' using errcode = 'P0001';
  end if;

  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001';
  end if;

  select count(*) into v_pending from public.invitations inv
  where inv.estate_id = p_estate and inv.status in ('pending','matched') and inv.expires_at > now();
  if v_pending >= 20 then raise exception 'pending_invitation_cap' using errcode = 'P0001'; end if;

  select e.name into v_estate_name from public.estates e where e.id = p_estate;
  -- ★ THE INVITER NAME IS A NAME OR NOTHING (0069) — the same rule as create_estate_invitation. Blank,
  --   address-shaped or over-long → NULL; never the inviter's email address; never blocks the mint.
  select public.safe_inviter_display_name(p.full_name) into v_inviter_name from public.profiles p where p.id = auth.uid();
  v_email_hint := case when p_invitee_email is not null
    then left(p_invitee_email,1) || '•••@' || split_part(p_invitee_email,'@',2) else null end;
  v_phone_hint := case when p_invitee_phone is not null then '•••' || right(p_invitee_phone,4) else null end;
  v_raw := encode(gen_random_bytes(32), 'hex'); v_hash := encode(digest(v_raw, 'sha256'), 'hex');
  v_expires := now() + make_interval(days => p_expires_in_days);

  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at, invitee_email, invitee_phone,
     invitee_email_hint, invitee_phone_hint, estate_display_name, inviter_display_name, preview_visibility,
     token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), p_estate, auth.uid(), p_kind, p_proposed_role, 'pending', v_expires,
     p_invitee_email, p_invitee_phone, v_email_hint, v_phone_hint, v_estate_name, v_inviter_name,
     jsonb_build_object('showEstateName', p_show_estate_name, 'showInviterName', p_show_inviter_name),
     v_hash, now(), now())
  returning id into v_id;

  perform public.write_audit('invitation.created', 'invitations', v_id, p_estate,
    jsonb_build_object('invitation_id', v_id, 'kind', p_kind, 'proposed_role', p_proposed_role,
                       'token_fingerprint', substr(v_hash,1,12), 'expires_at', v_expires,
                       'invitee_email_hint', v_email_hint));
  return query select v_id, v_raw, substr(v_hash,1,12), v_expires;
end;
$function$;
revoke execute on function public.create_invitation(uuid,text,text,text,text,boolean,boolean,int) from public, anon;
grant  execute on function public.create_invitation(uuid,text,text,text,text,boolean,boolean,int) to authenticated;

-- ── 3 · the link preview: invitation_preview ──────────────────────────────────────────────────────
-- public.invitation_preview(p_token text) -> TABLE(…, inviter_display_name text, …)
--
-- Unauthenticated, token-bound. The owner's `showInviterName` still gates the release; the released
-- value now passes `safe_inviter_display_name`, so a legacy row holding an address returns NULL. The
-- estate-name gate is untouched. Also under db/functions/invitation_preview.sql. Grant unchanged (anon).

create or replace function public.invitation_preview(p_token text)
 returns table(token_fingerprint text, invitation_kind text, proposed_role text, estate_display_name text, inviter_display_name text, invitee_email_hint text, invitee_phone_hint text, expires_at timestamp with time zone, is_expired boolean, is_revoked boolean)
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_hash text;
  v_fp text;
  v_inv record;
begin
  -- Validate input shape early to avoid spending DB time on garbage.
  if p_token is null or length(p_token) < 16 or length(p_token) > 512 then
    return;
  end if;

  v_hash := encode(digest(p_token, 'sha256'), 'hex');

  -- Use first 12 hex chars to match iOS fingerprint length.
  -- The iOS InvitationToken.fingerprint uses SHA256 truncated to 12 chars.
  v_fp := substr(v_hash, 1, 12);

  select * into v_inv
  from public.invitations
  where token_hash = v_hash
  limit 1;

  if not found then
    return; -- empty result set; do not leak existence
  end if;

  return query select
    v_fp,
    v_inv.kind::text,
    v_inv.proposed_role::text,
    case when (v_inv.preview_visibility->>'showEstateName')::boolean is true
         then v_inv.estate_display_name else null end,
    -- ★ 0069: the owner's choice gates WHETHER a name is released; the sanitizer decides whether the
    --   stored value IS one. A legacy row holding an address releases NULL here, as it does everywhere.
    case when (v_inv.preview_visibility->>'showInviterName')::boolean is true
         then public.safe_inviter_display_name(v_inv.inviter_display_name) else null end,
    v_inv.invitee_email_hint,
    v_inv.invitee_phone_hint,
    v_inv.expires_at,
    (v_inv.expires_at < now()),
    (v_inv.status = 'revoked');
end;
$function$;
grant execute on function public.invitation_preview(text) to anon;

-- ── 4 · the pending-invitation list: resolve_membership ──────────────────────────────────────────
-- public.resolve_membership(p_email text, p_phone text) -> jsonb
--
-- 0068's body — the membership cue on additional contexts AND 0067's verified-contact matching of the
-- pending list — with ONE change: the pending list's `inviterDisplayName` passes
-- `safe_inviter_display_name`, exactly as the cue already did. Also under db/functions/resolve_membership.sql.

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
    -- ★ 0069: sanitized here too — the acceptance screen must never print an address that a legacy row
    --   stored as the inviter "name". The owner's choice still gates the release; NULL means no name.
    'inviterDisplayName',
      case when (i.preview_visibility->>'showInviterName')::boolean
           then public.safe_inviter_display_name(i.inviter_display_name) else null end,
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
    'isPrimaryEstate', false,
    -- The invitation cue (header note): bound to THIS membership, THIS estate and THIS caller's own
    -- acceptance, released only where the recipient already saw it, sanitized before serialization.
    -- A scalar subquery with no matching row is NULL — unlinked, mismatched and hidden all read as
    -- "no cue" without a branch per cause.
    'inviterDisplayName', (
      select public.safe_inviter_display_name(i.inviter_display_name)
        from public.invitations i
       where i.id = m.source_invitation_id
         and i.estate_id = m.estate_id
         and i.accepted_by = v_user
         and i.status = 'accepted'
         and coalesce((i.preview_visibility->>'showInviterName')::boolean, false)
    )
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
