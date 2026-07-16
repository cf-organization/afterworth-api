-- public.set_jurisdiction_floor(p_jurisdiction, p_floor_level, p_is_approved, p_notes, p_reason, p_case_ref) -> void
--
-- Slice C3 (migration 0026). The ADMIN write path for the counsel-owned verification-floor matrix. Upserts one
-- jurisdiction's floor. Gated inside via admin_require_gate (auth -> is_admin -> aal2 -> 15-min freshness) +
-- mandatory justification (require_breakglass_justification: reason + case_ref) + a HIGH-severity source='admin'
-- audit carrying old -> new floor. Changing a legal verification floor is high-consequence — exactly the act to
-- keep an immutable trail of. EXECUTE to authenticated only (gated inside). Source of truth — re-apply on reset.

create or replace function public.set_jurisdiction_floor(
  p_jurisdiction text,
  p_floor_level  public.verification_level,
  p_is_approved  boolean,
  p_notes        text,
  p_reason       text,
  p_case_ref     text
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_old text;
begin
  perform public.admin_require_gate();
  perform public.require_breakglass_justification(p_reason, p_case_ref);
  if p_jurisdiction is null or length(btrim(p_jurisdiction)) = 0 then
    raise exception 'jurisdiction_required' using errcode = 'P0001';
  end if;

  select floor_level::text into v_old from public.jurisdiction_policy where jurisdiction = p_jurisdiction;

  insert into public.jurisdiction_policy
    (jurisdiction, floor_level, is_counsel_approved, notes, updated_by, updated_at)
  values
    (p_jurisdiction, p_floor_level, p_is_approved, p_notes, auth.uid(), now())
  on conflict (jurisdiction) do update
    set floor_level         = excluded.floor_level,
        is_counsel_approved = excluded.is_counsel_approved,
        notes               = excluded.notes,
        updated_by          = excluded.updated_by,
        updated_at          = now();

  perform public.write_admin_breakglass_audit(
    'admin.jurisdiction_floor.set', 'jurisdiction_policy', null, null, p_reason, p_case_ref,
    jsonb_build_object('jurisdiction', p_jurisdiction, 'old_floor', v_old,
                       'new_floor', p_floor_level::text, 'is_counsel_approved', p_is_approved));
end;
$function$;
revoke execute on function public.set_jurisdiction_floor(text, public.verification_level, boolean, text, text, text)
  from public, anon;
grant  execute on function public.set_jurisdiction_floor(text, public.verification_level, boolean, text, text, text)
  to authenticated;
