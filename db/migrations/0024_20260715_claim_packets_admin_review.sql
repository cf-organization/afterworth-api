-- 0024_20260715_claim_packets_admin_review — Slice C1 (part 2): the admin review surface (4th admin console).
--
-- The reviewer of a death claim is a platform ADMIN. Two DEFINER RPCs, gated inside via admin_require_gate
-- (auth -> is_admin -> aal2 -> 15-min freshness — reused verbatim, same order the console mirrors):
--   * admin_list_claim_packets — the review QUEUE (keyset, clamp <=200). Same pattern as admin_list_invitations.
--   * admin_decide_claim_packet — approve|reject a submitted/under_review claim; stamps reviewer_id + decided_at
--     + review_notes and writes ONE high-severity source='admin' audit. Idempotent (already-at-target -> no-op,
--     no re-audit); a contradictory re-decision or a terminal state -> claim_already_decided (no silent flip).
--
-- Scope: C1 covers submit -> under_review -> approved/rejected. The 'under_review' TRANSITION rpc is DEFERRED
-- (decide accepts submitted OR under_review, so it slots in later without rework). The RELEASE transition is
-- Slice C5 — this migration has NO 'released' handling.
--
-- Audit is a DIRECT source='admin' insert (NOT write_admin_breakglass_audit): a routine review decision is the
-- normal admin flow, not an emergency override — stamping breakglass=true would mislabel the alarm channel.
-- 'admin' is an allowed audit_logs.source value (verified live). Separation of duties is NOT enforced in C1,
-- but both actor_ids are on record (claim.reviewer_id + the break-glass provisioner's audit actor_id) so a
-- future SoD policy can compare them.

begin;

-- ==================================================================================================
-- admin_list_claim_packets — the review queue. Admin gate inside; keyset (submitted_at desc, id desc).
-- All columns qualified c.* (RETURNS TABLE OUT names shadow claim_packets columns -> 42702).
-- ==================================================================================================
create or replace function public.admin_list_claim_packets(
  p_estate           uuid        default null,
  p_status           text        default null,
  p_before_submitted timestamptz default null,
  p_before_id        uuid        default null,
  p_limit            int         default 50
)
 returns table(
   id                       uuid,
   estate_id                uuid,
   requested_by             uuid,
   status                   text,
   death_certificate_doc_id uuid,
   executor_id_doc_id       uuid,
   reviewer_id              uuid,
   review_notes             text,
   submitted_at             timestamptz,
   decided_at               timestamptz
 )
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.admin_require_gate();
  return query
    select c.id, c.estate_id, c.requested_by, c.status,
           c.death_certificate_doc_id, c.executor_id_doc_id, c.reviewer_id,
           c.review_notes, c.submitted_at, c.decided_at
    from public.claim_packets c
    where (p_estate is null or c.estate_id = p_estate)
      and (p_status is null or c.status = p_status)
      and (
        p_before_submitted is null
        or c.submitted_at < p_before_submitted
        or (c.submitted_at = p_before_submitted and c.id < p_before_id)
      )
    order by c.submitted_at desc, c.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$function$;
revoke execute on function public.admin_list_claim_packets(uuid, text, timestamptz, uuid, int) from public, anon;
grant  execute on function public.admin_list_claim_packets(uuid, text, timestamptz, uuid, int) to authenticated;

-- ==================================================================================================
-- admin_decide_claim_packet — approve|reject. Admin gate + guarded transition + high-sev source='admin' audit.
-- ==================================================================================================
create or replace function public.admin_decide_claim_packet(
  p_claim_id     uuid,
  p_decision     text,          -- 'approve' | 'reject'
  p_review_notes text default null
)
 returns text                   -- the resulting status
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

  -- Idempotent replay: already at the requested terminal -> graceful no-op (no re-stamp, no re-audit).
  if v_status = v_target then
    return v_status;
  end if;
  -- Contradictory re-decision (approve<->reject) or a terminal/released state -> explicit rejection, no silent flip.
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

commit;
