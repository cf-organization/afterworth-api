-- 0029_20260717_claim_evidence_authorize — Slice C1.6b: the DEFINER gate + claim-scoped path resolver
-- behind the console evidence viewer (death certificate / executor ID).
--
-- The api endpoint (api/claims/[action].ts, action=view_evidence) calls this with the admin's JWT to
-- AUTHORIZE + resolve a storage_path, then SERVICE-ROLE-downloads that path and streams the bytes back.
-- The GATE lives HERE (admin_require_gate: auth -> is_admin -> aal2 -> 15-min freshness) — the endpoint is
-- only the outer layer; a direct rest/v1/rpc/... caller hits the identical gate (the DEFINER-door discipline).
--
-- ANTI-TRAVERSAL BY CONSTRUCTION: the client supplies ONLY (p_claim, p_slot) — NEVER a storage_path or a
-- document_id. The doc id is resolved FROM THE NAMED CLAIM's own row, so the only reachable paths are the two
-- evidence docs ON that claim; an arbitrary-document read is unrepresentable. (Admins are global reviewers by
-- design — they may name any claim — so the boundary is "only a claim's own 2 docs", not "only my estates".)
--
-- AUDIT INSIDE THE GATE: an admin opening a death certificate is sensitive-PII access -> ONE
-- claim.evidence_viewed audit (source 'admin', elevated severity, actor server-stamped = auth.uid()) is
-- written before the path leaves the DB. Distinct action from claim.approved/claim.rejected.
--
-- RETURNS TABLE OUT columns (storage_path/mime_type) shadow documents columns -> resolve into LOCAL vars
-- (v_path/v_mime) and return those; never a bare shadowed column ref (42702; the RETURNS-TABLE-shadow gotcha).
-- EXECUTE authenticated only (gate inside); REVOKE public/anon. Captured in db/functions/. Re-apply on reset.

begin;

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

  -- Resolve the doc id FROM THIS CLAIM ONLY (claim-scoped; the client cannot name a document).
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

  -- Sensitive-PII access audit — INSIDE the gate, before the path leaves the DB. Actor server-stamped.
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

commit;
