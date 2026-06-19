-- public.accept_invitation(p_invitation_id uuid)
--   -> TABLE(membership_id uuid, estate_id uuid, estate_display_name text,
--            role text, status text)
--
-- Accepts an invitation BY ID (not token). Used by the in-app "matched
-- invitations" screen, where the user was matched to an invitation by email
-- and has the invitation id but no token. Mirrors bind_invitation_token: same
-- invitee email/phone guard, same membership insert, idempotent, audited.
--
-- Security: knowing an invitation id is NOT sufficient. The caller's email/phone
-- (from profiles) must match the invitation's invitee_email/invitee_phone, the
-- same guard bind uses. This prevents accepting an invitation addressed to
-- someone else.
--
-- Beneficiary self-link: when proposed_role = 'beneficiary', after the membership
-- is created this also stamps the matching public.beneficiaries designation row(s)
-- with the accepting user (user_id = auth.uid()), matched by invitee_email/phone
-- within the estate. This is what lets the beneficiaries RLS read policy show a
-- beneficiary only their OWN row. Tolerates zero matches (a designation row need
-- not exist) and only stamps still-unlinked rows, so re-accepting self-heals an
-- acceptance that predated this linkage.
--
-- Error codes (mapped to HTTP in api/invitations/accept.ts):
--   42501 unauthenticated, P0002 not_found, P0003 expired, P0004 revoked,
--   P0005 already_accepted (by someone else), P0006 not_for_caller,
--   P0007 declined (invitation was already declined; cannot accept).
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

CREATE OR REPLACE FUNCTION public.accept_invitation(p_invitation_id uuid)
 RETURNS TABLE(membership_id uuid, estate_id uuid, estate_display_name text, role text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_user uuid := auth.uid();
  v_inv record;
  v_user_email text;
  v_user_phone text;
  v_membership_id uuid;
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

  if v_inv.expires_at < now() then
    raise exception 'invitation_expired' using errcode = 'P0003';
  end if;

  if v_inv.status = 'revoked' then
    raise exception 'invitation_revoked' using errcode = 'P0004';
  end if;

  if v_inv.status = 'declined' then
    raise exception 'invitation_declined' using errcode = 'P0007';
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

  -- Idempotency: if already accepted, return the caller's existing membership
  -- rather than inserting a duplicate. If it was accepted but no membership for
  -- this caller exists, it was accepted by someone else — reject.
  if v_inv.status = 'accepted' then
    select em.id into v_membership_id
    from public.estate_memberships em
    where em.estate_id = v_inv.estate_id
      and em.user_id = v_user
      and em.source_invitation_id = v_inv.id;

    if found then
      -- Self-heal: an earlier acceptance may predate the beneficiary self-link
      -- (or the link was added afterwards). If this is a beneficiary invitation
      -- and the designation row is still unlinked, stamp it now. No-op once set.
      if v_inv.proposed_role::text = 'beneficiary' then
        update public.beneficiaries
           set user_id = v_user
         where estate_id = v_inv.estate_id
           and user_id is null
           and (
             (v_inv.invitee_email is not null
              and lower(email) = lower(v_inv.invitee_email))
             or
             (v_inv.invitee_phone is not null
              and phone = v_inv.invitee_phone)
           );
      end if;

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

  -- Beneficiary self-link: stamp the matching designation row(s) with the
  -- accepting user so the beneficiaries RLS read policy (user_id = auth.uid())
  -- shows this beneficiary only their OWN row. Matched by contact within the
  -- estate (invitations carry no beneficiary_id). Only still-unlinked rows are
  -- stamped; zero matches is fine — a designation row need not exist.
  if v_inv.proposed_role::text = 'beneficiary' then
    update public.beneficiaries
       set user_id = v_user
     where estate_id = v_inv.estate_id
       and user_id is null
       and (
         (v_inv.invitee_email is not null
          and lower(email) = lower(v_inv.invitee_email))
         or
         (v_inv.invitee_phone is not null
          and phone = v_inv.invitee_phone)
       );
  end if;

  perform public.write_audit(
    'invitation.accepted',
    'estate_memberships',
    v_membership_id,
    v_inv.estate_id,
    jsonb_build_object(
      'invitation_id', v_inv.id,
      'via', 'accept_by_id'
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
