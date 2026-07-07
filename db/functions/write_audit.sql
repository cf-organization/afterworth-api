-- public.write_audit(p_action text, p_table text, p_target uuid, p_estate uuid, p_meta jsonb) -> void
--
-- The shared audit-trail writer: inserts ONE audit_logs row stamped with actor = auth.uid(). Called by
-- the mutating DEFINER RPCs (create_connection, create_asset_grant, grant create/revoke, ...). SECURITY
-- DEFINER so it can write audit_logs regardless of the caller's own grants.
--
-- CAPTURED FROM LIVE — was live-only, NOT in version control. This file is now the VC record; re-apply
-- on DB reset.
--
-- NOTE: inserts ONLY the caller-supplied p_meta — it does NOT re-read any source row, so the caller
-- controls exactly what is recorded (no accidental balance/token capture in the audit trail). This was
-- verified as part of the aal2-gate audit (write_audit can't leak an exact financial value).
-- Source of truth.

create or replace function public.write_audit(
  p_action text,
  p_table  text,
  p_target uuid,
  p_estate uuid,
  p_meta   jsonb default '{}'::jsonb
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  insert into audit_logs(actor_id, estate_id, action, target_table, target_id, metadata)
  values (auth.uid(), p_estate, p_action, p_table, p_target, p_meta);
end $function$;
