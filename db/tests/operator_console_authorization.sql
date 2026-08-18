-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-K — THE OPERATOR CONTROL PLANE, PROVED AGAINST A REAL DATABASE
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THIS FILE IS FOR. 11-K adds two READ doors so that nine deployed WRITE doors become
-- usable by an operator. A read door that answers the wrong caller is a disclosure, and a read door
-- that answers with estate content is a wider disclosure than the workflow needs. This file proves
-- — by EXECUTION, through the real doors — that:
--
--   1 · every wrong actor is refused, and refused for the RIGHT reason (§2, the security matrix);
--   2 · the case file carries no owner address and no estate content, checked against a fixture
--       that HAS both, so the absence cannot be an artifact of an empty estate (§3);
--   3 · `viewer_is_reviewer_a` answers from the server's own session, differently for two different
--       admins looking at the same case (§4);
--   4 · the worker pair is unreachable by any client role, and reachable by the worker (§5);
--   5 · the projections move NOTHING — case, lifecycle, level, notice and disclosure are all
--       byte-identical across a read (§6).
--
-- ★ AND THE CONTROLS COME FIRST. §0 proves each routine exists and that the instrument can observe
-- a real difference before any "refused" or "absent" claim is made. A withholding assertion against
-- a missing function passes by crashing, which is not withholding.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

create schema if not exists harness_op;
grant usage on schema harness_op to anon, authenticated;

-- Impersonation controlling BOTH JWT surfaces (the harness_dv rationale: claim residue from an
-- admin step would otherwise make an aal2-gated surface answer differently across stages).
create or replace function harness_op.attempt(p_uid uuid, p_claims jsonb, p_sql text)
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

/** A fresh AAL2 admin session: the only claim set the admin gate accepts. */
create or replace function harness_op.aal2(p_uid uuid) returns jsonb language sql as $$
  select jsonb_build_object('sub', p_uid, 'aal', 'aal2',
                            'iat', extract(epoch from now())::bigint);
$$;

create or replace function harness_op.as_admin_json(p_uid uuid, p_sql text)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', harness_op.aal2(p_uid)::text, true);
  set local role authenticated;
  execute p_sql into v;
  reset role;
  return v;
end $$;

/** Expect a refusal whose message CONTAINS the named sentinel. Names the actual message on failure. */
create or replace function harness_op.expect_err(
  p_label text, p_uid uuid, p_claims jsonb, p_sql text, p_expect text
) returns void language plpgsql as $$
declare v text;
begin
  v := harness_op.attempt(p_uid, p_claims, p_sql);
  if v = 'OK' then
    raise exception 'FAIL[%]: expected refusal %, but the call SUCCEEDED', p_label, p_expect;
  end if;
  if position(p_expect in v) = 0 then
    raise exception 'FAIL[%]: expected % but got %', p_label, p_expect, v;
  end if;
end $$;

do $$
declare
  OWNER_K   uuid; EXEC_K uuid; BENE_K uuid; DELE_K uuid; STRG_K uuid;
  ADMIN_A   uuid; ADMIN_B uuid; NONADMIN uuid;
  K         uuid;  -- the estate under test
  CASE_K    uuid;
  DOC_K     uuid;
  EV_K      uuid;
  v_json    jsonb;
  v_txt     text;
  v_n       int;
  v_before  jsonb;
  v_after   jsonb;
begin
  raise notice ' ';
  raise notice '══ PHASE 11-K · operator control plane ══';
  raise notice '0 · instrument self-check';

  -- (a) Every routine under test exists. Without this, every refusal below would "pass" by
  -- crashing on a function that does not exist.
  if to_regprocedure('public.admin_list_death_verification_cases(text, timestamptz, uuid, int)') is null
     or to_regprocedure('public.admin_get_death_verification_case(uuid)') is null
     or to_regprocedure('public.record_owner_notice_outcome(uuid, text, text)') is null then
    raise exception 'FAIL: a Phase 11-K routine is not installed — the bundle did not land';
  end if;
  raise notice '  ok   both projections and the outcome recorder resolved';

  -- (b) Grant posture, asserted rather than assumed.
  if has_function_privilege('anon', 'public.admin_get_death_verification_case(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.admin_list_death_verification_cases(text, timestamptz, uuid, int)', 'EXECUTE') then
    raise exception 'FAIL: an operator projection is anon-executable';
  end if;
  if not has_function_privilege('authenticated', 'public.admin_get_death_verification_case(uuid)', 'EXECUTE') then
    raise exception 'FAIL: the case file is not reachable by an authenticated admin at all';
  end if;
  -- ★ THE WORKER PAIR IS service_role ONLY. An operator who could claim a notice could strand it
  -- in `processing`, where the stale sweep later burns it — an owner silently un-notified.
  if has_function_privilege('authenticated', 'public.claim_owner_notices(int)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.record_owner_notice_outcome(uuid, text, text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.record_owner_notice_outcome(uuid, text, text)', 'EXECUTE') then
    raise exception 'FAIL: a client role can claim or settle an owner safety notice';
  end if;
  if not has_function_privilege('service_role', 'public.claim_owner_notices(int)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.record_owner_notice_outcome(uuid, text, text)', 'EXECUTE') then
    raise exception 'FAIL: the drain worker cannot claim or settle — the queue would never drain';
  end if;
  raise notice '  ok   projections admin-only; the claim/record pair is service_role only';

  -- (c) The sixth status is admitted by the constraint, and a nonsense one is not. Proves 0056
  -- landed AND that the CHECK was replaced rather than dropped.
  if (select pg_get_constraintdef(oid) from pg_constraint
       where conname = 'owner_notice_outbox_status_check') not like '%outcomeUncertain%' then
    raise exception 'FAIL: owner_notice_outbox does not admit outcomeUncertain';
  end if;
  raise notice '  ok   the outbox admits outcomeUncertain';

  -- ── FIXTURE ───────────────────────────────────────────────────────────────────────────────────
  -- ★ THE ESTATE IS DELIBERATELY FURNISHED. §3 asserts that no estate CONTENT reaches an operator;
  -- an empty estate would satisfy that assertion for the wrong reason. This one has a name, an
  -- owner with an email, a beneficiary, a designated executor, and a document.
  insert into auth.users default values returning id into OWNER_K;
  insert into auth.users default values returning id into EXEC_K;
  insert into auth.users default values returning id into BENE_K;
  insert into auth.users default values returning id into DELE_K;
  insert into auth.users default values returning id into STRG_K;
  insert into auth.users default values returning id into ADMIN_A;
  insert into auth.users default values returning id into ADMIN_B;
  insert into auth.users default values returning id into NONADMIN;

  update auth.users set email = 'op-owner@harness.invalid'   where id = OWNER_K;
  update auth.users set email = 'op-exec@harness.invalid'    where id = EXEC_K;

  insert into public.estates (owner_id, name) values (OWNER_K, 'OP Estate K') returning id into K;
  insert into public.admins (user_id) values (ADMIN_A), (ADMIN_B);

  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (K, EXEC_K, 'executor', 'active');
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (K, BENE_K, 'beneficiary', 'approved'),
         (K, DELE_K, 'professional_delegate', 'approved');

  insert into public.documents (estate_id, title, doc_type, storage_path)
  values (K, 'OP Death Certificate', 'death_certificate', 'op/harness/death-cert.pdf')
  returning id into DOC_K;

  -- Open a case through the REAL door, as the designee.
  v_txt := harness_op.attempt(EXEC_K, jsonb_build_object('sub', EXEC_K),
    format('select public.initiate_death_verification_case(%L)', K));
  if v_txt <> 'OK' then
    raise exception 'FAIL: could not open a case through the real door: %', v_txt;
  end if;
  select c.id into CASE_K from public.death_verification_cases c
   where c.estate_id = K order by c.created_at desc limit 1;

  v_txt := harness_op.attempt(EXEC_K, jsonb_build_object('sub', EXEC_K),
    format('select public.attach_death_verification_evidence(%L, %L)', CASE_K, DOC_K));
  if v_txt <> 'OK' then
    raise exception 'FAIL: could not attach evidence through the real door: %', v_txt;
  end if;
  select e.id into EV_K from public.death_verification_evidence e where e.case_id = CASE_K limit 1;

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '1 · a valid AAL2 admin can see the case (the positive control for every refusal)';

  v_json := harness_op.as_admin_json(ADMIN_A,
    format('select public.admin_get_death_verification_case(%L)', CASE_K));
  if v_json is null or v_json -> 'case' ->> 'case_id' <> CASE_K::text then
    raise exception 'FAIL: a valid AAL2 admin could not read the case file';
  end if;
  if (v_json -> 'evidence' ->> 0) is null then
    raise exception 'FAIL: the case file returned no evidence for a case that has some';
  end if;
  raise notice '  ok   the case file answers a fresh AAL2 admin, with evidence metadata present';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '2 · THE SECURITY MATRIX — every wrong actor refused, each for the right reason';

  -- anonymous: no sub at all
  perform harness_op.expect_err('anon/list', null, '{}'::jsonb,
    'select public.admin_list_death_verification_cases()', 'auth_required');
  perform harness_op.expect_err('anon/get', null, '{}'::jsonb,
    format('select public.admin_get_death_verification_case(%L)', CASE_K), 'auth_required');

  -- ★ EVERY NON-ADMIN ACTOR, INCLUDING THE ONES WITH REAL AUTHORITY OVER THIS ESTATE. The owner
  -- and the designated executor are the two people most likely to be mistaken for privileged here;
  -- both are refused identically, because operator authority is a SEPARATE AXIS from estate
  -- authority rather than a louder version of it.
  perform harness_op.expect_err('owner/get',        OWNER_K,  harness_op.aal2(OWNER_K),
    format('select public.admin_get_death_verification_case(%L)', CASE_K), 'admin_required');
  perform harness_op.expect_err('fiduciary/get',    EXEC_K,   harness_op.aal2(EXEC_K),
    format('select public.admin_get_death_verification_case(%L)', CASE_K), 'admin_required');
  perform harness_op.expect_err('beneficiary/get',  BENE_K,   harness_op.aal2(BENE_K),
    format('select public.admin_get_death_verification_case(%L)', CASE_K), 'admin_required');
  perform harness_op.expect_err('delegate/get',     DELE_K,   harness_op.aal2(DELE_K),
    format('select public.admin_get_death_verification_case(%L)', CASE_K), 'admin_required');
  perform harness_op.expect_err('stranger/get',     STRG_K,   harness_op.aal2(STRG_K),
    format('select public.admin_get_death_verification_case(%L)', CASE_K), 'admin_required');
  perform harness_op.expect_err('nonadmin/list',    NONADMIN, harness_op.aal2(NONADMIN),
    'select public.admin_list_death_verification_cases()', 'admin_required');

  -- ★ AN ADMIN AT aal1 IS STILL REFUSED. This is the assertion that separates "is an admin" from
  -- "has stepped up", and it is the one a console cannot enforce on the server's behalf.
  perform harness_op.expect_err('admin-aal1/get', ADMIN_A,
    jsonb_build_object('sub', ADMIN_A, 'aal', 'aal1', 'iat', extract(epoch from now())::bigint),
    format('select public.admin_get_death_verification_case(%L)', CASE_K), 'mfa_required');
  perform harness_op.expect_err('admin-aal1/list', ADMIN_A,
    jsonb_build_object('sub', ADMIN_A, 'aal', 'aal1', 'iat', extract(epoch from now())::bigint),
    'select public.admin_list_death_verification_cases()', 'mfa_required');

  -- ★ A STALE TOKEN IS REFUSED even though it is an AAL2 admin token. The 15-minute freshness
  -- bound is what keeps a captured access token from being a durable operator credential.
  perform harness_op.expect_err('admin-stale/get', ADMIN_A,
    jsonb_build_object('sub', ADMIN_A, 'aal', 'aal2',
                       'iat', extract(epoch from now())::bigint - 1000),
    format('select public.admin_get_death_verification_case(%L)', CASE_K),
    'stale_token_reauth_required');

  -- ★ A MISSING iat FAILS CLOSED. coalesce -> 0 -> ancient -> stale, never "no claim, no problem".
  perform harness_op.expect_err('admin-no-iat/get', ADMIN_A,
    jsonb_build_object('sub', ADMIN_A, 'aal', 'aal2'),
    format('select public.admin_get_death_verification_case(%L)', CASE_K),
    'stale_token_reauth_required');

  raise notice '  ok   anon, owner, fiduciary, beneficiary, delegate, stranger, non-admin, aal1,';
  raise notice '       stale and iat-less callers are ALL refused, each with its own sentinel';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '3 · the case file carries the WORKFLOW and not the ESTATE';

  -- Dispatch a real notice so the outbox arm is populated — otherwise §3's address assertion would
  -- be satisfied by an empty array rather than by a withheld column.
  v_txt := harness_op.attempt(ADMIN_A, harness_op.aal2(ADMIN_A),
    format('select public.admin_set_attained_verification_level(%L, %L::public.verification_level, %L)',
           CASE_K, 'enhanced_kyc', 'harness'));
  if v_txt <> 'OK' then raise exception 'FAIL: could not set attained level: %', v_txt; end if;
  v_txt := harness_op.attempt(ADMIN_A, harness_op.aal2(ADMIN_A),
    format('select public.admin_decide_death_verification_case(%L, %L)', CASE_K, 'verify'));
  if v_txt <> 'OK' then raise exception 'FAIL: could not verify the case: %', v_txt; end if;
  v_txt := harness_op.attempt(ADMIN_A, harness_op.aal2(ADMIN_A),
    format('select public.dispatch_owner_safety_notice(%L)', K));
  if v_txt <> 'OK' then raise exception 'FAIL: could not dispatch the owner notice: %', v_txt; end if;

  -- ★ THE WINDOW IS OPENED HERE, AND THE ORDER IS THE POINT. `authorize_release` checks the
  -- lifecycle state BEFORE it checks the two-person rule, so attempting a release from
  -- `owner_notification_dispatched` refuses with `invalid_release_state` — a refusal that says
  -- nothing whatsoever about reviewer distinctness. §4's two-person assertion would then have
  -- passed for the wrong reason, or (as it first did) failed while the rule was working perfectly.
  -- Reaching `challenge_window` is what makes the two-person refusal the NEXT gate in line, and
  -- therefore the one actually under test.
  v_txt := harness_op.attempt(ADMIN_A, harness_op.aal2(ADMIN_A),
    format('select public.begin_challenge_window(%L)', K));
  if v_txt <> 'OK' then raise exception 'FAIL: could not open the challenge window: %', v_txt; end if;

  v_json := harness_op.as_admin_json(ADMIN_A,
    format('select public.admin_get_death_verification_case(%L)', CASE_K));

  -- POSITIVE CONTROL: the outbox arm is genuinely populated, so the absence below is a WITHHELD
  -- column rather than an empty array.
  if jsonb_array_length(v_json -> 'owner_notice') < 1 then
    raise exception 'FAIL: the case file shows no owner notice for an estate that has one — the '
      'address assertion below would pass vacuously';
  end if;
  if (v_json -> 'owner_notice' -> 0 ->> 'status') is null then
    raise exception 'FAIL: the owner notice arm carries no status';
  end if;

  -- ★ THE ADDRESS IS NOT THERE. Checked against the WHOLE payload, so a future edit that adds it
  -- anywhere — not just under owner_notice — fails this.
  if v_json::text like '%op-owner@harness.invalid%' then
    raise exception 'FAIL: the operator case file discloses the OWNER''S EMAIL ADDRESS';
  end if;
  if v_json::text like '%recipient%' then
    raise exception 'FAIL: the operator case file carries a recipient field';
  end if;

  -- ★ NO STORAGE PATH. The evidence arm is populated (asserted in §1), so this is a real absence.
  if v_json::text like '%op/harness/death-cert.pdf%' or v_json::text like '%storage_path%' then
    raise exception 'FAIL: the operator case file discloses an evidence storage path';
  end if;

  -- The initiator's identity IS present — it is the one identity the adjudication needs.
  if v_json -> 'initiator' ->> 'user_id' <> EXEC_K::text then
    raise exception 'FAIL: the case file omits the initiator an operator must adjudicate';
  end if;

  -- Both levels are labelled, so the console cannot present a snapshot as the live bar.
  if (v_json -> 'case' ->> 'required_level_live') is null
     or (v_json -> 'case' ->> 'required_level_at_initiation') is null then
    raise exception 'FAIL: the case file does not label required-level provenance';
  end if;
  raise notice '  ok   notice status present, address WITHHELD, storage path WITHHELD,';
  raise notice '       initiator disclosed, both required-level readings labelled';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '4 · viewer_is_reviewer_a answers from the SERVER''S session, not the client''s';

  -- ADMIN_A decided this case, so A is reviewer A and is INELIGIBLE to authorize the release.
  v_json := harness_op.as_admin_json(ADMIN_A,
    format('select public.admin_get_death_verification_case(%L)', CASE_K));
  if (v_json -> 'release' ->> 'reviewer_a') <> ADMIN_A::text then
    raise exception 'FAIL: reviewer_a is not the case decider';
  end if;
  if (v_json -> 'release' ->> 'viewer_is_reviewer_a') <> 'true' then
    raise exception 'FAIL: the decider is not told they are reviewer A — the console would offer '
      'an authorize action that authorize_release refuses';
  end if;

  -- ★ THE SAME CASE, THE SAME ROW, A DIFFERENT ADMIN — and the answer flips. This is what proves
  -- the field is derived from auth.uid() rather than read off the case.
  v_json := harness_op.as_admin_json(ADMIN_B,
    format('select public.admin_get_death_verification_case(%L)', CASE_K));
  if (v_json -> 'release' ->> 'viewer_is_reviewer_a') <> 'false' then
    raise exception 'FAIL: a SECOND admin is told they are reviewer A — the two-person rule would '
      'be misrepresented in the console';
  end if;
  raise notice '  ok   the same case answers true for the decider and false for a second admin';

  -- And the door agrees with the projection: reviewer A really is refused.
  perform harness_op.expect_err('reviewer-a-cannot-release', ADMIN_A, harness_op.aal2(ADMIN_A),
    format('select public.authorize_release(%L, %L)', K, 'harness'), 'two_person_rule_violated');
  raise notice '  ok   authorize_release independently refuses reviewer A (UI is not the boundary)';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '5 · the window facts match the door exactly';

  v_json := harness_op.as_admin_json(ADMIN_A,
    format('select public.admin_get_death_verification_case(%L)', CASE_K));
  if (v_json -> 'window' ->> 'configured') <> 'true' then
    raise exception 'FAIL: the console reports the window unconfigured when policy holds 7 days';
  end if;

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ PHASE 11-OC / PHASE D — TWO DISTINCT REFUSALS, AND THE CONSOLE MUST NAME BOTH THE SAME WAY
  --   THE DOOR DOES. Before Phase D there was only one, and it was the WRONG one.
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- STATE 1 · the notice was queued moments ago and NOTHING has been accepted. The old console said
  -- "the window has not elapsed", which is a statement about the CLOCK and quietly conceded that the
  -- notice itself qualified. It never did — no message had been sent at all.
  if (v_json -> 'window' ->> 'elapsed') <> 'false' then
    raise exception 'FAIL: the console reports an elapsed window seconds after dispatch';
  end if;
  if (v_json -> 'release_authority' ->> 'ready') <> 'false'
     or (v_json -> 'release_authority' ->> 'refusal_code') <> 'notice_never_accepted' then
    raise exception 'FAIL[OC/D]: with no acceptance fact the projection reports ready=% code=% — '
      'the console must refuse for the reason the door refuses, not for the clock',
      v_json -> 'release_authority' ->> 'ready',
      v_json -> 'release_authority' ->> 'refusal_code';
  end if;
  -- ★ AND THE ELIGIBILITY DATE IS NULL, NOT A DATE COMPUTED FROM PROVENANCE. A console that filled
  -- this in from `owner_notified_at` would show operators a deadline the door does not recognise.
  if (v_json -> 'window' -> 'release_eligible_at') is distinct from 'null'::jsonb then
    raise exception 'FAIL[OC/D]: release_eligible_at is % with no acceptance fact — it must be NULL '
      'until there is an acceptance instant to anchor on', v_json -> 'window' -> 'release_eligible_at';
  end if;
  perform harness_op.expect_err('release-no-acceptance', ADMIN_B, harness_op.aal2(ADMIN_B),
    format('select public.authorize_release(%L, %L)', K, 'harness'), 'notice_never_accepted');
  raise notice '  ok   5a · no acceptance fact: projection and door BOTH say notice_never_accepted, '
    'and release_eligible_at is NULL rather than derived from provenance';

  -- STATE 2 · the provider accepts, so the clock finally has something to run from — and only NOW is
  -- "the window has not elapsed" a true description of this estate.
  perform public.record_owner_notice_outcome(
    (select o.id from public.owner_notice_outbox o
      where o.estate_id = K and o.superseded_by is null limit 1), 'providerAccepted');
  v_json := harness_op.as_admin_json(ADMIN_A,
    format('select public.admin_get_death_verification_case(%L)', CASE_K));
  if (v_json -> 'window' ->> 'elapsed') <> 'false' then
    raise exception 'FAIL: the console reports an elapsed window seconds after acceptance';
  end if;
  if (v_json -> 'release_authority' ->> 'refusal_code') <> 'release_window_not_elapsed' then
    raise exception 'FAIL[OC/D]: after acceptance the projection refuses with % rather than the '
      'clock', v_json -> 'release_authority' ->> 'refusal_code';
  end if;
  -- ★ THE SERVER OWNS THE ARITHMETIC. The console is handed the instant; it derives nothing.
  if (v_json -> 'window' -> 'release_eligible_at') is null
     or (v_json -> 'window' -> 'release_eligible_at') = 'null'::jsonb then
    raise exception 'FAIL[OC/D]: release_eligible_at is still NULL after a real provider acceptance';
  end if;
  if (v_json -> 'window' ->> 'release_eligible_at')::timestamptz
     is distinct from (v_json -> 'release_authority' ->> 'notice_accepted_at')::timestamptz
                      + public.challenge_window_duration() then
    raise exception 'FAIL[OC/D]: the projected eligibility instant is not notice_accepted_at + the '
      'configured window — the console is anchored on something the door does not use';
  end if;
  -- …and the release door agrees, which is the assertion that matters: a console that disagreed
  -- with the door would offer an action that fails, or hide one that would succeed.
  perform harness_op.expect_err('release-before-window', ADMIN_B, harness_op.aal2(ADMIN_B),
    format('select public.authorize_release(%L, %L)', K, 'harness'), 'release_window_not_elapsed');
  raise notice '  ok   5b · after acceptance: projection says not-elapsed, anchors the date on the '
    'acceptance fact, and the door refuses for the same reason';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '6 · reading the case file MOVES NOTHING';

  select jsonb_build_object(
    'case',      (select to_jsonb(c) from public.death_verification_cases c where c.id = CASE_K),
    'lifecycle', (select to_jsonb(l) from public.estate_lifecycle l where l.estate_id = K),
    'evidence',  (select jsonb_agg(to_jsonb(e) order by e.id)
                    from public.death_verification_evidence e where e.case_id = CASE_K),
    'notice',    (select jsonb_agg(to_jsonb(o) order by o.id)
                    from public.owner_notice_outbox o where o.estate_id = K)
  ) into v_before;

  perform harness_op.as_admin_json(ADMIN_A,
    format('select public.admin_get_death_verification_case(%L)', CASE_K));
  perform harness_op.as_admin_json(ADMIN_B,
    format('select public.admin_get_death_verification_case(%L)', CASE_K));
  perform harness_op.attempt(ADMIN_A, harness_op.aal2(ADMIN_A),
    'select public.admin_list_death_verification_cases()');

  select jsonb_build_object(
    'case',      (select to_jsonb(c) from public.death_verification_cases c where c.id = CASE_K),
    'lifecycle', (select to_jsonb(l) from public.estate_lifecycle l where l.estate_id = K),
    'evidence',  (select jsonb_agg(to_jsonb(e) order by e.id)
                    from public.death_verification_evidence e where e.case_id = CASE_K),
    'notice',    (select jsonb_agg(to_jsonb(o) order by o.id)
                    from public.owner_notice_outbox o where o.estate_id = K)
  ) into v_after;

  if v_before is distinct from v_after then
    raise exception 'FAIL: reading the operator projections CHANGED authoritative state';
  end if;
  raise notice '  ok   three reads by two admins left case, lifecycle, evidence and notice identical';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '7 · the queue lists the case, and lists no address';

  -- A `returns table` function needs a row context; count and inspect via a CTE.
  perform set_config('request.jwt.claim.sub', ADMIN_A::text, true);
  perform set_config('request.jwt.claims', harness_op.aal2(ADMIN_A)::text, true);
  set local role authenticated;
  select count(*) into v_n
    from public.admin_list_death_verification_cases() q
   where q.case_id = CASE_K;
  select to_jsonb(q) into v_json
    from public.admin_list_death_verification_cases() q
   where q.case_id = CASE_K;
  reset role;

  if v_n <> 1 then
    raise exception 'FAIL: the operator queue does not list the case exactly once (found %)', v_n;
  end if;
  if v_json::text like '%op-owner@harness.invalid%' then
    raise exception 'FAIL: the operator QUEUE discloses the owner''s email address';
  end if;
  -- The boolean answers the workflow question the address would have answered.
  if (v_json ->> 'owner_channel_resolvable') <> 'true' then
    raise exception 'FAIL: owner_channel_resolvable is false for an owner who HAS an address';
  end if;
  if (v_json ->> 'evidence_total')::int <> 1 then
    raise exception 'FAIL: the queue miscounts evidence (got %)', v_json ->> 'evidence_total';
  end if;
  raise notice '  ok   the queue lists the case once, counts its evidence, and carries no address';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '7b · Phase 11-OC — the case file projects the EPISODE and the re-notice verdict';

  -- ★ WITHOUT THESE FIELDS THE CONSOLE CAN RENDER ONLY A STATUS, AND THIS PHASE PROVED A STATUS IS
  -- NOT ENOUGH. `dispatched` means "the provider accepted" on a row written after Phase A and means
  -- "nobody knows" on a row written before it. A console that labelled both the same way would state,
  -- on the one screen where it matters, that a living owner was reached when nobody knows.
  v_json := harness_op.as_admin_json(ADMIN_A,
    format('select public.admin_get_death_verification_case(%L)', CASE_K));

  -- POSITIVE CONTROL FIRST: the fixture really does carry a notice row, or every field assertion
  -- below would be reading an empty array and passing vacuously.
  if jsonb_array_length(v_json -> 'owner_notice') < 1 then
    raise exception 'FAIL[control]: the case file carries no owner_notice rows, so the episode field '
      'assertions below inspect nothing';
  end if;
  declare
    v_n0 jsonb := (v_json -> 'owner_notice' -> 0);
    v_key text;
  begin
    foreach v_key in array array['case_id', 'generation', 'superseded_by', 'is_current',
                                 'notice_accepted_at', 'claimed_at'] loop
      if not (v_n0 ? v_key) then
        raise exception 'FAIL[OC]: the case file omits owner_notice.% — the console cannot tell a '
          'live generation from a retired one, nor an accepted notice from a legacy row', v_key;
      end if;
    end loop;
    -- The fixture's notice is the only generation, so it must be the CURRENT one.
    if (v_n0 ->> 'is_current') <> 'true' then
      raise exception 'FAIL[OC]: the only generation of this episode is not marked current';
    end if;
    if (v_n0 ->> 'generation')::int <> 1 then
      raise exception 'FAIL[OC]: an original dispatch is projected as generation %',
        v_n0 ->> 'generation';
    end if;
    -- ★ AND STILL NO ADDRESS. The row the projection reads HAS a recipient; the payload must not.
    if v_n0 ? 'recipient' then
      raise exception 'FAIL[OC]: the case file projects the owner-notice recipient';
    end if;
  end;

  -- ★ THE ACTION VERDICT COMES FROM THE SERVER, AND IT IS THE SAME FUNCTION THE DOOR CONSULTS.
  -- Asserted by comparing the projection's embedded verdict against a direct call: a console reading
  -- one and a door applying the other is exactly the divergence this field exists to prevent.
  if not (v_json ? 'owner_notice_reissue') then
    raise exception 'FAIL[C]: the case file carries no owner_notice_reissue verdict, so the console '
      'would have to reimplement the eligibility policy in TypeScript';
  end if;
  if not ((v_json -> 'owner_notice_reissue') ? 'eligible')
     or not ((v_json -> 'owner_notice_reissue') ? 'refusal_code') then
    raise exception 'FAIL[C]: the re-notice verdict lacks eligible/refusal_code: %',
      v_json -> 'owner_notice_reissue';
  end if;
  declare
    v_direct jsonb;
  begin
    perform set_config('request.jwt.claim.sub', ADMIN_A::text, true);
    perform set_config('request.jwt.claims', harness_op.aal2(ADMIN_A)::text, true);
    select public.owner_notice_reissue_assessment(CASE_K) into v_direct;
    if (v_json -> 'owner_notice_reissue' ->> 'eligible')
       is distinct from (v_direct ->> 'eligible')
       or (v_json -> 'owner_notice_reissue' ->> 'refusal_code')
       is distinct from (v_direct ->> 'refusal_code') then
      raise exception 'FAIL[C]: the projection''s verdict (%) differs from the shared assessment (%) '
        '— the console and the door would disagree about the same estate',
        v_json -> 'owner_notice_reissue', v_direct;
    end if;
  end;
  -- The verdict is counts and codes; it must carry no address on any branch.
  if (v_json -> 'owner_notice_reissue')::text ilike '%@%' then
    raise exception 'FAIL[C]: the re-notice verdict contains an address shape';
  end if;
  raise notice '  ok   the case file projects case_id/generation/superseded_by/is_current/'
    'notice_accepted_at/claimed_at and a server-calculated re-notice verdict that MATCHES the '
    'shared assessment — with no recipient anywhere';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '8 · fixture integrity';

  -- ★ ORDER IS FK ORDER, NOT NARRATIVE ORDER. `estate_lifecycle.updated_case_id` references the
  -- case, so the lifecycle row must go FIRST — deleting the case first raises
  -- estate_lifecycle_updated_case_id_fkey and strands the whole fixture in the database for every
  -- later suite to trip over.
  delete from public.owner_notice_outbox where estate_id = K;
  delete from public.release_authorizations where estate_id = K;
  delete from public.estate_lifecycle where estate_id = K;
  delete from public.death_verification_evidence where case_id = CASE_K;
  delete from public.death_verification_cases where estate_id = K;
  delete from public.documents where estate_id = K;
  delete from public.estate_memberships where estate_id = K;
  delete from public.estate_designations where estate_id = K;
  delete from public.notifications where estate_id = K;
  delete from public.audit_logs where estate_id = K;
  delete from public.estates where id = K;
  delete from public.admins where user_id in (ADMIN_A, ADMIN_B);
  delete from auth.users
   where id in (OWNER_K, EXEC_K, BENE_K, DELE_K, STRG_K, ADMIN_A, ADMIN_B, NONADMIN);

  if exists (select 1 from public.estates where id = K) then
    raise exception 'FAIL: the harness left its estate behind';
  end if;
  raise notice '  ok   every row this suite created has been removed';

  raise notice ' ';
  raise notice '  ALL PHASE 11-K OPERATOR CONTROL PLANE ASSERTIONS PASSED';
end $$;
