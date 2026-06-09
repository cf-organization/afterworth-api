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

  -- Pending invitations matching the user's email or phone.
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
      (p_email is not null
       and i.invitee_email is not null
       and lower(i.invitee_email) = lower(p_email))
      or
      (p_phone is not null
       and i.invitee_phone is not null
       and i.invitee_phone = p_phone)
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
