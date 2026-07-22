-- public.place_legal_hold(p_doc_id, p_reason) -> uuid — migration 0039.
-- ADMIN-gated (admin_require_gate: auth -> is_admin -> aal2 -> 15-min freshness). The document owner must NOT be
-- able to place/lift a hold on their own estate. Inserts an append-only legal_holds row + a high-sev audit.
-- An active hold (released_at IS NULL) blocks delete_vault_document / replace_vault_document. Source of truth.

create or replace function public.place_legal_hold(p_doc_id uuid, p_reason text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id uuid; v_estate uuid;
begin
  perform public.admin_require_gate();
  select estate_id into v_estate from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then raise exception 'reason_required' using errcode = 'P0001'; end if;

  insert into public.legal_holds (doc_id, reason, placed_by)
  values (p_doc_id, btrim(p_reason), auth.uid()) returning id into v_id;

  perform public.write_audit('document.legal_hold_placed', 'documents', p_doc_id, v_estate,
    jsonb_build_object('severity', 'high', 'hold_id', v_id, 'reason', btrim(p_reason)));
  return v_id;
end;
$function$;

revoke execute on function public.place_legal_hold(uuid, text) from public, anon;
grant  execute on function public.place_legal_hold(uuid, text) to authenticated;
