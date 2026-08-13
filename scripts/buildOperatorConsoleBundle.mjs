#!/usr/bin/env node
/**
 * Assemble the Phase 11-K operator control plane into ONE paste-ready artifact for the Supabase SQL
 * editor: migration 0056 (the sixth outbox status), the outbox module that gains the delivery
 * recorder and the worker grant, and the two narrow operator projections.
 *
 * The assembly lives in `scripts/lib/sqlBundle.mjs`, shared with the other five bundles. This file
 * is the MANIFEST — what goes in, in what order, and what must be true of the inputs.
 *
 * ★ APPLY ORDER, AND WHY IT IS THIS ONE.
 *
 *   1 · 0056 FIRST. It widens the `owner_notice_outbox` status CHECK. `record_owner_notice_outcome`
 *       below writes `'outcomeUncertain'`, which the un-widened constraint refuses — so the
 *       function must not exist before the constraint admits the value it produces. Pasting the
 *       function first would leave a routine that raises `check_violation` on its most important
 *       branch, and only on that branch, which is the class of failure nobody notices until an
 *       owner is not warned.
 *
 *   2 · `outbox_safety.sql` SECOND. It carries the whole outbox module — the age gate, the claim
 *       routine (now granted to `service_role`), the new outcome recorder, the purge and the
 *       census. It is re-pasted in full rather than patched: `create or replace` cannot patch a
 *       body, and a bundle that carried only the NEW function would leave the census without its
 *       `uncertain` key while claiming the phase had shipped.
 *
 *   3 · `operator_console.sql` LAST. Both projections call `required_verification_level`,
 *       `estate_owner_user_id`, `challenge_window_duration` and `admin_require_gate` at EXECUTION
 *       time (plpgsql), so they have no load-time dependency on anything here — but they read
 *       `owner_notice_outbox` columns whose vocabulary 0056 defines, and shipping the reader before
 *       the vocabulary would be a bundle with a broken middle.
 *
 * ★ WHAT THIS BUNDLE DELIBERATELY DOES NOT CARRY, for the standing reason the other five state:
 * `admin_require_gate`, `is_admin`, `require_aal2`, `write_audit`, `required_verification_level`,
 * `estate_owner_user_id` and `challenge_window_duration` are all deployed long before this phase and
 * reconciled by their own proofs. Bundling an unreconciled SECURITY DEFINER body into a paste-ready
 * artifact is how production nearly regressed once already (`create_asset_grant`, Phase 10-E).
 *
 * ★ AND IT CARRIES NO NEW AUTHORITY. Nothing in this artifact transitions a lifecycle, decides a
 * case, moves a verification level, dispatches a notice, opens a window, or releases anything. It
 * adds one service-role recorder, one service-role grant, and two admin-gated READS.
 *
 * Usage:  node scripts/buildOperatorConsoleBundle.mjs [--out <path>]
 *         node scripts/buildOperatorConsoleBundle.mjs --check     (verify inputs, emit nothing)
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root,
    script: 'scripts/buildOperatorConsoleBundle.mjs',
    parts: [
      'db/migrations/0056_20260813_operator_console_foundation.sql',
      'db/functions/outbox_safety.sql',
      'db/functions/operator_console.sql',
    ],
    /**
     * ★ CONTROLS THAT FAIL IF THE PHASE IS ABSENT, not controls that confirm a file is a file.
     *
     * Each names something that did not exist before 11-K, or something whose removal would
     * silently un-do it: the sixth status in the constraint, the worker grant without which no
     * drain can claim, the recorder without which every claimed row strands, the census key that
     * keeps the totals reconcilable, both projections, and — the load-bearing one — the ABSENCE
     * proof that the case file never selects the owner's address.
     */
    controls: [
      ['db/migrations/0056_20260813_operator_console_foundation.sql', "'outcomeUncertain',"],
      // The migration must keep its own apply-time guard: a migration that lost its self-check
      // cannot ship (the 11-B precedent — do not let the build mask the runtime layer).
      ['db/migrations/0056_20260813_operator_console_foundation.sql', '0056 FAILED: outcomeUncertain is not an admitted'],
      // ★ THE NEEDLE STOPS SHORT OF THE ROLE LIST AND THE SEMICOLON, DELIBERATELY — the
      // `p11b-legacy-fused-becomes-writable` lesson applied to a grant. Pinning the exact line
      // `… to service_role;` would make the BUILD refuse any mutation that widens the grant, so
      // the mutation could only ever be caught here and nothing would prove the runtime layer
      // fires. One defensive layer would be hiding whether the second works at all. This control
      // still fails if the grant is absent entirely; a WIDENED grant is caught where it should be
      // — at runtime, by `operator_console_authorization.sql` §0, which asserts
      // has_function_privilege('authenticated', …) is false.
      ['db/functions/outbox_safety.sql', 'grant  execute on function public.claim_owner_notices(int) to service_role'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.record_owner_notice_outcome('],
      ['db/functions/outbox_safety.sql', 'grant  execute on function public.record_owner_notice_outcome(uuid, text, text) to service_role;'],
      ['db/functions/outbox_safety.sql', "'uncertain', (select count(*) from rows r where r.status = 'outcomeUncertain')"],
      ['db/functions/operator_console.sql', 'create or replace function public.admin_list_death_verification_cases('],
      ['db/functions/operator_console.sql', 'create or replace function public.admin_get_death_verification_case(p_case uuid)'],
      ['db/functions/operator_console.sql', 'owner_channel_resolvable'],
      // Same discipline: the KEY must be present (a projection that dropped it would break the
      // console's two-person messaging), but its EXPRESSION is left to the runtime assertion in
      // §4, which reads the same case as two different admins and requires the answer to flip.
      ['db/functions/operator_console.sql', "'viewer_is_reviewer_a'"],
    ],
    out: 'db/bundles/operator_console_bundle.sql',
  },
  process.argv.slice(2)
);
