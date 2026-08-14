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
  v_is_fiduciary boolean;
begin
  select * into v_inv from public.invitations where id = p_invitation_id;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- ════════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ PHASE 11-MC — A FIDUCIARY DESIGNATION NO LONGER MANUFACTURES A DISCLOSURE CLASS.
  -- ════════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- Until now every acceptance inserted an `estate_memberships` row at the invitation's
  -- `proposed_role`, and `create_invitation` forces that to `'beneficiary'` for executor/trustee. So
  -- granting WORKFLOW capacity silently granted a DISCLOSURE access class as a side effect — the
  -- authority-model defect 11-MA diagnosed.
  --
  -- ★ THE GATE IS `kind`, NOT `proposed_role`, AND THAT CHOICE IS THE WHOLE COMPATIBILITY STORY.
  --
  -- `proposed_role` is PERSISTED AT CREATE TIME (`create_invitation` writes it into the row). Every
  -- executor/trustee invitation already in the table therefore carries a stored
  -- `proposed_role = 'beneficiary'`, and an invitation created before this change but accepted after it
  -- would still manufacture a membership if the provisioner keyed off that stale column. Correcting
  -- `create_invitation` alone fixes NOTHING for outstanding invitations.
  --
  -- `kind` is the authoritative, immutable statement of what the invitation IS. Keying on it fixes new
  -- and outstanding invitations in one place, with no data migration and no need to cancel anything.
  --
  -- ★ AND REMOVING THE FORCED ROLE ALONE WOULD HAVE BEEN WORSE THAN LEAVING IT. Without this gate, an
  -- executor invitation minted with `p_proposed_role = 'professional_delegate'` would provision a
  -- PROFESSIONAL DELEGATE membership instead of a beneficiary one — a different disclosure class,
  -- manufactured just as silently. The defect was never the forced value; it was that a fiduciary
  -- invitation created a membership at all.
  -- ★ `coalesce(..., false)` IS LOAD-BEARING, AND A LAXER TEST SCHEMA IS WHAT PROVED IT.
  --
  -- `NULL in ('executor','trustee')` evaluates to NULL, not false — so `if not v_is_fiduciary` would be
  -- `not NULL`, the membership branch would be SKIPPED, and an ordinary beneficiary acceptance would
  -- silently provision nothing. Production's `invitations.kind` is `text NOT NULL` so it cannot be null
  -- there; the test preamble declares it merely `text`, and an existing lifecycle fixture that omits
  -- `kind` failed immediately on the first run of this correction.
  --
  -- That divergence caught a genuine fragility rather than exposing a harmless one, which is why the
  -- preamble is NOT being tightened to match: a null kind must mean "not a fiduciary invitation" and
  -- therefore "provision exactly as before", because the conservative default for an unrecognised
  -- invitation is the path that existed before this change — never the one that creates no membership.
  v_is_fiduciary := coalesce(v_inv.kind in ('executor', 'trustee'), false);

  if not v_is_fiduciary then
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
  else
    /**
     * ★ AN INDEPENDENTLY-HELD MEMBERSHIP IS REPORTED, NEVER CREATED, AND NEVER TOUCHED.
     *
     * A person may already be a beneficiary or professional delegate of this estate for reasons that
     * have nothing to do with this invitation. Accepting a fiduciary invitation must leave that
     * relationship exactly as it was — it is a separate authority on a separate axis. So this SELECTs
     * an existing membership to report, and inserts none.
     *
     * ★ NULL IS A LEGITIMATE RETURN VALUE FROM HERE NOW. A fiduciary-only recipient has no membership,
     * so there is no `estate_memberships.id` to hand back. Both callers were adjusted to tell the truth
     * about that rather than assert an approved membership that does not exist, and the two BFF routes
     * that read the result were adjusted to accept it — see `lib/invitations/accept.ts`. Deploying this
     * routine BEFORE those callers would make every executor acceptance look like a 502.
     */
    select em.id into v_membership_id from public.estate_memberships em
     where em.estate_id = v_inv.estate_id and em.user_id = p_user;
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
