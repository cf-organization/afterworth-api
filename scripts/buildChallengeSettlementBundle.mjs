#!/usr/bin/env node
/**
 * Assemble the Phase 11-NR remediation of FINDING 4 into ONE paste-ready artifact.
 *
 * ★ WHAT IT FIXES. `challenge_death_process` settled the death-verification case with
 * `where estate_id = p_estate and status = 'open'`. That is the case status at exactly ONE of the
 * four lifecycle states the owner challenge is reachable from. On the canonical operator-driven path
 * — initiate → verify → dispatch → window → challenge — the case is `verified`, so the UPDATE matched
 * no row, its `returning initiated_by` yielded NULL, and the Phase 11-L halt notification was never
 * emitted to anybody. The estate reached `challenge_halted` while its case row still read `verified`.
 *
 * ★ IT IS NOT HYPOTHETICAL. The Branch A production fire drill (2026-08-15) measured it on a real
 * estate: lifecycle `challenge_halted`, case `verified`, `updated_at` byte-identical to `decided_at`,
 * zero fiduciary notifications against a positive control of two owner notifications, and the settled
 * case still answering the operator console's `verified` filter while invisible to `halted`.
 *
 * ★ ONE PART, DELIBERATELY — AND ONE FILE SMALLER THAN THE ARTIFACT THAT ALREADY CARRIES IT.
 * `halt_notification_bundle.sql` also ships this file, but it re-pastes
 * `lifecycle_notification_rpcs.sql` alongside it. Nothing in the notification catalog changed here,
 * and this repository has already come within one paste of regressing production by re-applying a
 * source file that was behind the deployed body (`create_asset_grant`, Phase 10-E). So the
 * remediation ships exactly the file that changed and nothing else: the deployment diff and the
 * blast radius are the same set.
 *
 * ★ WHAT IT DELIBERATELY DOES NOT CARRY. No migration, no table, no constraint, no grant beyond the
 * revoke/grant pair each routine already declares for itself. `'halted'` is NOT new vocabulary — it
 * has been in `death_verification_cases_status_check` since migration 0054, added for this exact
 * transition — so there is no DDL to ship. The settlement set is widened from `('open')` to
 * `('open','verified')` inside one already-deployed routine body.
 *
 * ★ RE-PASTE SAFE. Every statement is `create or replace` / `revoke` / `grant` / `comment on`. Pasting
 * it twice is indistinguishable from pasting it once.
 *
 * ★ CONTROLS PIN STRUCTURE, NEVER THE POLICY THE SQL SUITE TESTS. This list contains no needle for
 * the settlement predicate, the `set status = 'halted'` assignment, the idempotency guard or the
 * owner gate. That is the `p11b-legacy-fused` lesson, which this programme has now paid for four
 * separate times: a control tight enough to make the BUILD refuse a mutation means the mutation can
 * only ever be caught here, and nothing proves the runtime layer works at all. Every behavioural
 * question is answered by `db/tests/release_safety_authorization.sql` §8, executed against a real
 * Postgres, and by the five `p11nr-*` mutations that must each be DETECTED there:
 *   · settlement narrowed back to 'open'  → §8 anchors on a VERIFIED case; §7 cannot see it
 *   · settlement widened to every row     → §8 carries a REJECTED decoy that must survive
 *   · recipient from a later SELECT       → §8's decoy has a DIFFERENT initiator
 *   · case never settled                  → §8 asserts the operator queue through the real RPC
 *   · replay guard neutered               → §2/§7/§8 all replay the challenge
 *
 * Usage:  node scripts/buildChallengeSettlementBundle.mjs [--out <path>]
 *         node scripts/buildChallengeSettlementBundle.mjs --check     (verify inputs, emit nothing)
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root,
    script: 'scripts/buildChallengeSettlementBundle.mjs',
    parts: ['db/functions/release_safety.sql'],
    /**
     * ★ THE FILE MUST SHIP WHOLE, AND THAT IS A REAL COMPLETENESS CONTROL RATHER THAN CEREMONY.
     * `create or replace` only replaces the routines the artifact actually contains. A part that had
     * lost one of these six would leave the DEPLOYED body of that routine in place, silently, while
     * the paste reported success — the half-applied state every verifier here exists to detect. So
     * the presence of each signature is asserted before a byte is written.
     */
    controls: [
      ['db/functions/release_safety.sql', 'create or replace function public.challenge_window_duration'],
      ['db/functions/release_safety.sql', 'create or replace function public.dispatch_owner_safety_notice'],
      ['db/functions/release_safety.sql', 'create or replace function public.begin_challenge_window'],
      ['db/functions/release_safety.sql', 'create or replace function public.authorize_release'],
      ['db/functions/release_safety.sql', 'create or replace function public.challenge_death_process'],
      ['db/functions/release_safety.sql', 'create or replace function public.get_owner_safety_status'],
      // The recipient mechanism must exist at all — a build with no initiator capture is not this fix.
      ['db/functions/release_safety.sql', 'v_initiator'],
      // Privilege statements: the artifact either carries them or it does not, and no mutation edits
      // them. The SQL suite asserts the anon/authenticated layer independently regardless.
      ['db/functions/release_safety.sql',
        'revoke execute on function public.challenge_death_process(uuid) from public, anon;'],
      ['db/functions/release_safety.sql',
        'grant  execute on function public.challenge_death_process(uuid) to authenticated;'],
    ],
    out: 'db/bundles/challenge_settlement_bundle.sql',
  },
  process.argv.slice(2)
);
