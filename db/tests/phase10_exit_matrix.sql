-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 10-F — THE EXIT MATRIX: does 10-A … 10-E compose into ONE coherent disclosure system?
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- Every suite before this one asks whether a FEATURE is correct. This one asks whether the features
-- are correct TOGETHER — because each was built and proved in isolation, and disclosure is not a
-- property any single one of them owns.
--
-- ★ THE QUESTION IS INFORMATION EQUIVALENCE, NOT FIELD SUPPRESSION.
--
-- Phase 10-B established that withholding is a property of INFORMATION, not of fields, and 10-A
-- shipped the counter-example: `limited_detail` suppressed `total_cents` and then published the exact
-- same number as a range whose low and high were equal. Every field was correctly nulled. The value
-- was disclosed anyway.
--
-- So the strongest test in this file is not "is field X null". It is:
--
--     CHANGE THE HIDDEN WORLD. THE VIEWER'S ENTIRE PAYLOAD MUST NOT MOVE.
--
-- If adding an asset a viewer may not see changes ANY byte of what they receive — a count, a bracket,
-- a document total, a category appearing, a notification arriving, a deep link materialising — then
-- the hidden asset is disclosed, whatever the field list says. That is a difference test over the
-- composed system, and it cannot be satisfied by nulling a column.
--
-- Each such test is paired with a POSITIVE CONTROL that changes the AUTHORIZED world and requires the
-- payload TO move. Without it, a projection that always returned `{}` would pass every equivalence
-- assertion in this file.

\set ON_ERROR_STOP on

-- ── the composed probe ──────────────────────────────────────────────────────────────────────────
--
-- ★ ONE FUNCTION PER PROJECTION, PLUS ONE THAT COMPOSES THEM. The composed view is what makes the
-- equivalence tests meaningful: a leak that no single projection commits can still exist in the
-- TUPLE of answers a viewer can collect, and a viewer can always collect all of them.
create schema if not exists harness_exit;

create or replace function harness_exit.discovery(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select public.get_estate_discovery(p_estate) into v;
  reset role;
  return v;
end $$;

create or replace function harness_exit.readiness(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select public.get_estate_readiness(p_estate) into v;
  reset role;
  return v;
end $$;

create or replace function harness_exit.workspace(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select public.get_professional_workspace(p_estate) into v;
  reset role;
  return v;
end $$;

/**
 * Everything one viewer can learn about one estate through Phase 10, in a single value.
 *
 * ★ THIS IS THE UNIT THE EQUIVALENCE TESTS COMPARE. Asking "did discovery change" invites the answer
 * "no, but readiness did" — and a viewer never queries one endpoint in isolation.
 */
create or replace function harness_exit.composed(p_uid uuid, p_estate uuid)
returns jsonb language sql as $$
  select jsonb_build_object(
    'discovery', harness_exit.discovery(p_uid, p_estate),
    'readiness', harness_exit.readiness(p_uid, p_estate),
    'workspace', harness_exit.workspace(p_uid, p_estate)
  );
$$;

/** The refusal-shape probe: the composed tuple, used where only the REFUSAL bytes matter. */
create or replace function harness_exit.probe(p_uid uuid, p_estate uuid)
returns jsonb language sql as $$ select harness_exit.composed(p_uid, p_estate); $$;

/** Grant a category through the REAL door, as the owner. Never a direct insert. */
create or replace function harness_exit.grant(
  p_estate uuid, p_owner uuid, p_grantee uuid, p_role text, p_tier text,
  p_cond text default 'immediately'
) returns void language plpgsql as $$
begin
  delete from public.access_grants
   where estate_id = p_estate and grantee_user_id = p_grantee and category = 'estate_inventory';
  perform set_config('request.jwt.claim.sub', p_owner::text, true);
  set local role authenticated;
  perform public.create_asset_grant(p_estate, p_grantee, p_role, 'estate_inventory', p_tier, p_cond);
  reset role;
end $$;


do $exit$
declare
  OWNER_X uuid; BENE uuid; DELE uuid; STRANGER uuid; OWNER_Y uuid; REVOKED uuid;
  X uuid; Y uuid;
  before_json jsonb; after_json jsonb; ctl_json jsonb;
  v jsonb; v2 jsonb; n int; cause text;
  refusal_bytes text; first_bytes text;
  lo bigint; hi bigint; exact_v bigint;
begin
  raise notice ' ';
  raise notice '══ PHASE 10-F · exit matrix — composed disclosure ══';

  -- ── fixture, semantically isolated from every other suite ───────────────────────────────────
  insert into auth.users default values returning id into OWNER_X;
  insert into auth.users default values returning id into OWNER_Y;
  insert into auth.users default values returning id into BENE;
  insert into auth.users default values returning id into DELE;
  insert into auth.users default values returning id into STRANGER;
  insert into auth.users default values returning id into REVOKED;

  insert into public.estates (owner_id, name) values (OWNER_X, 'Exit Estate X') returning id into X;
  insert into public.estates (owner_id, name) values (OWNER_Y, 'Exit Estate Y') returning id into Y;

  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (X, OWNER_X, 'primary_user', 'approved'),
    (X, BENE,    'beneficiary', 'approved'),
    (X, DELE,    'professional_delegate', 'approved'),
    (X, REVOKED, 'professional_delegate', 'revoked'),
    (Y, OWNER_Y, 'primary_user', 'approved');

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 1 · refusal shape is identical across every cause AND every Phase 10 projection';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THE MATRIX IS CAUSE × PROJECTION, because 10-C and 10-D each proved byte-identity WITHIN one
  -- projection and nothing proved it ACROSS them. A refusal that is uniform per-endpoint can still be
  -- an oracle in composition: if discovery refuses a stranger and a wrong-estate viewer identically,
  -- but readiness distinguishes them, the pair of answers separates the two causes.
  for cause, v in
    select c.name, harness_exit.probe(c.uid, X)
    from (values
      ('stranger',        STRANGER),
      ('revoked member',  REVOKED),
      ('foreign owner',   OWNER_Y),
      ('anonymous',       null::uuid)
    ) as c(name, uid)
  loop
    if first_bytes is null then
      first_bytes := v::text;
      refusal_bytes := v::text;
    end if;
    if v::text is distinct from first_bytes then
      raise exception 'FAIL: refusal differs by CAUSE. % produced % but the first cause produced %',
        cause, v::text, first_bytes;
    end if;
  end loop;
  raise notice '  ok   4 refusal causes produce byte-identical composed output';

  -- ★ AND A WRONG-ESTATE REFUSAL IS INDISTINGUISHABLE FROM A NO-SUCH-ESTATE ONE. Otherwise the pair
  -- confirms an estate exists, which is itself a disclosure about someone else's affairs.
  if harness_exit.probe(STRANGER, X)::text
     is distinct from harness_exit.probe(STRANGER, gen_random_uuid())::text then
    raise exception 'FAIL: a refusal on a REAL estate differs from one on a nonexistent estate — the '
      'shape confirms the estate exists';
  end if;
  raise notice '  ok   real-estate and no-such-estate refusals are indistinguishable';

  -- ★ POSITIVE CONTROL. Four identical refusals are also what a projection that always returns the
  -- same thing produces. The OWNER must get something DIFFERENT, or nothing above discriminates.
  if harness_exit.probe(OWNER_X, X)::text = first_bytes then
    raise exception 'FAIL(control): the OWNER received the same bytes as a stranger — the probe is '
      'not reading anything, so the byte-identity above proves nothing';
  end if;
  raise notice '  ok   control: the owner receives materially different output';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 2 · ★ INFORMATION EQUIVALENCE — changing the hidden world moves nothing';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- The beneficiary holds NO inventory grant, so every asset on this estate is hidden from them.
  before_json := harness_exit.composed(BENE, X);

  perform set_config('request.jwt.claim.sub', OWNER_X::text, true);
  perform public.create_estate_asset(X, 'primaryResidence', 'Hidden house', null, null, 'US', 'Vermont',
                                     null, null, 91000000);
  perform public.create_estate_asset(X, 'chequingAccount', 'Hidden account', null, null, null, null,
                                     'Northbank', 'h1', 4200000);

  after_json := harness_exit.composed(BENE, X);
  if before_json::text is distinct from after_json::text then
    raise exception 'FAIL: adding TWO hidden assets changed the beneficiary composed payload.%  before=%  after=%',
      chr(10), before_json::text, after_json::text;
  end if;
  raise notice '  ok   two hidden assets added — beneficiary composed payload byte-identical';

  -- ★ POSITIVE CONTROL: the same instrument MUST detect an authorized change. Grant the beneficiary
  -- category_summary and the payload has to move, or the equivalence above is vacuous.
  perform harness_exit.grant(X, OWNER_X, BENE, 'beneficiary', 'category_summary');
  ctl_json := harness_exit.composed(BENE, X);
  if ctl_json::text = after_json::text then
    raise exception 'FAIL(control): granting category_summary changed NOTHING — the composed probe '
      'is blind, and every equivalence assertion in this section is vacuous';
  end if;
  raise notice '  ok   control: an AUTHORIZED change does move the payload';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 3 · ★ ARCHIVED AND DEATH-CONDITIONED MATERIAL CONTRIBUTES TO NO AGGREGATE';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- The beneficiary is now at category_summary and legitimately sees counts and brackets. That makes
  -- this the sharpest possible test: an aggregate they DO receive must not shift when material they
  -- may NOT receive changes. A count is exactly where archived rows leak back in.
  before_json := harness_exit.composed(BENE, X);

  --
  -- ★ ARCHIVED THROUGH THE REAL RPC, NOT BY UPDATING THE COLUMN. A raw
  -- `update ... set archived_at = now()` violates `estate_assets_archived_pair`, which requires
  -- `archived_at` and `archived_by` to move together — and the constraint catching that is the point:
  -- a test that hand-writes a state the product cannot produce is testing a state that cannot occur.
  perform set_config('request.jwt.claim.sub', OWNER_X::text, true);
  set local role authenticated;
  perform public.create_estate_asset(X, 'primaryResidence', 'Archived house', null, null, 'US', 'Maine',
                                     null, null, 55000000);
  perform public.archive_estate_asset(
    (select a.id from public.estate_assets a where a.estate_id = X and a.label = 'Archived house'));
  reset role;
  if not exists (select 1 from public.estate_assets a
                  where a.estate_id = X and a.label = 'Archived house' and a.archived_at is not null) then
    raise exception 'FAIL(fixture): the asset was not actually archived, so the equivalence check below '
      'would compare two identical live worlds and pass for the wrong reason';
  end if;

  after_json := harness_exit.composed(BENE, X);
  if before_json::text is distinct from after_json::text then
    raise exception 'FAIL: an ARCHIVED asset moved a category_summary aggregate.%  before=%  after=%',
      chr(10), before_json::text, after_json::text;
  end if;
  raise notice '  ok   an archived asset changes no count, bracket or category';

  -- A death-conditioned grant to a STRANGER must leave both of them exactly where they were.
  before_json := harness_exit.composed(BENE, X);
  refusal_bytes := harness_exit.composed(STRANGER, X)::text;
  perform harness_exit.grant(X, OWNER_X, STRANGER, 'beneficiary', 'category_summary',
                             'after_verified_death_or_incapacity');
  if harness_exit.composed(STRANGER, X)::text is distinct from refusal_bytes then
    raise exception 'FAIL: a DEATH-CONDITIONED grant changed what its holder receives — it is not dormant';
  end if;
  if harness_exit.composed(BENE, X)::text is distinct from before_json::text then
    raise exception 'FAIL: a death-conditioned grant to a THIRD PARTY moved the beneficiary payload';
  end if;
  raise notice '  ok   a death-conditioned grant is dormant for its holder and invisible to others';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 4 · ★ A SINGLE-ITEM CATEGORY IS NOT AN EXACT-VALUE ORACLE';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- This is the shape of the defect 10-A actually shipped: `limited_detail` suppressed `total_cents`
  -- and republished the identical number as a range with low = high. A bracket is only a bracket if
  -- it is WIDER than the value it contains — and a category holding exactly one asset is where that
  -- is easiest to get wrong, because the "aggregate" and the item are the same number.
  perform set_config('request.jwt.claim.sub', OWNER_X::text, true);
  perform public.create_estate_asset(X, 'jewellery', 'Single valuable', null, null, null, null,
                                     null, null, 3777700);
  exact_v := 3777700;

  v := harness_exit.discovery(BENE, X);
  select (c->>'range_low_cents')::bigint, (c->>'range_high_cents')::bigint into lo, hi
    from jsonb_array_elements(v->'categories') c
   where c->>'category' = 'physicalValuable';

  if lo is null or hi is null then
    raise exception 'FAIL(control): the single-item category produced no bracket, so nothing was tested';
  end if;
  if lo = hi then
    raise exception 'FAIL: the bracket collapsed to a point (% = %) — it publishes the exact total', lo, hi;
  end if;
  if hi - lo < exact_v / 10 then
    raise exception 'FAIL: the bracket [%,%] is narrower than 10%% of the value % — it is an oracle',
      lo, hi, exact_v;
  end if;
  if exact_v < lo or exact_v > hi then
    raise exception 'FAIL: the bracket [%,%] does not even contain the value % — it is wrong, not merely narrow',
      lo, hi, exact_v;
  end if;
  -- And the exact value appears NOWHERE in the whole composed payload, in any field.
  if harness_exit.composed(BENE, X)::text like '%' || exact_v::text || '%' then
    raise exception 'FAIL: the exact value % appears somewhere in the composed beneficiary payload', exact_v;
  end if;
  raise notice '  ok   single-item bracket [%,%] contains but does not pin %', lo, hi, exact_v;

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 5 · readiness and workspace stay out of the beneficiary composition';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  if (harness_exit.readiness(BENE, X)->>'authorized') is distinct from 'false' then
    raise exception 'FAIL: a beneficiary received readiness';
  end if;
  if (harness_exit.workspace(BENE, X)->>'authorized') is distinct from 'false' then
    raise exception 'FAIL: a beneficiary received the professional workspace';
  end if;
  if (harness_exit.workspace(OWNER_X, X)->>'authorized') is distinct from 'false' then
    raise exception 'FAIL: the OWNER received the professional workspace — it is not an owner dashboard';
  end if;
  if (harness_exit.readiness(DELE, X)->>'authorized') is distinct from 'false' then
    raise exception 'FAIL: a professional delegate received owner readiness';
  end if;
  raise notice '  ok   readiness is owner-only; the workspace is delegate-only; neither crosses';

  -- ★ AND THE OWNER'S READINESS DOES NOT LEAK INTO ANYONE ELSE'S AGGREGATE. Readiness counts
  -- findings over documents and assets — exactly the material a non-owner is rationed. Adding a
  -- finding-generating asset must not move a beneficiary's payload.
  --
  -- ★ THE READINESS SLICE ONLY, AND THE REASON MATTERS. Adding an asset legitimately moves a
  -- category_summary viewer's DISCOVERY — they are entitled to counts and brackets, so requiring the
  -- whole composed payload to freeze here would assert something false and fail for a correct reason.
  -- What must not move is the readiness slice: findings are an owner-only judgement about the estate,
  -- and a beneficiary must learn nothing from the fact that one appeared.
  before_json := harness_exit.readiness(BENE, X);
  n := coalesce((harness_exit.readiness(OWNER_X, X)->>'finding_count')::int, -1);
  perform set_config('request.jwt.claim.sub', OWNER_X::text, true);
  perform public.create_estate_asset(X, 'brokerageAccount', 'No-document asset', null, null, null, null,
                                     'Broker', null, null);
  after_json := harness_exit.readiness(BENE, X);
  if before_json::text is distinct from after_json::text then
    raise exception 'FAIL: an owner-visible readiness finding moved the beneficiary readiness slice: % -> %',
      before_json::text, after_json::text;
  end if;
  -- ★ POSITIVE CONTROL: the OWNER's finding count must actually have moved, or the freeze above is
  -- a statement about a readiness projection that never changes for anyone.
  if coalesce((harness_exit.readiness(OWNER_X, X)->>'finding_count')::int, -1) = n then
    raise exception 'FAIL(control): the owner finding_count did not change when an asset was added '
      '(still %), so "the beneficiary slice did not move" proves nothing', n;
  end if;
  raise notice '  ok   an owner readiness finding does not surface in a beneficiary payload';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 6 · ★ PHASE 11 FIREWALL, RE-PROVED OVER THE COMPOSED SYSTEM';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- 10-A/E each proved a dormancy rule inside their own projection. The firewall claim is about the
  -- SYSTEM: an approved claim must not release anything ANYWHERE, and the release seam must not move
  -- as a side effect of any Phase 10 read.
  before_json := harness_exit.composed(BENE, X);
  refusal_bytes := harness_exit.composed(STRANGER, X)::text;
  if public.estate_release_state(X) is distinct from 'active' then
    raise exception 'FAIL(precondition): the estate is not in release state active';
  end if;

  -- ★ THE DELTA, NOT THE TOTAL. Section 2 granted the beneficiary category_summary through the real
  -- door, and a LIVE grant correctly notifies its grantee — so a notification legitimately exists
  -- before the claim is ever inserted. Asserting a total of zero here would fail on that earlier,
  -- correct emission and would have to be "fixed" by weakening something real. What the firewall
  -- claims is that approving a claim adds NOTHING.
  select count(*) into n from public.notifications
   where user_id in (OWNER_X, BENE, DELE, STRANGER, REVOKED, OWNER_Y);

  insert into public.claim_packets (estate_id, requested_by, status) values (X, BENE, 'approved');

  if public.estate_release_state(X) = 'active' then
    raise notice '       (release state unchanged by an approved claim — the seam did not move)';
  end if;
  --
  -- ★ THE SEAM IS ALLOWED TO MOVE. EVERYTHING ELSE IS NOT — and separating those two is the whole
  -- content of this assertion.
  --
  -- `estate_release_state` exists precisely so the claims machinery has ONE place to report itself,
  -- and 10-A put it in the discovery payload deliberately: a survivor can be told "a claim is under
  -- review" without any disclosure following from it. So a claim reaching `approved` SHOULD change
  -- that field, and a test demanding the whole payload freeze would fail for a correct reason and
  -- invite someone to "fix" the seam.
  --
  -- What must not move is anything that carries estate CONTENT: the tier, the categories, the counts,
  -- the brackets, the document total. Those are compared with the seam removed.
  after_json := harness_exit.composed(BENE, X);
  if (before_json #- '{discovery,release_state}')::text
     is distinct from (after_json #- '{discovery,release_state}')::text then
    raise exception 'FAIL: an APPROVED CLAIM changed beneficiary CONTENT, not just the release seam.%'
      '  before=%  after=%', chr(10),
      (before_json #- '{discovery,release_state}')::text,
      (after_json  #- '{discovery,release_state}')::text;
  end if;
  raise notice '  ok   claim approval moved the release SEAM only (% -> %), no content',
    before_json->'discovery'->>'release_state', after_json->'discovery'->>'release_state';

  -- ★ AND THE SEAM DID NOT REACH `released`. That value is Phase 11's to set, and only when
  -- activation is genuinely connected to disclosure. An approved CLAIM is not an approved RELEASE.
  if public.estate_release_state(X) = 'released' then
    raise exception 'FAIL: an approved claim advanced the estate to RELEASED — Phase 11 has started';
  end if;

  if (harness_exit.composed(STRANGER, X) #- '{discovery,release_state}')::text
     is distinct from (refusal_bytes::jsonb #- '{discovery,release_state}')::text then
    raise exception 'FAIL: an APPROVED CLAIM changed what a stranger receives';
  end if;
  -- The dormant death-conditioned grant from section 3 must STILL be dormant after the approval —
  -- this is the pairing that matters most: a claim decision plus a death-conditioned grant is exactly
  -- the combination Phase 11 will eventually connect, and it must do nothing until it does.
  if (harness_exit.composed(STRANGER, X) #- '{discovery,release_state}')::text
     is distinct from (refusal_bytes::jsonb #- '{discovery,release_state}')::text then
    raise exception 'FAIL: the death-conditioned grant activated on claim approval';
  end if;
  if public.notification_grant_is_live('active', 'after_verified_death_or_incapacity', now()) then
    raise exception 'FAIL: an approved claim made the death-conditioned release predicate true';
  end if;
  -- And NOTHING NEW was announced to anyone.
  if (select count(*) from public.notifications
       where user_id in (OWNER_X, BENE, DELE, STRANGER, REVOKED, OWNER_Y)) <> n then
    raise exception 'FAIL: approving a claim emitted a notification (% -> %) — something announced a release',
      n, (select count(*) from public.notifications
           where user_id in (OWNER_X, BENE, DELE, STRANGER, REVOKED, OWNER_Y));
  end if;
  -- ★ AND NO ROW ANYWHERE USES RELEASE LANGUAGE, whenever it was written. The delta check above
  -- proves the claim added nothing; this proves nothing already present says the estate opened.
  if exists (select 1 from public.notifications
              where user_id in (OWNER_X, BENE, DELE, STRANGER, REVOKED, OWNER_Y)
                and (title || ' ' || coalesce(body, '')) ~* '(released|now available|died|death|survivor|activat)') then
    raise exception 'FAIL: a notification uses release/death language';
  end if;
  raise notice '  ok   approved claim releases nothing, activates nothing, announces nothing';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 7 · ★ NOTIFICATION EXISTENCE IS NOT A SIDE CHANNEL';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- A notification that ARRIVES tells its recipient something even before it is read. If creating a
  -- hidden asset, or granting someone else access, produced a row for an unrelated viewer, the mere
  -- existence of that row would disclose activity they are not party to.
  -- ★ A DELTA AGAIN, AND FOR THE SAME REASON AS SECTION 6. The beneficiary was correctly notified of
  -- their OWN grant back in section 2, so they are not "uninvolved" in the absolute — only in respect
  -- of what happens next. The question is whether creating an asset and granting a THIRD PARTY adds
  -- anything to anyone who is not party to it.
  select count(*) into n from public.notifications where user_id in (BENE, STRANGER, OWNER_Y, REVOKED);

  perform set_config('request.jwt.claim.sub', OWNER_X::text, true);
  set local role authenticated;
  perform public.create_estate_asset(X, 'chequingAccount', 'Quiet asset', null, null, null, null,
                                     'Northbank', 'q1', 999900);
  reset role;
  perform harness_exit.grant(X, OWNER_X, DELE, 'professional_delegate', 'category_summary');

  if (select count(*) from public.notifications
       where user_id in (BENE, STRANGER, OWNER_Y, REVOKED)) <> n then
    raise exception 'FAIL: creating an asset or granting a third party notified an uninvolved party '
      '(% -> %)', n, (select count(*) from public.notifications
                       where user_id in (BENE, STRANGER, OWNER_Y, REVOKED));
  end if;
  -- ★ POSITIVE CONTROL: the grantee IS party to their own grant and must have been told, or the
  -- unchanged count above is just an emitter that never fires.
  select count(*) into n from public.notifications where user_id = DELE;
  if n < 1 then
    raise exception 'FAIL(control): the GRANTEE received no notification for their own grant — the '
      'emitter is silent, so "nobody else was notified" proves nothing';
  end if;
  raise notice '  ok   only the grantee is told; asset creation notifies nobody';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 8 · revoked membership loses everything, and loses it uniformly';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  if harness_exit.composed(REVOKED, X)::text is distinct from harness_exit.composed(STRANGER, X)::text then
    raise exception 'FAIL: a REVOKED member is distinguishable from a stranger — revocation is a '
      'disclosure about the relationship that existed';
  end if;
  raise notice '  ok   a revoked member is byte-identical to a stranger';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 9 · cross-estate isolation over the composed system';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  if harness_exit.composed(OWNER_Y, X)::text is distinct from harness_exit.composed(STRANGER, X)::text then
    raise exception 'FAIL: another estate owner is distinguishable from a stranger on estate X';
  end if;
  if (harness_exit.discovery(OWNER_X, Y)->>'authorized') is distinct from 'false' then
    raise exception 'FAIL: estate X owner received discovery on estate Y';
  end if;
  raise notice '  ok   ownership of one estate confers nothing on another';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '10 · fixture integrity';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  delete from public.notifications where user_id in (OWNER_X, OWNER_Y, BENE, DELE, STRANGER, REVOKED);
  delete from public.claim_packets where estate_id in (X, Y);
  delete from public.access_grants where estate_id in (X, Y);
  delete from public.estate_assets where estate_id in (X, Y);
  delete from public.estate_memberships where estate_id in (X, Y);
  delete from public.estates where id in (X, Y);
  select count(*) into n from public.estate_assets where estate_id in (X, Y);
  if n <> 0 then raise exception 'FAIL: this suite left % asset row(s) behind', n; end if;
  raise notice '  ok   every row this suite created has been removed';

  raise notice ' ALL PHASE 10-F EXIT MATRIX ASSERTIONS PASSED';
end
$exit$;
