#!/usr/bin/env node
/**
 * Assemble the Phase 11-OBR / OB-1 remediation into ONE paste-ready artifact.
 *
 * ★ WHAT IT FIXES, MEASURED IN PRODUCTION. The Branch A owner-safety notice was observed at
 * `status = 'processing'`, `attempts = 1`, `dispatched_at = null` a day after the drain claimed it.
 * `claim_owner_notices` selected `status = 'queued'` only, so no future drain could hand it out
 * again. The owner's single independent warning that their estate was being released was lost, and
 * the only remaining transition was a stale sweep that marks it failed a day AFTER the release
 * window it exists to protect has already elapsed.
 *
 * ★ TWO PARTS, AND BOTH ARE REQUIRED IN THIS ORDER. The migration adds `claimed_at`; the routine
 * reads it. Pasting the routine against a database without the column fails on the first claim, so
 * the column ships in front of it inside the same transaction.
 *
 * ★ IT CARRIES `outbox_safety.sql` WHOLE, WHICH MEANS IT ALSO RE-PASTES `record_owner_notice_outcome`
 * AND THE PURGE. That is not scope creep — `create or replace` only replaces what the artifact
 * contains, and the file is the unit the repository maintains. The controls below assert all three
 * routines are present so a part that had lost one cannot silently leave a stale body deployed.
 *
 * ★ WHAT IT DELIBERATELY DOES NOT DO: it does not touch `authorize_release`. That routine accepts any
 * owner-notice row with `status <> 'cancelled'`, so `processing` and even `failedPermanent` satisfy
 * the "owner is independently reachable" release guard today. That is OB-2 — a product decision about
 * when a release may proceed — and this artifact must not decide it. Migration 0057 asserts the
 * precondition is unchanged, so OB-1 cannot drift into OB-2 unnoticed.
 *
 * ★ CONTROLS PIN STRUCTURE, NEVER THE POLICY THE SQL SUITE TESTS. There is deliberately no needle
 * for the visibility timeout value, the reclaim predicate, or the `claimed_at = now()` stamp. That is
 * the `p11b-legacy-fused` lesson this programme has now paid for five times: a control tight enough
 * to make the BUILD refuse a mutation means the mutation can only ever be caught here, and nothing
 * proves the runtime layer works. Every behavioural question is answered by
 * `db/tests/release_safety_authorization.sql` §9 against a real Postgres, and by the `p11obr-*`
 * mutations that must each be DETECTED there.
 *
 * Usage:  node scripts/buildOwnerNoticeClaimVisibilityBundle.mjs [--out <path>]
 *         node scripts/buildOwnerNoticeClaimVisibilityBundle.mjs --check
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root,
    script: 'scripts/buildOwnerNoticeClaimVisibilityBundle.mjs',
    parts: [
      'db/migrations/0057_20260816_owner_notice_claim_visibility.sql',
      'db/functions/outbox_safety.sql',
    ],
    controls: [
      // The column the entire remediation rests on. Absent, there is nothing to time out against.
      ['db/migrations/0057_20260816_owner_notice_claim_visibility.sql',
        'add column if not exists claimed_at timestamptz'],
      // The migration's own OB-2 guard must ship with it, or the artifact loses its proof that this
      // paste did not change when a release may proceed.
      ['db/migrations/0057_20260816_owner_notice_claim_visibility.sql', 'authorize_release'],
      // The three routines the file defines must all be present — `create or replace` only replaces
      // what the artifact carries, so a missing one silently leaves the deployed body in place.
      ['db/functions/outbox_safety.sql', 'create or replace function public.claim_owner_notices'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.record_owner_notice_outcome'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.purge_outbox_rows'],
      /**
       * ★ THE PRIVILEGE LINES ARE DELIBERATELY NOT PINNED HERE, AND THE FIRST VERSION OF THIS LIST
       * PINNED THEM. That draft asserted the `revoke ... from public, anon, authenticated` and the
       * `grant ... to service_role` for `claim_owner_notices` — reasoning, in a comment, that "no
       * mutation edits them".
       *
       * Two mutations edit exactly them. `p11k-worker-pair-client-reachable` and
       * `p11e-release-lever-granted-to-clients` both went from DETECTED to **HARNESS_FAILURE**: this
       * builder refused the mutated input, so the bundle never built, Postgres never saw the widened
       * grant, and nothing proved the SQL suite still catches a client-reachable worker routine.
       *
       * That is the sixth time this programme has put a build control in front of a runtime one
       * (11-K twice, 11-L four needles, 11-MB twice, and now here) — and the third time it happened
       * directly underneath a comment warning against it. Recorded rather than quietly corrected,
       * because a comment claiming a lesson is learned is worth less than the evidence that it was
       * not.
       *
       * The privilege layer keeps its own answer, where it can actually fail:
       *   · `release_safety_authorization.sql` §0 asserts `authenticated` holds no EXECUTE
       *   · `operator_console_authorization.sql` asserts the same and that `service_role` does
       * Both are executed against a real database, and both kill these mutations.
       */
    ],
    out: 'db/bundles/owner_notice_claim_visibility_bundle.sql',
  },
  process.argv.slice(2)
);
