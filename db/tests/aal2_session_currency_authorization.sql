-- db/tests/aal2_session_currency_authorization.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ AN AAL2 CLAIM IS A MEMORY. THIS SUITE IS ABOUT WHETHER THE SERVER STILL AGREES WITH IT.
--
-- MEASURED ON NONPROD, 2026-10-01, on a dedicated MFA account that owns nothing else:
--
--     enrol + verify TOTP                     -> aal2, access token lifetime 3600s
--     RETAIN the access token
--     get_estate_net_worth with it            -> HTTP 200   (control: the gate is reached)
--     POST /api/auth/mfa/recover              -> HTTP 200   (factor DELETED, sessions REVOKED)
--     the SAME token, three seconds later     -> HTTP 200   ✗ STILL ACCEPTED
--
-- So for up to an hour after "I lost my authenticator", the lost device kept reading exact estate
-- totals. 0064 closes it by asking the server, at call time, whether the assurance is still true.
--
-- ★ WHAT THIS SUITE MUST NOT BE. A suite that only showed refusals could be green because the fixture
--   is broken — a missing estate, a non-owner caller, an unloaded function all refuse too. So every
--   refusal section is bracketed by the SAME call SUCCEEDING, before and after. §1 establishes the
--   positive control, each §2/§3 scenario breaks exactly one fact, and §2e restores it and requires
--   the original success back. A refusal is only evidence when the identical call just worked.
--
-- ★ AND IT MUST NOT PASS ON THE OLD CODE. §0 asserts the predicate is LOADED and SECURITY DEFINER and
--   that `require_aal2` delegates to it, BEFORE any authorization claim is evaluated — the repository's
--   own rule, after a Dashboard audit once passed 63 assertions against an empty file list.
--
-- Loaded after the financial surfaces it exercises and before the exit matrix. It owns its fixture
-- entirely (its own users, estate and assets) and removes every row in §6.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists harness_a2;

/** Run `p_sql` as `authenticated` under an exact claim set. Returns 'OK' or 'ERR:<sqlerrm>'. */
create or replace function harness_a2.attempt(p_uid uuid, p_claims jsonb, p_sql text)
returns text language plpgsql as $$
declare v_msg text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', coalesce(p_claims::text, '{}'), true);
  begin
    set local role authenticated;
    execute p_sql;
    reset role;
    return 'OK';
  exception when others then
    reset role;
    v_msg := SQLERRM;
    return 'ERR:' || v_msg;
  end;
end $$;

/** The exact net-worth total one caller can read, or NULL when the call is refused. */
create or replace function harness_a2.total(p_uid uuid, p_claims jsonb, p_estate uuid)
returns bigint language plpgsql as $$
declare v bigint;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', coalesce(p_claims::text, '{}'), true);
  begin
    set local role authenticated;
    select w.total_cents into v from public.get_estate_net_worth(p_estate) w;
    reset role;
    return v;
  exception when others then
    reset role;
    return null;
  end;
end $$;

/**
 * What one caller can see of `normalized_assets` by DIRECT query — the RLS/policy path.
 *
 * ★ IT RETURNS TEXT, NOT A COUNT, AND THAT IS LOAD-BEARING. "0 rows" is an RLS DENIAL;
 *   "permission denied for table" is a BROKEN INSTRUMENT; from the outside both are "nothing reached
 *   me". Carrying the error text means a harness gap names itself instead of passing as an
 *   authorization result — which is not hypothetical. On the first run of this suite the preamble
 *   granted `authenticated` no privilege on this table, so the direct path RAISED, and that is how it
 *   came to light that migration 0010's restrictive aal2 policy had never been exercised here at all.
 */
create or replace function harness_a2.visible_assets(p_uid uuid, p_claims jsonb, p_estate uuid)
returns text language plpgsql as $$
declare v int;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', coalesce(p_claims::text, '{}'), true);
  begin
    set local role authenticated;
    select count(*) into v from public.normalized_assets a where a.estate_id = p_estate;
    reset role;
    return v::text;
  exception when others then
    reset role;
    return 'ERR:' || SQLERRM;
  end;
end $$;

create or replace function harness_a2.expect_mfa_required(p_label text, p_uid uuid, p_claims jsonb, p_estate uuid)
returns void language plpgsql as $$
declare v text;
begin
  v := harness_a2.attempt(p_uid, p_claims,
         format('select * from public.get_estate_net_worth(%L)', p_estate));
  if v = 'OK' then
    raise exception 'FAIL[%]: the AAL2 gate ACCEPTED this caller — the window is open', p_label;
  end if;
  if position('mfa_required' in v) = 0 then
    raise exception 'FAIL[%]: refused, but not by the MFA gate — got %', p_label, v;
  end if;
end $$;

-- =================================================================================================
-- 0 · THE INSTRUMENT IS LOADED — asserted BEFORE any authorization claim is evaluated
-- =================================================================================================
DO $$
DECLARE v_secdef boolean; v_body text; v_n int;
BEGIN
  SELECT p.prosecdef INTO v_secdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'aal2_is_current';
  IF v_secdef IS NULL THEN
    RAISE EXCEPTION 'CANNOT VERIFY: public.aal2_is_current() is not loaded in this harness. Every '
      'assertion below would measure the OLD gate and report it as the new one';
  END IF;
  IF NOT v_secdef THEN
    RAISE EXCEPTION 'CANNOT VERIFY: aal2_is_current is not SECURITY DEFINER — it cannot read '
      'auth.sessions as `authenticated` and the policy path below would error rather than refuse';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_body FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'require_aal2';
  IF v_body IS NULL OR position('aal2_is_current' in v_body) = 0 THEN
    RAISE EXCEPTION 'CANNOT VERIFY: require_aal2 does not delegate to aal2_is_current — the eight '
      'RPC call sites are still reading the stateless claim';
  END IF;

  SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'auth' AND c.relname IN ('sessions','mfa_factors');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'CANNOT VERIFY: auth.sessions / auth.mfa_factors are not modelled (found %)', v_n;
  END IF;

  RAISE NOTICE '  ok   the currency predicate is loaded, DEFINER, and the gate delegates to it';
END $$;

-- =================================================================================================
-- 1 · FIXTURE + ★ THE POSITIVE CONTROL: a fresh, currency-backed AAL2 owner reads the exact total
-- =================================================================================================
DO $$
DECLARE
  OWNER_Z  uuid := 'a2a2a2a2-0000-4000-8000-00000000aaaa';
  OTHER_Z  uuid := 'a2a2a2a2-0000-4000-8000-00000000bbbb';
  EST_Z    uuid;
  v_total  bigint;
BEGIN
  insert into auth.users (id, email) values (OWNER_Z, 'aal2-owner@fixture.invalid') on conflict do nothing;
  insert into auth.users (id, email) values (OTHER_Z, 'aal2-other@fixture.invalid') on conflict do nothing;

  insert into public.estates (id, owner_id, name)
  values ('a2a2a2a2-1111-4111-8111-00000000eeee', OWNER_Z, 'AAL2 Currency Estate')
  on conflict do nothing;
  EST_Z := 'a2a2a2a2-1111-4111-8111-00000000eeee';

  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (EST_Z, OWNER_Z, 'primary_user', 'approved') on conflict do nothing;

  -- Two assets with a distinctive exact sum, so a wrong total is visible rather than plausible.
  insert into public.normalized_assets (estate_id, connection_id, institution_name, asset_group, balance_cents, currency)
  values (EST_Z, gen_random_uuid(), 'A2 Bank',  'cashBank',             4100000, 'USD'),
         (EST_Z, gen_random_uuid(), 'A2 Broker','investmentBrokerage', 17800000, 'USD')
  on conflict do nothing;

  -- BOTH users get the server-side state a real stepped-up caller has. OTHER_Z's session exists only
  -- so §3d can prove a VALID session belonging to SOMEONE ELSE is refused.
  perform harness_auth.grant_aal2(OWNER_Z);
  perform harness_auth.grant_aal2(OTHER_Z);

  -- ★ THE CONTROL. If this does not pass, nothing below means anything.
  v_total := harness_a2.total(OWNER_Z, harness_auth.aal2(OWNER_Z), EST_Z);
  IF v_total IS NULL THEN
    RAISE EXCEPTION 'CANNOT VERIFY: a fresh, currency-backed AAL2 owner was REFUSED the gated read. '
      'The fix is too strict, or the fixture is wrong — either way every refusal below is vacuous';
  END IF;
  IF v_total <> 21900000 THEN
    RAISE EXCEPTION 'CANNOT VERIFY: the owner read a total of % — expected 21900000. The fixture is '
      'not the one these assertions describe', v_total;
  END IF;
  RAISE NOTICE '  ok   ★ a FRESH, currency-backed AAL2 session reads the exact total (21900000)';
END $$;

-- =================================================================================================
-- 2 · ★ THE MEASURED DEFECT — the same token, after the things aal2 rests on are gone
-- =================================================================================================
DO $$
DECLARE
  OWNER_Z uuid := 'a2a2a2a2-0000-4000-8000-00000000aaaa';
  EST_Z   uuid := 'a2a2a2a2-1111-4111-8111-00000000eeee';
  STALE   jsonb;
  v_total bigint;
BEGIN
  -- The token is captured ONCE, here, and never rebuilt. Every scenario below replays THIS value —
  -- which is the whole point: on the deployed platform the attacker's token cannot be re-minted either.
  STALE := harness_auth.aal2(OWNER_Z);

  -- (a) GLOBAL LOGOUT — what /api/auth/mfa/recover does in step 3. The factor is still there.
  perform harness_auth.revoke_session(OWNER_Z);
  perform harness_a2.expect_mfa_required('2a/session-revoked', OWNER_Z, STALE, EST_Z);
  RAISE NOTICE '  ok   ★ a revoked SESSION defeats a retained aal2 token';

  -- (b) FACTOR REMOVED — what recover does in step 2. Put the session back first, so this scenario
  --     breaks exactly ONE fact and leg 3 is what refuses.
  perform harness_auth.grant_aal2(OWNER_Z);
  perform harness_auth.remove_factors(OWNER_Z);
  perform harness_a2.expect_mfa_required('2b/factor-removed', OWNER_Z, STALE, EST_Z);
  RAISE NOTICE '  ok   ★ a removed FACTOR defeats a retained aal2 token, independently';

  -- (c) An UNVERIFIED factor is not a factor. An abandoned enrolment must not re-open the gate.
  insert into auth.mfa_factors (id, user_id, status)
  values (gen_random_uuid(), OWNER_Z, 'unverified');
  perform harness_a2.expect_mfa_required('2c/unverified-factor-only', OWNER_Z, STALE, EST_Z);
  delete from auth.mfa_factors where user_id = OWNER_Z;
  RAISE NOTICE '  ok   an UNVERIFIED factor does not satisfy the gate';

  -- (d) BOTH GONE — the state recovery actually leaves behind. This is the measured nonprod case.
  perform harness_auth.revoke_session(OWNER_Z);
  perform harness_a2.expect_mfa_required('2d/recovery-state', OWNER_Z, STALE, EST_Z);
  RAISE NOTICE '  ok   ★ THE MEASURED CASE: post-recovery state refuses the pre-recovery token';

  -- (e) ★ RETURN TO GREEN. Restore the facts and require the IDENTICAL call to succeed again. Without
  --     this, every refusal above is equally consistent with a broken fixture.
  perform harness_auth.grant_aal2(OWNER_Z);
  v_total := harness_a2.total(OWNER_Z, STALE, EST_Z);
  IF v_total IS DISTINCT FROM 21900000 THEN
    RAISE EXCEPTION 'FAIL[2e/return-to-green]: after restoring the session and factor the same token '
      'read % — expected 21900000. The refusals above were not caused by what they claim', v_total;
  END IF;
  RAISE NOTICE '  ok   ★ and the same token works again once the server state is restored';
END $$;

-- =================================================================================================
-- 3 · CLAIM-SHAPE LEGS — each one fails CLOSED, and none of them raises something other than the gate
-- =================================================================================================
DO $$
DECLARE
  OWNER_Z uuid := 'a2a2a2a2-0000-4000-8000-00000000aaaa';
  OTHER_Z uuid := 'a2a2a2a2-0000-4000-8000-00000000bbbb';
  EST_Z   uuid := 'a2a2a2a2-1111-4111-8111-00000000eeee';
  v_total bigint;
BEGIN
  -- (a) aal1 — the ORIGINAL behaviour, unchanged by 0064. A regression here would be a disaster
  --     dressed as a refactor.
  perform harness_a2.expect_mfa_required('3a/aal1', OWNER_Z,
    harness_auth.aal2(OWNER_Z, jsonb_build_object('aal','aal1')), EST_Z);

  -- (b) aal2 with NO session_id. An unrecognised token shape is refused, not waived.
  perform harness_a2.expect_mfa_required('3b/no-session-id', OWNER_Z,
    jsonb_build_object('sub', OWNER_Z, 'aal', 'aal2',
                       'iat', extract(epoch from now())::bigint), EST_Z);

  -- (c) A MALFORMED session_id must refuse via the gate, NOT raise 22P02 from a failed uuid cast.
  --     A cast error is a 500 to the client and, worse, it means the predicate aborted rather than
  --     answered — so the policy path would error instead of denying.
  perform harness_a2.expect_mfa_required('3c/malformed-session-id', OWNER_Z,
    harness_auth.aal2(OWNER_Z, jsonb_build_object('session_id','not-a-uuid')), EST_Z);

  -- (d) SOMEONE ELSE'S live session. The row exists, so a leg that only checked existence would pass.
  perform harness_a2.expect_mfa_required('3d/foreign-session', OWNER_Z,
    harness_auth.aal2(OWNER_Z,
      jsonb_build_object('session_id', harness_auth.session_id(OTHER_Z))), EST_Z);

  -- (e) An EXPIRED session (`not_after` in the past) is not a live one.
  update auth.sessions set not_after = now() - interval '1 minute' where user_id = OWNER_Z;
  perform harness_a2.expect_mfa_required('3e/expired-session', OWNER_Z,
    harness_auth.aal2(OWNER_Z), EST_Z);
  update auth.sessions set not_after = null where user_id = OWNER_Z;

  -- ★ CONTROL AGAIN, after five refusals and two UPDATEs to the session row.
  v_total := harness_a2.total(OWNER_Z, harness_auth.aal2(OWNER_Z), EST_Z);
  IF v_total IS DISTINCT FROM 21900000 THEN
    RAISE EXCEPTION 'FAIL[3/control]: the valid caller no longer reads the total (got %)', v_total;
  END IF;
  RAISE NOTICE '  ok   five claim-shape legs fail closed, and the valid caller still passes';
END $$;

-- =================================================================================================
-- 4 · ★ THE SECOND ROUTE — the RESTRICTIVE POLICIES, which had their OWN copy of the stateless check
-- =================================================================================================
--
-- `connections_require_aal2` and `normalized_assets_require_aal2` (0010) INLINED
-- `coalesce(auth.jwt() ->> 'aal','aal1') = 'aal2'`. They are the direct-query half of the gate, and a
-- fix confined to `require_aal2()` would have left them exactly as open as before. 0064 re-points both
-- at the same predicate; this section proves the re-pointed shape actually denies.
--
-- The policy is created HERE rather than in the preamble because it must exist AFTER
-- `db/functions/aal2_is_current.sql` is loaded — a policy cannot reference a function that does not yet
-- exist. It is dropped again in §6: a RESTRICTIVE policy left on this table would silently change what
-- every later suite can read.
DO $$
DECLARE
  OWNER_Z uuid := 'a2a2a2a2-0000-4000-8000-00000000aaaa';
  EST_Z   uuid := 'a2a2a2a2-1111-4111-8111-00000000eeee';
  v_seen  text;
  v_restrictive boolean;
  v_qual  text;
BEGIN
  drop policy if exists normalized_assets_require_aal2 on public.normalized_assets;
  create policy normalized_assets_require_aal2 on public.normalized_assets
    as restrictive for all
    using ((select public.aal2_is_current()))
    with check ((select public.aal2_is_current()));

  -- The policy is the 0064 shape, by identity: RESTRICTIVE, and calling the predicate rather than
  -- reading the claim. A PERMISSIVE policy with the same body would gate nothing.
  SELECT NOT p.polpermissive, pg_get_expr(p.polqual, p.polrelid) INTO v_restrictive, v_qual
    FROM pg_policy p WHERE p.polname = 'normalized_assets_require_aal2';
  IF NOT coalesce(v_restrictive, false) THEN
    RAISE EXCEPTION 'CANNOT VERIFY: the aal2 policy is not RESTRICTIVE in this harness';
  END IF;
  IF position('aal2_is_current' in coalesce(v_qual,'')) = 0 THEN
    RAISE EXCEPTION 'CANNOT VERIFY: the aal2 policy does not call the predicate (%)', v_qual;
  END IF;

  -- ★ CONTROL — with currency, the owner's own permissive policy lets the direct read through.
  v_seen := harness_a2.visible_assets(OWNER_Z, harness_auth.aal2(OWNER_Z), EST_Z);
  IF v_seen <> '2' THEN
    RAISE EXCEPTION 'CANNOT VERIFY: a current AAL2 owner reads % by direct query, expected 2 rows. '
      'An ERR: here is a harness gap (privilege, not policy); a 0 means the restrictive policy '
      'refuses a caller it should admit. Either way nothing below is evidence', v_seen;
  END IF;

  -- The stale token on the DIRECT path. RLS denies by returning NO ROWS, never by raising — and the
  -- difference matters: an exception would mean the predicate could not be evaluated as
  -- `authenticated`, which on the deployed platform is a 500 where a deny belongs.
  perform harness_auth.revoke_session(OWNER_Z);
  v_seen := harness_a2.visible_assets(OWNER_Z, harness_auth.aal2(OWNER_Z), EST_Z);
  IF v_seen LIKE 'ERR:%' THEN
    RAISE EXCEPTION 'FAIL[4/policy-stale]: the direct query RAISED instead of denying — %', v_seen;
  END IF;
  IF v_seen <> '0' THEN
    RAISE EXCEPTION 'FAIL[4/policy-stale]: a revoked session still reads % by direct query', v_seen;
  END IF;
  RAISE NOTICE '  ok   ★ the RESTRICTIVE policy path denies a stale token too (0 rows, no error)';

  -- Restore, and require the control back.
  perform harness_auth.grant_aal2(OWNER_Z);
  v_seen := harness_a2.visible_assets(OWNER_Z, harness_auth.aal2(OWNER_Z), EST_Z);
  IF v_seen <> '2' THEN
    RAISE EXCEPTION 'FAIL[4/return-to-green]: after restoring currency the owner reads %', v_seen;
  END IF;
  RAISE NOTICE '  ok   and the policy path admits the owner again once currency is restored';
END $$;

-- =================================================================================================
-- 5 · THE CLIENT CONTRACT DID NOT CHANGE — and the refusals disclose nothing
-- =================================================================================================
DO $$
DECLARE
  OWNER_Z  uuid := 'a2a2a2a2-0000-4000-8000-00000000aaaa';
  EST_Z    uuid := 'a2a2a2a2-1111-4111-8111-00000000eeee';
  v_aal1   text;
  v_stale  text;
  v_state  text;
BEGIN
  v_aal1 := harness_a2.attempt(OWNER_Z, harness_auth.aal2(OWNER_Z, jsonb_build_object('aal','aal1')),
              format('select * from public.get_estate_net_worth(%L)', EST_Z));
  perform harness_auth.revoke_session(OWNER_Z);
  perform harness_auth.remove_factors(OWNER_Z);
  v_stale := harness_a2.attempt(OWNER_Z, harness_auth.aal2(OWNER_Z),
               format('select * from public.get_estate_net_worth(%L)', EST_Z));

  -- ★ BYTE-IDENTICAL, DELIBERATELY. "Your factor was deleted" and "your session was revoked" are facts
  -- about another device's state, and the holder of a stale token is the one party who should not learn
  -- which. It is also why no client release is needed: the message the app already handles is the
  -- message every leg raises.
  IF v_aal1 IS DISTINCT FROM v_stale THEN
    RAISE EXCEPTION 'FAIL[5/uniform-refusal]: aal1 said % but the stale token said % — the refusal '
      'discloses which server-side fact failed', v_aal1, v_stale;
  END IF;
  IF position('mfa_required' in v_stale) = 0 THEN
    RAISE EXCEPTION 'FAIL[5/sentinel]: the sentinel the client maps is gone — got %', v_stale;
  END IF;

  -- And the errcode PostgREST turns into a 403 is still 42501, not a generic P0001.
  BEGIN
    perform set_config('request.jwt.claims', '{}', true);
    perform public.require_aal2();
    RAISE EXCEPTION 'FAIL[5/errcode]: require_aal2 did not raise for an empty claim set';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE '  ok   the sentinel is unchanged: mfa_required / 42501, identical for every leg';
  END;

  perform harness_auth.grant_aal2(OWNER_Z);
  v_state := 'restored';
END $$;

-- =================================================================================================
-- 6 · FIXTURE INTEGRITY — the policy is removed and every row this suite created is gone
-- =================================================================================================
DO $$
DECLARE
  OWNER_Z uuid := 'a2a2a2a2-0000-4000-8000-00000000aaaa';
  OTHER_Z uuid := 'a2a2a2a2-0000-4000-8000-00000000bbbb';
  EST_Z   uuid := 'a2a2a2a2-1111-4111-8111-00000000eeee';
  v_n     int;
BEGIN
  -- ★ THE POLICY MUST GO. §4 created a RESTRICTIVE policy on a table later suites read directly; left
  --   behind it would silently narrow what every one of them can see, and they would fail for a reason
  --   that looks nothing like this file.
  drop policy if exists normalized_assets_require_aal2 on public.normalized_assets;
  SELECT count(*) INTO v_n FROM pg_policy WHERE polname = 'normalized_assets_require_aal2';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'FAIL[6]: the aal2 policy this suite created is still on normalized_assets';
  END IF;

  delete from public.normalized_assets where estate_id = EST_Z;
  delete from public.estate_memberships where estate_id = EST_Z;
  delete from public.estates where id = EST_Z;
  delete from auth.mfa_factors where user_id in (OWNER_Z, OTHER_Z);
  delete from auth.sessions   where user_id in (OWNER_Z, OTHER_Z);
  delete from auth.users      where id      in (OWNER_Z, OTHER_Z);

  SELECT count(*) INTO v_n FROM public.estates WHERE id = EST_Z;
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL[6]: fixture estate survived teardown'; END IF;
  SELECT count(*) INTO v_n FROM auth.users WHERE id IN (OWNER_Z, OTHER_Z);
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL[6]: fixture users survived teardown'; END IF;

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
  RAISE NOTICE '  ok   policy dropped, every fixture row removed, claims reset';
  RAISE NOTICE '  ALL AAL2 SESSION-CURRENCY ASSERTIONS PASSED';
END $$;
