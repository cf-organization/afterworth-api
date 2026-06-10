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
end;
$function$;
