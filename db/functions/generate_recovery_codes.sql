-- public.generate_recovery_codes() -> text[]   (the plaintext codes, shown ONCE)
--
-- Mints a fresh set of one-time MFA recovery codes for the CURRENT user (auth.uid()) and
-- returns the PLAINTEXT — the only time it is ever available; only bcrypt hashes are stored.
-- Called at enrollment (right after the first factor verify → session is aal2) and on
-- regenerate-in-Settings. See db/migrations/0006 + docs/live-data-migration.md.
--
-- SELF-SCOPED: operates only on auth.uid()'s own codes — no estate, no cross-user. Requires
-- aal2 (you must be MFA-authed to mint codes; true at first enrollment via the just-verified
-- factor). The aal1 recovery (validate) path is the inverse (no aal2 — the user is locked out).
--
-- ATOMIC: a single function invocation is one transaction (PostgREST wraps each rpc call), so
-- delete-old + insert-new commit together or roll back together — a mid-failure can NEVER
-- leave the user with zero codes (on rollback they keep their existing set). (Edge: if the
-- txn commits but the response is lost in transit, the new codes exist unseen — the user still
-- has their TOTP and can regenerate; not a lockout.)
--
-- Error codes: 42501 -> 403 (unauthenticated / not aal2).
-- SECURITY DEFINER; relies on auth.uid(). Default EXECUTE is PUBLIC (matches the other RPCs).
-- Source of truth — re-apply on DB reset.

create or replace function public.generate_recovery_codes()
 returns text[]
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user  uuid := auth.uid();
  v_codes text[] := '{}';
  v_code  text;
  i       int;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Must be MFA-authed (aal2) to (re)generate.
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa required to generate recovery codes' using errcode = '42501';
  end if;

  -- Regenerate REPLACES the prior set (old codes invalidated). Atomic with the inserts below.
  delete from public.recovery_codes where user_id = v_user;

  for i in 1..10 loop
    -- 64-bit, hex (16 chars; user-typeable). bcrypt makes offline brute-force infeasible even
    -- at this length; iOS formats for display (e.g. groups of 4).
    v_code := encode(extensions.gen_random_bytes(8), 'hex');
    insert into public.recovery_codes (user_id, code_hash)
      values (v_user, extensions.crypt(v_code, extensions.gen_salt('bf')));
    v_codes := array_append(v_codes, v_code);
  end loop;

  -- Fresh code set invalidates any prior lockout/attempt state.
  delete from public.mfa_recovery_attempts where user_id = v_user;

  return v_codes;   -- plaintext, shown ONCE
end;
$function$;
