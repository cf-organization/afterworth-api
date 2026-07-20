-- public.admin_authorize_claim_evidence(p_claim uuid, p_slot text)
--   -> TABLE(storage_path text, document_id uuid, mime_type text, max_upload_bytes bigint)
--
-- Slice C1.6b (migration 0029); max_upload_bytes added by 0032 (upload contract unification). The DEFINER gate
-- + claim-scoped path resolver behind the console evidence viewer. api/claims/[action].ts (view_evidence)
-- calls this with the admin's JWT to authorize + resolve, then service-role-STREAMS the object (blob.stream()).
-- The gate lives HERE (admin_require_gate: auth -> is_admin -> aal2 -> 15-min freshness); a direct
-- rest/v1/rpc/... caller hits the same gate.
--
-- ANTI-TRAVERSAL: client sends only (p_claim, p_slot); the doc id is resolved FROM THE NAMED CLAIM's row.
-- AUDIT: one claim.evidence_viewed (source 'admin', severity high, actor auth.uid()) inside the gate.
-- 0032: also returns max_upload_bytes (from upload_policy) so the endpoint's serving guard is POLICY-SOURCED
-- (defensive-only now that streaming lifts the 4.5MB buffered cap), never a hardcoded number. Generous fallback
-- only if the seeded singleton is absent. RETURNS TABLE OUT cols shadow documents cols -> resolve into locals
-- (42702). EXECUTE authenticated only. Source of truth -- re-apply on reset.

create or replace function public.admin_authorize_claim_evidence(
  p_claim uuid,
  p_slot  text
)
 returns table(storage_path text, document_id uuid, mime_type text, max_upload_bytes bigint)
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
  v_max    bigint;
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

  -- Serving guard ceiling, sourced from policy (defensive; streaming lifts the real cap). Generous fallback
  -- only if the seeded singleton is somehow absent — never a hardcoded contract number.
  v_max := coalesce((select p.max_upload_bytes from public.upload_policy p where p.id = 1), 25 * 1024 * 1024);

  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    v_uid, v_estate, 'claim.evidence_viewed', 'documents', v_doc,
    jsonb_build_object('severity', 'high', 'claim_id', p_claim, 'document_id', v_doc, 'slot', p_slot),
    'admin'
  );

  return query select v_path, v_doc, v_mime, v_max;
end;
$function$;
revoke execute on function public.admin_authorize_claim_evidence(uuid, text) from public, anon;
grant  execute on function public.admin_authorize_claim_evidence(uuid, text) to authenticated;
