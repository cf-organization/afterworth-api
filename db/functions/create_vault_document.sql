-- public.create_vault_document(p_estate uuid, p_doc_id uuid, p_storage_path text, p_title text,
--                              p_doc_subtype text, p_sensitivity text default 'sealed') -> uuid
--
-- Migration 0035 — the owner vault-doc CREATE door (direct-to-Supabase; the client uploads bytes to storage
-- then calls this). Row creation is DEFINER-RPC-ONLY (0030 dropped documents_write). Gate + checks, in order:
--   auth -> is_estate_owner(p_estate) -> estate exists -> title (trim+<=200) -> subtype-in/both-out (catalog
--   lookup: unknown_subtype / inactive_subtype, derive coarse doc_type) -> sensitivity in the server 5-set ->
--   PATH AGREEMENT (regex: exactly estates/<p_estate>/vault/<p_doc_id>.<ext>, kills traversal, ties id<->object)
--   -> object MUST exist (size/mime read from storage, never client-trusted) -> upload_policy quota
--   (max_upload_bytes + allowed_mime_types) -> insert ONE row (owner_id=auth.uid(), is_encrypted=false,
--   persist BOTH doc_type + doc_subtype) -> write_audit('document.created', changed via='create_vault_document').
-- Multi-source agreement (p_estate == path-estate == row estate_id, gated is_estate_owner) mirrors
-- submit_claim_with_evidence (0031). EXECUTE authenticated; REVOKE public/anon. Source of truth — re-apply on reset.

create or replace function public.create_vault_document(
  p_estate       uuid,
  p_doc_id       uuid,
  p_storage_path text,
  p_title        text,
  p_doc_subtype  text,
  p_sensitivity  text default 'sealed'
)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_doc_type  text;
  v_size      bigint;
  v_mime      text;
  v_max_bytes bigint;
  v_mimes     text[];
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    raise exception 'not_estate_owner' using errcode = '42501';
  end if;
  if not exists (select 1 from public.estates where id = p_estate) then
    raise exception 'estate_not_found' using errcode = 'P0002';
  end if;

  if p_title is null or length(btrim(p_title)) = 0 then
    raise exception 'title_required' using errcode = 'P0001';
  end if;
  if length(p_title) > 200 then
    raise exception 'title_too_long' using errcode = 'P0001';
  end if;

  select ds.doc_type into v_doc_type
    from public.document_subtype ds
    where ds.subtype = p_doc_subtype and ds.is_active;
  if not found then
    if exists (select 1 from public.document_subtype where subtype = p_doc_subtype) then
      raise exception 'inactive_subtype' using errcode = 'P0001';
    else
      raise exception 'unknown_subtype' using errcode = 'P0001';
    end if;
  end if;

  if p_sensitivity is not null
     and p_sensitivity not in ('low','medium','high','restricted','sealed') then
    raise exception 'invalid_sensitivity' using errcode = 'P0001';
  end if;

  if p_storage_path !~ ('^estates/' || p_estate::text || '/vault/' || p_doc_id::text || '\.[a-zA-Z0-9]+$') then
    raise exception 'vault_path_mismatch' using errcode = 'P0001';
  end if;

  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_size, v_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_storage_path;
  if not found then
    raise exception 'vault_object_missing' using errcode = 'P0002';
  end if;

  select max_upload_bytes, allowed_mime_types into v_max_bytes, v_mimes
    from public.upload_policy where id = 1;
  if coalesce(v_size, 0) > v_max_bytes then
    raise exception 'vault_too_large' using errcode = 'P0001';
  end if;
  if v_mime is null or not (v_mime = any(v_mimes)) then
    raise exception 'vault_mime_rejected' using errcode = 'P0001';
  end if;

  insert into public.documents
    (id, estate_id, owner_id, doc_type, doc_subtype, title, storage_path, mime_type, size_bytes, is_encrypted, sensitivity)
  values
    (p_doc_id, p_estate, v_uid, v_doc_type, p_doc_subtype, btrim(p_title), p_storage_path, v_mime, v_size, false,
     coalesce(p_sensitivity, 'sealed'));

  perform public.write_audit('document.created', 'documents', p_doc_id, p_estate,
    jsonb_build_object('doc_id', p_doc_id, 'doc_type', v_doc_type, 'doc_subtype', p_doc_subtype,
                       'via', 'create_vault_document'));

  return p_doc_id;
end;
$function$;

revoke execute on function public.create_vault_document(uuid, uuid, text, text, text, text) from public, anon;
grant  execute on function public.create_vault_document(uuid, uuid, text, text, text, text) to authenticated;
