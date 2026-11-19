-- db/tests/capture_discovery_payloads.sql
--
-- Emit one REAL `get_estate_discovery` payload per viewer class / tier, so the mobile decoder is
-- written against what the server actually returns rather than what a developer imagines it returns.
--
-- ★ THIS IS THE `description: z.string()` LESSON APPLIED BEFORE THE FACT. A decoder built from a
-- hand-written fixture agrees with whatever the client already believes; the only way to learn the
-- real nullability is to read a payload the database produced. Run AFTER the authorization suite, so
-- the fixture state already exists.
--
-- Output: one row per scenario, `label | payload`. The runner writes it to a JSON fixture.

\set ON_ERROR_STOP on

-- Reset to a known, fully-populated state: the authorization suite leaves grants revoked/archived.
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; v_asset uuid;
begin
  -- Restore the archived asset so the capture covers a populated estate.
  select id into v_asset from public.estate_assets where estate_id = A and archived_at is not null limit 1;
  if v_asset is not null then
    perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
    perform public.restore_estate_asset(v_asset);
  end if;
end $$;


/** Set a viewer's inventory tier and return their uid, so it can be used inline above. */
create or replace function harness.set_tier(p_uid uuid, p_role text, p_tier text)
returns uuid language plpgsql as $$
begin
  perform harness.grant_inventory(p_uid, p_role, p_tier, 'immediately');
  return p_uid;
end $$;

create or replace function harness.clear_tier(p_uid uuid)
returns uuid language plpgsql as $$
begin
  delete from public.access_grants
   where grantee_user_id = p_uid and category = 'estate_inventory';
  return p_uid;
end $$;

/**
 * ★ 0066 — rebuild the two-estate beneficiary fixture for ONE scenario and return the beneficiary's
 * uid. The authorization suite that proves these payloads removes its rows afterwards, so the capture
 * re-creates exactly the state each scenario needs (idempotent inserts, grants through the real door,
 * prior grants replaced). The ids and amounts are the suite's own: A = two cash accounts whose sum
 * crosses a bracket boundary plus one investment; B = one cash account; P = the precision-test pair.
 */
create or replace function harness_cd.capture_setup(p_scenario text)
returns uuid language plpgsql as $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  A uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa'; B uuid := 'cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb';
  P uuid := 'cdcdcdcd-9999-4999-8999-cdcdcdcdcd99'; U uuid := 'cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcdee';
  O uuid := 'cdcdcdcd-0000-4000-8000-cdcdcdcdcd00';
begin
  insert into auth.users (id) values (BEN), ('cdcdcdcd-0002-4002-8002-cdcdcdcdcd02'), ('cdcdcdcd-0003-4003-8003-cdcdcdcdcd03') on conflict do nothing;
  insert into public.estates (id, owner_id) values
    (A, 'cdcdcdcd-0002-4002-8002-cdcdcdcdcd02'), (P, 'cdcdcdcd-0002-4002-8002-cdcdcdcdcd02'),
    (B, 'cdcdcdcd-0003-4003-8003-cdcdcdcdcd03'), (U, 'cdcdcdcd-0003-4003-8003-cdcdcdcdcd03'), (O, BEN)
  on conflict do nothing;
  if not exists (select 1 from public.normalized_assets where estate_id = A) then
    insert into public.normalized_assets (estate_id, connection_id, institution_name, asset_group, balance_cents, currency) values
      (A, gen_random_uuid(), 'A Cash One', 'cashBank', 2800000, 'USD'), (A, gen_random_uuid(), 'A Cash Two', 'cashBank', 2900000, 'USD'),
      (A, gen_random_uuid(), 'A Broker', 'investmentBrokerage', 400000, 'USD'),
      (P, gen_random_uuid(), 'P Cash', 'cashBank', 4800000, 'USD'), (P, gen_random_uuid(), 'P Broker', 'investmentBrokerage', 400000, 'USD'),
      (B, gen_random_uuid(), 'B Cash', 'cashBank', 1500000, 'USD'), (U, gen_random_uuid(), 'U Cash', 'cashBank', 7700000, 'USD'),
      (O, gen_random_uuid(), 'O Cash', 'cashBank', 900000, 'USD');
  end if;
  -- a clean slate for the beneficiary on every scenario, then exactly the grants the scenario names
  delete from public.access_grants where grantee_user_id = BEN and estate_id in (A, B, P, U, O);
  case p_scenario
    when 'A' then       perform harness_cd.grant(A, BEN, 'beneficiary', 'account_balances', 'category_summary');
    when 'A_NAMES' then perform harness_cd.grant(A, BEN, 'beneficiary', 'account_balances', 'category_summary');
                        perform harness_cd.grant(A, BEN, 'beneficiary', 'institution_names', 'full_detail');
    when 'B' then       perform harness_cd.grant(B, BEN, 'beneficiary', 'account_balances', 'range_only');
                        perform harness_cd.grant(B, BEN, 'beneficiary', 'total_asset_value', 'range_only');
    when 'P' then       perform harness_cd.grant(P, BEN, 'beneficiary', 'account_balances', 'category_summary');
                        perform harness_cd.grant(P, BEN, 'beneficiary', 'total_asset_value', 'range_only');
    else null;  -- 'U' (ungranted) and 'O' (owned) need no grant
  end case;
  return BEN;
end $$;

create or replace function harness.capture(p_label text, p_uid uuid, p_estate uuid)
returns table (label text, payload jsonb) language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select public.get_estate_discovery(p_estate) into v;
  reset role;
  return query select p_label, v;
end $$;

/**
 * Make a DEDICATED persona a professional delegate of estate B (which holds NO assets) and grant
 * them the inventory category there. Estate B is owned by owner B, so the grant runs as THAT owner —
 * through the same RPC, never a direct insert.
 *
 * ★ A DEDICATED PERSONA, NOT THE ESTATE-A DELEGATE. A first version reused `55555555…` and thereby
 * made them a member of estate B — which silently turned `workspace_cross_estate_refused` into an
 * AUTHORIZED payload, because that scenario asks exactly this user about exactly this estate. One
 * fixture quietly rewrote another's meaning, which is the cross-suite hygiene failure the readiness
 * suite already had to fix once.
 */
create or replace function harness.grant_empty_estate(p_uid uuid)
returns uuid language plpgsql as $$
declare B uuid := 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';
begin
  insert into public.estate_memberships (estate_id, user_id, role, status)
  select B, p_uid, 'professional_delegate', 'approved'
   where not exists (
     select 1 from public.estate_memberships
      where estate_id = B and user_id = p_uid and role = 'professional_delegate');
  delete from public.access_grants
   where estate_id = B and grantee_user_id = p_uid and category = 'estate_inventory';
  perform harness.attempt('22222222-2222-4222-8222-222222222222',
    format('select public.create_asset_grant(%L::uuid, %L::uuid, %L, %L, %L, %L)',
           B, p_uid, 'professional_delegate', 'estate_inventory', 'category_summary', 'immediately'));
  return p_uid;
end $$;

create or replace function harness.capture_workspace(p_label text, p_uid uuid, p_estate uuid)
returns table (label text, payload jsonb) language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select public.get_professional_workspace(p_estate) into v;
  reset role;
  return query select p_label, v;
end $$;

create or replace function harness.capture_readiness(p_label text, p_uid uuid, p_estate uuid)
returns table (label text, payload jsonb) language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select public.get_estate_readiness(p_estate) into v;
  reset role;
  return query select p_label, v;
end $$;

select jsonb_pretty(jsonb_object_agg(label, payload)) as captured
from (
  -- Owner — the maximal payload.
  select * from harness.capture('owner',
    '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- Beneficiary at range_only — existence of categories only.
  select * from harness.capture('beneficiary_range_only',
    (select harness.set_tier('44444444-4444-4444-8444-444444444444', 'beneficiary', 'range_only')),
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- Beneficiary at category_summary — counts + brackets.
  select * from harness.capture('beneficiary_category_summary',
    (select harness.set_tier('44444444-4444-4444-8444-444444444444', 'beneficiary', 'category_summary')),
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- Professional at limited_detail — labels, no values.
  select * from harness.capture('professional_limited_detail',
    (select harness.set_tier('55555555-5555-4555-8555-555555555555', 'professional_delegate', 'limited_detail')),
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- Professional at full_detail — everything a non-owner can reach.
  select * from harness.capture('professional_full_detail',
    (select harness.set_tier('55555555-5555-4555-8555-555555555555', 'professional_delegate', 'full_detail')),
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- Member with NO grant — authorized to be here, discovers nothing.
  select * from harness.capture('member_no_grant',
    (select harness.clear_tier('44444444-4444-4444-8444-444444444444')),
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- A stranger, and an anonymous caller.
  select * from harness.capture('stranger',
    '33333333-3333-4333-8333-333333333333', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  select * from harness.capture('anonymous', null, 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- An estate with NO assets at all — the genuinely empty projection.
  select * from harness.capture('owner_empty_estate',
    '22222222-2222-4222-8222-222222222222', 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb')
  union all
  -- ★ 0066 — ONE beneficiary identity across estates the suite re-creates for the capture (the
  --   authorization suite removes its own fixture in §9, so the state is rebuilt here, idempotently,
  --   through the same helpers). Every scenario below is the same person asking about a different
  --   estate; the payloads differ ONLY because the estate differs.
  select * from harness.capture('beneficiary_connector_category_totals',
    (select harness_cd.capture_setup('A')), 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa')
  union all
  select * from harness.capture('beneficiary_connector_categories_only',
    (select harness_cd.capture_setup('B')), 'cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb')
  union all
  select * from harness.capture('beneficiary_connector_suppressed_total',
    (select harness_cd.capture_setup('P')), 'cdcdcdcd-9999-4999-8999-cdcdcdcdcd99')
  union all
  select * from harness.capture('beneficiary_connector_with_names',
    (select harness_cd.capture_setup('A_NAMES')), 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa')
  union all
  select * from harness.capture('beneficiary_connector_ungranted',
    (select harness_cd.capture_setup('U')), 'cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcdee')
  union all
  select * from harness.capture('beneficiary_connector_owns_other_estate',
    (select harness_cd.capture_setup('O')), 'cdcdcdcd-0000-4000-8000-cdcdcdcdcd00')
  union all
  -- ── Phase 10-C readiness, same discipline: the decoder is written against real payloads ────────
  select * from harness.capture_readiness('readiness_owner',
    '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  select * from harness.capture_readiness('readiness_owner_empty',
    '22222222-2222-4222-8222-222222222222', 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb')
  union all
  select * from harness.capture_readiness('readiness_beneficiary_refused',
    '44444444-4444-4444-8444-444444444444', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  select * from harness.capture_readiness('readiness_professional_refused',
    '55555555-5555-4555-8555-555555555555', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  select * from harness.capture_readiness('readiness_anonymous', null, 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- ── Phase 10-D workspace, same discipline ─────────────────────────────────────────────────────
  -- ★ THE DELEGATE AT category_summary — the tier the real E2E fixture grants, so the render tests
  -- and the deployed fixture are describing the same rung.
  select * from harness.capture_workspace('workspace_delegate_category_summary',
    (select harness.set_tier('55555555-5555-4555-8555-555555555555', 'professional_delegate', 'category_summary')),
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- The delegate at full_detail — the maximal non-owner payload, where per-item rows appear.
  select * from harness.capture_workspace('workspace_delegate_full_detail',
    (select harness.set_tier('55555555-5555-4555-8555-555555555555', 'professional_delegate', 'full_detail')),
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- ★ THE DELEGATE WITH NOTHING RELEASED — the branch that must render the empty state and must NOT
  -- carry an `inventory` key at all. Captured rather than constructed, because "absent" and "empty"
  -- are exactly the distinction a hand-written fixture gets wrong.
  select * from harness.capture_workspace('workspace_delegate_nothing_shared',
    (select harness.clear_tier('55555555-5555-4555-8555-555555555555')),
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- ★ A GRANT OVER AN ESTATE THAT HOLDS NOTHING — `inventory` PRESENT with ZERO categories.
  --
  -- This is the case that makes the screen's "omit an empty section" rule observable. Every other
  -- authorized fixture either has no `inventory` key or has one with categories in it, so a screen
  -- that rendered a "Property shared with you" heading over an empty list would look identical to a
  -- correct one — a mutation deleting the emptiness check SURVIVED the whole suite for exactly that
  -- reason. It is a genuinely reachable product state: an owner may grant a delegate access before
  -- recording any property.
  select * from harness.capture_workspace('workspace_delegate_granted_empty_estate',
    (select harness.grant_empty_estate('88888888-8888-4888-8888-888888888888')),
    'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb')
  union all
  -- The delegate who ALSO holds a trustee designation — capacity is additive, never a relationship.
  select * from harness.capture_workspace('workspace_delegate_with_trustee',
    '77777777-7777-4777-8777-777777777777', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  -- Every refusal class, so the client can prove they are byte-identical against REAL output.
  select * from harness.capture_workspace('workspace_owner_refused',
    '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  select * from harness.capture_workspace('workspace_beneficiary_refused',
    '44444444-4444-4444-8444-444444444444', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  select * from harness.capture_workspace('workspace_executor_only_refused',
    '66666666-6666-4666-8666-666666666666', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  select * from harness.capture_workspace('workspace_stranger_refused',
    '33333333-3333-4333-8333-333333333333', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
  union all
  select * from harness.capture_workspace('workspace_cross_estate_refused',
    '55555555-5555-4555-8555-555555555555', 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb')
  union all
  select * from harness.capture_workspace('workspace_anonymous_refused', null,
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')
) s;
