-- public.admin_list_claim_packets(p_estate, p_status, p_before_submitted, p_before_id, p_limit)
--   -> TABLE(id, estate_id, requested_by, status, death_certificate_doc_id, executor_id_doc_id,
--            reviewer_id, review_notes, submitted_at, decided_at)
--
-- Slice C1 (migration 0024). The admin death-claim review QUEUE. Gated INSIDE via admin_require_gate
-- (auth -> is_admin -> aal2 -> 15-min freshness). Keyset (submitted_at desc, id desc), clamp <=200. Same
-- pattern as admin_list_invitations. All columns qualified c.* (RETURNS TABLE OUT names shadow claim_packets
-- columns -> 42702). EXECUTE to authenticated only (gate inside). Source of truth — re-apply on reset.

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
