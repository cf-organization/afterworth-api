-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-H — FIDUCIARY CAPACITY IS NOT A DISCLOSURE TIER
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THE PHASE'S PRIMARY QUESTION, MADE EXECUTABLE. Phase 11-H asks: can fiduciary WORKFLOW authority
-- exist without collapsing into DISCLOSURE authority? That is not a design intention to be asserted
-- in a document — it is a property of the deployed authorization model, and this file measures it.
--
-- ★ THE PROOF IS A DIFFERENCE, NOT A SNAPSHOT. Asserting "an executor sees nothing" is weak: it
-- passes on an estate where there is nothing to see, and passes just as well if the projection is
-- broken. Instead this file takes ONE person, composes everything they can read, then adds a
-- fiduciary designation to that same person and composes again:
--
--     DISCLOSURE  must be BYTE-IDENTICAL across that change — capacity adds no visibility.
--     WORKFLOW    must CHANGE from refused to allowed — capacity is not inert either.
--
-- Both halves are required. Without the second, a model that simply ignored designations entirely
-- would pass, and "capacity grants nothing" would be true only because capacity does nothing.
--
-- ★ EVERY EQUIVALENCE IS PAIRED WITH A POSITIVE CONTROL. §0 proves the composed payload MOVES when
-- a real grant is added, before any "it did not move" claim is believed. An equivalence assertion on
-- an instrument that cannot observe change is the vacuous-audit failure recorded in AGENTS.md.
--
-- ★ TRUSTEE IS NOT A SECOND CAPACITY IN THIS SYSTEM, AND THAT IS PINNED RATHER THAN ASSUMED.
-- `is_estate_executor` resolves `designation_type in ('executor','trustee')`, so the two designations
-- are ONE capacity wearing two labels. §3 asserts they are interchangeable at every surface, so that
-- a future contributor who assumes "trustee is weaker than executor" is contradicted by a test
-- rather than discovering it in production.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

create schema if not exists harness_fc;
grant usage on schema harness_fc to anon, authenticated;

/**
 * The composed READ surface for one viewer — every disclosure route a fiduciary might be imagined
 * to reach. Composed as one value so the comparison is over the whole surface, not a field someone
 * remembered to check.
 */
create or replace function harness_fc.composed(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  select jsonb_build_object(
    'discovery',  harness_dv.try(format('select public.get_estate_discovery(%L)', p_estate)),
    'assets',     harness_dv.try(format(
      'select coalesce(jsonb_agg(to_jsonb(a) order by a.id), ''[]''::jsonb) from public.list_estate_assets(%L) a', p_estate)),
    'net_worth',  harness_dv.try(format(
      'select coalesce(jsonb_agg(to_jsonb(w)), ''[]''::jsonb) from public.get_estate_net_worth(%L) w', p_estate)),
    'workspace',  harness_dv.try(format('select public.get_professional_workspace(%L)', p_estate)),
    'readiness',  harness_dv.try(format('select public.get_estate_readiness(%L)', p_estate))
  ) into v;
  reset role;
  return v;
exception when others then
  reset role;
  return jsonb_build_object('error', SQLERRM);
end $$;

/**
 * The composed WORKFLOW surface — can this viewer OPEN the fiduciary workflow?
 *
 * ★ IT RECORDS ALLOWED/REFUSED, NEVER THE RETURNED IDENTIFIER. A case id is state that would differ
 * between runs and make an equivalence comparison meaningless.
 *
 * ★ AN AUTHORIZATION REFUSAL AND A LIFECYCLE CONFLICT ARE DIFFERENT ANSWERS, AND COLLAPSING THEM
 * PRODUCED A FALSE FINDING. The first version of this helper returned 'REFUSED' for every exception.
 * `initiate_death_verification_case` permits ONE live case per estate and raises `lifecycle_conflict`
 * (P0001) for a second — so when §3 ran an executor and a trustee against the SAME estate, the
 * trustee's perfectly authorized call was reported as a refusal, and the suite announced that
 * executor and trustee hold different authority. They do not; the instrument could not tell "you may
 * not" from "not right now". Anything that reports one answer for two situations will eventually be
 * believed about the wrong one.
 */
create or replace function harness_fc.workflow(p_uid uuid, p_estate uuid)
returns text language plpgsql as $$
declare v uuid;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  select public.initiate_death_verification_case(p_estate) into v;
  reset role;
  return case when v is null then 'ALLOWED_NULL' else 'ALLOWED' end;
exception
  when sqlstate '42501' then
    reset role;
    return 'REFUSED';
  when others then
    reset role;
    -- Authorized, but blocked by estate state. NOT an authorization answer.
    return 'CONFLICT:' || SQLERRM;
end $$;

/** Grant a fiduciary designation the way the product does — through the designation table. */
create or replace function harness_fc.designate(p_estate uuid, p_uid uuid, p_type text)
returns void language plpgsql as $$
begin
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (p_estate, p_uid, p_type, 'active');
end $$;

-- =================================================================================================
-- 0 · THE INSTRUMENT CAN SEE A DISCLOSURE CHANGE  (a control that cannot fail is not a control)
-- =================================================================================================
do $fc0$
declare
  OWN_ uuid; SUBJ uuid; S uuid; before_ jsonb; after_ jsonb;
begin
  raise notice ' ';
  raise notice '══ PHASE 11-H · fiduciary capacity ══';
  raise notice '0 · instrument self-check';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into SUBJ;
  insert into public.estates (owner_id, name) values (OWN_, 'FC control') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved'), (S, SUBJ, 'beneficiary', 'approved');

  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'FC control piece', null, null, null, null, null, null, 4200000);

  before_ := harness_fc.composed(SUBJ, S);

  -- A real, immediately-effective grant. If this does not move the composed payload, every
  -- "the payload did not move" assertion below would be measuring a broken instrument.
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  insert into public.access_grants (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition, granted_by_user_id)
  values (S, SUBJ, 'beneficiary', 'estate_inventory', 'category_summary', 'immediately', OWN_);

  after_ := harness_fc.composed(SUBJ, S);

  if before_ = after_ then
    raise exception 'INSTRUMENT DEAD: adding a real grant did not change the composed payload';
  end if;
  raise notice '  ok   composed payload moves when a genuine grant is added';
end $fc0$;

-- =================================================================================================
-- 1 · ★ ORTHOGONALITY — a fiduciary designation changes WORKFLOW and changes DISCLOSURE BY NOTHING
-- =================================================================================================
--
-- The same person, the same estate, the same grants. The ONLY difference is a designation row.
do $fc1$
declare
  OWN_ uuid; SUBJ uuid; S uuid;
  disc_before jsonb; disc_after jsonb;
  flow_before text;  flow_after text;
begin
  raise notice '1 · orthogonality of capacity and disclosure';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into SUBJ;
  insert into public.estates (owner_id, name) values (OWN_, 'FC orthogonality') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved'), (S, SUBJ, 'beneficiary', 'approved');

  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'Orthogonality piece', null, null, null, null, null, null, 9900000);
  insert into public.access_grants (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition, granted_by_user_id)
  values (S, SUBJ, 'beneficiary', 'estate_inventory', 'category_summary', 'immediately', OWN_);

  disc_before := harness_fc.composed(SUBJ, S);
  flow_before := harness_fc.workflow(SUBJ, S);

  -- The single change under test.
  perform harness_fc.designate(S, SUBJ, 'executor');

  disc_after := harness_fc.composed(SUBJ, S);
  flow_after := harness_fc.workflow(SUBJ, S);

  -- ★ HALF ONE: capacity must not move disclosure by one byte.
  if disc_before <> disc_after then
    raise exception 'CAPACITY INFLATED DISCLOSURE: designation changed the composed read surface. before=% after=%',
      disc_before, disc_after;
  end if;
  raise notice '  ok   disclosure byte-identical before and after the designation';

  -- ★ HALF TWO: and it must not be inert, or half one is vacuous.
  if flow_before <> 'REFUSED' then
    raise exception 'PRE-DESIGNATION WORKFLOW WAS NOT REFUSED (got %) — the workflow gate is open to non-fiduciaries', flow_before;
  end if;
  if flow_after = 'REFUSED' then
    raise exception 'POST-DESIGNATION WORKFLOW STILL REFUSED — the designation grants no workflow authority, so the equivalence above proves nothing';
  end if;
  raise notice '  ok   workflow authority moved REFUSED -> % (capacity is real, and read-inert)', flow_after;
end $fc1$;

-- =================================================================================================
-- 2 · THE CONVERSE — disclosure does not manufacture workflow authority
-- =================================================================================================
--
-- ★ THE MIRROR DEFECT IS EQUALLY PLAUSIBLE. "This beneficiary can see everything, so surely they may
-- open a verification case" is the same laundering in the other direction. A maximal grant must buy
-- exactly zero workflow authority.
do $fc2$
declare
  OWN_ uuid; RICH uuid; S uuid; flow text; disc jsonb;
begin
  raise notice '2 · disclosure does not manufacture workflow authority';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into RICH;
  insert into public.estates (owner_id, name) values (OWN_, 'FC converse') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved'), (S, RICH, 'beneficiary', 'approved');

  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'Converse piece', null, null, null, null, null, null, 7700000);
  -- The most generous grant the vocabulary permits.
  insert into public.access_grants (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition, granted_by_user_id)
  values (S, RICH, 'beneficiary', 'estate_inventory', 'full_detail', 'immediately', OWN_);

  disc := harness_fc.composed(RICH, S);
  flow := harness_fc.workflow(RICH, S);

  -- Paired control: the grant must actually be disclosing, or "no workflow" is trivially true.
  if disc->'discovery' is null or (disc->'discovery')::text = 'null' then
    raise exception 'CONTROL FAILED: full_detail grantee sees no discovery at all — fixture is not disclosing';
  end if;
  if flow <> 'REFUSED' then
    raise exception 'DISCLOSURE MANUFACTURED WORKFLOW AUTHORITY: full_detail grantee opened a verification case (%)', flow;
  end if;
  raise notice '  ok   a full_detail grantee discloses richly and holds no workflow authority';
end $fc2$;

-- =================================================================================================
-- 3 · TRUSTEE AND EXECUTOR ARE ONE CAPACITY — pinned, not assumed
-- =================================================================================================
--
-- ★ WHY PIN A SAMENESS. The brief treats executor and trustee as two capacities. The SOURCE does
-- not: `is_estate_executor` accepts both designation types, so they are interchangeable everywhere.
-- Pinning it means a contributor who later assumes trustee is the weaker of the two is corrected by
-- a failing test rather than by a production disclosure. If the product ever needs them to differ,
-- this test is the thing that must be deliberately changed — which is the point.
do $fc3$
declare
  OWN_ uuid; EX uuid; TR uuid; S_EX uuid; S_TR uuid;
  ex_disc jsonb; tr_disc jsonb; ex_flow text; tr_flow text;
begin
  raise notice '3 · trustee and executor are one capacity';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into auth.users default values returning id into TR;

  -- ★ ONE ESTATE PER CAPACITY. `initiate_death_verification_case` allows a single live case per
  -- estate, so testing both capacities against one estate measures WHO WENT FIRST, not who is
  -- authorized. Two structurally identical estates keep the comparison about the designation.
  insert into public.estates (owner_id, name) values (OWN_, 'FC capacity exec') returning id into S_EX;
  insert into public.estates (owner_id, name) values (OWN_, 'FC capacity trust') returning id into S_TR;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S_EX, OWN_, 'primary_user', 'approved'), (S_TR, OWN_, 'primary_user', 'approved');

  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S_EX, 'artwork', 'Capacity piece', null, null, null, null, null, null, 1300000);
  perform public.create_estate_asset(S_TR, 'artwork', 'Capacity piece', null, null, null, null, null, null, 1300000);

  perform harness_fc.designate(S_EX, EX, 'executor');
  perform harness_fc.designate(S_TR, TR, 'trustee');

  ex_disc := harness_fc.composed(EX, S_EX);
  tr_disc := harness_fc.composed(TR, S_TR);
  ex_flow := harness_fc.workflow(EX, S_EX);
  tr_flow := harness_fc.workflow(TR, S_TR);

  -- ★ THE TWO ESTATES DIFFER BY ID, SO COMPARE THE DISCLOSURE SHAPE, NOT THE RAW BYTES. Estate ids
  -- and asset ids are expected to differ; anything else differing is a capacity difference.
  if (ex_disc #>> '{discovery,authorized}') is distinct from (tr_disc #>> '{discovery,authorized}')
     or jsonb_array_length(coalesce(ex_disc->'assets', '[]'::jsonb))
        <> jsonb_array_length(coalesce(tr_disc->'assets', '[]'::jsonb)) then
    raise exception 'EXECUTOR AND TRUSTEE DISCLOSE DIFFERENTLY, but one predicate serves both. exec=% trustee=%',
      ex_disc, tr_disc;
  end if;
  if ex_flow <> tr_flow then
    raise exception 'EXECUTOR AND TRUSTEE HOLD DIFFERENT WORKFLOW AUTHORITY: exec=% trustee=%', ex_flow, tr_flow;
  end if;
  if ex_flow <> 'ALLOWED' then
    raise exception 'CONTROL FAILED: the executor did not open the workflow (got %) — sameness is vacuous', ex_flow;
  end if;
  raise notice '  ok   identical disclosure and identical workflow authority (both %)', ex_flow;
end $fc3$;

-- =================================================================================================
-- 4 · A FIDUCIARY WITH NO GRANT DISCLOSES NOTHING, AT EVERY LIFECYCLE STATE
-- =================================================================================================
--
-- ★ THE STATE AXIS. Phase 11-G proved this at `released`. The concern here is the opposite end: a
-- fiduciary is the participant most likely to acquire disclosure "while the process is running" —
-- during verification, during the challenge window, at the moment of dispatch. If capacity is truly
-- read-inert, the composed payload is the SAME at every state, including the terminal one.
do $fc4$
declare
  OWN_ uuid; EX uuid; S uuid; st text; base jsonb; now_ jsonb;
  states text[] := array['active','death_verification_pending','death_verified',
                         'owner_notification_dispatched','challenge_window','released'];
begin
  raise notice '4 · a grantless fiduciary across the lifecycle';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'FC lifecycle') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'Lifecycle piece', null, null, null, null, null, null, 5100000);
  perform harness_fc.designate(S, EX, 'executor');

  base := harness_fc.composed(EX, S);

  foreach st in array states loop
    if st <> 'active' then
      perform harness_sv.drive(S, st);
    end if;
    now_ := harness_fc.composed(EX, S);
    if now_ <> base then
      raise exception 'FIDUCIARY DISCLOSURE MOVED AT STATE %: capacity gained visibility from a lifecycle change. base=% now=%',
        st, base, now_;
    end if;
  end loop;
  raise notice '  ok   identical composed payload at all % states, including released', array_length(states, 1);
end $fc4$;

-- =================================================================================================
-- 5 · THE INSTRUCTION SURFACE IS ASSERTED BY THE CENSUS, NOT HERE — AND THAT IS A CORRECTION
-- =================================================================================================
--
-- ★ THIS SECTION USED TO LIVE HERE AND PROVED NOTHING. `encrypted_instructions` carries an RLS
-- policy granting an executor SELECT after release, so its reachability is squarely this phase's
-- business. The assertion was written as a runtime probe: read the table as an executor, expect a
-- refusal, conclude "dormant".
--
-- The table does not exist in this suite's schema at all. `preamble_real_auth.sql` never creates it,
-- so the probe raised `relation "public.encrypted_instructions" does not exist`, the handler caught
-- it exactly as it would catch a permission denial, and the suite reported that a capacity-gated
-- disclosure path was safely closed. It was measuring the absence of the TABLE and calling it the
-- absence of ACCESS — the same collapse of "nothing here" into "not allowed" that Phase 11-G spent
-- its whole client half separating.
--
-- ★ THE CLAIM IS TRUE; ONLY THE INSTRUMENT WAS WRONG. Reachability is a property of the SOURCE — is
-- there a table-level GRANT, is there a SECURITY DEFINER reader — and `scripts/reconFiduciaryAuthority.mjs`
-- derives exactly that, with positive controls proving it can see the table and the policy before it
-- reports on either. That is the correct observation boundary, so the assertion lives there and this
-- file does not restate it.
--
-- If the table is ever added to the harness schema, a runtime probe belongs here — with an explicit
-- precondition asserting the relation EXISTS before any refusal is interpreted as a policy outcome.

do $fcdone$ begin raise notice 'ALL FIDUCIARY CAPACITY ASSERTIONS PASSED'; end $fcdone$;
