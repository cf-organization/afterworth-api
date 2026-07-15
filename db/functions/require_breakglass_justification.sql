-- public.require_breakglass_justification(p_reason text, p_case_ref text) -> void
--
-- REUSABLE break-glass primitive: raises unless BOTH a reason and a case reference are non-empty. A
-- break-glass action with no paper trail is exactly what the accountability layer exists to prevent, so
-- this is mandatory at every break-glass entrypoint. INTERNAL (client roles revoked; DEFINER callers use
-- it as owner). Errors: 'breakglass_reason_required' / 'breakglass_case_ref_required' (P0001).
-- Created by migration 0022. Source of truth — re-apply on reset.

create or replace function public.require_breakglass_justification(p_reason text, p_case_ref text)
 returns void
 language plpgsql
 set search_path to 'public'
as $function$
begin
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'breakglass_reason_required' using errcode = 'P0001';
  end if;
  if p_case_ref is null or length(btrim(p_case_ref)) = 0 then
    raise exception 'breakglass_case_ref_required' using errcode = 'P0001';
  end if;
end;
$function$;
revoke execute on function public.require_breakglass_justification(text, text) from public, anon, authenticated;
