-- db/tests/beneficiary_connector_disclosure_authorization.sql
--
-- THE AUTHORIZATION PROOF for migration 0066 — beneficiary connector disclosure, scoped per estate.
--
-- ★ ONE BENEFICIARY IDENTITY, SEVERAL ESTATES. Separate users per estate cannot prove scope; the same
--   person must hold "Category totals" in A, "Categories only" in B, own O outright, and be a stranger
--   to U — and each read must answer for the estate it was asked about and no other.
--
-- ★ THE AMOUNTS ARE CHOSEN SO A LEAK WOULD BE UNMISTAKABLE. Estate A holds two cash accounts, $28,000
--   and $29,000 — each inside the $10k–50k bracket — whose SUM, $57,000, lands in $50k–100k. A per-
--   account bracket and a category bracket are therefore different numbers, and "the sum's bracket,
--   once" is distinguishable from "each account's bracket" and from "the sum's bracket per account".
--
-- ★ EVERY NEGATIVE IS PAIRED WITH ITS POSITIVE, every absence beside a presence, and the harness
--   proves it can see what it later asserts is missing. Exit contract: raises on the first failure.

\set ON_ERROR_STOP on

create schema if not exists harness_cd;

-- ── identities and estates (fixed ids; removed in §9) ───────────────────────────────────────────
insert into auth.users (id) values
  ('cdcdcdcd-0001-4001-8001-cdcdcdcdcd01'),   -- BEN  — the one beneficiary identity
  ('cdcdcdcd-0002-4002-8002-cdcdcdcdcd02'),   -- OA   — owner of A and P
  ('cdcdcdcd-0003-4003-8003-cdcdcdcdcd03'),   -- OB   — owner of B and U
  ('cdcdcdcd-0004-4004-8004-cdcdcdcdcd04')    -- PRO  — professional delegate on A
on conflict do nothing;
insert into public.estates (id, owner_id) values
  ('cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa', 'cdcdcdcd-0002-4002-8002-cdcdcdcdcd02'),  -- A
  ('cdcdcdcd-9999-4999-8999-cdcdcdcdcd99', 'cdcdcdcd-0002-4002-8002-cdcdcdcdcd02'),  -- P (precision demo)
  ('cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb', 'cdcdcdcd-0003-4003-8003-cdcdcdcdcd03'),  -- B
  ('cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcdee', 'cdcdcdcd-0003-4003-8003-cdcdcdcdcd03'),  -- U (ungranted)
  ('cdcdcdcd-0000-4000-8000-cdcdcdcdcd00', 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01'),  -- O (BEN's own)
  ('cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcde2', 'cdcdcdcd-0003-4003-8003-cdcdcdcdcd03')   -- E (non-USD; BEN ungranted)
on conflict do nothing;
-- ★ EVERY ROW CARRIES A NONEMPTY MASKED IDENTIFIER, ONE CARRIES A NONEMPTY HOLDING, ONE ESTATE IS
--   NOT IN USD. "The ending was not revealed" / "no holdings leaked" / "no currency leaked" are
--   assertions only when there is an ending, a holding and a currency to leak.
insert into public.normalized_assets (estate_id, connection_id, institution_name, asset_group, balance_cents, currency, masked_identifier, holdings) values
  ('cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa', gen_random_uuid(), 'A Cash One',  'cashBank',            2800000, 'USD', '****4321', '[]'),
  ('cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa', gen_random_uuid(), 'A Cash Two',  'cashBank',            2900000, 'USD', '****8765', '[]'),
  ('cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa', gen_random_uuid(), 'A Broker',    'investmentBrokerage',  400000, 'USD', '****2468', '[{"ticker":"SYNTH","quantity":12,"value_cents":400000}]'),
  ('cdcdcdcd-9999-4999-8999-cdcdcdcdcd99', gen_random_uuid(), 'P Cash',      'cashBank',            4800000, 'USD', '****1111', '[]'),
  ('cdcdcdcd-9999-4999-8999-cdcdcdcdcd99', gen_random_uuid(), 'P Broker',    'investmentBrokerage',  400000, 'USD', '****2222', '[]'),
  ('cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb', gen_random_uuid(), 'B Cash',      'cashBank',            1500000, 'USD', '****3333', '[]'),
  ('cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcdee', gen_random_uuid(), 'U Cash',      'cashBank',            7700000, 'USD', '****4444', '[]'),
  ('cdcdcdcd-0000-4000-8000-cdcdcdcdcd00', gen_random_uuid(), 'O Cash',      'cashBank',             900000, 'USD', '****5555', '[]'),
  ('cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcde2', gen_random_uuid(), 'E Bank',      'cashBank',            1234567, 'EUR', '****9999', '[]')
on conflict do nothing;

-- ── readers, run as the viewer under the authenticated role ────────────────────────────────────
create or replace function harness_cd.as_viewer(p_uid uuid, p_claims jsonb) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', coalesce(p_claims::text, '{}'), true);
end $$;

create or replace function harness_cd.disco(p_uid uuid, p_claims jsonb, p_estate uuid) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform harness_cd.as_viewer(p_uid, p_claims);
  set local role authenticated;
  select public.get_estate_discovery(p_estate) into v;
  reset role;
  return v;
end $$;

create or replace function harness_cd.rows(p_uid uuid, p_claims jsonb, p_estate uuid) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform harness_cd.as_viewer(p_uid, p_claims);
  set local role authenticated;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at), '[]'::jsonb) into v from public.list_estate_assets(p_estate) a;
  reset role;
  return v;
end $$;

create or replace function harness_cd.total(p_uid uuid, p_claims jsonb, p_estate uuid) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform harness_cd.as_viewer(p_uid, p_claims);
  set local role authenticated;
  select to_jsonb(w) into v from public.get_estate_net_worth(p_estate) w;
  reset role;
  return v;
end $$;

/** Grant through the REAL door, as the estate's owner. Replaces any prior grant in that category. */
create or replace function harness_cd.grant(p_estate uuid, p_uid uuid, p_role text, p_cat text, p_tier text) returns text language plpgsql as $$
declare v_owner uuid; v text;
begin
  select owner_id into v_owner from public.estates where id = p_estate;
  delete from public.access_grants where estate_id = p_estate and grantee_user_id = p_uid and category = p_cat;
  v := harness.attempt(v_owner, format('select public.create_asset_grant(%L::uuid, %L::uuid, %L, %L, %L, %L)',
                                       p_estate, p_uid, p_role, p_cat, p_tier, 'immediately'));
  return v;
end $$;

/** Revoke through the REAL door, as the estate's owner. */
create or replace function harness_cd.revoke(p_estate uuid, p_uid uuid, p_cat text) returns text language plpgsql as $$
declare v_owner uuid; v_grant uuid;
begin
  select owner_id into v_owner from public.estates where id = p_estate;
  select id into v_grant from public.access_grants
   where estate_id = p_estate and grantee_user_id = p_uid and category = p_cat and status = 'active' limit 1;
  if v_grant is null then return 'ERR:no active grant'; end if;
  return harness.attempt(v_owner, format('select public.revoke_document_grant(%L::uuid)', v_grant));
end $$;

/** A current aal2 posture for this user: claims + a live session + a verified factor. */
create or replace function harness_cd.aal2_claims(p_uid uuid) returns jsonb language plpgsql as $$
declare v_session uuid := gen_random_uuid();
begin
  insert into auth.sessions (id, user_id, not_after) values (v_session, p_uid, null);
  insert into auth.mfa_factors (id, user_id, status) values (gen_random_uuid(), p_uid, 'verified') on conflict do nothing;
  return jsonb_build_object('aal', 'aal2', 'session_id', v_session::text);
end $$;

create or replace function harness_cd.expect(p_label text, p_ok boolean, p_detail text default null) returns void language plpgsql as $$
begin
  if not p_ok then raise exception 'FAIL [%]%', p_label, coalesce(' — ' || p_detail, ''); end if;
  raise notice '  ok   %', p_label;
end $$;

-- =================================================================================================
-- 0 · the instrument can see the things it will later assert are absent
-- =================================================================================================
do $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  A   uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa';
  d jsonb; v text;
begin
  raise notice '0 · positive controls';
  perform harness_cd.expect('the brackets this suite reasons with are the deployed ones',
    public.asset_bracket_low(2800000) = 1000000 and public.asset_bracket_high(2800000) = 5000000
    and public.asset_bracket_low(5700000) = 5000000 and public.asset_bracket_high(5700000) = 10000000,
    'bracket ladder changed — the fixture arithmetic no longer demonstrates anything');
  perform harness_cd.expect('a per-account bracket and the sum bracket DIFFER for estate A',
    public.asset_bracket_low(2800000) <> public.asset_bracket_low(5700000));

  v := harness_cd.grant(A, BEN, 'beneficiary', 'account_balances', 'category_summary');
  perform harness_cd.expect('the real door grants Category totals to the beneficiary on A', v = 'OK', v);
  d := harness_cd.disco(BEN, '{}', A);
  perform harness_cd.expect('the discovery reader answers for A and carries connected_categories',
    d ? 'connected_categories' and (d->>'authorized')::boolean, d::text);
  perform harness_cd.expect('the fixture carries a NONEMPTY masked identifier, a NONEMPTY holding and a non-USD estate',
    (select count(*) from public.normalized_assets where estate_id = A and masked_identifier like '****%') = 3
    and (select jsonb_array_length(holdings) from public.normalized_assets where estate_id = A and institution_name = 'A Broker') = 1
    and (select currency from public.normalized_assets where estate_id = 'cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcde2') = 'EUR');
  perform harness_cd.expect('the owner of A sees exact per-account rows (aal2) — the surface can speak',
    jsonb_array_length(harness_cd.rows('cdcdcdcd-0002-4002-8002-cdcdcdcdcd02', harness_cd.aal2_claims('cdcdcdcd-0002-4002-8002-cdcdcdcdcd02'), A)) = 3);
end $$;

-- =================================================================================================
-- 1 · "Category totals" in A: the SUM's bracket, ONCE per category; nothing per account
-- =================================================================================================
do $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  A   uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa';
  d jsonb; cats jsonb; cash jsonb; inv jsonb; t jsonb;
begin
  raise notice '1 · Category totals (category_summary) on estate A';
  d := harness_cd.disco(BEN, '{}', A);
  cats := d->'connected_categories';
  perform harness_cd.expect('exactly TWO category objects (cashBank, investmentBrokerage) — not three accounts',
    jsonb_array_length(cats) = 2, cats::text);
  select x into cash from jsonb_array_elements(cats) x where x->>'asset_group' = 'cashBank';
  select x into inv  from jsonb_array_elements(cats) x where x->>'asset_group' = 'investmentBrokerage';
  perform harness_cd.expect('★ cashBank carries the bracket of the SUM ($57k → $50k–100k), not of either account',
    (cash->>'range_low_cents')::bigint = 5000000 and (cash->>'range_high_cents')::bigint = 10000000, cash::text);
  perform harness_cd.expect('investmentBrokerage carries its own bracket ($4k → $0–10k)',
    (inv->>'range_low_cents')::bigint = 0 and (inv->>'range_high_cents')::bigint = 1000000, inv::text);
  perform harness_cd.expect('no exact amount anywhere in the categories',
    cash->'total_cents' = 'null'::jsonb and inv->'total_cents' = 'null'::jsonb);
  perform harness_cd.expect('★ NO account rows through this grant (connected_institutions absent)',
    not (d ? 'connected_institutions'), d::text);
  perform harness_cd.expect('no id, name or masked identifier anywhere in the payload',
    d::text not like '%A Cash One%' and d::text not like '%A Broker%' and d::text not like '%masked_identifier%');
  perform harness_cd.expect('★ list_estate_assets returns NO rows to this grant',
    jsonb_array_length(harness_cd.rows(BEN, '{}', A)) = 0);
  t := harness_cd.total(BEN, '{}', A);
  perform harness_cd.expect('no total without a total grant (hidden, not suppressed)',
    t->>'resolved_tier' = 'hidden' and (t->>'suppressed_by_breakdown')::boolean = false, t::text);
end $$;

-- =================================================================================================
-- 2 · "Categories only" in B: presence, no amounts of any kind
-- =================================================================================================
do $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  B   uuid := 'cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb';
  d jsonb; cats jsonb; v text;
begin
  raise notice '2 · Categories only (range_only) on estate B — same person';
  v := harness_cd.grant(B, BEN, 'beneficiary', 'account_balances', 'range_only');
  perform harness_cd.expect('the real door grants Categories only on B', v = 'OK', v);
  d := harness_cd.disco(BEN, '{}', B);
  cats := d->'connected_categories';
  perform harness_cd.expect('B discloses the one category present', jsonb_array_length(cats) = 1 and cats->0->>'asset_group' = 'cashBank', cats::text);
  perform harness_cd.expect('★ and NO amounts: total, low and high are all null',
    cats->0->'total_cents' = 'null'::jsonb and cats->0->'range_low_cents' = 'null'::jsonb and cats->0->'range_high_cents' = 'null'::jsonb, cats::text);
  perform harness_cd.expect('no rows, no names, no numbers in the whole payload',
    not (d ? 'connected_institutions') and d::text not like '%B Cash%' and d::text not like '%1500000%');
  perform harness_cd.expect('list_estate_assets returns NO rows to this grant', jsonb_array_length(harness_cd.rows(BEN, '{}', B)) = 0);
end $$;

-- =================================================================================================
-- 3 · SCOPE — the same identity, each estate answers only for itself
-- =================================================================================================
do $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  A uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa'; B uuid := 'cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb';
  U uuid := 'cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcdee'; O uuid := 'cdcdcdcd-0000-4000-8000-cdcdcdcdcd00';
  dA jsonb; dB jsonb; dU jsonb; d_own jsonb; claims jsonb;
begin
  raise notice '3 · estate scope';
  dA := harness_cd.disco(BEN, '{}', A); dB := harness_cd.disco(BEN, '{}', B);
  perform harness_cd.expect('A still answers Category totals and B still answers Categories only, read back-to-back',
    dA->'connected_categories'->0->'range_low_cents' <> 'null'::jsonb and dB->'connected_categories'->0->'range_low_cents' = 'null'::jsonb);
  perform harness_cd.expect('★ A''s generous grant confers nothing on B: B shows no bracket, no A amount, no A name',
    dB::text not like '%5000000%' and dB::text not like '%A Cash%');
  dU := harness_cd.disco(BEN, '{}', U);
  perform harness_cd.expect('★ the UNGRANTED estate refuses outright — never a fallback to A or B',
    (dU->>'authorized')::boolean = false and not (dU ? 'connected_categories') and not (dU ? 'connected_total'), dU::text);
  perform harness_cd.expect('list_estate_assets on U: nothing', jsonb_array_length(harness_cd.rows(BEN, '{}', U)) = 0);
  perform harness_cd.expect('an unknown estate id refuses the same way',
    (harness_cd.disco(BEN, '{}', '00000000-0000-4000-8000-00000000dead')->>'authorized')::boolean = false);
  d_own := harness_cd.disco(BEN, '{}', O);
  perform harness_cd.expect('★ the estate BEN OWNS answers through the owner path (is_owner true)',
    (d_own->>'authorized')::boolean and (d_own->>'is_owner')::boolean, d_own::text);
  perform harness_cd.expect('…and owning O does not turn BEN into an owner of A or B',
    (dA->>'is_owner')::boolean = false and (dB->>'is_owner')::boolean = false);
  perform harness_cd.expect('owner at aal1: O''s exact total is refused by the reader, so connected_total is null and nothing else breaks',
    d_own->'connected_total' = 'null'::jsonb and (d_own ? 'connected_categories'));

  -- ★ AAL2 SATISFIES AN AUTHENTICATION REQUIREMENT; IT NEVER CREATES A GRANT.
  claims := harness_cd.aal2_claims(BEN);
  perform harness_cd.expect('the aal2 posture is genuinely current (positive control via the owner path on O)',
    (harness_cd.disco(BEN, claims, O)->'connected_total'->>'resolved_tier') = 'full_detail');
  dU := harness_cd.disco(BEN, claims, U);
  perform harness_cd.expect('★ aal2 on the ungranted estate: still refused', (dU->>'authorized')::boolean = false, dU::text);
  dA := harness_cd.disco(BEN, claims, A);
  perform harness_cd.expect('★ aal2 on A: still the sum''s bracket, never an exact figure',
    dA->'connected_categories'->0->'total_cents' = 'null'::jsonb and dA::text not like '%2800000%' and dA::text not like '%5700000%');
  perform harness_cd.expect('aal2 on A: still no rows', jsonb_array_length(harness_cd.rows(BEN, claims, A)) = 0);
end $$;

-- =================================================================================================
-- 3b · NO ESTATE METADATA BEFORE THE GRANT — an ungranted caller learns neither currency nor amount
-- =================================================================================================
do $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  E   uuid := 'cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcde2';   -- EUR, BEN holds nothing
  NX  uuid := '00000000-0000-4000-8000-00000000dead';   -- does not exist
  t jsonb; tn jsonb; d jsonb; v text;
begin
  raise notice '3b · metadata is not emitted before the total grant is checked';
  t  := harness_cd.total(BEN, '{}', E);
  tn := harness_cd.total(BEN, '{}', NX);
  perform harness_cd.expect('★ ungranted caller on a EUR estate: hidden row, NO currency, NO amount',
    t->>'resolved_tier' = 'hidden' and t->'currency' = 'null'::jsonb and t->'total_cents' = 'null'::jsonb
    and t->'range_low_cents' = 'null'::jsonb and t::text not like '%EUR%', t::text);
  perform harness_cd.expect('★ CONTROL: a NONEXISTENT estate answers with the IDENTICAL row',
    t - 'currency' = tn - 'currency' and tn->'currency' = 'null'::jsonb, tn::text);
  perform harness_cd.expect('discovery on E refuses outright; on the nonexistent id likewise',
    (harness_cd.disco(BEN, '{}', E)->>'authorized')::boolean = false and (harness_cd.disco(BEN, '{}', NX)->>'authorized')::boolean = false);
  -- separately authorized DESCRIPTIVE information is preserved, and still no currency on the total
  v := harness_cd.grant(E, BEN, 'beneficiary', 'institution_names', 'full_detail');
  perform harness_cd.expect('the real door grants institution names on E', v = 'OK', v);
  d := harness_cd.disco(BEN, '{}', E);
  perform harness_cd.expect('★ with ONLY a names grant: the named row appears, the total row stays hidden with NULL currency, no amount anywhere',
    jsonb_array_length(d->'connected_institutions') = 1 and d->'connected_institutions'->0->>'institution' = 'E Bank'
    and d->'connected_total'->>'resolved_tier' = 'hidden' and d->'connected_total'->'currency' = 'null'::jsonb
    and d::text not like '%1234567%' and not (d ? 'connected_categories'), d::text);
  perform harness_cd.expect('(the row itself may carry the account''s currency — that is the names grant''s own disclosure, not the total''s)',
    d->'connected_institutions'->0->>'currency' = 'EUR');
  perform harness_cd.revoke(E, BEN, 'institution_names');
end $$;

-- =================================================================================================
-- 4 · the estate TOTAL is its own grant, and the PRECISION test decides co-appearance
-- =================================================================================================
do $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  A uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa'; B uuid := 'cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb';
  P uuid := 'cdcdcdcd-9999-4999-8999-cdcdcdcdcd99';
  t jsonb; v text;
  cash_low bigint; cash_high bigint; inv_high bigint; tot_low bigint; pinned_low bigint;
begin
  raise notice '4 · the estate total';
  -- 4a · "No access" on balances neither grants nor suppresses a separately permitted total.
  v := harness_cd.grant(B, BEN, 'beneficiary', 'total_asset_value', 'range_only');
  perform harness_cd.expect('the real door grants a range_only total on B', v = 'OK', v);
  v := harness_cd.grant(B, BEN, 'beneficiary', 'account_balances', 'hidden');
  perform harness_cd.expect('the real door stores balances at hidden (No access) on B', v = 'OK', v);
  t := harness_cd.total(BEN, '{}', B);
  perform harness_cd.expect('★ No access on balances does NOT suppress the total: B shows the bracket ($15k → $10k–50k)',
    t->>'resolved_tier' = 'range_only' and (t->>'range_low_cents')::bigint = 1000000 and (t->>'suppressed_by_breakdown')::boolean = false, t::text);
  perform harness_cd.expect('…and hidden balances disclose no categories at all',
    not (harness_cd.disco(BEN, '{}', B) ? 'connected_categories'));
  perform harness_cd.revoke(B, BEN, 'total_asset_value');
  t := harness_cd.total(BEN, '{}', B);
  perform harness_cd.expect('★ No access on balances does NOT grant a total either: with the total grant gone, hidden',
    t->>'resolved_tier' = 'hidden' and (t->>'suppressed_by_breakdown')::boolean = false, t::text);
  -- restore B to Categories only for the later sections
  perform harness_cd.grant(B, BEN, 'beneficiary', 'account_balances', 'range_only');

  -- 4b · Categories only + total: nothing to combine → the total co-appears.
  perform harness_cd.grant(B, BEN, 'beneficiary', 'total_asset_value', 'range_only');
  t := harness_cd.total(BEN, '{}', B);
  perform harness_cd.expect('★ Categories only + total → the total SHOWS (no amounts exist to combine it with)',
    t->>'resolved_tier' = 'range_only' and (t->>'range_low_cents')::bigint = 1000000, t::text);

  -- 4c · Category totals + total: THE PRECISION TEST, in arithmetic, then the reader's answer.
  --      Estate P: cash $48,000 → [10k,50k]; investments $4,000 → [0,10k]; total $52,000 → [50k,100k].
  --      total_low − inv_high = 50,000 − 10,000 = 40,000 > cash_low 10,000 ⇒ cash pinned to [40k,50k].
  cash_low := public.asset_bracket_low(4800000); cash_high := public.asset_bracket_high(4800000);
  inv_high := public.asset_bracket_high(400000); tot_low := public.asset_bracket_low(5200000);
  pinned_low := tot_low - inv_high;
  perform harness_cd.expect(format('arithmetic: a disclosed total would pin cash to [%s,%s], narrower than its own [%s,%s]',
                                   pinned_low, cash_high, cash_low, cash_high),
    pinned_low > cash_low and pinned_low < cash_high);
  perform harness_cd.grant(P, BEN, 'beneficiary', 'account_balances', 'category_summary');
  perform harness_cd.grant(P, BEN, 'beneficiary', 'total_asset_value', 'range_only');
  t := harness_cd.total(BEN, '{}', P);
  perform harness_cd.expect('★ so beside Category totals the total is WITHHELD, flagged as suppressed — and carries no currency either',
    t->>'resolved_tier' = 'hidden' and (t->>'suppressed_by_breakdown')::boolean = true and t->'range_low_cents' = 'null'::jsonb
    and t->'currency' = 'null'::jsonb, t::text);
  perform harness_cd.expect('…and the discovery payload carries the same answer, with the category brackets still shown',
    (harness_cd.disco(BEN, '{}', P)->'connected_total'->>'suppressed_by_breakdown')::boolean = true
    and jsonb_array_length(harness_cd.disco(BEN, '{}', P)->'connected_categories') = 2);
  -- 4d · a total on P alone (balances revoked) shows again
  perform harness_cd.revoke(P, BEN, 'account_balances');
  t := harness_cd.total(BEN, '{}', P);
  perform harness_cd.expect('revoking the breakdown releases the total ($52k → $50k–100k)',
    (t->>'range_low_cents')::bigint = 5000000 and (t->>'suppressed_by_breakdown')::boolean = false, t::text);
end $$;

-- =================================================================================================
-- 5 · descriptive grants produce rows; balances grants never do (and never a per-account bracket)
-- =================================================================================================
do $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  A uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa';
  d jsonb; r jsonb;
begin
  raise notice '5 · descriptive fields respect their own permissions';
  perform harness_cd.grant(A, BEN, 'beneficiary', 'institution_names', 'full_detail');
  d := harness_cd.disco(BEN, '{}', A);
  perform harness_cd.expect('with institution_names granted, rows appear — three accounts, named',
    jsonb_array_length(d->'connected_institutions') = 3 and d::text like '%A Cash One%', d::text);
  perform harness_cd.expect('★ rows carry NO amount and NO per-account bracket (the two compatibility range keys exist and are ALWAYS null)',
    (select count(*) from jsonb_array_elements(d->'connected_institutions') x
      where x->'balance_cents' = 'null'::jsonb and x->'range_low_cents' = 'null'::jsonb and x->'range_high_cents' = 'null'::jsonb) = 3,
    (d->'connected_institutions'->0)::text);
  perform harness_cd.expect('★ masked identifiers stay withheld without their own grant — the ENDING is nowhere in the payload',
    d->'connected_institutions'->0->'masked_identifier' = 'null'::jsonb and d::text not like '%4321%' and d::text not like '%8765%');
  perform harness_cd.expect('…and list_estate_assets masks it too',
    (harness_cd.rows(BEN, '{}', A)->0->>'masked_identifier') = '••••' and harness_cd.rows(BEN, '{}', A)::text not like '%4321%');
  perform harness_cd.expect('the category brackets are unchanged by the descriptive grant',
    (d->'connected_categories'->0->>'range_low_cents')::bigint in (0, 5000000));
  r := harness_cd.rows(BEN, '{}', A);
  perform harness_cd.expect('list_estate_assets now returns the three rows, named, balance NULL, range NULL',
    jsonb_array_length(r) = 3 and r->0->'balance_cents' = 'null'::jsonb and r->0->'range_low_cents' = 'null'::jsonb
    and r->0->>'institution_name' <> 'Protected Institution', r::text);
  perform harness_cd.revoke(A, BEN, 'institution_names');
  perform harness_cd.expect('revoking the descriptive grant removes the rows again',
    not (harness_cd.disco(BEN, '{}', A) ? 'connected_institutions') and jsonb_array_length(harness_cd.rows(BEN, '{}', A)) = 0);
end $$;

-- =================================================================================================
-- 5b · ACCOUNT DETAILS — the ending discloses at limited_detail / full_detail ONLY, on both readers
-- =================================================================================================
do $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  A uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa';
  d jsonb; r jsonb; v text; tier text;
begin
  raise notice '5b · account details, tier by tier (names granted throughout, so rows exist)';
  perform harness_cd.grant(A, BEN, 'beneficiary', 'institution_names', 'full_detail');
  foreach tier in array array['range_only', 'category_summary'] loop
    v := harness_cd.grant(A, BEN, 'beneficiary', 'linked_account_details', tier);
    perform harness_cd.expect(format('the real door stores account details at %s', tier), v = 'OK', v);
    d := harness_cd.disco(BEN, '{}', A); r := harness_cd.rows(BEN, '{}', A);
    perform harness_cd.expect(format('★ %s: rows exist (names), the ending is withheld on BOTH readers', tier),
      jsonb_array_length(d->'connected_institutions') = 3 and d::text not like '%4321%'
      and d->'connected_institutions'->0->'masked_identifier' = 'null'::jsonb
      and r::text not like '%4321%' and (r->0->>'masked_identifier') = '••••', d::text);
  end loop;
  foreach tier in array array['limited_detail', 'full_detail'] loop
    v := harness_cd.grant(A, BEN, 'beneficiary', 'linked_account_details', tier);
    perform harness_cd.expect(format('the real door stores account details at %s', tier), v = 'OK', v);
    d := harness_cd.disco(BEN, '{}', A); r := harness_cd.rows(BEN, '{}', A);
    perform harness_cd.expect(format('★ %s: the masked ending IS disclosed on both readers — and still no amount', tier),
      (select count(*) from jsonb_array_elements(d->'connected_institutions') x where x->>'masked_identifier' like '****%') = 3
      and (select count(*) from jsonb_array_elements(r) x where x->>'masked_identifier' like '****%') = 3
      and d->'connected_institutions'->0->'balance_cents' = 'null'::jsonb and r->0->'balance_cents' = 'null'::jsonb, d::text);
  end loop;
  -- a details grant WITHOUT a names grant: rows carry the ending but no name
  perform harness_cd.revoke(A, BEN, 'institution_names');
  d := harness_cd.disco(BEN, '{}', A);
  perform harness_cd.expect('details without names: rows with endings and NO institution name',
    jsonb_array_length(d->'connected_institutions') = 3 and d->'connected_institutions'->0->'institution' = 'null'::jsonb
    and d::text not like '%A Cash One%' and d::text like '%****%', d::text);
  perform harness_cd.revoke(A, BEN, 'linked_account_details');
  perform harness_cd.expect('and with both revoked, no rows at all',
    not (harness_cd.disco(BEN, '{}', A) ? 'connected_institutions') and jsonb_array_length(harness_cd.rows(BEN, '{}', A)) = 0);
end $$;

-- =================================================================================================
-- 6 · the professional's explicitly authorized access survives, with its two-factor check
-- =================================================================================================
do $$
declare
  PRO uuid := 'cdcdcdcd-0004-4004-8004-cdcdcdcdcd04';
  A uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa';
  d jsonb; r jsonb; claims jsonb; v text;
begin
  raise notice '6 · professional delegate at limited_detail';
  v := harness_cd.grant(A, PRO, 'professional_delegate', 'account_balances', 'limited_detail');
  perform harness_cd.expect('the real door grants limited_detail to the delegate', v = 'OK', v);
  v := harness_cd.grant(A, PRO, 'professional_delegate', 'total_asset_value', 'range_only');
  perform harness_cd.expect('…and a separately granted BRACKETED total', v = 'OK', v);
  d := harness_cd.disco(PRO, '{}', A);
  perform harness_cd.expect('★ at aal1 the exact tier DEGRADES to the category bracket — never raises, never exact',
    (d->>'authorized')::boolean and d->'connected_categories'->0->'total_cents' = 'null'::jsonb
    and d->'connected_categories'->0->'range_low_cents' <> 'null'::jsonb, d::text);
  -- ★ ONE EFFECTIVE TIER PER SESSION: what this session SEES is a category-bracket breakdown, so the
  --   anti-inference rule withholds the total — in the discovery payload AND on the direct read.
  perform harness_cd.expect('★ at aal1 the total is SUPPRESSED beside the degraded breakdown (discovery)',
    (d->'connected_total'->>'suppressed_by_breakdown')::boolean = true and d->'connected_total'->'currency' = 'null'::jsonb, (d->'connected_total')::text);
  perform harness_cd.expect('★ …and on the DIRECT read of get_estate_net_worth at aal1',
    (harness_cd.total(PRO, '{}', A)->>'suppressed_by_breakdown')::boolean = true, harness_cd.total(PRO, '{}', A)::text);
  perform harness_cd.as_viewer(PRO, '{}');
  v := harness.attempt(PRO, format('select * from public.list_estate_assets(%L)', A));
  perform harness_cd.expect('list_estate_assets at aal1 refuses with mfa_required', position('mfa_required' in v) > 0, v);
  claims := harness_cd.aal2_claims(PRO);
  d := harness_cd.disco(PRO, claims, A);
  perform harness_cd.expect('at aal2: exact per-category totals ($57,000 cash)',
    (select (x->>'total_cents')::bigint from jsonb_array_elements(d->'connected_categories') x where x->>'asset_group'='cashBank') = 5700000, d::text);
  perform harness_cd.expect('at aal2: per-account rows with exact balances, no holdings key',
    jsonb_array_length(d->'connected_institutions') = 3 and d::text not like '%holdings%');
  perform harness_cd.expect('★ at aal2 the exact figures are disclosed, so the bracketed total CO-APPEARS (discovery and direct read)',
    d->'connected_total'->>'resolved_tier' = 'range_only' and (d->'connected_total'->>'range_low_cents')::bigint = 5000000
    and (harness_cd.total(PRO, claims, A)->>'resolved_tier') = 'range_only', (d->'connected_total')::text);
  r := harness_cd.rows(PRO, claims, A);
  perform harness_cd.expect('list_estate_assets at aal2: exact balances, empty holdings',
    jsonb_array_length(r) = 3 and (r->0->>'balance_cents')::bigint > 0 and r->0->'holdings' = '[]'::jsonb, r::text);
  -- ★ HOLDINGS ARE OWNER-ONLY FOR THIS PILOT — even at full balances + full account details, the
  --   combination that used to unlock them.
  perform harness_cd.grant(A, PRO, 'professional_delegate', 'account_balances', 'full_detail');
  perform harness_cd.grant(A, PRO, 'professional_delegate', 'linked_account_details', 'full_detail');
  r := harness_cd.rows(PRO, claims, A); d := harness_cd.disco(PRO, claims, A);
  perform harness_cd.expect('★ full + full, aal2: exact balances and masked endings, and STILL no holdings on either reader',
    (select count(*) from jsonb_array_elements(r) x where x->'holdings' = '[]'::jsonb) = 3
    and (select count(*) from jsonb_array_elements(r) x where x->>'masked_identifier' like '****%') = 3
    and r::text not like '%SYNTH%' and d::text not like '%SYNTH%' and d::text not like '%holdings%', r::text);
  perform harness_cd.revoke(A, PRO, 'linked_account_details');
  perform harness_cd.grant(A, PRO, 'professional_delegate', 'account_balances', 'limited_detail');
  perform harness_cd.expect('and the delegate holds nothing on B', (harness_cd.disco(PRO, claims, 'cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb')->>'authorized')::boolean = false);
end $$;

-- =================================================================================================
-- 7 · revoke A — B keeps working
-- =================================================================================================
do $$
declare
  BEN uuid := 'cdcdcdcd-0001-4001-8001-cdcdcdcdcd01';
  A uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa'; B uuid := 'cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb';
  dA jsonb; dB jsonb; v text;
begin
  raise notice '7 · revoke A, B unaffected';
  v := harness_cd.revoke(A, BEN, 'account_balances');
  perform harness_cd.expect('the real door revokes A''s Category totals', v = 'OK', v);
  dA := harness_cd.disco(BEN, '{}', A);
  perform harness_cd.expect('★ A now refuses (no grant, no membership) and carries nothing',
    (dA->>'authorized')::boolean = false, dA::text);
  dB := harness_cd.disco(BEN, '{}', B);
  perform harness_cd.expect('★ B still answers Categories only, with its total bracket',
    (dB->>'authorized')::boolean and jsonb_array_length(dB->'connected_categories') = 1
    and dB->'connected_total'->>'resolved_tier' = 'range_only', dB::text);
end $$;

-- =================================================================================================
-- 8 · the owner's surfaces are unchanged
-- =================================================================================================
do $$
declare OA uuid := 'cdcdcdcd-0002-4002-8002-cdcdcdcdcd02'; A uuid := 'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa'; claims jsonb; t jsonb; r jsonb;
begin
  raise notice '8 · owner';
  claims := harness_cd.aal2_claims(OA);
  t := harness_cd.total(OA, claims, A);
  perform harness_cd.expect('owner at aal2: exact total $61,000', (t->>'total_cents')::bigint = 6100000 and t->>'resolved_tier' = 'full_detail', t::text);
  r := harness_cd.rows(OA, claims, A);
  perform harness_cd.expect('owner at aal2: three exact rows', jsonb_array_length(r) = 3 and (r->0->>'balance_cents')::bigint > 0);
  perform harness_cd.expect('★ owner at aal2: the NONEMPTY holding is disclosed (the positive control for every "no holdings" above)',
    (select count(*) from jsonb_array_elements(r) x where x->>'institution_name' = 'A Broker' and jsonb_array_length(x->'holdings') = 1) = 1
    and r::text like '%SYNTH%', r::text);
  -- ★ claims are transaction-local: clear the aal2 posture set above before asking about aal1.
  perform harness_cd.as_viewer(OA, '{}');
  perform harness_cd.expect('owner at aal1 is refused the exact rows (mfa_required)',
    position('mfa_required' in harness.attempt(OA, format('select * from public.list_estate_assets(%L)', A))) > 0);
end $$;

-- =================================================================================================
-- 9 · fixture integrity — everything this suite created is removed
-- =================================================================================================
do $$
declare n int;
begin
  raise notice '9 · fixture integrity';
  delete from public.access_grants where estate_id in (
    'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa','cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb','cdcdcdcd-9999-4999-8999-cdcdcdcdcd99',
    'cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcdee','cdcdcdcd-0000-4000-8000-cdcdcdcdcd00','cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcde2');
  delete from public.normalized_assets where estate_id in (
    'cdcdcdcd-aaaa-4aaa-8aaa-cdcdcdcdcdaa','cdcdcdcd-bbbb-4bbb-8bbb-cdcdcdcdcdbb','cdcdcdcd-9999-4999-8999-cdcdcdcdcd99',
    'cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcdee','cdcdcdcd-0000-4000-8000-cdcdcdcdcd00','cdcdcdcd-eeee-4eee-8eee-cdcdcdcdcde2');
  -- the real grant door writes attributed audit rows; they reference these actors and estates
  delete from public.audit_logs where actor_id::text like 'cdcdcdcd-%' or estate_id::text like 'cdcdcdcd-%';
  delete from auth.sessions where user_id::text like 'cdcdcdcd-%';
  delete from auth.mfa_factors where user_id::text like 'cdcdcdcd-%';
  delete from public.estates where id::text like 'cdcdcdcd-%';
  delete from auth.users where id::text like 'cdcdcdcd-%';
  select count(*) into n from public.estates where id::text like 'cdcdcdcd-%';
  if n <> 0 then raise exception 'FAIL: fixture rows remain'; end if;
  raise notice '  ok   every row this suite created has been removed';
  raise notice 'ALL BENEFICIARY CONNECTOR DISCLOSURE ASSERTIONS PASSED';
end $$;
