-- public.authorize_purge(p_outbox_id) -> table(v_bucket, v_path) — migration 0039.
-- The CLIENT-immediate drain gate. Owner-gated on the outbox row's (denormalized) estate; bumps attempts;
-- returns the object to remove. Excludes already-purged rows (idempotency: a purged row can never re-authorize).
-- Distinct OUT names avoid the RETURNS TABLE column-shadow trap. Source of truth.

create or replace function public.authorize_purge(p_outbox_id uuid)
 returns table(v_bucket text, v_path text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_estate uuid;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select o.estate_id into v_estate
    from public.storage_deletion_outbox o where o.id = p_outbox_id and o.status <> 'purged';
  if not found then raise exception 'outbox_not_found_or_purged' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  update public.storage_deletion_outbox set attempts = attempts + 1 where id = p_outbox_id;
  return query
    select o.bucket, o.object_path from public.storage_deletion_outbox o where o.id = p_outbox_id;
end;
$function$;

revoke execute on function public.authorize_purge(uuid) from public, anon;
grant  execute on function public.authorize_purge(uuid) to authenticated;
