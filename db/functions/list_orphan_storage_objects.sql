-- public.list_orphan_storage_objects(p_grace_hours int default 72, p_max int default 100)
--   -> TABLE(object_name text, created_at timestamptz, size_bytes bigint)
--
-- Migration 0034 — the orphan-sweeper's IDENTIFY step. Returns `documents`-bucket objects older than the grace
-- with NO documents.storage_path referencing them (the SOLE authoritative reference — CQ2). Whole bucket
-- (lock #7); batch-capped at 100. Admin-gated inside (admin_require_gate); DEFINER reads storage.objects +
-- documents as owner. This RPC only IDENTIFIES — byte deletion needs the storage API (afterworth-api
-- sweep_orphans action), because deleting a storage.objects ROW does NOT delete the S3 bytes.
--
-- ★ FORWARD-COMPAT INVARIANT: any path writing to the documents bucket MUST create its documents row within the
-- grace window (72h) or its object is reclaimed — binds the upcoming owner vault-doc upload RPC (no draft/
-- staging/resumable pattern that leaves an object row-less past the window). EXECUTE authenticated only.
-- Source of truth — re-apply on reset.

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
      and o.name not like '%.emptyFolderPlaceholder'   -- Supabase folder markers are system artifacts, not orphan uploads
      and o.created_at < now() - make_interval(hours => greatest(coalesce(p_grace_hours, 72), 0))
      and not exists (select 1 from public.documents d where d.storage_path = o.name)
    order by o.created_at
    limit least(greatest(coalesce(p_max, 100), 1), 100);
end;
$function$;
revoke execute on function public.list_orphan_storage_objects(int, int) from public, anon;
grant  execute on function public.list_orphan_storage_objects(int, int) to authenticated;
