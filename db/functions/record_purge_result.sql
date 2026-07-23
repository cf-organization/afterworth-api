-- public.record_purge_result(p_outbox_id, p_ok, p_error) -> void — migration 0039.
-- The CLIENT-immediate drain result. Owner-gated. Idempotent: ok -> purged; not-ok -> failed + last_error
-- (re-drainable by the cron/sweeper). "Object already gone" is a SUCCESS to the caller (storage remove of a
-- missing key is a no-op), so a half-completed purge converges to 'purged' on retry. Source of truth.

create or replace function public.record_purge_result(
  p_outbox_id uuid,
  p_ok        boolean,
  p_error     text default null
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_estate uuid;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select estate_id into v_estate from public.storage_deletion_outbox where id = p_outbox_id;
  if not found then raise exception 'outbox_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  if p_ok then
    update public.storage_deletion_outbox
       set status = 'purged', purged_at = now(), last_error = null where id = p_outbox_id;
  else
    update public.storage_deletion_outbox
       set status = 'failed', last_error = left(coalesce(p_error, 'unknown'), 500) where id = p_outbox_id;
  end if;
end;
$function$;

revoke execute on function public.record_purge_result(uuid, boolean, text) from public, anon;
grant  execute on function public.record_purge_result(uuid, boolean, text) to authenticated;
