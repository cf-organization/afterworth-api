-- 0064_20261001_aal2_session_currency.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECURITY FIX — an AAL2 claim must be CURRENT, not merely minted.
--
-- ★ THE MEASUREMENT THAT PROMPTED THIS, ON NONPROD, 2026-10-01, on a dedicated MFA account.
--
--     enrol + verify a TOTP factor            -> session is aal2 (token lifetime 3600s)
--     RETAIN the access token
--     call get_estate_net_worth with it       -> HTTP 200   (positive control: the gate is reached)
--     POST /api/auth/mfa/recover              -> HTTP 200   (factor DELETED, sessions REVOKED)
--     call get_estate_net_worth with the SAME token, 3s later
--                                             -> HTTP 200   ✗ ACCEPTED
--
--   For up to sixty minutes after a user reports a lost authenticator, the device holding the old
--   token retained full access to exact estate totals and holdings. `require_aal2()` read
--   `auth.jwt() ->> 'aal'`, which is a STATELESS claim: nothing that happens after the token is
--   minted can change it.
--
-- ★ WHAT THIS IS NOT. It is not a shorter JWT lifetime (that shrinks the window and never closes it,
--   and taxes every request to do so). It is not refresh-token revocation, which GoTrue already does
--   and which cannot touch an outstanding stateless access token. It is a server-side currency check
--   at the moment of the privileged call.
--
-- ★ THE AFFECTED GATES, ALL OF THEM.
--
--     via public.require_aal2()   — admin_require_gate, connections, get_connection_access_token,
--                                   get_estate_net_worth (x2), invitation_write_gate,
--                                   list_estate_assets (x2)                        [8 call sites]
--     as RESTRICTIVE RLS policy   — connections_require_aal2, normalized_assets_require_aal2
--                                   (0010), which INLINED their own copy of the claim read and so
--                                   had the identical hole on the direct-query path   [2 policies]
--
--   Both routes now evaluate ONE predicate, `public.aal2_is_current()`. The policies previously
--   duplicated the rule; that duplication is what let a fix to the function leave them behind.
--
-- ★ MUTATION SURFACE: ONE NEW FUNCTION, ONE FUNCTION BODY REPLACED, TWO POLICY PREDICATES ALTERED,
--   FOUR GRANTS. No DML. No table, column, index or constraint is touched. RLS policy alteration does
--   not validate existing rows, so no data is read or rewritten.
--
-- ★ IT FAILS CLOSED AND IT CAN ONLY NARROW ACCESS. Every leg returns false on anything it cannot
--   positively confirm — absent claim, absent/malformed session_id, missing session row, expired
--   session, missing verified factor. No input makes this grant access the old form refused.
--
-- ★ EXECUTE IS GRANTED TO anon AS WELL AS authenticated, AND THAT IS NOT AN OVERSIGHT. The two
--   restrictive policies carry no TO clause, so they apply to PUBLIC and are evaluated for anon too.
--   Without EXECUTE, anon's refusal would arrive as "permission denied for function" — a 500-shaped
--   error instead of a clean deny. The function discloses one boolean about the caller's own request
--   and takes no arguments, so it cannot be aimed at anyone else.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1 · THE PREDICATE. Body is single-sourced with db/functions/aal2_is_current.sql, which carries
--        the full rationale for each leg; `test/aal2SessionCurrency.test.ts` holds the two copies to
--        each other so this migration cannot drift from the source of truth. ──
create or replace function public.aal2_is_current()
 returns boolean
 language plpgsql
 stable
 security definer
 set search_path to 'public', 'auth', 'extensions'
as $function$
declare
  v_claims  jsonb := coalesce(auth.jwt(), '{}'::jsonb);
  v_uid     uuid;
  v_session uuid;
begin
  -- LEG 1 — the token must claim aal2. Absent claim coalesces to aal1: fail-closed.
  if coalesce(v_claims ->> 'aal', 'aal1') <> 'aal2' then
    return false;
  end if;

  v_uid := auth.uid();
  if v_uid is null then
    return false;
  end if;

  -- LEG 2 — the session that minted the claim must still be live, and be THIS user's.
  -- A malformed or absent session_id is refused rather than waived: a token shape we do not
  -- recognise is not a token we can vouch for.
  begin
    v_session := nullif(v_claims ->> 'session_id', '')::uuid;
  exception when others then
    return false;
  end;
  if v_session is null then
    return false;
  end if;
  if not exists (
    select 1 from auth.sessions s
     where s.id = v_session
       and s.user_id = v_uid
       and (s.not_after is null or s.not_after > now())
  ) then
    return false;
  end if;

  -- LEG 3 — a verified factor must still exist for this user.
  if not exists (
    select 1 from auth.mfa_factors f
     where f.user_id = v_uid
       and f.status::text = 'verified'
  ) then
    return false;
  end if;

  return true;
end;
$function$;

alter function public.aal2_is_current() owner to postgres;
revoke all on function public.aal2_is_current() from public;
grant execute on function public.aal2_is_current() to anon, authenticated, service_role;

-- ── 2 · THE GATE delegates. Message and errcode are UNCHANGED, so no client release is required. ──
create or replace function public.require_aal2()
 returns void
 language plpgsql
 stable
 set search_path to 'public', 'auth', 'extensions'
as $function$
begin
  if not public.aal2_is_current() then
    raise exception 'mfa_required' using errcode = '42501';
  end if;
end;
$function$;

-- ── 3 · THE TWO RESTRICTIVE POLICIES stop carrying their own copy of the rule.
--        ALTER, not DROP+CREATE: the name, command and RESTRICTIVE-ness are preserved by construction
--        rather than re-asserted, so this cannot accidentally downgrade a policy to PERMISSIVE.
--        `(select ...)` makes the planner evaluate the predicate once per statement (InitPlan) instead
--        of once per row. ──
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
                  WHERE p.polname = 'connections_require_aal2' AND c.relname = 'connections') THEN
    RAISE EXCEPTION '0064 PRECONDITION FAILED: policy connections_require_aal2 is absent — '
      'refusing to proceed, because a missing aal2 policy is a finding, not something to create here';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
                  WHERE p.polname = 'normalized_assets_require_aal2' AND c.relname = 'normalized_assets') THEN
    RAISE EXCEPTION '0064 PRECONDITION FAILED: policy normalized_assets_require_aal2 is absent';
  END IF;
END
$do$;

alter policy connections_require_aal2 on public.connections
  using ((select public.aal2_is_current()))
  with check ((select public.aal2_is_current()));

alter policy normalized_assets_require_aal2 on public.normalized_assets
  using ((select public.aal2_is_current()))
  with check ((select public.aal2_is_current()));

-- ── 4 · POSTCONDITIONS, IN-TRANSACTION. Nothing commits unless every one of them holds. ──
DO $do$
DECLARE
  v_prosecdef  boolean;
  v_config     text[];
  v_body       text;
  v_qual       text;
  v_check      text;
  v_restrictive boolean;
  r            record;
BEGIN
  -- (a) The predicate is DEFINER with a pinned search_path. An invoker-rights copy would raise
  --     "permission denied for table sessions" inside the two policies instead of answering.
  SELECT p.prosecdef, p.proconfig INTO v_prosecdef, v_config
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'aal2_is_current';
  IF v_prosecdef IS NULL THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: public.aal2_is_current() does not exist';
  END IF;
  IF NOT v_prosecdef THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: aal2_is_current is not SECURITY DEFINER';
  END IF;
  IF v_config IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(v_config) c WHERE c LIKE 'search\_path=%') THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: aal2_is_current has no pinned search_path';
  END IF;

  -- (b) All three legs are present in the deployed body. A body that kept only leg 1 would be the
  --     original defect wearing the new function's name, and every other assertion here would pass.
  SELECT pg_get_functiondef(p.oid) INTO v_body
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'aal2_is_current';
  IF position('auth.sessions' in v_body) = 0 THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: the session-currency leg is not in the deployed body';
  END IF;
  IF position('auth.mfa_factors' in v_body) = 0 THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: the verified-factor leg is not in the deployed body';
  END IF;
  IF position('''aal''' in v_body) = 0 AND position('"aal"' in v_body) = 0 THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: the aal-claim leg is not in the deployed body';
  END IF;

  -- (c) require_aal2 delegates, and no longer reads the claim itself. Both halves are asserted: a
  --     body that called the predicate AND kept its own claim read would pass the first half alone.
  SELECT pg_get_functiondef(p.oid) INTO v_body
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'require_aal2';
  IF position('aal2_is_current' in v_body) = 0 THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: require_aal2 does not call aal2_is_current';
  END IF;
  IF position('auth.jwt' in v_body) > 0 THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: require_aal2 still reads the claim directly';
  END IF;
  IF position('mfa_required' in v_body) = 0 THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: require_aal2 no longer raises the mfa_required sentinel';
  END IF;

  -- (d) EACH policy BY IDENTITY: still RESTRICTIVE, still FOR ALL, both expressions re-pointed, and
  --     neither retaining the inlined claim read. Counting policies would not prove any of this.
  FOR r IN SELECT unnest(ARRAY['connections_require_aal2','normalized_assets_require_aal2']) AS nm
  LOOP
    SELECT NOT p.polpermissive,
           pg_get_expr(p.polqual, p.polrelid),
           pg_get_expr(p.polwithcheck, p.polrelid)
      INTO v_restrictive, v_qual, v_check
      FROM pg_policy p WHERE p.polname = r.nm;
    IF v_restrictive IS NULL THEN
      RAISE EXCEPTION '0064 POSTCONDITION FAILED: policy % vanished', r.nm;
    END IF;
    IF NOT v_restrictive THEN
      RAISE EXCEPTION '0064 POSTCONDITION FAILED: policy % is no longer RESTRICTIVE', r.nm;
    END IF;
    IF v_qual IS NULL OR position('aal2_is_current' in v_qual) = 0 THEN
      RAISE EXCEPTION '0064 POSTCONDITION FAILED: policy % USING does not call aal2_is_current (%)', r.nm, v_qual;
    END IF;
    IF v_check IS NULL OR position('aal2_is_current' in v_check) = 0 THEN
      RAISE EXCEPTION '0064 POSTCONDITION FAILED: policy % WITH CHECK does not call aal2_is_current (%)', r.nm, v_check;
    END IF;
    IF position('aal1' in v_qual) > 0 OR position('aal1' in coalesce(v_check,'')) > 0 THEN
      RAISE EXCEPTION '0064 POSTCONDITION FAILED: policy % still inlines the claim read (%)', r.nm, v_qual;
    END IF;
  END LOOP;

  -- (e) The grant that keeps a refusal a refusal rather than a function-permission error.
  IF NOT has_function_privilege('authenticated', 'public.aal2_is_current()', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.aal2_is_current()', 'EXECUTE') THEN
    RAISE EXCEPTION '0064 POSTCONDITION FAILED: anon/authenticated cannot EXECUTE aal2_is_current';
  END IF;

  RAISE NOTICE '0064 OK — aal2 currency is enforced by one predicate across 8 call sites and 2 policies';
END
$do$;

COMMIT;
