-- 0016_20260710_invitation_lifecycle — owner-OR-admin invitation create / revoke / extend RPCs.
--
-- Closes the "invitation creation is 100% manual" gap (Slice 2). Client-reachable via PostgREST
-- rpc/ (no Vercel endpoint this slice — the console is the first client; iOS adopts create later),
-- so the gate lives INSIDE each function. lib/rateLimit.ts (Vercel enforce()) does NOT cover the
-- PostgREST door, so create carries a DB-resident pending-cap as the abuse throttle.
--
-- The create RPC writes exactly what the consume side reads (invitation_preview / bind / accept /
-- resolve_membership): token_hash (sha256-hex), kind/proposed_role, invitee_email/phone + masked
-- hints, estate/inviter display names, preview_visibility, expires_at. The raw token is returned
-- ONCE and never stored or logged (only its sha256-hex hash + a 12-char fingerprint).

begin;

-- Shared gate (internal): auth -> (owner OR admin). Owner writes are aal1 (matches the in-app
-- posture — do not silently raise). Admin (non-owner) writes take the uniform Slice-1 admin posture:
-- aal2 + 15-min iat freshness.
create or replace function public.invitation_write_gate(p_estate uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not (public.is_estate_owner(p_estate) or public.is_admin()) then
    raise exception 'owner_or_admin_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    -- admin (non-owner) branch
    perform public.require_aal2();
    if extract(epoch from now())::bigint - coalesce((auth.jwt() ->> 'iat')::bigint, 0) > 900 then
      raise exception 'stale_token_reauth_required' using errcode = '42501';
    end if;
  end if;
end;
$function$;
revoke execute on function public.invitation_write_gate(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- create_invitation — mint a pending invitation; returns the raw token ONCE.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.create_invitation(
  p_estate            uuid,
  p_kind              text,
  p_proposed_role     text,
  p_invitee_email     text    default null,
  p_invitee_phone     text    default null,
  p_show_estate_name  boolean default false,
  p_show_inviter_name boolean default false,
  p_expires_in_days   int     default 14
)
 returns table(invitation_id uuid, raw_token text, token_fingerprint text, expires_at timestamptz)
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_pending int;
  v_raw text; v_hash text;
  v_estate_name text; v_inviter_name text;
  v_email_hint text; v_phone_hint text;
  v_expires timestamptz; v_id uuid;
begin
  perform public.invitation_write_gate(p_estate);

  if p_invitee_email is null and p_invitee_phone is null then
    raise exception 'invitee_contact_required' using errcode = 'P0001';
  end if;
  if p_kind not in ('beneficiary','professional_delegate')
     or p_proposed_role not in ('beneficiary','professional_delegate') then
    raise exception 'kind_not_yet_supported' using errcode = 'P0001';   -- executor/trustee deferred
  end if;
  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001';
  end if;

  -- pending-cap: only ACTIVE (pending/matched AND not yet expired) invitations count -> an aged-out
  -- slot frees the cap. Soft throttle (a minor concurrent race is acceptable pre-launch).
  -- qualify columns: `expires_at` is also an OUT column of this function (RETURNS TABLE), so a bare
  -- reference here is ambiguous (42702). Alias the table.
  select count(*) into v_pending
  from public.invitations inv
  where inv.estate_id = p_estate and inv.status in ('pending','matched') and inv.expires_at > now();
  if v_pending >= 20 then
    raise exception 'pending_invitation_cap' using errcode = 'P0001';
  end if;

  select e.name into v_estate_name from public.estates e where e.id = p_estate;
  select coalesce(nullif(p.full_name,''), p.email) into v_inviter_name
  from public.profiles p where p.id = auth.uid();

  -- masked hints (locked conventions): email = first-char + ••• + domain; phone = ••• + last 4 (NEW).
  v_email_hint := case when p_invitee_email is not null
    then left(p_invitee_email,1) || '•••@' || split_part(p_invitee_email,'@',2) else null end;
  v_phone_hint := case when p_invitee_phone is not null
    then '•••' || right(p_invitee_phone,4) else null end;

  -- token: 256-bit -> 64-char hex (within bind/preview's 16..512). Store only the sha256-hex hash.
  v_raw     := encode(gen_random_bytes(32), 'hex');
  v_hash    := encode(digest(v_raw, 'sha256'), 'hex');
  v_expires := now() + make_interval(days => p_expires_in_days);

  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_phone, invitee_email_hint, invitee_phone_hint,
     estate_display_name, inviter_display_name, preview_visibility, token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), p_estate, auth.uid(), p_kind, p_proposed_role, 'pending', v_expires,
     p_invitee_email, p_invitee_phone, v_email_hint, v_phone_hint,
     v_estate_name, v_inviter_name,
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

-- ---------------------------------------------------------------------------------------------------
-- revoke_invitation — pending/matched -> revoked; idempotent on already-revoked.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.revoke_invitation(p_invitation_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_inv record;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select * into v_inv from public.invitations where id = p_invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;
  perform public.invitation_write_gate(v_inv.estate_id);

  if v_inv.status = 'revoked' then return; end if;                         -- idempotent
  if v_inv.status not in ('pending','matched') then
    raise exception 'cannot_revoke_%', v_inv.status using errcode = 'P0005';  -- e.g. accepted/declined
  end if;

  update public.invitations set status = 'revoked', updated_at = now() where id = v_inv.id;
  perform public.write_audit('invitation.revoked', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'prior_status', v_inv.status));
end;
$function$;
revoke execute on function public.revoke_invitation(uuid) from public, anon;
grant  execute on function public.revoke_invitation(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- extend_invitation — pending/matched only; new expiry = now()+days, capped at created_at + 90d.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.extend_invitation(p_invitation_id uuid, p_expires_in_days int default 14)
 returns table(invitation_id uuid, expires_at timestamptz)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_inv record; v_new timestamptz;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001'; end if;
  select * into v_inv from public.invitations where id = p_invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;
  perform public.invitation_write_gate(v_inv.estate_id);

  if v_inv.status not in ('pending','matched') then
    raise exception 'cannot_extend_%', v_inv.status using errcode = 'P0005'; end if;
  if v_inv.created_at + interval '90 days' <= now() then
    raise exception 'invitation_lifetime_exceeded' using errcode = 'P0003'; end if;  -- mint a new one

  v_new := least(now() + make_interval(days => p_expires_in_days), v_inv.created_at + interval '90 days');
  update public.invitations set expires_at = v_new, updated_at = now() where id = v_inv.id;
  perform public.write_audit('invitation.extended', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'old_expires_at', v_inv.expires_at, 'new_expires_at', v_new));
  return query select v_inv.id, v_new;
end;
$function$;
revoke execute on function public.extend_invitation(uuid,int) from public, anon;
grant  execute on function public.extend_invitation(uuid,int) to authenticated;

commit;
