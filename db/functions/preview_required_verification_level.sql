-- public.preview_required_verification_level(p_estate uuid) -> text
--
-- Slice C3 (migration 0027). The ONLY client door to the verification-level RESULT. Gated to a PARTY of the
-- estate (designated executor / owner / admin): the result is not secret to the claimant (they must know what
-- verification to pass), but a non-party cannot probe arbitrary estates, and the jurisdiction MATRIX stays
-- world-unreadable (protected separately). Delegates to the DEFINER-internal engine required_verification_level.
-- EXECUTE to authenticated only. Errors: 42501 auth_required / not_authorized. Source of truth — re-apply on reset.

create or replace function public.preview_required_verification_level(p_estate uuid)
 returns text
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not (public.is_estate_executor(p_estate, v_uid)
          or public.is_estate_owner(p_estate)
          or public.is_admin()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.required_verification_level(p_estate)::text;
end;
$function$;
revoke execute on function public.preview_required_verification_level(uuid) from public, anon;
grant  execute on function public.preview_required_verification_level(uuid) to authenticated;
