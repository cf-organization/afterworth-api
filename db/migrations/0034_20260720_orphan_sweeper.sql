-- 0034_20260720_orphan_sweeper — orphan-upload retention sweeper (the C1.6a-iOS V1-retry boundary).
--
-- An interrupted evidence submit (upload succeeds, RPC never runs) leaves a storage object with NO authoritative
-- row — death-certificate PII with no owner record. This closes that boundary: identify + delete such orphans.
--
-- ★ FORWARD-COMPAT INVARIANT (load-bearing): documents.storage_path is the SOLE authoritative reference to a
--   `documents`-bucket object (verified live — CQ2). Therefore **any path that writes to the documents bucket
--   MUST create its documents row within the grace window (72h), or the sweeper WILL reclaim the object.** The
--   upcoming OWNER VAULT-DOC UPLOAD RPC is bound by this: a draft / staging / resumable-upload pattern that
--   leaves an object row-less for >72h would be indistinguishable from an orphan and would be deleted. Upload
--   → row must stay within the window (the current flow is seconds).
--
-- WHY AN RPC + ENDPOINT, NOT SQL: deleting a storage.objects ROW does NOT delete the S3 BYTES (verified: the
--   storage service keys S3 ops off that row; a SQL delete orphans the bytes WORSE, and `protect_objects_delete`
--   guards raw SQL deletes anyway). Byte deletion REQUIRES the storage API (service-role) — so this RPC only
--   IDENTIFIES orphans; the afterworth-api sweep_orphans action does the service-role `storage.remove`.
--
-- Conservative predicate (fail-safe against the upload-before-row race): age > grace AND no documents row. The
-- grace is a param (default 72h) so a dry-run can preview with a smaller window; the console always sends 72h.
-- Both RPCs are admin-gated INSIDE (admin_require_gate: auth -> is_admin -> aal2 -> 15-min freshness), DEFINER
-- (read storage.objects + write audit as owner), EXECUTE authenticated only. Captured in db/functions/.

begin;

-- ---- Identify orphans (whole `documents` bucket, per lock #7). Batch-capped at 100. DEFINER reads
--      storage.objects + documents as owner. Admin-gated. Grace param default 72h. ----
create or replace function public.list_orphan_storage_objects(
  p_grace_hours int default 72,
  p_max         int default 100
)
 returns table(object_name text, created_at timestamptz, size_bytes bigint)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.admin_require_gate();
  return query
    select o.name, o.created_at, (o.metadata->>'size')::bigint
    from storage.objects o
    where o.bucket_id = 'documents'
      and o.created_at < now() - make_interval(hours => greatest(coalesce(p_grace_hours, 72), 0))
      and not exists (select 1 from public.documents d where d.storage_path = o.name)
    order by o.created_at
    limit least(greatest(coalesce(p_max, 100), 1), 100);
end;
$function$;
revoke execute on function public.list_orphan_storage_objects(int, int) from public, anon;
grant  execute on function public.list_orphan_storage_objects(int, int) to authenticated;

-- ---- Audit a sweep run — BOTH modes (dry_run + delete). Deleting PII must leave a trace: action
--      storage.orphans_swept, source='admin', actor=auth.uid(), paths + counts in metadata. Admin-gated. ----
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

commit;
