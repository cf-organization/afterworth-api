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

  select profiles.email, profiles.phone into v_user_email, v_user_phone from public.profiles where profiles.id = v_user;
  if not ((v_inv.invitee_email is not null and lower(v_inv.invitee_email) = lower(coalesce(v_user_email,'')))
       or (v_inv.invitee_phone is not null and v_inv.invitee_phone = coalesce(v_user_phone,''))) then
    raise exception 'invitation_not_for_caller' using errcode = 'P0006';
  end if;

  -- Idempotency keys on the invitation's OWN accepted_by (authoritative), NOT the membership's
  -- source_invitation_id (see accept_invitation) — a reconciled membership has a different/NULL source.
  if v_inv.status = 'accepted' then
    if v_inv.accepted_by = v_user then
      perform public.provision_from_invitation(v_inv.id, v_user);   -- idempotent self-heal (re-stamps a missing designation)
      select em.id into v_membership_id from public.estate_memberships em
       where em.estate_id = v_inv.estate_id and em.user_id = v_user;
      return query select v_membership_id, v_inv.estate_id,
        (select e.name from public.estates e where e.id = v_inv.estate_id), v_inv.proposed_role::text, 'approved'::text;
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
    (select e.name from public.estates e where e.id = v_inv.estate_id), v_inv.proposed_role::text, 'approved'::text;
end;
$function$;
