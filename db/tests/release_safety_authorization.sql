-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-E — THE CHALLENGE WINDOW AND THE RELEASE SEAM, PROVED AGAINST A REAL DATABASE
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THIS FILE IS FOR. 11-D connected `death_verified` to disclosure. 11-E inserts the safety
-- seam that makes an irreversible act survivable: the owner is notified, a window runs, and the
-- owner can halt the whole process in ONE action with no evidence, no review and no waiting. This
-- file proves — by EXECUTION, through the real doors — that:
--
--   1 · every pre-release stage discloses NOTHING (A active · B pending · C death_verified ·
--       D challenge_window · E challenge_halted), and `released` discloses only what an EXISTING
--       owner-authored grant already authorized;
--   2 · the owner challenge is owner-only, evidence-free, review-free, designation-free,
--       idempotent, terminal, and WINS THE EXACT BOUNDARY TIE — and it settles the case row and
--       notifies the initiating fiduciary from EVERY lifecycle state it is reachable from, not only
--       from `death_verification_pending` (§8, Phase 11-NR);
--   3 · release refuses before the window elapses, without a committed owner notice, without a
--       verified case, without configuration, from a halted process, and from any other state;
--   4 · nothing anywhere manufactures a grant, tier, membership or designation.
--
-- ★ AND EVERY WITHHOLDING ASSERTION IS PAIRED. §0 proves the instrument can see a real disclosure
-- before any "nothing moved" claim is made, and the release stage itself is the positive control
-- for the four stages that precede it: if released did not move the payload, the stage assertions
-- would be measuring a viewer who could never see anything.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

create schema if not exists harness_rs;
grant usage on schema harness_rs to anon, authenticated;

-- Impersonation controlling BOTH JWT surfaces (the harness_dv rationale: claim residue from an
-- admin step would otherwise make an aal2-gated surface answer differently across stages).
create or replace function harness_rs.attempt(p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare v_msg text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', '{}', true);
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

create or replace function harness_rs.as_admin(p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare v_msg text;
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', p_uid, 'aal', 'aal2',
                       'iat', extract(epoch from now())::bigint)::text, true);
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

/** Admin call returning a jsonb payload (the census). Same claim discipline as `as_admin`. */
create or replace function harness_rs.as_admin_json(p_uid uuid, p_sql text)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', p_uid, 'aal', 'aal2',
                       'iat', extract(epoch from now())::bigint)::text, true);
  execute p_sql into v;
  return v;
end $$;

/** The composed view — every surface one viewer can reach, as one value (the 10-F instrument). */
create or replace function harness_rs.composed(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  select jsonb_build_object(
    'discovery', harness_dv.try(format('select public.get_estate_discovery(%L)', p_estate)),
    'assets', harness_dv.try(format(
      'select coalesce(jsonb_agg(to_jsonb(a) order by a.id), ''[]''::jsonb) from public.list_estate_assets(%L) a', p_estate)),
    'net_worth', harness_dv.try(format(
      'select coalesce(jsonb_agg(to_jsonb(w)), ''[]''::jsonb) from public.get_estate_net_worth(%L) w', p_estate)),
    'documents', harness_dv.try(format(
      'select coalesce(jsonb_agg(d.id order by d.id), ''[]''::jsonb) from public.documents d where d.estate_id = %L', p_estate)),
    'readiness', harness_dv.try(format('select public.get_estate_readiness(%L)', p_estate)),
    'workspace', harness_dv.try(format('select public.get_professional_workspace(%L)', p_estate)),
    'notifications', harness_dv.try(format(
      'select coalesce(jsonb_agg(jsonb_build_object(''kind'', n.kind, ''title'', n.title, ''estate'', n.estate_id) order by n.created_at, n.id), ''[]''::jsonb) '
      || 'from public.notifications n where n.estate_id = %L', p_estate))
  ) into v;
  reset role;
  return v;
exception when others then
  reset role;
  return jsonb_build_object('error', SQLERRM);
end $$;

/** Every authority-shaped table for an estate, as one value — the no-manufacturing bracket. */
create or replace function harness_rs.authority_snapshot(p_estate uuid)
returns jsonb language sql as $$
  select jsonb_build_object(
    'grants',       coalesce((select jsonb_agg(to_jsonb(g) order by g.id)
                                from public.access_grants g where g.estate_id = p_estate), '[]'::jsonb),
    'memberships',  coalesce((select jsonb_agg(to_jsonb(m) order by m.user_id, m.role)
                                from public.estate_memberships m where m.estate_id = p_estate), '[]'::jsonb),
    'designations', coalesce((select jsonb_agg(to_jsonb(d) order by d.id)
                                from public.estate_designations d where d.estate_id = p_estate), '[]'::jsonb));
$$;

-- =================================================================================================
-- 0 · THE INSTRUMENT IS READING THE REAL THING
-- =================================================================================================
do $$
declare v_n int;
begin
  raise notice ' ';
  raise notice '══ PHASE 11-E · challenge window and release seam ══';
  raise notice '0 · instrument self-check';

  -- (a) Every routine under test exists. A withholding assertion against a missing function passes
  -- by crashing, which is not withholding.
  if to_regprocedure('public.begin_challenge_window(uuid)') is null
     or to_regprocedure('public.challenge_death_process(uuid)') is null
     or to_regprocedure('public.dispatch_owner_safety_notice(uuid)') is null
     or to_regprocedure('public.authorize_release(uuid, text)') is null
     or to_regprocedure('public.get_owner_safety_status(uuid)') is null
     or to_regprocedure('public.challenge_window_duration()') is null
     or to_regprocedure('public.claim_owner_notices(int)') is null
     or to_regprocedure('public.purge_outbox_rows(text, timestamptz, text)') is null then
    raise exception 'FAIL: a Phase 11-E/F safety routine is not installed — the bundle did not land';
  end if;
  -- ★ THE ONE-PERSON LEVER IS GONE (D1). Leaving `release_estate` beside the two-person door would
  -- be the decision undone by any un-rewired caller — 0055 drops it, and this is what proves it.
  if to_regprocedure('public.release_estate(uuid)') is not null then
    raise exception 'FAIL: the one-person release lever still exists — D1 is bypassable';
  end if;
  raise notice '  ok   all eight safety routines resolved; the one-person lever is GONE';

  -- (b) THE RELEASE LEVER IS UNREACHABLE BY CLIENTS, and the challenge IS reachable. If these were
  -- reversed, every assertion below would describe a system nobody can operate safely.
  -- The release door is admin-gated INSIDE (D1); `anon` may not reach it at all.
  if has_function_privilege('anon', 'public.authorize_release(uuid, text)', 'EXECUTE') then
    raise exception 'FAIL: authorize_release is anon-executable';
  end if;
  if has_function_privilege('authenticated', 'public.claim_owner_notices(int)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.owner_notice_age_gate()', 'EXECUTE') then
    raise exception 'FAIL: an internal outbox routine is client-executable';
  end if;
  if has_function_privilege('authenticated', 'public.challenge_window_duration()', 'EXECUTE') then
    raise exception 'FAIL: the safety clock is client-readable';
  end if;
  if not has_function_privilege('authenticated', 'public.challenge_death_process(uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.get_owner_safety_status(uuid)', 'EXECUTE') then
    raise exception 'FAIL: the owner challenge or its status read is NOT client-executable — the '
      'owner cannot reach the one action that protects them';
  end if;
  raise notice '  ok   release door admin-gated and anon-refused; owner challenge + status reachable';

  -- (b2) THE TWO-PERSON RULE IS A TABLE CONSTRAINT, not merely routine logic (D1). A routine-only
  -- check is bypassable by any other writer; this proves the wall exists behind the door.
  if not exists (select 1 from pg_constraint where conname = 'release_authorizations_two_person') then
    raise exception 'FAIL: the two-person rule is not a table constraint';
  end if;
  -- …and the CHECK actually refuses, proven by attempting it.
  begin
    insert into public.release_authorizations
      (estate_id, case_id, reviewer_a, reviewer_b, verified_at, audit_reason)
    values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), now(), 'probe');
    raise exception 'FAIL: a release authorization with invented FKs was insertable';
  exception
    when check_violation then
      raise exception 'FAIL: the two-person CHECK refused two DISTINCT reviewers';
    when foreign_key_violation then null;  -- refused by FK, as expected; the CHECK is tested below
  end;

  -- (c) THE WINDOW DURATION IS THE APPROVED 7 x 24h (D2).
  --
  -- ★ THIS ASSERTION WAS INVERTED IN 11-F, AND THE INVERSION IS THE DECISION. In 11-E the duration
  -- was undecided, so the correct posture was "seeded by nothing, so no window can ever elapse" and
  -- this block refused any row. D2 decides it, so the value is now recorded in a migration —
  -- reviewably, once — and what must be pinned is that production carries the APPROVED number
  -- rather than whatever a console session last set.
  select count(*) into v_n from public.release_safety_policy;
  if v_n <> 1 then
    raise exception 'FAIL: release_safety_policy holds % row(s); expected exactly the one approved '
      'configuration', v_n;
  end if;
  if public.challenge_window_duration() is distinct from interval '7 days' then
    raise exception 'FAIL: the challenge window is % — D2 approved 7 x 24 hours',
      coalesce(public.challenge_window_duration()::text, 'NULL');
  end if;
  -- The age gate is DERIVED from it, so the two can never drift apart.
  if public.owner_notice_age_gate() is distinct from interval '8 days' then
    raise exception 'FAIL: the owner-notice age gate is % (expected window + 1 day)',
      coalesce(public.owner_notice_age_gate()::text, 'NULL');
  end if;
  raise notice '  ok   the challenge window is the approved 7 days; the age gate derives to 8 days';

  -- (d) The lifecycle vocabulary is exactly the six states, and the predicate agrees with it.
  if (select count(*) from regexp_matches(
        (select pg_get_constraintdef(con.oid)
           from pg_constraint con
           join pg_class rel on rel.oid = con.conrelid
           join pg_namespace nsp on nsp.oid = rel.relnamespace
          where nsp.nspname = 'public' and rel.relname = 'estate_lifecycle' and con.contype = 'c'
            and pg_get_constraintdef(con.oid) ilike '%state%'),
        '''[a-z_]+''', 'g')) <> 7 then
    raise exception 'FAIL: the lifecycle CHECK is not exactly seven states';
  end if;
  if not public.release_condition_satisfied('after_verified_death', null, 'standard', 'released')
     or public.release_condition_satisfied('after_verified_death', null, 'standard', 'death_verified')
     or public.release_condition_satisfied('after_verified_death', null, 'standard', 'challenge_window')
     or public.release_condition_satisfied('after_verified_death', null, 'standard', 'challenge_halted') then
    raise exception 'FAIL: the predicate does not implement the 11-E seam (released yes; verified, '
      'window and halted all no)';
  end if;
  raise notice '  ok   six lifecycle states; the predicate satisfies death ONLY at released';
end $$;

-- =================================================================================================
-- 1 · THE FULL SAFETY WALK — one estate, every stage, through the real doors
-- =================================================================================================
do $rs$
declare
  OWNER_S uuid; EXEC_S uuid; DELE_S uuid; STRG_S uuid; ADMIN_S uuid; ADMIN2_S uuid; OWNER_F uuid;
  S uuid; F uuid; ASSET_S uuid;
  v_case uuid; v_res text; v_status text; v_notice uuid; n int;
  auth_before jsonb; auth_after jsonb;
  dele_a jsonb; dele_b jsonb; dele_c jsonb; dele_d jsonb; dele_f jsonb;
  strg_a jsonb; strg_f jsonb; owner_f_view jsonb;
  v_disco jsonb; v_cat jsonb; v_tier text; v_rows bigint;
begin
  raise notice '1 · the safety walk (stages A-F through the real doors)';

  -- ── fixture ────────────────────────────────────────────────────────────────────────────────────
  insert into auth.users default values returning id into OWNER_S;
  insert into auth.users default values returning id into EXEC_S;
  insert into auth.users default values returning id into DELE_S;
  insert into auth.users default values returning id into STRG_S;
  insert into auth.users default values returning id into ADMIN_S;
  insert into auth.users default values returning id into ADMIN2_S;
  insert into auth.users default values returning id into OWNER_F;
  -- ★ D4: the owner must be INDEPENDENTLY REACHABLE. `auth.users.email` is the address the account
  -- authenticates with — the one a claimant cannot repoint — and dispatch REFUSES without it.
  update auth.users set email = 'rs-owner-s@example.invalid' where id = OWNER_S;
  insert into public.estates (owner_id, name) values (OWNER_S, 'RS Estate S') returning id into S;
  insert into public.estates (owner_id, name) values (OWNER_F, 'RS Estate F') returning id into F;
  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (S, OWNER_S, 'primary_user', 'approved'),
    (S, DELE_S,  'professional_delegate', 'approved'),
    (F, OWNER_F, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EXEC_S, 'executor', 'active');
  insert into public.admins (user_id) values (ADMIN_S), (ADMIN2_S);

  -- ONE asset in ONE category with a distinctive exact value: the single-asset oracle fixture.
  perform set_config('request.jwt.claim.sub', OWNER_S::text, true);
  select public.create_estate_asset(S, 'artwork', 'RS painting', null, null, null, null, null, null, 3311900)
    into ASSET_S;
  -- Financial rows so the LEGACY surfaces have something they COULD disclose at released.
  insert into public.normalized_assets (estate_id, connection_id, institution_name, asset_group, balance_cents, currency)
  values (S, gen_random_uuid(), 'RS Bank', 'cashBank', 8800000, 'USD');

  -- The owner-authored death-conditioned grant, through the REAL door.
  perform harness_dv.grant_inventory(S, OWNER_S, DELE_S, 'professional_delegate', 'category_summary', 'after_verified_death');
  -- The same delegate holds an identical grant on the FOREIGN estate — the cross-estate control.
  perform harness_dv.grant_inventory(F, OWNER_F, DELE_S, 'professional_delegate', 'category_summary', 'after_verified_death');

  auth_before := harness_rs.authority_snapshot(S);

  -- ── STAGE A · active ──────────────────────────────────────────────────────────────────────────
  dele_a := harness_rs.composed(DELE_S, S);
  strg_a := harness_rs.composed(STRG_S, S);
  owner_f_view := harness_rs.composed(DELE_S, F);
  if position('category_summary' in dele_a::text) > 0 then
    raise exception 'FAIL[A]: a death-conditioned grant discloses at lifecycle active';
  end if;
  if public.estate_lifecycle_state(S) <> 'active' then
    raise exception 'FAIL[A precondition]: estate S does not start active';
  end if;
  raise notice '  ok   STAGE A (active): the death-conditioned grant discloses nothing';

  -- ── STAGE B · verification pending (real door: designee initiates) ────────────────────────────
  v_res := harness_rs.attempt(EXEC_S, format('select public.initiate_death_verification_case(%L)', S));
  if v_res <> 'OK' then raise exception 'FAIL[B]: designee could not initiate: %', v_res; end if;
  select id into v_case from public.death_verification_cases where estate_id = S and status = 'open';
  dele_b := harness_rs.composed(DELE_S, S);
  if dele_b::text is distinct from dele_a::text then
    raise exception 'FAIL[B]: verification pending moved the death-conditioned payload';
  end if;
  raise notice '  ok   STAGE B (verification pending): payload byte-identical';

  -- ── STAGE C · death_verified (real door: admin attains + verifies) ────────────────────────────
  v_res := harness_rs.as_admin(ADMIN_S, format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case));
  if v_res <> 'OK' then raise exception 'FAIL[C]: attained level refused: %', v_res; end if;
  v_res := harness_rs.as_admin(ADMIN_S, format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));
  if v_res <> 'OK' then raise exception 'FAIL[C]: verify refused: %', v_res; end if;
  if public.estate_lifecycle_state(S) <> 'death_verified' then
    raise exception 'FAIL[C]: the lifecycle did not reach death_verified';
  end if;
  dele_c := harness_rs.composed(DELE_S, S);
  if dele_c::text is distinct from dele_a::text then
    raise exception 'FAIL[C · THE 11-E SEAM]: death_verified moved the death-conditioned payload — '
      'an accepted verification released information before the owner-challenge window';
  end if;
  raise notice '  ok   STAGE C (death_verified): payload byte-identical — verification is not release';

  -- ── RELEASE IS REFUSED FROM death_verified (the window has not even opened) ────────────────────
  v_res := harness_rs.as_admin(ADMIN2_S, format('select public.authorize_release(%L, %L)', S, 'post-window release'));
  if position('invalid_release_state' in v_res) = 0 then
    raise exception 'FAIL: release from death_verified got %', v_res;
  end if;
  raise notice '  ok   release refuses from death_verified (invalid_release_state)';

  -- ── THE WINDOW CANNOT OPEN WITHOUT A DISPATCH (11-F). The death_verified -> challenge_window edge
  -- was DELETED, so the routine that used to notify-and-open now has no legal input here.
  v_res := harness_rs.as_admin(ADMIN_S, format('select public.begin_challenge_window(%L)', S));
  if position('invalid_window_state' in v_res) = 0 then
    raise exception 'FAIL: a window opened directly from death_verified (got %) — the owner would '
      'never have been told', v_res;
  end if;
  raise notice '  ok   no window can open from death_verified — dispatch is now on the only path';

  -- ── STAGE D · challenge_window (real door: admin opens; the owner notice must COMMIT) ─────────
  select count(*) into n from public.notifications where user_id = OWNER_S and estate_id = S;
  if n <> 0 then raise exception 'FAIL[D precondition]: the owner already had notifications'; end if;

  -- ★ D4 — DISPATCH FIRST, and it commits BOTH channels or the transition rolls back.
  v_res := harness_rs.as_admin(ADMIN_S, format('select public.dispatch_owner_safety_notice(%L)', S));
  if v_res <> 'OK' then raise exception 'FAIL[D]: dispatch refused: %', v_res; end if;
  if public.estate_lifecycle_state(S) <> 'owner_notification_dispatched' then
    raise exception 'FAIL[D]: dispatch did not reach owner_notification_dispatched';
  end if;
  -- The EMAIL row is the independently reachable channel, addressed and committed.
  select count(*) into n from public.owner_notice_outbox
   where estate_id = S and channel = 'email' and status = 'queued'
     and recipient = 'rs-owner-s@example.invalid';
  if n <> 1 then
    raise exception 'FAIL[D]: expected exactly 1 addressed email notice, found %', n;
  end if;
  -- D2: the clock started AT DISPATCH, not at verification.
  if (select owner_notified_at from public.estate_lifecycle where estate_id = S) is null then
    raise exception 'FAIL[D]: the challenge clock did not start at dispatch';
  end if;
  -- Idempotent replay dispatches nothing further.
  v_res := harness_rs.as_admin(ADMIN_S, format('select public.dispatch_owner_safety_notice(%L)', S));
  select count(*) into n from public.owner_notice_outbox where estate_id = S;
  if v_res <> 'OK' or n <> 1 then
    raise exception 'FAIL[D]: dispatch replay was not idempotent (% / % rows)', v_res, n;
  end if;

  v_res := harness_rs.as_admin(ADMIN_S, format('select public.begin_challenge_window(%L)', S));
  if v_res <> 'OK' then raise exception 'FAIL[D]: opening the window refused: %', v_res; end if;
  if public.estate_lifecycle_state(S) <> 'challenge_window' then
    raise exception 'FAIL[D]: the lifecycle did not reach challenge_window';
  end if;

  -- ★ THE SAFETY NOTICE IS A COMMITTED FACT, and the lifecycle row points at it.
  select count(*) into n from public.notifications
   where user_id = OWNER_S and estate_id = S and title = 'A release process is waiting';
  if n <> 1 then
    raise exception 'FAIL[D]: the owner safety notice was not committed (% row(s))', n;
  end if;
  select safety_notification_id into v_notice from public.estate_lifecycle where estate_id = S;
  if v_notice is null then
    raise exception 'FAIL[D]: the lifecycle row does not record the safety notification';
  end if;
  -- ★ COPY DISCIPLINE (§18): the notice asserts no death, names no claimant, no estate, no count.
  if exists (select 1 from public.notifications n2
              where n2.id = v_notice
                and (n2.title || ' ' || coalesce(n2.body, '')) ~* '(died|death|deceased|passed away|claim|executor|fraud)') then
    raise exception 'FAIL[D]: the owner safety notice asserts a death or names the claim workflow';
  end if;

  dele_d := harness_rs.composed(DELE_S, S);
  if dele_d::text is distinct from dele_a::text then
    raise exception 'FAIL[D]: challenge_window moved the death-conditioned payload — the window '
      'discloses while the owner can still halt it';
  end if;
  raise notice '  ok   STAGE D (challenge_window): owner notified (committed, honest copy); payload byte-identical';

  -- ── RELEASE IS REFUSED: window not elapsed ────────────────────────────────────────────────────
  v_res := harness_rs.as_admin(ADMIN2_S, format('select public.authorize_release(%L, %L)', S, 'premature'));
  if position('release_window_not_elapsed' in v_res) = 0 then
    raise exception 'FAIL: premature release got %', v_res;
  end if;
  raise notice '  ok   release refuses before the 7-day window elapses';

  -- ── AUTHORITY BRACKET so far: nothing manufactured through B, C, D ────────────────────────────
  auth_after := harness_rs.authority_snapshot(S);
  if auth_after::text is distinct from auth_before::text then
    raise exception 'FAIL: the verification/window flow touched grants, memberships or designations';
  end if;
  raise notice '  ok   no grant, membership or designation moved through stages B-D';

  -- ── STAGE F · released (elapse the window by ageing the notice, then release) ─────────────────
  -- Ageing `owner_notified_at` is the deterministic equivalent of waiting: the duration is read
  -- LIVE from configuration, so a notice 8 days old under a 7-day window is exactly an elapsed one.
  update public.estate_lifecycle
     set owner_notified_at = now() - interval '8 days'
   where estate_id = S;

  -- ★ D1 — THE VERIFIER MAY NOT RELEASE. ADMIN_S decided the death case; their release attempt must
  -- be refused BY THE DATABASE, and only a second operator can proceed.
  v_res := harness_rs.as_admin(ADMIN_S, format('select public.authorize_release(%L, %L)', S, 'verifier self-release'));
  if position('two_person_rule_violated' in v_res) = 0 then
    raise exception 'FAIL[D1]: the death verifier was allowed to authorize release (got %)', v_res;
  end if;
  if public.estate_lifecycle_state(S) <> 'challenge_window' then
    raise exception 'FAIL[D1]: the refused release still moved the lifecycle';
  end if;
  -- An empty audit reason is refused: "cleaning up" is not a reason a year from now.
  v_res := harness_rs.as_admin(ADMIN2_S, format('select public.authorize_release(%L, %L)', S, '   '));
  if position('audit_reason_required' in v_res) = 0 then
    raise exception 'FAIL: a blank audit reason was accepted (got %)', v_res;
  end if;

  v_res := harness_rs.as_admin(ADMIN2_S, format('select public.authorize_release(%L, %L)', S, 'window elapsed, no challenge'));
  if v_res <> 'OK' then raise exception 'FAIL[F]: the second reviewer could not release: %', v_res; end if;
  if public.estate_lifecycle_state(S) <> 'released' then
    raise exception 'FAIL[F]: release did not reach the released lifecycle';
  end if;
  -- The authorization record carries both reviewers and the full audit shape (Stage 5).
  select count(*) into n from public.release_authorizations
   where estate_id = S and reviewer_a = ADMIN_S and reviewer_b = ADMIN2_S
     and verified_at is not null and authorized_at is not null and released_at is not null
     and btrim(audit_reason) <> '';
  if n <> 1 then
    raise exception 'FAIL[F]: expected 1 complete release authorization record, found %', n;
  end if;

  dele_f := harness_rs.composed(DELE_S, S);
  if dele_f::text is not distinct from dele_a::text then
    raise exception 'FAIL[F · CONTROL]: released did NOT move the payload of the viewer holding the '
      'owner-authored death grant — every stage assertion above is vacuous, because this instrument '
      'cannot observe a disclosure at all';
  end if;
  -- Only the projections the inventory grant authorizes may move (discovery + workspace inventory).
  if (dele_f - 'discovery' - 'workspace')::text is distinct from (dele_a - 'discovery' - 'workspace')::text then
    raise exception 'FAIL[F]: release moved a surface OUTSIDE the qualifying grant. before=% after=%',
      (dele_a - 'discovery' - 'workspace')::text, (dele_f - 'discovery' - 'workspace')::text;
  end if;
  if (dele_f -> 'workspace' -> 'inventory' ->> 'tier') is distinct from 'category_summary' then
    raise exception 'FAIL[F]: the released workspace does not honour the authored tier: %',
      (dele_f -> 'workspace' -> 'inventory')::text;
  end if;
  raise notice '  ok   STAGE F (released): exactly the authorized projections moved, at the authored tier';

  -- ★ THE SINGLE-ASSET ORACLE, POST-RELEASE (§13). One asset in one category: the exact value must
  -- be underivable through the newly live tier.
  perform set_config('request.jwt.claim.sub', DELE_S::text, true);
  set local role authenticated;
  select public.get_estate_discovery(S) into v_disco;
  reset role;
  v_cat := v_disco -> 'categories' -> 0;
  if (v_cat ->> 'item_count')::int <> 1 then
    raise exception 'FAIL[F]: single-asset category reports item_count %', v_cat ->> 'item_count';
  end if;
  if v_cat -> 'total_cents' is distinct from 'null'::jsonb then
    raise exception 'FAIL[F]: category_summary published an exact total after release: %', v_cat::text;
  end if;
  if position('3311900' in v_disco::text) > 0 then
    raise exception 'FAIL[F]: the exact single-asset value leaked through the released payload';
  end if;
  raise notice '  ok   ORACLE: the released tier brackets a single-asset category (no exact value)';

  -- ★ THE LEGACY CLAMP SURVIVES RELEASE (R10): asset rows and net worth stay dormant.
  perform set_config('request.jwt.claim.sub', DELE_S::text, true);
  set local role authenticated;
  select count(*) into v_rows from public.list_estate_assets(S);
  if v_rows <> 0 then
    reset role;
    raise exception 'FAIL[F]: release activated % asset row(s) under legacy_immediate_only (R10)', v_rows;
  end if;
  if exists (select 1 from public.get_estate_net_worth(S) w
             where w.total_cents is not null or w.range_low_cents is not null) then
    reset role;
    raise exception 'FAIL[F]: release disclosed a net-worth figure under legacy_immediate_only (R10)';
  end if;
  reset role;
  raise notice '  ok   R10: the legacy asset surfaces stay dormant even at released';

  -- ★ A VIEWER WITH NO QUALIFYING GRANT LEARNS NOTHING FROM THE RELEASE.
  strg_f := harness_rs.composed(STRG_S, S);
  if strg_f::text is distinct from strg_a::text then
    raise exception 'FAIL[F]: release moved the payload of a viewer holding NO grant';
  end if;
  if harness_rs.composed(null, S) -> 'discovery' ? 'categories' then
    raise exception 'FAIL[F]: an anonymous caller received categories from a released estate';
  end if;
  raise notice '  ok   no-grant viewer and anonymous caller both unmoved by release';

  -- ★ CROSS-ESTATE (§16): the identical grant on estate F is untouched — F is still active.
  if harness_rs.composed(DELE_S, F)::text is distinct from owner_f_view::text then
    raise exception 'FAIL[F]: estate S''s release moved the delegate''s estate-F payload';
  end if;
  raise notice '  ok   CROSS-ESTATE: the identical grant on the foreign estate stayed dormant';

  -- ★ NOTHING WAS MANUFACTURED BY THE RELEASE ITSELF (§14).
  auth_after := harness_rs.authority_snapshot(S);
  if auth_after::text is distinct from auth_before::text then
    raise exception 'FAIL[F]: release touched grants, memberships or designations — activation must '
      'be EVALUATIVE, never a write';
  end if;
  raise notice '  ok   release created no grant, tier, membership or designation (byte-identical)';

  -- ★ IDEMPOTENT RELEASE, and the owner is told the honest thing about being too late (R15).
  v_res := harness_rs.as_admin(ADMIN2_S, format('select public.authorize_release(%L, %L)', S, 'idempotent replay'));
  select count(*) into n from public.release_authorizations where estate_id = S;
  if v_res <> 'OK' or n <> 1 then
    raise exception 'FAIL: release replay was not idempotent (% / % authorization rows)', v_res, n;
  end if;
  v_res := harness_rs.attempt(OWNER_S, format('select public.challenge_death_process(%L)', S));
  if position('already_released' in v_res) = 0 then
    raise exception 'FAIL: challenging a released estate got % (the owner must be told plainly, not '
      'given a false success)', v_res;
  end if;
  perform set_config('request.jwt.claim.sub', OWNER_S::text, true);
  set local role authenticated;
  select public.get_owner_safety_status(S) into v_status;
  reset role;
  if v_status <> 'released' then
    raise exception 'FAIL: owner safety status reads % on a released estate', v_status;
  end if;
  raise notice '  ok   release is idempotent; a late challenge is refused honestly (already_released)';
end $rs$;

-- =================================================================================================
-- 2 · THE OWNER CHALLENGE — owner-only, evidence-free, idempotent, terminal
-- =================================================================================================
do $rs2$
declare
  OWNER_C uuid; EXEC_C uuid; BEN_C uuid; DELE_C uuid; ADMIN_C uuid; OWNER_G uuid;
  C uuid; G uuid;
  v_case uuid; v_res text; v_status text; refusal text; cause text; n int;
  auth_before jsonb; dele_before jsonb;
begin
  raise notice '2 · the owner challenge';

  insert into auth.users default values returning id into OWNER_C;
  insert into auth.users default values returning id into EXEC_C;
  insert into auth.users default values returning id into BEN_C;
  insert into auth.users default values returning id into DELE_C;
  insert into auth.users default values returning id into ADMIN_C;
  insert into auth.users default values returning id into OWNER_G;
  insert into public.estates (owner_id, name) values (OWNER_C, 'RS Estate C') returning id into C;
  insert into public.estates (owner_id, name) values (OWNER_G, 'RS Estate G') returning id into G;
  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (C, OWNER_C, 'primary_user', 'approved'),
    (C, BEN_C,   'beneficiary', 'approved'),
    (C, DELE_C,  'professional_delegate', 'approved'),
    (G, OWNER_G, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (C, EXEC_C, 'executor', 'active');
  insert into public.admins (user_id) values (ADMIN_C) on conflict do nothing;
  perform harness_dv.grant_inventory(C, OWNER_C, DELE_C, 'professional_delegate', 'category_summary', 'after_verified_death');

  -- ── NOTHING TO CHALLENGE on an untouched estate: honest refusal, not a silent success ─────────
  v_res := harness_rs.attempt(OWNER_C, format('select public.challenge_death_process(%L)', C));
  if position('nothing_to_challenge' in v_res) = 0 then
    raise exception 'FAIL: challenging an active estate got %', v_res;
  end if;
  perform set_config('request.jwt.claim.sub', OWNER_C::text, true);
  set local role authenticated;
  select public.get_owner_safety_status(C) into v_status;
  reset role;
  if v_status <> 'none' then
    raise exception 'FAIL: owner safety status reads % on an untouched estate', v_status;
  end if;

  -- ── A PROCESS BEGINS, and the owner surface says so in one word ───────────────────────────────
  v_res := harness_rs.attempt(EXEC_C, format('select public.initiate_death_verification_case(%L)', C));
  if v_res <> 'OK' then raise exception 'FAIL: initiation refused: %', v_res; end if;
  select id into v_case from public.death_verification_cases where estate_id = C and status = 'open';
  perform set_config('request.jwt.claim.sub', OWNER_C::text, true);
  set local role authenticated;
  select public.get_owner_safety_status(C) into v_status;
  reset role;
  if v_status <> 'challengeable' then
    raise exception 'FAIL: owner safety status reads % while a process is pending', v_status;
  end if;
  raise notice '  ok   the owner surface reports challengeable as soon as a process exists';

  -- ── EVERY NON-OWNER IS REFUSED, BYTE-IDENTICALLY (§16) ────────────────────────────────────────
  refusal := null;
  for v_res, cause in
    -- ★ THE COLUMN ALIASES ARE NOT SINGLE LETTERS. `c` collided with the block's `C` estate
    -- variable and PL/pgSQL refused the ambiguity outright — the loud direction for that mistake.
    select harness_rs.attempt(t.probe_uid, format('select public.challenge_death_process(%L)', t.probe_estate)),
           t.probe_cause
      from (values
        (BEN_C,   C,                 'beneficiary'),
        (DELE_C,  C,                 'professional delegate'),
        (EXEC_C,  C,                 'the claimant/designee'),
        (ADMIN_C, C,                 'a platform admin (no override in 11-E)'),
        (OWNER_G, C,                 'a foreign owner'),
        (OWNER_C, gen_random_uuid(), 'the owner against a NONEXISTENT estate')
      ) t(probe_uid, probe_estate, probe_cause)
  loop
    if v_res = 'OK' then
      raise exception 'FAIL: % was allowed to challenge', cause;
    end if;
    if refusal is null then refusal := v_res;
    elsif v_res is distinct from refusal then
      raise exception 'FAIL: refusal for "%" differs from the common shape: % vs %', cause, v_res, refusal;
    end if;
  end loop;
  if refusal is distinct from 'ERR:not_authorized' then
    raise exception 'FAIL: the common challenge refusal carries more than the sentinel: %', refusal;
  end if;
  v_res := harness_rs.attempt(null, format('select public.challenge_death_process(%L)', C));
  if position('auth_required' in v_res) = 0 then
    raise exception 'FAIL: anonymous challenge got %', v_res;
  end if;
  raise notice '  ok   6 unauthorized challenge causes refused BYTE-IDENTICALLY; anonymous refused';

  -- ── THE STATUS READ IS GATED TOO, AND FOR THE SAME REASON ─────────────────────────────────────
  --
  -- ★ ADDED BECAUSE A MUTATION SURVIVED. `p11e-status-read-loses-owner-gate` hollowed out the owner
  -- check in `get_owner_safety_status` and the whole suite stayed green: every assertion above
  -- exercised the CHALLENGE gate, and nothing had ever asked whether the STATUS gate existed. An
  -- ungated status read is a death-process oracle — any authenticated user could ask "is a release
  -- running against this estate id", which is precisely the fact §17 protects. Two routines, two
  -- gates, and only one of them was being watched.
  refusal := null;
  for v_res, cause in
    select harness_rs.attempt(t.probe_uid, format('select public.get_owner_safety_status(%L)', t.probe_estate)),
           t.probe_cause
      from (values
        (BEN_C,   C,                 'beneficiary'),
        (DELE_C,  C,                 'professional delegate'),
        (EXEC_C,  C,                 'the claimant/designee'),
        (ADMIN_C, C,                 'a platform admin'),
        (OWNER_G, C,                 'a foreign owner'),
        (OWNER_C, gen_random_uuid(), 'the owner against a NONEXISTENT estate')
      ) t(probe_uid, probe_estate, probe_cause)
  loop
    if v_res = 'OK' then
      raise exception 'FAIL: % could read the owner safety status', cause;
    end if;
    if refusal is null then refusal := v_res;
    elsif v_res is distinct from refusal then
      raise exception 'FAIL: status refusal for "%" differs: % vs %', cause, v_res, refusal;
    end if;
  end loop;
  if refusal is distinct from 'ERR:not_authorized' then
    raise exception 'FAIL: the common status refusal carries more than the sentinel: %', refusal;
  end if;
  if position('auth_required' in harness_rs.attempt(null, format('select public.get_owner_safety_status(%L)', C))) = 0 then
    raise exception 'FAIL: anonymous status read was not refused';
  end if;
  -- ★ AND THE POSITIVE CONTROL: the OWNER can read it, or the refusals above prove only that the
  -- routine is broken for everyone.
  perform set_config('request.jwt.claim.sub', OWNER_C::text, true);
  set local role authenticated;
  select public.get_owner_safety_status(C) into v_status;
  reset role;
  if v_status is null then
    raise exception 'FAIL[control]: the owner could not read their own safety status';
  end if;
  raise notice '  ok   the STATUS read is owner-gated too (6 causes byte-identical; owner can read)';

  -- ── THE OWNER HALTS IT: one action, no evidence, no review, no designation, no waiting ────────
  auth_before := harness_rs.authority_snapshot(C);
  dele_before := harness_rs.composed(DELE_C, C);
  v_res := harness_rs.attempt(OWNER_C, format('select public.challenge_death_process(%L)', C));
  if v_res <> 'OK' then raise exception 'FAIL: the OWNER could not challenge: %', v_res; end if;
  if public.estate_lifecycle_state(C) <> 'challenge_halted' then
    raise exception 'FAIL: the challenge did not halt the lifecycle';
  end if;
  select status into v_res from public.death_verification_cases where id = v_case;
  if v_res <> 'halted' then
    raise exception 'FAIL: the open case reads % after an owner challenge (expected halted — '
      'distinct from cancelled, which means the initiator withdrew)', v_res;
  end if;
  raise notice '  ok   the owner halts the process in ONE call (no evidence, review, designation or wait)';

  -- ── THE OWNER WITH NO ACTIVE DESIGNEE CAN STILL HALT (R13) ────────────────────────────────────
  --
  -- ★ ADDED BECAUSE A MUTATION SURVIVED, AND THE FIXTURE WAS THE REASON. A mutation requiring an
  -- active designation to challenge went UNDETECTED: estate C has an executor, so demanding one
  -- changed no outcome. The test could not fail — the transformation was invisible to the input.
  --
  -- The state that makes it observable is also the one that matters most: an owner who discovers a
  -- process against them and REVOKES the designee must still be able to halt it. Under the mutation
  -- that owner is locked out of their own protection by the very act of removing the person running
  -- the process against them.
  declare
    OWNER_N uuid; EXEC_N uuid; N uuid; v_case_n uuid;
  begin
    insert into auth.users default values returning id into OWNER_N;
    insert into auth.users default values returning id into EXEC_N;
    insert into public.estates (owner_id, name) values (OWNER_N, 'RS Estate N') returning id into N;
    insert into public.estate_memberships (estate_id, user_id, role, status)
    values (N, OWNER_N, 'primary_user', 'approved');
    insert into public.estate_designations (estate_id, user_id, designation_type, status)
    values (N, EXEC_N, 'executor', 'active');

    -- A process starts, then the owner revokes the designee (their real-world first move).
    if harness_rs.attempt(EXEC_N, format('select public.initiate_death_verification_case(%L)', N)) <> 'OK' then
      raise exception 'FAIL[no-designee precondition]: the designee could not initiate on N';
    end if;
    select id into v_case_n from public.death_verification_cases where estate_id = N and status = 'open';
    update public.estate_designations set status = 'revoked' where estate_id = N;
    if exists (select 1 from public.estate_designations
                where estate_id = N and status = 'active') then
      raise exception 'FAIL[no-designee precondition]: estate N still has an active designation — '
        'this fixture cannot observe a designation requirement';
    end if;

    -- The owner halts it anyway. No designation, no evidence, no review — one call.
    if harness_rs.attempt(OWNER_N, format('select public.challenge_death_process(%L)', N)) <> 'OK' then
      raise exception 'FAIL: an owner with NO active designation could not halt a process against '
        'their own estate — the challenge acquired a designation requirement (R13)';
    end if;
    if public.estate_lifecycle_state(N) <> 'challenge_halted' then
      raise exception 'FAIL: the no-designee challenge did not halt the lifecycle';
    end if;
    if (select status from public.death_verification_cases where id = v_case_n) <> 'halted' then
      raise exception 'FAIL: the no-designee challenge did not halt the open case';
    end if;
    raise notice '  ok   an owner with NO active designation can still halt (R13: no designation gate)';
  end;

  -- ── STAGE E · challenge_halted DISCLOSES NOTHING, and nothing was manufactured ────────────────
  if harness_rs.composed(DELE_C, C)::text is distinct from dele_before::text then
    raise exception 'FAIL[E]: challenge_halted moved the death-conditioned payload';
  end if;
  if harness_rs.authority_snapshot(C)::text is distinct from auth_before::text then
    raise exception 'FAIL[E]: the challenge touched grants, memberships or designations';
  end if;
  raise notice '  ok   STAGE E (challenge_halted): payload byte-identical; no authority row moved';

  -- ── IDEMPOTENT, and TERMINAL: nothing reopens a halted process ────────────────────────────────
  select count(*) into n from public.audit_logs where estate_id = C and action = 'death_process.challenged';
  v_res := harness_rs.attempt(OWNER_C, format('select public.challenge_death_process(%L)', C));
  if v_res <> 'OK' then raise exception 'FAIL: idempotent challenge replay errored: %', v_res; end if;
  if (select count(*) from public.audit_logs where estate_id = C and action = 'death_process.challenged') <> n then
    raise exception 'FAIL: idempotent challenge replay wrote a second audit row';
  end if;

  -- Release can NEVER proceed from a halted process.
  v_res := harness_rs.as_admin(ADMIN_C, format('select public.authorize_release(%L, %L)', C, 'post-halt probe'));
  if position('invalid_release_state' in v_res) = 0 then
    raise exception 'FAIL: release from challenge_halted got %', v_res;
  end if;
  -- No existing routine reopens it: every outbound transition is refused by the closed map.
  for v_res in select unnest(array['active', 'death_verification_pending', 'death_verified',
                                   'owner_notification_dispatched', 'challenge_window', 'released']) loop
    begin
      perform public.apply_estate_lifecycle_transition(C, v_res, null, 'rs-harness-probe');
      raise exception 'FAIL: challenge_halted -> % was accepted — a halted process can be reopened', v_res;
    exception when others then
      if position('invalid_lifecycle_transition' in SQLERRM) = 0 then
        raise exception 'FAIL: reopening probe to % raised the wrong error: %', v_res, SQLERRM;
      end if;
    end;
  end loop;
  -- A new window cannot be opened on it either (the admin door refuses).
  v_res := harness_rs.as_admin(ADMIN_C, format('select public.begin_challenge_window(%L)', C));
  if position('invalid_window_state' in v_res) = 0 then
    raise exception 'FAIL: a window was opened on a halted process: %', v_res;
  end if;
  -- And a fresh case cannot be initiated to route around it.
  v_res := harness_rs.attempt(EXEC_C, format('select public.initiate_death_verification_case(%L)', C));
  if position('lifecycle_conflict' in v_res) = 0 then
    raise exception 'FAIL: a new case was initiated on a halted estate: %', v_res;
  end if;
  raise notice '  ok   challenge_halted is TERMINAL: no transition out, no window, no new case, no release';

  -- ── THE AUDIT RECORDS THE ACT, NEVER THE PROVENANCE (§17) ─────────────────────────────────────
  if not exists (select 1 from public.audit_logs
                  where estate_id = C and action = 'death_process.challenged'
                    and actor_id = OWNER_C and metadata ->> 'from_state' is not null) then
    raise exception 'FAIL: the challenge audit is missing, misattributed, or lost its from_state';
  end if;
  if exists (select 1 from public.audit_logs
              where estate_id = C and action = 'death_process.challenged'
                and (metadata::text ~* '(ip|user_agent|device|email|phone|channel|location|latitude)'
                     or ip is not null or user_agent is not null)) then
    raise exception 'FAIL: the challenge audit carries provenance about a living owner';
  end if;
  raise notice '  ok   the challenge audit records the ACT and no provenance (no channel, device or address)';

  -- ── THE CLAIMANT LEARNS ONLY THAT IT HALTED (§17) ─────────────────────────────────────────────
  -- The case row is the claimant-visible fact in this phase, and it says `halted` and nothing else:
  -- no channel, no timestamp of the owner action, no owner identity.
  if exists (select 1 from public.death_verification_cases
              where id = v_case
                and (decision_note is not null or decided_by is not null)) then
    raise exception 'FAIL: the halted case carries a decision note or actor — challenge provenance '
      'must not reach the claimant-visible row';
  end if;
  raise notice '  ok   the claimant-visible case says halted alone (no provenance, no owner identity)';
end $rs2$;

-- =================================================================================================
-- 3 · THE EXACT-BOUNDARY TIEBREAK — challenge wins, at the same instant, in both orderings
-- =================================================================================================
--
-- ★ THE INSTANT IS CONSTRUCTED, NOT WAITED FOR. `now()` is the transaction timestamp and is
-- constant inside a transaction, so setting `owner_notified_at = now() - duration` puts the estate
-- at EXACTLY `now() = notified_at + duration` — the boundary instant itself, not ±1 second. Release
-- requires the window STRICTLY elapsed, so at that instant it refuses; the challenge does not
-- consult the clock at all, so it succeeds. Both orderings are exercised.
do $rs3$
declare
  OWNER_T uuid; EXEC_T uuid; ADMIN_T uuid; ADMIN2_T uuid; T1 uuid; T2 uuid;
  v_case uuid; v_res text; v_notified timestamptz; v_dur interval;
begin
  raise notice '3 · the exact-boundary tiebreak (challenge wins ties)';

  v_dur := public.challenge_window_duration();
  if v_dur is null then
    raise exception 'FAIL: the tiebreak cannot be constructed — no window duration is configured';
  end if;

  insert into auth.users default values returning id into OWNER_T;
  insert into auth.users default values returning id into EXEC_T;
  insert into auth.users default values returning id into ADMIN_T;
  insert into auth.users default values returning id into ADMIN2_T;
  insert into public.admins (user_id) values (ADMIN_T), (ADMIN2_T) on conflict do nothing;
  update auth.users set email = 'rs-owner-t@example.invalid' where id = OWNER_T;

  -- Two identical estates at the identical boundary instant: one tests release-then-challenge,
  -- the other challenge-then-release.
  for v_res in select unnest(array['release_first', 'challenge_first']) loop
    declare E uuid;
    begin
      insert into public.estates (owner_id, name) values (OWNER_T, 'RS Tie ' || v_res) returning id into E;
      insert into public.estate_memberships (estate_id, user_id, role, status)
      values (E, OWNER_T, 'primary_user', 'approved');
      insert into public.estate_designations (estate_id, user_id, designation_type, status)
      values (E, EXEC_T, 'executor', 'active');

      perform harness_rs.attempt(EXEC_T, format('select public.initiate_death_verification_case(%L)', E));
      select id into v_case from public.death_verification_cases where estate_id = E and status = 'open';
      perform harness_rs.as_admin(ADMIN_T, format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case));
      perform harness_rs.as_admin(ADMIN_T, format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));
      perform harness_rs.as_admin(ADMIN_T, format('select public.dispatch_owner_safety_notice(%L)', E));
      perform harness_rs.as_admin(ADMIN_T, format('select public.begin_challenge_window(%L)', E));

      -- ★ THE BOUNDARY, EXACTLY: notified_at + duration = now().
      update public.estate_lifecycle
         set owner_notified_at = now() - v_dur
       where estate_id = E;
      select owner_notified_at into v_notified from public.estate_lifecycle where estate_id = E;
      if v_notified + v_dur is distinct from now() then
        raise exception 'FAIL: the boundary fixture is not exact (notified+duration=%, now=%)',
          v_notified + v_dur, now();
      end if;

      if v_res = 'release_first' then
        -- Release attempts FIRST at the boundary and must refuse…
        if position('release_window_not_elapsed' in
             harness_rs.as_admin(ADMIN2_T, format('select public.authorize_release(%L, %L)', E, 'boundary'))) = 0 then
          raise exception 'FAIL[TIE]: release did not refuse at the exact boundary instant — the '
            'window must be STRICTLY elapsed, and a tie belongs to the owner';
        end if;
        -- …and the owner challenge then succeeds at the same instant.
        if harness_rs.attempt(OWNER_T, format('select public.challenge_death_process(%L)', E)) <> 'OK' then
          raise exception 'FAIL[TIE]: the owner could not challenge at the boundary instant';
        end if;
      else
        -- The owner challenges FIRST at the boundary…
        if harness_rs.attempt(OWNER_T, format('select public.challenge_death_process(%L)', E)) <> 'OK' then
          raise exception 'FAIL[TIE]: the owner could not challenge at the boundary instant';
        end if;
        -- …and release is then impossible, for the stronger reason (the state, not the clock).
        if position('invalid_release_state' in
             harness_rs.as_admin(ADMIN2_T, format('select public.authorize_release(%L, %L)', E, 'post-challenge'))) = 0 then
          raise exception 'FAIL[TIE]: release did not refuse after an owner challenge';
        end if;
      end if;

      if public.estate_lifecycle_state(E) <> 'challenge_halted' then
        raise exception 'FAIL[TIE:%]: the estate did not end halted', v_res;
      end if;
      raise notice '  ok   TIE (%): challenge wins at the exact boundary instant', v_res;
    end;
  end loop;

  -- ★ ONE SECOND PAST THE BOUNDARY, RELEASE WORKS — the positive control that proves the refusals
  -- above came from the STRICT comparison and not from a release path that never works.
  declare E2 uuid;
  begin
    insert into public.estates (owner_id, name) values (OWNER_T, 'RS Tie control') returning id into E2;
    insert into public.estate_memberships (estate_id, user_id, role, status)
    values (E2, OWNER_T, 'primary_user', 'approved');
    insert into public.estate_designations (estate_id, user_id, designation_type, status)
    values (E2, EXEC_T, 'executor', 'active');
    perform harness_rs.attempt(EXEC_T, format('select public.initiate_death_verification_case(%L)', E2));
    select id into v_case from public.death_verification_cases where estate_id = E2 and status = 'open';
    perform harness_rs.as_admin(ADMIN_T, format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case));
    perform harness_rs.as_admin(ADMIN_T, format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));
    perform harness_rs.as_admin(ADMIN_T, format('select public.dispatch_owner_safety_notice(%L)', E2));
    perform harness_rs.as_admin(ADMIN_T, format('select public.begin_challenge_window(%L)', E2));
    update public.estate_lifecycle
       set owner_notified_at = now() - v_dur - interval '1 second'
     where estate_id = E2;
    perform harness_rs.as_admin(ADMIN2_T, format('select public.authorize_release(%L, %L)', E2, 'control'));
    if public.estate_lifecycle_state(E2) <> 'released' then
      raise exception 'FAIL[TIE CONTROL]: release one second past the boundary did not succeed — '
        'the boundary refusals above prove nothing';
    end if;
    raise notice '  ok   CONTROL: one second past the boundary, release succeeds (the refusals were the tie)';
  end;
end $rs3$;

-- =================================================================================================
-- 4 · RELEASE GUARDS — every precondition refuses on its own
-- =================================================================================================
do $rs4$
declare
  OWNER_R uuid; EXEC_R uuid; ADMIN_R uuid; ADMIN2_R uuid; R1 uuid;
  v_case uuid; v_res text;
begin
  raise notice '4 · release guards';

  insert into auth.users default values returning id into OWNER_R;
  insert into auth.users default values returning id into EXEC_R;
  insert into auth.users default values returning id into ADMIN_R;
  insert into auth.users default values returning id into ADMIN2_R;
  insert into public.admins (user_id) values (ADMIN_R), (ADMIN2_R) on conflict do nothing;
  update auth.users set email = 'rs-owner-r@example.invalid' where id = OWNER_R;
  insert into public.estates (owner_id, name) values (OWNER_R, 'RS Estate R') returning id into R1;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (R1, OWNER_R, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (R1, EXEC_R, 'executor', 'active');

  -- Release from `active` (no lifecycle row at all) refuses.
  if position('invalid_release_state' in
       harness_rs.as_admin(ADMIN_R, format('select public.authorize_release(%L, %L)', R1, 'probe'))) = 0 then
    raise exception 'FAIL: release did not refuse on an estate with no death process';
  end if;

  -- A window cannot be opened without a verified case (the workflow precondition).
  perform harness_rs.attempt(EXEC_R, format('select public.initiate_death_verification_case(%L)', R1));
  v_res := harness_rs.as_admin(ADMIN_R, format('select public.begin_challenge_window(%L)', R1));
  if position('invalid_window_state' in v_res) = 0 then
    raise exception 'FAIL: a window opened on a merely-pending estate: %', v_res;
  end if;

  -- The window door is admin-gated: the designee and the owner cannot open it themselves.
  select id into v_case from public.death_verification_cases where estate_id = R1 and status = 'open';
  perform harness_rs.as_admin(ADMIN_R, format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case));
  perform harness_rs.as_admin(ADMIN_R, format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));
  v_res := harness_rs.attempt(EXEC_R, format('select public.begin_challenge_window(%L)', R1));
  if position('admin_required' in v_res) = 0 then
    raise exception 'FAIL: the designee opened the challenge window: %', v_res;
  end if;
  v_res := harness_rs.attempt(OWNER_R, format('select public.begin_challenge_window(%L)', R1));
  if position('admin_required' in v_res) = 0 then
    raise exception 'FAIL: the owner opened the challenge window: %', v_res;
  end if;
  raise notice '  ok   the window door is admin-gated; release refuses from active and from pending';

  -- Open the window, then strip the committed notice: release must refuse (owner_not_notified).
  v_res := harness_rs.as_admin(ADMIN_R, format('select public.dispatch_owner_safety_notice(%L)', R1));
  if v_res <> 'OK' then raise exception 'FAIL: dispatch refused: %', v_res; end if;
  v_res := harness_rs.as_admin(ADMIN_R, format('select public.begin_challenge_window(%L)', R1));
  if v_res <> 'OK' then raise exception 'FAIL: window open refused: %', v_res; end if;
  update public.estate_lifecycle
     set owner_notified_at = null, safety_notification_id = null
   where estate_id = R1;
  if position('owner_not_notified' in
       harness_rs.as_admin(ADMIN2_R, format('select public.authorize_release(%L, %L)', R1, 'probe'))) = 0 then
    raise exception 'FAIL: release did not refuse with NO committed owner notice';
  end if;
  raise notice '  ok   release refuses without a committed owner safety notice';

  -- Restore the notice and elapse it, then delete the verified case: release must still refuse.
  update public.estate_lifecycle
     set owner_notified_at = now() - interval '30 days',
         safety_notification_id = gen_random_uuid()
   where estate_id = R1;
  -- ★ THE EMAIL-CHANNEL PRECONDITION AT THE RELEASE DOOR, exercised on its own. Every other path
  -- leaves a live notice row behind, so this guard had never fired: cancelling the notice while the
  -- lifecycle facts stay intact is the only state that isolates it.
  update public.owner_notice_outbox set status = 'cancelled' where estate_id = R1;
  if position('owner_channel_unreachable' in
       harness_rs.as_admin(ADMIN2_R, format('select public.authorize_release(%L, %L)', R1, 'probe'))) = 0 then
    raise exception 'FAIL: release did not refuse with the owner notice CANCELLED — the email '
      'channel precondition is not enforced at the release door';
  end if;
  update public.owner_notice_outbox set status = 'queued' where estate_id = R1;
  raise notice '  ok   release refuses when the owner email notice is cancelled (D4 at the door)';

  update public.death_verification_cases set status = 'rejected' where estate_id = R1;
  if position('no_verified_case' in
       harness_rs.as_admin(ADMIN2_R, format('select public.authorize_release(%L, %L)', R1, 'probe'))) = 0 then
    raise exception 'FAIL: release did not refuse with no VERIFIED case';
  end if;
  raise notice '  ok   release refuses without a verified death-verification case';
end $rs4$;

-- =================================================================================================
-- 5 · CLAIM / EVIDENCE / ATTAINED-LEVEL FIREWALL — none of them is a release
-- =================================================================================================
do $rs5$
declare
  OWNER_W uuid; EXEC_W uuid; DELE_W uuid; ADMIN_W uuid; W uuid; DOC_W uuid;
  v_case uuid; v_ev uuid; before_ jsonb; after_ jsonb;
begin
  raise notice '5 · claim / evidence / attained-level firewall';

  insert into auth.users default values returning id into OWNER_W;
  insert into auth.users default values returning id into EXEC_W;
  insert into auth.users default values returning id into DELE_W;
  insert into auth.users default values returning id into ADMIN_W;
  insert into public.admins (user_id) values (ADMIN_W) on conflict do nothing;
  insert into public.estates (owner_id, name) values (OWNER_W, 'RS Estate W') returning id into W;
  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (W, OWNER_W, 'primary_user', 'approved'),
    (W, DELE_W,  'professional_delegate', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (W, EXEC_W, 'executor', 'active');
  insert into public.documents (estate_id, title) values (W, 'RS evidence doc') returning id into DOC_W;
  perform harness_dv.grant_inventory(W, OWNER_W, DELE_W, 'professional_delegate', 'category_summary', 'after_verified_death');

  before_ := harness_rs.composed(DELE_W, W);

  -- ── A CLAIM, SUBMITTED AND APPROVED, RELEASES NOTHING ─────────────────────────────────────────
  --
  -- ★ THE ONE THING A CLAIM MAY MOVE IS ITS OWN LABEL, and the comparison is written to say so
  -- precisely rather than to paper over it. `get_estate_discovery` carries `release_state`, a
  -- projection of `claim_packets.status` that 10-A put there deliberately so a survivor can be told
  -- "a claim is under review" — with no disclosure following from it. So the assertion is split:
  -- the label MUST move (otherwise this fixture proves nothing about claims), and every other byte
  -- of every surface must not. Comparing whole payloads would have failed on the designed
  -- behaviour; ignoring the field entirely would have stopped testing that the seam is label-only.
  insert into public.claim_packets (estate_id, requested_by, status) values (W, EXEC_W, 'approved');
  if public.estate_lifecycle_state(W) <> 'active' then
    raise exception 'FAIL: an approved claim moved the AUTHORITATIVE lifecycle — the claim '
      'projection became the release carrier';
  end if;
  after_ := harness_rs.composed(DELE_W, W);
  if (after_ -> 'discovery' ->> 'release_state') is not distinct from (before_ -> 'discovery' ->> 'release_state') then
    raise exception 'FAIL[control]: the approved claim did not move its own label — this fixture '
      'cannot observe a claim at all, so the no-content assertion below is vacuous';
  end if;
  if (after_ -> 'discovery' ->> 'release_state') <> 'claim_approved' then
    raise exception 'FAIL: the claim label reads % after approval', after_ -> 'discovery' ->> 'release_state';
  end if;
  if jsonb_set(after_, '{discovery,release_state}', '"x"'::jsonb)::text
     is distinct from jsonb_set(before_, '{discovery,release_state}', '"x"'::jsonb)::text then
    raise exception 'FAIL: an approved claim moved CONTENT, not just its label. before=% after=%',
      before_::text, after_::text;
  end if;
  -- Re-anchor the baseline to the post-claim world for the evidence/attainment stages below.
  before_ := after_;

  -- EVIDENCE received and accepted releases nothing.
  perform harness_rs.attempt(EXEC_W, format('select public.initiate_death_verification_case(%L)', W));
  select id into v_case from public.death_verification_cases where estate_id = W and status = 'open';
  perform harness_rs.attempt(EXEC_W, format('select public.attach_death_verification_evidence(%L, %L)', v_case, DOC_W));
  select id into v_ev from public.death_verification_evidence where case_id = v_case;
  perform harness_rs.as_admin(ADMIN_W, format('select public.admin_review_death_evidence(%L, ''reviewed_accepted'')', v_ev));
  if harness_rs.composed(DELE_W, W)::text is distinct from before_::text then
    raise exception 'FAIL: accepted evidence moved the death-conditioned payload';
  end if;

  -- ATTAINED LEVEL sufficient releases nothing.
  perform harness_rs.as_admin(ADMIN_W, format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case));
  if harness_rs.composed(DELE_W, W)::text is distinct from before_::text then
    raise exception 'FAIL: a sufficient attained level moved the death-conditioned payload';
  end if;
  if public.estate_lifecycle_state(W) <> 'death_verification_pending' then
    raise exception 'FAIL: evidence or attainment moved the lifecycle by itself';
  end if;

  -- And release is impossible from every one of those states.
  if position('invalid_release_state' in
       harness_rs.as_admin(ADMIN_W, format('select public.authorize_release(%L, %L)', W, 'firewall probe'))) = 0 then
    raise exception 'FAIL: release did not refuse from a merely-pending, evidenced, attained estate';
  end if;
  raise notice '  ok   claim approval, accepted evidence and sufficient attainment each release NOTHING';

  delete from public.claim_packets where estate_id = W;
end $rs5$;

-- =================================================================================================
-- 6 · DISPATCH FAILURE, ROLLBACK, AND OUTBOX SAFETY (Phase 11-F, Stages 2 and 3)
-- =================================================================================================
do $rs6$
declare
  OWNER_U uuid; EXEC_U uuid; ADMIN_U uuid; U uuid;
  v_case uuid; v_res text; n int; v_census jsonb; v_audit int; v_purged int;
begin
  raise notice '6 · dispatch failure, rollback, and outbox safety';

  insert into auth.users default values returning id into OWNER_U;
  insert into auth.users default values returning id into EXEC_U;
  insert into auth.users default values returning id into ADMIN_U;
  insert into public.admins (user_id) values (ADMIN_U) on conflict do nothing;
  insert into public.estates (owner_id, name) values (OWNER_U, 'RS Estate U') returning id into U;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (U, OWNER_U, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (U, EXEC_U, 'executor', 'active');
  -- ★ NO EMAIL ON THIS OWNER, deliberately: this estate exercises the unreachable-channel path.

  perform harness_rs.attempt(EXEC_U, format('select public.initiate_death_verification_case(%L)', U));
  select id into v_case from public.death_verification_cases where estate_id = U and status = 'open';
  perform harness_rs.as_admin(ADMIN_U, format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case));
  perform harness_rs.as_admin(ADMIN_U, format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));

  -- ★ D4 — AN UNREACHABLE OWNER STOPS THE WHOLE PROCESS. Not a warning, not a queued row nobody can
  -- deliver: the transition refuses and the estate stays at death_verified, where nothing releases.
  v_res := harness_rs.as_admin(ADMIN_U, format('select public.dispatch_owner_safety_notice(%L)', U));
  if position('owner_channel_unreachable' in v_res) = 0 then
    raise exception 'FAIL: dispatch to an owner with NO email address got %', v_res;
  end if;

  -- ★ AND THE FAILURE ROLLED BACK EVERYTHING. No outbox row, no in-app notice, no state change —
  -- a half-dispatch that moved the lifecycle would start a clock on an owner who was never told.
  select count(*) into n from public.owner_notice_outbox where estate_id = U;
  if n <> 0 then
    raise exception 'FAIL: a failed dispatch left % outbox row(s) behind', n;
  end if;
  select count(*) into n from public.notifications where estate_id = U;
  if n <> 0 then
    raise exception 'FAIL: a failed dispatch left % in-app notification(s) behind', n;
  end if;
  if public.estate_lifecycle_state(U) <> 'death_verified' then
    raise exception 'FAIL: a failed dispatch moved the lifecycle to %', public.estate_lifecycle_state(U);
  end if;
  raise notice '  ok   an unreachable owner refuses dispatch and rolls back BOTH channels and the state';

  -- Give the owner a channel; the same call now succeeds, proving the refusal was the address.
  update auth.users set email = 'rs-owner-u@example.invalid' where id = OWNER_U;
  v_res := harness_rs.as_admin(ADMIN_U, format('select public.dispatch_owner_safety_notice(%L)', U));
  if v_res <> 'OK' then
    raise exception 'FAIL[control]: dispatch still refused after the owner became reachable: %', v_res;
  end if;
  raise notice '  ok   CONTROL: the same dispatch succeeds once the owner is reachable';

  -- ── THE AGE GATE (Stage 3) ────────────────────────────────────────────────────────────────────
  -- A notice older than the gate is never sent and never deleted: it settles as failedPermanent
  -- with an explicit class, leaving the evidence that the owner was not reached in time.
  update public.owner_notice_outbox
     set requested_at = now() - interval '30 days'
   where estate_id = U;
  perform public.claim_owner_notices(25);
  select count(*) into n from public.owner_notice_outbox
   where estate_id = U and status = 'failedPermanent' and failure_class = 'stale_beyond_age_gate';
  if n <> 1 then
    raise exception 'FAIL: the age gate did not settle the stale notice (% row(s))', n;
  end if;
  raise notice '  ok   AGE GATE: a stale notice is marked failedPermanent, never sent, never deleted';

  -- A FRESH notice IS claimable — the control that proves the gate is not simply refusing everything.
  update public.owner_notice_outbox
     set requested_at = now(), status = 'queued', failure_class = null
   where estate_id = U;
  select count(*) into n from public.claim_owner_notices(25);
  if n <> 1 then
    raise exception 'FAIL[control]: a FRESH notice was not claimable (% claimed) — the age gate is '
      'refusing everything and the stale assertion above proves nothing', n;
  end if;
  raise notice '  ok   CONTROL: a fresh notice IS claimed (the gate discriminates)';

  -- ── THE PURGE IS NEVER SILENT, AND NEVER TAKES A LIVE MESSAGE (Stage 3) ──────────────────────
  --
  -- ★ THE FIXTURE MIXES SETTLED AND IN-FLIGHT ROWS, DELIBERATELY. With only in-flight rows the
  -- (correct) COUNT returns 0 and the routine short-circuits before the DELETE ever runs — so a
  -- widened DELETE would be invisible, one layer masked by another. A mix makes the count non-zero,
  -- the delete execute, and the survival of the in-flight row an actual observation.
  select count(*) into v_audit from public.outbox_purge_audit;
  update public.owner_notice_outbox set status = 'dispatched', dispatched_at = now() where estate_id = U;
  -- ★ PHASE 11-OC — THE SECOND ROW IS GENERATION 2 OF THE SAME EPISODE, WHICH IS THE ONLY SHAPE THE
  -- MODEL PERMITS. The partial unique index allows exactly ONE current generation per case, so two
  -- coexisting rows for one estate are legal only as a supersession pair. That is also the REALISTIC
  -- shape — it is what an operator re-notice produces — so the purge is now exercised against a state
  -- production can actually reach, rather than one only a direct INSERT could manufacture.
  --
  -- The write order is forced: retire the predecessor against a pre-generated successor id, THEN
  -- insert the successor. Insert-first would raise unique_violation; this order is legal only because
  -- the superseded_by FK is DEFERRABLE INITIALLY DEFERRED (migration 0058 proves both directions).
  declare
    v_epis uuid;
    v_gen2 uuid := gen_random_uuid();
  begin
    select o.case_id into v_epis from public.owner_notice_outbox o
     where o.estate_id = U and o.superseded_by is null limit 1;
    if v_epis is null then
      raise exception 'FAIL[precondition]: estate U''s notice carries no case_id, so the purge '
        'fixture cannot build a supersession pair — the dispatch path stopped writing the episode key';
    end if;
    update public.owner_notice_outbox set superseded_by = v_gen2
     where estate_id = U and superseded_by is null;
    insert into public.owner_notice_outbox
      (id, estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
       reissue_reason)
    values (v_gen2, U, OWNER_U, 'email', 'rs-owner-u@example.invalid',
            'death_process.window_opened', 'processing', v_epis, 2, 'prior_failed_permanent');
  end;

  select public.purge_outbox_rows('owner_notice_outbox', now() + interval '1 day', 'harness sweep')
    into v_purged;
  if v_purged <> 1 then
    raise exception 'FAIL: the purge removed % row(s), expected exactly the 1 SETTLED row', v_purged;
  end if;
  -- The in-flight message survived: it is still on its way to a living owner.
  select count(*) into n from public.owner_notice_outbox where estate_id = U and status = 'processing';
  if n <> 1 then
    raise exception 'FAIL: the purge deleted an IN-FLIGHT safety notice — a live warning to an owner';
  end if;
  delete from public.owner_notice_outbox where estate_id = U;
  if (select count(*) from public.outbox_purge_audit) <> v_audit + 1 then
    raise exception 'FAIL: the purge wrote no audit row — a silent purge is impossible by design';
  end if;
  if not exists (select 1 from public.outbox_purge_audit
                  where outbox_name = 'owner_notice_outbox' and row_count = 1
                    and btrim(reason) <> '' and actor_id is not null) then
    raise exception 'FAIL: the purge audit row is missing its count, reason or actor';
  end if;
  raise notice '  ok   PURGE: in-flight rows refused; settled rows removed WITH an attributed audit row';

  -- A blank reason and an unknown outbox are both refused.
  v_res := harness_rs.as_admin(ADMIN_U,
    format('select public.purge_outbox_rows(%L, %L, %L)', 'owner_notice_outbox', now(), '  '));
  if position('purge_reason_required' in v_res) = 0 then
    raise exception 'FAIL: a blank purge reason was accepted (got %)', v_res;
  end if;
  v_res := harness_rs.as_admin(ADMIN_U,
    format('select public.purge_outbox_rows(%L, %L, %L)', 'invitation_delivery_outbox', now(), 'probe'));
  if position('unknown_outbox' in v_res) = 0 then
    raise exception 'FAIL: the purge accepted an outbox outside its closed vocabulary (got %)', v_res;
  end if;
  raise notice '  ok   PURGE: blank reason and unknown outbox both refused';

  -- ── THE CENSUS (Stage 3 classification) ───────────────────────────────────────────────────────
  -- ★ THE TOTAL IS COMPARED AGAINST THE REAL ROW COUNT, not merely present. A census whose total
  -- is wrong is worse than no census: it is the number an operator quotes when deciding to purge.
  -- (The first implementation joined a per-status aggregate laterally and tripled its own total,
  -- which a presence-only assertion would have passed.)
  select count(*) into n from public.owner_notice_outbox;
  v_census := harness_rs.as_admin_json(ADMIN_U, 'select public.owner_notice_census()');
  if v_census is null or not (v_census ? 'total') or not (v_census ? 'age_gate')
     or not (v_census ? 'by_status') then
    raise exception 'FAIL: the outbox census does not report totals, status map and the age gate: %', v_census;
  end if;
  if (v_census ->> 'total')::int is distinct from n then
    raise exception 'FAIL: the census reports total=% against % real row(s)',
      v_census ->> 'total', n;
  end if;
  -- The per-status counts must sum to the same total, or the two halves disagree.
  if (select coalesce(sum(value::int), 0) from jsonb_each_text(v_census -> 'by_status')) is distinct from n then
    raise exception 'FAIL: the census status map sums to % against % real row(s): %',
      (select coalesce(sum(value::int), 0) from jsonb_each_text(v_census -> 'by_status')), n, v_census;
  end if;
  -- Counts only: no recipient address may appear anywhere in the census payload.
  if v_census::text ilike '%@example.invalid%' then
    raise exception 'FAIL: the census leaked a recipient address';
  end if;
  raise notice '  ok   CENSUS: totals, status/age distribution and the age gate; no address disclosed';
end $rs6$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 7 · PHASE 11-L — THE HALT NOTIFICATION, HALTED FROM `death_verification_pending`
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- Every assertion here is about a notification ROW, because that is the only artifact the recipient
-- ever sees. The stage is built so each rule is observable: a fixture where the recipient is not the
-- caller, a second estate with its OWN initiator, a revoked designation, and a failed halt.
--
-- ★ SCOPE, CORRECTED IN PHASE 11-NR. Every estate in this section halts IMMEDIATELY AFTER
-- `initiate`, so every case here is 'open' and the section speaks only for that entry state. It was
-- previously read — by its own title, and by 11-M §14 — as evidence that the halt notification works
-- generally. It is not: the Branch A production drill walked verify → dispatch → window → halt and
-- found the notification could not fire there at all. The claim this section is entitled to make is
-- "halting a PENDING process notifies its initiator". The canonical operator-driven path is §8, and
-- neither section is a substitute for the other.
do $rs7$
declare
  OWNER_H uuid; EXEC_H uuid; BEN_H uuid; H uuid; v_case_h uuid;
  OWNER_X uuid; EXEC_X uuid; X uuid;
  OWNER_R uuid; EXEC_R uuid; R uuid;
  OWNER_F uuid; F uuid;
  v_res text; n int; n_before int;
  cat_title text; cat_body text; cat_kind text;
  row_title text; row_body text; row_kind text; row_link text;
begin
  raise notice ' ';
  raise notice '7 · the halt notification (Phase 11-L)';

  insert into auth.users default values returning id into OWNER_H;
  insert into auth.users default values returning id into EXEC_H;
  insert into auth.users default values returning id into BEN_H;
  insert into public.estates (owner_id, name) values (OWNER_H, 'RS Estate H') returning id into H;
  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (H, OWNER_H, 'primary_user', 'approved'),
    (H, BEN_H,   'beneficiary',  'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (H, EXEC_H, 'executor', 'active');

  -- ── CONTROL: the catalog must actually carry the event, or every assertion below is vacuous ────
  select category, title, body into cat_kind, cat_title, cat_body
    from public.notification_event_copy('death_process.halted');
  if cat_title is null or cat_body is null or cat_kind is null then
    raise exception 'FAIL[control]: the catalog has no death_process.halted entry — nothing below '
      'could observe a notification even if one were emitted';
  end if;
  -- The category must be one the RN client already decodes. `other` would render "Account update".
  if cat_kind <> 'claimUpdate' then
    raise exception 'FAIL: the halt category is %, which the client does not decode to a real label', cat_kind;
  end if;
  raise notice '  ok   CONTROL: the catalog carries death_process.halted as %', cat_kind;

  -- ── A FAILED HALT EMITS NOTHING (mutations 1 and 2) ───────────────────────────────────────────
  -- Emission lives inside the transition, so a refused halt cannot produce a row. Asserted BEFORE
  -- the successful halt, so the count below starts from a known zero.
  select count(*) into n_before from public.notifications where kind = 'claimUpdate';
  v_res := harness_rs.attempt(OWNER_H, format('select public.challenge_death_process(%L)', H));
  if position('nothing_to_challenge' in v_res) = 0 then
    raise exception 'FAIL[precondition]: challenging an untouched estate got %', v_res;
  end if;
  select count(*) into n from public.notifications where kind = 'claimUpdate';
  if n <> n_before then
    raise exception 'FAIL: a REFUSED halt emitted % notification(s) — emission is outside the '
      'transition, so a notification can exist for a state change that never happened', n - n_before;
  end if;
  raise notice '  ok   a refused halt (nothing_to_challenge) emits NOTHING';

  -- ── THE HALT NOTIFIES THE INITIATOR ───────────────────────────────────────────────────────────
  if harness_rs.attempt(EXEC_H, format('select public.initiate_death_verification_case(%L)', H)) <> 'OK' then
    raise exception 'FAIL[precondition]: the designee could not initiate on H';
  end if;
  select id into v_case_h from public.death_verification_cases where estate_id = H and status = 'open';

  -- Precondition: no halt notification exists for this estate yet, so the halt is what creates it.
  if exists (select 1 from public.notifications where estate_id = H and kind = 'claimUpdate') then
    raise exception 'FAIL[precondition]: a claimUpdate row already exists on H before the halt';
  end if;

  if harness_rs.attempt(OWNER_H, format('select public.challenge_death_process(%L)', H)) <> 'OK' then
    raise exception 'FAIL: the owner could not halt on H';
  end if;

  select count(*) into n from public.notifications where estate_id = H and kind = 'claimUpdate';
  if n <> 1 then
    raise exception 'FAIL: the halt produced % claimUpdate notification(s) on H, expected exactly 1', n;
  end if;

  select user_id, title, body, kind, action_deep_link
    into OWNER_F, row_title, row_body, row_kind, row_link
    from public.notifications where estate_id = H and kind = 'claimUpdate';
  if OWNER_F <> EXEC_H then
    raise exception 'FAIL: the halt notification went to a user who did not initiate the case';
  end if;
  raise notice '  ok   the INITIATING fiduciary receives exactly one notification';

  -- ── AND NOBODY ELSE DOES (mutation 4: the owner; plus no broadcast) ───────────────────────────
  if exists (select 1 from public.notifications
              where estate_id = H and kind = 'claimUpdate' and user_id = OWNER_H) then
    raise exception 'FAIL: the CHALLENGING OWNER received claimant-facing copy about their own halt';
  end if;
  if exists (select 1 from public.notifications
              where estate_id = H and kind = 'claimUpdate' and user_id = BEN_H) then
    raise exception 'FAIL: a beneficiary received the halt notification — this is a broadcast';
  end if;
  raise notice '  ok   the owner and the beneficiary receive NOTHING';

  -- ── THE COPY IS THE CATALOG'S, NOT COMPOSED HERE (mutation 8) ─────────────────────────────────
  if row_title is distinct from cat_title or row_body is distinct from cat_body then
    raise exception 'FAIL: the emitted copy (%, %) differs from the catalog (%, %) — text was '
      'composed at the emission site', row_title, row_body, cat_title, cat_body;
  end if;

  -- ── THE COPY DISCLOSES NOTHING (mutations 6 and 7) ────────────────────────────────────────────
  -- Channel, address, reason, evidence and accusation are each named rather than gestured at, so a
  -- future copy edit that reintroduces one fails here instead of shipping.
  if row_body ilike '%@%' or row_title ilike '%@%' then
    raise exception 'FAIL: the halt copy contains an address shape: % / %', row_title, row_body;
  end if;
  if row_body ilike '%email%' or row_body ilike '%phone%' or row_body ilike '%sms%'
     or row_body ilike '%channel%' then
    raise exception 'FAIL: the halt copy names an owner channel: %', row_body;
  end if;
  if row_body ilike '%evidence%' or row_body ilike '%certificate%' or row_body ilike '%document%' then
    raise exception 'FAIL: the halt copy names evidence: %', row_body;
  end if;
  if row_body ilike '%fraud%' or row_body ilike '%suspic%' or row_body ilike '%false%'
     or row_body ilike '%invalid%' or row_body ilike '%denied%' or row_body ilike '%reject%' then
    raise exception 'FAIL: the halt copy carries accusatory or judgemental language: %', row_body;
  end if;
  -- It must not explain WHY, and "because"/"reason" are how an explanation would arrive.
  if row_body ilike '%because%' or row_body ilike '%reason%' then
    raise exception 'FAIL: the halt copy explains the halt: %', row_body;
  end if;
  -- No identifier of any kind may be interpolated into user-facing text.
  if row_body like ('%' || H::text || '%') or row_body like ('%' || OWNER_H::text || '%')
     or row_body like ('%' || v_case_h::text || '%') then
    raise exception 'FAIL: the halt copy interpolates an identifier: %', row_body;
  end if;
  if row_body ilike '%RS Estate H%' then
    raise exception 'FAIL: the halt copy names the estate: %', row_body;
  end if;
  raise notice '  ok   copy is the catalog constant: no channel, address, reason, evidence, id or estate name';

  -- ── NO DEEP LINK (mutation 9) ─────────────────────────────────────────────────────────────────
  -- The recipient's own surface exists (/executor) but has no allowlist key in the RN client, and an
  -- unmatched string resolves to null there anyway. Emitting one would be inventing a route.
  if row_link is not null then
    raise exception 'FAIL: the halt notification carries a deep link (%) — no allowlisted fiduciary '
      'destination exists, so this can only be an unmatched or invented route', row_link;
  end if;
  raise notice '  ok   no deep link is attached';

  -- ── IDEMPOTENT RE-CHALLENGE EMITS NOTHING FURTHER (mutation 5) ────────────────────────────────
  if harness_rs.attempt(OWNER_H, format('select public.challenge_death_process(%L)', H)) <> 'OK' then
    raise exception 'FAIL: the idempotent replay of the challenge was refused';
  end if;
  select count(*) into n from public.notifications where estate_id = H and kind = 'claimUpdate';
  if n <> 1 then
    raise exception 'FAIL: an idempotent re-challenge produced % notification(s), expected 1 — the '
      'recipient is told twice that a process stopped once', n;
  end if;
  raise notice '  ok   idempotent re-challenge emits NO second notification';

  -- ── AN UNRELATED ESTATE'S INITIATOR IS UNTOUCHED (mutation 10) ────────────────────────────────
  -- A second estate with its OWN open case and its OWN initiator. Halting H must not reach X.
  insert into auth.users default values returning id into OWNER_X;
  insert into auth.users default values returning id into EXEC_X;
  insert into public.estates (owner_id, name) values (OWNER_X, 'RS Estate X') returning id into X;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (X, OWNER_X, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (X, EXEC_X, 'executor', 'active');
  if harness_rs.attempt(EXEC_X, format('select public.initiate_death_verification_case(%L)', X)) <> 'OK' then
    raise exception 'FAIL[precondition]: the designee could not initiate on X';
  end if;
  if exists (select 1 from public.notifications where user_id = EXEC_X and kind = 'claimUpdate') then
    raise exception 'FAIL: halting H notified the initiator of a DIFFERENT estate';
  end if;
  if exists (select 1 from public.notifications where estate_id = X and kind = 'claimUpdate') then
    raise exception 'FAIL: a claimUpdate row exists on X, whose process was never halted';
  end if;
  -- X's case must still be open — halting H must not have touched another estate's case at all.
  if (select status from public.death_verification_cases where estate_id = X) <> 'open' then
    raise exception 'FAIL: halting H changed the case status on X';
  end if;
  raise notice '  ok   an unrelated estate''s initiator and case are untouched';

  -- ── HISTORICAL INITIATOR: A REVOKED DESIGNEE IS STILL TOLD (the case-model rule) ──────────────
  --
  -- ★ THE FIXTURE IS BUILT SO THE RULE IS OBSERVABLE, because a live-designation lookup would pass
  -- against estate H (whose executor is still active). 0052 states the initiator fields are "a
  -- snapshot of fact … never an authority the case can later re-assert". The notification asserts no
  -- authority — it reports one fact about something this person personally did — so revocation must
  -- NOT suppress it. Under a live-designation rule the message is silently dropped for exactly the
  -- person owed it, and the owner's revocation becomes a way to stop the claimant ever learning.
  insert into auth.users default values returning id into OWNER_R;
  insert into auth.users default values returning id into EXEC_R;
  insert into public.estates (owner_id, name) values (OWNER_R, 'RS Estate R') returning id into R;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (R, OWNER_R, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (R, EXEC_R, 'executor', 'active');
  if harness_rs.attempt(EXEC_R, format('select public.initiate_death_verification_case(%L)', R)) <> 'OK' then
    raise exception 'FAIL[precondition]: the designee could not initiate on R';
  end if;
  update public.estate_designations set status = 'revoked' where estate_id = R;
  if exists (select 1 from public.estate_designations where estate_id = R and status = 'active') then
    raise exception 'FAIL[precondition]: estate R still has an active designation — this fixture '
      'cannot observe a live-designation requirement';
  end if;
  if harness_rs.attempt(OWNER_R, format('select public.challenge_death_process(%L)', R)) <> 'OK' then
    raise exception 'FAIL: the owner could not halt on R';
  end if;
  if not exists (select 1 from public.notifications
                  where estate_id = R and kind = 'claimUpdate' and user_id = EXEC_R) then
    raise exception 'FAIL: the initiator of a case was NOT told their process halted because their '
      'designation had since been revoked — historical initiator semantics were replaced by a live '
      'designation lookup, and the person owed the message is the one who lost it';
  end if;
  raise notice '  ok   a REVOKED designee is still told their own process halted (historical initiator)';

  -- ── THE OWNER-EXCLUSION GUARD, ON A FIXTURE THAT CAN OBSERVE IT ───────────────────────────────
  --
  -- ★ WITHOUT THIS ESTATE THE GUARD IS UNTESTABLE, AND THAT IS THE WHOLE REASON IT EXISTS HERE. On
  -- H the initiator (EXEC_H) is not the owner, so deleting `and v_initiator <> v_uid` changes
  -- nothing and every assertion above still passes — a control that cannot fail. The state that
  -- makes it observable is an owner who is ALSO the designated executor of their own estate:
  -- `initiate_death_verification_case` requires an active designation for auth.uid() and forbids no
  -- self-designation, so this is representable rather than contrived.
  --
  -- Such an owner halting their own process must receive NOTHING. They performed both acts; sending
  -- them claimant-facing copy about their own halt reads as a message from a stranger about their
  -- own death process.
  declare
    OWNER_S uuid; S uuid;
  begin
    insert into auth.users default values returning id into OWNER_S;
    insert into public.estates (owner_id, name) values (OWNER_S, 'RS Estate S') returning id into S;
    insert into public.estate_memberships (estate_id, user_id, role, status)
    values (S, OWNER_S, 'primary_user', 'approved');
    insert into public.estate_designations (estate_id, user_id, designation_type, status)
    values (S, OWNER_S, 'executor', 'active');

    if harness_rs.attempt(OWNER_S, format('select public.initiate_death_verification_case(%L)', S)) <> 'OK' then
      raise exception 'FAIL[precondition]: an owner who is also the designated executor could not '
        'initiate on their own estate — this fixture cannot observe the owner-exclusion guard';
    end if;
    if (select initiated_by from public.death_verification_cases where estate_id = S) <> OWNER_S then
      raise exception 'FAIL[precondition]: estate S''s case initiator is not the owner';
    end if;

    if harness_rs.attempt(OWNER_S, format('select public.challenge_death_process(%L)', S)) <> 'OK' then
      raise exception 'FAIL: the owner could not halt their own process on S';
    end if;
    if exists (select 1 from public.notifications where estate_id = S and kind = 'claimUpdate') then
      raise exception 'FAIL: an owner who initiated AND halted their own process received '
        'claimant-facing copy about it — the owner-exclusion guard is gone';
    end if;
    raise notice '  ok   an owner who is also the initiator receives NOTHING (guard is observable)';
  end;

  -- ── THE RECIPIENT IS NOT CALLER-SUPPLIABLE ────────────────────────────────────────────────────
  -- challenge_death_process takes ONE argument. A second one is unrepresentable, so no client can
  -- nominate a recipient. Asserted against the catalog rather than by reading the body.
  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.proname = 'challenge_death_process'
         and p.pronargs = 1) <> 1 then
    raise exception 'FAIL: challenge_death_process no longer has exactly one parameter — a recipient '
      'or actor argument would let a caller choose who is notified';
  end if;
  raise notice '  ok   the routine takes one argument: no recipient can be caller-supplied';

  -- ── THE STAGE TOTAL, SCOPED TO THIS STAGE'S ESTATES ───────────────────────────────────────────
  --
  -- ★ SCOPED, AND THE FIRST VERSION WAS NOT. It counted every `claimUpdate` row in the database and
  -- expected 2, which failed at 4 — correctly. Stage 2 halts estates C and N through the same door,
  -- so those two rows are the feature working, not contamination. An unscoped count in a suite that
  -- shares one database measures other stages' behaviour and calls it this stage's.
  --
  -- Four halt ATTEMPTS happened here: H refused (active), H succeeded, H replayed (idempotent),
  -- R succeeded. X was never halted. So exactly two rows, one each on H and R.
  select count(*) into n from public.notifications
   where kind = 'claimUpdate' and estate_id in (H, X, R);
  if n <> 2 then
    raise exception 'FAIL: % claimUpdate rows across this stage''s estates, expected exactly 2 '
      '(one on H, one on R, none on X)', n;
  end if;
  if (select count(*) from public.notifications where kind = 'claimUpdate' and estate_id = H) <> 1
     or (select count(*) from public.notifications where kind = 'claimUpdate' and estate_id = R) <> 1
     or (select count(*) from public.notifications where kind = 'claimUpdate' and estate_id = X) <> 0 then
    raise exception 'FAIL: the per-estate halt-notification distribution is wrong (H/R/X)';
  end if;
  raise notice '  ok   exactly 2 halt notifications: one on H, one on R, none on X (4 halt attempts)';
end $rs7$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 8 · PHASE 11-NR — THE CANONICAL OPERATOR-DRIVEN PATH, WHICH §7 NEVER TRAVERSED
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHY THIS SECTION EXISTS, STATED AS THE DEFECT IT WOULD HAVE CAUGHT. Every halt in §2, §3 and §7
-- fires IMMEDIATELY AFTER `initiate`, from `death_verification_pending`, where the case status is
-- 'open'. That is one of FOUR lifecycle states the challenge is reachable from, and it is the only
-- one where the pre-11-NR predicate `status = 'open'` matched anything. The suite did not merely
-- lack a test for the other three — it encoded the one working branch as THE representative branch,
-- which is why 11-L shipped, was proved green, and was dead on every operator-driven process.
--
-- The Branch A production fire drill found it by walking the real path:
--   lifecycle challenge_halted · case row still 'verified' · v_initiator NULL · zero notifications ·
--   the halted case still sitting in the operator's `verified` queue.
--
-- ★ THE FIXTURE IS BUILT SO THE TRANSFORMATION IS OBSERVABLE, which is the whole rule §7 broke:
--
--   · the case reaching the challenge is 'verified', so the OLD predicate matches NOTHING — asserted
--     explicitly below, so later fixture drift cannot quietly make this section tautological again;
--   · a DECOY case is present — a prior attempt on the same estate, initiated by a DIFFERENT
--     fiduciary and REJECTED by an operator — so a predicate that settles "every row for the estate"
--     is detectable, and so is a recipient recovered from the wrong row;
--   · both case rows are AGED before the challenge, because `now()` is transaction-constant and an
--     `updated_at` assertion written against it is a control that cannot fail.
do $rs8$
declare
  OWNER_V uuid; EXEC_V uuid; EXEC_P uuid; BEN_V uuid; ADMIN_V uuid; V uuid;
  OWNER_Z uuid; Z uuid;
  v_case_v uuid; v_case_p uuid;
  v_aged_v timestamptz; v_aged_p timestamptz;
  v_decided_by uuid; v_decided_at timestamptz;
  v_res text; n int;
  cat_title text; cat_body text; cat_kind text;
  row_user uuid; row_title text; row_body text; row_link text;
  q_verified jsonb; q_halted jsonb;
begin
  raise notice ' ';
  raise notice '8 · the canonical operator-driven path (Phase 11-NR)';

  insert into auth.users default values returning id into OWNER_V;
  insert into auth.users default values returning id into EXEC_V;
  insert into auth.users default values returning id into EXEC_P;
  insert into auth.users default values returning id into BEN_V;
  insert into auth.users default values returning id into ADMIN_V;
  -- D4: dispatch REFUSES without an independently reachable owner address.
  update auth.users set email = 'rs-owner-v@example.invalid' where id = OWNER_V;
  insert into public.estates (owner_id, name) values (OWNER_V, 'RS Estate V') returning id into V;
  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (V, OWNER_V, 'primary_user', 'approved'),
    (V, BEN_V,   'beneficiary',  'approved');
  -- TWO active fiduciaries: the decoy's initiator and the live case's initiator must be different
  -- people, or "the recipient came from the right row" is unobservable.
  insert into public.estate_designations (estate_id, user_id, designation_type, status) values
    (V, EXEC_P, 'executor', 'active'),
    (V, EXEC_V, 'trustee',  'active');
  insert into public.admins (user_id) values (ADMIN_V) on conflict do nothing;

  select category, title, body into cat_kind, cat_title, cat_body
    from public.notification_event_copy('death_process.halted');
  if cat_title is null then
    raise exception 'FAIL[control]: the catalog has no death_process.halted entry';
  end if;

  -- ── THE DECOY: a prior attempt, by a DIFFERENT fiduciary, REJECTED through the real door ───────
  if harness_rs.attempt(EXEC_P, format('select public.initiate_death_verification_case(%L)', V)) <> 'OK' then
    raise exception 'FAIL[precondition]: EXEC_P could not open the decoy case on V';
  end if;
  select id into v_case_p from public.death_verification_cases where estate_id = V and status = 'open';
  v_res := harness_rs.as_admin(ADMIN_V,
    format('select public.admin_decide_death_verification_case(%L, ''reject'')', v_case_p));
  if v_res <> 'OK' then raise exception 'FAIL[precondition]: rejecting the decoy refused: %', v_res; end if;
  if public.estate_lifecycle_state(V) <> 'active' then
    raise exception 'FAIL[precondition]: a rejected case did not return the lifecycle to active';
  end if;
  raise notice '  ok   a prior case exists on V, initiated by a DIFFERENT fiduciary and REJECTED';

  -- ── THE LIVE CASE, WALKED THROUGH EVERY REAL DOOR ──────────────────────────────────────────────
  if harness_rs.attempt(EXEC_V, format('select public.initiate_death_verification_case(%L)', V)) <> 'OK' then
    raise exception 'FAIL[precondition]: EXEC_V could not initiate the live case on V';
  end if;
  select id into v_case_v from public.death_verification_cases where estate_id = V and status = 'open';
  if v_case_v = v_case_p then
    raise exception 'FAIL[precondition]: the live case and the decoy are the same row';
  end if;

  v_res := harness_rs.as_admin(ADMIN_V,
    format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case_v));
  if v_res <> 'OK' then raise exception 'FAIL[precondition]: attained level refused: %', v_res; end if;
  v_res := harness_rs.as_admin(ADMIN_V,
    format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case_v));
  if v_res <> 'OK' then raise exception 'FAIL[precondition]: verify refused: %', v_res; end if;
  v_res := harness_rs.as_admin(ADMIN_V, format('select public.dispatch_owner_safety_notice(%L)', V));
  if v_res <> 'OK' then raise exception 'FAIL[precondition]: dispatch refused: %', v_res; end if;
  v_res := harness_rs.as_admin(ADMIN_V, format('select public.begin_challenge_window(%L)', V));
  if v_res <> 'OK' then raise exception 'FAIL[precondition]: opening the window refused: %', v_res; end if;

  -- ── THE ANCHOR. These four assertions are what make this section a control that CAN fail. ──────
  if public.estate_lifecycle_state(V) <> 'challenge_window' then
    raise exception 'FAIL[anchor]: the lifecycle is %, not challenge_window', public.estate_lifecycle_state(V);
  end if;
  if (select status from public.death_verification_cases where id = v_case_v) <> 'verified' then
    raise exception 'FAIL[anchor]: the live case is %, not verified — this fixture is no longer on '
      'the canonical path', (select status from public.death_verification_cases where id = v_case_v);
  end if;
  -- ★ THE PRE-11-NR PREDICATE MATCHES NOTHING HERE, AND THAT IS ASSERTED RATHER THAN ASSUMED. If a
  -- future edit reintroduces an open case at this point, every assertion below would pass under the
  -- OLD implementation and this section would silently stop testing the widening.
  if exists (select 1 from public.death_verification_cases where estate_id = V and status = 'open') then
    raise exception 'FAIL[anchor]: an OPEN case exists on V at challenge time — the pre-11-NR '
      'predicate (status = ''open'') would match, so this fixture can no longer observe the widening';
  end if;
  if (select status from public.death_verification_cases where id = v_case_p) <> 'rejected' then
    raise exception 'FAIL[anchor]: the decoy is not rejected';
  end if;
  raise notice '  ok   ANCHOR: lifecycle challenge_window · live case VERIFIED · no open case exists';

  -- The verification decision is a recorded fact that the halt must PRESERVE, not erase.
  select decided_by, decided_at into v_decided_by, v_decided_at
    from public.death_verification_cases where id = v_case_v;
  if v_decided_by is null or v_decided_at is null then
    raise exception 'FAIL[precondition]: the verified case carries no decision to preserve';
  end if;

  -- ★ AGED, BECAUSE now() IS TRANSACTION-CONSTANT. Without this, "the halt touched the row" and "the
  -- halt did not touch the decoy" are both trivially true and neither can fail.
  update public.death_verification_cases set updated_at = now() - interval '1 hour'
   where estate_id = V;
  select updated_at into v_aged_v from public.death_verification_cases where id = v_case_v;
  select updated_at into v_aged_p from public.death_verification_cases where id = v_case_p;

  -- ── NEGATIVE CONTROL, BEFORE THE HALT: an unauthorized challenge emits nothing ─────────────────
  select count(*) into n from public.notifications where estate_id = V and kind = 'claimUpdate';
  if n <> 0 then raise exception 'FAIL[precondition]: V already carries a claimUpdate row'; end if;
  v_res := harness_rs.attempt(BEN_V, format('select public.challenge_death_process(%L)', V));
  if v_res <> 'ERR:not_authorized' then
    raise exception 'FAIL: a beneficiary challenge on the canonical path got %', v_res;
  end if;
  if (select count(*) from public.notifications where estate_id = V and kind = 'claimUpdate') <> 0 then
    raise exception 'FAIL: a REFUSED challenge emitted a halt notification';
  end if;
  if (select status from public.death_verification_cases where id = v_case_v) <> 'verified' then
    raise exception 'FAIL: a REFUSED challenge settled the case';
  end if;
  raise notice '  ok   NEGATIVE: an unauthorized challenge settles nothing and emits nothing';

  -- ── THE OWNER CHALLENGES, FROM challenge_window ────────────────────────────────────────────────
  if harness_rs.attempt(OWNER_V, format('select public.challenge_death_process(%L)', V)) <> 'OK' then
    raise exception 'FAIL: the owner could not halt from challenge_window on the canonical path';
  end if;

  if public.estate_lifecycle_state(V) <> 'challenge_halted' then
    raise exception 'FAIL: the canonical-path challenge did not halt the lifecycle';
  end if;
  -- ★ THE ASSERTION THE WHOLE SECTION EXISTS FOR.
  if (select status from public.death_verification_cases where id = v_case_v) <> 'halted' then
    raise exception 'FAIL[11-NR]: the VERIFIED case reads % after an owner challenge, not halted — '
      'the lifecycle says challenge_halted while the case row says otherwise, which is exactly the '
      'divergence the Branch A drill measured in production',
      (select status from public.death_verification_cases where id = v_case_v);
  end if;
  if (select updated_at from public.death_verification_cases where id = v_case_v) <= v_aged_v then
    raise exception 'FAIL[11-NR]: the halt did not touch the live case row (updated_at unmoved)';
  end if;
  raise notice '  ok   the VERIFIED case settles to halted, and the row was actually written';

  -- ── THE DECOY IS UNTOUCHED: the settlement set is closed, not "every row for this estate" ──────
  if (select status from public.death_verification_cases where id = v_case_p) <> 'rejected' then
    raise exception 'FAIL: the halt overwrote a REJECTED historical case — an operator adjudication '
      'that did happen was erased by a settlement predicate that is too wide';
  end if;
  if (select updated_at from public.death_verification_cases where id = v_case_p) <> v_aged_p then
    raise exception 'FAIL: the halt wrote to the rejected historical case row';
  end if;
  -- Exactly ONE row on this estate was settled by this call.
  select count(*) into n from public.death_verification_cases where estate_id = V and status = 'halted';
  if n <> 1 then
    raise exception 'FAIL: % cases on V read halted, expected exactly 1 — more than one row supplied '
      'the recipient and `into` chose between them arbitrarily', n;
  end if;
  raise notice '  ok   exactly ONE case settled; the rejected historical case is byte-unchanged';

  -- ── THE VERIFICATION DECISION SURVIVES THE HALT ────────────────────────────────────────────────
  -- §2 asserts a halted case carries no decision — TRUE for a case halted from `pending`, which was
  -- never decided. On this path the decision is a real recorded fact about an operator's act, and a
  -- halt that erased it would be destroying the case file, not settling it.
  if (select decided_by from public.death_verification_cases where id = v_case_v) is distinct from v_decided_by
     or (select decided_at from public.death_verification_cases where id = v_case_v) is distinct from v_decided_at then
    raise exception 'FAIL: the halt overwrote the verification decision (decided_by / decided_at)';
  end if;
  raise notice '  ok   the operator''s verification decision is preserved, not erased';

  -- ── THE NOTIFICATION: exactly one, to the initiator of the case ACTUALLY SETTLED ───────────────
  select count(*) into n from public.notifications where estate_id = V and kind = 'claimUpdate';
  if n <> 1 then
    raise exception 'FAIL[11-NR]: the canonical-path halt produced % halt notification(s), expected '
      'exactly 1 — this is the artifact Branch A Stage 12 could not observe', n;
  end if;
  select user_id, title, body, action_deep_link
    into row_user, row_title, row_body, row_link
    from public.notifications where estate_id = V and kind = 'claimUpdate';
  if row_user <> EXEC_V then
    raise exception 'FAIL: the halt notification went to the wrong person — expected the initiator '
      'of the SETTLED case, got %', (case when row_user = EXEC_P then 'the initiator of the REJECTED '
      'historical case' else 'someone who initiated nothing here' end);
  end if;
  if row_title is distinct from cat_title or row_body is distinct from cat_body then
    raise exception 'FAIL: the emitted copy differs from the catalog — text was composed at the '
      'emission site';
  end if;
  if row_link is not null then
    raise exception 'FAIL: the halt notification carries a deep link (%)', row_link;
  end if;
  -- No owner-liveness or provenance disclosure, on the path where the owner demonstrably responded.
  if row_body ilike '%@%' or row_body ilike '%email%' or row_body ilike '%owner%'
     or row_body ilike '%alive%' or row_body ilike '%responded%' or row_body ilike '%channel%' then
    raise exception 'FAIL: the halt copy discloses owner liveness or channel: %', row_body;
  end if;
  if row_body like ('%' || V::text || '%') or row_body like ('%' || OWNER_V::text || '%')
     or row_body ilike '%RS Estate V%' then
    raise exception 'FAIL: the halt copy interpolates an identifier or the estate name: %', row_body;
  end if;
  -- The OWNER, who performed the halt, must not receive claimant-facing copy about it; nor may the
  -- decoy's initiator, nor a beneficiary.
  if exists (select 1 from public.notifications where estate_id = V and kind = 'claimUpdate'
              and user_id in (OWNER_V, EXEC_P, BEN_V)) then
    raise exception 'FAIL: the halt notification reached the owner, the decoy initiator or a beneficiary';
  end if;
  raise notice '  ok   ONE notification, to the SETTLED case''s initiator, catalog copy, no deep link';

  -- ── POSITIVE CONTROL: the owner notice from Stage D still exists and still reaches the owner ───
  -- Without this, "the fiduciary got exactly one row" could equally describe a notification layer
  -- that had stopped working for everyone on this estate.
  if (select count(*) from public.notifications
       where estate_id = V and user_id = OWNER_V and title = 'A release process is waiting') <> 1 then
    raise exception 'FAIL[control]: the owner safety notice is missing — the notification layer is '
      'broken on this estate, so the fiduciary assertions above prove nothing';
  end if;
  raise notice '  ok   CONTROL: the owner safety notice still exists (the layer works on V)';

  -- ── STAGE 5 · THE OPERATOR QUEUE, THROUGH THE REAL RPC ─────────────────────────────────────────
  -- ★ THE PREDICATE IS THE PRODUCT'S, NOT A HAND-WRITTEN APPROXIMATION. `p_status` is the filter an
  -- operator actually selects in the console, and the measured Branch A consequence was that a
  -- halted estate's case answered the `verified` filter and was invisible to `halted`.
  q_verified := harness_rs.as_admin_json(ADMIN_V, format(
    'select coalesce(jsonb_agg(jsonb_build_object(''case_id'', q.case_id, ''case_status'', q.case_status, '
    || '''lifecycle_state'', q.lifecycle_state) order by q.case_id), ''[]''::jsonb) '
    || 'from public.admin_list_death_verification_cases(''verified'') q where q.estate_id = %L', V));
  q_halted := harness_rs.as_admin_json(ADMIN_V, format(
    'select coalesce(jsonb_agg(jsonb_build_object(''case_id'', q.case_id, ''case_status'', q.case_status, '
    || '''lifecycle_state'', q.lifecycle_state) order by q.case_id), ''[]''::jsonb) '
    || 'from public.admin_list_death_verification_cases(''halted'') q where q.estate_id = %L', V));

  if jsonb_array_length(q_verified) <> 0 then
    raise exception 'FAIL[queue]: the halted estate''s case is STILL in the operator verified queue: %',
      q_verified;
  end if;
  if jsonb_array_length(q_halted) <> 1 then
    raise exception 'FAIL[queue]: the halted filter returns % row(s) for V, expected 1 — an operator '
      'cannot find the case they just watched stop', jsonb_array_length(q_halted);
  end if;
  if (q_halted -> 0 ->> 'case_id') <> v_case_v::text then
    raise exception 'FAIL[queue]: the halted filter returned the wrong case';
  end if;
  -- ★ THE INVARIANT: the two authorities cannot disagree. The queue projects both, side by side,
  -- which is precisely how the drill saw `case_status: verified` beside `lifecycle_state:
  -- challenge_halted` in one row.
  if (q_halted -> 0 ->> 'case_status') <> 'halted'
     or (q_halted -> 0 ->> 'lifecycle_state') <> 'challenge_halted' then
    raise exception 'FAIL[queue]: case classification and lifecycle disagree in the operator queue: %',
      q_halted;
  end if;
  raise notice '  ok   OPERATOR QUEUE: absent from `verified`, present in `halted`, both authorities agree';

  -- ── IDEMPOTENT REPLAY ON THE CANONICAL PATH ────────────────────────────────────────────────────
  if harness_rs.attempt(OWNER_V, format('select public.challenge_death_process(%L)', V)) <> 'OK' then
    raise exception 'FAIL: the idempotent replay was refused on the canonical path';
  end if;
  if (select count(*) from public.notifications where estate_id = V and kind = 'claimUpdate') <> 1 then
    raise exception 'FAIL: the replay emitted a second halt notification';
  end if;
  if (select status from public.death_verification_cases where id = v_case_v) <> 'halted'
     or (select count(*) from public.death_verification_cases where estate_id = V and status = 'halted') <> 1 then
    raise exception 'FAIL: the replay re-settled or duplicated a halted case';
  end if;
  if public.estate_lifecycle_state(V) <> 'challenge_halted' then
    raise exception 'FAIL: the replay moved the terminal lifecycle state';
  end if;
  raise notice '  ok   replay: no second notification, no re-settlement, terminal state unmoved';

  -- ── NEGATIVE CONTROL: a FOREIGN estate is not settled and its initiator is not told ────────────
  insert into auth.users default values returning id into OWNER_Z;
  insert into public.estates (owner_id, name) values (OWNER_Z, 'RS Estate Z') returning id into Z;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (Z, OWNER_Z, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (Z, EXEC_P, 'executor', 'active');
  if harness_rs.attempt(EXEC_P, format('select public.initiate_death_verification_case(%L)', Z)) <> 'OK' then
    raise exception 'FAIL[precondition]: EXEC_P could not initiate on the foreign estate Z';
  end if;
  if (select status from public.death_verification_cases where estate_id = Z) <> 'open' then
    raise exception 'FAIL: halting V settled a case on an unrelated estate';
  end if;
  if exists (select 1 from public.notifications where estate_id = Z and kind = 'claimUpdate') then
    raise exception 'FAIL: an unrelated estate received a halt notification';
  end if;
  raise notice '  ok   NEGATIVE: the foreign estate Z is unsettled and unnotified';

  -- ── STAGE TOTAL, SCOPED TO THIS SECTION'S ESTATES ──────────────────────────────────────────────
  -- Three halt attempts happened here: BEN_V refused, OWNER_V succeeded, OWNER_V replayed. One row.
  select count(*) into n from public.notifications where kind = 'claimUpdate' and estate_id in (V, Z);
  if n <> 1 then
    raise exception 'FAIL: % claimUpdate rows across this section''s estates, expected exactly 1', n;
  end if;
  raise notice '  ok   exactly 1 halt notification across V and Z (3 halt attempts)';
end $rs8$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 9 · PHASE 11-OBR / OB-1 — AN ABANDONED CLAIM IS RECOVERABLE
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THE DEFECT THIS SECTION EXISTS FOR WAS MEASURED IN PRODUCTION, NOT IMAGINED. The Branch A
-- owner-safety notice was observed at `processing` / `attempts = 1` / `dispatched_at = null` a full
-- day after the drain claimed it. `claim_owner_notices` selected `status = 'queued'` only, so no
-- future drain could ever hand it out again: the owner's one independent warning was lost, and the
-- only remaining transition was a stale sweep that would mark it failed a DAY AFTER the release
-- window it protects had already elapsed.
--
-- ★ THE CRASH-WINDOW TEST IS THE LOAD-BEARING ONE. Everything else here bounds the predicate; the
-- crash-window case reproduces the actual production failure — claim succeeds, worker dies before
-- settling, clock advances — and requires a later drain to recover it. The pre-OB-1 implementation
-- must fail that case, and the `p11obr-*` mutations prove it does.
--
-- ★ CLAIM AGE IS MOVED BY AGEING `claimed_at`, WHICH IS THE DETERMINISTIC EQUIVALENT OF WAITING —
-- the same technique §1 uses to elapse the challenge window. `now()` is transaction-constant, so a
-- test that did not move the clock could not distinguish "inside the timeout" from "outside" it.
--
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- ★ PHASE 11-OC — THIS SECTION DELIBERATELY BUILDS LEGACY-SHAPED ROWS, AND SAYS SO.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- Migration 0058 adds a BEFORE INSERT trigger refusing any owner-notice row with no `case_id`, because
-- from Phase A every real dispatch names its death-verification case. This section is not about
-- episodes: it probes the DRAIN — claim, reclaim, age gate, crash window — with ~10 rows per estate, a
-- shape no single production episode ever has (the partial unique index permits exactly ONE current
-- generation per case).
--
-- These rows are precisely the PRE-PHASE-A class this section was written for: the Branch A forensic
-- row carried no episode either, because the column did not exist. So the fixture builds them the way
-- history produced them, with the wall lifted for this section only.
--
-- ★ THE LIFT AND THE RESTORE ARE TOP-LEVEL STATEMENTS, NOT STATEMENTS INSIDE THE BLOCK, AND THAT IS
-- FORCED RATHER THAN STYLISTIC. `ALTER TABLE … ENABLE TRIGGER` cannot run while the transaction holds
-- pending deferred-constraint events, and §9 creates rows under a DEFERRABLE FK — so a restore inside
-- the DO block fails with "cannot ALTER TABLE … because it has pending trigger events". At top level
-- each statement is its own transaction and there is nothing pending. Measured, not guessed.
alter table public.owner_notice_outbox disable trigger owner_notice_outbox_require_episode;

do $rs9$
declare
  OWNER_W uuid; W uuid; ADMIN_W uuid; OTHER_W uuid; X2 uuid;
  v_id uuid; v_other uuid;
  n int; v_claimed_before timestamptz; v_claimed_after timestamptz; v_attempts int;
  TIMEOUT constant interval := interval '1 hour';   -- mirrors c_claim_visibility
begin
  raise notice ' ';
  raise notice '9 · OB-1: an abandoned claim is recoverable (Phase 11-OBR)';

  insert into auth.users default values returning id into OWNER_W;
  insert into auth.users default values returning id into OTHER_W;
  insert into auth.users default values returning id into ADMIN_W;
  update auth.users set email = 'rs-owner-w@example.invalid' where id = OWNER_W;
  insert into public.estates (owner_id, name) values (OWNER_W, 'RS Estate W2') returning id into W;
  insert into public.estates (owner_id, name) values (OTHER_W, 'RS Estate X2') returning id into X2;
  insert into public.admins (user_id) values (ADMIN_W) on conflict do nothing;

  -- ── CONTROL: the column the whole fix rests on must exist, or every assertion below is vacuous ──
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'owner_notice_outbox' and column_name = 'claimed_at'
  ) then
    raise exception 'FAIL[control]: owner_notice_outbox.claimed_at does not exist — migration 0057 '
      'did not load, and nothing below tests the reclaim contract';
  end if;
  raise notice '  ok   CONTROL: claimed_at exists';

  -- A helper row per case. `recipient` is required by the claim projection.
  create temporary table rs9_case (label text primary key, id uuid) on commit drop;

  -- ── 1 · A QUEUED ROW IS CLAIMED (the positive control the whole section needs) ─────────────────
  insert into public.owner_notice_outbox (estate_id, user_id, channel, recipient, notice_kind, status)
  values (W, OWNER_W, 'email', 'rs-w@example.invalid', 'death_process.window_opened', 'queued')
  returning id into v_id;
  select count(*) into n from public.claim_owner_notices(25) c where c.id = v_id;
  if n <> 1 then
    raise exception 'FAIL[control]: a QUEUED row was not claimed — the instrument claims nothing and '
      'every "not reclaimed" assertion below would pass vacuously';
  end if;
  select claimed_at, attempts into v_claimed_before, v_attempts
    from public.owner_notice_outbox where id = v_id;
  if v_claimed_before is null then
    raise exception 'FAIL: the claim did not stamp claimed_at — no timeout can ever be computed';
  end if;
  if v_attempts <> 1 then
    raise exception 'FAIL: the first claim set attempts to %, expected 1', v_attempts;
  end if;
  raise notice '  ok   1 · a queued row is claimed, claimed_at stamped, attempts = 1';

  -- ── 2 · A FRESHLY PROCESSING ROW IS NOT RECLAIMED ─────────────────────────────────────────────
  -- The row above is now `processing` with claimed_at = now(). A live worker still holds it.
  select count(*) into n from public.claim_owner_notices(25) c where c.id = v_id;
  if n <> 0 then
    raise exception 'FAIL: a row claimed moments ago was reclaimed — a live worker would be sending '
      'the same notice twice';
  end if;
  raise notice '  ok   2 · a freshly claimed row is NOT reclaimed';

  -- ── 3 · JUST INSIDE THE TIMEOUT IS NOT RECLAIMED ──────────────────────────────────────────────
  update public.owner_notice_outbox set claimed_at = now() - (TIMEOUT - interval '1 minute')
   where id = v_id;
  select count(*) into n from public.claim_owner_notices(25) c where c.id = v_id;
  if n <> 0 then
    raise exception 'FAIL: a claim 59 minutes old was reclaimed — the timeout is shorter than declared';
  end if;
  raise notice '  ok   3 · a claim just INSIDE the timeout is NOT reclaimed';

  -- ── 4 · THE BOUNDARY IS STRICT, AND THAT IS ASSERTED RATHER THAN ASSUMED ──────────────────────
  -- The predicate is `claimed_at < now() - timeout`. At EXACTLY the boundary it is false, so the row
  -- is not reclaimed. Ties go to the worker that already holds the claim — the same direction the
  -- release guard resolves its tie, where the owner keeps the benefit of the doubt.
  update public.owner_notice_outbox set claimed_at = now() - TIMEOUT where id = v_id;
  select count(*) into n from public.claim_owner_notices(25) c where c.id = v_id;
  if n <> 0 then
    raise exception 'FAIL: a claim EXACTLY at the boundary was reclaimed — the comparison is '
      'inclusive where the contract says strict';
  end if;
  raise notice '  ok   4 · the boundary is STRICT: exactly-at-timeout is NOT reclaimed';

  -- ── 5/6/7 · PAST THE TIMEOUT IT IS RECLAIMED, attempts INCREMENTS, claimed_at REFRESHES ───────
  update public.owner_notice_outbox set claimed_at = now() - (TIMEOUT + interval '1 minute')
   where id = v_id;
  select claimed_at into v_claimed_before from public.owner_notice_outbox where id = v_id;
  select count(*) into n from public.claim_owner_notices(25) c where c.id = v_id;
  if n <> 1 then
    raise exception 'FAIL[OB-1]: an abandoned claim past the visibility timeout was NOT reclaimed — '
      'this is the production defect, unfixed';
  end if;
  select claimed_at, attempts into v_claimed_after, v_attempts
    from public.owner_notice_outbox where id = v_id;
  if v_attempts <> 2 then
    raise exception 'FAIL: reclaim left attempts at %, expected 2 — an unbounded reclaim loop would '
      'never reach the retry cap', v_attempts;
  end if;
  if v_claimed_after <= v_claimed_before then
    raise exception 'FAIL: reclaim did not refresh claimed_at — the row is instantly reclaimable '
      'again and two concurrent drains would both take it';
  end if;
  raise notice '  ok   5/6/7 · past the timeout it IS reclaimed; attempts=2; claimed_at refreshed';

  -- ── 14 · A LEGACY `processing` ROW WITH claimed_at NULL IS RECLAIMABLE ────────────────────────
  -- This is the class the Branch A forensic row belongs to: claimed before the column existed. It is
  -- handled as a CLASS, never by id.
  insert into public.owner_notice_outbox (estate_id, user_id, channel, recipient, notice_kind, status, attempts)
  values (W, OWNER_W, 'email', 'rs-w2@example.invalid', 'death_process.window_opened', 'processing', 1)
  returning id into v_other;
  update public.owner_notice_outbox set claimed_at = null where id = v_other;
  select count(*) into n from public.claim_owner_notices(25) c where c.id = v_other;
  if n <> 1 then
    raise exception 'FAIL[OB-1]: a legacy processing row with claimed_at NULL was not reclaimed — '
      'the rows the defect already stranded stay stranded after deployment';
  end if;
  raise notice '  ok   14 · a legacy processing row (claimed_at NULL) IS reclaimed';

  -- ── 10/11/12 · SETTLED STATES ARE NEVER RECLAIMED, EACH ASSERTED BY NAME ──────────────────────
  -- Named individually rather than swept up by a `status <> terminal` test: two of these are terminal
  -- precisely because the message may already be in the owner's inbox.
  for n in 1..1 loop end loop;
  declare
    st text;
    v_settled uuid;
  begin
    foreach st in array array['dispatched', 'outcomeUncertain', 'failedPermanent', 'cancelled'] loop
      insert into public.owner_notice_outbox
        (estate_id, user_id, channel, recipient, notice_kind, status, claimed_at)
      values (W, OWNER_W, 'email', 'rs-w3@example.invalid', 'death_process.window_opened', st,
              now() - interval '30 days')
      returning id into v_settled;
      if exists (select 1 from public.claim_owner_notices(25) c where c.id = v_settled) then
        raise exception 'FAIL: a % row was reclaimed — a settled notice must never be re-sent', st;
      end if;
    end loop;
  end;
  raise notice '  ok   10/11/12 · dispatched / outcomeUncertain / failedPermanent / cancelled never reclaimed';

  -- ── 9 · THE AGE GATE STILL WINS OVER THE RECLAIM ──────────────────────────────────────────────
  -- A processing row that is BOTH abandoned and beyond the age gate must settle as stale, not be
  -- re-sent. The sweep runs first inside the routine, and this proves the order still holds.
  insert into public.owner_notice_outbox
    (estate_id, user_id, channel, recipient, notice_kind, status, claimed_at, requested_at)
  values (W, OWNER_W, 'email', 'rs-w4@example.invalid', 'death_process.window_opened', 'processing',
          now() - interval '30 days', now() - interval '30 days')
  returning id into v_other;
  if exists (select 1 from public.claim_owner_notices(25) c where c.id = v_other) then
    raise exception 'FAIL: a notice beyond the age gate was RECLAIMED and re-sent instead of being '
      'settled stale — the reclaim overtook the age gate';
  end if;
  if (select status from public.owner_notice_outbox where id = v_other) <> 'failedPermanent'
     or (select failure_class from public.owner_notice_outbox where id = v_other) <> 'stale_beyond_age_gate' then
    raise exception 'FAIL: the stale sweep no longer settles an abandoned over-age notice';
  end if;
  raise notice '  ok   9 · the age gate still beats the reclaim (stale, not re-sent)';

  -- ── 13 · AN UNRELATED ESTATE'S ROW IS UNTOUCHED ───────────────────────────────────────────────
  insert into public.owner_notice_outbox (estate_id, user_id, channel, recipient, notice_kind, status, claimed_at)
  values (X2, OTHER_W, 'email', 'rs-x2@example.invalid', 'death_process.window_opened', 'processing',
          now() - interval '10 minutes')
  returning id into v_other;
  perform public.claim_owner_notices(25);
  if (select status from public.owner_notice_outbox where id = v_other) <> 'processing'
     or (select attempts from public.owner_notice_outbox where id = v_other) <> 0 then
    raise exception 'FAIL: an unrelated estate''s freshly claimed row was disturbed';
  end if;
  raise notice '  ok   13 · an unrelated estate''s in-flight row is untouched';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ 6 · THE CRASH WINDOW — the exact production failure, reproduced end to end.
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- dispatch → claim → worker dies before recordOutcome → clock advances → a later drain recovers it.
  -- This is the case the pre-OB-1 implementation cannot pass, and it is what `p11obr-reclaim-removed`
  -- must be killed by.
  declare
    CRASH uuid;
    v_before text;
  begin
    insert into public.owner_notice_outbox (estate_id, user_id, channel, recipient, notice_kind, status)
    values (W, OWNER_W, 'email', 'rs-crash@example.invalid', 'death_process.window_opened', 'queued')
    returning id into CRASH;

    -- The drain claims it...
    if not exists (select 1 from public.claim_owner_notices(25) c where c.id = CRASH) then
      raise exception 'FAIL[crash precondition]: the notice was not claimed in the first place';
    end if;
    -- ...and the worker dies here. record_owner_notice_outcome is never called. Nothing else runs.
    select status into v_before from public.owner_notice_outbox where id = CRASH;
    if v_before <> 'processing' then
      raise exception 'FAIL[crash precondition]: the abandoned row reads %, expected processing', v_before;
    end if;

    -- A later drain, before the timeout: still nobody else's to take.
    if exists (select 1 from public.claim_owner_notices(25) c where c.id = CRASH) then
      raise exception 'FAIL: the abandoned row was reclaimed before the visibility timeout elapsed';
    end if;

    -- Time passes (deterministically).
    update public.owner_notice_outbox set claimed_at = now() - (TIMEOUT + interval '5 minutes')
     where id = CRASH;

    if not exists (select 1 from public.claim_owner_notices(25) c where c.id = CRASH) then
      raise exception 'FAIL[OB-1 CRASH WINDOW]: a notice abandoned by a dead worker was never handed '
        'to another one. This is the measured Branch A defect: the owner is never warned and nothing '
        'reports it.';
    end if;
    -- And it can now be settled normally, which is what makes the recovery complete rather than a
    -- second strand.
    if public.record_owner_notice_outcome(CRASH, 'providerAccepted') <> 'dispatched' then
      raise exception 'FAIL: the reclaimed notice could not be settled';
    end if;
    raise notice '  ok   6 · CRASH WINDOW: abandoned claim recovered by a later drain and settled';

    -- ══════════════════════════════════════════════════════════════════════════════════════════
    -- ★ OB-4 — THE SETTLE PATH MUST BE ABLE TO WRITE ITS OWN AUDIT ROW.
    -- ══════════════════════════════════════════════════════════════════════════════════════════
    --
    -- This is the ROOT CAUSE of the observed Branch A strand, and it is asserted here because the
    -- settle above would otherwise "pass" for the wrong reason if the audit insert were ever made
    -- conditional or swallowed inside the routine.
    --
    -- `record_owner_notice_outcome` closes by writing `source = 'worker'`.
    -- `audit_logs_source_check` admitted only ('server','ios_forward','admin') from migration 0014
    -- until 0057, so that insert raised `check_violation` on EVERY call — and the drain's
    -- `recordOutcome` catches the RPC error and only logs it. Every claimed notice therefore
    -- stranded in `processing`, which is exactly the state the Branch A row was found in.
    --
    -- The settle is asserted by its AUDIT ROW, not by the returned status: a future edit that made
    -- the audit best-effort would restore the silence this defect lived in.
    if not exists (
      select 1 from public.audit_logs
       where target_table = 'owner_notice_outbox' and target_id = CRASH
         and action = 'death_process.owner_notice_outcome' and source = 'worker'
    ) then
      raise exception 'FAIL[OB-4]: settling a notice wrote no worker-sourced audit row — either the '
        'audit source vocabulary still refuses ''worker'' (the production defect) or the settle '
        'stopped auditing, and a lost owner notice becomes unattributable';
    end if;
    -- The actor is a scheduled worker, not a person: NULL actor_id is the contract, not an omission.
    if exists (
      select 1 from public.audit_logs
       where target_id = CRASH and action = 'death_process.owner_notice_outcome'
         and actor_id is not null
    ) then
      raise exception 'FAIL: the worker audit invented a synthetic operator identity';
    end if;
    raise notice '  ok   OB-4 · the settle writes a worker-sourced audit row (actor NULL)';
  end;

  -- ── 10 (STAGE) · THE CENSUS CAN SEE A STUCK CLAIM ─────────────────────────────────────────────
  --
  -- ★ ASSERTED AGAINST A DELIBERATELY STALE FIXTURE, NEVER AGAINST ZERO. A census that reports
  -- `processing_stale: 0` on a database with nothing stuck is indistinguishable from one that cannot
  -- count at all — and "nothing is stuck" is precisely the false reassurance this defect hid behind
  -- for a day. So the fixture creates one abandoned claim and one live one, and the census must
  -- separate them.
  declare
    v_census jsonb;
    STALE uuid; LIVE uuid;
  begin
    insert into public.owner_notice_outbox
      (estate_id, user_id, channel, recipient, notice_kind, status, claimed_at)
    values (W, OWNER_W, 'email', 'rs-stale@example.invalid', 'death_process.window_opened',
            'processing', now() - interval '6 hours')
    returning id into STALE;
    insert into public.owner_notice_outbox
      (estate_id, user_id, channel, recipient, notice_kind, status, claimed_at)
    values (W, OWNER_W, 'email', 'rs-live@example.invalid', 'death_process.window_opened',
            'processing', now())
    returning id into LIVE;

    v_census := harness_rs.as_admin_json(ADMIN_W, 'select public.owner_notice_census()');

    if (v_census ->> 'processing_total')::int < 2 then
      raise exception 'FAIL[census]: processing_total is %, expected at least the 2 rows just '
        'created — the census cannot see in-flight work at all', v_census ->> 'processing_total';
    end if;
    if (v_census ->> 'processing_stale')::int < 1 then
      raise exception 'FAIL[census]: processing_stale is %, but a claim 6 hours old exists — an '
        'abandoned owner notice is invisible to the only surface that could report it',
        v_census ->> 'processing_stale';
    end if;
    -- ★ THE DISCRIMINATION CONTROL: stale must be STRICTLY FEWER than total, or the key is just
    -- counting `processing` under another name and would "detect" a healthy queue as stuck.
    if (v_census ->> 'processing_stale')::int >= (v_census ->> 'processing_total')::int then
      raise exception 'FAIL[census]: processing_stale (%) is not fewer than processing_total (%) — '
        'the live claim was counted as stale, so the key does not discriminate',
        v_census ->> 'processing_stale', v_census ->> 'processing_total';
    end if;
    if v_census ->> 'oldest_processing_age' is null then
      raise exception 'FAIL[census]: oldest_processing_age is null while rows are processing';
    end if;
    -- Counts and ages only: no address may appear anywhere in the projection.
    if v_census::text ilike '%@%' then
      raise exception 'FAIL[census]: the census projection contains an address shape';
    end if;
    raise notice '  ok   10 · census separates stale claims from live ones, and discloses no address';
  end;

  -- ── 8 · CONCURRENCY, TO THE EXTENT ONE SESSION CAN OBSERVE IT ─────────────────────────────────
  -- ★ STATED HONESTLY: `for update skip locked` is what stops two SIMULTANEOUS drains taking one row,
  -- and a single psql session cannot hold two concurrent transactions to prove it. What IS provable
  -- here is the property that makes the race rare rather than routine — a claim refreshes claimed_at,
  -- so a second drain arriving immediately after finds nothing eligible. Case 2 above is that proof.
  -- The `skip locked` clause itself is asserted structurally by the deployment verifiers.
  raise notice '  ok   8 · re-claim is not immediately repeatable (skip-locked itself: see verifiers)';

end $rs9$;

-- ── 15 · PHASE 11-OC · THE EPISODE WALL IS RESTORED, PROVED BY EXECUTION ────────────────────────
--
-- ★ ASSERTED BY TRYING AN INSERT, NOT BY HAVING WRITTEN `enable trigger`. A statement that ran is not
-- the same claim as a wall that holds: the trigger could have been dropped by a later artifact, or
-- `enable` could have been applied to a trigger that no longer exists. §9 lifted the wall, so §9 must
-- prove it put it back — every assertion in every LATER file depends on that being true, and a test
-- that silently left a production wall down would be a worse defect than the one §9 tests.
alter table public.owner_notice_outbox enable trigger owner_notice_outbox_require_episode;

do $rs9w$
declare
  v_estate uuid;
  v_user   uuid;
  v_holds  boolean;
begin
  select e.id, e.owner_id into v_estate, v_user from public.estates e
   where e.name = 'RS Estate W2' limit 1;
  if v_estate is null then
    raise exception 'FAIL[control]: §9''s estate is gone, so the wall-restore check would assert '
      'nothing at all';
  end if;

  begin
    insert into public.owner_notice_outbox (estate_id, user_id, channel, recipient, notice_kind, status)
    values (v_estate, v_user, 'email', 'rs-w-wall@example.invalid',
            'death_process.window_opened', 'queued');
    v_holds := false; -- reached: the wall is NOT back
  exception when others then
    v_holds := true;
  end;
  if not v_holds then
    delete from public.owner_notice_outbox where recipient = 'rs-w-wall@example.invalid';
    raise exception 'FAIL[OC]: the episode wall was NOT restored after §9 lifted it. Every later '
      'section runs unprotected, and a notice could be written with no episode';
  end if;
  raise notice '  ok   15 · the episode wall is restored (a NULL-case_id insert is refused again)';
end $rs9w$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 10 · PHASE 11-OC / PHASE A — ACCEPTANCE IS A FACT, AND A NOTICE BELONGS TO AN EPISODE
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THIS SECTION EXISTS BECAUSE MIGRATION 0058'S OWN SELF-CHECKS ARE SKIPPED IN THE REPLAY, AND IT
-- SAYS SO OUT LOUD. The Phase A bundle loads before any test file creates an estate, so 0058 reports
-- "no estates in this database — the execution controls in 5.3/5.4 are SKIPPED" and its census prints
-- zeroes. That is honest of 0058 and it is NOT coverage: a 0/0 census and a broken census are
-- indistinguishable from the outside. Everything 0058 could only skip is proved HERE, against
-- furnished NON-ZERO fixtures.
--
-- ★ AND THE CENSUS CONTROLS RUN IN BOTH DIRECTIONS, DELIBERATELY. It is not enough to prove the
-- readiness census can report an estate as REFUSED — a census hard-wired to refuse everything would
-- pass that and would read as conservative. So the fixture furnishes one estate Phase D would ADMIT
-- and one it would REFUSE, and both are asserted. A one-directional census is not an instrument.
do $rs10$
declare
  OWNER_Y uuid; EXEC_Y uuid; ADMIN_Y uuid; Y uuid;
  OWNER_Z uuid; EXEC_Z uuid; Z uuid;
  v_case_y uuid; v_case_z uuid;
  v_row_y uuid; v_row_z uuid;
  v_res text; n int; v_census jsonb; v_ready jsonb;
  v_acc timestamptz; v_disp timestamptz; v_status text; v_gen int; v_cid uuid;
  v_succ uuid;
  v_sum bigint;
begin
  raise notice ' ';
  raise notice '10 · Phase 11-OC / Phase A: the acceptance fact and the case episode';

  -- ── FIXTURE Y — the estate Phase D would ADMIT: a genuinely accepted notice ────────────────────
  insert into auth.users default values returning id into OWNER_Y;
  insert into auth.users default values returning id into EXEC_Y;
  insert into auth.users default values returning id into ADMIN_Y;
  insert into public.admins (user_id) values (ADMIN_Y) on conflict do nothing;
  update auth.users set email = 'rs-owner-y@example.invalid' where id = OWNER_Y;
  insert into public.estates (owner_id, name) values (OWNER_Y, 'RS Estate Y-OC') returning id into Y;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (Y, OWNER_Y, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (Y, EXEC_Y, 'executor', 'active');

  perform harness_rs.attempt(EXEC_Y, format('select public.initiate_death_verification_case(%L)', Y));
  select id into v_case_y from public.death_verification_cases where estate_id = Y and status = 'open';
  perform harness_rs.as_admin(ADMIN_Y,
    format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case_y));
  perform harness_rs.as_admin(ADMIN_Y,
    format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case_y));
  v_res := harness_rs.as_admin(ADMIN_Y, format('select public.dispatch_owner_safety_notice(%L)', Y));
  if v_res <> 'OK' then
    raise exception 'FAIL[precondition]: dispatch for estate Y refused: %', v_res;
  end if;

  -- ── 1 · THE DISPATCH NAMED ITS EPISODE ────────────────────────────────────────────────────────
  --
  -- `v_case` was already in hand inside dispatch_owner_safety_notice and, before Phase A, was
  -- discarded into the audit metadata only. The release predicate needs it ON THE ROW.
  select o.id, o.case_id, o.generation into v_row_y, v_cid, v_gen
    from public.owner_notice_outbox o where o.estate_id = Y;
  if v_cid is null then
    raise exception 'FAIL[OC]: dispatch wrote an owner-notice row with NO case_id — the release '
      'predicate has no episode key and an accepted notice from a prior rejected case could '
      'authorize a later one';
  end if;
  if v_cid <> v_case_y then
    raise exception 'FAIL[OC]: the notice names case % but the verified case is %', v_cid, v_case_y;
  end if;
  if v_gen <> 1 then
    raise exception 'FAIL[OC]: an original dispatch created generation %, expected 1', v_gen;
  end if;
  raise notice '  ok   1 · dispatch stamps the CURRENT case as the episode key, at generation 1';

  -- ── 2 · providerAccepted STAMPS ACCEPTANCE, IN THE SAME STATEMENT AS THE STATUS ────────────────
  --
  -- ★ PROVED BY EQUALITY, NOT BY BOTH BEING NON-NULL. `now()` is transaction-constant, so if the two
  -- columns are written by ONE statement they are byte-identical. Two statements in one transaction
  -- would also match, so this is necessary rather than sufficient — but a LATER separate write (the
  -- shape that would make `dispatched` + NULL acceptance reachable again) cannot produce equality
  -- with the status transition it is supposed to accompany. This is the invariant that makes the
  -- legacy `dispatched`+NULL shape structurally unreachable after Phase A.
  perform public.claim_owner_notices(25);
  perform public.record_owner_notice_outcome(v_row_y, 'providerAccepted');
  select status, dispatched_at, notice_accepted_at into v_status, v_disp, v_acc
    from public.owner_notice_outbox where id = v_row_y;
  if v_status <> 'dispatched' then
    raise exception 'FAIL[OC]: providerAccepted left status at %', v_status;
  end if;
  if v_acc is null then
    raise exception 'FAIL[OC]: providerAccepted did NOT stamp notice_accepted_at — the one fact Phase '
      'D makes release-authoritative is never written, so no estate could ever release';
  end if;
  if v_acc <> v_disp then
    raise exception 'FAIL[OC]: notice_accepted_at (%) and dispatched_at (%) differ, so they were not '
      'written by one statement — `dispatched` with NULL acceptance is reachable again', v_acc, v_disp;
  end if;
  -- ★ AND THE STAMP IS KEYED ON THE OUTCOME, NOT ON THE STATUS — asserted on the DEPLOYED body,
  -- because no behavioural fixture can see the difference today. `providerAccepted` is currently the
  -- only branch that yields `dispatched`, so keying on either produces identical results and the
  -- re-keying reads as harmless tidying. It is not: keying on `v_status` re-couples the acceptance fact
  -- to the status vocabulary, so the first future branch that reaches `dispatched` by another route
  -- inherits an acceptance nobody established — the exact "a new status silently becomes release-
  -- qualifying" class this design exists to eliminate. Same technique 0056/0057/0058 use on
  -- authorize_release, and legitimate for the same reason: the KEYING is the invariant.
  if (select prosrc from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
       where nsp.nspname = 'public' and p.proname = 'record_owner_notice_outcome')
     not like '%notice_accepted_at = case when p_outcome = ''providerAccepted''%' then
    raise exception 'FAIL[OC/D2]: the acceptance stamp is no longer keyed on p_outcome = '
      '''providerAccepted''. If it now keys on a STATUS, any future branch reaching `dispatched` '
      'inherits an acceptance fact no provider ever established.';
  end if;
  raise notice '  ok   2 · providerAccepted stamps acceptance in ONE statement with the status, '
    'keyed on the OUTCOME (asserted on the deployed body)';

  -- ── 3 · EVERY OTHER OUTCOME LEAVES ACCEPTANCE NULL (D2) ───────────────────────────────────────
  --
  -- Asserted per outcome, by name. An unknown or failed provider answer must NEVER be recorded as an
  -- acceptance — that is the entire reason this is a stamped fact rather than a status list, and the
  -- reason `outcomeUncertain` cannot authorize a release.
  --
  -- Each probe needs its own CURRENT generation, so each is written as a real supersession pair. That
  -- exercises the deferred-FK ordering as a side effect, on the path a re-notice will actually use.
  declare
    v_prev uuid := v_row_y;
    v_outcome text;
    v_probe uuid;
  begin
    foreach v_outcome in array array['outcomeUncertain', 'failedPermanent', 'retryPending'] loop
      v_succ := gen_random_uuid();
      update public.owner_notice_outbox set superseded_by = v_succ where id = v_prev;
      insert into public.owner_notice_outbox
        (id, estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
         reissue_reason)
      values (v_succ, Y, OWNER_Y, 'email', 'rs-owner-y@example.invalid',
              'death_process.window_opened', 'queued', v_case_y,
              (select generation + 1 from public.owner_notice_outbox where id = v_prev),
              'prior_outcome_uncertain');
      v_probe := v_succ;
      perform public.record_owner_notice_outcome(v_probe, v_outcome, 'probe');
      select notice_accepted_at into v_acc from public.owner_notice_outbox where id = v_probe;
      if v_acc is not null then
        raise exception 'FAIL[OC/D2]: outcome % stamped notice_accepted_at (%) — an unknown or '
          'failed provider answer has been recorded as an acceptance', v_outcome, v_acc;
      end if;
      v_prev := v_probe;
    end loop;
  end;
  raise notice '  ok   3 · outcomeUncertain / failedPermanent / retryPending each leave acceptance NULL';

  -- ── 4 · THE EPISODE HAS EXACTLY ONE CURRENT GENERATION ────────────────────────────────────────
  select count(*) into n from public.owner_notice_outbox
   where case_id = v_case_y and superseded_by is null;
  if n <> 1 then
    raise exception 'FAIL[OC/D12]: the episode has % current generations, expected exactly 1 — the '
      'active generation is not structurally identified and the door would need a max()', n;
  end if;
  select count(*) into n from public.owner_notice_outbox where case_id = v_case_y;
  if n < 4 then
    raise exception 'FAIL[control]: the episode holds only % rows; the supersession fixture did not '
      'build a chain and §10.4 proved nothing', n;
  end if;
  -- ★ AND THE INVARIANT IS ENFORCED BY THE DATABASE, NOT MERELY SATISFIED BY THIS FIXTURE.
  --
  -- Counting the current generations proves the fixture is well-formed; it does NOT prove a second one
  -- would be refused. Those are different claims, and only the second is the invariant Phase D depends
  -- on — without it the door would have to trust a max() the writer promises to maintain, and a
  -- concurrent double-reissue would produce two rows that both believe they are current.
  --
  -- Proven by ATTEMPTING the violation. Migration 0058 carries this control too, but on the replay
  -- database it is SKIPPED (no estates exist when the bundle loads), so this is the only place it
  -- actually executes. Mutation `p11oc-one-current-generation-not-enforced` was NOT_DETECTED until
  -- this assertion existed.
  declare
    v_dup_refused boolean;
  begin
    begin
      insert into public.owner_notice_outbox
        (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
         reissue_reason)
      values (Y, OWNER_Y, 'email', 'rs-owner-y@example.invalid', 'death_process.window_opened',
              'queued', v_case_y, 9, 'prior_failed_permanent');
      v_dup_refused := false; -- reached: a second CURRENT generation was accepted
    exception when unique_violation then
      v_dup_refused := true;
    end;
    if not v_dup_refused then
      raise exception 'FAIL[OC/D12]: a SECOND current generation was accepted for one case — the '
        'active generation is not structurally identified, so the release door would depend on a '
        'max() rather than on a wall, and a concurrent double-reissue produces two live notices';
    end if;
  end;
  raise notice '  ok   4 · a 4-generation episode has exactly ONE current generation, and a second '
    'is REFUSED by the database (proved by execution)';

  -- Y reaches the door with a real acceptance on record (generation 1, which MIN correctly anchors).
  v_res := harness_rs.as_admin(ADMIN_Y, format('select public.begin_challenge_window(%L)', Y));
  if v_res <> 'OK' then
    raise exception 'FAIL[precondition]: begin_challenge_window for Y refused: %', v_res;
  end if;

  -- ── FIXTURE Z — the estate Phase D would REFUSE: dispatched, never accepted ───────────────────
  insert into auth.users default values returning id into OWNER_Z;
  insert into auth.users default values returning id into EXEC_Z;
  update auth.users set email = 'rs-owner-z@example.invalid' where id = OWNER_Z;
  insert into public.estates (owner_id, name) values (OWNER_Z, 'RS Estate Z-OC') returning id into Z;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (Z, OWNER_Z, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (Z, EXEC_Z, 'executor', 'active');
  perform harness_rs.attempt(EXEC_Z, format('select public.initiate_death_verification_case(%L)', Z));
  select id into v_case_z from public.death_verification_cases where estate_id = Z and status = 'open';
  perform harness_rs.as_admin(ADMIN_Y,
    format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case_z));
  perform harness_rs.as_admin(ADMIN_Y,
    format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case_z));
  perform harness_rs.as_admin(ADMIN_Y, format('select public.dispatch_owner_safety_notice(%L)', Z));
  select o.id into v_row_z from public.owner_notice_outbox o where o.estate_id = Z;
  -- Settled as UNCERTAIN: the provider never confirmed. This is the D11 population — unknown, not
  -- accepted, not failed — and the one the old `status <> 'cancelled'` predicate silently admitted.
  perform public.claim_owner_notices(25);
  perform public.record_owner_notice_outcome(v_row_z, 'outcomeUncertain');
  perform harness_rs.as_admin(ADMIN_Y, format('select public.begin_challenge_window(%L)', Z));

  -- ── 5 · THE ROW CENSUS, AGAINST NON-ZERO DATA, WITH RECONCILIATION ────────────────────────────
  v_census := harness_rs.as_admin_json(ADMIN_Y, 'select public.owner_notice_census()');
  if (v_census ->> 'total')::bigint = 0 then
    raise exception 'FAIL[control]: the census total is 0, so every split below reconciles vacuously';
  end if;
  if (v_census ->> 'accepted_total')::bigint < 1 then
    raise exception 'FAIL[control]: accepted_total is 0 although estate Y has a stamped acceptance — '
      'the census cannot see the one fact Phase D turns on';
  end if;
  -- ★ NO NAMELESS GAP: the acceptance split must partition the total exactly.
  if (v_census ->> 'accepted_total')::bigint + (v_census ->> 'unaccepted_total')::bigint
     <> (v_census ->> 'total')::bigint then
    raise exception 'FAIL[census]: accepted(%) + unaccepted(%) <> total(%) — a row belongs to no '
      'named split and an operator reconciling them would find a gap with no name',
      v_census ->> 'accepted_total', v_census ->> 'unaccepted_total', v_census ->> 'total';
  end if;
  -- The generation histogram must also partition the total.
  select sum(value::bigint) into v_sum
    from jsonb_each_text(v_census -> 'by_generation');
  if v_sum <> (v_census ->> 'total')::bigint then
    raise exception 'FAIL[census]: by_generation sums to % but total is %', v_sum,
      v_census ->> 'total';
  end if;
  if (v_census ->> 'superseded_total')::bigint + (v_census ->> 'current_total')::bigint
     <> (v_census ->> 'total')::bigint then
    raise exception 'FAIL[census]: superseded + current <> total';
  end if;
  if v_census::text ilike '%@%' then
    raise exception 'FAIL[census]: the row census projection contains an address shape';
  end if;
  raise notice '  ok   5 · row census: non-zero, every split partitions the total, no address';

  -- ── 6 · THE READINESS CENSUS — BOTH DIRECTIONS, WHICH IS THE WHOLE POINT ──────────────────────
  v_ready := harness_rs.as_admin_json(ADMIN_Y,
    'select public.owner_notice_release_readiness_census()');
  if (v_ready ->> 'estates_at_door')::bigint < 2 then
    raise exception 'FAIL[control]: only % estate(s) at the door, but the fixture put Y and Z there — '
      'the readiness census cannot see the population it exists to measure',
      v_ready ->> 'estates_at_door';
  end if;
  -- POSITIVE CONTROL, DIRECTION 1: it can say ADMIT. Without this a census wired to refuse
  -- everything would satisfy direction 2 and read as safely conservative.
  if (v_ready ->> 'would_be_admitted_by_phase_d')::bigint < 1 then
    raise exception 'FAIL[control]: the readiness census admits NOBODY although estate Y has a real '
      'provider acceptance — it is refusing everything and direction 2 proves nothing';
  end if;
  -- POSITIVE CONTROL, DIRECTION 2: it can say REFUSE — and estate Z, whose provider outcome is
  -- UNKNOWN, must be in that class (D11).
  if (v_ready ->> 'would_be_refused_by_phase_d')::bigint < 1 then
    raise exception 'FAIL[OC/D11]: the readiness census refuses NOBODY although estate Z settled '
      'outcomeUncertain — an unknown provider outcome is being treated as an acceptance';
  end if;
  if (v_ready ->> 'would_be_admitted_by_phase_d')::bigint
     + (v_ready ->> 'would_be_refused_by_phase_d')::bigint
     <> (v_ready ->> 'estates_at_door')::bigint then
    raise exception 'FAIL[census]: admitted + refused <> estates_at_door';
  end if;
  -- Every estate lands in a NAMED bucket, and the buckets partition the total.
  select sum(value::bigint) into v_sum from jsonb_each_text(v_ready -> 'by_readiness');
  if v_sum <> (v_ready ->> 'estates_at_door')::bigint then
    raise exception 'FAIL[census]: by_readiness sums to % but estates_at_door is % — an estate fell '
      'through the classification', v_sum, v_ready ->> 'estates_at_door';
  end if;
  if (v_ready -> 'by_readiness') ? 'unclassified' then
    raise exception 'FAIL[census]: an estate classified as `unclassified` — a status outside the six '
      'reached the door and the bucket vocabulary is behind the CHECK constraint';
  end if;
  -- Z must be classified specifically as uncertain, not swept into a neighbouring bucket.
  if coalesce((v_ready -> 'by_readiness' ->> 'outcome_uncertain')::bigint, 0) < 1 then
    raise exception 'FAIL[census]: estate Z is not in the outcome_uncertain bucket; buckets = %',
      v_ready -> 'by_readiness';
  end if;
  if v_ready::text ilike '%@%' then
    raise exception 'FAIL[census]: the readiness projection contains an address shape';
  end if;
  -- Privacy: counts only. No identifier of any kind may appear.
  if v_ready::text ~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' then
    raise exception 'FAIL[census]: the readiness projection contains a uuid — it must be counts only';
  end if;
  raise notice '  ok   6 · readiness census: admits Y, refuses Z (outcomeUncertain), buckets '
    'partition the total, no uuid and no address';

  -- ── 7 · THE RELEASE DOOR IS STILL THE PRE-PHASE-D DOOR ───────────────────────────────────────
  --
  -- Phase A must not have changed when a release may proceed. Asserted on the deployed body, the same
  -- way migrations 0056/0057/0058 assert it, so a Phase D cutover pasted early fails HERE too.
  if (select prosrc from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
       where nsp.nspname = 'public' and p.proname = 'authorize_release') not like
      '%status <> ''cancelled''%' then
    raise exception 'FAIL[OC]: authorize_release no longer carries the pre-Phase-D predicate — the '
      'cutover has landed inside Phase A, ahead of its blast-radius census and its remedy';
  end if;
  raise notice '  ok   7 · Phase A left the release door unchanged (asserted on the deployed body)';

  -- ── 8 · EPISODE SCOPE — AN ACCEPTED NOTICE FROM A PRIOR CASE AUTHORIZES NOTHING (D3, R4) ───────
  --
  -- ★ THE FIXTURE MUST INTERLEAVE, OR IT PROVES NOTHING. Estates Y and Z each hold exactly ONE case,
  -- so for them case-scope and estate-scope give the SAME answer and a census scoped to the estate
  -- would pass every assertion above. That gap was not hypothetical: the mutation
  -- `p11oc-readiness-scoped-to-estate` was reported NOT_DETECTED against §10.1-§10.7, which is the
  -- transformation-test rule stated as evidence — a test of a scope must use input where the scope
  -- actually changes the output.
  --
  -- So estate V is built to disagree with itself: a PRIOR case carrying a real provider acceptance,
  -- and a CURRENT case whose own notice was never accepted. Case-scoped, V is refused (correct —
  -- nobody has been warned about THIS process). Estate-scoped, V is admitted, which is the release of
  -- an estate on the strength of a notice about a different, abandoned death process.
  declare
    OWNER_V uuid; EXEC_V uuid; V uuid;
    v_case_v1 uuid; v_case_v2 uuid; v_row_v1 uuid;
    v_before_admitted bigint;
    v_after_admitted bigint;
    v_acc_prior timestamptz;
    v_acc_current timestamptz;
  begin
    insert into auth.users default values returning id into OWNER_V;
    insert into auth.users default values returning id into EXEC_V;
    update auth.users set email = 'rs-owner-v@example.invalid' where id = OWNER_V;
    insert into public.estates (owner_id, name) values (OWNER_V, 'RS Estate V-OC') returning id into V;
    insert into public.estate_memberships (estate_id, user_id, role, status)
    values (V, OWNER_V, 'primary_user', 'approved');
    insert into public.estate_designations (estate_id, user_id, designation_type, status)
    values (V, EXEC_V, 'executor', 'active');

    -- PRIOR PROCESS: runs the full real path and reaches a genuine provider acceptance.
    perform harness_rs.attempt(EXEC_V, format('select public.initiate_death_verification_case(%L)', V));
    select id into v_case_v1 from public.death_verification_cases
     where estate_id = V and status = 'open';
    perform harness_rs.as_admin(ADMIN_Y,
      format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case_v1));
    perform harness_rs.as_admin(ADMIN_Y,
      format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case_v1));
    perform harness_rs.as_admin(ADMIN_Y, format('select public.dispatch_owner_safety_notice(%L)', V));
    select o.id into v_row_v1 from public.owner_notice_outbox o where o.estate_id = V;
    perform public.claim_owner_notices(25);
    perform public.record_owner_notice_outcome(v_row_v1, 'providerAccepted');
    perform harness_rs.as_admin(ADMIN_Y, format('select public.begin_challenge_window(%L)', V));

    -- That prior process is then abandoned, and a SECOND, independent one opens. The lifecycle stays
    -- at challenge_window for the new process; only the case identity moves. Composed directly rather
    -- than through the withdraw/re-initiate doors because what §10.8 tests is the SCOPE of the release
    -- predicate, not the reachability of the transition — and every NOT NULL column is carried over
    -- from the real case so no vocabulary is invented here.
    v_case_v2 := gen_random_uuid();
    insert into public.death_verification_cases (
      id, estate_id, event_type, status, initiated_by, initiator_designation_id,
      initiator_capacity, required_level_at_initiation, attained_level, decided_at, decided_by)
    select v_case_v2, c.estate_id, c.event_type, 'verified', c.initiated_by,
           c.initiator_designation_id, c.initiator_capacity, c.required_level_at_initiation,
           c.attained_level, now() + interval '1 second', c.decided_by
      from public.death_verification_cases c where c.id = v_case_v1;
    update public.death_verification_cases set status = 'cancelled' where id = v_case_v1;

    -- The NEW process's own notice: dispatched, never accepted. Nobody has been warned about THIS one.
    insert into public.owner_notice_outbox
      (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation, dispatched_at)
    values (V, OWNER_V, 'email', 'rs-owner-v@example.invalid', 'death_process.window_opened',
            'dispatched', v_case_v2, 1, now());

    -- ★ ASSERT THE INPUT PRECONDITION, so later fixture drift cannot quietly make this tautological.
    select o.notice_accepted_at into v_acc_prior from public.owner_notice_outbox o
     where o.case_id = v_case_v1;
    select o.notice_accepted_at into v_acc_current from public.owner_notice_outbox o
     where o.case_id = v_case_v2;
    if v_acc_prior is null then
      raise exception 'FAIL[control]: the PRIOR case carries no acceptance, so estate-scope and '
        'case-scope agree and §10.8 cannot distinguish them';
    end if;
    if v_acc_current is not null then
      raise exception 'FAIL[control]: the CURRENT case already carries an acceptance, so §10.8 would '
        'pass under either scope';
    end if;

    v_before_admitted := (v_ready ->> 'would_be_admitted_by_phase_d')::bigint;
    v_ready := harness_rs.as_admin_json(ADMIN_Y,
      'select public.owner_notice_release_readiness_census()');
    v_after_admitted := (v_ready ->> 'would_be_admitted_by_phase_d')::bigint;

    -- Estate V joined the door. It must NOT have joined the admitted set.
    if v_after_admitted <> v_before_admitted then
      raise exception 'FAIL[OC/D3]: adding an estate whose CURRENT case has no acceptance changed the '
        'admitted count from % to % — the predicate is scoped to the ESTATE, so an accepted notice '
        'from a prior abandoned death process authorizes a release under a new one',
        v_before_admitted, v_after_admitted;
    end if;
    if coalesce((v_ready -> 'by_readiness' ->> 'legacy_dispatched_unaccepted')::bigint, 0) < 1 then
      raise exception 'FAIL[OC/D3]: estate V is not classified as dispatched-without-acceptance; '
        'buckets = %', v_ready -> 'by_readiness';
    end if;
    raise notice '  ok   8 · episode scope: a prior case''s acceptance authorizes NOTHING for the '
      'current case (fixture interleaves, precondition asserted)';
  end;
end $rs10$;


-- =================================================================================================
-- 11 · PHASE 11-OC / PHASE C — THE OPERATOR RE-NOTICE
-- =================================================================================================
--
-- ★ WHAT THIS SECTION PROVES, AND WHY MIGRATION 0059 CANNOT PROVE IT ALONE. 0059 carries execution
-- controls, and on the replay database it reports them SKIPPED: the Phase C bundle loads before any
-- test file creates an estate, so there is no (estate, case) pair to exercise. That is honest of 0059
-- and it is NOT coverage. Everything it could only skip is proved HERE, against furnished non-zero
-- fixtures, through the real doors.
--
-- ★ THE CENTRAL CLAIM IS A TRANSFORMATION, AND THE FIXTURE IS BUILT SO THE TRANSFORMATION IS
-- OBSERVABLE. Phase C exists so an estate whose notice failed can obtain the acceptance fact Phase D
-- will require. §11.2 therefore drives one estate along the whole arc and reads the readiness census
-- at three points:
--
--     failedPermanent      → REFUSED          (the disease)
--     re-noticed, queued   → STILL REFUSED    (a reissue creates NO acceptance authority)
--     re-notice accepted   → ADMITTED         (the cure)
--
-- The middle reading is the one that makes this a control rather than a demonstration: if a reissue
-- alone moved the estate into the admitted set, an operator would hold a button that manufactures
-- release authority. And the third reading is the one that fails if the readiness census still
-- filters on the single Phase A `notice_kind` literal — a census blind to the remedy would report
-- this estate as permanently refused however many times it was re-noticed, and Phase C would be inert
-- inside the very instrument built to measure it.
--
-- ★ AND THE CONSOLE/DOOR AGREEMENT IS ASSERTED ON EVERY FIXTURE, NOT ARGUED. For each case below,
-- `owner_notice_reissue_assessment` is read and then the door is CALLED, and the two must agree: an
-- eligible verdict must be followed by a successful call, and an ineligible one by a refusal carrying
-- exactly that refusal code. A console that offered an action the door refuses would train operators
-- to ignore errors; one that hid an action the door would accept would leave an estate stranded.

create table if not exists harness_rs.ctx (k text primary key, v uuid);

/** Impersonate with an ARBITRARY claim set — the AAL1 / stale-token / non-admin matrix. */
create or replace function harness_rs.with_claims(p_uid uuid, p_claims jsonb, p_sql text)
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
create or replace function harness_rs.aal2(p_uid uuid) returns jsonb language sql as $$
  select jsonb_build_object('sub', p_uid, 'aal', 'aal2',
                            'iat', extract(epoch from now())::bigint);
$$;

/**
 * Read the shared assessment as an admin, then CALL the door, and require BOTH to refuse with the
 * SAME named code.
 *
 * ★ THIS IS THE CONSOLE-CANNOT-DISAGREE-WITH-THE-DOOR INSTRUMENT, and it is written as one helper so
 * every refusal fixture is held to it rather than the convenient ones. A verdict that disagreed with
 * the outcome fails here even if both halves are individually "reasonable".
 *
 * ★ IT IS REFUSAL-ONLY, DELIBERATELY. A helper that proved agreement on the SUCCESS path would have
 * to call the door — and a second call inside the same helper would append a second generation,
 * making every `generation = N` assertion downstream ambiguous. Success agreement is proved by
 * `reissue_once`, which reads the verdict, calls the door exactly once, and requires the door's
 * payload to match what the verdict predicted.
 */
create or replace function harness_rs.reissue_agrees(
  p_label text, p_admin uuid, p_case uuid, p_reason text, p_expect text
) returns void language plpgsql as $$
declare
  v_verdict jsonb;
  v_res     text;
begin
  if p_expect is null then
    raise exception 'HARNESS[%]: reissue_agrees is refusal-only; use reissue_once for success', p_label;
  end if;

  -- The console's answer, first.
  perform set_config('request.jwt.claim.sub', p_admin::text, true);
  perform set_config('request.jwt.claims', harness_rs.aal2(p_admin)::text, true);
  execute format('select public.owner_notice_reissue_assessment(%L)', p_case) into v_verdict;
  if (v_verdict ->> 'eligible')::boolean then
    raise exception 'FAIL[%]: the ASSESSMENT says eligible although the door is expected to refuse '
      'with % — the console would offer a control the server rejects', p_label, p_expect;
  end if;
  if v_verdict ->> 'refusal_code' is distinct from p_expect then
    raise exception 'FAIL[%]: the assessment refused with % but % was expected', p_label,
      v_verdict ->> 'refusal_code', p_expect;
  end if;

  -- The door's answer, second. Same actor, same claims.
  v_res := harness_rs.with_claims(p_admin, harness_rs.aal2(p_admin),
    format('select public.reissue_owner_safety_notice(%L, %L)', p_case, p_reason));
  if v_res = 'OK' then
    raise exception 'FAIL[%]: expected the door to refuse with %, but the call SUCCEEDED — the '
      'assessment and the door disagree in the dangerous direction', p_label, p_expect;
  end if;
  if position(p_expect in v_res) = 0 then
    raise exception 'FAIL[%]: expected refusal % but got %', p_label, p_expect, v_res;
  end if;
end $$;

/**
 * Assessment + a SINGLE successful reissue, returning the door's own payload.
 *
 * Separated from `reissue_agrees` because a helper that proves agreement by calling twice would
 * append two generations, and an assertion about generation N+1 written against a fixture that
 * quietly reached N+2 is the kind of test that passes for the wrong reason.
 */
create or replace function harness_rs.reissue_once(
  p_label text, p_admin uuid, p_case uuid, p_reason text
) returns jsonb language plpgsql as $$
declare v_verdict jsonb; v_out jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_admin::text, true);
  perform set_config('request.jwt.claims', harness_rs.aal2(p_admin)::text, true);
  execute format('select public.owner_notice_reissue_assessment(%L)', p_case) into v_verdict;
  if not (v_verdict ->> 'eligible')::boolean then
    raise exception 'FAIL[%]: the ASSESSMENT refuses (%) although the door is expected to accept — '
      'the console would hide a control this estate needs', p_label, v_verdict ->> 'refusal_code';
  end if;
  execute format('select public.reissue_owner_safety_notice(%L, %L)', p_case, p_reason) into v_out;
  if v_out is null then
    raise exception 'FAIL[%]: the door returned NULL', p_label;
  end if;
  -- The verdict promised a generation and a reason; the door must have produced exactly those.
  if (v_out ->> 'generation')::int is distinct from (v_verdict ->> 'next_generation')::int then
    raise exception 'FAIL[%]: the assessment predicted generation % and the door wrote % — the '
      'console would display a generation the server did not create', p_label,
      v_verdict ->> 'next_generation', v_out ->> 'generation';
  end if;
  if v_out ->> 'reissue_reason' is distinct from v_verdict ->> 'reissue_reason' then
    raise exception 'FAIL[%]: the assessment derived reason % and the door wrote %', p_label,
      v_verdict ->> 'reissue_reason', v_out ->> 'reissue_reason';
  end if;
  return v_out;
end $$;

/** Build one furnished estate at `owner_notification_dispatched`, with a generation-1 notice. */
create or replace function harness_rs.furnish_c(p_admin uuid, p_name text, p_email text)
returns uuid language plpgsql as $$
declare v_owner uuid; v_exec uuid; v_estate uuid; v_case uuid; v_res text;
begin
  insert into auth.users default values returning id into v_owner;
  insert into auth.users default values returning id into v_exec;
  update auth.users set email = p_email where id = v_owner;
  insert into public.estates (owner_id, name) values (v_owner, p_name) returning id into v_estate;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (v_estate, v_owner, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (v_estate, v_exec, 'executor', 'active');

  perform harness_rs.attempt(v_exec,
    format('select public.initiate_death_verification_case(%L)', v_estate));
  select id into v_case from public.death_verification_cases
   where estate_id = v_estate and status = 'open';
  perform harness_rs.as_admin(p_admin,
    format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', v_case));
  perform harness_rs.as_admin(p_admin,
    format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));
  v_res := harness_rs.as_admin(p_admin,
    format('select public.dispatch_owner_safety_notice(%L)', v_estate));
  if v_res <> 'OK' then
    raise exception 'FAIL[precondition]: dispatch for % refused: %', p_name, v_res;
  end if;
  return v_case;
end $$;

/** The CURRENT generation of an episode, read the way the door reads it. */
create or replace function harness_rs.current_gen(p_case uuid)
returns public.owner_notice_outbox language sql stable as $$
  select o.* from public.owner_notice_outbox o
   where o.case_id = p_case and o.channel = 'email'
     and o.notice_kind = any (public.owner_notice_episode_kinds())
     and o.superseded_by is null
   limit 1;
$$;

-- ── 11.0 · THE INSTRUMENT IS READING THE REAL THING ─────────────────────────────────────────────
do $rs11a$
declare
  ADMIN_C uuid; ADMIN_D uuid; NONADMIN uuid;
  CASE_P uuid; CASE_Q uuid; CASE_L uuid; CASE_N1 uuid; CASE_N2 uuid; CASE_N3 uuid;
  CASE_G uuid; CASE_H1 uuid; CASE_H2 uuid;
  P uuid; Q uuid; L uuid; N1 uuid; N2 uuid; N3 uuid; G uuid; H uuid;
  v_row public.owner_notice_outbox%rowtype;
  v_prior public.owner_notice_outbox%rowtype;
  v_out jsonb; v_ready jsonb; v_verdict jsonb;
  v_res text; n int;
  admitted_0 bigint; admitted_1 bigint; admitted_2 bigint;
  v_gen1 uuid; v_gen2 uuid;
  v_snapshot jsonb; v_snapshot_after jsonb;
  v_audit jsonb;
begin
  raise notice ' ';
  raise notice '11 · Phase 11-OC / Phase C: the operator re-notice';

  -- (a) every routine under test exists. A refusal assertion against a missing function passes by
  -- crashing, which is not a refusal.
  if to_regprocedure('public.reissue_owner_safety_notice(uuid, text)') is null
     or to_regprocedure('public.owner_notice_reissue_assessment(uuid)') is null
     or to_regprocedure('public.owner_notice_episode_kinds()') is null
     or to_regprocedure('public.owner_notice_reissue_kind()') is null then
    raise exception 'FAIL: a Phase C routine is not installed — the bundle did not land';
  end if;

  -- (b) THE PARAMETER LIST IS THE SAFETY PROPERTY. A recipient, an estate, a generation, a status or
  -- a vocabulary-reason parameter would each make a forbidden thing WRITABLE rather than merely
  -- forbidden. Asserted on the deployed signature, so adding one fails here.
  if to_regprocedure('public.reissue_owner_safety_notice(uuid, text)') is null then
    raise exception 'FAIL[C]: the re-notice door does not have the signature (uuid, text)';
  end if;
  if (select count(*) from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
       where nsp.nspname = 'public' and p.proname = 'reissue_owner_safety_notice') <> 1 then
    raise exception 'FAIL[C]: reissue_owner_safety_notice is overloaded — a second signature is a '
      'second door with its own parameter list, and the absences above stop being guarantees';
  end if;
  if (select pronargs from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
       where nsp.nspname = 'public' and p.proname = 'reissue_owner_safety_notice') <> 2 then
    raise exception 'FAIL[C]: the re-notice door takes more than (case, reason) — a recipient, an '
      'estate, a generation or a reason-vocabulary parameter has been added';
  end if;

  -- (c) grant posture, asserted rather than assumed.
  if has_function_privilege('anon', 'public.reissue_owner_safety_notice(uuid, text)', 'EXECUTE') then
    raise exception 'FAIL[C]: the re-notice door is anon-executable';
  end if;
  if has_function_privilege('anon', 'public.owner_notice_reissue_assessment(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.owner_notice_reissue_assessment(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.owner_notice_episode_kinds()', 'EXECUTE') then
    raise exception 'FAIL[C]: an INTERNAL Phase C helper is reachable by a client role';
  end if;
  -- POSITIVE CONTROL on the privilege matcher: it must be able to see a grant that IS present, or
  -- the three absences above would prove nothing.
  if not has_function_privilege('authenticated', 'public.reissue_owner_safety_notice(uuid, text)', 'EXECUTE') then
    raise exception 'FAIL[C]: the re-notice door is unreachable by an authenticated admin at all — '
      'the console can never call it and the privilege absences above are vacuous';
  end if;

  -- (d) the episode vocabulary really is a SET, and it really contains both kinds.
  if array_length(public.owner_notice_episode_kinds(), 1) <> 2
     or not ('death_process.window_opened' = any (public.owner_notice_episode_kinds()))
     or not (public.owner_notice_reissue_kind() = any (public.owner_notice_episode_kinds())) then
    raise exception 'FAIL[C]: owner_notice_episode_kinds() does not contain BOTH the initial kind and '
      'the re-notice kind — one of them is invisible to the census and to the door: %',
      public.owner_notice_episode_kinds();
  end if;
  if public.owner_notice_reissue_kind() = 'death_process.window_opened' then
    raise exception 'FAIL[C]: a re-notice is recorded as the INITIAL window-opening event. The outbox '
      'would assert the window opened twice, and an investigator reconstructing what the owner was '
      'told could not tell a first warning from a second.';
  end if;
  raise notice '  ok  11.0 · Phase C routines resolved; door is (case, reason) only, admin-reachable, '
    'helpers internal; the episode is a two-kind SET and a re-notice is not the initial event';

  -- ── FIXTURES ──────────────────────────────────────────────────────────────────────────────────
  insert into auth.users default values returning id into ADMIN_C;
  insert into auth.users default values returning id into ADMIN_D;
  insert into auth.users default values returning id into NONADMIN;
  insert into public.admins (user_id) values (ADMIN_C) on conflict do nothing;
  insert into public.admins (user_id) values (ADMIN_D) on conflict do nothing;

  CASE_P  := harness_rs.furnish_c(ADMIN_C, 'RS Estate P-C', 'rs-owner-p@example.invalid');
  CASE_Q  := harness_rs.furnish_c(ADMIN_C, 'RS Estate Q-C', 'rs-owner-q@example.invalid');
  CASE_L  := harness_rs.furnish_c(ADMIN_C, 'RS Estate L-C', 'rs-owner-l@example.invalid');
  CASE_N1 := harness_rs.furnish_c(ADMIN_C, 'RS Estate N1-C', 'rs-owner-n1@example.invalid');
  CASE_N2 := harness_rs.furnish_c(ADMIN_C, 'RS Estate N2-C', 'rs-owner-n2@example.invalid');
  CASE_N3 := harness_rs.furnish_c(ADMIN_C, 'RS Estate N3-C', 'rs-owner-n3@example.invalid');
  CASE_G  := harness_rs.furnish_c(ADMIN_C, 'RS Estate G-C', 'rs-owner-g@example.invalid');

  select estate_id into P from public.death_verification_cases where id = CASE_P;
  select estate_id into Q from public.death_verification_cases where id = CASE_Q;
  select estate_id into L from public.death_verification_cases where id = CASE_L;
  select estate_id into N1 from public.death_verification_cases where id = CASE_N1;
  select estate_id into N2 from public.death_verification_cases where id = CASE_N2;
  select estate_id into N3 from public.death_verification_cases where id = CASE_N3;
  select estate_id into G from public.death_verification_cases where id = CASE_G;

  insert into harness_rs.ctx (k, v) values ('admin_c', ADMIN_C) on conflict (k) do update set v = excluded.v;
  insert into harness_rs.ctx (k, v) values ('case_p', CASE_P) on conflict (k) do update set v = excluded.v;

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.1 · THE THREE ELIGIBLE CLASSES, AND THE LEGACY ONE IS LOAD-BEARING
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ CASE C — `dispatched` WITH NO ACCEPTANCE FACT — IS THE ONE THAT MUST NOT BE REFUSED ON THE
  -- STRENGTH OF ITS STATUS. Every row written before Phase A carries `dispatched` with a NULL stamp,
  -- because the stamp did not exist. That population is exactly what Phase D blocks, and refusing to
  -- re-notice it would leave it with no route to a remedy at all — which is the reason Phase C
  -- precedes Phase D rather than following it.

  -- P · failedPermanent, at challenge_window. Settled through the REAL write-back path.
  v_row := harness_rs.current_gen(CASE_P);
  perform public.record_owner_notice_outcome(v_row.id, 'failedPermanent', 'provider_rejected');
  perform harness_rs.as_admin(ADMIN_C, format('select public.begin_challenge_window(%L)', P));
  -- ★ THE PREDECESSOR IS BACKDATED, AND THAT IS THE TRANSFORMATION-TEST RULE RATHER THAN SET DRESSING.
  -- `now()` is TRANSACTION-constant, so inside this single test transaction a successor that COPIED
  -- `requested_at` and one that wrote a fresh `now()` are byte-identical — an assertion against them
  -- would pass with the copy in place and could never fail. Backdating the predecessor is input the
  -- transformation must change: a copy is then observably two hours stale, and a fresh stamp is not.
  update public.owner_notice_outbox set requested_at = now() - interval '2 hours'
   where id = v_row.id;

  -- Q · outcomeUncertain, left at owner_notification_dispatched.
  v_row := harness_rs.current_gen(CASE_Q);
  perform public.record_owner_notice_outcome(v_row.id, 'outcomeUncertain');

  -- L · the LEGACY shape, constructed by direct UPDATE because no code path can produce it any more.
  -- `record_owner_notice_outcome` writes status and acceptance in ONE statement, so `dispatched` +
  -- NULL is structurally unreachable after Phase A — which is precisely what makes it an unambiguous
  -- pre-Phase-A marker rather than a state this test invented.
  v_row := harness_rs.current_gen(CASE_L);
  update public.owner_notice_outbox
     set status = 'dispatched', dispatched_at = now(), notice_accepted_at = null
   where id = v_row.id;
  perform harness_rs.as_admin(ADMIN_C, format('select public.begin_challenge_window(%L)', L));
  -- ★ ASSERT THE INPUT PRECONDITION, so later fixture drift cannot quietly make this tautological.
  v_row := harness_rs.current_gen(CASE_L);
  if v_row.status <> 'dispatched' or v_row.notice_accepted_at is not null then
    raise exception 'FAIL[control]: the LEGACY fixture is not dispatched-with-NULL-acceptance '
      '(status=%, accepted=%), so §11.1 case C tests a different class entirely',
      v_row.status, v_row.notice_accepted_at;
  end if;

  v_out := harness_rs.reissue_once('C1/failedPermanent', ADMIN_C, CASE_P,
    'provider rejected the first notice; re-sending under Phase C');
  if v_out ->> 'status' <> 'queued' then
    raise exception 'FAIL[C1]: a re-notice did not start QUEUED (status=%) — a successful call means '
      'NEW WARNING QUEUED and nothing stronger', v_out ->> 'status';
  end if;
  if (v_out ->> 'generation')::int <> 2 then
    raise exception 'FAIL[C1]: expected generation 2, got %', v_out ->> 'generation';
  end if;
  if v_out ->> 'reissue_reason' <> 'prior_failed_permanent' then
    raise exception 'FAIL[C1]: the derived vocabulary reason is %, expected prior_failed_permanent',
      v_out ->> 'reissue_reason';
  end if;

  v_out := harness_rs.reissue_once('C2/outcomeUncertain', ADMIN_C, CASE_Q,
    'provider outcome never confirmed; re-sending under Phase C');
  if (v_out ->> 'generation')::int <> 2 or v_out ->> 'status' <> 'queued' then
    raise exception 'FAIL[C2]: outcomeUncertain did not yield a queued generation 2: %', v_out;
  end if;
  if v_out ->> 'reissue_reason' <> 'prior_outcome_uncertain' then
    raise exception 'FAIL[C2]: reason is %, expected prior_outcome_uncertain', v_out ->> 'reissue_reason';
  end if;

  v_out := harness_rs.reissue_once('C3/legacy dispatched+NULL', ADMIN_C, CASE_L,
    'pre-Phase-A row carries no acceptance fact; producing one under Phase C');
  if (v_out ->> 'generation')::int <> 2 or v_out ->> 'status' <> 'queued' then
    raise exception 'FAIL[C3]: the legacy class did not yield a queued generation 2: %', v_out;
  end if;
  if v_out ->> 'reissue_reason' <> 'legacy_no_acceptance_record' then
    raise exception 'FAIL[C3]: reason is %, expected legacy_no_acceptance_record',
      v_out ->> 'reissue_reason';
  end if;
  raise notice '  ok  11.1 · all three eligible classes yield a QUEUED generation 2 with a reason '
    'derived from the predecessor — including `dispatched` with no acceptance fact';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.2 · THE EPISODE — one current generation, forensics preserved, and the successor is clean
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  select id into v_gen1 from public.owner_notice_outbox
   where case_id = CASE_P and generation = 1;
  select id into v_gen2 from public.owner_notice_outbox
   where case_id = CASE_P and generation = 2;

  if v_gen1 is null or v_gen2 is null then
    raise exception 'FAIL[control]: estate P does not hold two generations, so §11.2 asserts nothing';
  end if;
  if v_gen1 = v_gen2 then
    raise exception 'FAIL[C]: the successor REUSED the predecessor row id. drain.ts builds the '
      'provider Idempotency-Key from the row id, so a deliberate re-notice would replay the first '
      'message''s key and the provider would no-op it — the second warning would never be sent.';
  end if;

  -- Exactly one current generation, and the CURRENT one is the successor.
  select count(*) into n from public.owner_notice_outbox
   where case_id = CASE_P and superseded_by is null;
  if n <> 1 then
    raise exception 'FAIL[C/D12]: the episode has % current generations, expected exactly 1', n;
  end if;
  select * into v_row from public.owner_notice_outbox where id = v_gen2;
  if v_row.superseded_by is not null then
    raise exception 'FAIL[C]: the NEW generation is already superseded';
  end if;
  select * into v_prior from public.owner_notice_outbox where id = v_gen1;
  if v_prior.superseded_by is distinct from v_gen2 then
    raise exception 'FAIL[C]: the prior generation does not point at the successor (superseded_by=%, '
      'successor=%) — the retirement link is the ONLY thing that identifies which row is live',
      v_prior.superseded_by, v_gen2;
  end if;

  -- The predecessor keeps EVERY forensic field. That evidence is why the reissue was warranted.
  if v_prior.status <> 'failedPermanent' then
    raise exception 'FAIL[C]: the retired generation''s status was rewritten to % — a requeued '
      'terminal row destroys the record that the owner was not reached', v_prior.status;
  end if;
  if v_prior.failure_class is distinct from 'provider_rejected' then
    raise exception 'FAIL[C]: the retired generation lost its failure_class (%)', v_prior.failure_class;
  end if;
  if v_prior.generation <> 1 or v_prior.case_id <> CASE_P then
    raise exception 'FAIL[C]: the retired generation''s episode identity was rewritten';
  end if;

  -- The successor inherits NOTHING that could carry a stale fact forward.
  if v_row.notice_accepted_at is not null then
    raise exception 'FAIL[C]: the new generation was born with an acceptance timestamp. Reissuing '
      'does not create acceptance authority — only the providerAccepted settle path may stamp it.';
  end if;
  if v_row.status <> 'queued' then
    raise exception 'FAIL[C]: the new generation was born %, not queued', v_row.status;
  end if;
  if v_row.attempts <> 0 or v_row.claimed_at is not null or v_row.dispatched_at is not null
     or v_row.failure_class is not null or v_row.next_attempt_at is not null then
    raise exception 'FAIL[C]: the new generation inherited a delivery fact from its predecessor '
      '(attempts=%, claimed=%, dispatched=%, class=%, next=%)',
      v_row.attempts, v_row.claimed_at, v_row.dispatched_at, v_row.failure_class, v_row.next_attempt_at;
  end if;
  -- ★ ASSERT THE INPUT PRECONDITION, so fixture drift cannot make the comparison tautological.
  if v_prior.requested_at >= now() then
    raise exception 'FAIL[control]: the predecessor was not backdated, so `now()` being '
      'transaction-constant makes the requested_at assertion below pass whether the successor '
      'copied the value or wrote a fresh one';
  end if;
  if v_row.requested_at <= v_prior.requested_at then
    raise exception 'FAIL[C]: the successor did not get a NEW requested_at (successor=%, '
      'predecessor=%) — the age gate would run from the predecessor''s request and the new warning '
      'could be settled stale before it was ever claimed', v_row.requested_at, v_prior.requested_at;
  end if;
  if v_row.notice_kind <> public.owner_notice_reissue_kind() then
    raise exception 'FAIL[C]: the successor carries kind % — a second warning recorded as the initial '
      'window-opening event', v_row.notice_kind;
  end if;
  if v_row.reissued_by is distinct from ADMIN_C then
    raise exception 'FAIL[C]: reissued_by is % — the operator is not derived from auth.uid()',
      v_row.reissued_by;
  end if;

  -- ★ THE RECIPIENT IS DERIVED, AND IT IS NOT RETURNED. The successor must carry the authoritative
  -- owner address (so the message can actually be sent) while the RPC payload carries none.
  if v_row.recipient is distinct from 'rs-owner-p@example.invalid' then
    raise exception 'FAIL[C]: the successor''s recipient is % — it was not derived through '
      'estate_owner_user_id -> auth.users.email', v_row.recipient;
  end if;
  if v_out::text ilike '%@%' then
    raise exception 'FAIL[C]: the re-notice RPC payload contains an address shape — re-notice is not '
      'a recipient-edit feature and the operator never needs to see a living owner''s address';
  end if;
  raise notice '  ok  11.2 · exactly one current generation; the retired row keeps every forensic '
    'field; the successor inherits none, gets a new id, a new requested_at and the re-notice kind; '
    'recipient derived and never returned';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.3 · THE REMEDIATION ARC — the transformation this whole phase exists to perform
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- Read at three points. The MIDDLE reading is the control: if a reissue alone moved the estate into
  -- the admitted set, an operator would hold a button that manufactures release authority.
  v_ready := harness_rs.as_admin_json(ADMIN_C,
    'select public.owner_notice_release_readiness_census()');
  admitted_0 := (v_ready ->> 'would_be_admitted_by_phase_d')::bigint;

  -- Precondition: estate P's episode carries NO acceptance anywhere, or the arc is tautological.
  select count(*) into n from public.owner_notice_outbox
   where case_id = CASE_P and notice_accepted_at is not null;
  if n <> 0 then
    raise exception 'FAIL[control]: estate P''s episode already carries % acceptance(s) before the '
      'remediation arc — the census reading below would pass with or without Phase C', n;
  end if;
  if (v_ready ->> 'would_be_refused_by_phase_d')::bigint < 1 then
    raise exception 'FAIL[control]: the readiness census refuses NOBODY although estate P sits at '
      'challenge_window with no acceptance — direction 2 proves nothing';
  end if;

  -- READING 1 → 2 · a queued re-notice adds NO release authority.
  v_ready := harness_rs.as_admin_json(ADMIN_C,
    'select public.owner_notice_release_readiness_census()');
  admitted_1 := (v_ready ->> 'would_be_admitted_by_phase_d')::bigint;
  if admitted_1 <> admitted_0 then
    raise exception 'FAIL[C/D7]: issuing a re-notice changed the admitted count from % to %. A '
      'protective act must never manufacture release authority — an operator would hold a button '
      'that unblocks a release by queueing an email.', admitted_0, admitted_1;
  end if;
  -- And the estate is visible as QUEUED rather than having vanished from the classification.
  if coalesce((v_ready -> 'by_readiness' ->> 'queued')::bigint, 0) < 1 then
    raise exception 'FAIL[C]: after a re-notice, estate P is not classified as `queued`; buckets = %. '
      'The readiness census cannot see a re-notice row at all, so a remediated estate reads as one '
      'that was never dispatched.', v_ready -> 'by_readiness';
  end if;

  -- READING 3 · the provider accepts the RE-NOTICE. This is the cure, and the assertion that fails
  -- if the census still filters on the single Phase A notice_kind literal.
  perform public.record_owner_notice_outcome(v_gen2, 'providerAccepted');
  select count(*) into n from public.owner_notice_outbox
   where case_id = CASE_P and notice_accepted_at is not null;
  if n <> 1 then
    raise exception 'FAIL[control]: the accepted re-notice did not produce exactly one acceptance in '
      'the episode (found %)', n;
  end if;
  v_ready := harness_rs.as_admin_json(ADMIN_C,
    'select public.owner_notice_release_readiness_census()');
  admitted_2 := (v_ready ->> 'would_be_admitted_by_phase_d')::bigint;
  if admitted_2 <> admitted_0 + 1 then
    raise exception 'FAIL[C]: an ACCEPTED re-notice did not move estate P into the admitted set '
      '(admitted % -> %). The readiness census filters on a single notice_kind literal, so it '
      'cannot see the remedy: a re-noticed estate would report as permanently refused however many '
      'times it was re-noticed, and Phase C is inert inside the instrument built to measure it.',
      admitted_0, admitted_2;
  end if;
  raise notice '  ok  11.3 · remediation arc: failedPermanent REFUSED -> re-noticed STILL REFUSED '
    '(no authority manufactured) -> accepted ADMITTED (admitted % -> %)', admitted_0, admitted_2;

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.4 · THE AUDIT — a distinct action, both generations, the reason, and no address
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  select to_jsonb(a) into v_audit from public.audit_logs a
   where a.action = 'death_process.owner_notice_reissued'
     and a.target_id = v_gen2;
  if v_audit is null then
    raise exception 'FAIL[C]: no death_process.owner_notice_reissued audit row was written for the '
      'new generation. A remediation with no audit is a safety-queue write nobody can reconstruct.';
  end if;
  if (v_audit ->> 'actor_id')::uuid is distinct from ADMIN_C then
    raise exception 'FAIL[C]: the audit names actor % rather than the acting admin', v_audit ->> 'actor_id';
  end if;
  if (v_audit -> 'metadata' ->> 'prior_notice_id')::uuid is distinct from v_gen1
     or (v_audit -> 'metadata' ->> 'new_notice_id')::uuid is distinct from v_gen2 then
    raise exception 'FAIL[C]: the audit does not name BOTH row ids — the supersession chain is not '
      'reconstructible from the audit alone: %', v_audit -> 'metadata';
  end if;
  if (v_audit -> 'metadata' ->> 'prior_generation')::int <> 1
     or (v_audit -> 'metadata' ->> 'new_generation')::int <> 2 then
    raise exception 'FAIL[C]: the audit points at the wrong generation(s): %', v_audit -> 'metadata';
  end if;
  if v_audit -> 'metadata' ->> 'prior_status' <> 'failedPermanent' then
    raise exception 'FAIL[C]: the audit does not record the state that warranted the reissue: %',
      v_audit -> 'metadata';
  end if;
  if v_audit -> 'metadata' ->> 'reason' is null
     or btrim(v_audit -> 'metadata' ->> 'reason') = '' then
    raise exception 'FAIL[C]: the operator''s reason was not recorded';
  end if;
  if v_audit -> 'metadata' ->> 'reissue_reason' is null then
    raise exception 'FAIL[C]: the derived vocabulary reason was not recorded';
  end if;
  if v_audit::text ilike '%@%' then
    raise exception 'FAIL[C]: the reissue audit contains an address shape. An audit row outlives '
      'every reason anyone had to read it.';
  end if;
  -- ★ AND IT IS NOT THE DISPATCH ACTION. Reusing `owner_notice_dispatched` would make the trail
  -- assert a lifecycle transition that did not happen, and hide the reissue from anyone counting
  -- dispatches.
  select count(*) into n from public.audit_logs a
   where a.action = 'death_process.owner_notice_dispatched' and a.target_id = v_gen2;
  if n <> 0 then
    raise exception 'FAIL[C]: the reissue also wrote a dispatch audit row — a second warning is being '
      'recorded as the window opening again';
  end if;
  raise notice '  ok  11.4 · audit: distinct action, acting admin, both row ids, both generations, '
    'prior status, operator reason and derived reason — and no address';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.5 · THE INELIGIBLE CURRENT GENERATIONS
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- Each refusal is asserted through `reissue_agrees`, so the console verdict and the door's actual
  -- behaviour are proved to match on every one of them.

  -- queued — the ordinary drain still owns it (N1 was dispatched and left alone).
  perform harness_rs.reissue_agrees('N/queued', ADMIN_C, CASE_N1, 'should be refused',
    'notice_still_queued');

  -- processing — OB-1 visibility/reclaim still owns it. Constructed by direct UPDATE: the production
  -- writer is `claim_owner_notices`, which claims a batch across the whole database, and a fixture
  -- that depended on batch composition would pass or fail for reasons unrelated to this rule.
  v_row := harness_rs.current_gen(CASE_N2);
  update public.owner_notice_outbox set status = 'processing', claimed_at = now(), attempts = 1
   where id = v_row.id;
  perform harness_rs.reissue_agrees('N/processing', ADMIN_C, CASE_N2, 'should be refused',
    'notice_still_processing');

  -- dispatched WITH an acceptance fact — provider acceptance is established, there is nothing to
  -- remedy, and re-warning a living owner about their own death process is not a free action.
  v_row := harness_rs.current_gen(CASE_N3);
  perform public.record_owner_notice_outcome(v_row.id, 'providerAccepted');
  perform harness_rs.reissue_agrees('N/accepted', ADMIN_C, CASE_N3, 'should be refused',
    'notice_already_accepted');

  -- ★ THE PAIR THAT MAKES THE ACCEPTANCE TEST REAL. N3 and L are BOTH `dispatched`. The only
  -- difference is the FACT, and they must reach opposite verdicts — otherwise the rule is a status
  -- list wearing a timestamp's clothes.
  v_row := harness_rs.current_gen(CASE_N3);
  if v_row.status <> 'dispatched' or v_row.notice_accepted_at is null then
    raise exception 'FAIL[control]: the accepted fixture is not dispatched-with-acceptance, so the '
      'pairing below proves nothing (status=%, accepted=%)', v_row.status, v_row.notice_accepted_at;
  end if;
  raise notice '  ok  11.5 · queued / processing / dispatched-with-acceptance each refused by name, '
    'and `dispatched` alone decides nothing — the FACT does';

  -- cancelled — defence in depth. Nothing in production writes it; this fixture does, by direct
  -- UPDATE, exactly as the 11-E fixture does. "Currently unreachable" is a statement about today.
  update public.owner_notice_outbox set status = 'cancelled'
   where id = (harness_rs.current_gen(CASE_N2)).id;
  perform harness_rs.reissue_agrees('N/cancelled', ADMIN_C, CASE_N2, 'should be refused',
    'notice_cancelled');
  raise notice '  ok  11.5b · a cancelled current generation is refused (defence in depth)';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.6 · THE LIFECYCLE GATE — five refusals AND two positive controls, one variable at a time
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THE FIXTURE VARIES IN EXACTLY ONE DIMENSION. Estate G holds a verified current case and a
  -- `failedPermanent` current generation throughout; only `estate_lifecycle.state` moves. Without the
  -- two POSITIVE controls a gate that refused every state would satisfy all five refusals and read as
  -- conservative — which is the failure mode this repository has shipped before.
  --
  -- The refused states are written by direct UPDATE because the transition map deliberately has no
  -- edge back to most of them. What §11.6 tests is the STATE GATE, not the reachability of a state.
  v_row := harness_rs.current_gen(CASE_G);
  perform public.record_owner_notice_outcome(v_row.id, 'failedPermanent', 'provider_rejected');

  declare
    v_state text;
    v_states text[] := array['active', 'death_verification_pending', 'death_verified',
                             'challenge_halted', 'released'];
  begin
    foreach v_state in array v_states loop
      update public.estate_lifecycle set state = v_state where estate_id = G;
      perform harness_rs.reissue_agrees(format('G/%s', v_state), ADMIN_C, CASE_G,
        'should be refused', 'invalid_reissue_state');
    end loop;
  end;

  -- POSITIVE CONTROL, BOTH PERMITTED STATES. The assessment must say ELIGIBLE in each — proved
  -- without calling the door, so the fixture is not consumed and the second control is real.
  declare
    v_state text;
  begin
    foreach v_state in array array['owner_notification_dispatched', 'challenge_window'] loop
      update public.estate_lifecycle set state = v_state where estate_id = G;
      perform set_config('request.jwt.claim.sub', ADMIN_C::text, true);
      perform set_config('request.jwt.claims', harness_rs.aal2(ADMIN_C)::text, true);
      execute format('select public.owner_notice_reissue_assessment(%L)', CASE_G) into v_verdict;
      if not (v_verdict ->> 'eligible')::boolean then
        raise exception 'FAIL[control]: state % is REFUSED (%) although it is one of the two states a '
          'warning is worth sending from. The lifecycle gate refuses everything, so the five '
          'refusals above prove nothing.', v_state, v_verdict ->> 'refusal_code';
      end if;
    end loop;
  end;
  raise notice '  ok  11.6 · five lifecycle states refused with invalid_reissue_state; BOTH permitted '
    'states accepted by the same instrument (one variable, positive controls first)';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.7 · EPISODE IDENTITY — the case is the episode, and a caller cannot override it
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THE FIXTURE MUST INTERLEAVE OR IT PROVES NOTHING. Estate H runs a first process to a
  -- `failedPermanent` notice, that process is abandoned, and a SECOND verified case opens. The FIRST
  -- case's current generation is still failedPermanent — eligible on every criterion except the one
  -- under test. If the door trusted the caller's case, it would happily append a generation to an
  -- ABANDONED process, and the notice it queued would warn an owner about a case nobody is running.
  CASE_H1 := harness_rs.furnish_c(ADMIN_C, 'RS Estate H-C', 'rs-owner-h@example.invalid');
  select estate_id into H from public.death_verification_cases where id = CASE_H1;
  v_row := harness_rs.current_gen(CASE_H1);
  perform public.record_owner_notice_outcome(v_row.id, 'failedPermanent', 'provider_rejected');
  perform harness_rs.as_admin(ADMIN_C, format('select public.begin_challenge_window(%L)', H));

  -- Before the second case exists, H1 IS the current episode and must be eligible — the positive
  -- control that makes the refusal below a statement about CURRENCY rather than about anything else.
  perform set_config('request.jwt.claim.sub', ADMIN_C::text, true);
  perform set_config('request.jwt.claims', harness_rs.aal2(ADMIN_C)::text, true);
  execute format('select public.owner_notice_reissue_assessment(%L)', CASE_H1) into v_verdict;
  if not (v_verdict ->> 'eligible')::boolean then
    raise exception 'FAIL[control]: case H1 is refused (%) while it is still the current episode, so '
      'the currency refusal below would pass for the wrong reason', v_verdict ->> 'refusal_code';
  end if;

  -- A SECOND, independent verified process opens. Composed directly rather than through the
  -- withdraw/re-initiate doors, exactly as §10.8 does and for the same reason: what is under test is
  -- the SCOPE of the episode key, not the reachability of the transition. Every NOT NULL column is
  -- carried over from the real case, so no vocabulary is invented here.
  CASE_H2 := gen_random_uuid();
  insert into public.death_verification_cases (
    id, estate_id, event_type, status, initiated_by, initiator_designation_id,
    initiator_capacity, required_level_at_initiation, attained_level, decided_at, decided_by)
  select CASE_H2, c.estate_id, c.event_type, 'verified', c.initiated_by,
         c.initiator_designation_id, c.initiator_capacity, c.required_level_at_initiation,
         c.attained_level, now() + interval '1 second', c.decided_by
    from public.death_verification_cases c where c.id = CASE_H1;
  update public.death_verification_cases set status = 'cancelled' where id = CASE_H1;

  -- 22 · a case that is not the current verified episode of its own estate.
  perform harness_rs.reissue_agrees('H/historical case', ADMIN_C, CASE_H1,
    'should be refused', 'case_not_current');

  -- 23 · an OPEN (never verified) case on an estate that has a verified one.
  declare
    v_open uuid := gen_random_uuid();
  begin
    insert into public.death_verification_cases (
      id, estate_id, event_type, status, initiated_by, initiator_designation_id,
      initiator_capacity, required_level_at_initiation)
    select v_open, c.estate_id, c.event_type, 'open', c.initiated_by,
           c.initiator_designation_id, c.initiator_capacity, c.required_level_at_initiation
      from public.death_verification_cases c where c.id = CASE_H1;
    perform harness_rs.reissue_agrees('H/unverified case', ADMIN_C, v_open,
      'should be refused', 'case_not_current');
  end;

  -- 24 · a case that does not exist at all.
  perform harness_rs.reissue_agrees('H/no such case', ADMIN_C, gen_random_uuid(),
    'should be refused', 'case_not_found');

  -- ★ AND THE ABANDONED EPISODE WAS NOT TOUCHED. The refusal must have left case H1's episode exactly
  -- as it was — one generation, still failedPermanent, still current within its own (dead) episode.
  select count(*) into n from public.owner_notice_outbox where case_id = CASE_H1;
  if n <> 1 then
    raise exception 'FAIL[C]: the refused reissue appended % rows to the abandoned episode', n;
  end if;
  raise notice '  ok  11.7 · episode identity: a historical case, an unverified case and a nonexistent '
    'case are each refused, the current episode is eligible (control), and nothing was appended';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.8 · NO CURRENT NOTICE — fail closed, and never silently dispatch instead
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- The current episode has no notice row at all. That is `no_current_notice`, and the remedy is a
  -- DISPATCH, not a re-notice. Creating an initial dispatch from this door would be a second,
  -- unaudited entry point into a lifecycle transition.
  update public.estate_lifecycle set state = 'challenge_window' where estate_id = H;
  perform harness_rs.reissue_agrees('H/no current notice', ADMIN_C, CASE_H2,
    'should be refused', 'no_current_notice');
  select count(*) into n from public.owner_notice_outbox where case_id = CASE_H2;
  if n <> 0 then
    raise exception 'FAIL[C]: a refused re-notice manufactured % row(s) for an episode that had none', n;
  end if;
  raise notice '  ok  11.8 · an episode with no current notice is refused and NOTHING is written';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.8b · AN UNREACHABLE OWNER FAILS CLOSED — no row is manufactured to satisfy the workflow
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THE TEMPTING WRONG ANSWER IS TO QUEUE THE ROW ANYWAY. It would make the console feel like it
  -- worked. What it actually produces is a row with no destination that the next drain claims, fails,
  -- and settles `failedPermanent` — leaving the episode with a SECOND dead generation and the first
  -- one retired, i.e. strictly worse than before the operator pressed the button. The remedy for an
  -- unreachable owner is to fix the account, not to queue mail at nobody.
  --
  -- The fixture dispatches with a real address (dispatch refuses without one) and then clears it, which
  -- is the reachable production shape: the account's address was removed or changed after dispatch.
  declare
    CASE_U uuid;
    U uuid;
    v_owner_u uuid;
  begin
    CASE_U := harness_rs.furnish_c(ADMIN_C, 'RS Estate U-C', 'rs-owner-u@example.invalid');
    select estate_id into U from public.death_verification_cases where id = CASE_U;
    perform public.record_owner_notice_outcome((harness_rs.current_gen(CASE_U)).id,
      'failedPermanent', 'provider_rejected');

    -- ★ POSITIVE CONTROL FIRST: while the address resolves, this episode is ELIGIBLE. Without it the
    -- refusal below would be explained by the estate rather than by the missing channel.
    perform set_config('request.jwt.claim.sub', ADMIN_C::text, true);
    perform set_config('request.jwt.claims', harness_rs.aal2(ADMIN_C)::text, true);
    execute format('select public.owner_notice_reissue_assessment(%L)', CASE_U) into v_verdict;
    if not (v_verdict ->> 'eligible')::boolean then
      raise exception 'FAIL[control]: estate U is refused (%) while its owner is still reachable',
        v_verdict ->> 'refusal_code';
    end if;
    if (v_verdict ->> 'owner_channel_resolvable') <> 'true' then
      raise exception 'FAIL[control]: owner_channel_resolvable is false for an owner who HAS an address';
    end if;

    -- The channel goes away.
    select public.estate_owner_user_id(U) into v_owner_u;
    update auth.users set email = null where id = v_owner_u;

    perform harness_rs.reissue_agrees('U/unreachable owner', ADMIN_C, CASE_U,
      'the owner has no address; this must fail closed', 'owner_channel_unreachable');

    select count(*) into n from public.owner_notice_outbox where case_id = CASE_U;
    if n <> 1 then
      raise exception 'FAIL[C]: a re-notice for an UNREACHABLE owner manufactured a row (episode holds '
        '% rows). It would be claimed, fail, and settle failedPermanent — a second dead generation '
        'with the evidence of the first one retired.', n;
    end if;
    if (harness_rs.current_gen(CASE_U)).superseded_by is not null then
      raise exception 'FAIL[C]: the refused re-notice RETIRED the current generation anyway';
    end if;

    -- Restore, so no later suite trips over an owner with no address.
    update auth.users set email = 'rs-owner-u@example.invalid' where id = v_owner_u;
  end;
  raise notice '  ok  11.8b · an unreachable owner is refused with owner_channel_unreachable, no row '
    'is manufactured, and the current generation is not retired (positive control first)';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.9 · THE REASON IS REQUIRED, AND BLANK IS NOT A REASON
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- Estate Q holds a QUEUED generation 2 after §11.1, so a blank-reason call would otherwise be
  -- refused for currency reasons and this test would pass without ever reaching the reason check.
  -- It is therefore run against estate L, whose generation 2 is settled failedPermanent first —
  -- making it genuinely eligible on every axis except the reason.
  v_row := harness_rs.current_gen(CASE_L);
  perform public.record_owner_notice_outcome(v_row.id, 'failedPermanent', 'provider_rejected');
  perform set_config('request.jwt.claim.sub', ADMIN_C::text, true);
  perform set_config('request.jwt.claims', harness_rs.aal2(ADMIN_C)::text, true);
  execute format('select public.owner_notice_reissue_assessment(%L)', CASE_L) into v_verdict;
  if not (v_verdict ->> 'eligible')::boolean then
    raise exception 'FAIL[control]: estate L is not eligible (%), so the blank-reason refusals below '
      'would pass for the wrong reason', v_verdict ->> 'refusal_code';
  end if;

  declare
    v_blank text;
  begin
    foreach v_blank in array array['', '   ', E'\t\n'] loop
      v_res := harness_rs.with_claims(ADMIN_C, harness_rs.aal2(ADMIN_C),
        format('select public.reissue_owner_safety_notice(%L, %L)', CASE_L, v_blank));
      if v_res = 'OK' then
        raise exception 'FAIL[C]: a blank reason (%) was accepted. "Cleaning up" is not a reason; the '
          'audit exists so a legitimate remediation can be told from an operator mailing a living '
          'person repeatedly.', v_blank;
      end if;
      if position('reissue_reason_required' in v_res) = 0 then
        raise exception 'FAIL[C]: a blank reason was refused for the wrong reason: %', v_res;
      end if;
    end loop;
  end;
  -- NULL too.
  v_res := harness_rs.with_claims(ADMIN_C, harness_rs.aal2(ADMIN_C),
    format('select public.reissue_owner_safety_notice(%L, null)', CASE_L));
  if v_res = 'OK' or position('reissue_reason_required' in v_res) = 0 then
    raise exception 'FAIL[C]: a NULL reason was not refused with reissue_reason_required: %', v_res;
  end if;
  select count(*) into n from public.owner_notice_outbox where case_id = CASE_L;
  if n <> 2 then
    raise exception 'FAIL[C]: the blank-reason refusals appended a generation (episode holds % rows)', n;
  end if;
  raise notice '  ok  11.9 · blank, whitespace-only and NULL reasons are each refused by name, against '
    'an otherwise-ELIGIBLE episode, and nothing is written';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.10 · THE ACTOR MATRIX — every wrong caller, refused for the RIGHT reason
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- Estate L is still eligible (proved above), so each refusal below is attributable to the ACTOR
  -- rather than to the state. Without that, a matrix of refusals would be indistinguishable from an
  -- estate that was never reissuable.
  declare
    v_owner_l uuid;
    v_exec_l  uuid;
    v_estate_l uuid;
  begin
    select estate_id into v_estate_l from public.death_verification_cases where id = CASE_L;
    select m.user_id into v_owner_l from public.estate_memberships m
     where m.estate_id = v_estate_l and m.role = 'primary_user';
    select d.user_id into v_exec_l from public.estate_designations d
     where d.estate_id = v_estate_l and d.designation_type = 'executor';

    -- anon: no sub at all.
    v_res := harness_rs.with_claims(null, '{}'::jsonb,
      format('select public.reissue_owner_safety_notice(%L, %L)', CASE_L, 'anon attempt'));
    if v_res = 'OK' or position('auth_required' in v_res) = 0 then
      raise exception 'FAIL[C/anon]: expected auth_required, got %', v_res;
    end if;

    -- a signed-in non-admin with a perfectly fresh AAL2 session.
    v_res := harness_rs.with_claims(NONADMIN, harness_rs.aal2(NONADMIN),
      format('select public.reissue_owner_safety_notice(%L, %L)', CASE_L, 'non-admin attempt'));
    if v_res = 'OK' or position('admin_required' in v_res) = 0 then
      raise exception 'FAIL[C/non-admin]: expected admin_required, got %', v_res;
    end if;

    -- THE OWNER of the estate, directly. Being the subject of the notice confers no authority to
    -- queue another one.
    v_res := harness_rs.with_claims(v_owner_l, harness_rs.aal2(v_owner_l),
      format('select public.reissue_owner_safety_notice(%L, %L)', CASE_L, 'owner attempt'));
    if v_res = 'OK' or position('admin_required' in v_res) = 0 then
      raise exception 'FAIL[C/owner]: expected admin_required, got %', v_res;
    end if;

    -- THE EXECUTOR, directly. The fiduciary running the process is the party a false claim would be
    -- made BY, and re-notice is the control that warns the owner about them.
    v_res := harness_rs.with_claims(v_exec_l, harness_rs.aal2(v_exec_l),
      format('select public.reissue_owner_safety_notice(%L, %L)', CASE_L, 'executor attempt'));
    if v_res = 'OK' or position('admin_required' in v_res) = 0 then
      raise exception 'FAIL[C/executor]: expected admin_required, got %', v_res;
    end if;

    -- A REAL ADMIN at AAL1 — authenticated, authorized, single factor.
    v_res := harness_rs.with_claims(ADMIN_C,
      jsonb_build_object('sub', ADMIN_C, 'aal', 'aal1',
                         'iat', extract(epoch from now())::bigint),
      format('select public.reissue_owner_safety_notice(%L, %L)', CASE_L, 'aal1 attempt'));
    if v_res = 'OK' or position('mfa_required' in v_res) = 0 then
      raise exception 'FAIL[C/aal1]: expected mfa_required, got %', v_res;
    end if;

    -- A REAL ADMIN at AAL2 with a STALE token: authorized, stepped up, and last authenticated an
    -- hour ago. The freshness bound is what stops a forgotten open tab from writing to a safety queue.
    v_res := harness_rs.with_claims(ADMIN_C,
      jsonb_build_object('sub', ADMIN_C, 'aal', 'aal2',
                         'iat', extract(epoch from now())::bigint - 3600),
      format('select public.reissue_owner_safety_notice(%L, %L)', CASE_L, 'stale attempt'));
    if v_res = 'OK' or position('stale_token_reauth_required' in v_res) = 0 then
      raise exception 'FAIL[C/stale]: expected stale_token_reauth_required, got %', v_res;
    end if;
  end;

  -- ★ THE POSITIVE CONTROL FOR THE WHOLE MATRIX. A fresh AAL2 admin, on the same episode, must
  -- SUCCEED — otherwise every refusal above is explained by the estate rather than by the caller.
  select count(*) into n from public.owner_notice_outbox where case_id = CASE_L;
  if n <> 2 then
    raise exception 'FAIL[C]: the actor matrix appended a generation (episode holds % rows)', n;
  end if;
  v_out := harness_rs.reissue_once('L/fresh aal2 admin', ADMIN_C, CASE_L,
    'positive control for the actor matrix');
  if (v_out ->> 'generation')::int <> 3 then
    raise exception 'FAIL[control]: the admin positive control produced generation % rather than 3',
      v_out ->> 'generation';
  end if;
  raise notice '  ok  11.10 · anon / non-admin / owner / executor / AAL1 / stale-AAL2 each refused by '
    'the RIGHT sentinel, and a fresh AAL2 admin succeeds on the same episode (positive control)';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.11 · A SUPERSEDED GENERATION IS UNREACHABLE, AND GENERATIONS NEVER REPEAT
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- There is no notice-id parameter, so naming a retired row is UNWRITABLE rather than merely
  -- forbidden (§11.0(b) pins the signature). What remains to prove is that the door always acts on
  -- the CURRENT generation: estate L now holds three, and the third was computed from the second.
  select count(*) into n from public.owner_notice_outbox where case_id = CASE_L;
  if n <> 3 then
    raise exception 'FAIL[C]: estate L holds % generations, expected 3', n;
  end if;
  select count(distinct generation) into n from public.owner_notice_outbox where case_id = CASE_L;
  if n <> 3 then
    raise exception 'FAIL[C]: estate L''s generation numbers repeat — a successor was computed from '
      'something other than the locked predecessor';
  end if;
  select count(*) into n from public.owner_notice_outbox
   where case_id = CASE_L and superseded_by is null;
  if n <> 1 then
    raise exception 'FAIL[C/D12]: estate L has % current generations after three reissues', n;
  end if;
  if (select generation from public.owner_notice_outbox
       where case_id = CASE_L and superseded_by is null) <> 3 then
    raise exception 'FAIL[C]: the CURRENT generation of estate L is not the newest one — the door '
      'appended from a retired row';
  end if;
  raise notice '  ok  11.11 · three generations, three distinct numbers, exactly one current, and the '
    'current one is the newest';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- 11.12 · THE WALL BEHIND THE DOOR — the database refuses a second current generation
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ A LOCK IS A PROTOCOL; AN INDEX IS A GUARANTEE. §11.13 proves the lock actually blocks a second
  -- session. This proves that even with the lock defeated, the DATABASE refuses — including across
  -- notice KINDS, which the Phase A index could not see and which is the entire reason migration 0059
  -- replaced it.
  declare
    v_refused boolean;
    v_est uuid;
    v_usr uuid;
  begin
    select estate_id into v_est from public.death_verification_cases where id = CASE_L;
    select user_id into v_usr from public.owner_notice_outbox where case_id = CASE_L limit 1;

    -- Same kind as the current generation (window_renotice).
    begin
      insert into public.owner_notice_outbox
        (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
         reissue_reason)
      values (v_est, v_usr, 'email', 'rs-c-wall-same@example.invalid',
              public.owner_notice_reissue_kind(), 'queued', CASE_L, 99, 'prior_failed_permanent');
      v_refused := false;
    exception when unique_violation then
      v_refused := true;
    end;
    if not v_refused then
      raise exception 'FAIL[C/D12]: a SECOND current generation of the same kind was accepted';
    end if;

    -- ★ AND A DIFFERENT KIND. Under the Phase A index this INSERT SUCCEEDS and the episode holds two
    -- live generations — one window_opened and one window_renotice — with nothing to say which the
    -- release door should read.
    begin
      insert into public.owner_notice_outbox
        (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation)
      -- Generation 1 with a NULL reason, because the `owner_notice_outbox_reissue_pairing` CHECK
      -- fires BEFORE the unique index and would otherwise answer this probe with a check_violation —
      -- a refusal, but from the wrong wall, which would make the assertion below say nothing about
      -- the one-current-generation invariant it is written to test.
      values (v_est, v_usr, 'email', 'rs-c-wall-cross@example.invalid',
              'death_process.window_opened', 'queued', CASE_L, 1);
      v_refused := false;
    exception when unique_violation then
      v_refused := true;
    end;
    if not v_refused then
      raise exception 'FAIL[C/D12]: a second CURRENT generation was accepted because its notice_kind '
        'DIFFERS. The one-current-generation wall is keyed on the KIND rather than the EPISODE, so a '
        're-notice creates a second live notice instead of retiring the first.';
    end if;

    -- POSITIVE CONTROL: the index must not be refusing everything. A row for a DIFFERENT episode, and
    -- a SUPERSEDED row in this one, must both be accepted.
    declare
      v_ok_id uuid := gen_random_uuid();
    begin
      insert into public.owner_notice_outbox
        (id, estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
         superseded_by)
      values (v_ok_id, v_est, v_usr, 'email', 'rs-c-wall-control@example.invalid',
              'death_process.window_opened', 'queued', CASE_L, 1, v_ok_id);
    exception when others then
      raise exception 'FAIL[control]: the per-episode index refused a SUPERSEDED row, so it is '
        'refusing everything and the two refusals above prove nothing: %', SQLERRM;
    end;
    delete from public.owner_notice_outbox where recipient like 'rs-c-wall-%@example.invalid';
  end;
  raise notice '  ok  11.12 · the database refuses a second current generation — same kind AND across '
    'kinds — while still accepting a superseded row (positive control)';
end $rs11a$;

-- =================================================================================================
-- 11.13 · CONCURRENCY — TWO GENUINE SESSIONS, AND AN HONEST STATEMENT WHEN THAT IS NOT POSSIBLE
-- =================================================================================================
--
-- ★ THIS IS A SEPARATE TOP-LEVEL BLOCK FOR A REASON THAT IS EASY TO GET WRONG. psql commits after
-- each statement, so the fixtures §11 built are visible to another session ONLY once the DO block
-- that created them has ended. A concurrency test written inside that block would open a second
-- connection that could not see the estate under test, and would then "prove" mutual exclusion by
-- failing to find anything — a green result from an instrument looking at an empty database.
--
-- ★ WHAT IS PROVED HERE, AND IN WHICH ORDER OF STRENGTH.
--
--   A · DETERMINISTIC, UNCONDITIONAL — the database refuses a second current generation. Already
--       asserted in §11.12; the wall does not depend on anything below.
--   B · REAL TWO-SESSION MUTUAL EXCLUSION — `dblink` opens two genuine backend sessions. Session 1
--       calls the door and holds its transaction open; session 2 calls it and is observed BLOCKED
--       (`dblink_is_busy` = 1) rather than proceeding. Session 1 commits, session 2 unblocks, and
--       session 2 must then REFUSE — because the episode's current generation is now the freshly
--       queued successor.
--
-- ★ AND IF `dblink` IS UNAVAILABLE THIS SAYS SO OUT LOUD AND CLASSIFIES ITSELF DOWN. It does not
-- silently pass, and it does not claim a concurrency runtime proof it did not perform. A skipped
-- proof reported as a proof is the vacuous-audit failure this repository has shipped five times.
-- ── 11.13A · THE FIXTURE, IN ITS OWN TRANSACTION ────────────────────────────────────────────────
--
-- ★ THIS IS A SEPARATE STATEMENT BECAUSE OF THE MISTAKE IT ALREADY CAUGHT. Written inside the block
-- below, the estate and case created here are UNCOMMITTED while `dblink` opens its sessions — so
-- both remote sessions saw no such case and the door answered `case_not_found`. A concurrency test
-- can only observe contention over rows that are actually visible to the contending sessions.
do $rs11b0$
declare
  ADMIN_C  uuid;
  v_case   uuid;
  v_estate uuid;
  n        int;
begin
  select v into ADMIN_C from harness_rs.ctx where k = 'admin_c';
  if ADMIN_C is null then
    raise exception 'FAIL[control]: §11.13 could not find the §11 fixture context — it would measure '
      'nothing. harness_rs.ctx is empty.';
  end if;

  -- A fresh episode of its own, so §11.13 cannot disturb the generation counts §11.11 asserts.
  v_case := harness_rs.furnish_c(ADMIN_C, 'RS Estate CC-C', 'rs-owner-cc@example.invalid');
  select estate_id into v_estate from public.death_verification_cases where id = v_case;
  perform public.record_owner_notice_outcome((harness_rs.current_gen(v_case)).id,
    'failedPermanent', 'provider_rejected');
  perform harness_rs.as_admin(ADMIN_C, format('select public.begin_challenge_window(%L)', v_estate));
  insert into harness_rs.ctx (k, v) values ('case_cc', v_case)
    on conflict (k) do update set v = excluded.v;

  -- Precondition: exactly one current generation, and it is eligible. Otherwise the "second operator
  -- is refused" result below would be true for a reason that has nothing to do with concurrency.
  select count(*) into n from public.owner_notice_outbox
   where case_id = v_case and superseded_by is null;
  if n <> 1 then
    raise exception 'FAIL[control]: the concurrency fixture has % current generations', n;
  end if;
  perform set_config('request.jwt.claim.sub', ADMIN_C::text, true);
  perform set_config('request.jwt.claims', harness_rs.aal2(ADMIN_C)::text, true);
  if not (public.owner_notice_reissue_assessment(v_case) ->> 'eligible')::boolean then
    raise exception 'FAIL[control]: the concurrency fixture is not eligible, so a refusal below '
      'would prove nothing about mutual exclusion';
  end if;
end $rs11b0$;

-- ── 11.13B · THE PROOF, AGAINST A COMMITTED FIXTURE ─────────────────────────────────────────────
do $rs11b$
declare
  ADMIN_C  uuid;
  v_case   uuid;
  v_gen    int;
  v_busy   int;
  v_res    text;
  v_conn   text;
  v_claims text;
  n        int;
  v_have_dblink boolean := false;
begin
  select v into ADMIN_C from harness_rs.ctx where k = 'admin_c';
  select v into v_case  from harness_rs.ctx where k = 'case_cc';
  if ADMIN_C is null or v_case is null then
    raise exception 'FAIL[control]: §11.13B could not find the committed concurrency fixture';
  end if;

  begin
    create extension if not exists dblink;
    v_have_dblink := true;
  exception when others then
    v_have_dblink := false;
  end;

  if not v_have_dblink then
    raise notice '  SKIP 11.13B · dblink is unavailable on this database, so NO real two-session '
      'proof was performed. The deterministic wall in §11.12 stands; this run has NOT demonstrated '
      'that a second concurrent operator BLOCKS. Reported rather than passed.';
  else
    -- Local socket, same database, same superuser the suite already runs as. Built from
    -- `current_database()`/`current_user` rather than hardcoded, so it follows the harness.
    v_conn := format('dbname=%s user=%s host=/var/run/postgresql', current_database(), current_user);
    begin
      perform dblink_connect('awc1', v_conn);
      perform dblink_connect('awc2', v_conn);
    exception when others then
      v_have_dblink := false;
      raise notice '  SKIP 11.13B · dblink could not open a local session (%). NO real two-session '
        'proof was performed; §11.12''s deterministic wall stands and this run has NOT demonstrated '
        'blocking.', SQLERRM;
    end;
  end if;

  if v_have_dblink then
    v_claims := harness_rs.aal2(ADMIN_C)::text;

    -- Both sessions authenticate as the SAME fresh AAL2 admin, through the real gate.
    perform dblink_exec('awc1', 'begin');
    perform dblink_exec('awc2', 'begin');
    perform x.r from dblink('awc1', format(
      'select set_config(%L, %L, false) || set_config(%L, %L, false)',
      'request.jwt.claim.sub', ADMIN_C::text, 'request.jwt.claims', v_claims)) as x(r text);
    perform x.r from dblink('awc2', format(
      'select set_config(%L, %L, false) || set_config(%L, %L, false)',
      'request.jwt.claim.sub', ADMIN_C::text, 'request.jwt.claims', v_claims)) as x(r text);

    -- SESSION 1 · calls the door and holds the transaction open. Its locks are live.
    perform x.r from dblink('awc1', format(
      'select public.reissue_owner_safety_notice(%L, %L)::text',
      v_case, 'concurrent operator 1')) as x(r text);

    -- SESSION 2 · the same call, sent ASYNCHRONOUSLY so this session can observe that it does not
    -- return. `dblink_is_busy` = 1 IS the mutual-exclusion evidence: session 2 is parked on session
    -- 1's row lock rather than racing past it.
    perform dblink_send_query('awc2', format(
      'select public.reissue_owner_safety_notice(%L, %L)::text',
      v_case, 'concurrent operator 2'));
    perform pg_sleep(0.75);
    v_busy := dblink_is_busy('awc2');
    if v_busy <> 1 then
      -- Drain and close before failing, so a failure does not strand two backends.
      begin perform dblink_exec('awc1', 'rollback'); exception when others then null; end;
      begin perform * from dblink_get_result('awc2') as x(r text); exception when others then null; end;
      begin perform dblink_exec('awc2', 'rollback'); exception when others then null; end;
      begin perform dblink_disconnect('awc1'); perform dblink_disconnect('awc2'); exception when others then null; end;
      raise exception 'FAIL[C/concurrency]: a second operator''s re-notice did NOT block while the '
        'first held its transaction open (dblink_is_busy=%). The two calls are racing, and the only '
        'thing standing between them is the unique index — which fails the loser with an opaque '
        'unique_violation instead of a named refusal.', v_busy;
    end if;

    -- Session 1 commits. Session 2 unblocks and must REFUSE: the current generation it re-reads is
    -- the successor session 1 just queued.
    perform dblink_exec('awc1', 'commit');
    begin
      perform x.r from dblink_get_result('awc2') as x(r text);
      v_res := 'OK';
    exception when others then
      v_res := 'ERR:' || SQLERRM;
    end;
    begin perform dblink_exec('awc2', 'rollback'); exception when others then null; end;
    perform dblink_disconnect('awc1');
    perform dblink_disconnect('awc2');

    if v_res = 'OK' then
      raise exception 'FAIL[C/concurrency]: BOTH concurrent operators succeeded. Two generation-N+1 '
        'rows now exist for one episode, or one of them silently reused a number.';
    end if;
    if position('notice_still_queued' in v_res) = 0 then
      raise exception 'FAIL[C/concurrency]: the second operator was refused, but not by the policy — '
        'expected notice_still_queued (it re-read the freshly queued successor) and got %. An opaque '
        'unique_violation here means the lock is not doing the work and the index is.', v_res;
    end if;

    raise notice '  ok  11.13B · REAL two-session proof: operator 2 BLOCKED while operator 1 held its '
      'transaction (dblink_is_busy=1), then refused with notice_still_queued once operator 1 '
      'committed. Two genuine backend sessions, not a simulation.';
  end if;

  -- ── THE INVARIANT, WHICHEVER PATH RAN ─────────────────────────────────────────────────────────
  select count(*) into n from public.owner_notice_outbox
   where case_id = v_case and superseded_by is null;
  if n <> 1 then
    raise exception 'FAIL[C/D12]: after the concurrency exercise the episode holds % current '
      'generations, expected exactly 1', n;
  end if;
  select count(*) into n from public.owner_notice_outbox where case_id = v_case;
  select max(generation) into v_gen from public.owner_notice_outbox where case_id = v_case;
  if v_have_dblink then
    if n <> 2 or v_gen <> 2 then
      raise exception 'FAIL[C/D12]: expected exactly two generations numbered 1 and 2 after the '
        'concurrent exercise; found % rows with max generation %', n, v_gen;
    end if;
    select count(distinct generation) into n from public.owner_notice_outbox where case_id = v_case;
    if n <> 2 then
      raise exception 'FAIL[C/D12]: two rows share a generation number — both operators appended';
    end if;
  end if;
  raise notice '  ok  11.13 · exactly one current generation survives the concurrent exercise';
end $rs11b$;

do $$
begin
  raise notice ' ';
  raise notice 'ALL RELEASE SAFETY ASSERTIONS PASSED';
end $$;
