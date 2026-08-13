-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-G — SURVIVOR MODE: only `released` changes what an owner already authorized
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THIS FILE IS FOR. Survivor Mode consumes the existing release and disclosure architecture;
-- it adds no authorization system of its own. That is only a safe claim if three things are true,
-- and each is asserted here by EXECUTION over the full lifecycle:
--
--   1 · ONE STATE MATTERS. For every viewer class, a death-conditioned grant is invisible at
--       `active`, `death_verification_pending`, `death_verified`, `owner_notification_dispatched`,
--       `challenge_window` and `challenge_halted`, and visible ONLY at `released`. Six states must
--       change nothing; one must change exactly what the owner authored.
--
--   2 · RELEASE MANUFACTURES NOTHING (G1). No grant, membership, beneficiary, designation or tier
--       appears because a lifecycle moved. The authority tables are captured before and after and
--       compared byte-for-byte.
--
--   3 · RELATIONSHIP IS NOT A TIER (G3). A beneficiary, a professional delegate and an executor are
--       put in front of the SAME estate at `released`. What each sees is decided by the grant the
--       owner wrote for them — never by what they are. An executor with no grant sees nothing at
--       `released`, which is the assertion most likely to be "fixed" into a bug later.
--
-- ★ AND VIEWER-SCOPING IS PROVEN, NOT ASSUMED (G2). Two beneficiaries with different grants on the
-- same released estate must each see their own projection and NOTHING of the other's — not the
-- other's categories, not their tier, not their existence, not a count.
--
-- ★ EVERY WITHHOLDING ASSERTION IS PAIRED. §0 proves the instrument can observe a real disclosure
-- before any "nothing moved" claim is made.
--
-- Exit contract: raises on the first failed assertion.

\set ON_ERROR_STOP on

create schema if not exists harness_sv;
grant usage on schema harness_sv to anon, authenticated;

/** The composed survivor view — every surface a survivor can reach, as one value. */
create or replace function harness_sv.composed(p_uid uuid, p_estate uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  select jsonb_build_object(
    'discovery', harness_dv.try(format('select public.get_estate_discovery(%L)', p_estate)),
    'assets', harness_dv.try(format(
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

/** Authority tables for one estate — the G1 bracket. */
create or replace function harness_sv.authority(p_estate uuid)
returns jsonb language sql as $$
  select jsonb_build_object(
    'grants',       coalesce((select jsonb_agg(to_jsonb(g) order by g.id)
                                from public.access_grants g where g.estate_id = p_estate), '[]'::jsonb),
    'memberships',  coalesce((select jsonb_agg(to_jsonb(m) order by m.user_id, m.role)
                                from public.estate_memberships m where m.estate_id = p_estate), '[]'::jsonb),
    'designations', coalesce((select jsonb_agg(to_jsonb(d) order by d.id)
                                from public.estate_designations d where d.estate_id = p_estate), '[]'::jsonb),
    'beneficiaries', coalesce((select jsonb_agg(to_jsonb(b) order by b.id)
                                from public.beneficiaries b where b.estate_id = p_estate), '[]'::jsonb));
$$;

/** Drive an estate to a lifecycle state through the AUTHORITATIVE writer only. */
create or replace function harness_sv.drive(p_estate uuid, p_to text)
returns void language plpgsql as $$
begin
  perform public.apply_estate_lifecycle_transition(p_estate, p_to, null, 'sv-harness');
end $$;

-- =================================================================================================
-- 0 · THE INSTRUMENT CAN SEE A DISCLOSURE  (a control that cannot fail is not a control)
-- =================================================================================================
do $sv0$
declare
  OWN_ uuid; BEN uuid; S uuid; v jsonb;
begin
  raise notice ' ';
  raise notice '══ PHASE 11-G · survivor mode ══';
  raise notice '0 · instrument self-check';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into BEN;
  insert into public.estates (owner_id, name) values (OWN_, 'SV control') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved'), (S, BEN, 'beneficiary', 'approved');
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'SV control piece', null, null, null, null, null, null, 2500000);

  -- An IMMEDIATELY grant must disclose, or every "nothing moved" assertion below is vacuous.
  perform harness_dv.grant_inventory(S, OWN_, BEN, 'beneficiary', 'category_summary', 'immediately');
  v := harness_sv.composed(BEN, S);
  if position('category_summary' in v::text) = 0 then
    raise exception 'FAIL[control]: an immediately-granted beneficiary sees nothing — the composed '
      'survivor instrument cannot observe a disclosure: %', v::text;
  end if;
  raise notice '  ok   CONTROL: an immediately-granted beneficiary IS visible to the instrument';
end $sv0$;

-- =================================================================================================
-- 1 · THE SEVEN-STATE MATRIX — six states change nothing, one changes exactly the authored grant
-- =================================================================================================
do $sv1$
declare
  OWN_ uuid; BEN uuid; DELE uuid; EXEC_ uuid; STRG uuid; OTHER_OWN uuid;
  S uuid; F uuid;
  v_state text; v_before jsonb; v_now jsonb; v_auth_before jsonb;
  ben_base jsonb; dele_base jsonb; exec_base jsonb; strg_base jsonb; foreign_base jsonb;
  v_tier text; n int;
begin
  raise notice '1 · the seven-state matrix';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into BEN;
  insert into auth.users default values returning id into DELE;
  insert into auth.users default values returning id into EXEC_;
  insert into auth.users default values returning id into STRG;
  insert into auth.users default values returning id into OTHER_OWN;
  insert into public.estates (owner_id, name) values (OWN_, 'SV Estate S') returning id into S;
  insert into public.estates (owner_id, name) values (OTHER_OWN, 'SV Estate F') returning id into F;

  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (S, OWN_, 'primary_user', 'approved'),
    (S, BEN,  'beneficiary', 'approved'),
    (S, DELE, 'professional_delegate', 'approved'),
    (F, OTHER_OWN, 'primary_user', 'approved');
  -- ★ AN EXECUTOR WITH NO GRANT. The most important row in this file: fiduciary capacity must
  -- confer NO disclosure, at any lifecycle state, including released (G3).
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EXEC_, 'executor', 'active');

  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'SV painting', null, null, null, null, null, null, 4400000);
  insert into public.normalized_assets (estate_id, connection_id, institution_name, asset_group, balance_cents, currency)
  values (S, gen_random_uuid(), 'SV Bank', 'cashBank', 9100000, 'USD');

  -- The owner authored ONE death-conditioned inventory grant, to the beneficiary.
  perform harness_dv.grant_inventory(S, OWN_, BEN, 'beneficiary', 'category_summary', 'after_verified_death');

  v_auth_before := harness_sv.authority(S);
  ben_base     := harness_sv.composed(BEN, S);
  dele_base    := harness_sv.composed(DELE, S);
  exec_base    := harness_sv.composed(EXEC_, S);
  strg_base    := harness_sv.composed(STRG, S);
  foreign_base := harness_sv.composed(OTHER_OWN, S);

  if position('category_summary' in ben_base::text) > 0 then
    raise exception 'FAIL: the death-conditioned grant discloses at `active`';
  end if;

  -- ── SIX PRE-RELEASE STATES: every viewer byte-identical to the active world ───────────────────
  foreach v_state in array array['death_verification_pending', 'death_verified',
                                 'owner_notification_dispatched', 'challenge_window'] loop
    perform harness_sv.drive(S, v_state);
    if harness_sv.composed(BEN, S)::text is distinct from ben_base::text then
      raise exception 'FAIL[%]: the death-conditioned beneficiary payload MOVED before release', v_state;
    end if;
    if harness_sv.composed(DELE, S)::text is distinct from dele_base::text
       or harness_sv.composed(EXEC_, S)::text is distinct from exec_base::text
       or harness_sv.composed(STRG, S)::text is distinct from strg_base::text then
      raise exception 'FAIL[%]: a non-granted viewer payload MOVED before release', v_state;
    end if;
    raise notice '  ok   % discloses NOTHING to any viewer', v_state;
  end loop;

  -- challenge_halted is terminal, so it needs its own estate to reach from the window.
  declare H uuid; HOWN uuid; HBEN uuid;
  begin
    insert into auth.users default values returning id into HOWN;
    insert into auth.users default values returning id into HBEN;
    insert into public.estates (owner_id, name) values (HOWN, 'SV Estate H') returning id into H;
    insert into public.estate_memberships (estate_id, user_id, role, status)
    values (H, HOWN, 'primary_user', 'approved'), (H, HBEN, 'beneficiary', 'approved');
    perform set_config('request.jwt.claim.sub', HOWN::text, true);
    perform public.create_estate_asset(H, 'artwork', 'SV halted piece', null, null, null, null, null, null, 3300000);
    perform harness_dv.grant_inventory(H, HOWN, HBEN, 'beneficiary', 'category_summary', 'after_verified_death');
    declare h_base jsonb := harness_sv.composed(HBEN, H);
    begin
      perform harness_sv.drive(H, 'death_verification_pending');
      perform harness_sv.drive(H, 'challenge_halted');
      if harness_sv.composed(HBEN, H)::text is distinct from h_base::text then
        raise exception 'FAIL[challenge_halted]: a halted process disclosed — the owner said they '
          'are alive and the estate opened anyway';
      end if;
      raise notice '  ok   challenge_halted discloses NOTHING (the owner objected)';
    end;
  end;

  -- ── RELEASED: exactly the authored grant, for exactly the authored viewer ─────────────────────
  perform harness_sv.drive(S, 'released');

  v_now := harness_sv.composed(BEN, S);
  if v_now::text is not distinct from ben_base::text then
    raise exception 'FAIL[control]: released did NOT move the payload of the viewer the owner '
      'authored — every assertion above is vacuous because this instrument sees no disclosure';
  end if;
  if position('category_summary' in v_now::text) = 0 then
    raise exception 'FAIL: the released beneficiary does not see the AUTHORED tier: %', v_now::text;
  end if;
  raise notice '  ok   RELEASED: the beneficiary sees exactly the grant the owner wrote';

  -- ★ G3, THE ROW MOST LIKELY TO BE "FIXED" INTO A BUG: an EXECUTOR with an active designation and
  -- NO grant sees nothing at released. Fiduciary capacity is not a disclosure tier.
  if harness_sv.composed(EXEC_, S)::text is distinct from exec_base::text then
    raise exception 'FAIL[G3]: an executor with NO GRANT gained disclosure at released — fiduciary '
      'capacity became a tier';
  end if;
  perform set_config('request.jwt.claim.sub', EXEC_::text, true);
  select public.inventory_disclosure_tier(S, EXEC_) into v_tier;
  if v_tier is distinct from 'hidden' then
    raise exception 'FAIL[G3]: executor resolved tier % at released', coalesce(v_tier, 'NULL');
  end if;
  raise notice '  ok   G3: an executor with no grant sees NOTHING at released (capacity is not tier)';

  -- ★ A PROFESSIONAL DELEGATE with a relationship but no death grant likewise gains nothing, and
  -- never becomes an owner.
  if harness_sv.composed(DELE, S)::text is distinct from dele_base::text then
    raise exception 'FAIL[G3]: a professional delegate with no qualifying grant gained disclosure';
  end if;
  if (harness_sv.composed(DELE, S) -> 'discovery' ->> 'is_owner') = 'true' then
    raise exception 'FAIL[G3]: a professional delegate is reported as OWNER';
  end if;
  raise notice '  ok   G3: a professional delegate gains nothing and never becomes owner';

  -- ★ NEGATIVE VIEWERS: stranger, foreign owner, anonymous — unmoved and refused.
  if harness_sv.composed(STRG, S)::text is distinct from strg_base::text then
    raise exception 'FAIL: an unrelated authenticated user was moved by release';
  end if;
  if harness_sv.composed(OTHER_OWN, S)::text is distinct from foreign_base::text then
    raise exception 'FAIL: a foreign-estate owner was moved by release';
  end if;
  if harness_sv.composed(null, S) -> 'discovery' ? 'categories' then
    raise exception 'FAIL: an anonymous caller received categories from a released estate';
  end if;
  raise notice '  ok   stranger, foreign owner and anonymous all unmoved and refused';

  -- ★ G1: RELEASE MANUFACTURED NOTHING.
  if harness_sv.authority(S)::text is distinct from v_auth_before::text then
    raise exception 'FAIL[G1]: release created or altered a grant, membership, beneficiary or '
      'designation';
  end if;
  raise notice '  ok   G1: no grant, membership, beneficiary or designation was manufactured';

  -- ★ CROSS-ESTATE: S released; F is untouched and its owner sees no change on their own estate.
  if public.estate_lifecycle_state(F) <> 'active' then
    raise exception 'FAIL: releasing S moved F''s lifecycle';
  end if;
  raise notice '  ok   cross-estate: the foreign estate lifecycle is untouched';
end $sv1$;

-- =================================================================================================
-- 2 · G2 — VIEWER-SCOPED: one survivor learns NOTHING about another
-- =================================================================================================
do $sv2$
declare
  OWN_ uuid; A uuid; B uuid; S uuid;
  a_view jsonb; b_view jsonb; a_before jsonb;
begin
  raise notice '2 · viewer scoping (G2)';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into A;
  insert into auth.users default values returning id into B;
  insert into public.estates (owner_id, name) values (OWN_, 'SV Estate G2') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (S, OWN_, 'primary_user', 'approved'),
    (S, A, 'beneficiary', 'approved'),
    (S, B, 'beneficiary', 'approved');
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'G2 painting', null, null, null, null, null, null, 5100000);
  perform public.create_estate_asset(S, 'secondaryProperty', 'G2 house', null, null, null, null, null, null, 88000000);

  -- Two DIFFERENT owner-authored grants: A gets inventory at category_summary; B gets nothing.
  perform harness_dv.grant_inventory(S, OWN_, A, 'beneficiary', 'category_summary', 'after_verified_death');

  a_before := harness_sv.composed(A, S);
  perform harness_sv.drive(S, 'death_verification_pending');
  perform harness_sv.drive(S, 'death_verified');
  perform harness_sv.drive(S, 'owner_notification_dispatched');
  perform harness_sv.drive(S, 'challenge_window');
  perform harness_sv.drive(S, 'released');

  a_view := harness_sv.composed(A, S);
  b_view := harness_sv.composed(B, S);

  if a_view::text is not distinct from a_before::text then
    raise exception 'FAIL[control]: A did not gain their authored grant at released';
  end if;

  -- ★ B HAS NO GRANT AND MUST LEARN NOTHING — not that A exists, not what A received, not a count.
  if b_view -> 'discovery' ? 'categories' then
    raise exception 'FAIL[G2]: a beneficiary with NO grant received categories at released';
  end if;
  if b_view::text ~* '(other|another|remaining|withheld|hidden_count|beneficiar[a-z]*_count|shared_with)' then
    raise exception 'FAIL[G2]: B''s payload references other parties or withheld counts: %', b_view::text;
  end if;
  -- No count of any kind that could reveal the other viewer's existence.
  if b_view -> 'discovery' ? 'document_count'
     and (b_view -> 'discovery' ->> 'document_count')::int > 0 then
    raise exception 'FAIL[G2]: B sees a nonzero document count with no grant';
  end if;
  raise notice '  ok   G2: a grantless beneficiary learns nothing — no categories, no counts, no others';

  -- ★ AND A LEARNS NOTHING ABOUT B EITHER. A's payload must not name another party or their tier.
  if a_view::text ~* '(other_beneficiar|another_viewer|shared_with_count|recipients)' then
    raise exception 'FAIL[G2]: A''s payload references other recipients: %', a_view::text;
  end if;
  raise notice '  ok   G2: the authorized survivor learns nothing about any other recipient';
end $sv2$;

-- =================================================================================================
-- 3 · GRANT-SHAPE MATRIX AT RELEASED — never / revoked / over-ceiling / immediate / fused / incapacity
-- =================================================================================================
do $sv3$
declare
  OWN_ uuid; V uuid; S uuid; v_tier text; v_cond text; base jsonb;
begin
  raise notice '3 · grant shapes at released';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into V;
  insert into public.estates (owner_id, name) values (OWN_, 'SV Estate G3') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (S, OWN_, 'primary_user', 'approved'), (S, V, 'beneficiary', 'approved');
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'G3 piece', null, null, null, null, null, null, 6200000);

  perform harness_sv.drive(S, 'death_verification_pending');
  perform harness_sv.drive(S, 'death_verified');
  perform harness_sv.drive(S, 'owner_notification_dispatched');
  perform harness_sv.drive(S, 'challenge_window');
  perform harness_sv.drive(S, 'released');

  -- Each condition, at the SAME tier, on a RELEASED estate. Only two may disclose.
  foreach v_cond in array array['never', 'after_verified_incapacity',
                                'after_verified_death_or_incapacity', 'after_claim_case_approval',
                                'after_identity_verification'] loop
    perform harness_rc.regrant_on(S, V, 'estate_inventory', 'category_summary', v_cond);
    perform set_config('request.jwt.claim.sub', V::text, true);
    select public.inventory_disclosure_tier(S, V) into v_tier;
    if v_tier is distinct from 'hidden' then
      raise exception 'FAIL: % resolved tier % on a RELEASED estate', v_cond, coalesce(v_tier, 'NULL');
    end if;
  end loop;
  raise notice '  ok   never / incapacity / fused / claim / identity all stay hidden at released';

  -- immediately: unchanged by release (it was already live).
  perform harness_rc.regrant_on(S, V, 'estate_inventory', 'category_summary', 'immediately');
  perform set_config('request.jwt.claim.sub', V::text, true);
  select public.inventory_disclosure_tier(S, V) into v_tier;
  if v_tier is distinct from 'category_summary' then
    raise exception 'FAIL: an immediately grant resolved % at released', coalesce(v_tier, 'NULL');
  end if;
  raise notice '  ok   an immediate grant is UNCHANGED by release';

  -- REVOKED death grant stays revoked.
  perform harness_rc.regrant_on(S, V, 'estate_inventory', 'category_summary', 'after_verified_death');
  update public.access_grants set status = 'revoked'
   where estate_id = S and grantee_user_id = V and category = 'estate_inventory';
  perform set_config('request.jwt.claim.sub', V::text, true);
  select public.inventory_disclosure_tier(S, V) into v_tier;
  if v_tier is distinct from 'hidden' then
    raise exception 'FAIL: a REVOKED death grant resolved % at released', coalesce(v_tier, 'NULL');
  end if;
  raise notice '  ok   a revoked grant stays revoked at released';

  -- OVER-CEILING death grant is clamped at released.
  perform harness_rc.regrant_on(S, V, 'estate_inventory', 'full_detail', 'after_verified_death');
  perform set_config('request.jwt.claim.sub', V::text, true);
  select public.inventory_disclosure_tier(S, V) into v_tier;
  if v_tier is distinct from 'hidden' then
    raise exception 'FAIL: an over-ceiling (beneficiary full_detail) grant resolved % at released',
      coalesce(v_tier, 'NULL');
  end if;
  raise notice '  ok   the ceiling clamps an over-ceiling grant even at released';
end $sv3$;

-- =================================================================================================
-- 4 · AGGREGATE DISCLOSURE AT RELEASED — hidden world moves, released payload does not
-- =================================================================================================
do $sv4$
declare
  OWN_ uuid; V uuid; S uuid; before_ jsonb; after_ jsonb; ctrl jsonb;
  v_asset uuid; v_disco jsonb; v_cat jsonb;
begin
  raise notice '4 · aggregate disclosure at released (10-F method)';

  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into V;
  insert into public.estates (owner_id, name) values (OWN_, 'SV Estate AG') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status) values
    (S, OWN_, 'primary_user', 'approved'), (S, V, 'beneficiary', 'approved');
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  -- ONE asset in ONE category: the single-item oracle fixture.
  perform public.create_estate_asset(S, 'artwork', 'AG lone piece', null, null, null, null, null, null, 3717700);

  perform harness_dv.grant_inventory(S, OWN_, V, 'beneficiary', 'category_summary', 'after_verified_death');
  perform harness_sv.drive(S, 'death_verification_pending');
  perform harness_sv.drive(S, 'death_verified');
  perform harness_sv.drive(S, 'owner_notification_dispatched');
  perform harness_sv.drive(S, 'challenge_window');
  perform harness_sv.drive(S, 'released');

  -- ★ THE SINGLE-ITEM ORACLE, POST-RELEASE. The exact value must be underivable at this tier.
  perform set_config('request.jwt.claim.sub', V::text, true);
  set local role authenticated;
  select public.get_estate_discovery(S) into v_disco;
  reset role;
  v_cat := v_disco -> 'categories' -> 0;
  if (v_cat ->> 'item_count')::int <> 1 then
    raise exception 'FAIL: single-item category reports item_count %', v_cat ->> 'item_count';
  end if;
  if v_cat -> 'total_cents' is distinct from 'null'::jsonb then
    raise exception 'FAIL: an exact category total was published at category_summary: %', v_cat::text;
  end if;
  if position('3717700' in v_disco::text) > 0 then
    raise exception 'FAIL: the exact single-asset value leaked at released';
  end if;
  raise notice '  ok   ORACLE: a single-item category brackets its value at released';

  -- ★ EQUIVALENCE: change the HIDDEN world (a category this viewer is not granted cannot exist,
  -- so use an ARCHIVED asset — withdrawn material must never rejoin an aggregate).
  before_ := harness_sv.composed(V, S);
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  select public.create_estate_asset(S, 'secondaryProperty', 'AG hidden house', null, null, null, null, null, null, 91000000)
    into v_asset;
  perform public.archive_estate_asset(v_asset);
  after_ := harness_sv.composed(V, S);
  if after_::text is distinct from before_::text then
    raise exception 'FAIL: an ARCHIVED asset moved the released survivor payload — withdrawn '
      'material rejoined an aggregate. before=% after=%', before_::text, after_::text;
  end if;
  raise notice '  ok   EQUIVALENCE: an archived asset moves no byte of the released payload';

  -- ★ POSITIVE CONTROL: an UNARCHIVED asset in the granted category DOES move it, so the
  -- equivalence above is not measuring a frozen instrument.
  perform set_config('request.jwt.claim.sub', OWN_::text, true);
  perform public.create_estate_asset(S, 'artwork', 'AG second piece', null, null, null, null, null, null, 1200000);
  ctrl := harness_sv.composed(V, S);
  if ctrl::text is not distinct from after_::text then
    raise exception 'FAIL[control]: an AUTHORIZED change did not move the payload — the equivalence '
      'assertion above is vacuous';
  end if;
  raise notice '  ok   CONTROL: an authorized change DOES move the released payload';
end $sv4$;

do $$
begin
  raise notice ' ';
  raise notice 'ALL SURVIVOR MODE ASSERTIONS PASSED';
end $$;
