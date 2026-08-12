-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-B — THE CANONICAL RELEASE-CONDITION ENGINE, PROVED AGAINST A REAL DATABASE
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THIS FILE IS FOR. The release rule used to be written out seven times. It is now written
-- once, and every read path calls it. That is only an improvement if two things are true:
--
--   1 · the centre gives the SAME answers the seven copies gave — a refactor that changes a
--       disclosure answer is not a refactor;
--   2 · nothing satisfies a death, incapacity, identity or claim condition, at any surface, for any
--       viewer, under either policy.
--
-- Both are asserted here by EXECUTION, over the full input space where it is finite. The source
-- audit (`test/releaseConditionCentralization.test.ts`) proves there is one authority; this file
-- proves the authority is right.
--
-- ★ AND EVERY ASSERTION BELOW IS PAIRED. Proving a death-conditioned grant discloses nothing is
-- worth nothing unless an `immediately` grant at the same tier, on the same estate, for the same
-- viewer, is shown to disclose something. A projection that returned `{}` would satisfy every
-- withholding assertion in this file; the positive control is what stops that reading as a pass.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

-- =================================================================================================
-- fixture — the financial rows that make the asset and net-worth surfaces observable
-- =================================================================================================
--
-- ★ WITHOUT THESE ROWS EVERY ASSERTION BELOW WOULD BE VACUOUS, and until Phase 11-B they did not
-- exist: `normalized_assets` was not modelled by the harness at all, so `get_estate_net_worth` could
-- not be loaded and `list_estate_assets` could not be called. Four of the seven copies of the
-- release rule had never executed in any test.
--
-- The amounts are chosen so a disclosure would be UNMISTAKABLE — two rows, two groups, a total that
-- is not zero — because "the beneficiary saw nothing" is not evidence when there was nothing to see.
insert into public.normalized_assets (estate_id, connection_id, institution_name, asset_group, balance_cents, currency)
values
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', gen_random_uuid(), 'Northbank', 'cashBank', 5150000, 'USD'),
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', gen_random_uuid(), 'Southvest', 'investmentBrokerage', 31200000, 'USD')
on conflict do nothing;

-- =================================================================================================
-- 0 · THE INSTRUMENT IS READING THE REAL THING  (a control that cannot fail is not a control)
-- =================================================================================================
--
-- ★ THREE WAYS THIS SUITE COULD BE VACUOUS, CLOSED BEFORE ANYTHING IS ASSERTED.
--
-- (a) `release_condition_satisfied` might not exist — the preamble's `can_access_document` forward-
--     references it, and a plpgsql body is not resolved until it is CALLED. If the bundle failed to
--     load it, every "is withheld" assertion below would pass by RAISING inside a function whose
--     exception the harness converts to a refusal. Withholding-by-crash is not withholding.
--
-- (b) `asset_category_grantable` is installed by the preamble as `select false` and REPLACED by the
--     estate bundle with the real ceiling. If that replacement ever stopped happening, nothing would
--     be grantable, every disclosure assertion would report "correctly hidden", and the suite would
--     go green while measuring a stub. "Nothing is visible" reads as safe, which is what makes it
--     the dangerous vacuum.
--
-- (c) `can_access_document` might still be the pre-11-B body. The preamble and the bundle both
--     define it; if the bundle's copy did not land, this file would be testing the old inline rule
--     and reporting it as the centralized one.
do $$
declare v_def text; v_ok boolean;
begin
  raise notice '0 · release-condition instrument self-check';

  if to_regprocedure('public.release_condition_satisfied(text, timestamptz, text)') is null then
    raise exception 'FAIL: public.release_condition_satisfied does not exist — every withholding '
      'assertion below would pass by crashing';
  end if;
  if to_regprocedure('public.release_condition_writable(text)') is null then
    raise exception 'FAIL: public.release_condition_writable does not exist';
  end if;
  raise notice '  ok   the canonical predicate resolved (it is called, not assumed)';

  -- (b) The ceiling must be the REAL one, not the preamble's `select false` stand-in.
  if public.asset_category_grantable('beneficiary', 'estate_inventory', 'category_summary') is not true then
    raise exception 'FAIL: asset_category_grantable refuses a combination the real ceiling permits — '
      'the preamble stub was not replaced by the estate bundle, and every disclosure assertion in '
      'this suite would be vacuously "hidden"';
  end if;
  if public.asset_category_grantable('beneficiary', 'account_balances', 'full_detail') is not false then
    raise exception 'FAIL: asset_category_grantable permits an over-ceiling combination — it is not '
      'the real ceiling';
  end if;
  raise notice '  ok   the REAL asset ceiling is loaded (it both permits and refuses)';

  -- (c) The document gate delegates rather than carrying its own copy.
  select pg_get_functiondef(to_regprocedure('public.can_access_document(uuid)')) into v_def;
  if v_def is null then
    raise exception 'FAIL: can_access_document is not installed';
  end if;
  if position('release_condition_satisfied' in v_def) = 0 then
    raise exception 'FAIL: the LOADED can_access_document does not call the canonical predicate — '
      'the bundle copy did not land and this suite would be testing the pre-11-B body';
  end if;
  raise notice '  ok   the loaded document gate delegates to the canonical predicate';

  -- And the predicate itself must DISAGREE across inputs, or comparing it to anything is vacuous.
  select public.release_condition_satisfied('immediately', null, 'standard') into v_ok;
  if v_ok is not true then
    raise exception 'FAIL: the canonical predicate refuses `immediately` — it is stubbed to false';
  end if;
  select public.release_condition_satisfied('never', null, 'standard') into v_ok;
  if v_ok is not false then
    raise exception 'FAIL: the canonical predicate accepts `never` — it is stubbed to true';
  end if;
  raise notice '  ok   the predicate distinguishes inputs (it is neither stub)';
end $$;

-- =================================================================================================
-- 1 · THE FULL TRUTH TABLE — every condition × approved/not × every policy, enumerated
-- =================================================================================================
--
-- ★ THE EXPECTATION IS WRITTEN OUT AS DATA, NOT COMPUTED. A helper that re-derived "should this be
-- satisfied?" would be a second copy of the policy being tested, and it would agree with the first
-- one no matter what either said. The rows below are the specification; the function is compared to
-- them.
--
-- ★ AND THE VOCABULARY IS ENUMERATED FROM THE DEPLOYED CHECK, so a condition added to storage
-- without being considered here fails this file rather than passing silently.
create schema if not exists harness_rc;

/**
 * THE COMPOSED VIEW — everything one viewer can collect about this estate, as a single value.
 *
 * ★ COMPOSED, NOT PER-PROJECTION, for the 10-F reason: a leak that no single projection commits can
 * still exist in the TUPLE of answers a viewer can gather, and a viewer can always gather all of
 * them. Comparing one projection before and after a hidden change would miss a fact that moved from
 * the inventory payload into the asset list.
 *
 * ★ IT RUNS AS THE VIEWER, UNDER `authenticated`, SECURITY INVOKER. A definer helper would execute
 * as the harness owner and hand every scenario rights no client has, and the comparison would then
 * be between two payloads nobody can actually receive.
 */
create or replace function harness_rc.composed(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select jsonb_build_object(
    'discovery', public.get_estate_discovery(p_estate),
    -- ★ ORDERED BY A COLUMN THIS FUNCTION ACTUALLY RETURNS. The first version ordered by `a.label`,
    -- which does not exist here — `list_estate_assets` returns the normalized-asset shape, not the
    -- estate-asset one. Every composed payload was therefore the SAME error object, the equivalence
    -- assertion in section 6 compared two identical errors and passed, and only the positive control
    -- noticed. A green error state is not evidence, and this is what that looks like from inside.
    'assets', coalesce((select jsonb_agg(to_jsonb(a) order by a.id)
                          from public.list_estate_assets(p_estate) a), '[]'::jsonb),
    'net_worth', coalesce((select jsonb_agg(to_jsonb(w))
                             from public.get_estate_net_worth(p_estate) w), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(d.id order by d.id)
                             from public.documents d where d.estate_id = p_estate), '[]'::jsonb)
  ) into v;
  reset role;
  return v;
exception when others then
  -- ★ THE ERROR IS PART OF THE PAYLOAD, NOT A REASON TO STOP. A refusal that changes its MESSAGE
  -- when the hidden world changes is a disclosure channel, and swallowing it to `null` would make
  -- two different refusals compare equal — which is the vacuous direction.
  reset role;
  return jsonb_build_object('error', SQLERRM);
end $$;

create or replace function harness_rc.expected(p_cond text, p_approved boolean, p_policy text)
returns boolean language sql immutable as $$
  -- The specification, stated once, in one place, as literals.
  select case
    when p_policy = 'standard' and p_cond = 'immediately' then true
    when p_policy = 'standard' and p_cond in ('after_owner_approval','after_access_request_approval')
      then p_approved
    when p_policy = 'legacy_immediate_only' and p_cond = 'immediately' then true
    else false
  end;
$$;

do $$
declare
  v_conds text[];
  v_cond text; v_pol text; v_app boolean;
  v_got boolean; v_want boolean;
  v_n int := 0; v_true int := 0;
begin
  raise notice '1 · the canonical predicate, full truth table';

  -- ★ THE CONDITION LIST COMES FROM THE CHECK CONSTRAINT ITSELF. Hand-listing it here is how a
  -- vocabulary grows past its tests: someone adds a value to the CHECK, nobody adds a row here, and
  -- the new condition is never asked about.
  select array_agg(distinct m[1] order by m[1])
    into v_conds
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace,
    lateral regexp_matches(pg_get_constraintdef(con.oid), '''([a-z_]+)''', 'g') m
   where nsp.nspname = 'public' and rel.relname = 'access_grants'
     and con.conname = 'access_grants_release_condition_check';

  if v_conds is null or array_length(v_conds, 1) < 8 then
    raise exception 'FAIL: extracted % condition(s) from the CHECK; expected the full vocabulary. '
      'The scan set must be asserted before any rule is evaluated.', coalesce(array_length(v_conds,1), 0);
  end if;
  if not ('after_verified_death' = any(v_conds)) or not ('after_verified_incapacity' = any(v_conds)) then
    raise exception 'FAIL: the split conditions are not in the deployed CHECK: %', v_conds;
  end if;
  if not ('after_verified_death_or_incapacity' = any(v_conds)) then
    raise exception 'FAIL: the legacy fused condition was dropped from the CHECK — stored rows orphaned';
  end if;
  raise notice '  ok   % conditions enumerated FROM the deployed CHECK (split present, legacy retained)',
    array_length(v_conds, 1);

  -- ★ AN UNKNOWN CONDITION AND AN UNKNOWN POLICY ARE PUT THROUGH THE SAME MATRIX. The vocabulary is
  -- closed; the function must be closed the same way.
  foreach v_cond in array (v_conds || array['aw_probe_condition_that_cannot_exist', null]) loop
    foreach v_pol in array array['standard', 'legacy_immediate_only', 'aw_probe_policy', null] loop
      foreach v_app in array array[true, false] loop
        v_got := public.release_condition_satisfied(
                   v_cond, case when v_app then now() else null end, v_pol);
        v_want := coalesce(harness_rc.expected(v_cond, v_app, v_pol), false);
        if v_got is distinct from v_want then
          raise exception 'FAIL: release_condition_satisfied(%, approved=%, %) = %, expected %',
            coalesce(v_cond, 'NULL'), v_app, coalesce(v_pol, 'NULL'), v_got, v_want;
        end if;
        if v_got then v_true := v_true + 1; end if;
        v_n := v_n + 1;
      end loop;
    end loop;
  end loop;

  -- ★ POSITIVE CONTROL ON THE MATRIX ITSELF. An all-false table would agree with an all-false
  -- function perfectly and prove nothing at all.
  if v_true = 0 then
    raise exception 'FAIL: the truth table is satisfied by NOTHING — the comparison is vacuous';
  end if;
  raise notice '  ok   % combinations, % satisfied, exact agreement with the written specification', v_n, v_true;
end $$;

-- =================================================================================================
-- 2 · DORMANCY, STATED AS THE PROPERTY THAT MATTERS: nothing releases these, ever
-- =================================================================================================
do $$
declare v_cond text; v_pol text;
begin
  raise notice '2 · death / incapacity / identity / claim / never are satisfied by nothing';
  foreach v_cond in array array[
    'after_verified_death',
    'after_verified_incapacity',
    'after_verified_death_or_incapacity',
    'after_identity_verification',
    'after_claim_case_approval',
    'never'
  ] loop
    foreach v_pol in array array['standard', 'legacy_immediate_only'] loop
      -- Approved or not, timestamped or not: there is no argument that makes these true.
      if public.release_condition_satisfied(v_cond, now(), v_pol)
         or public.release_condition_satisfied(v_cond, null, v_pol)
         or public.release_condition_satisfied(v_cond, '1970-01-01'::timestamptz, v_pol) then
        raise exception 'FAIL: % is satisfiable under policy %', v_cond, v_pol;
      end if;
    end loop;
    raise notice '  ok   % is dormant under both policies, approved or not', v_cond;
  end loop;
end $$;

-- =================================================================================================
-- 3 · THE WRITE GATE — the split is real for NEW data, and legacy rows are untouched
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        BEN uuid := '44444444-4444-4444-8444-444444444444';
begin
  raise notice '3 · release_condition_writable';

  -- POSITIVE CONTROL FIRST: the gate says yes to something, or "it refuses X" means nothing.
  if not public.release_condition_writable('immediately')
     or not public.release_condition_writable('after_owner_approval')
     or not public.release_condition_writable('never') then
    raise exception 'FAIL: the write gate refuses conditions that must remain writable — it is '
      'stubbed to false and every refusal assertion below is vacuous';
  end if;
  raise notice '  ok   the gate admits the conditions that must stay writable';

  -- ★ THE SPLIT IS EXPRESSIBLE. This is the half of the change a user could notice.
  if not public.release_condition_writable('after_verified_death')
     or not public.release_condition_writable('after_verified_incapacity') then
    raise exception 'FAIL: the split conditions are not writable — the split did not happen';
  end if;
  raise notice '  ok   after_verified_death and after_verified_incapacity are writable';

  -- ★ AND THE FUSED VALUE IS NOT. Readable forever, writable never again.
  if public.release_condition_writable('after_verified_death_or_incapacity') then
    raise exception 'FAIL: the deprecated fused condition is still writable — new rows can still '
      'carry the ambiguity the split exists to end';
  end if;
  if public.release_condition_writable('aw_probe_condition_that_cannot_exist')
     or public.release_condition_writable(null) then
    raise exception 'FAIL: the write gate accepts an unknown or NULL condition';
  end if;
  raise notice '  ok   the fused value, an unknown value and NULL are all refused';
end $$;

-- The gate is enforced by the REAL DOOR, not merely defined. A vocabulary function nobody calls is
-- a comment.
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        BEN uuid := '44444444-4444-4444-8444-444444444444';
begin
  delete from public.access_grants
   where estate_id = A and grantee_user_id = BEN and category = 'estate_inventory';

  perform harness.expect_err('create_asset_grant refuses the deprecated fused condition',
    '11111111-1111-4111-8111-111111111111',
    format('select public.create_asset_grant(%L::uuid, %L::uuid, %L, %L, %L, %L)',
           A, BEN, 'beneficiary', 'estate_inventory', 'category_summary',
           'after_verified_death_or_incapacity'),
    'unsupported release condition');

  perform harness.expect_ok('create_asset_grant ACCEPTS the split death condition (expressible, not live)',
    '11111111-1111-4111-8111-111111111111',
    format('select public.create_asset_grant(%L::uuid, %L::uuid, %L, %L, %L, %L)',
           A, BEN, 'beneficiary', 'estate_inventory', 'category_summary', 'after_verified_death'));

  delete from public.access_grants
   where estate_id = A and grantee_user_id = BEN and category = 'estate_inventory';

  perform harness.expect_err('create_document_grant refuses the deprecated fused condition',
    '11111111-1111-4111-8111-111111111111',
    format('select public.create_document_grant(%L::uuid, %L::uuid, %L, %L::uuid, %L, %L)',
           A, BEN, 'beneficiary', 'dddddddd-1111-4111-8111-dddddddddddd', 'limited_detail',
           'after_verified_death_or_incapacity'),
    'unsupported release condition');
end $$;

-- =================================================================================================
-- 4 · THE FIREWALL, AT EVERY SURFACE, FOR EVERY DORMANT CONDITION
-- =================================================================================================
--
-- ★ THE FIXTURE IS BUILT SO THE TRANSFORMATION IS OBSERVABLE. Each dormant grant is created at a
-- tier that WOULD disclose if the condition were satisfied, on an estate that HAS content, for a
-- viewer who is otherwise eligible. A grant at `hidden`, or on an empty estate, would be withheld
-- for reasons that have nothing to do with the release condition and the test could not fail.
create or replace function harness_rc.regrant(p_uid uuid, p_cat text, p_tier text, p_cond text)
returns void language plpgsql as $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
begin
  delete from public.access_grants
   where estate_id = A and grantee_user_id = p_uid and category = p_cat;
  -- ★ DIRECT INSERT, DELIBERATELY, so a LEGACY row can be constructed. `create_asset_grant` now
  -- refuses the fused value — which is the point of section 3 — so the only way to build the row an
  -- existing database already contains is to write it the way that database did. This is the
  -- migration-compatibility case, and it cannot be tested through a door that now refuses it.
  insert into public.access_grants
    (estate_id, grantee_user_id, grantee_role, document_id, category, visibility_tier,
     release_condition, status, granted_by_user_id, approved_at, approved_by_user_id)
  values
    (A, p_uid, 'beneficiary', null, p_cat, p_tier,
     p_cond, 'active', '11111111-1111-4111-8111-111111111111',
     -- ★ APPROVED, ON PURPOSE. A dormant grant that has ALSO been approved is the strongest form of
     -- the test: it removes "it was withheld because nobody approved it" as an explanation, so the
     -- only thing left holding the line is the release condition itself.
     now(), '11111111-1111-4111-8111-111111111111');
end $$;

do $$
declare
  BEN uuid := '44444444-4444-4444-8444-444444444444';
  A   uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
  v_cond text;
  v_disco jsonb;
  v_rows bigint;
  v_live_disco jsonb;
begin
  raise notice '4 · dormant conditions disclose nothing, at every surface';

  -- ── POSITIVE CONTROL FIRST. The SAME viewer, SAME category, SAME tier, only the condition
  --    differs. Without this the loop below could be passing because the estate is empty.
  perform harness_rc.regrant(BEN, 'estate_inventory', 'category_summary', 'immediately');
  perform harness_rc.regrant(BEN, 'account_balances', 'category_summary', 'immediately');
  perform harness_rc.regrant(BEN, 'total_asset_value', 'range_only', 'immediately');
  perform set_config('request.jwt.claim.sub', BEN::text, true);
  set local role authenticated;
  select public.get_estate_discovery(A) into v_live_disco;
  select count(*) into v_rows from public.list_estate_assets(A);
  reset role;
  if coalesce(jsonb_array_length(v_live_disco -> 'categories'), 0) = 0 then
    raise exception 'FAIL: the CONTROL grant disclosed no categories — the fixture cannot express a '
      'disclosure, so proving the dormant grants withhold one proves nothing';
  end if;
  raise notice '  ok   CONTROL: an immediately-released grant discloses % inventory categor(y/ies)',
    jsonb_array_length(v_live_disco -> 'categories');

  -- ★ AND THE SAME CONTROL FOR THE TWO SURFACES THAT HAD NEVER RUN. `list_estate_assets` was
  -- created by a bundle and called by no assertion; `get_estate_net_worth` was not installed at all.
  -- Asserting they withhold under a dormant condition is worth nothing until they are shown to
  -- disclose under a live one — which is the whole reason `normalized_assets` is now in the harness.
  if v_rows = 0 then
    raise exception 'FAIL: the CONTROL account_balances grant produced no asset rows — every '
      'withholding assertion about list_estate_assets below would be vacuous';
  end if;
  raise notice '  ok   CONTROL: an immediately-released account_balances grant discloses % asset row(s)', v_rows;

  perform set_config('request.jwt.claim.sub', BEN::text, true);
  set local role authenticated;
  -- The total is SUPPRESSED while account_balances is live (the subtraction-attack exclusion), so
  -- the net-worth control drops that grant first and asks again. Proving the surface can speak at
  -- all is the point; the exclusion itself is 10-A's assertion, not this file's.
  reset role;
  delete from public.access_grants
   where estate_id = A and grantee_user_id = BEN and category = 'account_balances';
  perform set_config('request.jwt.claim.sub', BEN::text, true);
  set local role authenticated;
  if not exists (select 1 from public.get_estate_net_worth(A) w where w.range_low_cents is not null) then
    reset role;
    raise exception 'FAIL: the CONTROL total_asset_value grant produced no net-worth figure — every '
      'withholding assertion about get_estate_net_worth below would be vacuous';
  end if;
  reset role;
  raise notice '  ok   CONTROL: an immediately-released total_asset_value grant discloses a bracket';

  foreach v_cond in array array[
    'after_verified_death',
    'after_verified_incapacity',
    'after_verified_death_or_incapacity',
    'after_claim_case_approval',
    'after_identity_verification',
    'never'
  ] loop
    -- inventory / discovery
    perform harness_rc.regrant(BEN, 'estate_inventory', 'category_summary', v_cond);
    perform set_config('request.jwt.claim.sub', BEN::text, true);
    set local role authenticated;
    select public.get_estate_discovery(A) into v_disco;
    reset role;
    if v_disco ? 'categories' then
      raise exception 'FAIL: % disclosed inventory categories', v_cond;
    end if;

    -- assets (list_estate_assets) and net worth
    perform harness_rc.regrant(BEN, 'account_balances', 'category_summary', v_cond);
    perform harness_rc.regrant(BEN, 'total_asset_value', 'range_only', v_cond);
    perform set_config('request.jwt.claim.sub', BEN::text, true);
    set local role authenticated;
    select count(*) into v_rows from public.list_estate_assets(A);
    if v_rows <> 0 then
      reset role;
      raise exception 'FAIL: % disclosed % asset row(s)', v_cond, v_rows;
    end if;
    if exists (select 1 from public.get_estate_net_worth(A) w
               where w.total_cents is not null or w.range_low_cents is not null) then
      reset role;
      raise exception 'FAIL: % disclosed a net-worth figure', v_cond;
    end if;
    reset role;

    -- notifications (the "may we even speak about this grant" gate)
    if public.notification_grant_is_live('active', v_cond, now()) then
      raise exception 'FAIL: % is notification-live', v_cond;
    end if;

    raise notice '  ok   % discloses nothing on inventory, assets, net worth or notifications', v_cond;
  end loop;

  -- Leave the fixture as the rest of the suite expects it.
  delete from public.access_grants
   where estate_id = A and grantee_user_id = BEN
     and category in ('estate_inventory', 'account_balances', 'total_asset_value');
end $$;

-- =================================================================================================
-- 5 · DOCUMENTS — the same firewall, through the gate that guards document rows
-- =================================================================================================
do $$
declare
  BEN uuid := '44444444-4444-4444-8444-444444444444';
  A   uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
  D   uuid := 'dddddddd-11b0-4111-8111-dddddddddddd';
  v_cond text;
  v_can boolean;
begin
  raise notice '5 · can_access_document under every dormant condition';

  -- ★ THE FIXTURE DOCUMENT DEFAULTS TO `sealed`, WHICH NO GRANT CAN OPEN. Left alone, every
  -- assertion in this section would have "passed" — refused by the CEILING, never reaching the
  -- release condition at all — and the section would have proved nothing about the thing it is named
  -- for. The control below is what caught that; this line is the fix rather than a convenience.
  --
  -- A dedicated document, so the sensitivity change is local to this file and no other suite's
  -- fixture moves underneath it.
  insert into public.documents (id, estate_id, title, sensitivity)
  values ('dddddddd-11b0-4111-8111-dddddddddddd', A, 'Release-condition fixture', 'medium')
  on conflict (id) do update set sensitivity = 'medium';

  -- CONTROL: the same grant with `immediately` must OPEN the document, or the refusals below are
  -- being produced by the ceiling, the tier, or a missing row.
  delete from public.access_grants where estate_id = A and grantee_user_id = BEN and document_id = D;
  insert into public.access_grants
    (estate_id, grantee_user_id, grantee_role, document_id, category, visibility_tier,
     release_condition, status, granted_by_user_id)
  values (A, BEN, 'beneficiary', D, null, 'limited_detail', 'immediately', 'active',
          '11111111-1111-4111-8111-111111111111');
  perform set_config('request.jwt.claim.sub', BEN::text, true);
  set local role authenticated;
  select public.can_access_document(D) into v_can;
  reset role;
  if not v_can then
    raise exception 'FAIL: the CONTROL document grant did not open the document — every refusal '
      'below would be caused by something other than the release condition';
  end if;
  raise notice '  ok   CONTROL: an immediately-released document grant opens the document';

  foreach v_cond in array array[
    'after_verified_death', 'after_verified_incapacity', 'after_verified_death_or_incapacity',
    'after_claim_case_approval', 'after_identity_verification', 'never'
  ] loop
    update public.access_grants
       set release_condition = v_cond, approved_at = now(),
           approved_by_user_id = '11111111-1111-4111-8111-111111111111'
     where estate_id = A and grantee_user_id = BEN and document_id = D;
    perform set_config('request.jwt.claim.sub', BEN::text, true);
    set local role authenticated;
    select public.can_access_document(D) into v_can;
    reset role;
    if v_can then
      raise exception 'FAIL: % opened a document (approved_at was set, and it still must not)', v_cond;
    end if;
    raise notice '  ok   % keeps the document closed even when approved', v_cond;
  end loop;

  delete from public.access_grants where estate_id = A and grantee_user_id = BEN and document_id = D;
end $$;

-- =================================================================================================
-- 6 · INFORMATION EQUIVALENCE — change the hidden world; the dormant viewer must not move
-- =================================================================================================
--
-- ★ THE STRONGEST FORM AVAILABLE, borrowed from the 10-F exit matrix. Field-by-field suppression can
-- be satisfied by nulling a column while republishing the same number elsewhere. This cannot: the
-- viewer's ENTIRE payload — every projection they can reach, as one value — is captured before and
-- after a change they are not authorized to see, and compared byte for byte.
do $$
declare
  BEN uuid := '44444444-4444-4444-8444-444444444444';
  A   uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
  v_before jsonb; v_after jsonb; v_control jsonb;
  v_asset uuid;
begin
  raise notice '6 · information equivalence under a death-conditioned grant';

  perform harness_rc.regrant(BEN, 'estate_inventory', 'category_summary', 'after_verified_death');
  perform harness_rc.regrant(BEN, 'account_balances', 'category_summary', 'after_verified_death');

  select harness_rc.composed(BEN, A) into v_before;

  -- CHANGE THE HIDDEN WORLD — a new asset in a new category, the most observable change available.
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  select public.create_estate_asset(A, 'artwork', 'A painting', null, null, null, null, null, null, 4200000)
    into v_asset;

  select harness_rc.composed(BEN, A) into v_after;

  if v_before is distinct from v_after then
    raise exception 'FAIL: a change the viewer may not see MOVED their payload. before=% after=%',
      v_before::text, v_after::text;
  end if;
  raise notice '  ok   adding a hidden asset moved no byte of the dormant viewer''s composed payload';

  -- ★ POSITIVE CONTROL. Without this, a `composed` that always returned the same constant — or an
  -- estate with nothing in it — would satisfy the equivalence above perfectly.
  perform harness_rc.regrant(BEN, 'estate_inventory', 'category_summary', 'immediately');
  select harness_rc.composed(BEN, A) into v_control;
  if v_control is not distinct from v_after then
    raise exception 'FAIL: an AUTHORIZED change did not move the payload — the equivalence assertion '
      'above is vacuous, because this probe cannot observe a disclosure at all. payload=%',
      v_control::text;
  end if;
  raise notice '  ok   CONTROL: authorizing the same viewer DOES move the payload';

  -- Restore.
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  perform public.archive_estate_asset(v_asset);
  delete from public.access_grants
   where estate_id = A and grantee_user_id = BEN
     and category in ('estate_inventory', 'account_balances', 'total_asset_value');
end $$;

-- =================================================================================================
-- 7 · REFUSAL CLASSES — a dormant condition must be byte-identical to having no grant at all
-- =================================================================================================
--
-- ★ OTHERWISE THE CONDITION ITSELF IS THE DISCLOSURE. If a death-conditioned grant produced a
-- payload distinguishable from "you have no grant", a beneficiary could learn that the owner had
-- written a death-conditioned grant naming them — which is a fact about the owner's estate plan, and
-- exactly the kind of thing Phase 11 must not start leaking as a side effect of building toward it.
do $$
declare
  BEN uuid := '44444444-4444-4444-8444-444444444444';
  STRANGER uuid := '33333333-3333-4333-8333-333333333333';
  A   uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
  v_dormant jsonb; v_nograt jsonb; v_foreign jsonb; v_anon jsonb;
begin
  raise notice '7 · refusal classes are indistinguishable';

  perform harness_rc.regrant(BEN, 'estate_inventory', 'category_summary', 'after_verified_death');
  select harness_rc.composed(BEN, A) into v_dormant;

  delete from public.access_grants where estate_id = A and grantee_user_id = BEN;
  select harness_rc.composed(BEN, A) into v_nograt;

  if v_dormant is distinct from v_nograt then
    raise exception 'FAIL: a death-conditioned grant is DISTINGUISHABLE from having no grant. dormant=% none=%',
      v_dormant::text, v_nograt::text;
  end if;
  raise notice '  ok   a dormant grant is byte-identical to no grant at all';

  -- Cross-estate and anonymous refusals, for completeness of the matrix.
  select harness_rc.composed(STRANGER, A) into v_foreign;
  select harness_rc.composed(null, A) into v_anon;
  if v_foreign -> 'discovery' ? 'categories' then
    raise exception 'FAIL: an unrelated authenticated user received inventory categories';
  end if;
  if v_anon -> 'discovery' ? 'categories' then
    raise exception 'FAIL: an anonymous caller received inventory categories';
  end if;
  raise notice '  ok   unrelated user and anonymous caller both refused';
end $$;

-- =================================================================================================
-- 7b · A LIVE GRANT ON ONE ESTATE CONFERS NOTHING ON ANOTHER
-- =================================================================================================
--
-- ★ ADDED BECAUSE A MUTATION SURVIVED. `p11b-cross-estate-grant-satisfies` widened the tier
-- lookup's estate predicate (`g.estate_id = p_estate` → `g.estate_id is not null`) and the whole
-- suite stayed green — no scenario had ever put a viewer with a LIVE grant on estate B in front of
-- estate A. Section 7's stranger held no grant anywhere, so the refusal it asserted was produced by
-- "no grant exists", never by "your grant is for a different estate". This is that missing state.
--
-- The failure this pins is not hypothetical: it is the exact shape of a professional delegate who
-- serves several estates, where any widened lookup would let their live grant on one client's
-- estate resolve a tier on another's.
do $$
declare
  STRANGER uuid := '33333333-3333-4333-8333-333333333333';
  OWNER_B  uuid := '22222222-2222-4222-8222-222222222222';
  A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
  B uuid := 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';
  v_tier_b text; v_tier_a text;
begin
  raise notice '7b · a live grant on estate B decides nothing about estate A';

  -- Owner B grants the stranger inventory on B, THROUGH THE REAL DOOR, immediately released.
  delete from public.access_grants
   where estate_id = B and grantee_user_id = STRANGER and category = 'estate_inventory';
  perform harness.expect_ok('owner B grants the stranger inventory on B',
    OWNER_B,
    format('select public.create_asset_grant(%L::uuid, %L::uuid, %L, %L, %L, %L)',
           B, STRANGER, 'beneficiary', 'estate_inventory', 'category_summary', 'immediately'));

  -- POSITIVE CONTROL: the grant is real and live where it belongs. Without this, the refusal below
  -- could be "no grant exists" — the exact vacuity that let the mutation survive.
  --
  -- ★ THE CALLER CONTEXT IS SET TO THE STRANGER FIRST. `inventory_disclosure_tier` answers its
  -- owner-check from auth.uid(), and the previous statement ran as OWNER_B — probed naively, the
  -- control reported `full_detail` because the CALLER owned B, which is this suite's own reminder
  -- that identity is carried by the session, not by the p_uid argument.
  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  select public.inventory_disclosure_tier(B, STRANGER) into v_tier_b;
  if v_tier_b is distinct from 'category_summary' then
    raise exception 'FAIL: the estate-B control grant resolved tier % on its OWN estate — the '
      'cross-estate refusal below would be vacuous', coalesce(v_tier_b, 'NULL');
  end if;
  raise notice '  ok   CONTROL: the grant is live on estate B (tier %)', v_tier_b;

  -- THE ASSERTION: that same live grant must be invisible to estate A's evaluation.
  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  select public.inventory_disclosure_tier(A, STRANGER) into v_tier_a;
  if v_tier_a is distinct from 'hidden' then
    raise exception 'FAIL: a grant on estate B resolved tier % on estate A — the tier lookup is not '
      'estate-scoped', coalesce(v_tier_a, 'NULL');
  end if;

  -- And through the composed surfaces, not only the helper: discovery on A must still refuse.
  if harness_rc.composed(STRANGER, A) -> 'discovery' ? 'categories' then
    raise exception 'FAIL: estate A discovery disclosed categories to a viewer whose only grant is on B';
  end if;
  raise notice '  ok   the estate-B grant confers nothing on estate A, helper and composed alike';

  delete from public.access_grants
   where estate_id = B and grantee_user_id = STRANGER and category = 'estate_inventory';
end $$;

-- =================================================================================================
-- 8 · A FIDUCIARY DESIGNATION STILL CONFERS NO TIER, and a death condition does not change that
-- =================================================================================================
do $$
declare
  EXEC_ uuid := '66666666-6666-4666-8666-666666666666';
  A     uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
  v_tier text;
begin
  raise notice '8 · executor designation + death condition confers nothing';

  perform set_config('request.jwt.claim.sub', EXEC_::text, true);
  if not public.is_estate_executor(A, EXEC_) then
    raise exception 'FAIL: the fixture executor is not designated — this assertion would be vacuous';
  end if;

  select public.inventory_disclosure_tier(A, EXEC_) into v_tier;
  if v_tier <> 'hidden' then
    raise exception 'FAIL: a designated executor holds tier % with no grant', v_tier;
  end if;

  -- And with a death-conditioned grant, which is the combination Phase 11 is building toward.
  perform harness_rc.regrant(EXEC_, 'estate_inventory', 'full_detail', 'after_verified_death');
  select public.inventory_disclosure_tier(A, EXEC_) into v_tier;
  if v_tier <> 'hidden' then
    raise exception 'FAIL: executor + death-conditioned grant produced tier %', v_tier;
  end if;
  raise notice '  ok   designation alone, and designation + dormant grant, both yield hidden';

  delete from public.access_grants where estate_id = A and grantee_user_id = EXEC_;
end $$;

do $$
begin
  raise notice 'ALL RELEASE-CONDITION ASSERTIONS PASSED';
end $$;
