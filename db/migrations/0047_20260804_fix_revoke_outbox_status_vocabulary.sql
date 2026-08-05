-- 0047_20260804_fix_revoke_outbox_status_vocabulary.sql
--
-- ★ REVOKING AN INVITATION DOES NOT CANCEL ITS QUEUED EMAIL. Silent, unlike 0045/0046.
--
-- 0042 wrote revoke's cancellation statement against the outbox vocabulary of its time:
--
--     set status = 'failed' ... where ... status = 'pending'
--
-- 0043 then replaced that vocabulary wholesale — new rows default to 'queued', the check
-- constraint became
--   ('queued','processing','providerAccepted','outcomeUncertain','retryPending','failedPermanent','cancelled')
-- and 'pending' and 'failed' both ceased to exist. revoke was never updated, so the statement is
-- DOUBLY stale:
--
--   * the predicate `status = 'pending'` matches NOTHING, because no row is ever 'pending' again;
--   * the target `status = 'failed'` is not in the check constraint, so it could not succeed even
--     if the predicate did match.
--
-- The result is a no-op that raises nothing. The invitation is correctly marked revoked, but its
-- queued delivery stays claimable and the daily drain still sends it. The owner is told the
-- invitation is revoked; the recipient still receives the email.
--
-- Harm is bounded — accept_invitation re-validates and the revoked invitation cannot be accepted —
-- but an email going out for a revoked invitation is wrong and confusing, and nothing surfaced it
-- because there was no error to surface. Found by the 0046 verification harness, which seeds a real
-- queued row and asserts it is cancelled.
--
-- THE FIX, matching 0043's own semantics:
--
--   * cancel exactly the DELIVERABLE set, `('queued','retryPending')` — the same predicate the
--     worker's claimable index uses, so precisely the rows that could still be sent;
--   * set 'cancelled', which 0043 introduced for this exact case and documents as
--     "invitation became terminal before it could be sent".
--
-- Rows already past sending (providerAccepted, outcomeUncertain, failedPermanent) are deliberately
-- left alone: their email has already left, and rewriting their state would erase delivery history
-- and imply a recall that did not happen.
--
-- Additive `create or replace function`, built on top of 0046 so both fixes compose. 0042–0046 are
-- NOT modified. No signature, grant, security-definer, search_path, status-transition, audit or
-- return-shape change.

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
     set status = 'cancelled', last_error = 'invitation_revoked'
   where ob.invitation_id = v_inv.id and ob.status in ('queued', 'retryPending');

  perform public.write_audit('invitation.revoked', 'invitations', v_inv.id, p_estate,
    jsonb_build_object('invitation_id', v_inv.id, 'prior_status', v_inv.status));

  return query select v_inv.id, 'revoked'::text, now();
end;
$function$;
commit;
