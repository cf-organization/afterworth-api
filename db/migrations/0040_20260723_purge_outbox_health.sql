-- 0040_20260723_purge_outbox_health — operational VISIBILITY for the purge outbox + orphan debris (read-only).
--
-- WHY: the outbox drain cron is DAILY (Vercel Hobby) and a cron's failure mode is SILENCE. The client-immediate
-- purge is the primary path; if it fails a row sits until 4am, and if the cron itself stalls it sits until
-- someone notices. This RPC is the heartbeat that makes "nobody noticed" impossible.
--
-- ★ CHANGES NOTHING about the delete architecture. Purely a READ: no new columns, no change to
-- storage_deletion_outbox or the orphan sweeper. Additive DEFINER read RPC only.
--
-- last_successful_drain_at is DERIVED as max(purged_at) — NO new column (prefer deriving, per the slice). It is
-- the last time any outbox row was purged (client-immediate OR cron), which is exactly "when did the drain last
-- succeed".
--
-- orphan_candidate_count REUSES list_orphan_storage_objects' proven predicate by wrapping it in a COUNT — the
-- WHERE clause is NOT re-implemented. It shares that function's 100-row cap (least(...,100)), so the count and
-- the Preview list AGREE (both cap at 100); in practice the debris is well under 100. The nested call re-runs
-- admin_require_gate (idempotent — already passed for this caller).
--
-- Admin-gated INSIDE (admin_require_gate: auth -> is_admin -> aal2 -> 15-min freshness) — the DEFINER-door
-- discipline; a direct PostgREST caller hits the identical gate. Supabase-direct (no Vercel endpoint; the api
-- function count is unchanged). Captured to VC: db/functions/purge_outbox_health.sql.

begin;

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
    -- headline signal: how long the OLDEST un-purged (pending or failed) row has been waiting.
    'oldest_pending_age_seconds', coalesce(extract(epoch from (now() - min(requested_at)
                                    filter (where status <> 'purged')))::bigint, 0),
    'max_attempts_seen',          coalesce(max(attempts) filter (where status <> 'purged'), 0),
    -- derived (no new column): the last time any row was purged = when the drain last succeeded.
    'last_successful_drain_at',   max(purged_at),
    -- reuse the sweeper's exact predicate as a COUNT (shares its 100-cap; agrees with the Preview list).
    'orphan_candidate_count',     (select count(*) from public.list_orphan_storage_objects(72, 100))
  )
  into v_result
  from public.storage_deletion_outbox;

  return v_result;
end;
$function$;

revoke execute on function public.purge_outbox_health() from public, anon;
grant  execute on function public.purge_outbox_health() to authenticated;

commit;
