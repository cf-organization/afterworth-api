-- public.submit_claim_with_evidence(p_estate, p_death_cert_doc_id, p_death_cert_path,
--                                   p_executor_id_doc_id, p_executor_id_path) -> uuid (claim_packets.id)
--
-- Slice C1.6a (migration 0031). The atomic evidence-carrying submit door. The executor uploads both PDFs
-- direct-to-storage (RLS-gated by 0030), THEN calls this; it creates the two documents rows + the claim in
-- ONE transaction. Order upload→RPC: an orphan OBJECT is harmless/GC-able, an orphan ROW (serving 404) is not,
-- so the RPC REQUIRES each object to exist (no orphan rows) and reads size/mime FROM storage.objects (never a
-- client-supplied value).
--
-- ★ MULTI-SOURCE AGREEMENT — all must agree or reject (no single check suffices; cross-estate smuggling vector):
--   (a) p_estate; (b) the estate in EACH storage_path (strict regex: estates/<p_estate>/claim-evidence/
--   <doc_id>.<ext> — also kills traversal + ties the row id to the object); (c) the claim's estate_id (= p_estate
--   by construction); (d) is_estate_executor(p_estate, auth.uid()) — an ACTIVE designation, never a role.
--   Dedicated mismatch leg: path-estate ≠ p_estate → evidence_path_mismatch.
--
-- Per-claim quota (per-file 25MB defense-in-depth; aggregate 50MB). Rows: owner_id=auth.uid(), estate_id=
-- p_estate, is_encrypted=false, sensitivity='sealed' (evidence is executor-own + admin-review, never grant-
-- shared). One-active-per-estate honored (pre-check + 0023 partial-unique). No Vercel endpoint — iOS calls this
-- RPC directly (api stays 12/12). EXECUTE authenticated, gate inside; REVOKE public/anon.
--
-- Source of truth — re-apply on DB reset.

create or replace function public.submit_claim_with_evidence(
  p_estate             uuid,
  p_death_cert_doc_id  uuid,
  p_death_cert_path    text,
  p_executor_id_doc_id uuid,
  p_executor_id_path   text
)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid     uuid := auth.uid();
  v_claim   uuid;
  v_dc_size bigint; v_dc_mime text;
  v_ex_size bigint; v_ex_mime text;
  c_max_file bigint := 25 * 1024 * 1024;
  c_max_agg  bigint := 50 * 1024 * 1024;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_executor(p_estate, v_uid) then
    raise exception 'not_estate_executor' using errcode = '42501';
  end if;
  if not exists (select 1 from public.estates where id = p_estate) then
    raise exception 'estate_not_found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.claim_packets c where c.estate_id = p_estate and c.status <> 'rejected') then
    raise exception 'active_claim_exists' using errcode = 'P0001';
  end if;

  if p_death_cert_path !~ ('^estates/' || p_estate::text || '/claim-evidence/' || p_death_cert_doc_id::text || '\.[a-zA-Z0-9]+$') then
    raise exception 'evidence_path_mismatch' using errcode = 'P0001';
  end if;
  if p_executor_id_path !~ ('^estates/' || p_estate::text || '/claim-evidence/' || p_executor_id_doc_id::text || '\.[a-zA-Z0-9]+$') then
    raise exception 'evidence_path_mismatch' using errcode = 'P0001';
  end if;

  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_dc_size, v_dc_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_death_cert_path;
  if not found then
    raise exception 'evidence_object_missing' using errcode = 'P0002';
  end if;
  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_ex_size, v_ex_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_executor_id_path;
  if not found then
    raise exception 'evidence_object_missing' using errcode = 'P0002';
  end if;

  if coalesce(v_dc_size, 0) > c_max_file or coalesce(v_ex_size, 0) > c_max_file then
    raise exception 'evidence_too_large' using errcode = 'P0001';
  end if;
  if coalesce(v_dc_size, 0) + coalesce(v_ex_size, 0) > c_max_agg then
    raise exception 'evidence_quota_exceeded' using errcode = 'P0001';
  end if;

  insert into public.documents
    (id, estate_id, owner_id, doc_type, title, storage_path, mime_type, size_bytes, is_encrypted, sensitivity)
  values
    (p_death_cert_doc_id,  p_estate, v_uid, 'death_certificate', 'Death Certificate', p_death_cert_path,  v_dc_mime, v_dc_size, false, 'sealed'),
    (p_executor_id_doc_id, p_estate, v_uid, 'id_document',       'Executor ID',       p_executor_id_path, v_ex_mime, v_ex_size, false, 'sealed');

  insert into public.claim_packets
    (estate_id, requested_by, status, death_certificate_doc_id, executor_id_doc_id, submitted_at)
  values
    (p_estate, v_uid, 'submitted', p_death_cert_doc_id, p_executor_id_doc_id, now())
  returning id into v_claim;

  perform public.write_audit('claim.submitted', 'claim_packets', v_claim, p_estate,
    jsonb_build_object('claim_id', v_claim, 'has_death_cert', true, 'has_executor_id', true,
                       'via', 'submit_claim_with_evidence'));

  return v_claim;
end;
$function$;
revoke execute on function public.submit_claim_with_evidence(uuid, uuid, text, uuid, text) from public, anon;
grant  execute on function public.submit_claim_with_evidence(uuid, uuid, text, uuid, text) to authenticated;
