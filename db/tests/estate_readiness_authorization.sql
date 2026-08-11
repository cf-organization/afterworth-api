-- db/tests/estate_readiness_authorization.sql
--
-- THE READINESS PROOF — owner-only authority, and no aggregate that reconstructs a withheld fact.
--
-- ★ WHY THE AGGREGATE TESTS ARE MANDATORY HERE. Phase 10-B shipped a HIGH defect in which
-- `limited_detail` withheld each item's value and then published the exact category total that
-- equalled it. Readiness deals almost entirely in derived facts and counts, so it is the surface most
-- exposed to that failure mode. The rule it established:
--
--     WITHHOLDING IS A PROPERTY OF INFORMATION, NOT OF FIELDS.
--
-- ★ THE ONE-RECORD CASE IS THE POSITIVE CONTROL. A count over a single-record category IS that
-- record. Testing only multi-record fixtures is how the 10-B leak survived 54 assertions.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

create or replace function harness.readiness(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select public.get_estate_readiness(p_estate) into v;
  reset role;
  return v;
end $$;

/** Count findings of one kind. */
create or replace function harness.finding_count(p_payload jsonb, p_kind text)
returns int language sql immutable as $$
  select count(*)::int from jsonb_array_elements(coalesce(p_payload->'findings', '[]'::jsonb)) f
   where f->>'kind' = p_kind;
$$;

-- =================================================================================================
-- 14 · owner-only authority
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        B uuid := 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';
        d jsonb;
begin
  raise notice '14 · readiness authority';

  d := harness.readiness('11111111-1111-4111-8111-111111111111', A);
  if (d->>'authorized') <> 'true' then
    raise exception 'FAIL: the owner was refused their own readiness: %', d;
  end if;
  raise notice '  ok   owner receives readiness for their own estate';

  -- ★ EVERY NON-OWNER, INCLUDING ONES WITH REAL STANDING IN THIS ESTATE. A readiness list is a
  -- census of everything the estate holds; handing it to a beneficiary would reconstruct precisely
  -- what get_estate_discovery spent Phase 10-A withholding.
  d := harness.readiness('44444444-4444-4444-8444-444444444444', A);
  if (d->>'authorized') <> 'false' or d ? 'findings' then
    raise exception 'FAIL: an approved BENEFICIARY member received readiness: %', d;
  end if;
  raise notice '  ok   an approved beneficiary member is refused (and gets no findings key)';

  d := harness.readiness('55555555-5555-4555-8555-555555555555', A);
  if (d->>'authorized') <> 'false' or d ? 'findings' then
    raise exception 'FAIL: a PROFESSIONAL DELEGATE received readiness: %', d;
  end if;
  raise notice '  ok   a professional delegate is refused — 10-D owns their workspace';

  d := harness.readiness('33333333-3333-4333-8333-333333333333', A);
  if (d->>'authorized') <> 'false' then
    raise exception 'FAIL: an unrelated user received readiness: %', d;
  end if;
  raise notice '  ok   an unrelated authenticated user is refused';

  -- ★ CROSS-ESTATE. Owner B is a legitimate owner — of a DIFFERENT estate.
  d := harness.readiness('22222222-2222-4222-8222-222222222222', A);
  if (d->>'authorized') <> 'false' then
    raise exception 'FAIL: the owner of estate B received estate A readiness: %', d;
  end if;
  -- …and is authorized on their own, so the refusal is scoping rather than a broken function.
  if (harness.readiness('22222222-2222-4222-8222-222222222222', B)->>'authorized') <> 'true' then
    raise exception 'FAIL: owner B was refused on their OWN estate';
  end if;
  raise notice '  ok   cross-estate refused, while remaining owner of their own';

  d := harness.readiness(null, A);
  if (d->>'authorized') <> 'false' then
    raise exception 'FAIL: an anonymous caller received readiness: %', d;
  end if;
  raise notice '  ok   anonymous is refused';

  -- ★ A GRANT DOES NOT PROMOTE ANYONE. The beneficiary holds an active estate_inventory grant from
  -- the discovery suite; a disclosure grant must not become owner authority.
  perform harness.grant_inventory('44444444-4444-4444-8444-444444444444', 'beneficiary', 'category_summary');
  if (harness.readiness('44444444-4444-4444-8444-444444444444', A)->>'authorized') <> 'false' then
    raise exception 'FAIL: an inventory GRANT conferred readiness access';
  end if;
  raise notice '  ok   an inventory grant confers no readiness access';
end $$;

-- =================================================================================================
-- 15 · findings are factual, and archived rows contribute nothing
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        OWNER_A uuid := '11111111-1111-4111-8111-111111111111';
        d jsonb; v_asset uuid; v_before int; v_after int;
begin
  raise notice '15 · findings';

  d := harness.readiness(OWNER_A, A);
  if jsonb_array_length(d->'findings') = 0 then
    raise exception 'FAIL: precondition — the fixture estate should produce findings';
  end if;
  raise notice '  ok   the owner receives % finding(s)', jsonb_array_length(d->'findings');

  -- ★ NO SCORE, NO PERCENTAGE, NO GRADE — asserted on the PAYLOAD, not merely on the UI. A ratio
  -- emitted here would reach every future client whether or not one screen chose to render it.
  if d ? 'score' or d ? 'percent' or d ? 'percentage' or d ? 'grade' or d ? 'health' or d ? 'ready' then
    raise exception 'FAIL: the readiness payload carries a score-like key: %', (select jsonb_object_keys(d) limit 1);
  end if;
  raise notice '  ok   the payload carries no score, percentage, grade or health key';

  -- An asset with no linked document produces a missing_evidence finding.
  if harness.finding_count(d, 'missing_evidence') = 0 then
    raise exception 'FAIL: expected at least one missing_evidence finding';
  end if;
  raise notice '  ok   missing_evidence is reported for an asset with no linked document';

  -- ★ ARCHIVING REMOVES THE FINDING. The owner retired the record; asking them to fix it would be
  -- nagging about something they already dealt with.
  v_before := jsonb_array_length(d->'findings');
  select id into v_asset from public.estate_assets
   where estate_id = A and archived_at is null
     and not exists (select 1 from public.estate_asset_documents l where l.asset_id = id)
   limit 1;
  if v_asset is null then
    raise exception 'FAIL: precondition — no un-evidenced live asset to archive';
  end if;
  perform harness.expect_ok('owner archives it', OWNER_A,
    format('select public.archive_estate_asset(%L::uuid)', v_asset));
  v_after := jsonb_array_length(harness.readiness(OWNER_A, A)->'findings');
  if v_after >= v_before then
    raise exception 'FAIL: archiving did not remove its findings (% -> %)', v_before, v_after;
  end if;
  raise notice '  ok   an archived asset contributes no findings (% -> %)', v_before, v_after;
  perform harness.expect_ok('owner restores it', OWNER_A,
    format('select public.restore_estate_asset(%L::uuid)', v_asset));

  -- ★ A LINKED DOCUMENT CLEARS THE EVIDENCE FINDING — the other direction, so the assertion above
  -- is about evidence rather than about the row merely existing.
  v_before := harness.finding_count(harness.readiness(OWNER_A, A), 'missing_evidence');
  perform harness.expect_ok('owner links a document', OWNER_A,
    format('select public.link_asset_document(%L::uuid, %L::uuid)', v_asset, 'dddddddd-1111-4111-8111-dddddddddddd'));
  v_after := harness.finding_count(harness.readiness(OWNER_A, A), 'missing_evidence');
  if v_after >= v_before then
    raise exception 'FAIL: linking evidence did not clear a missing_evidence finding (% -> %)', v_before, v_after;
  end if;
  raise notice '  ok   linking a document clears the finding (% -> %)', v_before, v_after;

  -- ★ A RECORDED ZERO IS NOT A MISSING VALUE. Null is the absence of a statement; zero is one.
  perform harness.expect_ok('owner records a zero value', OWNER_A,
    format('select public.update_estate_asset(%L::uuid, null, null, null, null, null, null, null, null, 0)', v_asset));
  if exists (
    select 1 from jsonb_array_elements(harness.readiness(OWNER_A, A)->'findings') f
     where f->>'kind' = 'missing_value' and (f->>'subject_id')::uuid = v_asset
  ) then
    raise exception 'FAIL: a recorded ZERO was reported as a missing value';
  end if;
  raise notice '  ok   a recorded zero is not reported as a missing value';
end $$;

-- =================================================================================================
-- 16 · AGGREGATE DISCLOSURE — the Phase 10-B lesson, applied to counts
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        OWNER_A uuid := '11111111-1111-4111-8111-111111111111';
        BENE uuid := '44444444-4444-4444-8444-444444444444';
        PRO  uuid := '55555555-5555-4555-8555-555555555555';
        d jsonb;
begin
  raise notice '16 · aggregate disclosure';

  -- ★ THE ONE-RECORD POSITIVE CONTROL. A count over a single record IS that record, so if any count
  -- were to escape to a non-owner it would disclose a specific asset — not a statistic. Every
  -- non-owner therefore receives NO count key at all, not a zero.
  d := harness.readiness(BENE, A);
  if d ? 'finding_count' or d ? 'findings' then
    raise exception 'FAIL: a refused viewer received a count or a findings list: %', d;
  end if;
  raise notice '  ok   a refused viewer receives NO count key — not a zero';

  d := harness.readiness(PRO, A);
  if d ? 'finding_count' or d ? 'findings' then
    raise exception 'FAIL: a professional received a count or findings: %', d;
  end if;
  raise notice '  ok   a professional receives no count either';

  -- ★ THE REFUSAL IS BYTE-IDENTICAL ACROSS CAUSES. A stranger, a beneficiary, a professional and the
  -- owner of another estate must be indistinguishable — otherwise the shape of the refusal becomes
  -- an oracle for what relationship the caller has to this estate.
  if harness.readiness(BENE, A)::text <> harness.readiness('33333333-3333-4333-8333-333333333333', A)::text
     or harness.readiness(PRO, A)::text <> harness.readiness(null, A)::text
     or harness.readiness(BENE, A)::text <> harness.readiness('22222222-2222-4222-8222-222222222222', A)::text then
    raise exception 'FAIL: refusals differ by cause — the payload is an oracle';
  end if;
  raise notice '  ok   every refusal is byte-identical, whatever the cause';

  -- ★ THE OWNER'S COUNT MATCHES THE OWNER'S LIST. It has no denominator and cannot exceed what is
  -- already in the same payload, so it discloses nothing the recipient does not already hold.
  d := harness.readiness(OWNER_A, A);
  if (d->>'finding_count')::int <> jsonb_array_length(d->'findings') then
    raise exception 'FAIL: finding_count disagrees with the findings it counts';
  end if;
  raise notice '  ok   the owner count equals the owner list — no hidden denominator';

  -- ★ A DEATH-CONDITIONED GRANT STILL RELEASES NOTHING, INCLUDING THROUGH READINESS.
  perform harness.grant_inventory(BENE, 'beneficiary', 'category_summary', 'after_verified_death_or_incapacity');
  if (harness.readiness(BENE, A)->>'authorized') <> 'false' then
    raise exception 'FAIL: a death-conditioned grant produced readiness access';
  end if;
  raise notice '  ok   a death-conditioned grant produces no readiness access';

  -- ★ AND AN APPROVED CLAIM STILL RELEASES NOTHING. The claim rows are left approved by the
  -- discovery suite, so this asserts against the state Phase 11 will one day change.
  if public.estate_release_state(A) <> 'claim_approved' then
    raise exception 'FAIL: precondition — expected an approved claim from the discovery suite, got %',
      public.estate_release_state(A);
  end if;
  if (harness.readiness(BENE, A)->>'authorized') <> 'false' then
    raise exception 'FAIL: an APPROVED claim produced readiness access';
  end if;
  raise notice '  ok   an APPROVED claim still produces no readiness access';
end $$;

-- =================================================================================================
-- 17 · DEFINER does not launder authority
-- =================================================================================================
do $$
declare v_secdef int;
begin
  raise notice '17 · definer posture';
  select count(*) into v_secdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef and p.proname = 'get_estate_readiness';
  if v_secdef <> 1 then
    raise exception 'FAIL: get_estate_readiness is not SECURITY DEFINER';
  end if;
  -- It runs as the function owner and is STILL refused, because the rule keys off auth.uid().
  if (harness.readiness('33333333-3333-4333-8333-333333333333',
                        'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')->>'authorized') <> 'false' then
    raise exception 'FAIL: DEFINER laundered authority';
  end if;
  raise notice '  ok   DEFINER does not launder authority';
end $$;

do $$ begin raise notice 'ALL READINESS ASSERTIONS PASSED'; end $$;
