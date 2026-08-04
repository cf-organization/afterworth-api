-- 0046_20260804_fix_revoke_invitation_ambiguous_invitation_id.sql
--
-- ★ revoke_estate_invitation is BROKEN IN PRODUCTION. Every owner revoke fails.
--
-- Same defect class as 0045, different function and different column. The function declares
-- `RETURNS TABLE(invitation_id uuid, status text, revoked_at timestamptz)`, so BOTH `invitation_id`
-- and `status` are implicit OUT variables in scope for the entire PL/pgSQL body. The statement that
-- cancels queued deliveries then references them bare:
--
--     update public.invitation_delivery_outbox
--        set status = 'failed', last_error = 'invitation_revoked'
--      where invitation_id = v_inv.id and status = 'pending';
--
-- PostgreSQL refuses it:
--
--     42702: column reference "invitation_id" is ambiguous
--     It could refer to either a PL/pgSQL variable or a table column.
--
-- The statement runs unconditionally after the owner gate and the status guard, so EVERY revoke by
-- a legitimate owner raises. The mobile client classified the unrecognised code as a generic
-- failure and correctly made no optimistic change — the invitation simply stayed pending.
--
-- Found by executing revoke through the real owner UI on the iOS Simulator, then reproducing the
-- raw error by calling the RPC directly as the authenticated owner.
--
-- THE FIX: alias the outbox table and qualify both predicates — the same shape 0045 used. Purely
-- additive: `create or replace function`, no signature, grant, security-definer, search_path,
-- vocabulary or audit change. Migration 0042 is NOT modified.
--
-- ★ WHY `status` IS QUALIFIED TOO. Only `invitation_id` is reported, because PostgreSQL stops at
-- the first ambiguity. `status` collides identically and would raise the moment the first is fixed,
-- so both are qualified in one pass rather than shipping a fix that fails one line later.

begin;

create or replace function public.revoke_estate_invitation(p_estate uuid, p_invitation uuid)
 returns table(invitation_id uuid, status text, revoked_at timestamptz)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_inv record; v_eff text;
begin
  perform public.estate_owner_gate(p_estate);

  select * into v_inv from public.invitations
   where id = p_invitation and estate_id = p_estate for update;
  -- Cross-estate and unknown ids are indistinguishable: an owner must not be able to probe for
  -- the existence of another estate's invitations.
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- Idempotent on already-revoked: repeating the operation returns the authoritative revoked row
  -- rather than an error, so a retried request is safe.
  if v_inv.status = 'revoked' then
    return query select v_inv.id, v_inv.status, v_inv.revoked_at;
    return;
  end if;

  v_eff := public.invitation_effective_status(v_inv.status, v_inv.expires_at);
  if v_eff not in ('pending', 'matched') then
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  update public.invitations
     set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), updated_at = now()
   where id = v_inv.id;

  -- Any queued delivery for a revoked invitation must not go out.
  update public.invitation_delivery_outbox as ob
     set status = 'failed', last_error = 'invitation_revoked'
   where ob.invitation_id = v_inv.id and ob.status = 'pending';

  perform public.write_audit('invitation.revoked', 'invitations', v_inv.id, p_estate,
    jsonb_build_object('invitation_id', v_inv.id, 'prior_status', v_inv.status));

  return query select v_inv.id, 'revoked'::text, now();
end;
$function$;
commit;
