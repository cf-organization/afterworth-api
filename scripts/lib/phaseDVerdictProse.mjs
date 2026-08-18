/**
 * PHASE 11-OC / PHASE D · THE VERIFIER'S SCOPE SUMMARY — extracted so it can be TESTED and MUTATED.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY THIS IS A MODULE AND NOT THREE `note()` CALLS INSIDE `main()`.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `verifyPhaseDDeployment.mjs` runs against a live server: `main()` cannot execute without an AAL2
 * session, so any prose built inline in it is unreachable from a unit test and unreachable from the
 * mutation matrix. That is exactly how the defect this module exists to prevent shipped in the first
 * place — the wording was inline, nothing could assert on it, and it went out claiming
 *
 *     PROVED: the Phase D release authority is deployed …
 *
 * on a run whose own verdict was `PHASE_C_STILL_ACTIVE` and whose exit code was 1. The CHECKS were
 * right. The SUMMARY contradicted them, three lines above the verdict, on the screen an operator
 * reads immediately after a deployment.
 *
 * ★ THE FAILURE CLASS, NAMED. This is not a wrong check — it is a right check with a false summary,
 * and the summary is what a human carries away. An instrument whose prose can disagree with its own
 * verdict is a vacuous audit wearing different clothes: the reader is told a conclusion the run did
 * not reach, and nothing in the pipeline objects.
 *
 * ★ SO THE CONTRACT IS INTERNAL CONSISTENCY, ASSERTED AS ONE PROPERTY:
 *
 *        VERDICT   ⟷   EXIT CODE   ⟷   PROSE
 *
 * all three derive from the same two inputs, in one place, and `test/phaseDVerdictProse.test.ts`
 * proves they can never disagree — including the direction that actually shipped.
 */

/** The two states the verifier exists to distinguish. Anything else is a programming error. */
export const PHASE_D_DEPLOYED = 'PHASE_D_DEPLOYED';
export const PHASE_C_STILL_ACTIVE = 'PHASE_C_STILL_ACTIVE';

/**
 * Wording that may appear ONLY when Phase D is genuinely deployed and every assertion passed.
 *
 * ★ IT IS EXPORTED SO THE TEST MATCHES THE REAL STRING RATHER THAN A COPY. A test carrying its own
 * spelling of the claim would keep passing after the production wording drifted — the
 * two-literals-are-two-opinions failure, applied to an audit's own evidence.
 */
export const DEPLOYMENT_PROOF_SENTENCE =
  'the Phase D release authority is deployed, shared by the projection and the';

/**
 * Build the SCOPE block for a completed run.
 *
 * @param {string}  phase     PHASE_D_DEPLOYED | PHASE_C_STILL_ACTIVE — what was OBSERVED
 * @param {number}  failures  how many assertions failed on this run
 * @returns {{lines: string[], claimsDeployment: boolean, exitCode: number}}
 *
 * `claimsDeployment` is returned rather than left for a caller to grep, so the invariant
 * "prose claims deployment ⟹ phase is deployed AND nothing failed" is checkable directly.
 */
export function scopeReport(phase, failures) {
  if (phase !== PHASE_D_DEPLOYED && phase !== PHASE_C_STILL_ACTIVE) {
    throw new Error(`phaseDVerdictProse: unknown phase ${String(phase)}`);
  }
  if (!Number.isInteger(failures) || failures < 0) {
    throw new Error(`phaseDVerdictProse: failures must be a non-negative integer`);
  }

  const clean = phase === PHASE_D_DEPLOYED && failures === 0;
  const lines = [];
  let claimsDeployment = false;

  if (clean) {
    // ★ THE ONLY BRANCH PERMITTED TO ASSERT A DEPLOYMENT.
    lines.push(`     PROVED   : ${DEPLOYMENT_PROOF_SENTENCE}`);
    lines.push('                door, gated, and anchored on the acceptance fact rather than on provenance.');
    claimsDeployment = true;
  } else if (phase === PHASE_D_DEPLOYED) {
    // The authority IS present but something failed. Reporting a clean cutover here would be the
    // same overclaim in a subtler place — a half-verified deployment reading as a whole one.
    lines.push('     PARTIAL  : the Phase D authority IS present, but one or more assertions above failed.');
    lines.push('                Nothing here may be read as a clean cutover — see the ✗ lines.');
  } else {
    // ★ THE BRANCH THAT SHIPPED WRONG. It must say plainly that NOTHING about Phase D was
    // established, that this is EXPECTED before the paste, and that it is nonetheless a failure to
    // verify rather than a clean bill of health. All three, because dropping any one of them turns
    // an honest "not yet" into either a false alarm or a false reassurance.
    lines.push('     PROVED   : NOTHING about Phase D. The release door is still on PHASE C semantics —');
    lines.push('                the case file carries no `release_authority`, so the acceptance authority');
    lines.push('                is NOT deployed. This is the EXPECTED result before the artifact is pasted,');
    lines.push('                and it is a failure to verify Phase D rather than a clean bill of health.');
  }

  lines.push('     NOT PROVED: that a real release succeeds in production. Executing one would');
  lines.push('                 IRREVERSIBLY DISCLOSE AN ESTATE. That is not a check; it is the act itself.');
  lines.push('     STATUS    : PRODUCTION_RUNTIME_PROOF_PENDING — Branch B, separately authorized, against');
  lines.push('                 a synthetic estate, after a real seven-day window.');
  lines.push('     NOTE      : notice_accepted_at is PROVIDER ACCEPTANCE. It is not delivery, not receipt,');
  lines.push('                 and not proof that a living owner read anything.');

  // ★ THE EXIT CODE IS DERIVED HERE TOO, so it cannot drift from the prose it accompanies. A run
  // that observed Phase C has FAILED to verify Phase D even if no individual assertion errored.
  return Object.freeze({
    lines: Object.freeze(lines),
    claimsDeployment,
    exitCode: clean ? 0 : 1,
  });
}
