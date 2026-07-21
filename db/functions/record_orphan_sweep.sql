-- public.record_orphan_sweep(p_mode text, p_paths text[], p_grace_hours int, p_batch_cap int) -> void
--
-- Migration 0034 — audits an orphan-sweep run in BOTH modes (dry_run + delete). Deleting PII must be traceable:
-- action 'storage.orphans_swept', source='admin', actor=auth.uid(), the paths + counts + grace + cap in metadata
-- (severity high; audit_logs has no severity column). Admin-gated inside (admin_require_gate); DEFINER writes
-- audit_logs as owner. Called by the afterworth-api sweep_orphans action after listing (dry) or removing (real).
-- EXECUTE authenticated only. Source of truth — re-apply on reset.

create or replace function public.record_orphan_sweep(
  p_mode        text,
  p_paths       text[],
  p_grace_hours int,
  p_batch_cap   int
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid();
begin
  perform public.admin_require_gate();
  if p_mode not in ('dry_run', 'delete') then
    raise exception 'invalid_mode' using errcode = 'P0001';
  end if;
  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    v_uid, null, 'storage.orphans_swept', 'storage.objects', null,
    jsonb_build_object(
      'severity', 'high',
      'mode', p_mode,
      'count', coalesce(array_length(p_paths, 1), 0),
      'grace_hours', p_grace_hours,
      'batch_cap', p_batch_cap,
      'paths', to_jsonb(coalesce(p_paths, array[]::text[]))
    ),
    'admin'
  );
end;
$function$;
revoke execute on function public.record_orphan_sweep(text, text[], int, int) from public, anon;
grant  execute on function public.record_orphan_sweep(text, text[], int, int) to authenticated;
