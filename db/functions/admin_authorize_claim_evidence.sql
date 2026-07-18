-- public.admin_authorize_claim_evidence(p_claim uuid, p_slot text)
--   -> TABLE(storage_path text, document_id uuid, mime_type text)
--
-- Slice C1.6b (migration 0029). The DEFINER gate + claim-scoped path resolver behind the console evidence
-- viewer. api/claims/[action].ts (view_evidence) calls this with the admin's JWT to authorize + resolve, then
-- service-role-downloads the returned storage_path and streams the bytes. The gate lives HERE (admin_require_gate:
-- auth -> is_admin -> aal2 -> 15-min freshness); a direct rest/v1/rpc/... caller hits the same gate.
--
-- ANTI-TRAVERSAL: the client supplies ONLY (p_claim, p_slot); the doc id is resolved FROM THE NAMED CLAIM's row,
-- so only that claim's two evidence docs are reachable — an arbitrary-document read is unrepresentable. Admins are
-- global reviewers (may name any claim); the boundary is "a claim's own 2 docs", enforced by the resolution shape.
--
-- AUDIT: ONE claim.evidence_viewed (source 'admin', severity 'high' in metadata, actor = auth.uid()) written
-- inside the gate before the path leaves the DB (sensitive-PII access, individually attributable).
--
-- RETURNS TABLE OUT columns (storage_path/mime_type) shadow documents columns -> resolve into local vars and
-- return those (42702 avoidance). EXECUTE authenticated only; REVOKE public/anon.
--
-- Source of truth — re-apply on DB reset.

create or replace function public.admin_authorize_claim_evidence(
  p_claim uuid,
  p_slot  text
)
 returns table(storage_path text, document_id uuid, mime_type text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_doc    uuid;
  v_path   text;
  v_mime   text;
begin
  perform public.admin_require_gate();

  if p_slot not in ('death_cert', 'executor_id') then
    raise exception 'invalid_slot' using errcode = 'P0001';
  end if;

  select c.estate_id,
         case p_slot when 'death_cert' then c.death_certificate_doc_id
                     else c.executor_id_doc_id end
    into v_estate, v_doc
    from public.claim_packets c
   where c.id = p_claim;
  if not found then
    raise exception 'claim_not_found' using errcode = 'P0002';
  end if;
  if v_doc is null then
    raise exception 'evidence_not_found' using errcode = 'P0002';
  end if;

  select d.storage_path, d.mime_type
    into v_path, v_mime
    from public.documents d
   where d.id = v_doc;
  if not found then
    raise exception 'evidence_not_found' using errcode = 'P0002';
  end if;

  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    v_uid, v_estate, 'claim.evidence_viewed', 'documents', v_doc,
    jsonb_build_object('severity', 'high', 'claim_id', p_claim, 'document_id', v_doc, 'slot', p_slot),
    'admin'
  );

  return query select v_path, v_doc, v_mime;
end;
$function$;
revoke execute on function public.admin_authorize_claim_evidence(uuid, text) from public, anon;
grant  execute on function public.admin_authorize_claim_evidence(uuid, text) to authenticated;
