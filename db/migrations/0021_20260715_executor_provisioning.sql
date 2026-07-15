-- 0021_20260715_executor_provisioning — create-side lift + SHARED provisioning helper + both accept paths.
--
-- Lets someone BECOME an executor/trustee. LOCKED design (Option ii — shared helper, REQUIRED):
--   * A shared DEFINER helper provision_from_invitation(invitation_id, user_id) holds the post-status
--     provisioning: membership-reconcile + beneficiary self-link (triple-equality) + executor/trustee
--     designation stamp + audit. BOTH accept_invitation AND bind_invitation_token call it — so a
--     bind-accepted executor can NEVER end up membership-without-designation (a silent authority void), and
--     the pre-existing bind beneficiary-self-link asymmetry is fixed too.
--   * Executor/trustee accept writes TWO rows: an estate_membership with the GENERIC access-class
--     role='beneficiary' (nav/RLS/messaging/audit ONLY) + an estate_designations row (the SOLE fiduciary
--     truth). Executor authority is NEVER inferred from membership role. Membership role CHECK NOT extended.
--   * create_invitation stops rejecting executor/trustee and DERIVES proposed_role='beneficiary' for them.
--   * Idempotency: membership ON CONFLICT (estate_id,user_id) DO NOTHING (reconcile, don't duplicate — an
--     executor may already be a beneficiary member); designation ON CONFLICT (partial-unique-on-active) DO
--     NOTHING; audit designation.created ONLY when actually inserted (no re-audit on double-accept).
--   * Verification: NO-OP seam (per-claim, Reading A; an external call would break tx atomicity).
--
-- REGRESSION obligation (proven in the matrix): a beneficiary accept/bind still yields the SAME membership +
-- status + invitation.accepted/.bound audit; the ONLY change to bind is the ADDED beneficiary self-link (the
-- asymmetry fix). CLObber: the accept/create clobber-diff confirmed live == the pre-0021 VC bodies; run the
-- bind clobber-diff before applying.

begin;

-- ==================================================================================================
-- provision_from_invitation — SHARED, idempotent provisioning (INTERNAL: DEFINER callers only). Assumes the
-- caller has already locked the invitation FOR UPDATE and run the status + P0006 identity guards.
-- ==================================================================================================
create or replace function public.provision_from_invitation(p_invitation_id uuid, p_user uuid)
 returns uuid   -- the reconciled estate_memberships.id
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_inv record;
  v_membership_id uuid;
  v_desig_id uuid;
begin
  select * into v_inv from public.invitations where id = p_invitation_id;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- Membership reconcile: idempotent via UNIQUE(estate_id,user_id). Reuse an existing membership (e.g. an
  -- executor who is already a beneficiary member) rather than duplicating.
  insert into public.estate_memberships
    (id, estate_id, user_id, role, status, source_invitation_id, approved_at, created_at)
  values
    (gen_random_uuid(), v_inv.estate_id, p_user, v_inv.proposed_role, 'approved', v_inv.id, now(), now())
  on conflict (estate_id, user_id) do nothing
  returning id into v_membership_id;
  if v_membership_id is null then
    select em.id into v_membership_id from public.estate_memberships em
     where em.estate_id = v_inv.estate_id and em.user_id = p_user;
  end if;

  -- Beneficiary self-link (triple-equality) — now shared by BOTH accept and bind (fixes the bind asymmetry).
  -- Stamp still-unlinked designation rows whose contact matches the invitation invitee; zero matches is fine.
  if v_inv.proposed_role::text = 'beneficiary' then
    update public.beneficiaries set user_id = p_user
     where estate_id = v_inv.estate_id and user_id is null
       and ((v_inv.invitee_email is not null and lower(email) = lower(v_inv.invitee_email))
            or (v_inv.invitee_phone is not null and phone = v_inv.invitee_phone));
  end if;

  -- Executor/trustee designation — the SOLE source of fiduciary truth (NEVER the membership role).
  if v_inv.kind in ('executor','trustee') then
    v_desig_id := null;
    insert into public.estate_designations
      (estate_id, user_id, designation_type, status, source_invitation_id, granted_by)
    values (v_inv.estate_id, p_user, v_inv.kind, 'active', v_inv.id, v_inv.invited_by)
    on conflict (estate_id, user_id, designation_type) where status = 'active' do nothing
    returning id into v_desig_id;
    if v_desig_id is not null then
      perform public.write_audit('designation.created', 'estate_designations', v_desig_id, v_inv.estate_id,
        jsonb_build_object('invitation_id', v_inv.id, 'designation_type', v_inv.kind));
    end if;
    -- VERIFICATION HOOK (NO-OP): per-claim verification (Reading A) attaches here later; no external call.
  end if;

  return v_membership_id;
end;
$function$;
revoke execute on function public.provision_from_invitation(uuid, uuid) from public, anon, authenticated;

-- ==================================================================================================
-- create_invitation — lift executor/trustee; derive proposed_role='beneficiary' for them.
-- ==================================================================================================
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

  -- LIFTED: kind now allows all four. Executor/trustee take the GENERIC 'beneficiary' access-class membership
  -- (fiduciary authority lives ONLY in estate_designations, stamped at accept), so DERIVE proposed_role.
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

-- ==================================================================================================
-- accept_invitation — caller: status + P0006 guards + idempotency; delegate provisioning to the helper.
-- ==================================================================================================
create or replace function public.accept_invitation(p_invitation_id uuid)
 returns table(membership_id uuid, estate_id uuid, estate_display_name text, role text, status text)
 language plpgsql security definer set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid();
  v_inv record; v_user_email text; v_user_phone text; v_membership_id uuid;
begin
  if v_user is null then raise exception 'unauthenticated' using errcode = '42501'; end if;
  select * into v_inv from public.invitations where id = p_invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;
  if v_inv.expires_at < now() then raise exception 'invitation_expired' using errcode = 'P0003'; end if;
  if v_inv.status = 'revoked' then raise exception 'invitation_revoked' using errcode = 'P0004'; end if;
  if v_inv.status = 'declined' then raise exception 'invitation_declined' using errcode = 'P0007'; end if;

  -- P0006 identity guard — kept in the caller, BEFORE idempotency, to preserve P0006-before-P0005 ordering.
  select profiles.email, profiles.phone into v_user_email, v_user_phone from public.profiles where profiles.id = v_user;
  if not ((v_inv.invitee_email is not null and lower(v_inv.invitee_email) = lower(coalesce(v_user_email,'')))
       or (v_inv.invitee_phone is not null and v_inv.invitee_phone = coalesce(v_user_phone,''))) then
    raise exception 'invitation_not_for_caller' using errcode = 'P0006';
  end if;

  -- Idempotency keys on the invitation's OWN accepted_by (authoritative), NOT the membership's
  -- source_invitation_id: a reconciled membership (an executor who was already a beneficiary member) has a
  -- different/NULL source, so keying on source would (a) spuriously P0005 a same-user re-accept AND (b)
  -- NEVER self-heal a missing designation — the silent-authority-void the shared helper exists to prevent.
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
  perform public.write_audit('invitation.accepted', 'estate_memberships', v_membership_id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'via', 'accept_by_id'));
  return query select v_membership_id, v_inv.estate_id,
    (select e.name from public.estates e where e.id = v_inv.estate_id), v_inv.proposed_role::text, 'approved'::text;
end;
$function$;

-- ==================================================================================================
-- bind_invitation_token — same spine (token lookup; no P0007); delegate provisioning to the helper. The
-- beneficiary self-link is now applied here too (via the helper) — the asymmetry fix.
-- ==================================================================================================
create or replace function public.bind_invitation_token(p_token text)
 returns table(membership_id uuid, estate_id uuid, estate_display_name text, role text, status text)
 language plpgsql security definer set search_path to 'public', 'extensions'
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

commit;
