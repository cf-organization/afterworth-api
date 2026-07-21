-- public.update_vault_document(p_doc_id uuid, p_title text default null, p_doc_subtype text default null,
--                              p_sensitivity text default null) -> void
--
-- Migration 0035 — the owner vault-doc UPDATE door: METADATA-ONLY. The IMMUTABLE fields (estate_id, owner_id,
-- storage_path, mime_type, size_bytes, is_encrypted, created_at) are UNREPRESENTABLE — they are NOT parameters,
-- so a caller cannot touch them (the strongest "rejected/ignored"). Gate: auth -> resolve the row -> owner gate
-- on the ROW's estate_id (never a param). At least one field required (no_fields_to_update). A p_doc_subtype
-- change RE-DERIVES doc_type from the catalog (same unknown/inactive rejections as create). Audit records the
-- CHANGED FIELD NAMES only (never the values). EXECUTE authenticated; REVOKE public/anon. Source of truth.

create or replace function public.update_vault_document(
  p_doc_id      uuid,
  p_title       text default null,
  p_doc_subtype text default null,
  p_sensitivity text default null
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid      uuid := auth.uid();
  v_estate   uuid;
  v_new_type text;
  v_changed  text[] := '{}';
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;

  select estate_id into v_estate from public.documents where id = p_doc_id;
  if not found then
    raise exception 'document_not_found' using errcode = 'P0002';
  end if;
  if not public.is_estate_owner(v_estate) then
    raise exception 'not_estate_owner' using errcode = '42501';
  end if;

  if p_title is null and p_doc_subtype is null and p_sensitivity is null then
    raise exception 'no_fields_to_update' using errcode = 'P0001';
  end if;

  if p_title is not null then
    if length(btrim(p_title)) = 0 then
      raise exception 'title_required' using errcode = 'P0001';
    end if;
    if length(p_title) > 200 then
      raise exception 'title_too_long' using errcode = 'P0001';
    end if;
    update public.documents set title = btrim(p_title) where id = p_doc_id;
    v_changed := array_append(v_changed, 'title');
  end if;

  if p_doc_subtype is not null then
    select ds.doc_type into v_new_type
      from public.document_subtype ds
      where ds.subtype = p_doc_subtype and ds.is_active;
    if not found then
      if exists (select 1 from public.document_subtype where subtype = p_doc_subtype) then
        raise exception 'inactive_subtype' using errcode = 'P0001';
      else
        raise exception 'unknown_subtype' using errcode = 'P0001';
      end if;
    end if;
    update public.documents set doc_subtype = p_doc_subtype, doc_type = v_new_type where id = p_doc_id;
    v_changed := array_append(v_changed, 'doc_subtype');
    v_changed := array_append(v_changed, 'doc_type');
  end if;

  if p_sensitivity is not null then
    if p_sensitivity not in ('low','medium','high','restricted','sealed') then
      raise exception 'invalid_sensitivity' using errcode = 'P0001';
    end if;
    update public.documents set sensitivity = p_sensitivity where id = p_doc_id;
    v_changed := array_append(v_changed, 'sensitivity');
  end if;

  perform public.write_audit('document.updated', 'documents', p_doc_id, v_estate,
    jsonb_build_object('doc_id', p_doc_id, 'changed', to_jsonb(v_changed), 'via', 'update_vault_document'));
end;
$function$;

revoke execute on function public.update_vault_document(uuid, text, text, text) from public, anon;
grant  execute on function public.update_vault_document(uuid, text, text, text) to authenticated;
