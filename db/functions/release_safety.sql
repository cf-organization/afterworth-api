-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-E · RELEASE SAFETY — the challenge window between death_verified and released
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THIS FILE OWNS. The three transitions that stand between an accepted death verification
-- and irreversible disclosure, plus the owner-facing status read:
--
--   begin_challenge_window   death_verified → challenge_window     [admin, AAL2+fresh]
--   challenge_death_process  any pre-released death-process state
--                            → challenge_halted                    [the authenticated OWNER, alone]
--   release_estate           challenge_window → released           [INTERNAL — no reachable door]
--   get_owner_safety_status  owner-scoped presentation union       [authenticated, owner-gated]
--
-- ★ WHAT THIS FILE MUST NEVER TOUCH: access_grants, visibility tiers, memberships, designations,
-- documents, claim rows, or the release predicate. Release is EVALUATIVE — the lifecycle moves and
-- the one canonical predicate answers differently. `test/deathVerificationFoundation.test.ts`
-- pins the forbidden set for this file exactly as it does for the death-verification module.
--
-- ★ THE SAFETY NOTIFICATION IS LOAD-BEARING, AND THE EMITTER'S USUAL TRADE IS INVERTED HERE.
-- `emit_lifecycle_notification` deliberately swallows insert failure so that a grant still commits
-- when a heads-up cannot be written — the right trade for a heads-up. The window-open notice is
-- not a heads-up: it is the owner's one chance to object before disclosure becomes irreversible,
-- so `begin_challenge_window` REQUIRES the emit to return a committed row id and rolls the whole
-- transition back otherwise. The window cannot begin un-notified. (Reliability class, stated
-- honestly: one in-app notification row, committed in the SAME transaction as the transition.
-- Whether that class is sufficient to start a release clock in production is part of the window-
-- duration product decision; until an operator configures a duration, no window can elapse.)
--
-- ★ THE TIEBREAK IS STRUCTURAL (R14). Release requires the window STRICTLY elapsed:
-- `now() > owner_notified_at + duration`. At the exact boundary instant the release refuses while
-- the challenge still succeeds; both serialize on the lifecycle row lock; and the transition map
-- has no edge out of challenge_halted, so a committed challenge is final in 11-E — no resume, no
-- admin override (R: deliberately absent, a future product decision).
--
-- ★ CHALLENGE PROVENANCE IS PROTECTED (§17). The audit row records THAT the owner challenged and
-- from which lifecycle state — never a channel, device, address, or location. `write_audit` does
-- not populate ip/user_agent, and nothing here adds them. Claimant-facing surfaces may learn only
-- that the process halted.
--
-- Deploys via `db/bundles/death_verification_bundle.sql` (after 0054 and the workflow routines).
-- Source of truth — re-apply on DB reset.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- challenge_window_duration() → interval                        [INTERNAL — the configured window]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- NULL means NOT CONFIGURED, and not configured means the window never elapses (fail-closed:
-- release refuses, the challenge stays available). Read LIVE at release time — the H2 precedent:
-- a duration lengthened mid-window lengthens the window; there is no stamped deadline to go stale.
create or replace function public.challenge_window_duration()
 returns interval
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select p.challenge_window from public.release_safety_policy p where p.id;
$function$;
revoke execute on function public.challenge_window_duration() from public, anon, authenticated;

comment on function public.challenge_window_duration() is
  'The configured owner-challenge window (Phase 11-E). NULL = not configured = the window never '
  'elapses and release refuses. Set only by an explicit, reviewed operator INSERT into '
  'release_safety_policy — never seeded by a migration. INTERNAL: clients cannot read the safety '
  'clock; the owner surface answers through get_owner_safety_status.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- begin_challenge_window(p_estate) → text                                      [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- Opens the safety window on a death_verified estate: notifies the owner (same transaction,
-- REQUIRED — see the header) and moves the lifecycle. The same platform authority that decides a
-- verification case (admin_require_gate) opens the window; unlike release, this action is
-- safety-INCREASING — it starts the owner's clock and discloses nothing.
create or replace function public.begin_challenge_window(p_estate uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid    uuid;
  v_state  text;
  v_owner  uuid;
  v_case   uuid;
  v_notice uuid;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  select l.state into v_state
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;

  if v_state = 'challenge_window' then
    return 'challenge_window'; -- idempotent replay: no re-notify, no re-audit
  end if;
  if v_state is distinct from 'death_verified' then
    raise exception 'invalid_window_state' using errcode = 'P0001';
  end if;

  -- The verified case is the workflow evidence the window rests on (belt beside the state machine).
  select c.id into v_case
    from public.death_verification_cases c
   where c.estate_id = p_estate and c.status = 'verified'
   order by c.decided_at desc
   limit 1;
  if v_case is null then
    raise exception 'no_verified_case' using errcode = 'P0001';
  end if;

  v_owner := public.estate_owner_user_id(p_estate);
  if v_owner is null then
    raise exception 'owner_unresolved' using errcode = 'P0001';
  end if;

  -- ★ THE INVERTED TRADE: the safety notice must COMMIT or the window must not open. A null here
  -- means the emitter refused or failed; raising rolls back everything this routine did.
  v_notice := public.emit_lifecycle_notification(
    v_owner, p_estate, 'death_process.window_opened', 'afterworth://challenge');
  if v_notice is null then
    raise exception 'owner_notification_failed' using errcode = 'P0001';
  end if;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'challenge_window', v_case, 'window_opened');

  update public.estate_lifecycle
     set owner_notified_at = now(),
         challenge_window_started_at = now(),
         safety_notification_id = v_notice
   where estate_id = p_estate;

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, p_estate, 'death_process.window_opened', 'estate_lifecycle', v_case,
          jsonb_build_object('severity', 'high', 'case_id', v_case,
                            'safety_notification_id', v_notice),
          'admin');
  return 'challenge_window';
end $function$;
revoke execute on function public.begin_challenge_window(uuid) from public, anon;
grant  execute on function public.begin_challenge_window(uuid) to authenticated;

comment on function public.begin_challenge_window(uuid) is
  'Opens the owner-challenge window on a death_verified estate (Phase 11-E). Admin-gated '
  '(AAL2 + freshness). The owner safety notice is REQUIRED to commit in the same transaction — '
  'a window cannot begin un-notified. Idempotent. Discloses nothing; starts the safety clock.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- challenge_death_process(p_estate) → text                          [the authenticated OWNER only]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ R13 IS THE SIGNATURE: one argument, one action. No evidence parameter exists, no review step
-- exists, no waiting period exists, no designation is consulted. The authenticated owner of the
-- estate halts the process — from pending, from death_verified, or from inside the window — and
-- challenge_halted is terminal in 11-E: the map has no edge out, and no routine reopens it.
--
-- ★ THE GATE RUNS BEFORE ANY EXISTENCE OR STATE LOOKUP. `is_estate_owner` answers false for a
-- nonexistent estate and a foreign one alike, so every unauthorized caller — beneficiary,
-- designee, claimant, foreign owner, probe against a random uuid — refuses with the same bytes.
create or replace function public.challenge_death_process(p_estate uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid   uuid := auth.uid();
  v_state text;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select l.state into v_state
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;
  if v_state is null then
    v_state := 'active';
  end if;

  if v_state = 'challenge_halted' then
    return 'challenge_halted'; -- idempotent replay: no re-stamp, no re-audit
  end if;
  if v_state = 'active' then
    raise exception 'nothing_to_challenge' using errcode = 'P0001';
  end if;
  -- Too late is stated honestly (R15): what was disclosed cannot be undisclosed, and pretending
  -- a halt succeeded would claim otherwise. The owner is authorized to know this about their
  -- own estate.
  if v_state = 'released' then
    raise exception 'already_released' using errcode = 'P0001';
  end if;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'challenge_halted', null, 'owner_challenge');

  update public.estate_lifecycle
     set halted_at = now()
   where estate_id = p_estate;

  -- Any open case is halted — distinct from 'cancelled' (initiator withdrew): the owner said no.
  update public.death_verification_cases
     set status = 'halted', updated_at = now()
   where estate_id = p_estate and status = 'open';

  -- ★ NO PROVENANCE. The fact recorded is THAT the owner challenged and from which state — never
  -- a channel, a device, an address, or a location (§17: provenance is security-sensitive
  -- information about a living owner).
  perform public.write_audit(
    'death_process.challenged', 'estate_lifecycle', null, p_estate,
    jsonb_build_object('severity', 'high', 'from_state', v_state));
  return 'challenge_halted';
end $function$;
revoke execute on function public.challenge_death_process(uuid) from public, anon;
grant  execute on function public.challenge_death_process(uuid) to authenticated;

comment on function public.challenge_death_process(uuid) is
  'The owner challenge (Phase 11-E, R12-R14): the authenticated estate owner halts a pre-released '
  'death process in one action — no evidence, no review, no waiting, no designation. Wins ties '
  '(release requires the window strictly elapsed; both serialize on the lifecycle row lock). '
  'Produces challenge_halted, terminal in 11-E. Records no provenance beyond the act itself.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- release_estate(p_estate) → text            [INTERNAL — no client role, no reachable door in 11-E]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE ACTOR IS DELIBERATELY UNWIRED. Who may pull this lever — a single admin, a two-person
-- rule, an automated elapse job — is a product decision (11-A threat model T5) that 11-E does not
-- own. The routine exists so the guards are real and testable; EXECUTE is revoked from every
-- client role and no routine calls it. Wiring an actor is the named 11-F decision, and the drift
-- verifier reports this function's privilege posture so a quiet future GRANT is loud.
create or replace function public.release_estate(p_estate uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_row      public.estate_lifecycle%rowtype;
  v_case     uuid;
  v_duration interval;
begin
  select l.* into v_row
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;

  if v_row.state = 'released' then
    return 'released'; -- idempotent replay: no re-stamp, no re-audit
  end if;
  if v_row.state is distinct from 'challenge_window' then
    -- challenge_halted lands here too: release can NEVER proceed from a halted process.
    raise exception 'invalid_release_state' using errcode = 'P0001';
  end if;

  -- The window rests on a committed safety notice and a verified case — facts, re-checked.
  if v_row.owner_notified_at is null or v_row.safety_notification_id is null then
    raise exception 'owner_not_notified' using errcode = 'P0001';
  end if;
  select c.id into v_case
    from public.death_verification_cases c
   where c.estate_id = p_estate and c.status = 'verified'
   order by c.decided_at desc
   limit 1;
  if v_case is null then
    raise exception 'no_verified_case' using errcode = 'P0001';
  end if;

  -- The duration is read LIVE (H2 precedent). Unconfigured = the window never elapses.
  v_duration := public.challenge_window_duration();
  if v_duration is null then
    raise exception 'release_window_not_configured' using errcode = 'P0001';
  end if;

  -- ★ STRICTLY ELAPSED (R14). At the exact boundary instant (`now() = notified + duration`) this
  -- refuses — and the owner challenge, serialized on the same row lock, still succeeds. The
  -- coalesce is the three-valued-logic discipline: a NULL comparison must refuse, not pass.
  if not coalesce(now() > v_row.owner_notified_at + v_duration, false) then
    raise exception 'release_window_not_elapsed' using errcode = 'P0001';
  end if;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'released', v_case, 'window_elapsed');

  update public.estate_lifecycle
     set released_at = now()
   where estate_id = p_estate;

  perform public.write_audit(
    'death_process.released', 'estate_lifecycle', v_case, p_estate,
    jsonb_build_object('severity', 'high', 'case_id', v_case,
                       'owner_notified_at', v_row.owner_notified_at,
                       'window_started_at', v_row.challenge_window_started_at,
                       'window_duration', v_duration::text));
  return 'released';
end $function$;
revoke execute on function public.release_estate(uuid) from public, anon, authenticated;

comment on function public.release_estate(uuid) is
  'THE release transition (Phase 11-E): challenge_window -> released, only when the owner was '
  'notified (committed safety notice), a verified case exists, the configured window has STRICTLY '
  'elapsed (ties refuse - the owner challenge wins them, R14), and no challenge halted the process '
  '(the map has no edge from challenge_halted). Idempotent, audited. INTERNAL: EXECUTE revoked '
  'from every client role and called by nothing - the release ACTOR is an explicitly deferred '
  'product decision (11-F), so in 11-E released is unreachable in any deployed environment.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- get_owner_safety_status(p_estate) → text                          [authenticated, owner-gated]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- The owner-facing presentation of their own estate's safety state — a CLOSED four-value union,
-- deliberately coarser than the lifecycle: the owner surface needs "is there something to halt",
-- never the machine's internals. An owner is authorized to know this about their own estate; no
-- one else may ask (same byte-identical refusal discipline as the challenge).
--
--   none          nothing to challenge (no death process, or it concluded without release)
--   challengeable a death process is underway and the owner may halt it
--   halted        the owner (or a prior challenge) halted the process
--   released      the process completed; the owner arrived too late to halt (stated honestly)
create or replace function public.get_owner_safety_status(p_estate uuid)
 returns text
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare
  v_uid   uuid := auth.uid();
  v_state text;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  v_state := public.estate_lifecycle_state(p_estate);
  return case v_state
    when 'death_verification_pending' then 'challengeable'
    when 'death_verified'             then 'challengeable'
    when 'challenge_window'           then 'challengeable'
    when 'challenge_halted'           then 'halted'
    when 'released'                   then 'released'
    else 'none'
  end;
end $function$;
revoke execute on function public.get_owner_safety_status(uuid) from public, anon;
grant  execute on function public.get_owner_safety_status(uuid) to authenticated;

comment on function public.get_owner_safety_status(uuid) is
  'Owner-scoped safety status (Phase 11-E): a closed presentation union (none / challengeable / '
  'halted / released) over the authoritative lifecycle, for the challenge surface. Owner-only; '
  'every other caller refuses byte-identically. Not an authorization and not a disclosure: it '
  'answers about the process, never about estate content.';
