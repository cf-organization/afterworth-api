-- public.write_admin_breakglass_audit(p_action, p_table, p_target, p_estate, p_reason, p_case_ref, p_meta) -> void
--
-- REUSABLE break-glass primitive: writes ONE high-severity accountability row to audit_logs with
-- source='admin' (an allowed source value — verified live 2026-07-15), actor server-stamped (auth.uid()),
-- and metadata merged with {severity:'high', breakglass:true, reason, case_ref}. audit_logs has no severity
-- column, so severity lives in metadata. "Immutable" here = server-stamped actor + append-only via grants
-- (client UPDATE/DELETE revoked), not a trigger. INTERNAL (client roles revoked). SECURITY DEFINER so it can
-- write audit_logs regardless of the caller's grants (write_audit's direct EXECUTE is revoked from clients).
-- Created by migration 0022. Source of truth — re-apply on reset.

create or replace function public.write_admin_breakglass_audit(
  p_action   text,
  p_table    text,
  p_target   uuid,
  p_estate   uuid,
  p_reason   text,
  p_case_ref text,
  p_meta     jsonb default '{}'::jsonb
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    auth.uid(), p_estate, p_action, p_table, p_target,
    coalesce(p_meta, '{}'::jsonb)
      || jsonb_build_object('severity', 'high', 'breakglass', true, 'reason', p_reason, 'case_ref', p_case_ref),
    'admin'
  );
end;
$function$;
revoke execute on function public.write_admin_breakglass_audit(text, text, uuid, uuid, text, text, jsonb)
  from public, anon, authenticated;
