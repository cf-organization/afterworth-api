-- public.is_estate_executor(p_estate uuid, p_user uuid) -> boolean
--
-- The CANONICAL fiduciary predicate: is p_user an ACTIVE executor/trustee designee of p_estate? SECURITY
-- DEFINER (reads estate_designations regardless of the caller's grants — the table is grant-less), STABLE,
-- boolean leaks nothing. Serves BOTH the encrypted_instructions RLS (auth.uid()) and the future claims path
-- (requested_by). Created by migration 0019 (Slice R). EXECUTE granted to authenticated only. Verified live
-- 2026-07-15 (active executor/trustee -> t, non-designee -> f, revoked -> f). Source of truth — re-apply on reset.

create or replace function public.is_estate_executor(p_estate uuid, p_user uuid)
 returns boolean
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select exists (
    select 1 from public.estate_designations d
    where d.estate_id = p_estate
      and d.user_id    = p_user
      and d.designation_type in ('executor','trustee')
      and d.status = 'active'
  );
$function$;
revoke execute on function public.is_estate_executor(uuid, uuid) from public, anon;
grant  execute on function public.is_estate_executor(uuid, uuid) to authenticated;
