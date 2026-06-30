-- public.validate_recovery_code(p_code text) -> uuid   (the matching code's id, or NULL)
--
-- RECOVERY step 1 of 2 — VALIDATE ONLY (do NOT mark used). Checks that p_code is an UNUSED
-- recovery code for the CURRENT user (auth.uid()) and returns its id, WITHOUT consuming it.
-- Returns NULL on a wrong/already-used code.
--
-- WHY SPLIT FROM MARK (the load-bearing reason): the credential must NOT be burned until the
-- action it authorizes succeeds. /api/auth/mfa/recover validates here, then deletes the MFA
-- factor (the admin op), and ONLY after that succeeds calls mark_recovery_code_used(id). If
-- deleteFactor fails (transient / partial), the code stays UNUSED → the user retries cleanly,
-- no burned code stranding them. (Accepted: a small validated-but-not-yet-marked window allows
-- a concurrent double-use — negligible on a low-concurrency recovery path, and far better than
-- burning codes on transient failures.)
--
-- SELF-SCOPED: operates only on auth.uid()'s own codes. Runs at aal1 ON PURPOSE — the user lost
-- their authenticator (the inverse of generate_recovery_codes, which requires aal2). Does NOT
-- touch auth.mfa_factors.
--
-- BRUTE-FORCE GUARD (defense-in-depth on top of 64-bit codes + bcrypt): a per-user lockout in
-- mfa_recovery_attempts — 5 consecutive WRONG codes -> 15-minute lock (the 5th failure SETS the
-- lock; the next call hits it -> P0001); cleared on a valid code. The endpoint also applies the
-- rate-limit hook and is a named consumer of the deferred real rate-limiting. Thresholds tunable.
--
-- Error codes: 42501 -> 403 (unauthenticated). P0001 -> handled-as-locked (429) by the endpoint.
-- A wrong/used code returns NULL (not an exception).
-- SECURITY DEFINER; relies on auth.uid(). Default EXECUTE is PUBLIC. Source of truth.

create or replace function public.validate_recovery_code(p_code text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user         uuid := auth.uid();
  v_id           uuid;
  v_locked_until timestamptz;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Lockout check (brute-force guard) — reject without even testing the code.
  select locked_until into v_locked_until
  from public.mfa_recovery_attempts where user_id = v_user;
  if v_locked_until is not null and v_locked_until > now() then
    raise exception 'too many recovery attempts; try again later' using errcode = 'P0001';
  end if;

  -- Match an UNUSED code for this user (bcrypt compare; ~10 rows). Do NOT mark used.
  select id into v_id
  from public.recovery_codes
  where user_id = v_user
    and used_at is null
    and code_hash = extensions.crypt(p_code, code_hash)
  limit 1;

  if v_id is null then
    -- Wrong/used code → a failed attempt; lock after 5 consecutive failures.
    insert into public.mfa_recovery_attempts (user_id, failed_count, updated_at)
      values (v_user, 1, now())
    on conflict (user_id) do update
      set failed_count = public.mfa_recovery_attempts.failed_count + 1,
          locked_until = case
            when public.mfa_recovery_attempts.failed_count + 1 >= 5
              then now() + interval '15 minutes'
            else null
          end,
          updated_at = now();
    return null;
  end if;

  -- Valid code presented → clear the attempt/lockout state (legitimacy proven). NOT consumed yet.
  delete from public.mfa_recovery_attempts where user_id = v_user;
  return v_id;
end;
$function$;
