-- db/tests/capture_executor_payloads.sql
--
-- Emit one REAL `get_executor_workspace` payload per workflow state, so the mobile decoder is
-- written against what the function actually returns rather than what a developer imagines it
-- returns.
--
-- ★ WHY THIS FILE HAD TO EXIST BEFORE THE CLIENT DID. The deployed database holds NO fixture with an
-- active executor or trustee designation — probed through the product path as all four synthetic
-- personas, every one reported zero designations and every estate answered `{"authorized": false}`.
-- So the refused branch is capturable from production and the AUTHORIZED branch is not. Creating a
-- live one is a one-way door: `provision_from_invitation` is the only writer of
-- `estate_designations` and it only ever inserts `status = 'active'`; nothing client-reachable
-- revokes. Manufacturing one would have meant production SQL to undo.
--
-- This is the honest substitute, and its evidence class is stated rather than implied: the payloads
-- below are produced by EXECUTING `db/functions/executor_workspace.sql` — the same body the
-- source↔deployment reconciler reports DEPLOYED — against fixtures built by the real routines
-- (`initiate_death_verification_case`, `admin_decide_death_verification_case`,
-- `challenge_death_process`, `apply_estate_lifecycle_transition`). It is function-execution
-- evidence, not a hand-written fixture and not a production capture.
--
-- ★ THE REFUSED PAYLOAD IS CAPTURED HERE **AND** VERBATIM FROM PRODUCTION, and the two are compared
-- in the client (`features/executor/__tests__/capturedPayloads.test.ts`). That comparison is what
-- makes the authorized branch trustworthy: if this harness reproduced production's refusal shape
-- byte-for-byte, it is running the same contract.
--
-- Output: one row per scenario, `label | payload`. The runner writes it to a JSON fixture.

\set ON_ERROR_STOP on

create schema if not exists harness_ewc;
grant usage on schema harness_ewc to anon, authenticated;

/** One viewer's workflow payload, read through the same role the product uses. */
create or replace function harness_ewc.capture(p_label text, p_uid uuid, p_estate uuid)
returns table (label text, payload jsonb) language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  select public.get_executor_workspace(p_estate) into v;
  reset role;
  return query select p_label, v;
end $$;

/**
 * Walk the lifecycle to a target state one LEGAL edge at a time.
 *
 * ★ NOT A SHORTCUT AROUND THE TRANSITION MAP — it drives the real
 * `apply_estate_lifecycle_transition`, which refuses any edge the product forbids. Jumping straight
 * to `challenge_window` was the first thing this file tried, and the map correctly refused it. A
 * capture that reached a state the product cannot reach would produce a payload no client will ever
 * see, which is worse than no fixture.
 */
create or replace function harness_ewc.walk(p_estate uuid, p_to text)
returns void language plpgsql as $$
declare v_cur text; v_next text; v_guard int := 0;
begin
  loop
    v_cur := public.estate_lifecycle_state(p_estate);
    exit when v_cur = p_to;
    v_guard := v_guard + 1;
    if v_guard > 8 then
      raise exception 'walk: no path from % to % within the map', v_cur, p_to;
    end if;
    v_next := case
      -- `challenge_halted` has inbound edges from four states; take it as soon as one is reached.
      when p_to = 'challenge_halted'
       and v_cur in ('death_verification_pending', 'death_verified',
                     'owner_notification_dispatched', 'challenge_window') then 'challenge_halted'
      when v_cur = 'active'                        then 'death_verification_pending'
      when v_cur = 'death_verification_pending'    then 'death_verified'
      when v_cur = 'death_verified'                then 'owner_notification_dispatched'
      when v_cur = 'owner_notification_dispatched' then 'challenge_window'
      when v_cur = 'challenge_window'              then 'released'
      else null
    end;
    if v_next is null then
      raise exception 'walk: no edge out of % toward %', v_cur, p_to;
    end if;
    perform public.apply_estate_lifecycle_transition(p_estate, v_next, null, 'ewc-capture');
  end loop;
end $$;

/** Where each scenario's (viewer, estate) pair lands, so the final SELECT can name them. */
create table if not exists harness_ewc.fixture (
  label  text primary key,
  uid    uuid,
  estate uuid not null
);

/**
 * Build one estate per scenario. Separate estates throughout: a verification case is one-per-estate
 * and a lifecycle is one-per-estate, so sharing would make later scenarios overwrite earlier ones.
 */
do $ewc$
declare
  OWN_ uuid; EX uuid; TR uuid; DELE uuid; STRG uuid; ADM uuid;
  S uuid; v_case uuid;
begin
  insert into auth.users default values returning id into ADM;
  insert into public.admins (user_id) values (ADM) on conflict do nothing;

  -- ── 1 · NOT STARTED — executor, lifecycle active, no case, no claim ────────────────────────────
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into auth.users default values returning id into DELE;
  insert into auth.users default values returning id into STRG;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC not started') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved'), (S, DELE, 'professional_delegate', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  insert into harness_ewc.fixture values
    ('executor_not_started', EX, S),
    -- Every refusal class this client can actually reach, from the SAME estate, so the client can
    -- prove they are byte-identical against real output rather than against one another.
    ('refused_owner', OWN_, S),
    ('refused_professional_delegate', DELE, S),
    ('refused_stranger', STRG, S);

  -- ── 2 · NOT STARTED, TRUSTEE — the capacity sameness fixture ───────────────────────────────────
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into TR;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC trustee') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, TR, 'trustee', 'active');
  insert into harness_ewc.fixture values ('trustee_not_started', TR, S);

  -- ── 3 · IN PROGRESS — an open verification case ────────────────────────────────────────────────
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC open') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.initiate_death_verification_case(S);
  insert into harness_ewc.fixture values ('executor_verification_open', EX, S);

  -- ── 4 · CANCELLED — the fiduciary withdrew their own case ──────────────────────────────────────
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC cancelled') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.initiate_death_verification_case(S);
  select c.id into v_case from public.death_verification_cases c where c.estate_id = S;
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.cancel_death_verification_case(v_case);
  insert into harness_ewc.fixture values ('executor_verification_cancelled', EX, S);

  -- ── 5 · REJECTED — an administrator refused the evidence ───────────────────────────────────────
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC rejected') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.initiate_death_verification_case(S);
  select c.id into v_case from public.death_verification_cases c where c.estate_id = S;
  perform harness_dv.as_admin(ADM,
    format('select public.admin_decide_death_verification_case(%L, ''reject'')', v_case));
  insert into harness_ewc.fixture values ('executor_verification_rejected', EX, S);

  -- ── 6 · VERIFIED — attained level raised, then decided ─────────────────────────────────────────
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC verified') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.initiate_death_verification_case(S);
  select c.id into v_case from public.death_verification_cases c where c.estate_id = S;
  perform harness_dv.as_admin(ADM, format(
    'select public.admin_set_attained_verification_level(%L, ''enhanced_kyc''::public.verification_level, ''ewc'')',
    v_case));
  perform harness_dv.as_admin(ADM,
    format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));
  insert into harness_ewc.fixture values ('executor_verification_verified', EX, S);

  -- ── 7 · CHALLENGE WINDOW OPEN ──────────────────────────────────────────────────────────────────
  --
  -- ★ REACHED THE WAY THE PRODUCT REACHES IT — a case is opened and VERIFIED before the lifecycle
  -- advances. Driving the lifecycle alone would have produced `challenge_window_open: true` beside
  -- `verification.state: 'none'`, a pairing no real estate can present, and a screen built against
  -- it would be built against a state it will never see.
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC window') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.initiate_death_verification_case(S);
  select c.id into v_case from public.death_verification_cases c where c.estate_id = S;
  perform harness_dv.as_admin(ADM, format(
    'select public.admin_set_attained_verification_level(%L, ''enhanced_kyc''::public.verification_level, ''ewc'')',
    v_case));
  perform harness_dv.as_admin(ADM,
    format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));
  perform harness_ewc.walk(S, 'challenge_window');
  insert into harness_ewc.fixture values ('executor_challenge_window', EX, S);

  -- ── 8 · HALTED — the process was stopped after verification ───────────────────────────────────
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC halted') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.initiate_death_verification_case(S);
  select c.id into v_case from public.death_verification_cases c where c.estate_id = S;
  perform harness_dv.as_admin(ADM, format(
    'select public.admin_set_attained_verification_level(%L, ''enhanced_kyc''::public.verification_level, ''ewc'')',
    v_case));
  perform harness_dv.as_admin(ADM,
    format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));
  perform harness_ewc.walk(S, 'challenge_halted');
  insert into harness_ewc.fixture values ('executor_challenge_halted', EX, S);

  -- ── 9 · RELEASE COMPLETE, WITH NO VERIFICATION CASE ON RECORD ─────────────────────────────────
  --
  -- ★ THE DELIBERATE ODD ONE, AND THE ONLY ONE BUILT BY LIFECYCLE ALONE. `process` and
  -- `verification` are computed from DIFFERENT sources — `estate_lifecycle_state` and
  -- `death_verification_cases` — and a client that inferred one from the other would be inventing a
  -- coupling the payload does not carry. Every other fixture advances them together, so without this
  -- row a decoder that required `release_completed` to imply a verified case would pass everything.
  -- Scenario 11 covers the ordinary route to `released`.
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC released') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform harness_ewc.walk(S, 'released');
  insert into harness_ewc.fixture values ('executor_released', EX, S);

  -- ── 10 · THE CALLER'S OWN CLAIM IS SUBMITTED ───────────────────────────────────────────────────
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC claim') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  -- `submit_claim_packet` lives in migration 0023 and is not among SQL_SUITE_PARTS, so the row is
  -- inserted directly. What is being captured is the PROJECTION's output for a submitted claim; how
  -- the row arrived does not change the shape the client must decode. The columns written are
  -- exactly the ones the RPC writes.
  insert into public.claim_packets (estate_id, requested_by, status)
  values (S, EX, 'submitted');
  insert into harness_ewc.fixture values ('executor_claim_submitted', EX, S);

  -- ── 11 · NO CURRENT ACTION — every action's precondition is false at once ──────────────────────
  --
  -- ★ THE STATE THE CLIENT IS MOST LIKELY TO GET WRONG, and the reason it is built explicitly: an
  -- authorized fiduciary with an EMPTY `actions` array is not the same fact as an unauthorized one,
  -- and every other authorized fixture here has at least one action. Without this row a client that
  -- collapsed "authorized, nothing to do" into the refusal state would pass every capture test.
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC no action') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'active');
  perform set_config('request.jwt.claim.sub', EX::text, true);
  perform public.initiate_death_verification_case(S);
  select c.id into v_case from public.death_verification_cases c where c.estate_id = S;
  perform harness_dv.as_admin(ADM, format(
    'select public.admin_set_attained_verification_level(%L, ''enhanced_kyc''::public.verification_level, ''ewc'')',
    v_case));
  perform harness_dv.as_admin(ADM,
    format('select public.admin_decide_death_verification_case(%L, ''verify'')', v_case));
  insert into public.claim_packets (estate_id, requested_by, status) values (S, EX, 'submitted');
  perform harness_ewc.walk(S, 'released');
  insert into harness_ewc.fixture values ('executor_no_current_action', EX, S);

  -- ── 12 · REVOKED FIDUCIARY — the designation existed and no longer does ────────────────────────
  insert into auth.users default values returning id into OWN_;
  insert into auth.users default values returning id into EX;
  insert into public.estates (owner_id, name) values (OWN_, 'EWC revoked') returning id into S;
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (S, OWN_, 'primary_user', 'approved');
  -- `revoked_at` is a production column the harness table does not model; `status` is the only
  -- field `is_estate_executor` reads, and it is the field under test here.
  insert into public.estate_designations (estate_id, user_id, designation_type, status)
  values (S, EX, 'executor', 'revoked');
  insert into harness_ewc.fixture values ('refused_revoked_fiduciary', EX, S);

  -- ── 13 · A WELL-FORMED ESTATE ID THAT IS NO ESTATE ────────────────────────────────────────────
  insert into harness_ewc.fixture values
    ('refused_nonexistent_estate', EX, '00000000-0000-4000-8000-000000000000');
end $ewc$;

/**
 * ★ THE FIXTURE SET IS ASSERTED BEFORE IT IS EMITTED. A builder that silently skipped a scenario
 * would produce a smaller JSON object, and a smaller object still parses — the runner's own
 * scenario-count floor is the second line of defence, this one is the first and it names the gap.
 */
do $ewc_check$
declare n int;
begin
  select count(*) into n from harness_ewc.fixture;
  if n <> 16 then
    raise exception 'CAPTURE INCOMPLETE: built % scenarios, expected 16', n;
  end if;
  if exists (select 1 from harness_ewc.fixture where estate is null) then
    raise exception 'CAPTURE INCOMPLETE: a scenario has no estate';
  end if;
end $ewc_check$;

select jsonb_pretty(jsonb_object_agg(c.label, c.payload))
from harness_ewc.fixture f
cross join lateral harness_ewc.capture(f.label, f.uid, f.estate) c;
