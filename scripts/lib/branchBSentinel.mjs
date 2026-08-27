/**
 * PHASE 11-OB PREP · THE BRANCH B PRODUCTION SENTINEL — one instrument, two worlds, no synthesis.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ ABSENT IS NOT BROKEN, AND THAT DISTINCTION IS THE WHOLE POINT OF THIS FILE.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Branch B has not started. Its estate does not exist. A sentinel that reported FAIL for that would
 * be shouting for the entire period during which everything is exactly as it should be, and the
 * shouting would be the reason nobody looks at it on the day it matters.
 *
 * So before the drill exists the verdict is `BRANCH_B_FIXTURE_ABSENT` — a first-class, expected,
 * exit-0 answer — and the STANDING fixture is still checked, because that half is live today.
 *
 * ★ AND ABSENT IS NEVER SYNTHESIZED INTO STATE. The tempting shortcut is to treat missing rows as
 * zeroes: no lifecycle row means `active`, no case means `open`, no release authorization means
 * "none, good". Every one of those reads a hole as a fact. `personaSummary()` labelled every
 * all-false capability set "Professional delegate" by exactly this move. Missing is reported as
 * missing; the estate is either present in full or reported absent.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE STANDING FIXTURE IS NOT RE-IMPLEMENTED HERE.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `afterworth-mobile/scripts/fiduciaryFixtureSentinel.mjs` already asserts the 23 properties of the
 * AW_FIDUCIARY standing fixture through its own product paths. A second copy of those assertions
 * would drift, and the day they disagreed nobody would know which was right. The CLI shells out to
 * it and consumes its exit code and its `N/M` tally; this module classifies the result.
 *
 * PURE. The CLI collects; this decides.
 */

/**
 * ★ PHASE 11-Q — `OK` NOW MEANS SOMETHING. IT USED TO BE DEAD CODE.
 *
 * `OK` was always documented as "the drill finished cleanly", and the classifier ended with
 * `released_at === null ? IN_FLIGHT : OK`. But a release necessarily flips three pinned
 * expectations at once — `released_at`, the pinned `lifecycle`, and the disclosure posture — and any
 * finding forced `DRIFTED`. The findings list could therefore never be empty once a release existed,
 * so `OK` was unreachable and every correct release was reported as generic drift at exit 1.
 *
 * ★ THE FIX IS PHASE AWARENESS, NOT TOLERANCE. The checkpoint describes a drill at
 *   `challenge_window`; after release the SAME checkpoint describes a drill that has legitimately
 *   moved on. So the classifier asks which phase it is looking at and applies that phase's
 *   expectations — it does not widen the pre-release ones.
 *
 * ★ `RELEASED_INCONSISTENT` EXISTS SO THE FIX CANNOT BECOME AN AMNESTY. A half-released world —
 *   `released_at` with no `released` lifecycle, or the reverse — is neither a healthy in-flight
 *   drill nor a clean finish, and it must not borrow either verdict.
 */
export const SENTINEL = Object.freeze({
  OK: 'BRANCH_B_SENTINEL_OK',
  ABSENT: 'BRANCH_B_FIXTURE_ABSENT',
  IN_FLIGHT: 'BRANCH_B_IN_FLIGHT_WAITING',
  DRIFTED: 'BRANCH_B_SENTINEL_DRIFTED',
  RELEASED_INCONSISTENT: 'BRANCH_B_RELEASED_INCONSISTENT',
  UNVERIFIABLE: 'BRANCH_B_SENTINEL_UNVERIFIABLE',
});

/**
 * The closed disclosure-posture vocabulary the collector can emit. A value outside this set is a
 * collector change this module has not been taught, and fails closed in EVERY phase rather than
 * falling through a `!== 'hidden'` test that would read an unknown string as a leak, or — worse
 * — an unknown string as a successful disclosure.
 */
export const DISCLOSURE_POSTURES = Object.freeze({
  HIDDEN: 'hidden',
  DISCLOSED: 'sentinel_DISCLOSED',
  PROBE_BROKEN: 'probe_broken_open_control_not_visible',
});

/** The lifecycle phases the sentinel distinguishes, derived from two independent signals. */
export const PHASE = Object.freeze({
  PRE_RELEASE: 'pre_release',
  RELEASED: 'released',
  INCONSISTENT: 'inconsistent',
});

/**
 * PURE. Which phase does this observation describe?
 *
 * ★ TWO INDEPENDENT SIGNALS, AND DISAGREEMENT IS ITS OWN ANSWER. `released_at` is stamped by
 *   `authorize_release` in the same transaction that transitions the lifecycle, so in a healthy
 *   world they always agree. Reading only one would let a half-written release masquerade as the
 *   other phase — and which one it masqueraded as would depend on which field we happened to pick.
 */
export function observedPhase(branchB) {
  const hasInstant = branchB?.released_at !== null && branchB?.released_at !== undefined;
  const hasLifecycle = branchB?.lifecycle === 'released';
  if (!hasInstant && !hasLifecycle) return PHASE.PRE_RELEASE;
  if (hasInstant && hasLifecycle) return PHASE.RELEASED;
  return PHASE.INCONSISTENT;
}

/**
 * ★ PHASE 11-P — THE FIELDS THE SENTINEL PINS AGAINST THE COMMITTED CHECKPOINT.
 *
 * The drill now EXISTS, so "is it intact" stops meaning "does it exist" and starts meaning "is it
 * still the SAME drill". A sentinel that only checked presence would stay green while the case was
 * replaced, the notice superseded, or the reviewer seats swapped — every one of which invalidates
 * the release the checkpoint is being kept for.
 *
 * `null` is compared as a VALUE, not as absent: before the worker runs, `notice_accepted_at` must be
 * null, and a non-null there is drift exactly as much as a wrong uuid is.
 *
 * ★ `generation` IS DELIBERATELY NOT PINNED HERE, AND ITS PROPERTY IS STILL COVERED. The checkpoint
 * schema has no `generation` key — its key set IS its schema — so naming one produced a
 * `checkpoint_field_missing` finding rather than a comparison. The stop condition it guards
 * ("a superseded generation treated as current") is enforced more tightly by `owner_outbox_id`:
 * the observation selects the row where `is_current`, so a re-notice makes the CURRENT row a
 * DIFFERENT uuid and the pin fails. An id comparison subsumes an ordinal one.
 */
export const BRANCH_B_PINNED = Object.freeze([
  'estate_uuid',
  'case_uuid',
  'lifecycle',
  'owner_outbox_id',
  'notice_accepted_at',
  'release_eligible_at',
  'reviewer_a_uid',
  'reviewer_b_uid',
]);

/**
 * Compare an observation against the checkpoint's pinned facts. Pure; returns findings only.
 *
 * ★ A MISSING KEY IS DRIFT, NEVER A SKIPPED COMPARISON. Reading `undefined === undefined` as
 * agreement is how an audit passes against a projection that stopped publishing the field.
 */

/**
 * ★ TIMESTAMPS ARE COMPARED AS INSTANTS, NOT AS SPELLINGS.
 *
 * PostgREST renders `2026-08-19T04:22:12.450582+00:00` (microseconds, numeric offset); the checkpoint
 * stores `2026-08-19T04:22:12.450Z` (milliseconds, Z). Those are the SAME MOMENT and different
 * strings, so a raw `!==` would have reported permanent drift on a perfectly intact drill — an
 * instrument that cries wolf until somebody widens it until it means nothing.
 *
 * Everything else stays a strict identity comparison: uuids and lifecycle names have exactly one
 * correct spelling, and normalizing those would be inventing tolerance where none is owed.
 */
const INSTANT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/;
function sameValue(a, b) {
  if (a === b) return true;
  if (typeof a === 'string' && typeof b === 'string' && INSTANT_RE.test(a) && INSTANT_RE.test(b)) {
    const x = Date.parse(a);
    const y = Date.parse(b);
    return Number.isFinite(x) && Number.isFinite(y) && x === y;
  }
  return false;
}

export function compareBranchBExpectations(observed, expected, fields = BRANCH_B_PINNED) {
  const findings = [];
  if (!observed || typeof observed !== 'object') {
    return [{ code: 'branch_b_observation_malformed', detail: typeof observed }];
  }
  if (!expected || typeof expected !== 'object') {
    return [{ code: 'branch_b_expectations_absent', detail: 'no checkpoint supplied to pin against' }];
  }
  for (const f of fields) {
    if (!(f in expected)) {
      findings.push({ code: 'checkpoint_field_missing', detail: f });
      continue;
    }
    if (!(f in observed)) {
      findings.push({ code: 'observation_field_missing', detail: f });
      continue;
    }
    if (!sameValue(observed[f], expected[f])) {
      findings.push({
        code: 'branch_b_drift',
        detail: `${f}: observed=${String(observed[f])} checkpoint=${String(expected[f])}`,
      });
    }
  }
  return findings;
}

/**
 * Everything the sentinel checks once the Branch B estate EXISTS. Declared as data so the CLI, the
 * report and the test all read one list — and so a check cannot be quietly dropped.
 */
/**
 * ★ PHASE 11-Q — `release_authorizations` IS GONE, BECAUSE IT WAS NEVER OBSERVED.
 *
 * The collector set it to the literal `0` and never read a database. Two consequences, both live:
 * the consumer check `if (branchB.release_authorizations !== 0)` could NEVER fire, and the CLI
 * printed "reserved, 0 authorization(s)" — a claim production flatly contradicted the moment a
 * release existed. A number that cannot be wrong is not evidence; a number that is always wrong
 * after the event it describes is worse than none.
 *
 * ★ IT WAS REMOVED RATHER THAN REPAIRED. `release_authorizations` has RLS enabled with ZERO grants
 *   and ZERO policies — DEFINER-routine-only — so no client can count it, and inventing a read
 *   would have meant widening a deliberately sealed table to satisfy an instrument. Duplication is
 *   already bounded where it belongs: the `release_authorizations_one_per_estate` unique index on
 *   `(estate_id)` makes a second row impossible, and the writer returns early on an already-released
 *   state without inserting one. `released_at` is the observable fact, and it is pinned above.
 */
export const BRANCH_B_PROPERTIES = Object.freeze([
  'estate_uuid',
  'designation',
  'membership',
  'grant',
  'lifecycle',
  'case',
  'owner_notice',
  'challenge_window',
  'released_at',
  'disclosure_posture',
  'fixture_lock',
]);

const SENTINEL_RE = /^(\d{1,4})\/(\d{1,4})$/;

/**
 * @param {object} input
 * @param {object|null} input.standingFixture  { tally: 'N/M', exitCode: number } — null if not run
 * @param {object|null} input.branchB          the observed Branch B world, or null if it does not exist
 * @param {string[]}   [input.expectedProperties]
 */
export function classifyBranchBSentinel({
  standingFixture,
  branchB,
  expected = null,
  expectedProperties = BRANCH_B_PROPERTIES,
}) {
  const findings = [];
  const note = (code, detail) => findings.push({ code, detail });

  /* ── THE STANDING WORLD, WHICH IS LIVE TODAY ─────────────────────────────────────────────────── */
  if (!standingFixture || typeof standingFixture !== 'object') {
    return frozen(SENTINEL.UNVERIFIABLE, [{ code: 'standing_fixture_not_run', detail: 'no result supplied' }]);
  }
  const m = SENTINEL_RE.exec(String(standingFixture.tally ?? ''));
  if (!m) {
    return frozen(SENTINEL.UNVERIFIABLE, [
      { code: 'standing_fixture_tally_unreadable', detail: String(standingFixture.tally) },
    ]);
  }
  const [, passed, total] = m;
  if (Number(total) === 0) {
    // ★ ASSERT THE SCAN SET BEFORE BELIEVING THE RESULT. 0/0 is a green nothing.
    return frozen(SENTINEL.UNVERIFIABLE, [{ code: 'standing_fixture_checked_nothing', detail: '0 checks' }]);
  }
  const standingIntact = passed === total && standingFixture.exitCode === 0;
  if (!standingIntact) {
    note('standing_fixture_not_intact', `${passed}/${total} exit ${standingFixture.exitCode}`);
  }

  /* ── THE BRANCH B WORLD, WHICH DOES NOT EXIST YET ────────────────────────────────────────────── */
  if (branchB === null || branchB === undefined) {
    // Expected, for as long as Branch B has not started. Still a real verdict about the standing world.
    return frozen(standingIntact ? SENTINEL.ABSENT : SENTINEL.DRIFTED, [
      ...findings,
      { code: 'branch_b_fixture_absent', detail: 'no Branch B estate has been provisioned' },
    ]);
  }
  if (typeof branchB !== 'object' || Array.isArray(branchB)) {
    return frozen(SENTINEL.UNVERIFIABLE, [{ code: 'branch_b_observation_malformed', detail: typeof branchB }]);
  }

  // ★ PRESENT MEANS PRESENT IN FULL. A partial observation is refused rather than completed with
  //   assumptions — a missing `released_at` key is not the same as `released_at: null`.
  const missing = expectedProperties.filter((p) => !(p in branchB));
  if (missing.length > 0) {
    return frozen(SENTINEL.UNVERIFIABLE, [
      ...findings,
      { code: 'branch_b_observation_incomplete', detail: missing.join(',') },
    ]);
  }

  if (branchB.fixture_lock !== 'free' && branchB.fixture_lock !== 'held') {
    note('branch_b_fixture_lock_unreadable', String(branchB.fixture_lock));
  }

  /* ── WHICH PHASE IS THIS? ─────────────────────────────────────────────────────────────────────
   * ★ A HALF-RELEASED WORLD BORROWS NEITHER VERDICT. `authorize_release` stamps `released_at` and
   *   transitions the lifecycle in ONE transaction, so the two agree in every healthy world.
   *   Disagreement means something wrote this estate outside the sanctioned path, which is the most
   *   serious thing this instrument can find and gets a verdict of its own.
   */
  const phase = observedPhase(branchB);
  const pinnedFields =
    phase === PHASE.RELEASED
      // The lifecycle legitimately MOVED — it is asserted by the phase itself, above, rather than
      // compared to a checkpoint written before the move. Every identity fact still holds.
      ? BRANCH_B_PINNED.filter((f) => f !== 'lifecycle')
      : BRANCH_B_PINNED;

  const meta = {
    phase,
    standing_fixture: `${passed}/${total}`,
    branch_b_properties_observed: expectedProperties.length,
    branch_b_pinned_compared: expected ? pinnedFields.length : 0,
  };

  if (phase === PHASE.INCONSISTENT) {
    // ★ The two fields are written together, in one transaction, by the release routine (named in
    //   `db/functions/release_safety.sql`). It is deliberately NOT named in the string below:
    //   `readOnlyAudit` strips comments but keeps STRING literals, because a string is how a call
    //   gets built. Naming a mutation routine in prose is fine; naming it in a value is not.
    note(
      'branch_b_release_state_inconsistent',
      `lifecycle=${String(branchB.lifecycle)} released_at=${String(branchB.released_at)} — `
        + 'the release routine writes these together and they cannot legitimately disagree'
    );
    for (const f of compareBranchBExpectations(branchB, expected, pinnedFields)) findings.push(f);
    return frozen(SENTINEL.RELEASED_INCONSISTENT, findings, meta);
  }

  /* ── THE DISCLOSURE POSTURE IS A SAFETY PROPERTY, AND ITS EXPECTATION IS PHASE-DEPENDENT ──────
   * ★ BEFORE release the death-conditioned document must be WITHHELD — a disclosure there means the
   *   drill leaked and the owner's challenge window was worthless.
   * ★ AFTER release it must be DISCLOSED — that is the entire product behaviour under test. A
   *   still-hidden document post-release is a FAILED release, and is named as one rather than being
   *   folded into the pre-release "wrong posture" finding, because the two need opposite responses.
   * ★ AN UNKNOWN POSTURE FAILS IN BOTH PHASES. It is neither proof of a leak nor proof of a
   *   disclosure, so it can never be read as either.
   */
  const posture = branchB.disclosure_posture;
  const known = Object.values(DISCLOSURE_POSTURES).includes(posture);
  if (!known) {
    note('branch_b_disclosure_posture_unknown', String(posture));
  } else if (posture === DISCLOSURE_POSTURES.PROBE_BROKEN) {
    note('branch_b_disclosure_probe_broken', String(posture));
  } else if (phase === PHASE.PRE_RELEASE && posture !== DISCLOSURE_POSTURES.HIDDEN) {
    note('branch_b_disclosure_posture_wrong', String(posture));
  } else if (phase === PHASE.RELEASED && posture !== DISCLOSURE_POSTURES.DISCLOSED) {
    note(
      'branch_b_release_did_not_disclose',
      `${String(posture)} — the estate is released but the sanctioned document is still withheld`
    );
  }

  // ★ PINNED-FACT COMPARISON. Presence was the question while Branch B did not exist; identity is
  //   the question now that it does — and identity must survive a release untouched.
  for (const f of compareBranchBExpectations(branchB, expected, pinnedFields)) findings.push(f);

  if (findings.length > 0) {
    return frozen(phase === PHASE.RELEASED ? SENTINEL.RELEASED_INCONSISTENT : SENTINEL.DRIFTED, findings, meta);
  }

  // Intact. Mid-flight and waiting is a DIFFERENT true answer from "the drill finished cleanly",
  // and the two must not share a verdict.
  return frozen(phase === PHASE.RELEASED ? SENTINEL.OK : SENTINEL.IN_FLIGHT, findings, meta);
}

function frozen(verdict, findings, extra = {}) {
  return Object.freeze({ verdict, findings: Object.freeze(findings), ...extra });
}

/**
 * 0 = a healthy world (absent, in flight, or cleanly finished) · 1 = drifted or an inconsistent
 * release · 2 = could not verify. Never a bare pass.
 *
 * ★ `OK` JOINS THE ZERO-EXIT SET AND `RELEASED_INCONSISTENT` JOINS THE ONE-EXIT SET. A finished
 *   drill is not a failure and must stop being reported as one; a half-released estate is a failure
 *   and must never be reported as anything else.
 */
export function sentinelExitCode(verdict) {
  if (verdict === SENTINEL.OK || verdict === SENTINEL.ABSENT || verdict === SENTINEL.IN_FLIGHT) {
    return 0;
  }
  if (verdict === SENTINEL.DRIFTED || verdict === SENTINEL.RELEASED_INCONSISTENT) return 1;
  return 2;
}
