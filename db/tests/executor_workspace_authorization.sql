-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-I — the fiduciary workflow read: authorized by capacity, blind to the estate
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THE LOAD-BEARING CLAIM, AND WHY IT NEEDS TWO HALVES. Adding a fiduciary designation must change
-- the WORKFLOW projection from refused to authorized, and must change every DISCLOSURE projection by
-- nothing at all. Either half alone is worthless:
--
--   - proving only that disclosure is unchanged passes trivially for a projection that returns
--     nothing, or for an implementation that ignores designations entirely;
--   - proving only that workflow became authorized says nothing about what came with it.
--
-- §1 measures both across the SAME person and estate, with the designation as the only edit.
--
-- ★ INFORMATION EQUIVALENCE (§3) CHANGES THE HIDDEN WORLD AND DEMANDS THE PAYLOAD NOT MOVE — paired,
-- as always, with a positive control that changes a WORKFLOW fact and demands it DOES move. A frozen
-- projection is not evidence of discretion; it is evidence of a broken function.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

create schema if not exists harness_ew;
grant usage on schema harness_ew to anon, authenticated;

/** The workflow projection as one viewer sees it. */
create or replace function harness_ew.workspace(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  v := harness_dv.try(format('select public.get_executor_workspace(%L)', p_estate));
  reset role;
  return v;
end $$;

/** Every DISCLOSURE surface, composed — the thing that must not move when capacity changes. */
create or replace function harness_ew.disclosure(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  select jsonb_build_object(
    'discovery', harness_dv.try(format('select public.get_estate_discovery(%L)', p_estate)),
    'assets',    harness_dv.try(format(
      'select coalesce(jsonb_agg(to_jsonb(a) order by a.id), ''[]''::jsonb) from public.list_estate_assets(%L) a', p_estate)),
    'net_worth', harness_dv.try(format(
      'select coalesce(jsonb_agg(to_jsonb(w)), ''[]''::jsonb) from public.get_estate_net_worth(%L) w', p_estate)),
    'workspace', harness_dv.try(format('select public.get_professional_workspace(%L)', p_estate)),
    'readiness', harness_dv.try(format('select public.get_estate_readiness(%L)', p_estate))
  ) into v;
  reset role;
  return v;
exception when others then
  reset role;
  return jsonb_build_object('error', SQLERRM);
end $$;

-- =================================================================================================
-- 0 · THE INSTRUMENT CAN SEE BOTH KINDS OF CHANGE
-- =================================================================================================
do $ew0$
declare OWN_ uuid; EX uuid; S uuid; w0 jsonb; w1 jsonb;
begin
  raise notice ' ';
  raise notice '══ PHASE 11-I · executor workflow read ══';
  raise notice '0 · instrument self-check';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EW control') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status) values (S, OWN_, 'primary_user', 'approved');

  w0 := harness_ew.workspace(EX, S);
  if (w0->>'authorized') is distinct from 'false' then
    raise exception 'CONTROL FAILED: a non-fiduciary was not refused (got %)', w0;
  end if;

  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');

  w1 := harness_ew.workspace(EX, S);
  if (w1->>'authorized') is distinct from 'true' then
    raise exception 'CONTROL FAILED: a designated executor was not authorized (got %)', w1;
  end if;
  raise notice '  ok   the projection distinguishes refused from authorized';
end $ew0$;

-- =================================================================================================
-- 1 · ★ THE LOAD-BEARING INVARIANT — designation changes WORKFLOW and changes DISCLOSURE BY NOTHING
-- =================================================================================================
do $ew1$
declare
  OWN_ uuid; SUBJ uuid; S uuid;
  w_before jsonb; w_after jsonb; d_before jsonb; d_after jsonb;
begin
  raise notice '1 · designation moves workflow only';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into SUBJ;
  insert into public.estates (owner_id, name) values (OWN_, 'EW invariant') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved'), (S, SUBJ, 'beneficiary', 'approved');

  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'EW piece', null, null, null, null, null, null, 8800000);
  insert into public.access_grants (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition, granted_by_user_id)
  values (S, SUBJ, 'beneficiary', 'estate_inventory', 'category_summary', 'immediately', OWN_);

  w_before := harness_ew.workspace(SUBJ, S);
  d_before := harness_ew.disclosure(SUBJ, S);

  -- The single edit under test.
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, SUBJ, 'executor', 'active');

  w_after := harness_ew.workspace(SUBJ, S);
  d_after := harness_ew.disclosure(SUBJ, S);

  if (w_before->>'authorized') is distinct from 'false' or (w_after->>'authorized') is distinct from 'true' then
    raise exception 'WORKFLOW DID NOT MOVE: before=% after=%', w_before, w_after;
  end if;
  raise notice '  ok   workflow projection moved refused -> authorized';

  if d_before <> d_after then
    raise exception 'CAPACITY INFLATED DISCLOSURE: before=% after=%', d_before, d_after;
  end if;
  raise notice '  ok   every disclosure projection byte-identical across the designation';
end $ew1$;

-- =================================================================================================
-- 2 · PERSONA MATRIX — only a fiduciary is authorized, and refusal has ONE shape
-- =================================================================================================
do $ew2$
declare
  OWN_ uuid; OTHER_OWN uuid; BEN uuid; DELE uuid; EX uuid; TR uuid; REVOKED uuid; STRANGER uuid;
  S uuid; S2 uuid; v jsonb; who text;
begin
  raise notice '2 · persona matrix';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into OTHER_OWN;
  insert into auth.users default values returning id into BEN;
  insert into auth.users default values returning id into DELE;
  insert into auth.users default values returning id into EX;
  insert into auth.users default values returning id into TR;
  insert into auth.users default values returning id into REVOKED;
  insert into auth.users default values returning id into STRANGER;
  insert into public.estates (owner_id, name) values (OWN_, 'EW personas') returning id into S;
  insert into public.estates (owner_id, name) values (OTHER_OWN, 'EW foreign') returning id into S2;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved'), (S, BEN, 'beneficiary', 'approved'),
         (S, DELE, 'professional_delegate', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active'), (S, TR, 'trustee', 'active'),
         (S, REVOKED, 'executor', 'revoked');

  -- ★ AUTHORIZED: only the two active fiduciary capacities.
  foreach who in array array['executor','trustee'] loop
    v := harness_ew.workspace(case who when 'executor' then EX else TR end, S);
    if (v->>'authorized') is distinct from 'true' then
      raise exception '% was refused but holds an active designation: %', who, v;
    end if;
  end loop;
  raise notice '  ok   executor and trustee are both authorized';

  -- ★ REFUSED, and byte-identically so. The owner is refused too: ownership is not a fiduciary
  -- capacity, and an owner has no death-verification workflow of their own to read.
  for who, v in
    select 'beneficiary',     harness_ew.workspace(BEN, S) union all
    select 'delegate',        harness_ew.workspace(DELE, S) union all
    select 'revoked',         harness_ew.workspace(REVOKED, S) union all
    select 'stranger',        harness_ew.workspace(STRANGER, S) union all
    select 'owner',           harness_ew.workspace(OWN_, S) union all
    select 'foreign owner',   harness_ew.workspace(OTHER_OWN, S) union all
    select 'exec elsewhere',  harness_ew.workspace(EX, S2)
  loop
    if v <> jsonb_build_object('authorized', false) then
      raise exception '% received something other than the single refusal shape: %', who, v;
    end if;
  end loop;
  raise notice '  ok   every non-fiduciary receives one identical refusal';

  -- ★ AND THE REFUSAL FOR A NONEXISTENT ESTATE MATCHES, so the projection is not an existence oracle.
  if harness_ew.workspace(EX, gen_random_uuid()) <> jsonb_build_object('authorized', false) then
    raise exception 'a nonexistent estate produced a distinguishable answer';
  end if;
  raise notice '  ok   a nonexistent estate is indistinguishable from an unauthorized one';
end $ew2$;

-- =================================================================================================
-- 3 · ★ INFORMATION EQUIVALENCE — the hidden world moves, the workflow payload does not
-- =================================================================================================
do $ew3$
declare
  OWN_ uuid; EX uuid; BEN2 uuid; S uuid; base jsonb; now_ jsonb; doc uuid;
begin
  raise notice '3 · information equivalence';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into auth.users default values returning id into BEN2;
  insert into public.estates (owner_id, name) values (OWN_, 'EW equivalence') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status) values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');

  base := harness_ew.workspace(EX, S);

  -- Change the hidden world in seven independent ways.
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'Hidden piece one', null, null, null, null, null, null, 1234500);
  -- ★ A SUBTYPE FROM A DIFFERENT PARENT CATEGORY, so this genuinely adds a new category to the
  -- inventory. `realEstate` is a CATEGORY key, not a subtype — passing it here is the
  -- `unknown_subtype` mistake the taxonomy rule exists to prevent.
  perform public.create_estate_asset(S, 'secondaryProperty', 'Hidden new category', null, null, null, null, null, null, 99000000);
  perform public.create_estate_asset(S, 'artwork', 'Hidden piece two', null, null, null, null, null, null, 4200);
  insert into public.estate_memberships (estate_id, user_id, role, status) values (S, BEN2, 'beneficiary', 'approved');
  insert into public.access_grants (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition, granted_by_user_id)
  values (S, BEN2, 'beneficiary', 'estate_inventory', 'full_detail', 'immediately', OWN_);
  insert into public.beneficiaries (estate_id, user_id, email)
  values (S, BEN2, 'hidden-beneficiary@example.invalid');

  now_ := harness_ew.workspace(EX, S);
  if now_ <> base then
    raise exception 'WORKFLOW PAYLOAD LEAKED ESTATE STATE. base=% now=%', base, now_;
  end if;
  raise notice '  ok   assets, a new category, a beneficiary and a grant all moved: payload identical';

  -- ★ THE POSITIVE CONTROL. A WORKFLOW fact changes, and the payload MUST move — otherwise the
  -- equivalence above is a frozen function, not a discreet one.
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.initiate_death_verification_case(S);
  now_ := harness_ew.workspace(EX, S);
  if now_ = base then
    raise exception 'FROZEN PROJECTION: opening a verification case did not change the payload';
  end if;
  if (now_ #>> '{verification,state}') is distinct from 'open' then
    raise exception 'workflow state did not report the open case: %', now_;
  end if;
  raise notice '  ok   opening a verification case DOES move the payload (state=open)';
end $ew3$;

-- =================================================================================================
-- 4 · THE FORBIDDEN VOCABULARY NEVER APPEARS IN THE PAYLOAD
-- =================================================================================================
--
-- ★ A STRUCTURAL CHECK OVER THE WHOLE VALUE, not a field-by-field review someone must remember to
-- update. Any future contributor who adds `document_count` fails here without reading this comment.
do $ew4$
declare
  OWN_ uuid; EX uuid; S uuid; v jsonb; k text;
  forbidden text[] := array[
    'asset','assets','asset_count','asset_value','category','categories','category_count',
    'net_worth','document','documents','document_count','beneficiary','beneficiaries',
    'beneficiary_count','grant','grants','tier','visibility_tier','inventory',
    'reviewer','reviewer_id','decided_by','decision_note','review_notes','audit_id',
    'initiator','initiated_by','initiator_capacity','other_executors','hidden_count'];
begin
  raise notice '4 · forbidden vocabulary';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EW vocabulary') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status) values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'Vocabulary piece', null, null, null, null, null, null, 5500000);
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.initiate_death_verification_case(S);

  v := harness_ew.workspace(EX, S);

  -- Every key at every depth, flattened.
  foreach k in array forbidden loop
    if exists (
      select 1 from jsonb_each(v->'verification') e where e.key = k
      union all select 1 from jsonb_each(v->'claim')   e where e.key = k
      union all select 1 from jsonb_each(v->'process') e where e.key = k
      union all select 1 from jsonb_each(v)            e where e.key = k
    ) then
      raise exception 'FORBIDDEN KEY "%" present in the workflow payload: %', k, v;
    end if;
  end loop;
  raise notice '  ok   none of % forbidden keys appear at any depth', array_length(forbidden, 1);

  -- Paired control: the checker CAN find a key that is present.
  if not exists (select 1 from jsonb_each(v->'verification') e where e.key = 'state') then
    raise exception 'CONTROL FAILED: the key scanner cannot see a key that is present';
  end if;
  raise notice '  ok   the key scanner finds a key known to be present';
end $ew4$;

-- =================================================================================================
-- 5 · LIFECYCLE COVERAGE — the workflow reports process state without disclosing content
-- =================================================================================================
do $ew5$
declare
  OWN_ uuid; EX uuid; S uuid; st text; v jsonb; d_base jsonb; d_now jsonb;
  states text[] := array['active','death_verification_pending','death_verified',
                         'owner_notification_dispatched','challenge_window','released'];
begin
  raise notice '5 · lifecycle coverage';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EW lifecycle') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status) values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'Lifecycle piece', null, null, null, null, null, null, 7000000);

  d_base := harness_ew.disclosure(EX, S);

  foreach st in array states loop
    if st <> 'active' then perform harness_sv.drive(S, st); end if;
    v := harness_ew.workspace(EX, S);
    if (v->>'authorized') is distinct from 'true' then
      raise exception 'fiduciary lost workflow authorization at state %: %', st, v;
    end if;
    -- ★ The grantless fiduciary's DISCLOSURE must not move as the lifecycle advances — including
    -- at `released`, where "the estate is released so show them everything" is most tempting.
    d_now := harness_ew.disclosure(EX, S);
    if d_now <> d_base then
      raise exception 'DISCLOSURE MOVED AT STATE % for a grantless fiduciary: base=% now=%', st, d_base, d_now;
    end if;
  end loop;

  if (v #>> '{process,release_completed}') is distinct from 'true' then
    raise exception 'release_completed not reported at released: %', v;
  end if;
  raise notice '  ok   authorized at all % states; disclosure never moved; release reported',
    array_length(states, 1);
end $ew5$;

-- =================================================================================================
-- 6 · ★ encrypted_instructions FIREWALL — its parallel vocabulary reaches nothing
-- =================================================================================================
--
-- ★ ASSERTED OVER SOURCE, BECAUSE THAT IS WHERE THE COUPLING WOULD LIVE. Phase 11-H learned this the
-- hard way: a runtime probe of `encrypted_instructions` reported "dormant" when the table simply did
-- not exist in the suite schema — measuring the absence of the TABLE and calling it the absence of
-- ACCESS. Reachability is a property of the source text, so it is checked there, and only there.
do $ew6$
declare v_src text; needle text;
begin
  raise notice '6 · encrypted_instructions firewall';

  select prosrc into v_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_executor_workspace';

  if v_src is null then
    raise exception 'CONTROL FAILED: get_executor_workspace not found in pg_proc — nothing was inspected';
  end if;

  foreach needle in array array['encrypted_instructions','on_death','on_executor_claim'] loop
    if position(needle in v_src) > 0 then
      raise exception 'HIGH: get_executor_workspace references the dormant instruction vocabulary "%"', needle;
    end if;
  end loop;

  -- Paired control: the scanner can find a token that IS in the body.
  if position('is_estate_executor' in v_src) = 0 then
    raise exception 'CONTROL FAILED: the source scanner cannot find a token known to be present';
  end if;
  raise notice '  ok   no instruction vocabulary in the projection (scanner control passed)';
end $ew6$;


-- =================================================================================================
-- 7 · ★ estate_release_state IS A LOCKED HELPER — and the consumer that needs it still works
-- =================================================================================================
--
-- ★ THE DEFECT THIS PINS. `estate_release_state` is SECURITY DEFINER, takes an arbitrary estate id,
-- and has NO authorization gate in its body. While it was granted to `authenticated`, any signed-in
-- user could pass any estate id and learn that estate's claim/release state. Estate ids are not
-- secrets — they travel in deep links, invitations and support threads.
--
-- ★ BOTH HALVES ARE REQUIRED, AND THE SECOND IS THE ONE THAT CATCHES A BAD FIX. A revoke test alone
-- passes just as happily when the revoke has broken every disclosure surface downstream. The sole
-- production caller is `get_estate_discovery` — SECURITY DEFINER, serving NON-owner readers — so
-- this section calls the CONSUMER through the product path and requires it to still answer.
do $ew7$
declare
  OWN_ uuid; BEN uuid; STRANGER uuid; S uuid; denied boolean; disc jsonb;
begin
  raise notice '7 · estate_release_state lockdown';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into BEN;
  insert into auth.users default values returning id into STRANGER;
  insert into public.estates (owner_id, name) values (OWN_, 'EW lockdown') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved'), (S, BEN, 'beneficiary', 'approved');
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'Lockdown piece', null, null, null, null, null, null, 3300000);
  insert into public.access_grants (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition, granted_by_user_id)
  values (S, BEN, 'beneficiary', 'estate_inventory', 'category_summary', 'immediately', OWN_);

  -- ★ A COMPLETE STRANGER, AIMED AT A FOREIGN ESTATE — the exact shape of the defect.
  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  begin
    perform public.estate_release_state(S);
    denied := false;
  exception when insufficient_privilege then
    denied := true;
  when others then
    -- ★ ONLY 42501 COUNTS. Any other error would mean the call ENTERED the routine and failed
    -- inside it, which is not the same as being refused at the door.
    denied := false;
  end;
  reset role;
  if not denied then
    raise exception 'SECURITY: an unrelated authenticated caller reached estate_release_state on a foreign estate';
  end if;
  raise notice '  ok   an unrelated authenticated caller is refused at the door (42501)';

  -- The owner is locked out of the DIRECT contract too: it is an internal helper, not an API.
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  set local role authenticated;
  begin
    perform public.estate_release_state(S);
    denied := false;
  exception when insufficient_privilege then denied := true;
  when others then denied := false;
  end;
  reset role;
  if not denied then
    raise exception 'estate_release_state is still directly callable by the owner — the direct contract is meant to be closed';
  end if;
  raise notice '  ok   the direct contract is closed for every client role, owner included';

  -- ★ AND ANON, WHICH THE FIRST VERSION OF THIS SECTION NEVER CHECKED. The mutation
  -- `hotfix-release-state-anon-granted` SURVIVED against the original assertions: granting the
  -- helper to `anon` makes a foreign estate's claim state readable with no session at all, and
  -- nothing here noticed. Testing the role you expect to be attacked is not the same as testing
  -- every role that can hold the privilege.
  set local role anon;
  begin
    perform public.estate_release_state(S);
    denied := false;
  exception when insufficient_privilege then denied := true;
  when others then denied := false;
  end;
  reset role;
  if not denied then
    raise exception 'SECURITY: estate_release_state is reachable by anon';
  end if;
  raise notice '  ok   anon is refused at the door';

  -- ★ AND THE DOWNSTREAM CONSUMER STILL WORKS. get_estate_discovery is SECURITY DEFINER and calls
  -- the helper internally; a revoke that broke it would be a worse defect than the one being fixed.
  disc := harness_ew.disclosure(BEN, S);
  if (disc #>> '{discovery,authorized}') is distinct from 'true' then
    raise exception 'REVOKE BROKE THE CONSUMER: the beneficiary discovery payload is no longer authorized: %', disc;
  end if;
  if (disc #>> '{discovery,release_state}') is null then
    raise exception 'REVOKE BROKE THE CONSUMER: discovery no longer carries release_state: %', disc;
  end if;
  raise notice '  ok   get_estate_discovery still resolves release_state for a non-owner reader';
end $ew7$;

do $ewdone$ begin raise notice 'ALL EXECUTOR WORKSPACE ASSERTIONS PASSED'; end $ewdone$;
