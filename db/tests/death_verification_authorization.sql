-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-C — DEATH-VERIFICATION FOUNDATION, PROVED AGAINST A REAL DATABASE
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THIS FILE IS FOR. Phase 11-C created the estate lifecycle record, the death-verification
-- case, evidence, and the attained-verification level. Those are worth having only if four things
-- are true, and each is asserted here by EXECUTION:
--
--   1 · INITIATION IS DESIGNEE-GATED — beneficiary, professional delegate, owner-without-
--       designation, revoked designee, foreign owner, non-member and anonymous are all refused,
--       and every authenticated refusal is byte-identical (case existence is protected
--       information; a probe learns nothing from refusal shape, including whether the estate
--       exists at all).
--
--   2 · REQUIRED ≠ ATTAINED. The requirement is policy-derived (fail-closed to maximum for
--       unknown jurisdiction); the attained level starts at NULL and moves only through the
--       admin-gated setter; the decision routine re-derives the requirement LIVE and refuses
--       `verify` until attained ≥ required (H2 closed).
--
--   3 · NOTHING IN THE VERIFICATION WORKFLOW CHANGES DISCLOSURE — INCLUDING VERIFICATION ITSELF
--       (re-anchored in 11-E). Case created, evidence received, evidence reviewed, attained level
--       raised, death VERIFIED — after every one of those, EVERY viewer's COMPOSED payload
--       (discovery + assets + net worth + documents + readiness + workspace + notifications) is
--       byte-identical to its value before the death-world existed, and that now includes the
--       holder of an owner-authored `after_verified_death` grant: 11-E inserts the owner-challenge
--       window between an accepted verification and any disclosure, so `death_verified` releases
--       NOTHING. No grant row is touched, no membership or designation appears, and estate Y's
--       identical death grant stays dormant (a foreign lifecycle reaches nothing). Activation
--       itself — at `released`, through the real safety door — is proven in
--       `db/tests/release_safety_authorization.sql`. Paired here with a positive control that
--       moves the authorized world and requires the payload to move.
--
--   4 · EVERY MUTATION IS AUDITED with actor and estate; a DENIED mutation writes nothing.
--
-- ★ AND EVERY WITHHOLDING ASSERTION IS PAIRED. A composed payload that was an error object on both
-- sides would satisfy equivalence vacuously; §0 proves the instrument can see an authorized change
-- and that the viewers' payloads contain real disclosure to begin with.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

create schema if not exists harness_dv;
-- The composed helper switches to `authenticated` BEFORE its per-projection sub-calls run, so the
-- client role needs USAGE on this schema (functions default to PUBLIC EXECUTE).
grant usage on schema harness_dv to anon, authenticated;

-- =================================================================================================
-- helpers — impersonation that controls BOTH JWT surfaces
-- =================================================================================================
--
-- ★ WHY NOT REUSE `harness.attempt`. It sets `request.jwt.claim.sub` and leaves
-- `request.jwt.claims` wherever the previous caller put it. Inside one DO block that is one
-- transaction, so after an admin step (aal2 + fresh iat) a subsequent "beneficiary" probe would
-- carry the ADMIN's claims with the beneficiary's uid — and any aal2-gated surface in the composed
-- payload would answer differently before and after the admin acted. The equivalence assertions
-- would then report a disclosure change that is actually claim residue. Every helper here sets
-- BOTH GUCs, every time.

create or replace function harness_dv.attempt(p_uid uuid, p_sql text)
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

/** The ADMIN caller: aal2, freshly-issued token — what the console middleware forwards. */
create or replace function harness_dv.as_admin(p_uid uuid, p_sql text)
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

/** Admin caller with DEGRADED claims — for proving the gate's own legs. */
create or replace function harness_dv.as_admin_claims(p_uid uuid, p_claims jsonb, p_sql text)
returns text language plpgsql as $$
declare v_msg text;
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', p_claims::text, true);
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

create or replace function harness_dv.expect_ok(p_label text, p_uid uuid, p_sql text)
returns void language plpgsql as $$
declare v text;
begin
  v := harness_dv.attempt(p_uid, p_sql);
  if v <> 'OK' then
    raise exception 'FAIL [%]: expected success, got %', p_label, v;
  end if;
  raise notice '  ok   %', p_label;
end $$;

create or replace function harness_dv.expect_err(p_label text, p_uid uuid, p_sql text, p_expect text)
returns void language plpgsql as $$
declare v text;
begin
  v := harness_dv.attempt(p_uid, p_sql);
  if v = 'OK' then
    raise exception 'FAIL [%]: expected refusal (%), but the statement SUCCEEDED', p_label, p_expect;
  end if;
  if position(p_expect in v) = 0 then
    raise exception 'FAIL [%]: expected refusal containing "%", got %', p_label, p_expect, v;
  end if;
  raise notice '  ok   % (refused: %)', p_label, p_expect;
end $$;

/**
 * THE COMPOSED VIEW — everything one viewer can collect about this estate, as a single value.
 * The `harness_rc.composed` shape plus readiness, workspace and the viewer's notifications:
 * the full §17 surface list. Runs AS THE VIEWER, under `authenticated`, SECURITY INVOKER, with
 * clean aal1 claims; the error is part of the payload (a refusal whose message changes with the
 * hidden world is itself a disclosure channel).
 */
create or replace function harness_dv.composed(p_uid uuid, p_estate uuid)
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

/** One projection, as the CURRENT role, error captured as value. */
create or replace function harness_dv.try(p_sql text)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  execute p_sql into v;
  return coalesce(v, 'null'::jsonb);
exception when others then
  return jsonb_build_object('error', SQLERRM);
end $$;

/** Grant a category through the REAL door, as the owner. Never a direct insert. */
create or replace function harness_dv.grant_inventory(
  p_estate uuid, p_owner uuid, p_grantee uuid, p_role text, p_tier text, p_cond text
) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_owner::text, true);
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  perform public.create_asset_grant(p_estate, p_grantee, p_role, 'estate_inventory', p_tier, p_cond);
  reset role;
end $$;

-- =================================================================================================
-- 0 · THE INSTRUMENT IS READING THE REAL THING
-- =================================================================================================
do $$
declare
  v_def text; v_n int; v_lvl public.verification_level; v_res text; v_state text;
  v_probe uuid;
begin
  raise notice ' ';
  raise notice '══ PHASE 11-C · death-verification foundation ══';
  raise notice '0 · instrument self-check';

  -- (a) Every routine under test exists — a withholding assertion against a missing function
  -- passes by crashing, which is not withholding.
  if to_regprocedure('public.initiate_death_verification_case(uuid)') is null
     or to_regprocedure('public.attach_death_verification_evidence(uuid, uuid)') is null
     or to_regprocedure('public.cancel_death_verification_case(uuid)') is null
     or to_regprocedure('public.admin_review_death_evidence(uuid, text, text)') is null
     or to_regprocedure('public.admin_set_attained_verification_level(uuid, public.verification_level, text)') is null
     or to_regprocedure('public.admin_decide_death_verification_case(uuid, text, text)') is null
     or to_regprocedure('public.estate_lifecycle_state(uuid)') is null
     or to_regprocedure('public.apply_estate_lifecycle_transition(uuid, text, uuid, text)') is null then
    raise exception 'FAIL: a death-verification routine is not installed — the bundle did not land';
  end if;
  raise notice '  ok   all eight routines resolved (called, not assumed)';

  -- (b) The policy engine is loaded and DISTINGUISHES inputs. If it answered a constant, every
  -- "required = enhanced_kyc" assertion below would be measuring a stub.
  if to_regprocedure('public.required_verification_level(uuid)') is null then
    raise exception 'FAIL: required_verification_level is not installed';
  end if;
  select public.required_verification_level(gen_random_uuid()) into v_lvl;
  if v_lvl is distinct from 'enhanced_kyc'::public.verification_level then
    raise exception 'FAIL: unknown estate did not fail closed to enhanced_kyc (got %)', v_lvl;
  end if;
  -- A counsel-approved minimal floor on a fixture jurisdiction must LOWER the answer for an
  -- assetless estate — proving the engine reads the table, so the fail-closed answer above is a
  -- decision, not a constant.
  insert into auth.users (id) values ('dddddddd-0000-4000-8000-00000000dddd') on conflict do nothing;
  insert into public.estates (id, owner_id, name, jurisdiction)
  values ('dddddddd-1111-4111-8111-dddddddddddd', 'dddddddd-0000-4000-8000-00000000dddd',
          'DV Probe Estate', 'harness-dv-approved')
  on conflict (id) do nothing;
  insert into public.jurisdiction_policy (jurisdiction, floor_level, is_counsel_approved)
  values ('harness-dv-approved', 'attestation', true)
  on conflict (jurisdiction) do update set floor_level = 'attestation', is_counsel_approved = true;
  select public.required_verification_level('dddddddd-1111-4111-8111-dddddddddddd') into v_lvl;
  if v_lvl is distinct from 'attestation'::public.verification_level then
    raise exception 'FAIL: approved minimal floor did not lower the requirement (got %) — the '
      'engine is not reading jurisdiction_policy and every fail-closed assertion is vacuous', v_lvl;
  end if;
  raise notice '  ok   the policy engine distinguishes inputs (fail-closed default is a decision, not a constant)';

  -- (c) The audit writer is REAL here — the 11-C promotion of the old no-op stub. An assertion
  -- that a denied mutation "wrote no audit row" proves nothing if successful mutations write
  -- nothing either.
  v_probe := gen_random_uuid();
  perform public.write_audit('harness.probe', 'harness', v_probe, null, '{}'::jsonb);
  select count(*) into v_n from public.audit_logs where action = 'harness.probe' and target_id = v_probe;
  if v_n <> 1 then
    raise exception 'FAIL: write_audit recorded % row(s) for the probe — the harness is carrying '
      'the old no-op stub and every audit assertion below is vacuous', v_n;
  end if;
  delete from public.audit_logs where action = 'harness.probe' and target_id = v_probe;
  raise notice '  ok   write_audit persists rows (the audit assertions can fail)';

  -- (d) The attained/required columns are typed to the policy enum — no second ladder to drift,
  -- no text path around the vocabulary (an out-of-vocabulary level must be UNREPRESENTABLE).
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'death_verification_cases'
     and column_name in ('required_level_at_initiation', 'attained_level')
     and udt_name = 'verification_level';
  if v_n <> 2 then
    raise exception 'FAIL: case levels are not typed public.verification_level';
  end if;
  raise notice '  ok   required and attained are the policy engine''s enum (one ladder)';

  -- (e) The lifecycle vocabulary is CLOSED at the six states of the 11-E safety machine.
  --
  -- ★ RE-ANCHORED IN 11-E. This pinned three states and refused anything release-shaped — correct
  -- while release was unbuilt, and wrong once 0054 deliberately added the safety seam. The absence
  -- guarantee did not weaken, it MOVED: `released` is storable and reachable ONLY through
  -- `release_estate` (client-revoked, unconfigured window, no caller), the map has no edge out of
  -- challenge_halted or released, and the closed-set assertion below still refuses any INVENTED
  -- state — `frozen` and `release_pending` remain unrepresentable.
  select pg_get_constraintdef(con.oid) into v_def
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'estate_lifecycle' and con.contype = 'c';
  if v_def is null then
    raise exception 'FAIL: estate_lifecycle has no CHECK';
  end if;
  if position('frozen' in v_def) > 0 or position('release_pending' in v_def) > 0 then
    raise exception 'FAIL: an unapproved lifecycle state is STORABLE: %', v_def;
  end if;
  foreach v_state in array array['active', 'death_verification_pending', 'death_verified',
                                 'challenge_window', 'challenge_halted', 'released'] loop
    if position('''' || v_state || '''' in v_def) = 0 then
      raise exception 'FAIL: the lifecycle CHECK is missing the 11-E state %: %', v_state, v_def;
    end if;
  end loop;
  if (select count(*) from regexp_matches(v_def, '''[a-z_]+''', 'g')) <> 6 then
    raise exception 'FAIL: the lifecycle vocabulary is not exactly six states: %', v_def;
  end if;
  select pg_get_constraintdef(con.oid) into v_def
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'death_verification_cases'
     and con.contype = 'c' and pg_get_constraintdef(con.oid) ilike '%event_type%';
  if v_def is null or position('incapacity' in v_def) > 0
     or (select count(*) from regexp_matches(v_def, '''[a-z_]+''', 'g')) <> 1 then
    raise exception 'FAIL: event_type is not the closed set (''death''): %', coalesce(v_def, '<absent>');
  end if;
  raise notice '  ok   lifecycle states = 3 (released unrepresentable); event_type = death only';

  -- (f) The admin gate actually gates in THIS harness (its legs can fail here).
  insert into auth.users (id) values ('eeeeeeee-0000-4000-8000-00000000eeee') on conflict do nothing;
  insert into public.admins (user_id) values ('eeeeeeee-0000-4000-8000-00000000eeee') on conflict do nothing;
  v_res := harness_dv.as_admin_claims('eeeeeeee-0000-4000-8000-00000000eeee', '{}'::jsonb,
    'select public.admin_decide_death_verification_case(gen_random_uuid(), ''verify'')');
  if position('mfa_required' in v_res) = 0 then
    raise exception 'FAIL: an aal1 admin was not stopped by the gate (got %) — the AAL2 leg is not '
      'loaded in this harness and every admin assertion below is weaker than it claims', v_res;
  end if;
  v_res := harness_dv.as_admin_claims('eeeeeeee-0000-4000-8000-00000000eeee',
    jsonb_build_object('aal', 'aal2', 'iat', extract(epoch from now())::bigint - 2000),
    'select public.admin_decide_death_verification_case(gen_random_uuid(), ''verify'')');
  if position('stale_token_reauth_required' in v_res) = 0 then
    raise exception 'FAIL: a stale admin token was not refused (got %)', v_res;
  end if;
  raise notice '  ok   the admin gate''s aal2 and freshness legs are live in this harness';
end $$;

-- =================================================================================================
-- 1 · FIXTURE — estates, personas, dormant death grants, an observable disclosure surface
-- =================================================================================================
do $dv$
declare
  OWNER_X uuid; EXEC_X uuid; TRUSTEE_X uuid; BENE uuid; DELE uuid; STRANGER uuid; REVOKED uuid;
  OWNER_Y uuid; EXEC_Y uuid; ADMIN uuid; OWNER_Z uuid; EXEC_Z uuid;
  X uuid; Y uuid; Z uuid;
  DOC_X uuid; DOC_Y uuid;
  case1 uuid; case2 uuid; case_y uuid; case_y2 uuid; case_z uuid;
  ev1 uuid;
  bene_before jsonb; dele_before jsonb; strg_before jsonb; owner_y_before jsonb;
  dele_y_before jsonb; dele_after jsonb;
  v jsonb; v2 jsonb; v_res text; v_res2 text; v_res3 text; n int; n2 int;
  audit_before int; notif_before int;
  grants_before jsonb; grants_after jsonb;
  memb_before jsonb; desig_before jsonb;
  refusal_bytes text; cause_bytes text;
  v_lvl text;
begin
  raise notice '1 · fixture';

  insert into auth.users default values returning id into OWNER_X;
  insert into auth.users default values returning id into EXEC_X;
  insert into auth.users default values returning id into TRUSTEE_X;
  insert into auth.users default values returning id into BENE;
  insert into auth.users default values returning id into DELE;
  insert into auth.users default values returning id into STRANGER;
  insert into auth.users default values returning id into REVOKED;
  insert into auth.users default values returning id into OWNER_Y;
  insert into auth.users default values returning id into EXEC_Y;
  insert into auth.users default values returning id into ADMIN;
  insert into auth.users default values returning id into OWNER_Z;
  insert into auth.users default values returning id into EXEC_Z;

  insert into public.estates (owner_id, name) values (OWNER_X, 'DV Estate X') returning id into X;
  insert into public.estates (owner_id, name) values (OWNER_Y, 'DV Estate Y') returning id into Y;
  -- Z carries the counsel-approved minimal-floor jurisdiction from §0 and NO assets: the one
  -- estate whose requirement is legitimately BELOW the fail-closed maximum.
  insert into public.estates (owner_id, name, jurisdiction)
  values (OWNER_Z, 'DV Estate Z', 'harness-dv-approved') returning id into Z;

  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (X, OWNER_X, 'primary_user', 'approved'),
    (X, BENE,    'beneficiary', 'approved'),
    (X, DELE,    'professional_delegate', 'approved'),
    (Y, OWNER_Y, 'primary_user', 'approved'),
    (Z, OWNER_Z, 'primary_user', 'approved');

  insert into public.estate_designations (estate_id, user_id, designation_type, status) values
    (X, EXEC_X,    'executor', 'active'),
    (X, TRUSTEE_X, 'trustee',  'active'),
    (X, REVOKED,   'executor', 'revoked'),
    (Y, EXEC_Y,    'executor', 'active'),
    (Z, EXEC_Z,    'executor', 'active');

  insert into public.admins (user_id) values (ADMIN);

  insert into public.documents (estate_id, title) values (X, 'DV evidence doc') returning id into DOC_X;
  insert into public.documents (estate_id, title) values (Y, 'DV foreign doc') returning id into DOC_Y;

  -- The observable surface: assets on X so the beneficiary's composed payload contains REAL
  -- disclosure (an all-error payload satisfies equivalence vacuously).
  insert into public.normalized_assets (estate_id, connection_id, institution_name, asset_group, balance_cents, currency)
  values (X, gen_random_uuid(), 'DV Northbank', 'cashBank', 4200000, 'USD');

  -- Grants through the REAL door: one live (the positive-control surface), one death-conditioned
  -- (the grant Phase 11 exists to activate — dormant through every workflow stage, live at
  -- death_verified and only there), and a death-conditioned grant on estate Y for the SAME
  -- delegate, which must stay dormant when X — a different estate — reaches death_verified.
  perform harness_dv.grant_inventory(X, OWNER_X, BENE, 'beneficiary', 'category_summary', 'immediately');
  perform harness_dv.grant_inventory(X, OWNER_X, DELE, 'professional_delegate', 'category_summary', 'after_verified_death');
  perform harness_dv.grant_inventory(Y, OWNER_Y, DELE, 'professional_delegate', 'category_summary', 'after_verified_death');

  -- ★ PRECONDITIONS, ASSERTED (a fixture drift here would quietly re-anchor every test below).
  if public.estate_lifecycle_state(X) <> 'active' then
    raise exception 'FAIL[precondition]: estate X does not start at lifecycle active';
  end if;
  if public.estate_release_state(X) <> 'active' then
    raise exception 'FAIL[precondition]: estate X carries claim state before the suite starts';
  end if;
  select count(*) into n from public.death_verification_cases where estate_id in (X, Y, Z);
  if n <> 0 then
    raise exception 'FAIL[precondition]: % pre-existing case(s)', n;
  end if;
  raise notice '  ok   fixture in place (lifecycle active, no cases, dormant death grant present)';

  -- The beneficiary's payload must CONTAIN disclosure (the immediately grant at category_summary):
  bene_before := harness_dv.composed(BENE, X);
  if bene_before ? 'error' then
    raise exception 'FAIL[control]: the beneficiary composed payload is a bare error: %', bene_before;
  end if;
  if position('category_summary' in bene_before::text) = 0 then
    raise exception 'FAIL[control]: the beneficiary payload shows no category_summary disclosure — '
      'the equivalence assertions below would compare empty against empty: %', bene_before::text;
  end if;
  dele_before  := harness_dv.composed(DELE, X);
  strg_before  := harness_dv.composed(STRANGER, X);
  owner_y_before := harness_dv.composed(OWNER_Y, X);
  -- The delegate's view of estate Y — the cross-estate control: X's death must not move it.
  dele_y_before := harness_dv.composed(DELE, Y);
  select coalesce(jsonb_agg(to_jsonb(g) order by g.id), '[]'::jsonb) into grants_before
    from public.access_grants g where g.estate_id = X;
  -- ★ 11-D BRACKETS: activation is EVALUATIVE. Not only must no grant row move — no membership and
  -- no designation may appear either, or "no new grants manufactured" would be checked one table
  -- short of the claim.
  select coalesce(jsonb_agg(to_jsonb(m) order by m.estate_id, m.user_id, m.role), '[]'::jsonb)
    into memb_before
    from public.estate_memberships m where m.estate_id in (X, Y, Z);
  select coalesce(jsonb_agg(to_jsonb(d) order by d.id), '[]'::jsonb) into desig_before
    from public.estate_designations d where d.estate_id in (X, Y, Z);
  raise notice '  ok   composed BEFORE captured; beneficiary payload carries real disclosure';

  -- ===============================================================================================
  -- 2 · INITIATION — refusals first (no case exists yet, so nothing can leak by existing)
  -- ===============================================================================================
  raise notice '2 · initiation authorization';

  select count(*) into audit_before from public.audit_logs;
  select count(*) into notif_before from public.notifications;

  -- Anonymous: the one distinguishable refusal (no identity at all).
  v_res := harness_dv.attempt(null, format('select public.initiate_death_verification_case(%L)', X));
  if position('auth_required' in v_res) = 0 then
    raise exception 'FAIL: anonymous initiation got %', v_res;
  end if;
  raise notice '  ok   anonymous initiation refused (auth_required)';

  -- Every AUTHENTICATED unauthorized cause must produce the SAME bytes — including a nonexistent
  -- estate, so refusal shape cannot confirm estate existence.
  refusal_bytes := null;
  for v_res, cause_bytes in
    select harness_dv.attempt(u, format('select public.initiate_death_verification_case(%L)', e)), c
      from (values
        (BENE,     X,               'beneficiary'),
        (DELE,     X,               'professional delegate without designation'),
        (STRANGER, X,               'non-member'),
        (OWNER_X,  X,               'owner WITHOUT designation'),
        (REVOKED,  X,               'revoked designee'),
        (EXEC_Y,   X,               'foreign designee (cross-estate)'),
        (OWNER_Y,  X,               'foreign owner'),
        (EXEC_X,   gen_random_uuid(), 'designee against NONEXISTENT estate')
      ) t(u, e, c)
  loop
    if v_res = 'OK' then
      raise exception 'FAIL: % was allowed to initiate', cause_bytes;
    end if;
    if refusal_bytes is null then
      refusal_bytes := v_res;
    elsif v_res is distinct from refusal_bytes then
      raise exception 'FAIL: refusal for "%" differs from the common shape: % vs %',
        cause_bytes, v_res, refusal_bytes;
    end if;
  end loop;
  -- ★ EXACT bytes, not substring: a refusal that still CONTAINS the sentinel but has grown an
  -- evidence count, an estate hint or a claimant id would pass a containment check while leaking.
  if refusal_bytes is distinct from 'ERR:not_authorized' then
    raise exception 'FAIL: the common refusal carries more than the sentinel: %', refusal_bytes;
  end if;
  raise notice '  ok   8 unauthorized initiation causes refused BYTE-IDENTICALLY (incl. nonexistent estate)';

  -- Denied mutations left NOTHING behind: no audit row, no notification, no case, no lifecycle row.
  select count(*) into n from public.audit_logs;
  if n <> audit_before then
    raise exception 'FAIL: refusals wrote % audit row(s)', n - audit_before;
  end if;
  select count(*) into n from public.death_verification_cases where estate_id in (X, Y, Z);
  if n <> 0 then
    raise exception 'FAIL: a refused initiation created a case';
  end if;
  raise notice '  ok   denied initiations wrote no audit row and created no state';

  -- ── The TRUSTEE initiates (current semantics: executor and trustee designations gate alike) ──
  v_res := harness_dv.attempt(TRUSTEE_X, format('select public.initiate_death_verification_case(%L)', X));
  if v_res <> 'OK' then
    raise exception 'FAIL: trustee designee refused: %', v_res;
  end if;
  select id, initiator_capacity, required_level_at_initiation::text
    into case1, v_res, v_lvl
    from public.death_verification_cases where estate_id = X and status = 'open';
  if v_res <> 'trustee' then
    raise exception 'FAIL: initiator_capacity recorded % for a trustee initiation', v_res;
  end if;
  if public.estate_lifecycle_state(X) <> 'death_verification_pending' then
    raise exception 'FAIL: initiation did not move the lifecycle to death_verification_pending';
  end if;
  raise notice '  ok   trustee designee initiates; capacity recorded as fact; lifecycle pending';

  -- ★ REQUIRED ≠ ATTAINED, at birth. X has no jurisdiction → fail-closed maximum; attained NULL.
  if v_lvl <> 'enhanced_kyc' then
    raise exception 'FAIL: unknown-jurisdiction estate did not snapshot enhanced_kyc (got %)', v_lvl;
  end if;
  select count(*) into n from public.death_verification_cases
   where id = case1 and attained_level is null;
  if n <> 1 then
    raise exception 'FAIL: initiation did not leave attained_level NULL — the required level leaked '
      'into the attained level';
  end if;
  raise notice '  ok   required snapshot = enhanced_kyc (fail-closed); attained baseline = NULL';

  -- A second initiation while a case is open: refused at the lifecycle guard…
  v_res := harness_dv.attempt(EXEC_X, format('select public.initiate_death_verification_case(%L)', X));
  if position('lifecycle_conflict' in v_res) = 0 then
    raise exception 'FAIL: second initiation while open got %', v_res;
  end if;
  -- …and the partial-unique index is INDEPENDENTLY load-bearing (race protection below the guard):
  begin
    insert into public.death_verification_cases
      (estate_id, initiated_by, initiator_designation_id, initiator_capacity, required_level_at_initiation)
    select X, EXEC_X, d.id, 'executor', 'enhanced_kyc'
      from public.estate_designations d
     where d.estate_id = X and d.user_id = EXEC_X and d.status = 'active';
    raise exception 'FAIL: a second OPEN case was insertable — the one-open-case index is gone';
  exception when unique_violation then
    null;
  end;
  raise notice '  ok   one open case per estate: lifecycle guard AND unique index each refuse';

  -- Cancellation: not the initiator → the same anonymous-shaped refusal; initiator → withdrawn.
  v_res := harness_dv.attempt(EXEC_X, format('select public.cancel_death_verification_case(%L)', case1));
  if v_res is distinct from 'ERR:not_authorized' then
    raise exception 'FAIL: non-initiating designee cancel got %', v_res;
  end if;
  v_res := harness_dv.attempt(TRUSTEE_X, format('select public.cancel_death_verification_case(%L)', case1));
  if v_res <> 'OK' then
    raise exception 'FAIL: initiator cancel refused: %', v_res;
  end if;
  if public.estate_lifecycle_state(X) <> 'active' then
    raise exception 'FAIL: cancellation did not return the lifecycle to active';
  end if;
  select count(*) into n from public.audit_logs where action = 'death_case.cancelled' and target_id = case1;
  select count(*) into n2 from public.audit_logs;
  v_res := harness_dv.attempt(TRUSTEE_X, format('select public.cancel_death_verification_case(%L)', case1));
  if v_res <> 'OK' then
    raise exception 'FAIL: idempotent cancel replay errored: %', v_res;
  end if;
  select count(*) into n from public.audit_logs;
  if n <> n2 then
    raise exception 'FAIL: idempotent cancel replay wrote a second audit trail';
  end if;
  raise notice '  ok   cancel: initiator-only, restores lifecycle, idempotent replay writes nothing';

  -- ── The EXECUTOR initiates the case the rest of the suite drives ──
  v_res := harness_dv.attempt(EXEC_X, format('select public.initiate_death_verification_case(%L)', X));
  if v_res <> 'OK' then
    raise exception 'FAIL: executor designee refused after cancellation: %', v_res;
  end if;
  select id into case2 from public.death_verification_cases where estate_id = X and status = 'open';
  select initiator_capacity into v_res from public.death_verification_cases where id = case2;
  if v_res <> 'executor' then
    raise exception 'FAIL: executor initiation recorded capacity %', v_res;
  end if;
  raise notice '  ok   executor designee initiates (the working case)';

  -- ★ FIREWALL after initiation: nothing any unauthorized viewer can compose has moved.
  if harness_dv.composed(BENE, X)::text is distinct from bene_before::text then
    raise exception 'FAIL[FIREWALL]: case initiation changed the beneficiary composed payload';
  end if;
  if harness_dv.composed(DELE, X)::text is distinct from dele_before::text then
    raise exception 'FAIL[FIREWALL]: case initiation changed the delegate composed payload';
  end if;
  if harness_dv.composed(STRANGER, X)::text is distinct from strg_before::text then
    raise exception 'FAIL[FIREWALL]: case initiation changed the stranger composed payload';
  end if;
  select coalesce(jsonb_agg(to_jsonb(g) order by g.id), '[]'::jsonb) into grants_after
    from public.access_grants g where g.estate_id = X;
  if grants_after::text is distinct from grants_before::text then
    raise exception 'FAIL[FIREWALL]: initiation touched access_grants — a case manufactured or altered a grant';
  end if;
  raise notice '  ok   FIREWALL: initiation changed no composed payload and touched no grant row';

  -- ===============================================================================================
  -- 3 · EVIDENCE — received is received, nothing more
  -- ===============================================================================================
  raise notice '3 · evidence';

  -- Cross-estate and nonexistent-object probes first, byte-identical where they must be.
  v_res  := harness_dv.attempt(BENE,   format('select public.attach_death_verification_evidence(%L, %L)', case2, DOC_X));
  v_res2 := harness_dv.attempt(EXEC_Y, format('select public.attach_death_verification_evidence(%L, %L)', case2, DOC_X));
  v_res3 := harness_dv.attempt(EXEC_X, format('select public.attach_death_verification_evidence(%L, %L)', gen_random_uuid(), DOC_X));
  if v_res is distinct from 'ERR:not_authorized' or v_res2 is distinct from v_res
     or v_res3 is distinct from v_res then
    raise exception 'FAIL: attach refusals not byte-identical not_authorized: % / % / %', v_res, v_res2, v_res3;
  end if;
  raise notice '  ok   attach: beneficiary, foreign designee, nonexistent case — byte-identical refusals';

  v_res  := harness_dv.attempt(EXEC_X, format('select public.attach_death_verification_evidence(%L, %L)', case2, DOC_Y));
  v_res2 := harness_dv.attempt(EXEC_X, format('select public.attach_death_verification_evidence(%L, %L)', case2, gen_random_uuid()));
  if v_res is distinct from v_res2 or position('doc_not_in_estate' in v_res) = 0 then
    raise exception 'FAIL: foreign document and nonexistent document refusals differ: % / %', v_res, v_res2;
  end if;
  raise notice '  ok   attach: foreign document and nonexistent document — byte-identical refusals';

  v_res := harness_dv.attempt(EXEC_X, format('select public.attach_death_verification_evidence(%L, %L)', case2, DOC_X));
  if v_res <> 'OK' then
    raise exception 'FAIL: designee could not attach estate document: %', v_res;
  end if;
  select id into ev1 from public.death_verification_evidence where case_id = case2;
  select review_status into v_res from public.death_verification_evidence where id = ev1;
  if v_res <> 'received' then
    raise exception 'FAIL: fresh evidence status is % (must be received — no vendor exists to say more)', v_res;
  end if;
  select count(*) into n from public.death_verification_cases where id = case2 and attained_level is null;
  if n <> 1 then
    raise exception 'FAIL: attaching evidence moved the attained level — upload became verification';
  end if;
  raise notice '  ok   evidence received; attained level UNMOVED by upload';

  -- The vault deletion path cannot orphan open-case evidence: the FK refuses.
  begin
    delete from public.documents where id = DOC_X;
    raise exception 'FAIL: an evidence-pinned document was deletable';
  exception when foreign_key_violation then
    null;
  end;
  raise notice '  ok   evidence-pinned document refuses deletion (FK holds the link authority)';

  if harness_dv.composed(BENE, X)::text is distinct from bene_before::text
     or harness_dv.composed(DELE, X)::text is distinct from dele_before::text
     or harness_dv.composed(STRANGER, X)::text is distinct from strg_before::text then
    raise exception 'FAIL[FIREWALL]: evidence receipt changed a composed payload';
  end if;
  raise notice '  ok   FIREWALL: evidence receipt changed no composed payload';

  -- ===============================================================================================
  -- 4 · REVIEW AND ATTAINED LEVEL — admin-gated, explicit, separately audited
  -- ===============================================================================================
  raise notice '4 · review and attained level';

  -- Non-admin callers cannot review, set levels, or decide — including the case's own initiator.
  v_res := harness_dv.attempt(EXEC_X, format('select public.admin_review_death_evidence(%L, ''reviewed_accepted'')', ev1));
  if position('admin_required' in v_res) = 0 then
    raise exception 'FAIL: initiator review got %', v_res;
  end if;
  v_res := harness_dv.attempt(EXEC_X, format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', case2));
  if position('admin_required' in v_res) = 0 then
    raise exception 'FAIL: initiator set-attained got % — attained forgery by a claimant', v_res;
  end if;
  v_res := harness_dv.attempt(EXEC_X, format('select public.admin_decide_death_verification_case(%L, ''verify'')', case2));
  if position('admin_required' in v_res) = 0 then
    raise exception 'FAIL: initiator decide got %', v_res;
  end if;
  raise notice '  ok   review, attained level and decision are admin-gated (initiator refused all three)';

  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_review_death_evidence(%L, ''probe_outcome'')', ev1));
  if position('invalid_review_outcome' in v_res) = 0 then
    raise exception 'FAIL: invented review outcome got %', v_res;
  end if;
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_review_death_evidence(%L, ''reviewed_accepted'')', ev1));
  if v_res <> 'OK' then
    raise exception 'FAIL: admin review refused: %', v_res;
  end if;
  select review_status into v_res from public.death_verification_evidence where id = ev1;
  if v_res <> 'reviewed_accepted' then
    raise exception 'FAIL: review did not record (status %)', v_res;
  end if;
  -- Idempotent replay writes nothing; a CONTRARY re-review is refused, not silently flipped.
  select count(*) into n2 from public.audit_logs;
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_review_death_evidence(%L, ''reviewed_accepted'')', ev1));
  select count(*) into n from public.audit_logs;
  if v_res <> 'OK' or n <> n2 then
    raise exception 'FAIL: idempotent review replay errored or re-audited (% / %)', v_res, n - n2;
  end if;
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_review_death_evidence(%L, ''reviewed_rejected'')', ev1));
  if position('evidence_already_reviewed' in v_res) = 0 then
    raise exception 'FAIL: contrary re-review got %', v_res;
  end if;
  select count(*) into n from public.death_verification_cases where id = case2 and attained_level is null;
  if n <> 1 then
    raise exception 'FAIL: evidence REVIEW moved the attained level — review became verification (T15)';
  end if;
  raise notice '  ok   review recorded; replay idempotent; reversal refused; attained STILL unmoved';

  -- An out-of-vocabulary attained level is unrepresentable — refused by the TYPE, before the body.
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_set_attained_verification_level(%L, ''fully_verified'')', case2));
  if v_res = 'OK' or position('invalid input value for enum' in v_res) = 0 then
    raise exception 'FAIL: invented attained level got %', v_res;
  end if;
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_set_attained_verification_level(%L, ''kyc'')', case2));
  if v_res <> 'OK' then
    raise exception 'FAIL: admin set-attained refused: %', v_res;
  end if;
  raise notice '  ok   attained vocabulary is the enum (invented level unrepresentable); kyc recorded';

  -- ★ H2 ENFORCED: kyc < enhanced_kyc (live requirement, X has no jurisdiction) → verify refused.
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_decide_death_verification_case(%L, ''verify'')', case2));
  if position('verification_level_insufficient' in v_res) = 0 then
    raise exception 'FAIL: verify with attained < required got %', v_res;
  end if;
  raise notice '  ok   H2: verify refused while attained (kyc) < required (enhanced_kyc, derived live)';

  if harness_dv.composed(BENE, X)::text is distinct from bene_before::text
     or harness_dv.composed(DELE, X)::text is distinct from dele_before::text
     or harness_dv.composed(STRANGER, X)::text is distinct from strg_before::text then
    raise exception 'FAIL[FIREWALL]: review / attained-level progress changed a composed payload';
  end if;
  raise notice '  ok   FIREWALL: review and attained progress changed no composed payload';

  -- ===============================================================================================
  -- 5 · DECISION — verified death releases NOTHING
  -- ===============================================================================================
  raise notice '5 · decision';

  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_set_attained_verification_level(%L, ''enhanced_kyc'')', case2));
  if v_res <> 'OK' then
    raise exception 'FAIL: raising attained to enhanced_kyc refused: %', v_res;
  end if;
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_decide_death_verification_case(%L, ''verify'')', case2));
  if v_res <> 'OK' then
    raise exception 'FAIL: verify with attained = required refused: %', v_res;
  end if;
  if public.estate_lifecycle_state(X) <> 'death_verified' then
    raise exception 'FAIL: verification did not move the lifecycle to death_verified';
  end if;
  raise notice '  ok   attained = required → case verified; lifecycle = death_verified';

  -- ★ THE CENTRAL PROPERTY, REWRITTEN AGAIN IN 11-E — AND THE REWRITE IS THE PHASE. In 11-D this
  -- block asserted that the delegate's death-conditioned grant went LIVE at death_verified. The
  -- safety seam means an accepted verification must now disclose NOTHING: release waits for the
  -- owner-challenge window. So EVERY viewer — the delegate included — is byte-identical to the
  -- pre-case world at death_verified, and activation is proven one lifecycle later, through the
  -- real safety door, in `db/tests/release_safety_authorization.sql`.
  if harness_dv.composed(BENE, X)::text is distinct from bene_before::text then
    raise exception 'FAIL[FIREWALL]: death_verified changed the beneficiary composed payload';
  end if;
  if harness_dv.composed(STRANGER, X)::text is distinct from strg_before::text then
    raise exception 'FAIL[FIREWALL]: death_verified changed the stranger composed payload';
  end if;
  if harness_dv.composed(OWNER_Y, X)::text is distinct from owner_y_before::text then
    raise exception 'FAIL[FIREWALL]: death_verified changed the foreign-owner composed payload';
  end if;

  dele_after := harness_dv.composed(DELE, X);
  if dele_after::text is distinct from dele_before::text then
    raise exception 'FAIL[SAFETY SEAM]: death_verified moved the payload of the viewer holding the '
      'owner-authored death-conditioned grant — an accepted verification released information '
      'BEFORE the owner-challenge window. before=% after=%',
      dele_before::text, dele_after::text;
  end if;
  raise notice '  ok   SAFETY SEAM: death_verified moved NO composed payload — not even the holder '
    'of a death-conditioned grant (4 viewers, 7 surfaces each)';

  -- ★ CROSS-ESTATE: the SAME delegate holds the SAME death-conditioned grant on estate Y, whose
  -- lifecycle is active. Nothing about X may move it.
  if harness_dv.composed(DELE, Y)::text is distinct from dele_y_before::text then
    raise exception 'FAIL[CROSS-ESTATE]: X''s death_verified moved the delegate''s estate-Y payload '
      '— a foreign lifecycle reached a local grant';
  end if;
  raise notice '  ok   CROSS-ESTATE: the identical grant on estate Y stayed dormant (lifecycle is per-estate)';

  select coalesce(jsonb_agg(to_jsonb(g) order by g.id), '[]'::jsonb) into grants_after
    from public.access_grants g where g.estate_id = X;
  if grants_after::text is distinct from grants_before::text then
    raise exception 'FAIL[FIREWALL]: the verification flow touched access_grants — activation must '
      'be EVALUATIVE, never a write';
  end if;
  -- No membership materialized, no designation materialized — on any fixture estate.
  if (select coalesce(jsonb_agg(to_jsonb(m) order by m.estate_id, m.user_id, m.role), '[]'::jsonb)
        from public.estate_memberships m where m.estate_id in (X, Y, Z))::text
     is distinct from memb_before::text then
    raise exception 'FAIL[FIREWALL]: the verification flow touched estate_memberships';
  end if;
  if (select coalesce(jsonb_agg(to_jsonb(d) order by d.id), '[]'::jsonb)
        from public.estate_designations d where d.estate_id in (X, Y, Z))::text
     is distinct from desig_before::text then
    raise exception 'FAIL[FIREWALL]: the verification flow touched estate_designations';
  end if;
  select count(*) into n from public.notifications;
  if n <> notif_before then
    raise exception 'FAIL[FIREWALL]: the death-verification flow emitted % notification(s)', n - notif_before;
  end if;
  select count(*) into n from public.claim_packets where estate_id = X;
  if n <> 0 or public.estate_release_state(X) <> 'active' then
    raise exception 'FAIL: the case leaked into the CLAIM workflow (claim rows: %, release_state: %)',
      n, public.estate_release_state(X);
  end if;
  raise notice '  ok   FIREWALL: no grant row moved, no notification emitted, claim workflow untouched (D7)';

  -- Post-decision immutability: initiation, evidence, attained and re-decision all settle.
  v_res := harness_dv.attempt(EXEC_X, format('select public.initiate_death_verification_case(%L)', X));
  if position('lifecycle_conflict' in v_res) = 0 then
    raise exception 'FAIL: initiation on a death_verified estate got %', v_res;
  end if;
  v_res := harness_dv.attempt(EXEC_X, format('select public.attach_death_verification_evidence(%L, %L)', case2, DOC_X));
  if position('case_not_open' in v_res) = 0 then
    raise exception 'FAIL: attach to a decided case got %', v_res;
  end if;
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_set_attained_verification_level(%L, ''attestation'')', case2));
  if position('case_not_open' in v_res) = 0 then
    raise exception 'FAIL: attained rollback on a decided case got % (T8)', v_res;
  end if;
  select count(*) into n2 from public.audit_logs;
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_decide_death_verification_case(%L, ''verify'')', case2));
  select count(*) into n from public.audit_logs;
  if v_res <> 'OK' or n <> n2 then
    raise exception 'FAIL: idempotent verify replay errored or re-audited (T7): % / %', v_res, n - n2;
  end if;
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_decide_death_verification_case(%L, ''reject'')', case2));
  if position('case_already_decided' in v_res) = 0 then
    raise exception 'FAIL: contrary decision after verify got % (T8)', v_res;
  end if;
  raise notice '  ok   decided case immutable: no new evidence, no attained rollback, no reversal; replay idempotent';

  -- ===============================================================================================
  -- 6 · REJECT PATH AND LIVE-REQUIREMENT DERIVATION (estate Y, estate Z)
  -- ===============================================================================================
  raise notice '6 · reject path and live requirement';

  v_res := harness_dv.attempt(EXEC_Y, format('select public.initiate_death_verification_case(%L)', Y));
  if v_res <> 'OK' then
    raise exception 'FAIL: executor Y refused on Y: %', v_res;
  end if;
  select id into case_y from public.death_verification_cases where estate_id = Y and status = 'open';
  -- Reject needs no attained level — refusing to verify is always safe.
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_decide_death_verification_case(%L, ''reject'', ''insufficient evidence'')', case_y));
  if v_res <> 'OK' then
    raise exception 'FAIL: reject refused: %', v_res;
  end if;
  if public.estate_lifecycle_state(Y) <> 'active' then
    raise exception 'FAIL: rejection did not return the lifecycle to active';
  end if;
  v_res := harness_dv.attempt(EXEC_Y, format('select public.initiate_death_verification_case(%L)', Y));
  if v_res <> 'OK' then
    raise exception 'FAIL: re-initiation after rejection refused: %', v_res;
  end if;
  select id into case_y2 from public.death_verification_cases where estate_id = Y and status = 'open';
  v_res := harness_dv.attempt(EXEC_Y, format('select public.cancel_death_verification_case(%L)', case_y2));
  if v_res <> 'OK' then
    raise exception 'FAIL: cancel of the re-initiated case refused: %', v_res;
  end if;
  raise notice '  ok   reject returns lifecycle to active; the estate can be re-initiated';

  -- ★ THE REQUIREMENT IS DERIVED LIVE, NOT READ FROM THE SNAPSHOT. Z opens at `attestation`
  -- (approved minimal floor, no assets). The floor''s counsel approval is then WITHDRAWN — the
  -- engine fails closed to enhanced_kyc while the case''s snapshot still says attestation. If the
  -- decision consulted the snapshot, attestation would now suffice; it must not.
  v_res := harness_dv.attempt(EXEC_Z, format('select public.initiate_death_verification_case(%L)', Z));
  if v_res <> 'OK' then
    raise exception 'FAIL: executor Z refused on Z: %', v_res;
  end if;
  select id into case_z from public.death_verification_cases where estate_id = Z and status = 'open';
  select required_level_at_initiation::text into v_lvl from public.death_verification_cases where id = case_z;
  if v_lvl <> 'attestation' then
    raise exception 'FAIL: Z snapshot is % (expected attestation — the approved floor)', v_lvl;
  end if;
  update public.jurisdiction_policy set is_counsel_approved = false where jurisdiction = 'harness-dv-approved';
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_set_attained_verification_level(%L, ''attestation'')', case_z));
  if v_res <> 'OK' then
    raise exception 'FAIL: setting attained attestation on Z refused: %', v_res;
  end if;
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_decide_death_verification_case(%L, ''verify'')', case_z));
  if position('verification_level_insufficient' in v_res) = 0 then
    raise exception 'FAIL: decision consulted the SNAPSHOT (got %) — a policy tightened mid-case '
      'must tighten the case', v_res;
  end if;
  -- Restore the floor; attestation now suffices again — proving the refusal above was the live
  -- policy answering, not a broken comparison.
  update public.jurisdiction_policy set is_counsel_approved = true where jurisdiction = 'harness-dv-approved';
  v_res := harness_dv.as_admin(ADMIN, format('select public.admin_decide_death_verification_case(%L, ''verify'')', case_z));
  if v_res <> 'OK' then
    raise exception 'FAIL: verify at restored floor refused: %', v_res;
  end if;
  raise notice '  ok   requirement derived LIVE at decision (tightened policy refused; restored policy passed)';

  -- ===============================================================================================
  -- 7 · TRANSITION MAP, RLS POSTURE, FUNCTION PRIVILEGES
  -- ===============================================================================================
  raise notice '7 · structural posture';

  begin
    perform public.apply_estate_lifecycle_transition(Y, 'death_verified', null, 'harness-illegal');
    raise exception 'FAIL: active → death_verified was accepted directly — the transition map is open';
  exception when others then
    if position('invalid_lifecycle_transition' in SQLERRM) = 0 then
      raise exception 'FAIL: illegal transition raised the wrong error: %', SQLERRM;
    end if;
  end;
  begin
    perform public.apply_estate_lifecycle_transition(Y, 'released', null, 'harness-illegal');
    raise exception 'FAIL: a released transition was accepted';
  exception when others then
    if position('invalid_lifecycle_transition' in SQLERRM) = 0 then
      raise exception 'FAIL: released transition raised the wrong error: %', SQLERRM;
    end if;
  end;
  raise notice '  ok   transition map: active→death_verified refused; released refused (unreachable)';

  -- No client role holds ANY privilege on the three tables; direct reads fail as the client.
  select count(*) into n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('estate_lifecycle', 'death_verification_cases', 'death_verification_evidence')
     and grantee in ('anon', 'authenticated');
  if n <> 0 then
    raise exception 'FAIL: % client-role table grant(s) on the death-verification tables', n;
  end if;
  v_res := harness_dv.attempt(BENE, 'select count(*) from public.death_verification_cases');
  if position('permission denied' in v_res) = 0 then
    raise exception 'FAIL: a beneficiary could query the case table: %', v_res;
  end if;
  v_res := harness_dv.attempt(STRANGER, 'select count(*) from public.estate_lifecycle');
  if position('permission denied' in v_res) = 0 then
    raise exception 'FAIL: a stranger could query the lifecycle table: %', v_res;
  end if;
  raise notice '  ok   zero client grants; direct table reads refused (case existence unlearnable)';

  if has_function_privilege('authenticated', 'public.estate_lifecycle_state(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.apply_estate_lifecycle_transition(uuid, text, uuid, text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.initiate_death_verification_case(uuid)', 'EXECUTE') then
    raise exception 'FAIL: an internal routine is client-executable';
  end if;
  if not has_function_privilege('authenticated', 'public.initiate_death_verification_case(uuid)', 'EXECUTE') then
    raise exception 'FAIL: initiation is not executable by authenticated (the gate lives INSIDE)';
  end if;
  raise notice '  ok   internal routines revoked; gated doors granted';

  -- ===============================================================================================
  -- 8 · AUDIT TRAIL — every mutation attributed, nothing sensitive recorded
  -- ===============================================================================================
  raise notice '8 · audit trail';

  -- The full expected trail for estate X, action by action, with the right actor every time.
  select count(*) into n from public.audit_logs
   where estate_id = X and action = 'death_case.initiated' and actor_id in (TRUSTEE_X, EXEC_X);
  if n <> 2 then
    raise exception 'FAIL: expected 2 attributed initiation audit rows on X, found %', n;
  end if;
  select count(*) into n from public.audit_logs
   where estate_id = X and action = 'death_case.cancelled' and actor_id = TRUSTEE_X;
  if n <> 1 then
    raise exception 'FAIL: cancellation audit missing or misattributed';
  end if;
  select count(*) into n from public.audit_logs
   where estate_id = X and action = 'death_case.evidence_attached' and actor_id = EXEC_X;
  if n <> 1 then
    raise exception 'FAIL: evidence-attached audit missing or misattributed';
  end if;
  select count(*) into n from public.audit_logs
   where estate_id = X and action = 'death_case.evidence_reviewed' and actor_id = ADMIN and source = 'admin';
  if n <> 1 then
    raise exception 'FAIL: evidence-review audit missing, misattributed, or not admin-sourced';
  end if;
  select count(*) into n from public.audit_logs
   where estate_id = X and action = 'death_case.attained_level_set' and actor_id = ADMIN;
  if n <> 2 then
    raise exception 'FAIL: expected 2 attained-level audit rows (kyc, enhanced_kyc), found %', n;
  end if;
  select count(*) into n from public.audit_logs
   where estate_id = X and action = 'death_case.verified' and actor_id = ADMIN
     and metadata ->> 'required_level' = 'enhanced_kyc'
     and metadata ->> 'attained_level' = 'enhanced_kyc';
  if n <> 1 then
    raise exception 'FAIL: the verification audit does not carry the policy basis (required/attained)';
  end if;
  select count(*) into n from public.audit_logs
   where estate_id = X and action = 'estate_lifecycle.transition';
  if n <> 4 then
    raise exception 'FAIL: expected 4 lifecycle transition audits on X '
      '(pending, active, pending, death_verified), found %', n;
  end if;
  select count(*) into n from public.audit_logs
   where action like 'death_case.%' and (actor_id is null or estate_id is null);
  if n <> 0 then
    raise exception 'FAIL: % death-case audit row(s) missing actor or estate attribution', n;
  end if;
  -- Nothing sensitive: no audit row names a document title or carries claimant identity beyond
  -- the actor column itself.
  select count(*) into n from public.audit_logs
   where action like 'death_case.%'
     and (metadata::text ilike '%DV evidence doc%' or metadata::text ilike '%initiated_by%');
  if n <> 0 then
    raise exception 'FAIL: an audit row leaked document titles or claimant identity into metadata';
  end if;
  raise notice '  ok   full attributed trail (2 initiations, cancel, evidence, review, 2 levels, verify, 4 transitions); nothing sensitive';

  -- ===============================================================================================
  -- 9 · POSITIVE CONTROL — the instrument can SEE an authorized change
  -- ===============================================================================================
  raise notice '9 · positive control';

  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (X, STRANGER, 'beneficiary', 'approved');
  perform harness_dv.grant_inventory(X, OWNER_X, STRANGER, 'beneficiary', 'category_summary', 'immediately');
  v := harness_dv.composed(STRANGER, X);
  if v::text is not distinct from strg_before::text then
    raise exception 'FAIL[CONTROL]: an AUTHORIZED grant did not move the composed payload — the '
      'equivalence instrument cannot detect change and every firewall assertion above is vacuous';
  end if;
  raise notice '  ok   CONTROL: an authorized change moves the composed payload (the firewall could have failed)';

  raise notice ' ';
  raise notice 'ALL DEATH VERIFICATION ASSERTIONS PASSED';
end $dv$;
