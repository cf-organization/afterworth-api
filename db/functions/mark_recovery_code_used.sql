-- public.mark_recovery_code_used(p_id uuid) -> boolean
--
-- RECOVERY step 2 of 2 — marks a previously-VALIDATED recovery code USED (one-time), called by
-- /api/auth/mfa/recover ONLY AFTER the MFA factor delete succeeds. Split from validation so a
-- deleteFactor failure never burns the code (see validate_recovery_code).
--
-- SELF-SCOPED + idempotent: marks ONLY a row that belongs to auth.uid() and is still unused
-- (`user_id = auth.uid() and used_at is null`) — so a stale/foreign id can't be marked, and a
-- double-call is a no-op. Returns true if it marked a row, false otherwise (already used /
-- not the caller's). A false return is benign: the user is already recovered (the factor is
-- gone); a still-unused code with no factor to reset is inert residue, not a security issue.
--
-- Error codes: 42501 -> 403 (unauthenticated).
-- SECURITY DEFINER; relies on auth.uid(). Default EXECUTE is PUBLIC. Source of truth.

create or replace function public.mark_recovery_code_used(p_id uuid)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid();
  v_n    int;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  update public.recovery_codes
    set used_at = now()
    where id = p_id and user_id = v_user and used_at is null;

  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$function$;
