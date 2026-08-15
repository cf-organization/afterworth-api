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
  insert into public.owner_notice_outbox
    (estate_id, user_id, channel, recipient, notice_kind, status)
  values (U, OWNER_U, 'email', 'rs-owner-u@example.invalid', 'death_process.window_opened', 'processing');

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

do $$
begin
  raise notice ' ';
  raise notice 'ALL RELEASE SAFETY ASSERTIONS PASSED';
end $$;
