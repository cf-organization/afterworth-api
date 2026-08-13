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
--       idempotent, terminal, and WINS THE EXACT BOUNDARY TIE;
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
     or to_regprocedure('public.release_estate(uuid)') is null
     or to_regprocedure('public.get_owner_safety_status(uuid)') is null
     or to_regprocedure('public.challenge_window_duration()') is null then
    raise exception 'FAIL: a Phase 11-E safety routine is not installed — the bundle did not land';
  end if;
  raise notice '  ok   all five safety routines resolved (called, not assumed)';

  -- (b) THE RELEASE LEVER IS UNREACHABLE BY CLIENTS, and the challenge IS reachable. If these were
  -- reversed, every assertion below would describe a system nobody can operate safely.
  if has_function_privilege('authenticated', 'public.release_estate(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.release_estate(uuid)', 'EXECUTE') then
    raise exception 'FAIL: release_estate is client-executable — the release actor is an explicitly '
      'deferred product decision and no client may pull that lever';
  end if;
  if has_function_privilege('authenticated', 'public.challenge_window_duration()', 'EXECUTE') then
    raise exception 'FAIL: the safety clock is client-readable';
  end if;
  if not has_function_privilege('authenticated', 'public.challenge_death_process(uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.get_owner_safety_status(uuid)', 'EXECUTE') then
    raise exception 'FAIL: the owner challenge or its status read is NOT client-executable — the '
      'owner cannot reach the one action that protects them';
  end if;
  raise notice '  ok   release lever revoked from clients; owner challenge + status reachable';

  -- (c) THE WINDOW DURATION SHIPS UNCONFIGURED. A seeded default would be a product decision taken
  -- by a migration, and it would make the "not configured" refusal below untestable.
  select count(*) into v_n from public.release_safety_policy;
  if v_n <> 0 then
    raise exception 'FAIL: release_safety_policy is seeded (% row(s)) — the window duration must '
      'arrive by explicit operator action', v_n;
  end if;
  if public.challenge_window_duration() is not null then
    raise exception 'FAIL: an unconfigured window answered a duration';
  end if;
  raise notice '  ok   the window duration is UNCONFIGURED (fail-closed: no window can elapse)';

  -- (d) The lifecycle vocabulary is exactly the six states, and the predicate agrees with it.
  if (select count(*) from regexp_matches(
        (select pg_get_constraintdef(con.oid)
           from pg_constraint con
           join pg_class rel on rel.oid = con.conrelid
           join pg_namespace nsp on nsp.oid = rel.relnamespace
          where nsp.nspname = 'public' and rel.relname = 'estate_lifecycle' and con.contype = 'c'
            and pg_get_constraintdef(con.oid) ilike '%state%'),
        '''[a-z_]+''', 'g')) <> 6 then
    raise exception 'FAIL: the lifecycle CHECK is not exactly six states';
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
  OWNER_S uuid; EXEC_S uuid; DELE_S uuid; STRG_S uuid; ADMIN_S uuid; OWNER_F uuid;
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
  insert into auth.users default values returning id into OWNER_F;
  insert into public.estates (owner_id, name) values (OWNER_S, 'RS Estate S') returning id into S;
  insert into public.estates (owner_id, name) values (OWNER_F, 'RS Estate F') returning id into F;
  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (S, OWNER_S, 'primary_user', 'approved'),
    (S, DELE_S,  'professional_delegate', 'approved'),
    (F, OWNER_F, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EXEC_S, 'executor', 'active');
  insert into public.admins (user_id) values (ADMIN_S);

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
  begin
    perform public.release_estate(S);
    raise exception 'FAIL: release_estate succeeded from death_verified — the window was skipped';
  exception when others then
    if position('invalid_release_state' in SQLERRM) = 0 then
      raise exception 'FAIL: release from death_verified raised the wrong error: %', SQLERRM;
    end if;
  end;
  raise notice '  ok   release refuses from death_verified (invalid_release_state)';

  -- ── STAGE D · challenge_window (real door: admin opens; the owner notice must COMMIT) ─────────
  select count(*) into n from public.notifications where user_id = OWNER_S and estate_id = S;
  if n <> 0 then raise exception 'FAIL[D precondition]: the owner already had notifications'; end if;

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

  -- ── RELEASE IS REFUSED: unconfigured window (fail-closed) ─────────────────────────────────────
  begin
    perform public.release_estate(S);
    raise exception 'FAIL: release succeeded with NO configured window duration';
  exception when others then
    if position('release_window_not_configured' in SQLERRM) = 0 then
      raise exception 'FAIL: unconfigured release raised the wrong error: %', SQLERRM;
    end if;
  end;
  raise notice '  ok   release refuses while the window duration is unconfigured';

  -- Configure a window (the operator act, simulated here).
  insert into public.release_safety_policy (id, challenge_window) values (true, interval '7 days')
  on conflict (id) do update set challenge_window = excluded.challenge_window;

  -- ── RELEASE IS REFUSED: window not elapsed ────────────────────────────────────────────────────
  begin
    perform public.release_estate(S);
    raise exception 'FAIL: release succeeded before the window elapsed';
  exception when others then
    if position('release_window_not_elapsed' in SQLERRM) = 0 then
      raise exception 'FAIL: premature release raised the wrong error: %', SQLERRM;
    end if;
  end;
  raise notice '  ok   release refuses before the window elapses';

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

  perform public.release_estate(S);
  if public.estate_lifecycle_state(S) <> 'released' then
    raise exception 'FAIL[F]: release did not reach the released lifecycle';
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
  if public.release_estate(S) <> 'released' then
    raise exception 'FAIL: idempotent release replay did not return released';
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
  begin
    perform public.release_estate(C);
    raise exception 'FAIL: release succeeded from challenge_halted';
  exception when others then
    if position('invalid_release_state' in SQLERRM) = 0 then
      raise exception 'FAIL: release from challenge_halted raised the wrong error: %', SQLERRM;
    end if;
  end;
  -- No existing routine reopens it: every outbound transition is refused by the closed map.
  for v_res in select unnest(array['active', 'death_verification_pending', 'death_verified',
                                   'challenge_window', 'released']) loop
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
  OWNER_T uuid; EXEC_T uuid; ADMIN_T uuid; T1 uuid; T2 uuid;
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
  insert into public.admins (user_id) values (ADMIN_T) on conflict do nothing;

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
        begin
          perform public.release_estate(E);
          raise exception 'FAIL[TIE]: release SUCCEEDED at the exact boundary instant — the window '
            'must be STRICTLY elapsed, and a tie belongs to the owner';
        exception when others then
          if position('release_window_not_elapsed' in SQLERRM) = 0 then
            raise exception 'FAIL[TIE]: boundary release raised the wrong error: %', SQLERRM;
          end if;
        end;
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
        begin
          perform public.release_estate(E);
          raise exception 'FAIL[TIE]: release SUCCEEDED after an owner challenge';
        exception when others then
          if position('invalid_release_state' in SQLERRM) = 0 then
            raise exception 'FAIL[TIE]: post-challenge release raised the wrong error: %', SQLERRM;
          end if;
        end;
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
    perform harness_rs.as_admin(ADMIN_T, format('select public.begin_challenge_window(%L)', E2));
    update public.estate_lifecycle
       set owner_notified_at = now() - v_dur - interval '1 second'
     where estate_id = E2;
    perform public.release_estate(E2);
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
  OWNER_R uuid; EXEC_R uuid; ADMIN_R uuid; R1 uuid;
  v_case uuid; v_res text;
begin
  raise notice '4 · release guards';

  insert into auth.users default values returning id into OWNER_R;
  insert into auth.users default values returning id into EXEC_R;
  insert into auth.users default values returning id into ADMIN_R;
  insert into public.admins (user_id) values (ADMIN_R) on conflict do nothing;
  insert into public.estates (owner_id, name) values (OWNER_R, 'RS Estate R') returning id into R1;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (R1, OWNER_R, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (R1, EXEC_R, 'executor', 'active');

  -- Release from `active` (no lifecycle row at all) refuses.
  begin
    perform public.release_estate(R1);
    raise exception 'FAIL: release succeeded on an estate with no death process';
  exception when others then
    if position('invalid_release_state' in SQLERRM) = 0 then
      raise exception 'FAIL: release from active raised the wrong error: %', SQLERRM;
    end if;
  end;

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
  v_res := harness_rs.as_admin(ADMIN_R, format('select public.begin_challenge_window(%L)', R1));
  if v_res <> 'OK' then raise exception 'FAIL: window open refused: %', v_res; end if;
  update public.estate_lifecycle
     set owner_notified_at = null, safety_notification_id = null
   where estate_id = R1;
  begin
    perform public.release_estate(R1);
    raise exception 'FAIL: release succeeded with NO committed owner notice';
  exception when others then
    if position('owner_not_notified' in SQLERRM) = 0 then
      raise exception 'FAIL: un-notified release raised the wrong error: %', SQLERRM;
    end if;
  end;
  raise notice '  ok   release refuses without a committed owner safety notice';

  -- Restore the notice and elapse it, then delete the verified case: release must still refuse.
  update public.estate_lifecycle
     set owner_notified_at = now() - interval '30 days',
         safety_notification_id = gen_random_uuid()
   where estate_id = R1;
  update public.death_verification_cases set status = 'rejected' where estate_id = R1;
  begin
    perform public.release_estate(R1);
    raise exception 'FAIL: release succeeded with no VERIFIED case';
  exception when others then
    if position('no_verified_case' in SQLERRM) = 0 then
      raise exception 'FAIL: no-verified-case release raised the wrong error: %', SQLERRM;
    end if;
  end;
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
  begin
    perform public.release_estate(W);
    raise exception 'FAIL: release succeeded from a merely-pending, evidenced, attained estate';
  exception when others then
    if position('invalid_release_state' in SQLERRM) = 0 then
      raise exception 'FAIL: firewall release raised the wrong error: %', SQLERRM;
    end if;
  end;
  raise notice '  ok   claim approval, accepted evidence and sufficient attainment each release NOTHING';

  delete from public.claim_packets where estate_id = W;
end $rs5$;

do $$
begin
  raise notice ' ';
  raise notice 'ALL RELEASE SAFETY ASSERTIONS PASSED';
end $$;
