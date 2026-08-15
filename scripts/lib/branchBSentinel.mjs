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
  DRIFTED: 'BRANCH_B_SENTINEL_DRIFTED',
  UNVERIFIABLE: 'BRANCH_B_SENTINEL_UNVERIFIABLE',
});

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
export function classifyBranchBSentinel({ standingFixture, branchB, expectedProperties = BRANCH_B_PROPERTIES }) {
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

  return frozen(findings.length === 0 ? SENTINEL.OK : SENTINEL.DRIFTED, findings, {
    standing_fixture: `${passed}/${total}`,
    branch_b_properties_observed: expectedProperties.length,
  });
}

function frozen(verdict, findings, extra = {}) {
  return Object.freeze({ verdict, findings: Object.freeze(findings), ...extra });
}

/** 0 = OK or the expected ABSENT · 1 = drifted · 2 = could not verify. Never a bare pass. */
export function sentinelExitCode(verdict) {
  if (verdict === SENTINEL.OK || verdict === SENTINEL.ABSENT) return 0;
  if (verdict === SENTINEL.DRIFTED) return 1;
  return 2;
}
