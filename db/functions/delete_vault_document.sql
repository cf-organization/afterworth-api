-- public.delete_vault_document(p_doc_id) -> uuid (outbox id) — migration 0039.
-- Owner-gated HARD delete of a vault document: blocking gauntlet (active claim / legal hold / retention, with
-- machine-readable reason codes) → DELETE the documents row (DEFINER bypasses the RLS write-lockdown; rejected-
-- claim evidence FKs SET NULL) → enqueue the purge OUTBOX event (SAME TX) → immutable high-sev audit TOMBSTONE.
-- Returns the outbox id for the client-immediate purge. Source of truth.

create or replace function public.delete_vault_document(p_doc_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_path   text;
  v_outbox uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id, storage_path into v_estate, v_path from public.documents where id = p_doc_id;
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

  delete from public.documents where id = p_doc_id;

  insert into public.storage_deletion_outbox (estate_id, bucket, object_path, reason, requested_by)
  values (v_estate, 'documents', v_path, 'document_deleted', v_uid)
  returning id into v_outbox;

  perform public.write_audit('document.deleted', 'documents', p_doc_id, v_estate,
    jsonb_build_object('severity', 'high', 'storage_path', v_path, 'reason', 'document_deleted',
                       'outbox_id', v_outbox, 'via', 'delete_vault_document'));

  return v_outbox;
end;
$function$;

revoke execute on function public.delete_vault_document(uuid) from public, anon;
grant  execute on function public.delete_vault_document(uuid) to authenticated;
