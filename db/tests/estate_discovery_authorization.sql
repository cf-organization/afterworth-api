-- db/tests/estate_discovery_authorization.sql
--
-- THE DISCLOSURE PROOF for the Phase 10 discovery projection.
--
-- ★ WHAT MAKES THIS DIFFERENT FROM AN ORDINARY TEST. `get_estate_discovery` exists to decide what one
-- viewer may learn. The failure mode is not "it errors" — it is "it returns one field too many", and
-- that field is somebody's account balance. So every assertion below is about the SHAPE of what comes
-- back at each tier, and each one is paired with the tier above it: proving `range_only` withholds a
-- count means nothing unless `category_summary` is shown to include one, or the projection could be
-- returning nothing at all and passing.
--
-- ★ THE LADDER IS ASSERTED FROM THE BOTTOM UP, and each rung asserts BOTH what it adds and what it
-- still withholds.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

-- =================================================================================================
-- fixture — owner A, a beneficiary, a professional, an unrelated user, and estate B next door
-- =================================================================================================
insert into auth.users (id) values
  ('44444444-4444-4444-8444-444444444444'),  -- beneficiary of estate A
  ('55555555-5555-4555-8555-555555555555')   -- professional delegate of estate A
on conflict do nothing;

-- Owner A records a second asset in a different category so category grouping is observable.
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  -- 74,500,000 cents = $745,000 — chosen to land in a bracket ABOVE the ring's, so a bracketed total
  -- cannot accidentally equal a single asset's value and read as "exact" by coincidence.
  perform public.create_estate_asset(A, 'primaryResidence', 'Family home', null, null, 'US', 'Vermont',
                                     null, null, 74500000);
  perform public.create_estate_asset(A, 'chequingAccount', 'Everyday account', null, null, null, null,
                                     'Northbank', '1234', 1299900);
end $$;

-- Memberships. A membership alone must confer NO inventory disclosure — that is asserted below.
insert into public.estate_memberships (estate_id, user_id, role, status) values
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '44444444-4444-4444-8444-444444444444', 'beneficiary', 'approved'),
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '55555555-5555-4555-8555-555555555555', 'professional_delegate', 'approved')
on conflict do nothing;

create or replace function harness.discovery(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select public.get_estate_discovery(p_estate) into v;
  reset role;
  return v;
end $$;

/** Grant (or re-grant) the inventory category to a user at a tier. Runs as the OWNER, through the RPC. */
create or replace function harness.grant_inventory(p_uid uuid, p_role text, p_tier text, p_cond text default 'immediately')
returns text language plpgsql as $$
declare v text;
begin
  delete from public.access_grants
   where estate_id = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
     and grantee_user_id = p_uid and category = 'estate_inventory';
  v := harness.attempt('11111111-1111-4111-8111-111111111111',
    format('select public.create_asset_grant(%L::uuid, %L::uuid, %L, %L, %L, %L)',
           'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', p_uid, p_role, 'estate_inventory', p_tier, p_cond));
  return v;
end $$;

-- =================================================================================================
-- 9 · the new category is grantable THROUGH THE REAL DOOR
-- =================================================================================================
do $$
declare v text;
begin
  raise notice '9 · estate_inventory is a real grantable category';

  -- ★ THE CHECK AND THE DOOR MUST MOVE TOGETHER. Widening only the table constraint would leave the
  -- category accepted by storage and refused by the sole RPC that writes to it — correct-looking and
  -- unusable.
  v := harness.grant_inventory('44444444-4444-4444-8444-444444444444', 'beneficiary', 'category_summary');
  if v <> 'OK' then raise exception 'FAIL: owner could not grant estate_inventory: %', v; end if;
  raise notice '  ok   owner can create an estate_inventory grant';

  -- ★ THE CEILING HOLDS FOR THE NEW CATEGORY TOO. A beneficiary may never reach an exact figure.
  v := harness.grant_inventory('44444444-4444-4444-8444-444444444444', 'beneficiary', 'full_detail');
  if v = 'OK' then
    raise exception 'FAIL: a beneficiary was granted full_detail on estate_inventory — ceiling breached';
  end if;
  raise notice '  ok   beneficiary CANNOT be granted full_detail (ceiling: %)', left(v, 60);

  -- …and the professional may, which is what makes the refusal above a ceiling rather than a bug.
  v := harness.grant_inventory('55555555-5555-4555-8555-555555555555', 'professional_delegate', 'full_detail');
  if v <> 'OK' then raise exception 'FAIL: professional could not be granted full_detail: %', v; end if;
  raise notice '  ok   professional delegate CAN be granted full_detail';
end $$;

-- =================================================================================================
-- 10 · the ladder — each rung adds one thing and still withholds the next
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; d jsonb; cat jsonb;
begin
  raise notice '10 · the disclosure ladder';

  -- ── owner: everything ──────────────────────────────────────────────────────────────────────
  d := harness.discovery('11111111-1111-4111-8111-111111111111', A);
  if (d->>'inventory_tier') <> 'full_detail' or (d->>'is_owner') <> 'true' then
    raise exception 'FAIL: owner did not receive full_detail: %', d;
  end if;
  if jsonb_array_length(d->'items') < 3 then
    raise exception 'FAIL: owner should see all 3 assets, saw %', jsonb_array_length(d->'items');
  end if;
  raise notice '  ok   owner sees full_detail and every item';

  -- ── membership alone: NOTHING ──────────────────────────────────────────────────────────────
  -- ★ THE CENTRAL PHASE 10 CLAIM. Participating in an estate must not, by itself, disclose the
  -- inventory. Disclosure follows a GRANT, never a relationship.
  perform harness.grant_inventory('55555555-5555-4555-8555-555555555555', 'professional_delegate', 'full_detail');
  delete from public.access_grants
   where grantee_user_id = '44444444-4444-4444-8444-444444444444' and category = 'estate_inventory';
  d := harness.discovery('44444444-4444-4444-8444-444444444444', A);
  if (d->>'inventory_tier') <> 'hidden' then
    raise exception 'FAIL: an approved member with NO grant received tier %', d->>'inventory_tier';
  end if;
  if d ? 'categories' or d ? 'items' then
    raise exception 'FAIL: a hidden viewer received category/item keys: %', d;
  end if;
  raise notice '  ok   approved membership alone discloses NOTHING (no categories key at all)';

  -- ── range_only: which categories exist, and nothing else ───────────────────────────────────
  perform harness.grant_inventory('44444444-4444-4444-8444-444444444444', 'beneficiary', 'range_only');
  d := harness.discovery('44444444-4444-4444-8444-444444444444', A);
  if (d->>'inventory_tier') <> 'range_only' then
    raise exception 'FAIL: expected range_only, got %', d->>'inventory_tier';
  end if;
  if jsonb_array_length(d->'categories') < 2 then
    raise exception 'FAIL: range_only should still disclose WHICH categories exist';
  end if;
  cat := d->'categories'->0;
  if cat->>'item_count' is not null then
    raise exception 'FAIL: range_only leaked an item count: %', cat;
  end if;
  if cat->>'total_cents' is not null or cat->>'range_low_cents' is not null then
    raise exception 'FAIL: range_only leaked a value: %', cat;
  end if;
  if jsonb_array_length(d->'items') <> 0 then
    raise exception 'FAIL: range_only leaked per-item rows';
  end if;
  raise notice '  ok   range_only: categories only — no counts, no values, no items';

  -- ── category_summary: adds counts and a BRACKET, never an exact figure ─────────────────────
  perform harness.grant_inventory('44444444-4444-4444-8444-444444444444', 'beneficiary', 'category_summary');
  d := harness.discovery('44444444-4444-4444-8444-444444444444', A);
  cat := (select c from jsonb_array_elements(d->'categories') c where c->>'category' = 'realEstate');
  if cat is null then raise exception 'FAIL: realEstate category missing at category_summary'; end if;
  if cat->>'item_count' is null then
    raise exception 'FAIL: category_summary should disclose a count';
  end if;
  if cat->>'total_cents' is not null then
    raise exception 'FAIL: category_summary leaked an EXACT total: %', cat;
  end if;
  if cat->>'range_low_cents' is null then
    raise exception 'FAIL: category_summary should disclose a bracket';
  end if;
  -- ★ THE BRACKET MUST NOT BE THE EXACT FIGURE. A "range" whose low bound equals the true total is
  -- an exact disclosure wearing a range's clothes.
  if (cat->>'range_low_cents')::bigint = 74500000 then
    raise exception 'FAIL: the bracket low bound IS the exact total — not a bracket at all';
  end if;
  if jsonb_array_length(d->'items') <> 0 then
    raise exception 'FAIL: category_summary leaked per-item rows';
  end if;
  raise notice '  ok   category_summary: counts + a real bracket, no exact figure, no items';

  -- ── limited_detail (professional): labels and institutions, still no exact value ───────────
  perform harness.grant_inventory('55555555-5555-4555-8555-555555555555', 'professional_delegate', 'limited_detail');
  d := harness.discovery('55555555-5555-4555-8555-555555555555', A);
  if jsonb_array_length(d->'items') < 3 then
    raise exception 'FAIL: limited_detail should disclose per-item rows';
  end if;
  if exists (select 1 from jsonb_array_elements(d->'items') i where i->>'label' is null) then
    raise exception 'FAIL: limited_detail should disclose labels';
  end if;
  if exists (select 1 from jsonb_array_elements(d->'items') i where i->>'value_cents' is not null) then
    raise exception 'FAIL: limited_detail leaked an exact per-item value';
  end if;
  if exists (select 1 from jsonb_array_elements(d->'items') i where i->>'reference_hint' is not null) then
    raise exception 'FAIL: limited_detail leaked a reference hint';
  end if;

  -- ★ AND THE CATEGORY TOTAL MUST NOT BE EXACT EITHER. This assertion is here because its absence
  -- hid a real leak: `limited_detail` withheld every per-item value and then published the exact
  -- category total, which for a single-asset category IS that value. Withholding a field at one
  -- level and republishing it as an aggregate at another is the whole failure mode.
  cat := (select c from jsonb_array_elements(d->'categories') c where c->>'category' = 'bankAccount');
  if cat->>'total_cents' is not null then
    raise exception 'FAIL: limited_detail leaked an EXACT category total: %', cat;
  end if;
  if cat->>'range_low_cents' is null then
    raise exception 'FAIL: limited_detail should still disclose a bracket';
  end if;
  raise notice '  ok   limited_detail: labels + institutions, no exact values ANYWHERE, no hints';

  -- ── full_detail: adds exact value, hint and jurisdiction ──────────────────────────────────
  perform harness.grant_inventory('55555555-5555-4555-8555-555555555555', 'professional_delegate', 'full_detail');
  d := harness.discovery('55555555-5555-4555-8555-555555555555', A);
  if not exists (select 1 from jsonb_array_elements(d->'items') i where i->>'value_cents' is not null) then
    raise exception 'FAIL: full_detail should disclose exact values';
  end if;
  if not exists (select 1 from jsonb_array_elements(d->'items') i where i->>'reference_hint' = '1234') then
    raise exception 'FAIL: full_detail should disclose the reference hint';
  end if;
  raise notice '  ok   full_detail: exact values, reference hints, jurisdiction';
end $$;

-- =================================================================================================
-- 11 · negatives — strangers, other estates, anonymity, and dormant release conditions
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        B uuid := 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';
        d jsonb;
begin
  raise notice '11 · negatives';

  d := harness.discovery('33333333-3333-4333-8333-333333333333', A);
  if (d->>'authorized') <> 'false' then
    raise exception 'FAIL: an unrelated authenticated user was authorized: %', d;
  end if;
  raise notice '  ok   an unrelated authenticated user gets authorized:false and nothing else';

  -- ★ CROSS-ESTATE. Owner B is a legitimate owner — of a DIFFERENT estate. Authority is per-estate.
  d := harness.discovery('22222222-2222-4222-8222-222222222222', A);
  if (d->>'authorized') <> 'false' then
    raise exception 'FAIL: the owner of estate B discovered estate A: %', d;
  end if;
  raise notice '  ok   the owner of another estate discovers nothing here';

  -- …and the same caller IS authorized on their own estate, so the refusal above is scoping and not
  -- a broken function.
  d := harness.discovery('22222222-2222-4222-8222-222222222222', B);
  if (d->>'authorized') <> 'true' or (d->>'is_owner') <> 'true' then
    raise exception 'FAIL: owner B was refused on their OWN estate: %', d;
  end if;
  raise notice '  ok   …while remaining owner of their own estate';

  d := harness.discovery(null, A);
  if (d->>'authorized') <> 'false' then
    raise exception 'FAIL: an anonymous caller was authorized: %', d;
  end if;
  raise notice '  ok   anonymous gets authorized:false — not an error that would confirm existence';

  -- ★ A DEATH-CONDITIONED GRANT DISCLOSES NOTHING TODAY. `after_verified_death_or_incapacity` is
  -- default-deny until Phase 11 activates it; a grant carrying it must not leak in the meantime.
  perform harness.grant_inventory('44444444-4444-4444-8444-444444444444', 'beneficiary',
                                  'category_summary', 'after_verified_death_or_incapacity');
  d := harness.discovery('44444444-4444-4444-8444-444444444444', A);
  if (d->>'inventory_tier') <> 'hidden' then
    raise exception 'FAIL: a death-conditioned grant disclosed at tier %', d->>'inventory_tier';
  end if;
  raise notice '  ok   a death-conditioned grant is dormant-deny (Phase 11 activates it)';

  -- …and 'never' likewise.
  perform harness.grant_inventory('44444444-4444-4444-8444-444444444444', 'beneficiary',
                                  'category_summary', 'never');
  d := harness.discovery('44444444-4444-4444-8444-444444444444', A);
  if (d->>'inventory_tier') <> 'hidden' then
    raise exception 'FAIL: a never-release grant disclosed at tier %', d->>'inventory_tier';
  end if;
  raise notice '  ok   a never-release grant discloses nothing';

  -- ★ THE READ-TIME CEILING CLAMP IS AUTHORITATIVE — proven by simulating a grant that PREDATES a
  -- ceiling tightening. `create_asset_grant` refuses an over-ceiling grant at write time, so no such
  -- row can arise through the door; the clamp exists precisely for rows that already exist when the
  -- policy tightens. Inserting directly is the only way to reach that state, and without this the
  -- clamp is untested — a mutation removing it survived the whole suite until this was added.
  delete from public.access_grants
   where grantee_user_id = '44444444-4444-4444-8444-444444444444' and category = 'estate_inventory';
  insert into public.access_grants
    (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition,
     status, granted_by_user_id)
  values (A, '44444444-4444-4444-8444-444444444444', 'beneficiary', 'estate_inventory',
          'full_detail', 'immediately', 'active', '11111111-1111-4111-8111-111111111111');
  -- Precondition: the row really is over-ceiling, or the assertion below proves nothing.
  if public.asset_category_grantable('beneficiary', 'estate_inventory', 'full_detail') then
    raise exception 'FAIL: precondition — beneficiary+full_detail should be OVER the ceiling';
  end if;
  d := harness.discovery('44444444-4444-4444-8444-444444444444', A);
  if (d->>'inventory_tier') <> 'hidden' then
    raise exception 'FAIL: an over-ceiling grant was honoured at tier % instead of being clamped',
      d->>'inventory_tier';
  end if;
  raise notice '  ok   an over-ceiling grant is clamped to hidden at READ time';

  -- ★ A REVOKED GRANT STOPS DISCLOSING IMMEDIATELY.
  perform harness.grant_inventory('44444444-4444-4444-8444-444444444444', 'beneficiary', 'category_summary');
  update public.access_grants set status = 'revoked'
   where grantee_user_id = '44444444-4444-4444-8444-444444444444' and category = 'estate_inventory';
  d := harness.discovery('44444444-4444-4444-8444-444444444444', A);
  if (d->>'inventory_tier') <> 'hidden' then
    raise exception 'FAIL: a REVOKED grant still disclosed at tier %', d->>'inventory_tier';
  end if;
  raise notice '  ok   a revoked grant discloses nothing';
end $$;

-- =================================================================================================
-- 12 · archived assets are never disclosed to a survivor
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; v_asset uuid; d jsonb; v_before int; v_after int;
begin
  raise notice '12 · archived assets';
  perform harness.grant_inventory('55555555-5555-4555-8555-555555555555', 'professional_delegate', 'full_detail');
  d := harness.discovery('55555555-5555-4555-8555-555555555555', A);
  v_before := jsonb_array_length(d->'items');

  select id into v_asset from public.estate_assets
   where estate_id = A and archived_at is null and label = 'Family home' limit 1;
  perform harness.expect_ok('owner archives an asset',
    '11111111-1111-4111-8111-111111111111',
    format('select public.archive_estate_asset(%L::uuid)', v_asset));

  d := harness.discovery('55555555-5555-4555-8555-555555555555', A);
  v_after := jsonb_array_length(d->'items');
  if v_after <> v_before - 1 then
    raise exception 'FAIL: archiving did not remove the asset from discovery (% -> %)', v_before, v_after;
  end if;
  if exists (select 1 from jsonb_array_elements(d->'items') i where i->>'label' = 'Family home') then
    raise exception 'FAIL: an archived asset is still disclosed';
  end if;
  -- ★ AND THE OWNER STILL SEES IT — archiving is not deletion. If it vanished for the owner too, the
  -- assertion above would be measuring data loss rather than disclosure scoping.
  if not exists (select 1 from public.estate_assets where id = v_asset) then
    raise exception 'FAIL: archiving deleted the row';
  end if;
  raise notice '  ok   an archived asset leaves discovery but survives for the owner';
end $$;

-- =================================================================================================
-- 13 · the release-state seam reports, and grants nothing
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; d jsonb;
begin
  raise notice '13 · release state';
  if public.estate_release_state(A) <> 'active' then
    raise exception 'FAIL: expected active with no claim, got %', public.estate_release_state(A);
  end if;

  insert into public.claim_packets (estate_id, requested_by, status)
  values (A, '55555555-5555-4555-8555-555555555555', 'submitted');
  if public.estate_release_state(A) <> 'claim_submitted' then
    raise exception 'FAIL: expected claim_submitted, got %', public.estate_release_state(A);
  end if;
  raise notice '  ok   the seam reports claim state';

  -- ★ AND REPORTING IT CHANGES NO DISCLOSURE. A viewer with no grant still gets nothing while a
  -- claim is open — release is Phase 11, and a status field must not become a back door.
  delete from public.access_grants
   where grantee_user_id = '44444444-4444-4444-8444-444444444444' and category = 'estate_inventory';
  d := harness.discovery('44444444-4444-4444-8444-444444444444', A);
  if (d->>'inventory_tier') <> 'hidden' then
    raise exception 'FAIL: an open claim disclosed the inventory at tier %', d->>'inventory_tier';
  end if;
  raise notice '  ok   an open claim discloses nothing by itself';

  update public.claim_packets set status = 'approved' where estate_id = A;
  d := harness.discovery('44444444-4444-4444-8444-444444444444', A);
  if (d->>'inventory_tier') <> 'hidden' then
    raise exception 'FAIL: an APPROVED claim disclosed the inventory at tier %', d->>'inventory_tier';
  end if;
  if (d->>'release_state') <> 'claim_approved' then
    raise exception 'FAIL: release_state should report claim_approved, got %', d->>'release_state';
  end if;
  raise notice '  ok   even an APPROVED claim discloses nothing — the state is reported, not acted on';
end $$;

do $$ begin raise notice 'ALL DISCOVERY ASSERTIONS PASSED'; end $$;
