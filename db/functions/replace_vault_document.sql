-- public.replace_vault_document(p_doc_id, p_new_storage_path) -> uuid (outbox id) — migration 0039.
-- Owner-gated: same blocking gauntlet as delete (replace PURGES the old bytes) → atomically SWITCH storage_path
-- to the new object (bytes-only: path/mime/size; title/subtype/sensitivity via update_vault_document) → enqueue
-- deletion of the FORMER object (SAME TX). New path: estates/<estate>/vault/<doc_id>[-<token>].<ext>, MUST exist,
-- policy-quota'd, and DIFFER from the current object. NO versioning. Returns the outbox id. Source of truth.

create or replace function public.replace_vault_document(
  p_doc_id           uuid,
  p_new_storage_path text
)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_estate    uuid;
  v_old_path  text;
  v_size      bigint;
  v_mime      text;
  v_max_bytes bigint;
  v_mimes     text[];
  v_outbox    uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id, storage_path into v_estate, v_old_path from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  if exists (select 1 from public.claim_packets c
             where (c.death_certificate_doc_id = p_doc_id or c.executor_id_doc_id = p_doc_id)
               and c.status <> 'rejected') then
    raise exception 'blocked_active_claim' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.legal_holds h where h.doc_id = p_doc_id and h.released_at is null) then
    raise exception 'blocked_legal_hold' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.documents d
             where d.id = p_doc_id and d.retention_until is not null and d.retention_until > now()) then
    raise exception 'blocked_retention' using errcode = 'P0001';
  end if;

  if p_new_storage_path !~ ('^estates/' || v_estate::text || '/vault/' || p_doc_id::text || '(-[a-zA-Z0-9]+)?\.[a-zA-Z0-9]+$') then
    raise exception 'vault_path_mismatch' using errcode = 'P0001';
  end if;
  if p_new_storage_path = v_old_path then
    raise exception 'replace_same_object' using errcode = 'P0001';
  end if;

  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_size, v_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_new_storage_path;
  if not found then raise exception 'vault_object_missing' using errcode = 'P0002'; end if;

  select max_upload_bytes, allowed_mime_types into v_max_bytes, v_mimes from public.upload_policy where id = 1;
  if coalesce(v_size, 0) > v_max_bytes then raise exception 'vault_too_large' using errcode = 'P0001'; end if;
  if v_mime is null or not (v_mime = any(v_mimes)) then raise exception 'vault_mime_rejected' using errcode = 'P0001'; end if;

  update public.documents
     set storage_path = p_new_storage_path, mime_type = v_mime, size_bytes = v_size
   where id = p_doc_id;

  insert into public.storage_deletion_outbox (estate_id, bucket, object_path, reason, requested_by)
  values (v_estate, 'documents', v_old_path, 'document_replaced', v_uid)
  returning id into v_outbox;

  perform public.write_audit('document.replaced', 'documents', p_doc_id, v_estate,
    jsonb_build_object('severity', 'high', 'old_path', v_old_path, 'new_path', p_new_storage_path,
                       'outbox_id', v_outbox, 'via', 'replace_vault_document'));

  return v_outbox;
end;
$function$;

revoke execute on function public.replace_vault_document(uuid, text) from public, anon;
grant  execute on function public.replace_vault_document(uuid, text) to authenticated;
