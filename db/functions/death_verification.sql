-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-C · DEATH-VERIFICATION ROUTINES — initiation, evidence, review, decision, lifecycle
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ NOTHING IN THIS FILE RELEASES ANYTHING. No routine here writes `access_grants`, `documents`,
-- `encrypted_instructions`, `claim_packets`, `notifications`, or any visibility tier. No routine
-- calls `release_condition_satisfied`, `estate_release_state`, or any disclosure projection. The
-- case is a record of facts about verification — it is never an access instrument, and the Phase
-- 11-C suite proves every state it can reach leaves every viewer's composed payload byte-identical.
--
-- ★ THE GATES LIVE INSIDE THE DEFINERS (the DEFINER-door discipline). Every client-reachable
-- routine re-derives its own authority; nothing trusts a wrapper.
--
-- ★ REFUSAL SHAPE. For the client-reachable routines the unauthorized answer is ONE sentinel —
-- `not_authorized` (42501) — for every cause an unauthenticated identity check does not cover:
-- nonexistent estate, real-but-foreign estate, nonexistent case, foreign case, wrong role, revoked
-- designation. The gate runs BEFORE any existence lookup can differentiate, so a probe cannot use
-- refusal bytes to learn whether an estate or case exists (T9: case existence is itself protected).
-- `auth_required` for a missing session is the one distinguishable cause, matching every existing
-- gate in the repo. Admin routines may name their causes — an authenticated platform admin behind
-- AAL2 + freshness is authorized to know a case exists.
--
-- ★ REQUIRED ≥ ATTAINED IS ENFORCED HERE (H2 closed). `admin_decide_death_verification_case`
-- re-derives the required level LIVE at decision time and refuses `verify` unless the attained
-- level meets it. The initiation-time snapshot on the case row is a record for the case file,
-- never the enforcement input — a policy tightened mid-case tightens the case.
--
-- Deploys via `db/bundles/death_verification_bundle.sql` (migration 0052 + the lifecycle reader +
-- this file). Source of truth — re-apply on DB reset.
--
-- ★ `estate_lifecycle_state` MOVED OUT IN PHASE 11-D — see `db/functions/estate_lifecycle_state.sql`.
-- The reader now ships with the release-conditions bundle (the disclosure evaluators consume it as
-- the predicate's lifecycle argument, and the FIRST pasted artifact must carry the seam so no paste
-- order leaves a consumer referencing a reader that does not exist). The routines below still call
-- it at execution time; the death bundle carries the same source file so it stays single-paste
-- runnable.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- apply_estate_lifecycle_transition(p_estate, p_to, p_case, p_reason) → void          [INTERNAL]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE ONLY WRITER of `estate_lifecycle`, and the transition map is written out as the closed set
-- it is. Eight legal moves since 11-E:
--
--     active                      → death_verification_pending   (case initiated)
--     death_verification_pending  → active                       (case rejected / cancelled)
--     death_verification_pending  → death_verified               (admin decision, attained ≥ required)
--     death_verified              → challenge_window             (window opened, owner notified — 11-E)
--     death_verification_pending  → challenge_halted             (owner challenge — 11-E)
--     death_verified              → challenge_halted             (owner challenge — 11-E)
--     challenge_window            → challenge_halted             (owner challenge — 11-E)
--     challenge_window            → released                     (window elapsed, release_estate — 11-E)
--
-- Everything else raises. Two absences are the load-bearing half of the 11-E map:
--
--   · NOTHING LEAVES challenge_halted. The owner said no; there is no resume, no admin override,
--     no reopen — restoring one is a future product decision, not a bigger map (R: 11-E brief §7).
--   · NOTHING LEAVES released. Disclosure cannot be undone (R15); a post-release freeze would be a
--     new product surface, not an edge here.
--
-- And `released` is REACHABLE only through `release_estate` (client-revoked, no caller in 11-E),
-- which alone checks the window guards before asking for this edge.
--
-- ★ TRANSACTIONAL + AUDITED (the 11-A §7 requirement): the current row is locked, the move is
-- validated against it, and one audit row records from/to/case/reason with the acting user.
create or replace function public.apply_estate_lifecycle_transition(
  p_estate uuid,
  p_to     text,
  p_case   uuid,
  p_reason text
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_from text;
begin
  select l.state into v_from
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;
  if v_from is null then
    v_from := 'active';
  end if;

  -- The closed map. An unknown current state is unreachable (table CHECK) but still refused here:
  -- unknown state fails closed, it is never a wildcard. challenge_halted and released have NO
  -- outbound edges, deliberately (see the header).
  if not (
       (v_from = 'active'                     and p_to = 'death_verification_pending')
    or (v_from = 'death_verification_pending' and p_to = 'active')
    or (v_from = 'death_verification_pending' and p_to = 'death_verified')
    or (v_from = 'death_verified'             and p_to = 'challenge_window')
    or (v_from = 'death_verification_pending' and p_to = 'challenge_halted')
    or (v_from = 'death_verified'             and p_to = 'challenge_halted')
    or (v_from = 'challenge_window'           and p_to = 'challenge_halted')
    or (v_from = 'challenge_window'           and p_to = 'released')
  ) then
    raise exception 'invalid_lifecycle_transition' using errcode = 'P0001';
  end if;

  insert into public.estate_lifecycle (estate_id, state, updated_at, updated_case_id)
  values (p_estate, p_to, now(), p_case)
  on conflict (estate_id) do update
    set state = excluded.state,
        updated_at = excluded.updated_at,
        updated_case_id = excluded.updated_case_id;

  perform public.write_audit(
    'estate_lifecycle.transition', 'estate_lifecycle', p_case, p_estate,
    jsonb_build_object('from_state', v_from, 'to_state', p_to,
                       'case_id', p_case, 'reason', p_reason));
end $function$;
revoke execute on function public.apply_estate_lifecycle_transition(uuid, text, uuid, text)
  from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- initiate_death_verification_case(p_estate) → uuid                        [authenticated, gated]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ D2: initiation is DESIGNEE-ONLY — the same canonical fiduciary predicate that gates claim
-- submission (`is_estate_executor`: an ACTIVE executor or trustee designation). Membership roles,
-- disclosure tiers, professional_delegate status, and estate ownership neither qualify nor
-- disqualify: an owner without a designation is refused like any non-designee, and an owner who
-- holds one passes by the designation, exactly as `submit_claim_packet` has always answered.
--
-- ★ THE GATE RUNS BEFORE ANY EXISTENCE LOOKUP. `is_estate_executor` returns false for a
-- nonexistent estate and for a foreign one alike, so both refuse with the same bytes.
create or replace function public.initiate_death_verification_case(p_estate uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid          uuid := auth.uid();
  v_designation  uuid;
  v_capacity     text;
  v_state        text;
  v_juris        text;
  v_required     public.verification_level;
  v_case         uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_executor(p_estate, v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- The designation that authorizes this initiation, captured as fact on the case. Deterministic
  -- when the caller holds both capacities: 'executor' precedes 'trustee' (current product
  -- semantics rank them identically for initiation; the recorded capacity is a fact, not a power).
  select d.id, d.designation_type
    into v_designation, v_capacity
    from public.estate_designations d
   where d.estate_id = p_estate
     and d.user_id = v_uid
     and d.designation_type in ('executor', 'trustee')
     and d.status = 'active'
   order by d.designation_type
   limit 1;

  -- One live death-verification process per estate. An open case holds the lifecycle at
  -- death_verification_pending; a verified case holds it at death_verified. Both refuse a new
  -- initiation. Only an authorized designee can reach this sentinel, so it is not an oracle.
  v_state := public.estate_lifecycle_state(p_estate);
  if v_state <> 'active' then
    raise exception 'lifecycle_conflict' using errcode = 'P0001';
  end if;

  select e.jurisdiction into v_juris from public.estates e where e.id = p_estate;

  -- The policy engine's answer AT INITIATION, recorded on the case. Fail-closed inside the engine:
  -- unknown / unapproved / NULL jurisdiction answers 'enhanced_kyc'. NEVER copied into attained.
  v_required := public.required_verification_level(p_estate);

  insert into public.death_verification_cases
    (estate_id, event_type, status, initiated_by, initiator_designation_id, initiator_capacity,
     jurisdiction_context, required_level_at_initiation)
  values
    (p_estate, 'death', 'open', v_uid, v_designation, v_capacity, v_juris, v_required)
  returning id into v_case;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'death_verification_pending', v_case, 'case_initiated');

  perform public.write_audit(
    'death_case.initiated', 'death_verification_cases', v_case, p_estate,
    jsonb_build_object('case_id', v_case, 'event_type', 'death',
                       'initiator_capacity', v_capacity,
                       'required_level_at_initiation', v_required::text,
                       'jurisdiction_known', v_juris is not null));
  return v_case;
end $function$;
revoke execute on function public.initiate_death_verification_case(uuid) from public, anon;
grant  execute on function public.initiate_death_verification_case(uuid) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- attach_death_verification_evidence(p_case, p_document) → uuid            [authenticated, gated]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- Records that a document was RECEIVED as evidence for a case. It does not review, grade, or
-- verify anything, and it touches no verification level — a thousand attachments leave the
-- attained level exactly where it was (brief §13: file upload ≠ document verification).
--
-- The document must belong to the case's estate — the multi-source-agreement rule from
-- `submit_claim_with_evidence`, one join shorter. A document in another estate and a document that
-- does not exist refuse identically.
create or replace function public.attach_death_verification_evidence(p_case uuid, p_document uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid        uuid := auth.uid();
  v_estate     uuid;
  v_status     text;
  v_doc_estate uuid;
  v_evidence   uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;

  select c.estate_id, c.status into v_estate, v_status
    from public.death_verification_cases c
   where c.id = p_case;
  -- Nonexistent case and foreign case answer with the same bytes: the caller learns nothing about
  -- whether a case exists anywhere they are not a designee.
  if v_estate is null or not public.is_estate_executor(v_estate, v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  if v_status <> 'open' then
    raise exception 'case_not_open' using errcode = 'P0001';
  end if;

  select d.estate_id into v_doc_estate from public.documents d where d.id = p_document;
  -- One sentinel for missing and foreign alike: a designee cannot probe the document space of
  -- other estates through attachment errors.
  if v_doc_estate is null or v_doc_estate <> v_estate then
    raise exception 'doc_not_in_estate' using errcode = 'P0001';
  end if;

  insert into public.death_verification_evidence (case_id, estate_id, document_id, submitted_by)
  values (p_case, v_estate, p_document, v_uid)
  returning id into v_evidence;

  perform public.write_audit(
    'death_case.evidence_attached', 'death_verification_evidence', v_evidence, v_estate,
    jsonb_build_object('case_id', p_case, 'evidence_id', v_evidence, 'document_id', p_document));
  return v_evidence;
end $function$;
revoke execute on function public.attach_death_verification_evidence(uuid, uuid) from public, anon;
grant  execute on function public.attach_death_verification_evidence(uuid, uuid) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- cancel_death_verification_case(p_case) → text                            [authenticated, gated]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- The initiator may withdraw an OPEN case — and only while they still hold an active designation:
-- a revoked fiduciary does not keep acting because a case remembers them. Cancellation returns the
-- lifecycle to `active`; the case row survives as history.
create or replace function public.cancel_death_verification_case(p_case uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid          uuid := auth.uid();
  v_estate       uuid;
  v_status       text;
  v_initiated_by uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;

  select c.estate_id, c.status, c.initiated_by
    into v_estate, v_status, v_initiated_by
    from public.death_verification_cases c
   where c.id = p_case
   for update;
  if v_estate is null
     or v_initiated_by <> v_uid
     or not public.is_estate_executor(v_estate, v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  if v_status = 'cancelled' then
    return v_status; -- idempotent replay: no re-stamp, no re-audit (the claim-decision precedent)
  end if;
  if v_status <> 'open' then
    raise exception 'case_already_decided' using errcode = 'P0001';
  end if;

  update public.death_verification_cases
     set status = 'cancelled', updated_at = now()
   where id = p_case;

  perform public.apply_estate_lifecycle_transition(v_estate, 'active', p_case, 'case_cancelled');

  perform public.write_audit(
    'death_case.cancelled', 'death_verification_cases', p_case, v_estate,
    jsonb_build_object('case_id', p_case));
  return 'cancelled';
end $function$;
revoke execute on function public.cancel_death_verification_case(uuid) from public, anon;
grant  execute on function public.cancel_death_verification_case(uuid) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- admin_review_death_evidence(p_evidence, p_outcome, p_note) → text            [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- Records the platform's review of one received evidence item. The outcome vocabulary says what
-- happened — a reviewer accepted or rejected the item — never that a document is authentic (no
-- vendor exists to say so). Reviewing evidence DOES NOT move the attained level: that is a
-- separate, separately-audited act, so "the file looked right" can never silently become "the
-- death is verified" (T15).
create or replace function public.admin_review_death_evidence(
  p_evidence uuid,
  p_outcome  text,
  p_note     text default null
)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid     uuid;
  v_case    uuid;
  v_estate  uuid;
  v_status  text;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_outcome not in ('reviewed_accepted', 'reviewed_rejected') then
    raise exception 'invalid_review_outcome' using errcode = 'P0001';
  end if;

  select e.case_id, e.estate_id, e.review_status
    into v_case, v_estate, v_status
    from public.death_verification_evidence e
   where e.id = p_evidence
   for update;
  if v_case is null then
    raise exception 'evidence_not_found' using errcode = 'P0002';
  end if;

  if v_status = p_outcome then
    return v_status; -- idempotent replay: no re-stamp, no re-audit
  end if;
  if v_status <> 'received' then
    raise exception 'evidence_already_reviewed' using errcode = 'P0001';
  end if;

  update public.death_verification_evidence
     set review_status = p_outcome, reviewed_by = v_uid, reviewed_at = now(), review_note = p_note
   where id = p_evidence;

  -- Direct insert, source='admin', severity high — the admin_decide_claim_packet precedent.
  -- Metadata names ids and the outcome; never document contents, titles, or claimant identity.
  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, v_estate, 'death_case.evidence_reviewed', 'death_verification_evidence', p_evidence,
          jsonb_build_object('severity', 'high', 'case_id', v_case,
                            'evidence_id', p_evidence, 'outcome', p_outcome),
          'admin');
  return p_outcome;
end $function$;
revoke execute on function public.admin_review_death_evidence(uuid, text, text) from public, anon;
grant  execute on function public.admin_review_death_evidence(uuid, text, text) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- admin_set_attained_verification_level(p_case, p_level, p_basis) → text       [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE ONLY WRITER of `attained_level`. The parameter is TYPED to the policy engine's enum, so an
-- out-of-vocabulary level is unrepresentable at the call boundary — it fails Postgres enum
-- decoding before this body runs, and there is no text path around it. NULL is refused: attained
-- never returns to "unknown" by assertion; it starts there and moves only by this audited act.
--
-- Nothing here compares the level to the requirement — attainment is a fact, sufficiency is the
-- DECISION routine's question. And nothing here derives a level from evidence counts: a reviewer
-- states what the review process actually established, with the basis recorded.
create or replace function public.admin_set_attained_verification_level(
  p_case  uuid,
  p_level public.verification_level,
  p_basis text default null
)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid    uuid;
  v_estate uuid;
  v_status text;
  v_old    public.verification_level;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_level is null then
    raise exception 'invalid_verification_level' using errcode = 'P0001';
  end if;

  select c.estate_id, c.status, c.attained_level
    into v_estate, v_status, v_old
    from public.death_verification_cases c
   where c.id = p_case
   for update;
  if v_estate is null then
    raise exception 'case_not_found' using errcode = 'P0002';
  end if;
  if v_status <> 'open' then
    raise exception 'case_not_open' using errcode = 'P0001';
  end if;

  if v_old is not distinct from p_level then
    return p_level::text; -- idempotent replay: no re-stamp, no re-audit
  end if;

  update public.death_verification_cases
     set attained_level = p_level, updated_at = now()
   where id = p_case;

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, v_estate, 'death_case.attained_level_set', 'death_verification_cases', p_case,
          jsonb_build_object('severity', 'high', 'case_id', p_case,
                            'old_level', v_old::text, 'new_level', p_level::text,
                            'basis', p_basis),
          'admin');
  return p_level::text;
end $function$;
revoke execute on function public.admin_set_attained_verification_level(uuid, public.verification_level, text)
  from public, anon;
grant  execute on function public.admin_set_attained_verification_level(uuid, public.verification_level, text)
  to authenticated;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- admin_decide_death_verification_case(p_case, p_decision, p_note) → text      [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ H2 CLOSED HERE: `verify` refuses unless attained ≥ required, with the requirement RE-DERIVED
-- LIVE from the policy engine at decision time — the initiation snapshot is a record, not the
-- gate. A NULL attained level coalesces to refusal (the three-valued-logic trap, handled the way
-- `release_condition_satisfied` handles it).
--
-- ★ VERIFYING A DEATH RELEASES NOTHING. The lifecycle moves to `death_verified` and that is the
-- entire effect: no grant goes live (`release_condition_satisfied` takes no lifecycle state, and
-- `after_verified_death` satisfies nothing under any policy), no notification is emitted, no
-- claim row changes, no read path consults the new state. The 11-C suite compares every viewer's
-- composed payload across this transition and requires byte identity.
create or replace function public.admin_decide_death_verification_case(
  p_case     uuid,
  p_decision text,
  p_note     text default null
)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid      uuid;
  v_estate   uuid;
  v_status   text;
  v_attained public.verification_level;
  v_required public.verification_level;
  v_target   text;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_decision not in ('verify', 'reject') then
    raise exception 'invalid_decision' using errcode = 'P0001';
  end if;
  v_target := case p_decision when 'verify' then 'verified' else 'rejected' end;

  select c.estate_id, c.status, c.attained_level
    into v_estate, v_status, v_attained
    from public.death_verification_cases c
   where c.id = p_case
   for update;
  if v_estate is null then
    raise exception 'case_not_found' using errcode = 'P0002';
  end if;

  if v_status = v_target then
    return v_status; -- idempotent replay: no re-stamp, no re-audit
  end if;
  if v_status <> 'open' then
    raise exception 'case_already_decided' using errcode = 'P0001';
  end if;

  if p_decision = 'verify' then
    -- LIVE requirement, not the snapshot: a policy tightened mid-case tightens the case.
    v_required := public.required_verification_level(v_estate);
    if not coalesce(v_attained >= v_required, false) then
      raise exception 'verification_level_insufficient' using errcode = 'P0001';
    end if;
  end if;

  update public.death_verification_cases
     set status = v_target, decided_by = v_uid, decided_at = now(),
         decision_note = p_note, updated_at = now()
   where id = p_case;

  perform public.apply_estate_lifecycle_transition(
    v_estate,
    case when p_decision = 'verify' then 'death_verified' else 'active' end,
    p_case,
    'case_' || v_target);

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, v_estate, 'death_case.' || v_target, 'death_verification_cases', p_case,
          jsonb_build_object('severity', 'high', 'case_id', p_case, 'decision', p_decision,
                            'required_level', v_required::text, 'attained_level', v_attained::text,
                            'reviewer_id', v_uid),
          'admin');
  return v_target;
end $function$;
revoke execute on function public.admin_decide_death_verification_case(uuid, text, text) from public, anon;
grant  execute on function public.admin_decide_death_verification_case(uuid, text, text) to authenticated;
