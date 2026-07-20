-- 0032_20260720_upload_policy — Upload contract unification. ONE server-driven source of truth for the
-- evidence-upload limits, read by EVERY consumer so "what the client is told" == "what the server enforces".
--
-- Fixes the 25MB-upload vs 4MB-serving gap: the serving cap was Vercel's 4.5MB BUFFERED response limit —
-- which streaming does NOT hit (proven, not doc-trusted, in the proof leg). So serving switches to streaming
-- (blob.stream() at the api, piped upstream.body at the BFF) and the contract unifies at 25MB.
--
-- SOURCE OF TRUTH = public.upload_policy (singleton row id=1). Consumers:
--   * get_upload_policy() (DEFINER, authenticated) — the CLIENT reads it directly via supabase-js (like
--     submit_claim_with_evidence), so NO Vercel endpoint is needed (api stays 12/12). UX honesty only.
--   * submit_claim_with_evidence — reads the table for the per-file / aggregate / file-count / MIME gates
--     (replaces its hardcoded constants), so the RPC enforces the EXACT numbers the client is told.
--   * admin_authorize_claim_evidence — returns max_upload_bytes so the view_evidence serving guard is
--     SOURCED from policy (defensive-only now that streaming lifts the cap), never a hardcoded number.
--
-- THE ONE DUALITY (documented, proof-guarded): Storage enforces the bucket file_size_limit + allowed_mime_types
-- INDEPENDENTLY of this table. The table is the documented AUTHORITY; a limit change requires BOTH edits
-- (table + bucket). The drift-check proof leg (bucket == table) is the guardrail.
--
-- Enforcement stays SERVER-SIDE: the bucket (rejects at upload) + the RPC quotas (reject at submit) are the
-- real gates; get_upload_policy is for pre-upload UX warnings, never the security boundary.
--
-- CLOBBER DISCIPLINE: submit_claim_with_evidence (0031) + admin_authorize_claim_evidence (0029) are REPLACED
-- here — diff live vs the VC copies (db/functions/*) FIRST (both were just shipped by me, so live == VC).

begin;

-- ---- Source of truth: singleton config table (born-clean; no client grants — read via get_upload_policy). ----
create table if not exists public.upload_policy (
  id                  int         primary key default 1 check (id = 1),
  max_upload_bytes    bigint      not null,
  max_files_per_claim int         not null,
  max_aggregate_bytes bigint      not null,
  allowed_mime_types  text[]      not null,
  updated_at          timestamptz not null default now()
);

alter table public.upload_policy enable row level security;
-- No client GRANTS and no policies: the client reads via the DEFINER get_upload_policy(); admins edit via the
-- SQL editor (a set_upload_policy admin RPC is a deferred nicety). RLS-on + grant-less = born clean.

insert into public.upload_policy (id, max_upload_bytes, max_files_per_claim, max_aggregate_bytes, allowed_mime_types)
values (1, 25 * 1024 * 1024, 2, 50 * 1024 * 1024,
        array['application/pdf','image/jpeg','image/png','image/heic'])
on conflict (id) do nothing;

-- ---- get_upload_policy(): the client's read path (Supabase-direct; NO endpoint). UX honesty only. ----
create or replace function public.get_upload_policy()
 returns table(max_upload_bytes bigint, max_files_per_claim int, max_aggregate_bytes bigint, allowed_mime_types text[])
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select p.max_upload_bytes, p.max_files_per_claim, p.max_aggregate_bytes, p.allowed_mime_types
  from public.upload_policy p where p.id = 1;
$function$;
revoke execute on function public.get_upload_policy() from public, anon;
grant  execute on function public.get_upload_policy() to authenticated;

-- ---- submit_claim_with_evidence: read the policy (replaces hardcoded constants) + MIME + file-count gates. ----
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
  v_uid       uuid := auth.uid();
  v_claim     uuid;
  v_dc_size   bigint; v_dc_mime text;
  v_ex_size   bigint; v_ex_mime text;
  v_max_file  bigint; v_max_agg bigint; v_max_files int; v_mimes text[];
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

  -- Policy = the single source (fail-closed if the singleton is somehow absent).
  select max_upload_bytes, max_aggregate_bytes, max_files_per_claim, allowed_mime_types
    into v_max_file, v_max_agg, v_max_files, v_mimes
    from public.upload_policy where id = 1;
  if not found then
    raise exception 'upload_policy_missing' using errcode = 'P0002';
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

  -- File count (this RPC creates 2) + MIME allowlist (defense-in-depth; the bucket already enforced at upload)
  -- + per-file + aggregate — ALL sourced from upload_policy (the same numbers get_upload_policy tells the client).
  if 2 > v_max_files then
    raise exception 'evidence_too_many_files' using errcode = 'P0001';
  end if;
  if (v_dc_mime is not null and not (v_dc_mime = any(v_mimes)))
     or (v_ex_mime is not null and not (v_ex_mime = any(v_mimes))) then
    raise exception 'evidence_mime_rejected' using errcode = 'P0001';
  end if;
  if coalesce(v_dc_size, 0) > v_max_file or coalesce(v_ex_size, 0) > v_max_file then
    raise exception 'evidence_too_large' using errcode = 'P0001';
  end if;
  if coalesce(v_dc_size, 0) + coalesce(v_ex_size, 0) > v_max_agg then
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

-- ---- admin_authorize_claim_evidence: return max_upload_bytes so the serving guard is policy-sourced.
--      The RETURNS TABLE gains a column, and Postgres CANNOT change a function's return type via CREATE OR
--      REPLACE (42P13) — DROP first. No DB object depends on it (the Vercel endpoint is the only caller), so a
--      plain drop is safe; the grants below re-establish EXECUTE. ----
drop function if exists public.admin_authorize_claim_evidence(uuid, text);
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

commit;
