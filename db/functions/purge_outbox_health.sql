-- public.purge_outbox_health() -> jsonb — migration 0040.
-- Read-only operational heartbeat for the purge outbox + orphan debris. Admin-gated (admin_require_gate: auth ->
-- is_admin -> aal2 -> 15-min freshness). Changes NOTHING about the delete architecture (no new columns, no change
-- to storage_deletion_outbox or the sweeper). last_successful_drain_at is DERIVED as max(purged_at) (no new
-- column). orphan_candidate_count wraps list_orphan_storage_objects' proven predicate in a COUNT (shares its
-- 100-cap; agrees with the Preview list). Source of truth.

create or replace function public.purge_outbox_health()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_result jsonb;
begin
  perform public.admin_require_gate();

  select jsonb_build_object(
    'pending_count',              count(*) filter (where status = 'pending'),
    'failed_count',               count(*) filter (where status = 'failed'),
    'purged_last_24h',            count(*) filter (where status = 'purged' and purged_at > now() - interval '24 hours'),
    'oldest_pending_age_seconds', coalesce(extract(epoch from (now() - min(requested_at)
                                    filter (where status <> 'purged')))::bigint, 0),
    'max_attempts_seen',          coalesce(max(attempts) filter (where status <> 'purged'), 0),
    'last_successful_drain_at',   max(purged_at),
    'orphan_candidate_count',     (select count(*) from public.list_orphan_storage_objects(72, 100))
  )
  into v_result
  from public.storage_deletion_outbox;

  return v_result;
end;
$function$;

revoke execute on function public.purge_outbox_health() from public, anon;
grant  execute on function public.purge_outbox_health() to authenticated;
