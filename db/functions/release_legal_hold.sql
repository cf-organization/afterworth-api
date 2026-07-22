-- public.release_legal_hold(p_hold_id) -> void — migration 0039.
-- ADMIN-gated (admin_require_gate). Sets released_at once (the hold row persists = append-only history) +
-- a high-sev audit. After release, the document's delete/replace is no longer blocked by that hold.
-- Source of truth.

create or replace function public.release_legal_hold(p_hold_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_doc uuid; v_estate uuid;
begin
  perform public.admin_require_gate();
  select doc_id into v_doc from public.legal_holds where id = p_hold_id and released_at is null;
  if not found then raise exception 'hold_not_found_or_released' using errcode = 'P0002'; end if;

  update public.legal_holds set released_at = now(), released_by = auth.uid() where id = p_hold_id;

  select estate_id into v_estate from public.documents where id = v_doc;
  perform public.write_audit('document.legal_hold_released', 'documents', v_doc, v_estate,
    jsonb_build_object('severity', 'high', 'hold_id', p_hold_id));
end;
$function$;

revoke execute on function public.release_legal_hold(uuid) from public, anon;
grant  execute on function public.release_legal_hold(uuid) to authenticated;
