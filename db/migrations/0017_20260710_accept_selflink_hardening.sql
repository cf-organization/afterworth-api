-- 0017_20260710_accept_selflink_hardening — fix the beneficiary self-link OR-decouple flaw.
--
-- LATENT FLAW (found in the Slice-2 stamping trace; NOT the cause of fixture #1, which was a manual
-- seed artifact): accept_invitation's self-link stamped beneficiaries.user_id onto rows matched by
-- the INVITATION's invitee_email OR invitee_phone — decoupled from the accepting caller's own
-- identity. The P0006 guard also passes on email OR phone. So a caller who authed via ONE identifier
-- (say phone) could be stamped onto a designation matched on the OTHER (say email) — a different
-- person's row. Reachable on every beneficiary accept (both the fresh and the self-heal branches).
--
-- FIX (both self-link sites): TRIPLE-EQUALITY — a designation row is stamped only when its matching
-- identifier equals BOTH the invitation's invitee AND the caller's own profile contact (v_user_email
-- / v_user_phone, already loaded at the top). The legitimate same-identifier stamp is unchanged; a
-- cross-identifier stamp can no longer occur.
--
-- ALSO FIXED (pre-existing latent bug, surfaced by the hardening test): the self-link's bare
-- `where estate_id = v_inv.estate_id` collides with this function's RETURNS TABLE OUT column
-- `estate_id` (42702 "column reference estate_id is ambiguous"). It never fired in production because
-- NO beneficiary had ever accepted via the accept-by-id path (every beneficiary membership was seeded,
-- source_invitation_id NULL). Both self-link WHEREs now qualify the `beneficiaries.*` columns.
--
-- CREATE-OR-REPLACE of an existing live function — base confirmed live == VC (0016 gate drift check)
-- before overwriting. Only the two WHERE predicates change; everything else is the current body.

begin;

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

  if v_inv.status = 'accepted' then
    select em.id into v_membership_id
    from public.estate_memberships em
    where em.estate_id = v_inv.estate_id
      and em.user_id = v_user
      and em.source_invitation_id = v_inv.id;

    if found then
      -- Self-heal self-link (HARDENED: triple-equality — row identifier matches the invitation's
      -- invitee AND the caller's own profile contact).
      if v_inv.proposed_role::text = 'beneficiary' then
        update public.beneficiaries
           set user_id = v_user
         where beneficiaries.estate_id = v_inv.estate_id
           and beneficiaries.user_id is null
           and (
             (v_inv.invitee_email is not null and v_user_email is not null
              and lower(beneficiaries.email) = lower(v_inv.invitee_email)
              and lower(beneficiaries.email) = lower(v_user_email))
             or
             (v_inv.invitee_phone is not null and v_user_phone is not null
              and beneficiaries.phone = v_inv.invitee_phone
              and beneficiaries.phone = v_user_phone)
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

  -- Fresh self-link (HARDENED: triple-equality — see the self-heal branch above).
  if v_inv.proposed_role::text = 'beneficiary' then
    update public.beneficiaries
       set user_id = v_user
     where beneficiaries.estate_id = v_inv.estate_id
       and beneficiaries.user_id is null
       and (
         (v_inv.invitee_email is not null and v_user_email is not null
          and lower(beneficiaries.email) = lower(v_inv.invitee_email)
          and lower(beneficiaries.email) = lower(v_user_email))
         or
         (v_inv.invitee_phone is not null and v_user_phone is not null
          and beneficiaries.phone = v_inv.invitee_phone
          and beneficiaries.phone = v_user_phone)
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

commit;
