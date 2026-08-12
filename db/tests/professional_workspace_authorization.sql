-- db/tests/professional_workspace_authorization.sql
--
-- THE PROFESSIONAL-WORKSPACE PROOF — Phase 10-D.
--
-- ★ THE FAILURE MODE IS NOT "IT ERRORS". It is "a non-owner learns one thing more than the owner
-- released". So every assertion below is about the SHAPE of what comes back for each viewer class,
-- and each positive is paired with the negative that makes it meaningful: proving a delegate is
-- served means nothing unless a beneficiary, an owner, an executor-without-delegation and a stranger
-- are each shown to be refused by the SAME call.
--
-- ★ THE THREE BOUNDARIES THIS FILE EXISTS TO HOLD.
--
--   1 · DELEGATE ≠ OWNER.     A professional delegate never receives readiness, and never receives a
--                             fact the owner did not release through an existing gate.
--   2 · DELEGATE ≠ FIDUCIARY. An executor designation does not open the workspace; a workspace
--                             membership does not confer a capacity. Each is read from its own
--                             authoritative table and neither is inferred from the other.
--   3 · REFUSAL IS NOT AN ORACLE. Every refusal — unauthenticated, non-member, beneficiary, owner,
--                             executor-only, revoked, cross-estate, no-such-estate — is BYTE-
--                             IDENTICAL. A differing key set would answer "does that estate exist"
--                             and "am I known there" for free.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

create or replace function harness.workspace(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  set local role authenticated;
  select public.get_professional_workspace(p_estate) into v;
  reset role;
  return v;
end $$;

-- =================================================================================================
-- fixture — a delegate, a fiduciary-only user, and a delegate who is ALSO an executor
-- =================================================================================================
-- ★ THE DELEGATE ALREADY EXISTS. `55555555…` is the professional delegate the discovery suite
-- created and granted `estate_inventory` at `full_detail`. Reusing that viewer is deliberate: the
-- workspace must report exactly what discovery released, so it has to be asked about a viewer whose
-- release is independently pinned one file earlier.
insert into auth.users (id) values
  ('66666666-6666-4666-8666-666666666666'),  -- executor of estate A, NO membership at all
  ('77777777-7777-4777-8777-777777777777'),  -- professional delegate of A **and** trustee of A
  -- ★ USED ONLY BY THE PAYLOAD CAPTURE, on estate B. Kept off estate A deliberately so it cannot
  -- perturb any assertion in this file, and kept OUT of the estate-A delegate so the cross-estate
  -- refusal scenario keeps meaning what its name says.
  ('88888888-8888-4888-8888-888888888888')
on conflict do nothing;

insert into public.estate_memberships (estate_id, user_id, role, status) values
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '77777777-7777-4777-8777-777777777777', 'professional_delegate', 'approved')
on conflict do nothing;

insert into public.estate_designations (estate_id, user_id, designation_type, status) values
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '66666666-6666-4666-8666-666666666666', 'executor', 'active'),
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '77777777-7777-4777-8777-777777777777', 'trustee',  'active')
on conflict do nothing;

-- =================================================================================================
-- 19 · the gate — an approved professional_delegate membership, and nothing else
-- =================================================================================================
do $$
declare A     uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        B     uuid := 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';
        OWNER uuid := '11111111-1111-4111-8111-111111111111';
        BENE  uuid := '44444444-4444-4444-8444-444444444444';
        PRO   uuid := '55555555-5555-4555-8555-555555555555';
        EXEC_ uuid := '66666666-6666-4666-8666-666666666666';
        NOBODY uuid := '33333333-3333-4333-8333-333333333333';
        d jsonb;
begin
  raise notice '19 · professional workspace authority';

  -- ★ THE POSITIVE CASE FIRST. Every refusal below is meaningless if the routine refuses everyone.
  d := harness.workspace(PRO, A);
  if (d->>'authorized') <> 'true' then
    raise exception 'FAIL: the approved professional delegate was REFUSED their own workspace: %', d;
  end if;
  raise notice '  ok   an approved professional delegate receives a workspace';

  -- ★ IDENTITY COMES FROM THE MEMBERSHIP ROW, NOT FROM A CAPABILITY COMBINATION.
  if (d->>'relationship') <> 'professional_delegate' then
    raise exception 'FAIL: relationship is %, expected the membership role', d->>'relationship';
  end if;
  raise notice '  ok   the relationship reported is the authoritative membership role';

  -- ── refusals, all of which must be the SAME bytes ─────────────────────────────────────────────
  if (harness.workspace(OWNER, A)->>'authorized') <> 'false' then
    raise exception 'FAIL: the OWNER received a professional workspace over their own estate';
  end if;
  raise notice '  ok   the owner is refused — this is not an owner dashboard';

  -- ★ AND THE OWNERSHIP CHECK IS WHAT REFUSES THEM, WHICH HAD TO BE PROVED SEPARATELY.
  --
  -- The assertion immediately above passes with the ownership check DELETED — mutation-proved — for
  -- an uninteresting reason: this owner's membership row is `primary_user`, so the role filter
  -- already refuses them and the ownership check never runs. The assertion was true and was
  -- attributing the refusal to the wrong mechanism, which is the same shape as an
  -- `@ts-expect-error` that fires on a missing field rather than the excess one it names.
  --
  -- ★ CORRECTED IN PHASE 10-F. This comment used to say `estate_memberships` carries NO
  -- (estate, user) uniqueness, citing `list_estate_members`. That is CONTRADICTED BY LIVE:
  -- `db/tables/estate_memberships.sql` records a recon correction — the table HAS
  -- `unique (estate_id, user_id)`, so a user holds AT MOST ONE membership per estate. The harness
  -- omitted that constraint, which is what let this fixture exist at all.
  --
  -- The constraint is now in the preamble and this assertion STILL PASSES, which is the interesting
  -- part: the owner holds no other membership row on this estate, so the delegate row inserted below
  -- is their FIRST — the role filter therefore ADMITS them, and `is_estate_owner` is genuinely what
  -- refuses. The branch is covered by something other than its own comment.
  --
  -- What changed is the honesty of the claim: this is a DEFENCE-IN-DEPTH state, not a routine one.
  -- Reaching it in production would require an owner with a delegate membership and no primary_user
  -- row, which `ensure_primary_user_membership` and the on-conflict in `provision_from_invitation`
  -- between them make very hard. Defence in depth is worth testing; calling it "reachable" was not
  -- accurate, and the difference matters to whoever reads this next.
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (A, OWNER, 'professional_delegate', 'approved');
  begin
    if (harness.workspace(OWNER, A)->>'authorized') <> 'false' then
      raise exception 'FAIL: an owner holding a professional_delegate row received a workspace over '
        'their OWN estate — the ownership check is what must refuse this, and it did not';
    end if;
  exception when others then
    delete from public.estate_memberships
     where estate_id = A and user_id = OWNER and role = 'professional_delegate';
    raise;
  end;
  delete from public.estate_memberships
   where estate_id = A and user_id = OWNER and role = 'professional_delegate';
  raise notice '  ok   an owner is refused EVEN holding a delegate membership row (the ownership check)';

  if (harness.workspace(BENE, A)->>'authorized') <> 'false' then
    raise exception 'FAIL: a beneficiary received a professional workspace';
  end if;
  raise notice '  ok   a beneficiary is refused — membership alone is not delegation';

  -- ★ A FIDUCIARY DESIGNATION DOES NOT OPEN THIS DOOR. This user is an ACTIVE executor of estate A
  -- and holds no membership; their surface is the claim path, not this one.
  if (harness.workspace(EXEC_, A)->>'authorized') <> 'false' then
    raise exception 'FAIL: an executor with no delegate membership received a workspace';
  end if;
  raise notice '  ok   an executor designation does NOT confer the workspace';

  if (harness.workspace(NOBODY, A)->>'authorized') <> 'false' then
    raise exception 'FAIL: an unrelated authenticated user received a workspace';
  end if;
  if (harness.workspace(PRO, B)->>'authorized') <> 'false' then
    raise exception 'FAIL: the delegate reached ANOTHER estate''s workspace';
  end if;
  if (harness.workspace(null, A)->>'authorized') <> 'false' then
    raise exception 'FAIL: anonymous received a workspace';
  end if;
  raise notice '  ok   stranger, cross-estate and anonymous are each refused';
end $$;

-- =================================================================================================
-- 20 · the refusal is not an oracle
-- =================================================================================================
do $$
declare A uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        NOWHERE uuid := 'cccccccc-9999-4999-8999-cccccccccccc';  -- no such estate
        r jsonb;
        expected jsonb := jsonb_build_object('authorized', false);
begin
  raise notice '20 · refusal shape';

  -- ★ BYTE-IDENTICAL, NOT MERELY "authorized IS FALSE". A refusal carrying `capacities: []` on one
  -- branch and not another would distinguish "you are known here" from "you are not", and a refusal
  -- carrying `estate_display_name` would answer "does this estate exist" outright.
  for r in
    select harness.workspace(u, e) from (values
      ('11111111-1111-4111-8111-111111111111'::uuid, A),          -- owner
      ('44444444-4444-4444-8444-444444444444'::uuid, A),          -- beneficiary
      ('66666666-6666-4666-8666-666666666666'::uuid, A),          -- executor, no membership
      ('33333333-3333-4333-8333-333333333333'::uuid, A),          -- stranger
      ('55555555-5555-4555-8555-555555555555'::uuid,              -- delegate, WRONG estate
       'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'::uuid),
      ('55555555-5555-4555-8555-555555555555'::uuid, NOWHERE),    -- delegate, NO SUCH estate
      (null::uuid, A)                                             -- anonymous
    ) as t(u, e)
  loop
    if r <> expected then
      raise exception 'FAIL: a refusal differs from the canonical shape: % (expected %)', r, expected;
    end if;
  end loop;
  raise notice '  ok   all 7 refusal causes produce byte-identical output';

  -- ★ AND A NON-EXISTENT ESTATE IS INDISTINGUISHABLE FROM AN UNAUTHORIZED ONE. Asserted separately
  -- because it is the one an attacker actually probes with.
  if harness.workspace('55555555-5555-4555-8555-555555555555', NOWHERE)
     <> harness.workspace('55555555-5555-4555-8555-555555555555',
                          'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb') then
    raise exception 'FAIL: "no such estate" is distinguishable from "not your estate"';
  end if;
  raise notice '  ok   no-such-estate and not-your-estate are indistinguishable';
end $$;

-- =================================================================================================
-- 21 · fiduciary capacity is SEPARATE, additive, and never inferred
-- =================================================================================================
do $$
declare A    uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        PRO  uuid := '55555555-5555-4555-8555-555555555555';  -- delegate only
        -- ★ NOT `BOTH`. That is a SQL reserved word (it appears in `TRIM(BOTH ...)`), and plpgsql
        -- rejects it as a variable name with a bare syntax error pointing at the USE site rather than
        -- the declaration — which reads like a broken expression rather than a bad name.
        PRO_TRUSTEE uuid := '77777777-7777-4777-8777-777777777777';  -- delegate AND trustee
        d jsonb;
begin
  raise notice '21 · delegate ≠ fiduciary';

  -- ★ THE KEY IS ALWAYS PRESENT, AND EMPTY MEANS NONE. Omitting it for a delegate with no
  -- designation would make "we checked and there are none" indistinguishable from "we did not
  -- check", and a client cannot tell those apart from the payload.
  d := harness.workspace(PRO, A);
  if not (d ? 'capacities') then
    raise exception 'FAIL: capacities key absent for a delegate with no designation';
  end if;
  if jsonb_array_length(d->'capacities') <> 0 then
    raise exception 'FAIL: a delegate with NO designation reported capacities %', d->'capacities';
  end if;
  raise notice '  ok   a delegate with no designation reports an EMPTY capacity list, not an absent key';

  -- ★ THE ADDITIVE CASE — and it is what makes the empty list above a real observation rather than a
  -- routine that never populates the field at all.
  d := harness.workspace(PRO_TRUSTEE, A);
  if (d->>'authorized') <> 'true' then
    raise exception 'FAIL: a delegate who is also a trustee was refused';
  end if;
  if not (d->'capacities' @> '["trustee"]'::jsonb) then
    raise exception 'FAIL: an ACTIVE trustee designation was not reported: %', d->'capacities';
  end if;
  if (d->>'relationship') <> 'professional_delegate' then
    raise exception 'FAIL: a fiduciary capacity overwrote the relationship: %', d->>'relationship';
  end if;
  raise notice '  ok   a trustee designation ADDS a capacity without changing the relationship';

  -- ★ A REVOKED DESIGNATION CONFERS NOTHING.
  update public.estate_designations set status = 'revoked'
   where user_id = PRO_TRUSTEE and estate_id = A;
  d := harness.workspace(PRO_TRUSTEE, A);
  if jsonb_array_length(d->'capacities') <> 0 then
    raise exception 'FAIL: a REVOKED designation was still reported: %', d->'capacities';
  end if;
  raise notice '  ok   a revoked designation reports no capacity';
  update public.estate_designations set status = 'active'
   where user_id = PRO_TRUSTEE and estate_id = A;
end $$;

-- =================================================================================================
-- 22 · disclosure is delegated — the workspace adds nothing to what discovery released
-- =================================================================================================
do $$
declare A   uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        PRO uuid := '55555555-5555-4555-8555-555555555555';
        w jsonb; d jsonb;
begin
  raise notice '22 · inventory disclosure is delegated to get_estate_discovery';

  -- ★ THE WORKSPACE MUST AGREE WITH DISCOVERY EXACTLY, at every rung, or there are two disclosure
  -- authorities and the more permissive one is a leak.
  perform harness.grant_inventory(PRO, 'professional_delegate', 'category_summary');
  w := harness.workspace(PRO, A);
  d := harness.discovery(PRO, A);
  if (w->'inventory'->>'tier') <> (d->>'inventory_tier') then
    raise exception 'FAIL: workspace tier % <> discovery tier %',
      w->'inventory'->>'tier', d->>'inventory_tier';
  end if;
  if (w->'inventory'->'categories') <> (d->'categories') then
    raise exception 'FAIL: the workspace categories differ from the discovery categories';
  end if;
  if jsonb_array_length(w->'inventory'->'items') <> 0 then
    raise exception 'FAIL: the workspace published per-item rows at category_summary';
  end if;
  raise notice '  ok   at category_summary the workspace mirrors discovery exactly, items empty';

  -- ★ AND THE ABSENCE OF A GRANT REMOVES THE KEY, RATHER THAN EMPTYING IT. `inventory: {categories:
  -- []}` would tell the delegate an inventory exists and is being withheld — the disclosure
  -- `get_estate_discovery` avoids by omitting the key.
  delete from public.access_grants
   where estate_id = A and grantee_user_id = PRO and category = 'estate_inventory';
  w := harness.workspace(PRO, A);
  if (w->>'authorized') <> 'true' then
    raise exception 'FAIL: revoking the INVENTORY grant removed the whole workspace';
  end if;
  if w ? 'inventory' then
    raise exception 'FAIL: an ungranted delegate received an inventory key: %', w->'inventory';
  end if;
  raise notice '  ok   with no grant there is NO inventory key at all — not an empty one';

  -- ★ NO COUNT OF WHAT IS WITHHELD, ANYWHERE IN THE PAYLOAD. The estate demonstrably holds live
  -- assets at this moment; if any key in this payload reveals how many, the whole ladder is undone.
  if (select count(*) from public.estate_assets where estate_id = A and archived_at is null) = 0 then
    raise exception 'FAIL: precondition — the estate holds no live asset, so this proves nothing';
  end if;
  if w::text ~ '"(asset_count|hidden_count|withheld|total_assets|undisclosed)[^"]*"' then
    raise exception 'FAIL: the payload carries a withheld-quantity key: %', w;
  end if;
  raise notice '  ok   no key counts what is being withheld, on an estate that HAS withheld assets';

  -- restore the grant for anything downstream
  perform harness.grant_inventory(PRO, 'professional_delegate', 'category_summary');
end $$;

-- =================================================================================================
-- 23 · readiness never leaks through the workspace
-- =================================================================================================
do $$
declare A   uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        PRO uuid := '55555555-5555-4555-8555-555555555555';
        w jsonb;
begin
  raise notice '23 · no readiness, no score';

  w := harness.workspace(PRO, A);

  -- ★ POSITIVE CONTROL FIRST: the owner's readiness on this estate is NON-EMPTY. Asserting that a
  -- delegate receives no findings is worthless if there are no findings to receive.
  if jsonb_array_length(
       harness.readiness('11111111-1111-4111-8111-111111111111', A)->'findings') = 0 then
    raise exception 'FAIL: precondition — the owner has zero readiness findings, so the delegate '
      'assertions below would pass against nothing';
  end if;

  if w ? 'findings' or w ? 'finding_count' or w ? 'readiness' then
    raise exception 'FAIL: the workspace carries a readiness shape: %', w;
  end if;
  raise notice '  ok   no findings, finding_count or readiness key — while the owner HAS findings';

  if w::text ~* '"[^"]*(score|percent|grade|rating|weight|complete)[^"]*"\s*:' then
    raise exception 'FAIL: the workspace payload carries a score-like key: %', w;
  end if;
  raise notice '  ok   no score, percentage, grade or weighting key';

  -- The delegate is still refused readiness directly, which is the boundary the workspace must not
  -- route around.
  if (harness.readiness(PRO, A)->>'authorized') <> 'false' then
    raise exception 'FAIL: the delegate reached readiness directly';
  end if;
  raise notice '  ok   the delegate remains refused by get_estate_readiness itself';
end $$;

-- =================================================================================================
-- 24 · revocation removes the workspace; dormant conditions stay dormant
-- =================================================================================================
do $$
declare A   uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
        PRO uuid := '55555555-5555-4555-8555-555555555555';
        w jsonb;
begin
  raise notice '24 · revocation and dormancy';

  update public.estate_memberships set status = 'revoked'
   where estate_id = A and user_id = PRO and role = 'professional_delegate';
  w := harness.workspace(PRO, A);
  if (w->>'authorized') <> 'false' then
    raise exception 'FAIL: a REVOKED delegate still receives a workspace';
  end if;
  if w <> jsonb_build_object('authorized', false) then
    raise exception 'FAIL: a revoked delegate''s refusal differs from the canonical shape: %', w;
  end if;
  raise notice '  ok   a revoked membership removes the workspace, with the same refusal bytes';
  update public.estate_memberships set status = 'approved'
   where estate_id = A and user_id = PRO and role = 'professional_delegate';

  -- ★ A DEATH-CONDITIONED GRANT DISCLOSES NOTHING TODAY. Phase 11 activates this condition; until
  -- then the workspace must not be the surface that quietly honours it.
  -- Phase 11-B: the SPLIT condition (the fused value is no longer writable through the RPC).
  perform harness.grant_inventory(PRO, 'professional_delegate', 'full_detail',
                                  'after_verified_death');
  w := harness.workspace(PRO, A);
  if w ? 'inventory' then
    raise exception 'FAIL: a death-conditioned grant disclosed inventory through the workspace: %',
      w->'inventory';
  end if;
  raise notice '  ok   a death-conditioned grant stays dormant in the workspace';

  -- ★ AND AN APPROVED CLAIM STILL RELEASES NOTHING. The discovery suite leaves a claim approved on
  -- this estate; the workspace is asserted against that state rather than a hypothetical one.
  if public.estate_release_state(A) <> 'claim_approved' then
    raise exception 'FAIL: precondition — expected an approved claim from the discovery suite, got %',
      public.estate_release_state(A);
  end if;
  if harness.workspace(PRO, A) ? 'inventory' then
    raise exception 'FAIL: an APPROVED claim released inventory through the workspace';
  end if;
  raise notice '  ok   an APPROVED claim releases nothing through the workspace';

  perform harness.grant_inventory(PRO, 'professional_delegate', 'category_summary');
end $$;

-- =================================================================================================
-- 25 · DEFINER does not launder authority
-- =================================================================================================
do $$
declare v_secdef int;
begin
  raise notice '25 · definer posture';
  select count(*) into v_secdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef and p.proname = 'get_professional_workspace';
  if v_secdef <> 1 then
    raise exception 'FAIL: get_professional_workspace is not SECURITY DEFINER';
  end if;
  -- It runs as the function owner and is STILL refused, because the rule keys off auth.uid().
  if (harness.workspace('33333333-3333-4333-8333-333333333333',
                        'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')->>'authorized') <> 'false' then
    raise exception 'FAIL: DEFINER laundered authority';
  end if;
  raise notice '  ok   DEFINER does not launder authority';
end $$;

-- =================================================================================================
-- 26 · fixture integrity — this suite leaves the shared fixture as it found it
-- =================================================================================================
do $$ begin perform harness.assert_fixture_restored(); end $$;

do $$ begin raise notice 'ALL PROFESSIONAL WORKSPACE ASSERTIONS PASSED'; end $$;
