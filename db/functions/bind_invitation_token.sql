-- public.bind_invitation_token(p_token text)
--   -> TABLE(membership_id uuid, estate_id uuid, estate_display_name text,
--            role text, status text)
--
-- Binds the authenticated caller to an invitation by its plaintext token:
-- hashes the token, looks up the invitation, verifies it is for this caller
-- (email/phone match against profiles), and inserts an approved membership.
-- Idempotent: re-binding by the same caller returns the existing membership
-- row rather than raising.
--
-- Error codes (mapped to HTTP in api/invitations/bind.ts):
--   42501 unauthenticated, P0001 invalid_token, P0002 not_found,
--   P0003 expired, P0004 revoked, P0005 already_accepted (by someone else),
--   P0006 not_for_caller.
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

CREATE OR REPLACE FUNCTION public.bind_invitation_token(p_token text)
 RETURNS TABLE(membership_id uuid, estate_id uuid, estate_display_name text, role text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_user uuid := auth.uid();
  v_hash text;
  v_inv record;
  v_user_email text;
  v_user_phone text;
  v_membership_id uuid;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  if p_token is null or length(p_token) < 16 or length(p_token) > 512 then
    raise exception 'invalid_token' using errcode = 'P0001';
  end if;

  v_hash := encode(digest(p_token, 'sha256'), 'hex');

  select * into v_inv
  from public.invitations
  where token_hash = v_hash
  for update;

  if not found then
    raise exception 'invitation_not_found' using errcode = 'P0002';
  end if;

  if v_inv.expires_at < now() then
    raise exception 'invitation_expired' using errcode = 'P0003';
  end if;

  if v_inv.status = 'revoked' then
    raise exception 'invitation_revoked' using errcode = 'P0004';
  end if;

  select profiles.email, profiles.phone into v_user_email, v_user_phone
  from public.profiles
  where profiles.id = v_user;

  if not (
    (v_inv.invitee_email is not null
     and lower(v_inv.invitee_email) = lower(coalesce(v_user_email, '')))
    or
    (v_inv.invitee_phone is not null
     and v_inv.invitee_phone = coalesce(v_user_phone, ''))
  ) then
    raise exception 'invitation_not_for_caller' using errcode = 'P0006';
  end if;

  if v_inv.status = 'accepted' then
    select em.id into v_membership_id
    from public.estate_memberships em
    where em.estate_id = v_inv.estate_id
      and em.user_id = v_user
      and em.source_invitation_id = v_inv.id;

    if found then
      return query
        select
          v_membership_id,
          v_inv.estate_id,
          (select e.name from public.estates e where e.id = v_inv.estate_id),
          v_inv.proposed_role::text,
          'approved'::text;
      return;
    else
      raise exception 'invitation_already_accepted'
        using errcode = 'P0005';
    end if;
  end if;

  update public.invitations
     set status = 'accepted',
         accepted_by = v_user,
         accepted_at = now(),
         updated_at = now()
   where id = v_inv.id;

  insert into public.estate_memberships
    (id, estate_id, user_id, role, status, source_invitation_id,
     approved_at, created_at)
  values
    (gen_random_uuid(),
     v_inv.estate_id,
     v_user,
     v_inv.proposed_role,
     'approved',
     v_inv.id,
     now(),
     now())
  returning estate_memberships.id into v_membership_id;

  perform public.write_audit(
    'invitation.bound',
    'estate_memberships',
    v_membership_id,
    v_inv.estate_id,
    jsonb_build_object(
      'token_fingerprint', substr(v_hash, 1, 12),
      'invitation_id', v_inv.id
    )
  );

  return query
    select
      v_membership_id,
      v_inv.estate_id,
      (select e.name from public.estates e where e.id = v_inv.estate_id),
      v_inv.proposed_role::text,
      'approved'::text;
end;
$function$;
