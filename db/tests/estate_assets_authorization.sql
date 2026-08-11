-- db/tests/estate_assets_authorization.sql
--
-- THE AUTHORIZATION PROOF for the Phase 9 estate-asset surface.
--
-- ★ WHAT THIS EXISTS TO CLOSE. The first pass at SQL evidence stubbed `is_estate_owner()` to `true`.
-- Every RPC "passed", and the only thing proved was that each one CALLS the gate — not that the gate
-- ever refuses. An authorization suite in which nothing is refused is indistinguishable from one with
-- no authorization at all, which is the vacuous-scan failure this codebase has shipped before.
--
-- Here the real `is_estate_owner` runs, caller identity is switchable through the JWT claim, and every
-- scenario executes under `SET ROLE authenticated` so RLS is actually enforced.
--
-- ★ EVERY NEGATIVE IS PAIRED WITH ITS POSITIVE. "The non-owner was refused" means nothing unless the
-- SAME statement succeeds for the owner — otherwise a typo'd table name would read as airtight
-- security. Each block below asserts both directions.
--
-- Exit contract: raises on the first failed assertion, so a non-zero psql status IS the result.

\set ON_ERROR_STOP on

-- =================================================================================================
-- harness
-- =================================================================================================
create schema if not exists harness;

/**
 * Run `p_sql` as `p_uid` under the `authenticated` role, and report the outcome as text.
 *
 * ★ SECURITY INVOKER, DELIBERATELY. A DEFINER helper would execute the payload as the harness owner
 * and quietly hand every scenario superuser-adjacent rights — the test would then pass no matter what
 * the policies said. The whole point is to run as the role a real client runs as.
 *
 * A NULL uid means unauthenticated: the claim is cleared, so `auth.uid()` returns NULL exactly as it
 * does for an anonymous PostgREST request.
 */
create or replace function harness.attempt(p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare v_msg text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  begin
    set local role authenticated;
    execute p_sql;
    reset role;
    return 'OK';
  exception when others then
    reset role;
    -- SQLERRM only. A raw row would defeat the point of the sentinel discipline being tested.
    v_msg := SQLERRM;
    return 'ERR:' || v_msg;
  end;
end $$;

/** Assert a statement SUCCEEDS for this caller. */
create or replace function harness.expect_ok(p_label text, p_uid uuid, p_sql text)
returns void language plpgsql as $$
declare v text;
begin
  v := harness.attempt(p_uid, p_sql);
  if v <> 'OK' then
    raise exception 'FAIL [%]: expected success, got %', p_label, v;
  end if;
  raise notice '  ok   %', p_label;
end $$;

/** Assert a statement is REFUSED, and refused for the stated reason. */
create or replace function harness.expect_err(p_label text, p_uid uuid, p_sql text, p_expect text)
returns void language plpgsql as $$
declare v text;
begin
  v := harness.attempt(p_uid, p_sql);
  if v = 'OK' then
    raise exception 'FAIL [%]: expected refusal (%), but the statement SUCCEEDED', p_label, p_expect;
  end if;
  if position(p_expect in v) = 0 then
    raise exception 'FAIL [%]: expected refusal containing "%", got %', p_label, p_expect, v;
  end if;
  raise notice '  ok   % (refused: %)', p_label, p_expect;
end $$;

/** Assert a SELECT returns exactly N rows for this caller — the RLS read assertion. */
create or replace function harness.expect_rows(p_label text, p_uid uuid, p_sql text, p_expected bigint)
returns void language plpgsql as $$
declare v_count bigint;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  execute format('select count(*) from (%s) t', p_sql) into v_count;
  reset role;
  if v_count <> p_expected then
    raise exception 'FAIL [%]: expected % row(s), got %', p_label, p_expected, v_count;
  end if;
  raise notice '  ok   % (% row(s))', p_label, v_count;
end $$;

-- =================================================================================================
-- fixture — two estates, two owners, one unrelated authenticated user
-- =================================================================================================
-- Documented deliberately (10.9): the ONLY state manufactured is the minimum needed to express
-- "another estate exists and someone else owns it". No asset, grant or document is pre-created to
-- make a screen look populated.
insert into auth.users (id) values
  ('11111111-1111-4111-8111-111111111111'),  -- owner A
  ('22222222-2222-4222-8222-222222222222'),  -- owner B
  ('33333333-3333-4333-8333-333333333333')   -- authenticated, owns nothing
on conflict do nothing;

insert into public.estates (id, owner_id) values
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111'),
  ('bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb', '22222222-2222-4222-8222-222222222222')
on conflict do nothing;

insert into public.documents (id, estate_id) values
  ('dddddddd-1111-4111-8111-dddddddddddd', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'),
  ('dddddddd-2222-4222-8222-dddddddddddd', 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb')
on conflict do nothing;

-- =================================================================================================
-- 0 · the harness itself can fail  (a control that cannot fail is not a control)
-- =================================================================================================
do $$
begin
  raise notice '0 · harness self-check';
  -- The real gate must DISAGREE across callers, or every assertion below is vacuous.
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  if not public.is_estate_owner('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') then
    raise exception 'FAIL: the real is_estate_owner denied the true owner — harness is broken';
  end if;
  perform set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333333', true);
  if public.is_estate_owner('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') then
    raise exception 'FAIL: is_estate_owner returned TRUE for a non-owner — it is stubbed, not real';
  end if;
  perform set_config('request.jwt.claim.sub', '', true);
  if public.is_estate_owner('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') then
    raise exception 'FAIL: is_estate_owner returned TRUE with no identity';
  end if;
  raise notice '  ok   the gate distinguishes owner / non-owner / anonymous';
end $$;

-- =================================================================================================
-- 1 · CREATE — owner succeeds; nobody else does
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
begin
  raise notice '1 · create_estate_asset';

  perform harness.expect_ok('owner creates an asset',
    '11111111-1111-4111-8111-111111111111',
    format('select public.create_estate_asset(%L::uuid, %L, %L)', A, 'jewellery', 'Wedding ring'));

  perform harness.expect_err('authenticated non-owner cannot create',
    '33333333-3333-4333-8333-333333333333',
    format('select public.create_estate_asset(%L::uuid, %L, %L)', A, 'jewellery', 'Intruder ring'),
    'not_estate_owner');

  -- ★ THE CROSS-ESTATE CASE. Owner B is a legitimate owner of SOMETHING, which is exactly the caller
  -- an "is this person an owner?" check would wave through. The gate is per-ESTATE, not per-person.
  perform harness.expect_err('owner of another estate cannot create here',
    '22222222-2222-4222-8222-222222222222',
    format('select public.create_estate_asset(%L::uuid, %L, %L)', A, 'jewellery', 'Foreign ring'),
    'not_estate_owner');

  perform harness.expect_err('anonymous cannot create',
    null,
    format('select public.create_estate_asset(%L::uuid, %L, %L)', A, 'jewellery', 'Anon ring'),
    'auth_required');
end $$;

-- =================================================================================================
-- 2 · READ — RLS, not a client filter
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
begin
  raise notice '2 · estate_assets SELECT under RLS';

  perform harness.expect_rows('owner sees their own asset',
    '11111111-1111-4111-8111-111111111111',
    format('select id from public.estate_assets where estate_id = %L', A), 1);

  -- ★ NOT "sees a redacted row" — sees NOTHING. Row visibility is the hard boundary; there is no
  -- field-masking layer behind which a leak could hide.
  perform harness.expect_rows('authenticated non-owner sees nothing',
    '33333333-3333-4333-8333-333333333333',
    format('select id from public.estate_assets where estate_id = %L', A), 0);

  perform harness.expect_rows('owner of another estate sees nothing here',
    '22222222-2222-4222-8222-222222222222',
    format('select id from public.estate_assets where estate_id = %L', A), 0);

  perform harness.expect_rows('anonymous sees nothing',
    null, 'select id from public.estate_assets', 0);

  -- ★ AN UNSCOPED QUERY IS THE REAL TEST. A caller who simply omits the estate filter must still get
  -- only their own rows — otherwise scoping lives in the client's WHERE clause, not in the database.
  perform harness.expect_rows('an unscoped SELECT still returns only the caller''s rows',
    '22222222-2222-4222-8222-222222222222', 'select id from public.estate_assets', 0);
end $$;

-- =================================================================================================
-- 3 · WRITE PATHS — no client INSERT/UPDATE/DELETE exists at all
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
begin
  raise notice '3 · direct table writes are ungranted';

  -- ★ EVEN FOR THE OWNER. The RPCs own validation, the audit trail and the archive semantics; a
  -- direct write would bypass all three while still belonging to the right person.
  perform harness.expect_err('owner cannot INSERT directly',
    '11111111-1111-4111-8111-111111111111',
    format('insert into public.estate_assets (estate_id, created_by, category, subtype, label) values (%L::uuid, %L::uuid, %L, %L, %L)',
           A, '11111111-1111-4111-8111-111111111111', 'physicalValuable', 'jewellery', 'Direct'),
    'permission denied');

  perform harness.expect_err('owner cannot UPDATE directly',
    '11111111-1111-4111-8111-111111111111',
    'update public.estate_assets set label = ''Renamed''',
    'permission denied');

  perform harness.expect_err('owner cannot DELETE directly',
    '11111111-1111-4111-8111-111111111111',
    'delete from public.estate_assets',
    'permission denied');
end $$;

-- =================================================================================================
-- 4 · MUTATION BY OBJECT ID — a leaked/guessed asset id confers nothing
-- =================================================================================================
do $$
declare v_asset uuid;
begin
  raise notice '4 · update / archive / restore by object id';
  -- The id is taken from the database, i.e. the attacker is GIVEN a perfectly valid one. Guessability
  -- is not the defence being tested; authorization is.
  select id into v_asset from public.estate_assets
   where estate_id = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa' limit 1;

  perform harness.expect_err('non-owner cannot update a known asset id',
    '33333333-3333-4333-8333-333333333333',
    format('select public.update_estate_asset(%L::uuid, null, %L)', v_asset, 'Renamed by intruder'),
    'not_estate_owner');

  perform harness.expect_err('owner of another estate cannot update it',
    '22222222-2222-4222-8222-222222222222',
    format('select public.update_estate_asset(%L::uuid, null, %L)', v_asset, 'Renamed by neighbour'),
    'not_estate_owner');

  perform harness.expect_err('anonymous cannot update it',
    null,
    format('select public.update_estate_asset(%L::uuid, null, %L)', v_asset, 'Renamed by nobody'),
    'auth_required');

  perform harness.expect_err('non-owner cannot archive it',
    '33333333-3333-4333-8333-333333333333',
    format('select public.archive_estate_asset(%L::uuid)', v_asset), 'not_estate_owner');

  -- The owner can, which is what makes the three refusals above meaningful.
  perform harness.expect_ok('owner can archive it',
    '11111111-1111-4111-8111-111111111111',
    format('select public.archive_estate_asset(%L::uuid)', v_asset));

  perform harness.expect_err('non-owner cannot restore it',
    '33333333-3333-4333-8333-333333333333',
    format('select public.restore_estate_asset(%L::uuid)', v_asset), 'not_estate_owner');

  perform harness.expect_ok('owner can restore it',
    '11111111-1111-4111-8111-111111111111',
    format('select public.restore_estate_asset(%L::uuid)', v_asset));
end $$;

-- =================================================================================================
-- 5 · CROSS-ESTATE OBJECT COMPOSITION — ids from two estates cannot be combined
-- =================================================================================================
do $$
declare v_asset_a uuid;
begin
  raise notice '5 · cross-estate document linking';
  select id into v_asset_a from public.estate_assets
   where estate_id = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa' limit 1;

  -- ★ THE CALLER IS THE LEGITIMATE OWNER OF THE ASSET. Only the DOCUMENT is foreign. A check that
  -- stopped at "do you own the asset?" would pass this and leak the existence of estate B's document
  -- into a surface estate A's owner controls.
  perform harness.expect_err('owner cannot link a document from another estate',
    '11111111-1111-4111-8111-111111111111',
    format('select public.link_asset_document(%L::uuid, %L::uuid)', v_asset_a, 'dddddddd-2222-4222-8222-dddddddddddd'),
    'cross_estate_link');

  perform harness.expect_ok('owner can link a document from their OWN estate',
    '11111111-1111-4111-8111-111111111111',
    format('select public.link_asset_document(%L::uuid, %L::uuid)', v_asset_a, 'dddddddd-1111-4111-8111-dddddddddddd'));

  perform harness.expect_err('non-owner cannot link anything to it',
    '33333333-3333-4333-8333-333333333333',
    format('select public.link_asset_document(%L::uuid, %L::uuid)', v_asset_a, 'dddddddd-1111-4111-8111-dddddddddddd'),
    'not_estate_owner');

  perform harness.expect_rows('non-owner sees no link rows',
    '33333333-3333-4333-8333-333333333333', 'select asset_id from public.estate_asset_documents', 0);

  perform harness.expect_rows('owner sees their link row',
    '11111111-1111-4111-8111-111111111111', 'select asset_id from public.estate_asset_documents', 1);

  perform harness.expect_err('non-owner cannot unlink',
    '33333333-3333-4333-8333-333333333333',
    format('select public.unlink_asset_document(%L::uuid, %L::uuid)', v_asset_a, 'dddddddd-1111-4111-8111-dddddddddddd'),
    'not_estate_owner');
end $$;

-- =================================================================================================
-- 6 · SECURITY DEFINER DOES NOT BYPASS THE OWNER RULE
-- =================================================================================================
do $$
declare v_asset uuid; v_secdef int;
begin
  raise notice '6 · DEFINER does not launder authority';
  select id into v_asset from public.estate_assets limit 1;

  -- Precondition: these ARE definer functions. If they were not, the assertion below would be
  -- proving something about an ordinary invoker function and would say nothing about laundering.
  select count(*) into v_secdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef
     and p.proname in ('create_estate_asset','update_estate_asset','archive_estate_asset',
                       'restore_estate_asset','link_asset_document','unlink_asset_document',
                       'get_estate_asset_taxonomy');
  if v_secdef <> 7 then
    raise exception 'FAIL: expected 7 SECURITY DEFINER asset RPCs, found %', v_secdef;
  end if;
  raise notice '  ok   all 7 asset RPCs are SECURITY DEFINER';

  -- They run as the function owner, and are STILL refused — because the rule keys off auth.uid(),
  -- never off current_user. That distinction is the entire reason DEFINER is safe here.
  perform harness.expect_err('a DEFINER RPC still refuses a non-owner',
    '33333333-3333-4333-8333-333333333333',
    format('select public.update_estate_asset(%L::uuid, null, %L)', v_asset, 'Laundered'),
    'not_estate_owner');
end $$;

-- =================================================================================================
-- 7 · THE VOCABULARY IS READABLE; THE CATALOGS ARE NOT
-- =================================================================================================
do $$
begin
  raise notice '7 · taxonomy exposure';

  -- The taxonomy is generic category metadata and is deliberately client-readable through the RPC.
  perform harness.expect_ok('any authenticated caller may read the taxonomy RPC',
    '33333333-3333-4333-8333-333333333333', 'select public.get_estate_asset_taxonomy()');

  -- …but the tables behind it carry no client grant, so there is exactly one read path.
  perform harness.expect_err('the category table itself is ungranted',
    '33333333-3333-4333-8333-333333333333',
    'select value from public.estate_asset_category', 'permission denied');

  perform harness.expect_err('the subtype table itself is ungranted',
    '33333333-3333-4333-8333-333333333333',
    'select subtype from public.estate_asset_subtype', 'permission denied');
end $$;

-- =================================================================================================
-- 8 · ERRORS DO NOT LEAK ROW CONTENTS
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; v text;
begin
  raise notice '8 · validation errors carry a sentinel, never a row';

  -- Every user-supplied field is validated BEFORE the insert, so a bad value raises a machine-readable
  -- sentinel instead of a constraint violation. A constraint violation carries
  -- `DETAIL: Failing row contains (…)` — the value, notes, beneficiary note and reference hint — into
  -- the server log and any error telemetry. That is precisely the defect this suite locked down.
  v := harness.attempt('11111111-1111-4111-8111-111111111111',
    format('select public.create_estate_asset(%L::uuid, %L, %L, null, null, %L, null, null, null, null, null, %L)',
           A, 'jewellery', 'Leaky', 'USA', 'a private note about the ring'));
  if position('invalid_country_code' in v) = 0 then
    raise exception 'FAIL: expected invalid_country_code, got %', v;
  end if;
  if position('Failing row contains' in v) > 0 or position('private note' in v) > 0 then
    raise exception 'FAIL: the error leaked row contents: %', v;
  end if;
  raise notice '  ok   bad country code -> sentinel, and no row content in the message';
end $$;

do $$ begin raise notice 'ALL AUTHORIZATION ASSERTIONS PASSED'; end $$;
