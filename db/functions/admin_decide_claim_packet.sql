-- public.admin_decide_claim_packet(p_claim_id, p_decision 'approve'|'reject', p_review_notes) -> text (status)
--
-- Slice C1 (migration 0024). An admin decides a submitted/under_review claim. Gated INSIDE via
-- admin_require_gate (auth -> is_admin -> aal2 -> 15-min freshness). Stamps status + reviewer_id (=auth.uid())
-- + decided_at + review_notes, and writes ONE high-severity source='admin' audit (claim.approved/claim.rejected).
--
-- Guarded transition + idempotency: already-at-target -> graceful no-op (no re-stamp, no re-audit); a
-- CONTRADICTORY re-decision (approve<->reject) or a terminal/released state -> claim_already_decided (no silent
-- flip). C1 decides only submitted/under_review; RELEASE is Slice C5.
--
-- Audit is a DIRECT source='admin' insert, NOT write_admin_breakglass_audit — a routine review decision is the
-- normal admin flow, not an emergency override (breakglass=true would mislabel the alarm channel). 'admin' is
-- an allowed audit_logs.source value (verified live). SoD is NOT enforced here, but both actor_ids are on
-- record (this reviewer_id + any break-glass provisioner's audit actor_id) for a future SoD policy.
-- EXECUTE to authenticated only (gate inside). Source of truth — re-apply on reset.

create or replace function public.admin_decide_claim_packet(
  p_claim_id     uuid,
  p_decision     text,
  p_review_notes text default null
)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_estate uuid; v_status text; v_target text;
begin
  perform public.admin_require_gate();

  if p_decision not in ('approve', 'reject') then
    raise exception 'invalid_decision' using errcode = 'P0001';
  end if;
  v_target := case p_decision when 'approve' then 'approved' else 'rejected' end;

  select estate_id, status into v_estate, v_status from public.claim_packets where id = p_claim_id for update;
  if not found then
    raise exception 'claim_not_found' using errcode = 'P0002';
  end if;

  if v_status = v_target then
    return v_status;                                   -- idempotent replay
  end if;
  if v_status not in ('submitted', 'under_review') then
    raise exception 'claim_already_decided' using errcode = 'P0001';
  end if;

  update public.claim_packets
     set status = v_target, reviewer_id = v_uid, decided_at = now(), review_notes = p_review_notes
   where id = p_claim_id;

  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    v_uid, v_estate, 'claim.' || v_target, 'claim_packets', p_claim_id,
    jsonb_build_object('severity', 'high', 'claim_id', p_claim_id, 'decision', p_decision,
                       'reviewer_id', v_uid, 'review_notes', p_review_notes),
    'admin'
  );

  return v_target;
end;
$function$;
revoke execute on function public.admin_decide_claim_packet(uuid, text, text) from public, anon;
grant  execute on function public.admin_decide_claim_packet(uuid, text, text) to authenticated;
