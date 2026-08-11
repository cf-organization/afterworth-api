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
) s;
