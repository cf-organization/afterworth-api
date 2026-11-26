-- public.resolve_membership(p_email text, p_phone text) -> jsonb
--
-- Resolves the authenticated caller's membership context: their primary estate
-- (bootstrapped on first call if none exists), pending invitations matching
-- their email/phone, and additional (non-owned) estate memberships.
--
-- Each estate context includes ownerUserId (estates.owner_id) so the iOS legacy
-- estate-context layer has the real owner for both owned and beneficiary contexts.
--
-- ★ THE INVITATION CUE (2026-11-25). Each ADDITIONAL context (an approved, non-owned membership)
-- carries an optional, nullable `inviterDisplayName`: the safe inviter display name from the one
-- invitation THIS caller accepted to obtain THIS membership — an invitation cue, not a claim about
-- the estate's current owner. Why: every bootstrapped estate is named "My Estate", so a recipient
-- holding two memberships with the same role in two such estates had nothing to tell them apart
-- (mobile #221). The cue is released only when ALL of the following hold, otherwise it is NULL:
--   · the membership's `source_invitation_id` links an invitation (a reconciled membership has none);
--   · that invitation is for the SAME estate and was ACCEPTED BY THIS CALLER (`accepted_by = v_user`,
--     status 'accepted') — a mismatched or borrowed link releases nothing;
--   · the owner chose to show the inviter name at invitation time (`preview_visibility.showInviterName`),
--     i.e. the recipient already saw it on the acceptance screen — this re-releases, never discloses;
--   · the stored value passes `safe_inviter_display_name` (blank / email-shaped / over-long → NULL).
-- Never substituted from a profile, never an approval date, contact detail, nickname or id. Two
-- memberships may legitimately carry the SAME safe name; the server never manufactures a difference.
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
--
-- ★ 0069 (2026-11-26): the pending list's `inviterDisplayName` passes `safe_inviter_display_name` exactly as the
-- membership cue already did; the cue rules and the contact binding are unchanged. Body identical to 0069.

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
