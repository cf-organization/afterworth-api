-- public.admin_list_jurisdiction_policy() -> TABLE(jurisdiction, floor_level, is_counsel_approved, notes,
--                                                  updated_by, updated_at)
--
-- Slice C3 (migration 0026). The ONLY read path for the verification-floor matrix — admins/counsel view it;
-- clients cannot (the matrix is an attack map, world-unreadable). Gated inside via admin_require_gate.
-- EXECUTE to authenticated only. Source of truth — re-apply on reset.

create or replace function public.admin_list_jurisdiction_policy()
 returns table(
   jurisdiction text, floor_level text, is_counsel_approved boolean,
   notes text, updated_by uuid, updated_at timestamptz
 )
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.admin_require_gate();
  return query
    select j.jurisdiction, j.floor_level::text, j.is_counsel_approved, j.notes, j.updated_by, j.updated_at
    from public.jurisdiction_policy j
    order by j.jurisdiction;
end;
$function$;
revoke execute on function public.admin_list_jurisdiction_policy() from public, anon;
grant  execute on function public.admin_list_jurisdiction_policy() to authenticated;
