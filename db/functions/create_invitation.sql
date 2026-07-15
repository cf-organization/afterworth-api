-- public.create_invitation(p_estate, p_kind, p_proposed_role, p_invitee_email, p_invitee_phone,
--                          p_show_estate_name, p_show_inviter_name, p_expires_in_days)
--   -> TABLE(invitation_id uuid, raw_token text, token_fingerprint text, expires_at timestamptz)
--
-- Owner-OR-admin mints an invitation (invitation_write_gate). Returns the raw token ONCE. 0021 LIFTED the
-- executor/trustee rejection: kind now allows all four, and for executor/trustee proposed_role is DERIVED
-- to 'beneficiary' — the GENERIC access-class membership (fiduciary authority lives ONLY in
-- estate_designations, stamped at accept, NEVER the membership role). Pending-cap ≤20 active per estate.
-- Captured from live 2026-07-15 (previously VC-only in migration 0016). SECURITY DEFINER.

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

  -- kind allows all four; executor/trustee take the GENERIC 'beneficiary' access-class membership (derive it).
  if p_kind not in ('beneficiary','professional_delegate','executor','trustee') then
    raise exception 'kind_not_supported' using errcode = 'P0001';
  end if;
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
  select coalesce(nullif(p.full_name,''), p.email) into v_inviter_name from public.profiles p where p.id = auth.uid();
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
