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
-- ★ THE TIEBREAK IS STRUCTURAL (R14). Release requires the window STRICTLY elapsed. At the exact
-- boundary instant the release refuses while the challenge still succeeds; both serialize on the
-- lifecycle row lock; and the transition map has no edge out of challenge_halted, so a committed
-- challenge is final in 11-E — no resume, no admin override (R: deliberately absent, a future
-- product decision).
--
-- ★ PHASE 11-OC / PHASE D MOVED THE ANCHOR THAT THE STRICTNESS APPLIES TO, AND NOTHING ELSE ABOUT
-- IT. The comparison was `now() > owner_notified_at + duration`; it is now
-- `now() > notice_accepted_at + duration`, decided by `owner_notice_release_authority` below.
-- `owner_notified_at` is stamped when the email row is QUEUED, so the seven days used to run while
-- the message sat unsent and kept running when the provider rejected it outright. The seven-day
-- POLICY is unchanged — `challenge_window_duration()` is untouched — only the instant it counts
-- from. There is deliberately no fallback from acceptance to provenance: a coalesce would silently
-- restore the defective clock for exactly the legacy population Phase D exists to refuse.
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
-- dispatch_owner_safety_notice(p_estate) → text                               [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ PHASE 11-F, D4 — "the owner was told" MUST mean an independently reachable channel. 11-E wrote
-- one in-app notification and required it to commit; that is a real guarantee and it is not enough,
-- because a person who has stopped opening the app is exactly the person a false death process
-- targets successfully. This routine additionally commits an EMAIL row addressed to the owner, in
-- the SAME transaction as the state change, and refuses the whole transition if it cannot.
--
-- ★ THE REQUIREMENT IS DISPATCH INITIATION, NOT DELIVERY (Stage 2, stated exactly). No read
-- receipt, no open tracking, no acknowledgement — none of which this product can honestly observe,
-- and each of which would let a silent mail server hold a release hostage forever. What IS required
-- is that a real address was resolved and a real row was committed to a real queue.
--
-- ★ AND AN UNRESOLVABLE ADDRESS IS A HARD FAILURE. Queueing a row with no recipient would be
-- "dispatch initiated" in name only — the fail-closed answer is to refuse the transition, leaving
-- the estate at `death_verified` where nothing can release, rather than starting a clock nobody can
-- hear ticking.
--
-- ★ D2 — `owner_notified_at` IS STAMPED HERE, AND SINCE PHASE 11-OC / PHASE D IT IS PROVENANCE
-- RATHER THAN THE RELEASE CLOCK. It records the instant the operator initiated dispatch — not claim
-- creation, evidence upload, verification or administrative review, none of which the owner can see
-- — and that remains the right fact for this row to carry. What it is NOT is proof that a message
-- left the building: it is written when the outbox row is QUEUED, before any worker has run. The
-- seven days now run from `notice_accepted_at` on the accepted notice; see
-- `owner_notice_release_authority`. This routine is unchanged by Phase D.
create or replace function public.dispatch_owner_safety_notice(p_estate uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid       uuid;
  v_state     text;
  v_owner     uuid;
  v_recipient text;
  v_case      uuid;
  v_notice    uuid;
  v_outbox    uuid;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  select l.state into v_state
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;

  if v_state = 'owner_notification_dispatched' then
    return 'owner_notification_dispatched'; -- idempotent replay: no re-dispatch, no re-audit
  end if;
  if v_state is distinct from 'death_verified' then
    raise exception 'invalid_dispatch_state' using errcode = 'P0001';
  end if;

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

  -- ★ THE INDEPENDENT CHANNEL, RESOLVED FROM THE IDENTITY PROVIDER rather than from anything a
  -- claimant can write. `profiles.email` is user-editable in principle; `auth.users.email` is the
  -- address the account authenticates with, which is the one a claimant cannot repoint.
  select u.email into v_recipient from auth.users u where u.id = v_owner;
  if v_recipient is null or btrim(v_recipient) = '' then
    raise exception 'owner_channel_unreachable' using errcode = 'P0001';
  end if;

  -- EMAIL FIRST: the row whose existence is the dispatch. Same transaction as the transition, so a
  -- rollback anywhere below un-dispatches it and the window never opened.
  -- ★ PHASE 11-OC — THE ROW NAMES ITS EPISODE, AND `v_case` WAS ALREADY IN HAND.
  --
  -- `v_case` is resolved above and, until this phase, was discarded into the audit metadata only. It
  -- is the EPISODE key: one estate may legitimately experience several independent death processes
  -- over time (`rejected` and `cancelled` both return the lifecycle to `active`), so an accepted
  -- notice from a prior, rejected process must never authorize a release under a later case. Scoping
  -- the release predicate to the estate would do exactly that; scoping it to the case cannot.
  --
  -- `generation` is the literal 1 here and only ever incremented by the re-notice routine, under the
  -- predecessor's row lock — never from an unlocked max().
  --
  -- A BEFORE INSERT trigger (migration 0058) refuses any owner-notice row with a NULL case_id, so
  -- this is a wall rather than a promise this routine makes. Legacy rows keep their NULL and stay
  -- updatable, because the trigger fires on INSERT only.
  insert into public.owner_notice_outbox
    (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation)
  values (p_estate, v_owner, 'email', v_recipient, 'death_process.window_opened', 'queued',
          v_case, 1)
  returning id into v_outbox;
  if v_outbox is null then
    raise exception 'owner_notification_failed' using errcode = 'P0001';
  end if;

  -- IN-APP SECOND, and still REQUIRED (11-E's guarantee is kept, not replaced). Two channels, both
  -- committed, before any clock starts.
  v_notice := public.emit_lifecycle_notification(
    v_owner, p_estate, 'death_process.window_opened', 'afterworth://challenge');
  if v_notice is null then
    raise exception 'owner_notification_failed' using errcode = 'P0001';
  end if;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'owner_notification_dispatched', v_case, 'owner_notice_dispatched');

  update public.estate_lifecycle
     set owner_notified_at = now(),
         safety_notification_id = v_notice
   where estate_id = p_estate;

  -- ★ THE AUDIT RECORDS THE CHANNEL CLASS, NEVER THE ADDRESS. That a notice went to email is an
  -- operational fact; WHICH address is a living owner's contact detail, and an audit row outlives
  -- every reason anyone had to read it.
  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, p_estate, 'death_process.owner_notice_dispatched', 'owner_notice_outbox', v_outbox,
          jsonb_build_object('severity', 'high', 'case_id', v_case, 'channel', 'email',
                            'in_app_notification_id', v_notice),
          'admin');
  return 'owner_notification_dispatched';
end $function$;
revoke execute on function public.dispatch_owner_safety_notice(uuid) from public, anon;
grant  execute on function public.dispatch_owner_safety_notice(uuid) to authenticated;

comment on function public.dispatch_owner_safety_notice(uuid) is
  'Phase 11-F (D4): commits an EMAIL row and an in-app notice to the owner, in the same transaction '
  'as the death_verified -> owner_notification_dispatched transition, and stamps owner_notified_at '
  '(D2: the challenge clock starts at dispatch). Requires dispatch INITIATION, never delivery '
  'confirmation. An unresolvable owner address refuses the transition. Admin-gated; idempotent.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- owner_notice_release_authority(p_case) → jsonb                                       [INTERNAL]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ PHASE 11-OC · PHASE D — THE ONE PLACE THE RELEASE DOOR'S OWNER-NOTICE AUTHORITY IS DECIDED.
--
-- Before this phase, `authorize_release` asked TWO questions in two places and got the wrong answer
-- to both. It asked "does an email row exist for this ESTATE with `status <> 'cancelled'`" — a
-- predicate nothing in production can falsify, because `dispatch_owner_safety_notice` inserts that
-- row in the same transaction as the transition and no production path ever writes `'cancelled'`.
-- And it measured the seven days from `owner_notified_at`, which is stamped when the row is QUEUED:
-- the clock ran while the message sat unsent, and kept running when the provider rejected it.
--
-- Phase D replaces both with ONE fact the database can actually prove:
--
--        THE CURRENT GENERATION OF THE CURRENT CASE EPISODE HAS `notice_accepted_at`.
--
-- ★ WHAT THAT FACT IS, AND WHAT IT IS NOT — stated here because this is the last place anybody
-- reads before trusting it. `notice_accepted_at` is stamped by exactly one branch of exactly one
-- routine (`record_owner_notice_outcome`, `providerAccepted`). It means the EMAIL PROVIDER ACCEPTED
-- THE MESSAGE FOR DELIVERY. It is **not** delivered, not received, not opened, not read, and no
-- caller, projection, console label or document may rename it into any of those. It is the
-- strongest persisted provider fact this system currently has, and Phase D protects on that rather
-- than on a weaker one — never on a stronger one it cannot observe.
--
-- ★ IT IS A SEPARATE FUNCTION FOR THE `owner_notice_reissue_assessment` REASON, WHICH IS NOT
-- TIDINESS. Three callers need this verdict: the release door, the operator case file, and the
-- deployment verifier. A second opinion in any of them — a status list in a projection, a `case`
-- expression in the case file, a TypeScript mirror in the console — is a policy that drifts, and
-- the failure mode is an operator being offered a release the server refuses, or (far worse) a
-- console that says READY while the door's own rule says otherwise. So the door and the projection
-- call the SAME function, and `db/tests/release_safety_authorization.sql` §12 asserts they agree on
-- every fixture rather than assuming they must.
--
-- ★ FOUR INDEPENDENT AUTHORITIES, AND EVERY ONE OF THEM MUST HOLD.
--
--   1. EPISODE  — the notice must belong to the CURRENT death-verification case (D3). One estate may
--                 legitimately run several death processes over time: `rejected` and `cancelled`
--                 both return the lifecycle to `active`, and a later case opens a new episode. An
--                 accepted notice from a PRIOR, REJECTED process authorizing a release under a NEW
--                 case is the estate-scope defect this whole phase exists to close. The canonical
--                 case is re-resolved HERE from the estate and the caller's `p_case` is compared
--                 against it — never trusted as the episode.
--
--   2. GENERATION — the notice must be the STRUCTURALLY current generation (D4): the row nothing
--                 supersedes. `superseded_by is null`, which is a partial-unique-indexed wall, not
--                 `max(generation)`, not `max(requested_at)`, not "the newest timestamp", not array
--                 order. A derived-max invariant cannot be expressed as a constraint, so a door
--                 resting on one rests on an invariant only the writer maintains.
--
--   3. ACCEPTANCE — `notice_accepted_at is not null` on that row (D1). NOT `status = 'dispatched'`,
--                 NOT `status <> 'cancelled'`, NOT a status allow-list of any shape. The authority
--                 is VOCABULARY-INDEPENDENT on purpose: a seventh status added to the CHECK
--                 constraint tomorrow must not become release-qualifying merely by not being
--                 `'cancelled'`, and it cannot, because no status string appears in this decision.
--
--   4. CLOCK   — `now() > notice_accepted_at + challenge_window_duration()`, STRICTLY (D5). At the
--                 exact boundary instant this refuses and the owner's challenge — serialized on the
--                 same lifecycle row lock — still succeeds. `owner_notified_at` is PROVENANCE and is
--                 never the anchor; there is deliberately no `coalesce` from one to the other,
--                 because a fallback would silently restore the defective clock for exactly the
--                 legacy population Phase D exists to refuse.
--
-- ★ CURRENT-GENERATION-ONLY AND EPISODE-EXISTENTIAL AGREE ON EVERY REACHABLE STATE, AND THAT WAS
-- PROVEN BY READING THE SETTLE PATH RATHER THAN ASSUMED. `owner_notice_release_readiness_census`
-- reads acceptance as an existential over the whole episode, and argues — correctly — that
-- authority must be MONOTONE: if issuing a re-notice could REMOVE release authority, an operator
-- would hold a lever that suppresses a release. This function reads only the current generation,
-- which looks like it breaks that property. It does not, and the reason is structural:
--
--   · `record_owner_notice_outcome` no-ops on any row already `dispatched`, `outcomeUncertain`,
--     `failedPermanent` or `cancelled`, so a settled row can never gain an acceptance stamp.
--   · `owner_notice_reissue_assessment` permits a re-notice ONLY when the current generation is
--     `failedPermanent`, `outcomeUncertain`, or `dispatched` with NULL acceptance — all settled,
--     all NULL-acceptance at the instant of supersession. `queued` and `processing` (the only rows
--     that can still gain acceptance) are refused, so they are never superseded.
--
-- Therefore a superseded row carrying `notice_accepted_at` is UNREACHABLE through the deployed
-- doors, the two readings can differ only on a state the system cannot produce, and reading the
-- current generation costs no monotonicity. It is nevertheless read strictly, because D4 asks for
-- the structural invariant rather than for an argument that the loose one happens to be safe — and
-- §12 mutation-proves that a hand-written superseded acceptance authorizes NOTHING.
--
-- ★ IT FAILS CLOSED, AND EVERY REFUSAL HAS A NAME FROM A CLOSED SET. There is no fall-through: a
-- state this ladder does not recognise lands on an explicit code rather than joining a neighbouring
-- branch. `notice_never_accepted` is deliberately NOT called `notice_not_delivered` — mailbox
-- delivery is not known to this system and naming it would be the console inventing the one fact
-- this phase exists to stop being invented.
--
-- ★ IT DISCLOSES NO IDENTITY. No recipient address, no owner user id, no estate name, no provider
-- secret. Row ids, a generation number, two timestamps and a code — the facts an operator needs to
-- know whether a release call will be refused, and nothing that describes a living person.
create or replace function public.owner_notice_release_authority(p_case uuid)
 returns jsonb
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare
  v_c         public.death_verification_cases%rowtype;
  v_state     text;
  v_canonical uuid;
  v_row       public.owner_notice_outbox%rowtype;
  v_duration  interval;
  v_eligible  timestamptz;
  v_elapsed   boolean := false;
  v_refusal   text;
begin
  if p_case is null then
    return jsonb_build_object('ready', false, 'refusal_code', 'case_not_found',
                              'window_configured', false, 'elapsed', false);
  end if;

  select * into v_c from public.death_verification_cases c where c.id = p_case;
  if not found then
    return jsonb_build_object('ready', false, 'refusal_code', 'case_not_found',
                              'window_configured', false, 'elapsed', false);
  end if;

  -- AUTHORITY 1 · THE EPISODE. Resolved canonically from the ESTATE and compared against the
  -- caller's case — the identical derivation `authorize_release`, `dispatch_owner_safety_notice`,
  -- `owner_notice_reissue_assessment` and the readiness census all use. A caller cannot nominate an
  -- episode, so a historical case cannot be handed in as if it were current.
  select c.id into v_canonical
    from public.death_verification_cases c
   where c.estate_id = v_c.estate_id and c.status = 'verified'
   order by c.decided_at desc
   limit 1;

  select l.state into v_state from public.estate_lifecycle l where l.estate_id = v_c.estate_id;
  v_state := coalesce(v_state, 'active');

  -- AUTHORITY 2 · THE CURRENT GENERATION. Structural — `superseded_by is null` — never a max().
  -- The kind SET comes from `owner_notice_episode_kinds()` rather than a literal, for the reason
  -- Phase C gives: a literal here could not see a re-notice, so a remediated estate would be
  -- refused by the door that its remedy was built to unblock.
  select * into v_row
    from public.owner_notice_outbox o
   where o.case_id = p_case
     and o.channel = 'email'
     and o.notice_kind = any (public.owner_notice_episode_kinds())
     and o.superseded_by is null
   limit 1;

  v_duration := public.challenge_window_duration();

  -- AUTHORITY 4 · THE CLOCK, computed before the ladder so the projection can render the facts even
  -- on a branch that refuses. STRICT `>`; the coalesce is the three-valued-logic discipline — a NULL
  -- comparison must refuse, not pass.
  if v_row.notice_accepted_at is not null and v_duration is not null then
    v_eligible := v_row.notice_accepted_at + v_duration;
    v_elapsed  := coalesce(now() > v_eligible, false);
  end if;

  -- ── THE REFUSAL LADDER, IN THE ORDER THE DOOR APPLIES IT ─────────────────────────────────────
  if v_canonical is null then
    v_refusal := 'no_verified_case';
  elsif v_canonical <> p_case then
    -- A historical case on an estate that has moved on, or a case that was never verified. Either
    -- way the accepted notice it may carry authorizes NOTHING under the current process.
    v_refusal := 'notice_episode_mismatch';
  elsif v_state is distinct from 'challenge_window' then
    -- The release door's own state guard, restated here so the projection refuses for the same
    -- reason the routine will. `challenge_halted` lands here: release can never proceed from a halt.
    v_refusal := 'invalid_release_state';
  elsif v_row.id is null then
    -- No notice names this episode at all. Fail closed: an estate with no provable notice is not an
    -- estate whose owner was warned. Pre-Phase-A rows carry a NULL case_id and land here by design —
    -- they belong to no provable episode and are never guessed into one.
    v_refusal := 'no_current_notice';
  elsif v_row.notice_accepted_at is null then
    -- AUTHORITY 3 · THE LEGACY / UNSETTLED CLASS (D6). Covers every non-accepted shape at once and
    -- WITHOUT consulting a status string: `queued` (never sent), `processing` (never settled),
    -- `outcomeUncertain` (unknown), `failedPermanent` (definitively failed), `cancelled`, a
    -- pre-Phase-A `dispatched` row whose stamp did not exist, and any seventh status a future CHECK
    -- constraint admits. The remedy is a Phase C re-notice that PRODUCES the fact, never a backfill
    -- that invents one and never a manual UPDATE of a safety table.
    v_refusal := 'notice_never_accepted';
  elsif v_duration is null then
    -- NULL duration means NOT CONFIGURED, which means the window never elapses and release refuses.
    v_refusal := 'release_window_not_configured';
  elsif not v_elapsed then
    v_refusal := 'release_window_not_elapsed';
  end if;

  return jsonb_build_object(
    'ready',               v_refusal is null,
    'refusal_code',        v_refusal,
    'case_id',             p_case,
    'case_is_current',     v_canonical is not null and v_canonical = p_case,
    'lifecycle_state',     v_state,
    'notice_id',           v_row.id,
    'generation',          v_row.generation,
    'notice_kind',         v_row.notice_kind,
    -- THE FACT. NULL is a real answer and every consumer must render it as one.
    'notice_accepted_at',  v_row.notice_accepted_at,
    'accepted',            v_row.id is not null and v_row.notice_accepted_at is not null,
    'window_duration',     v_duration::text,
    'window_configured',   v_duration is not null,
    -- Anchored on ACCEPTANCE, never on owner_notified_at. NULL until there is an acceptance fact to
    -- anchor on, which is the honest answer rather than a date computed from provenance.
    'release_eligible_at', v_eligible,
    'elapsed',             v_elapsed);
end $function$;
revoke execute on function public.owner_notice_release_authority(uuid)
  from public, anon, authenticated;

comment on function public.owner_notice_release_authority(uuid) is
  'THE owner-notice release authority (Phase 11-OC / Phase D), consumed by both authorize_release '
  'and the operator case-file projection so the console can never offer a release the door refuses. '
  'A release qualifies ONLY when the CURRENT generation (superseded_by is null) of the CURRENT case '
  'episode carries notice_accepted_at, and now() > that instant + challenge_window_duration() '
  'STRICTLY. No status string participates in the decision, so a future status cannot become '
  'release-qualifying by not being cancelled. notice_accepted_at is PROVIDER ACCEPTANCE and never '
  'mailbox delivery; owner_notified_at is provenance and is never the clock. Every refusal carries '
  'a NAMED code from a closed set. Discloses no address and no identity. INTERNAL.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- begin_challenge_window(p_estate) → text                                      [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ REWRITTEN IN 11-F: it no longer notifies, because it no longer can. The notice moved to
-- `dispatch_owner_safety_notice`, and the edge `death_verified → challenge_window` was DELETED from
-- the transition map — so this routine's only legal input is an estate whose owner has already been
-- sent an email and an in-app notice. The guarantee "no window opens un-notified" is now carried by
-- the state machine rather than by this function remembering to check.
--
-- ★ PHASE D CORRECTS ITS INERT PREDICATE AND DELIBERATELY DOES **NOT** IMPORT THE RELEASE POLICY.
--
-- This door used to ask for an email row on the ESTATE with `status <> 'cancelled'` — the same
-- vacuous test the release door carried, and inert for the same reason. Phase D replaces it with
-- the fact it actually needs: A COMMITTED OWNER-SAFETY EMAIL NOTICE EXISTS FOR THE CURRENT CASE
-- EPISODE. Case-scoped, so an accepted notice from a PRIOR death process cannot satisfy it; the
-- current generation, so the check anchors on the same structural invariant the release door uses.
--
-- ★ AND IT MUST NOT REQUIRE `notice_accepted_at` (D7). Opening the window releases NOTHING — no
-- grant activates, no tier changes, no document becomes readable; the lifecycle moves and the
-- owner's challenge becomes available. The initial notice is normally still `queued` at this instant
-- because the drain runs asynchronously, so requiring provider acceptance here would make the window
-- unopenable until a worker had run, and would gate the owner's own protection on an email provider.
-- The irreversible door is `authorize_release`, and that is the one Phase D tightens.
create or replace function public.begin_challenge_window(p_estate uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid   uuid;
  v_state text;
  v_case  uuid;
  v_row   public.estate_lifecycle%rowtype;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  select l.* into v_row
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;
  v_state := v_row.state;

  if v_state = 'challenge_window' then
    return 'challenge_window'; -- idempotent replay
  end if;
  if v_state is distinct from 'owner_notification_dispatched' then
    raise exception 'invalid_window_state' using errcode = 'P0001';
  end if;

  -- Belt beside the state machine: the dispatch facts must actually be on the row.
  if v_row.owner_notified_at is null or v_row.safety_notification_id is null then
    raise exception 'owner_not_notified' using errcode = 'P0001';
  end if;

  -- ★ THE EPISODE IS RESOLVED BEFORE THE NOTICE IS LOOKED FOR, AND THAT ORDER IS THE FIX. The
  -- pre-Phase-D body checked the outbox by ESTATE and resolved the case afterwards, so a notice
  -- belonging to any death process this estate had ever run satisfied the guard.
  select c.id into v_case
    from public.death_verification_cases c
   where c.estate_id = p_estate and c.status = 'verified'
   order by c.decided_at desc
   limit 1;
  if v_case is null then
    raise exception 'no_verified_case' using errcode = 'P0001';
  end if;

  -- ★ PHASE D (D7) — A COMMITTED EMAIL NOTICE FOR **THIS** EPISODE, AND NOTHING STRONGER.
  --
  -- Case-scoped, so a notice from a prior rejected process cannot open a window under a new case.
  -- Current generation (`superseded_by is null`), so this anchors on the same structural invariant
  -- the release door uses — and, because supersession always writes a successor, "a current
  -- generation exists" is equivalent to "any generation exists" for the episode. NO status string
  -- and NO `notice_accepted_at`: the initial dispatch is normally still `queued` at this instant
  -- (the drain is asynchronous), and gating the owner's own protection on a provider would be a
  -- release-door policy applied to a door that discloses nothing.
  if not exists (
    select 1 from public.owner_notice_outbox o
     where o.case_id = v_case
       and o.channel = 'email'
       and o.notice_kind = any (public.owner_notice_episode_kinds())
       and o.superseded_by is null
  ) then
    raise exception 'no_current_notice' using errcode = 'P0001';
  end if;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'challenge_window', v_case, 'window_opened');

  update public.estate_lifecycle
     set challenge_window_started_at = now()
   where estate_id = p_estate;

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, p_estate, 'death_process.window_opened', 'estate_lifecycle', v_case,
          jsonb_build_object('severity', 'high', 'case_id', v_case,
                            'owner_notified_at', v_row.owner_notified_at),
          'admin');
  return 'challenge_window';
end $function$;
revoke execute on function public.begin_challenge_window(uuid) from public, anon;
grant  execute on function public.begin_challenge_window(uuid) to authenticated;

comment on function public.begin_challenge_window(uuid) is
  'Opens the owner-challenge window (Phase 11-E, rewritten 11-F, re-scoped 11-OC/D). Its ONLY legal '
  'input is owner_notification_dispatched — the death_verified -> challenge_window edge was deleted, '
  'so a window cannot open on an un-notified owner even by mistake. Phase D replaced the inert '
  'estate-scoped status <> cancelled predicate with the fact it needs: a committed email notice for '
  'the CURRENT case episode (no_current_notice otherwise). It deliberately does NOT require '
  'notice_accepted_at — opening the window discloses nothing and the initial notice is normally '
  'still queued. Admin-gated; idempotent; discloses nothing.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- authorize_release(p_estate, p_reason) → text                                 [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE TWO-PERSON RULE (D1), AND WHY IT LIVES IN THE DATABASE. The operator who verified the death
-- may not authorize the release. A console can enforce that and a console can be bypassed — by a
-- direct RPC, a future admin tool, a script, or the next rewrite. Here the rule is enforced twice on
-- purpose: this routine refuses, AND `release_authorizations` carries a CHECK constraint that makes
-- a single-reviewer row unwritable by ANY path. The routine is the door; the constraint is the wall.
--
-- ★ reviewer_a IS DERIVED, NEVER SUPPLIED. It is read from the verified case's `decided_by` — the
-- operator who actually made the call. A parameter would let the caller nominate a different
-- "first reviewer" and satisfy the rule against someone who never reviewed anything.
--
-- ★ THIS ROUTINE REPLACES 11-E's `release_estate`, WHICH IS DROPPED BY 0055. Leaving a one-person
-- lever beside a two-person door would be the whole decision undone by an un-rewired caller.
--
-- ★ AND IT STILL MANUFACTURES NOTHING (D5). No grant, no tier, no membership, no designation. The
-- lifecycle moves and the ONE canonical predicate answers differently for grants the owner already
-- authored.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ PHASE 11-OC / PHASE D — THE OWNER-NOTICE CUTOVER. WHAT CHANGED, AND WHAT DELIBERATELY DID NOT.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- EXACTLY TWO defective semantics are replaced, and every other guard in this routine is preserved
-- verbatim. Phase D makes release STRICTLY HARDER on every path and easier on none.
--
--   REPLACED · the owner-notice precondition
--       was:  an email row on this ESTATE with `status <> 'cancelled'`
--       now:  `owner_notice_release_authority(v_case)` — the CURRENT generation of the CURRENT
--             episode carries `notice_accepted_at`
--
--   REPLACED · the release clock anchor
--       was:  `now() > owner_notified_at + duration`   (stamped when the row was QUEUED)
--       now:  `now() > notice_accepted_at + duration`  (stamped when the PROVIDER ACCEPTED it)
--
--   PRESERVED · admin gate · non-blank reason · idempotent `released` replay · lifecycle must be
--   `challenge_window` · `owner_notified_at`/`safety_notification_id` present (now PROVENANCE, and
--   kept precisely because Phase D must not make any path easier) · verified-case requirement ·
--   reviewer_a DERIVED from the case decider · reviewer_b distinct · the `release_authorizations`
--   CHECK constraint · live `challenge_window_duration()` · STRICT `>` · the audit row · the
--   transition to `released`.
--
-- ★ THE REFUSAL ORDER IS UNCHANGED FOR EVERY PRE-EXISTING SENTINEL. `invalid_release_state`,
-- `owner_not_notified`, `no_verified_case`, `reviewer_a_unresolved` and `two_person_rule_violated`
-- all still fire before any clock or notice question, in that order, so a caller that was refused
-- for one of those reasons before is refused for the same reason now. The acceptance authority
-- occupies exactly the position the old `owner_channel_unreachable` predicate held relative to the
-- clock: after the two-person rule, before the release is written.
--
-- ★ THE AUTHORITY IS CONSULTED, NEVER RESTATED. This routine contains no status list, no
-- `superseded_by` test, no `case_id` join and no clock arithmetic of its own — all four live in
-- `owner_notice_release_authority`, which the operator console reads through the SAME function. A
-- second copy here is how a door and a console come to disagree in front of an operator holding an
-- irreversible lever.
create or replace function public.authorize_release(p_estate uuid, p_reason text)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_row        public.estate_lifecycle%rowtype;
  v_uid        uuid;
  v_case       uuid;
  v_reviewer_a uuid;
  v_verified   timestamptz;
  v_duration   interval;
  v_auth       jsonb;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'audit_reason_required' using errcode = 'P0001';
  end if;

  select l.* into v_row
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;

  if v_row.state = 'released' then
    return 'released'; -- idempotent replay: no second authorization row, no re-audit
  end if;
  if v_row.state is distinct from 'challenge_window' then
    -- challenge_halted lands here too: release can NEVER proceed from a halted process.
    raise exception 'invalid_release_state' using errcode = 'P0001';
  end if;

  -- The dispatch facts (D4), KEPT IN PHASE D AS PROVENANCE. These no longer decide when a release
  -- may proceed — `owner_notice_release_authority` does — but removing them would make one path
  -- easier, and Phase D makes no path easier. A window whose lifecycle row cannot even name the
  -- dispatch that opened it cannot elapse into disclosure.
  if v_row.owner_notified_at is null or v_row.safety_notification_id is null then
    raise exception 'owner_not_notified' using errcode = 'P0001';
  end if;

  select c.id, c.decided_by, c.decided_at into v_case, v_reviewer_a, v_verified
    from public.death_verification_cases c
   where c.estate_id = p_estate and c.status = 'verified'
   order by c.decided_at desc
   limit 1;
  if v_case is null then
    raise exception 'no_verified_case' using errcode = 'P0001';
  end if;
  if v_reviewer_a is null then
    raise exception 'reviewer_a_unresolved' using errcode = 'P0001';
  end if;

  -- ★ D1, ENFORCED HERE AND AGAIN BY THE TABLE CONSTRAINT BELOW.
  if v_uid = v_reviewer_a then
    raise exception 'two_person_rule_violated' using errcode = 'P0001';
  end if;

  -- ════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ PHASE D — THE OWNER-NOTICE ACCEPTANCE AUTHORITY AND THE RELEASE CLOCK, IN ONE CONSULTATION.
  -- ════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- The verdict is read under the lifecycle row lock taken above, so the state it describes cannot
  -- move between the answer and the write. `owner_notice_release_authority` is `stable` — it reads
  -- the calling statement's snapshot — which is correct here for exactly that reason, and is the
  -- same contract `reissue_owner_safety_notice` has with `owner_notice_reissue_assessment`.
  --
  -- ★ THE REFUSAL CODE IS RAISED VERBATIM, NEVER TRANSLATED. A `case` expression mapping the
  -- authority's codes onto this routine's own sentinels would be a second policy: the console reads
  -- the authority directly, so a translation layer here is precisely how the two come to describe
  -- the same estate differently. `release_window_not_configured` and `release_window_not_elapsed`
  -- are therefore still the strings a caller sees — they are now the AUTHORITY's names for them.
  v_auth := public.owner_notice_release_authority(v_case);
  if not (v_auth ->> 'ready')::boolean then
    raise exception '%', v_auth ->> 'refusal_code' using errcode = 'P0001';
  end if;
  -- Read back for the audit, from the SAME verdict that authorized this release rather than from a
  -- second lookup that could describe a different row.
  v_duration := (v_auth ->> 'window_duration')::interval;

  insert into public.release_authorizations
    (estate_id, case_id, reviewer_a, reviewer_b, verified_at, authorized_at, released_at, audit_reason)
  values (p_estate, v_case, v_reviewer_a, v_uid, v_verified, now(), now(), p_reason);

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'released', v_case, 'two_person_release');

  update public.estate_lifecycle
     set released_at = now()
   where estate_id = p_estate;

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, p_estate, 'death_process.released', 'release_authorizations', v_case,
          jsonb_build_object('severity', 'high', 'case_id', v_case,
                            'reviewer_a', v_reviewer_a, 'reviewer_b', v_uid,
                            'verified_at', v_verified,
                            -- PROVENANCE, and labelled as such. It is no longer the clock, and an
                            -- investigator reconstructing a disputed release a year later must be
                            -- able to see which instant the seven days actually ran from.
                            'owner_notified_at', v_row.owner_notified_at,
                            -- ★ THE FACT THE RELEASE RESTED ON, and the two derived instants, taken
                            -- from the verdict that authorized it. Provider acceptance — never
                            -- delivery, and the key name says so.
                            'notice_accepted_at', v_auth ->> 'notice_accepted_at',
                            'release_eligible_at', v_auth ->> 'release_eligible_at',
                            'notice_id', v_auth ->> 'notice_id',
                            'notice_generation', v_auth ->> 'generation',
                            'window_duration', v_duration::text,
                            'audit_reason', p_reason),
          'admin');
  return 'released';
end $function$;
revoke execute on function public.authorize_release(uuid, text) from public, anon;
grant  execute on function public.authorize_release(uuid, text) to authenticated;

comment on function public.authorize_release(uuid, text) is
  'THE release transition (Phase 11-F, re-anchored 11-OC/D): challenge_window -> released, by a '
  'SECOND platform operator. Requires admin gate, a non-empty audit reason, the dispatch provenance '
  'on the lifecycle row, a verified case, reviewer_b <> reviewer_a where reviewer_a is DERIVED from '
  'the case decider, and — from Phase D — owner_notice_release_authority: the CURRENT generation of '
  'the CURRENT case episode must carry notice_accepted_at (PROVIDER ACCEPTANCE, never mailbox '
  'delivery) and the window must be STRICTLY elapsed from THAT instant, not from owner_notified_at. '
  'No status string participates. Ties go to the owner challenge. Records a release_authorizations '
  'row whose CHECK constraint makes a single-reviewer release unwritable by any path. Creates no '
  'grant, tier, membership or designation.';

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
  v_uid       uuid := auth.uid();
  v_state     text;
  -- ★ Phase 11-L. The initiator of the case THIS CALL halts, captured from the UPDATE's own
  -- RETURNING rather than looked up afterwards. A separate SELECT could name a case this call did
  -- not touch — one already halted, or one halted by a concurrent transaction — and would notify
  -- someone about a process that is still running, or notify twice about one that stopped once.
  v_initiator uuid;
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

  -- The live case is halted — distinct from 'cancelled' (initiator withdrew): the owner said no.
  --
  -- ★ PHASE 11-NR — THE SET IS ('open','verified'), AND 'open' ALONE WAS THE DEFECT. This predicate
  -- read `status = 'open'`, which is the case status at exactly ONE of the four lifecycle states this
  -- routine can be reached from. The Branch A production drill measured the consequence: on the
  -- canonical operator-driven path the estate reached challenge_halted while its case row stayed
  -- 'verified', `v_initiator` came back NULL, and the 11-L halt notification — the entire deliverable
  -- of that phase — was never emitted to anybody. The case also stayed in the operator's `verified`
  -- work queue, invisible to a `halted` filter, with the queue row stating the contradiction outright.
  --
  -- The set is CLOSED and derived from the transition map, never "every row for this estate":
  --
  --   death_verification_pending    → case is 'open'      (initiate)
  --   death_verified                → case is 'verified'  (admin_decide 'verify')
  --   owner_notification_dispatched → case is 'verified'  (dispatch requires a verified case)
  --   challenge_window              → case is 'verified'  (begin_challenge_window requires one)
  --
  -- 'rejected' and 'cancelled' both return the lifecycle to `active`, where this routine has already
  -- raised `nothing_to_challenge` — they are decided history and settling them would overwrite an
  -- adjudication that did happen. 'halted' is excluded as a SECOND, independent guard against a
  -- re-stamp: the idempotent return above already refuses to reach this statement.
  --
  -- ★ AND IT STILL MATCHES AT MOST ONE ROW, WHICH NO LONGER FOLLOWS FROM THE INDEX ALONE.
  -- `death_verification_cases_one_open_per_estate` makes 'open' unique per estate; 'verified' is
  -- unique per estate for a different reason, and it is the state machine that supplies it. A
  -- verified case pins the lifecycle at death_verified or beyond, `initiate_death_verification_case`
  -- refuses unless the lifecycle is `active`, and no edge returns there from death_verified — so a
  -- second case cannot be opened once one is verified, and an 'open' case cannot coexist with a
  -- 'verified' one. Historical 'rejected' / 'cancelled' rows DO coexist and are excluded by the
  -- predicate. `into` therefore still has no set to choose from arbitrarily, and
  -- `release_safety_authorization.sql` §8 proves it on an estate that actually carries a decided
  -- historical case beside the live one.
  --
  -- ★ RETURNING gives us the initiator of the case actually settled HERE. A separate SELECT could
  -- name a case this call did not touch — one already halted, one from a prior rejected attempt, or
  -- one halted by a concurrent transaction — and would notify the wrong person, or notify twice
  -- about a process that stopped once.
  update public.death_verification_cases
     set status = 'halted', updated_at = now()
   where estate_id = p_estate and status in ('open', 'verified')
  returning initiated_by into v_initiator;

  -- ────────────────────────────────────────────────────────────────────────────────────────────
  -- ★ PHASE 11-L — TELL THE INITIATING FIDUCIARY THAT THEIR PROCESS STOPPED.
  -- ────────────────────────────────────────────────────────────────────────────────────────────
  --
  -- ★ RECIPIENT COMES FROM WORKFLOW STATE, NEVER FROM A CALLER. `p_estate` is the only input to
  -- this routine; there is no recipient parameter and therefore nothing for a client to point at
  -- someone else. `initiated_by` is `not null references auth.users(id)` on the case row.
  --
  -- ★ HISTORICAL INITIATOR, AND THE CASE MODEL SETTLES IT RATHER THAN A GUESS. 0052 states that
  -- `initiator_designation_id` / `initiator_capacity` are "a snapshot of fact ('this person acted
  -- as executor'), never an authority the case can later re-assert — a revoked designee does not
  -- keep acting because a case remembers them." So a designation revoked after initiation must NOT
  -- suppress this message: the notification asserts no authority, it reports one fact about
  -- something the recipient personally did. They already know they initiated it; being told it
  -- stopped discloses nothing they did not bring with them. Re-deriving a LIVE designation here
  -- would instead silently drop the message for exactly the person owed it.
  --
  -- ★ IT CANNOT REACH THE OWNER. The owner is the caller (is_estate_owner above), and the guard
  -- below excludes them explicitly. That covers the degenerate case where an estate owner is also
  -- a designee on their own estate: they would otherwise receive claimant-facing copy about their
  -- own halt, which reads as a message from a stranger about their own death process.
  --
  -- ★ NO DEEP LINK, DELIBERATELY. The recipient's own surface is `/executor`
  -- (`get_executor_workspace`, which refuses a revoked designee) — but the RN deep-link allowlist
  -- in `features/notifications/actions.ts` has no `afterworth://executor` key, and a link that is
  -- not in the allowlist resolves to null and renders as a non-navigating row anyway. Passing an
  -- unmatched string would be inventing a route rather than using one. Wiring that destination is
  -- a bounded mobile follow-up, recorded in docs/phase11l-halt-notification.md §6.
  --
  -- ★ EMISSION IS INSIDE THIS TRANSACTION, so it commits with the halt or not at all — no
  -- notification can precede or outlive the state change it describes. The idempotent-replay
  -- return above happens BEFORE any of this, so a second challenge emits nothing. And when no case
  -- was open, `v_initiator` is null and nothing is emitted: a halt with no initiated process to
  -- report has nobody to report it to.
  if v_initiator is not null and v_initiator <> v_uid then
    perform public.emit_lifecycle_notification(
      v_initiator, p_estate, 'death_process.halted', null);
  end if;

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
-- release_estate — REMOVED IN PHASE 11-F. Its replacement is `authorize_release` above.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ REMOVED FROM SOURCE, AND DROPPED BY MIGRATION 0055 — both halves are required. 11-E's
-- `release_estate(uuid)` released on ONE operator's say-so, which D1 forbids. Deleting only the
-- source would leave the function alive in every database that ever applied 11-E, because
-- `create or replace` cannot remove what it no longer mentions; dropping only in the migration
-- would let the next bundle paste recreate it from source. So the definition is gone from here and
-- the drop ships in the migration beside it — the 0053 precedent, applied to an actor rather than
-- to an argument.
--
-- A caller that was never rewired now fails loudly (`function does not exist`) instead of quietly
-- releasing an estate without a second reviewer.

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
  -- ★ THE 11-F STATE JOINS THE `challengeable` GROUP, and that is the safety-preserving mapping:
  -- an owner who has just received the email is squarely in the population this surface exists for.
  -- The union stays four values on purpose — the owner needs "can I stop this", never the machine's
  -- internals, and a client that could distinguish dispatched from windowed would be a client with
  -- something to branch on.
  return case v_state
    when 'death_verification_pending'    then 'challengeable'
    when 'death_verified'                then 'challengeable'
    when 'owner_notification_dispatched' then 'challengeable'
    when 'challenge_window'              then 'challengeable'
    when 'challenge_halted'              then 'halted'
    when 'released'                      then 'released'
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
