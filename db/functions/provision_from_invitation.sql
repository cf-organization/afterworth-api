-- public.provision_from_invitation(p_invitation_id uuid, p_user uuid) -> uuid (estate_memberships.id)
--
-- SHARED, idempotent post-status provisioning for BOTH accept_invitation and bind_invitation_token (0021).
-- Holds: membership-reconcile + beneficiary self-link (triple-equality) + executor/trustee designation stamp
-- + audit. Assumes the caller already locked the invitation FOR UPDATE and ran the status + P0006 identity
-- guards. INTERNAL only (revoked from public/anon/authenticated — the DEFINER callers invoke it as owner).
--
-- Why a shared helper: a bind-accepted executor must NEVER end up membership-without-designation (a silent
-- authority void). Centralizing here also fixes the pre-existing bind beneficiary-self-link asymmetry.
-- Idempotent: membership ON CONFLICT(estate_id,user_id) DO NOTHING (reuse, don't duplicate); designation
-- ON CONFLICT (partial-unique-on-active) DO NOTHING; designation.created audited ONLY when inserted.
-- Captured from live 2026-07-15 (migration 0021). Source of truth — re-apply on reset.

create or replace function public.provision_from_invitation(p_invitation_id uuid, p_user uuid)
 returns uuid
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

  if v_inv.proposed_role::text = 'beneficiary' then
    update public.beneficiaries set user_id = p_user
     where estate_id = v_inv.estate_id and user_id is null
       and ((v_inv.invitee_email is not null and lower(email) = lower(v_inv.invitee_email))
            or (v_inv.invitee_phone is not null and phone = v_inv.invitee_phone));
  end if;

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
