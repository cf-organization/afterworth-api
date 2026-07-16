-- 0028_20260716_claim_packets_enriched — Slice C1.5 (re-cut): display-resolved claims queue for the console.
--
-- The lean admin_list_claim_packets (0024) returns raw uuids — a reviewer can't triage "estate 9add… /
-- submitter cb5e…". This ADDITIVE sibling resolves the display fields the read-only console surface binds to:
-- estate name, submitter identity (profiles email/full_name), reviewer email (if decided), and the two
-- evidence documents' METADATA (title / doc_type / uploaded_at) — METADATA ONLY, never storage_path/content:
-- viewing the death cert + executor ID is Slice C1.6, and the DECIDE action is gated behind it (a reviewer
-- must see the evidence before approve/reject). admin_decide_claim_packet stays shipped but UI-unexposed.
--
-- Same admin gate preamble as its sibling (admin_require_gate: auth -> is_admin -> aal2 -> 15-min freshness).
-- DEFINER so it resolves profiles emails (RPC-gated) + documents (RLS) as owner. Keyset (submitted_at desc, id
-- desc), clamp <=200. All columns qualified (RETURNS TABLE OUT names shadow claim_packets columns -> 42702).
-- The original lean RPC is KEPT (additive). EXECUTE authenticated only; gate inside.

begin;

create or replace function public.admin_list_claim_packets_enriched(
  p_estate           uuid        default null,
  p_status           text        default null,
  p_before_submitted timestamptz default null,
  p_before_id        uuid        default null,
  p_limit            int         default 50
)
 returns table(
   id                        uuid,
   estate_id                 uuid,
   estate_name               text,
   requested_by              uuid,
   submitter_email           text,
   submitter_name            text,
   status                    text,
   submitted_at              timestamptz,
   decided_at                timestamptz,
   reviewer_id               uuid,
   reviewer_email            text,
   review_notes              text,
   death_certificate_doc_id  uuid,
   death_cert_title          text,
   death_cert_doc_type       text,
   death_cert_uploaded_at    timestamptz,
   executor_id_doc_id        uuid,
   executor_id_title         text,
   executor_id_doc_type      text,
   executor_id_uploaded_at   timestamptz
 )
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.admin_require_gate();
  return query
    select
      c.id, c.estate_id, e.name, c.requested_by, ps.email, ps.full_name,
      c.status, c.submitted_at, c.decided_at, c.reviewer_id, pr.email, c.review_notes,
      c.death_certificate_doc_id, dc.title, dc.doc_type, dc.created_at,
      c.executor_id_doc_id,       de.title, de.doc_type, de.created_at
    from public.claim_packets c
    left join public.estates   e  on e.id  = c.estate_id
    left join public.profiles  ps on ps.id = c.requested_by
    left join public.profiles  pr on pr.id = c.reviewer_id
    left join public.documents dc on dc.id = c.death_certificate_doc_id
    left join public.documents de on de.id = c.executor_id_doc_id
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
revoke execute on function public.admin_list_claim_packets_enriched(uuid, text, timestamptz, uuid, int) from public, anon;
grant  execute on function public.admin_list_claim_packets_enriched(uuid, text, timestamptz, uuid, int) to authenticated;

commit;
