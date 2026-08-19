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

export const SENTINEL = Object.freeze({
  OK: 'BRANCH_B_SENTINEL_OK',
  ABSENT: 'BRANCH_B_FIXTURE_ABSENT',
  IN_FLIGHT: 'BRANCH_B_IN_FLIGHT_WAITING',
  DRIFTED: 'BRANCH_B_SENTINEL_DRIFTED',
  UNVERIFIABLE: 'BRANCH_B_SENTINEL_UNVERIFIABLE',
});

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
export const BRANCH_B_PROPERTIES = Object.freeze([
  'estate_uuid',
  'designation',
  'membership',
  'grant',
  'lifecycle',
  'case',
  'owner_notice',
  'challenge_window',
  'release_authorizations',
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

  if (branchB.released_at !== null) note('branch_b_released', String(branchB.released_at));
  if (branchB.release_authorizations !== 0) {
    note('branch_b_release_authorization_present', String(branchB.release_authorizations));
  }
  if (branchB.fixture_lock !== 'free' && branchB.fixture_lock !== 'held') {
    note('branch_b_fixture_lock_unreadable', String(branchB.fixture_lock));
  }

  // ★ THE DISCLOSURE POSTURE IS A SAFETY PROPERTY, NOT A STATUS FIELD. Before release the
  //   death-conditioned sentinel must be withheld; a `true` here means the drill already leaked.
  if (branchB.disclosure_posture !== 'hidden') {
    note('branch_b_disclosure_posture_wrong', String(branchB.disclosure_posture));
  }

  // ★ PINNED-FACT COMPARISON. Presence was the question while Branch B did not exist; identity is
  //   the question now that it does.
  for (const f of compareBranchBExpectations(branchB, expected)) findings.push(f);

  const meta = {
    standing_fixture: `${passed}/${total}`,
    branch_b_properties_observed: expectedProperties.length,
    branch_b_pinned_compared: expected ? BRANCH_B_PINNED.length : 0,
  };
  if (findings.length > 0) return frozen(SENTINEL.DRIFTED, findings, meta);

  // Intact. `released_at === null` means the drill is still mid-flight and waiting, which is a
  // DIFFERENT true answer from "the drill finished cleanly" and must not share a verdict with it.
  return frozen(branchB.released_at === null ? SENTINEL.IN_FLIGHT : SENTINEL.OK, findings, meta);
}

function frozen(verdict, findings, extra = {}) {
  return Object.freeze({ verdict, findings: Object.freeze(findings), ...extra });
}

/** 0 = OK or the expected ABSENT · 1 = drifted · 2 = could not verify. Never a bare pass. */
export function sentinelExitCode(verdict) {
  if (verdict === SENTINEL.OK || verdict === SENTINEL.ABSENT || verdict === SENTINEL.IN_FLIGHT) {
    return 0;
  }
  if (verdict === SENTINEL.DRIFTED) return 1;
  return 2;
}
