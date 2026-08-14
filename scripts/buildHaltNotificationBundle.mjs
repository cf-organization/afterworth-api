#!/usr/bin/env node
/**
 * Assemble the Phase 11-L halt notification into ONE paste-ready artifact: the notification catalog
 * gaining `death_process.halted`, and the owner-challenge transition gaining the emission.
 *
 * The assembly lives in `scripts/lib/sqlBundle.mjs`, shared with the other bundles. This file is the
 * MANIFEST — what goes in, in what order, and what must be true of the inputs.
 *
 * ★ APPLY ORDER, AND WHY IT IS THIS ONE.
 *
 *   1 · `lifecycle_notification_rpcs.sql` FIRST — the catalog. `emit_lifecycle_notification` looks
 *       the event up at EXECUTION time and treats an unknown event as a refusal to emit (a warning
 *       and a null, never a generic fallback). So pasting the emitter first would not break: it
 *       would silently emit NOTHING for every halt in between, which is the failure this phase
 *       exists to remove. Catalog first means the window does not exist.
 *
 *   2 · `release_safety.sql` SECOND — the whole release-safety module, re-pasted in full because
 *       `create or replace` cannot patch a body. It carries `challenge_death_process` with the new
 *       emission, and re-asserts its own revoke/grant pair.
 *
 * ★ NO MIGRATION, AND THAT IS A REAL PROPERTY RATHER THAN AN OMISSION. This phase adds no column, no
 * constraint value and no grant. `death_verification_cases.status` already admits `'halted'` —
 * migration 0054 widened it and self-checks the widening — and `claimUpdate` is already in the RN
 * client's known-category set. Nothing here needs DDL, so nothing here ships DDL.
 *
 * ★ IT CARRIES NO NEW AUTHORITY. Nothing in this artifact decides a case, moves a verification
 * level, dispatches a notice, opens a window, or releases anything. It adds one catalog row and one
 * `perform emit_lifecycle_notification(...)` inside a transition that already existed. The emitter
 * itself stays INTERNAL — its execute is revoked from public/authenticated by migration 0050, and
 * `create or replace` on an unchanged signature preserves that.
 *
 * ★ WHAT IT DELIBERATELY DOES NOT CARRY, for the standing reason the other bundles state:
 * `emit_notification`, `apply_estate_lifecycle_transition`, `write_audit`, `is_estate_owner` and the
 * privilege statements in 0050 are all deployed long before this phase and reconciled by their own
 * proofs. Bundling an unreconciled SECURITY DEFINER body into a paste-ready artifact is how
 * production nearly regressed once already (`create_asset_grant`, Phase 10-E).
 *
 * Usage:  node scripts/buildHaltNotificationBundle.mjs [--out <path>]
 *         node scripts/buildHaltNotificationBundle.mjs --check     (verify inputs, emit nothing)
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root,
    script: 'scripts/buildHaltNotificationBundle.mjs',
    parts: [
      'db/functions/lifecycle_notification_rpcs.sql',
      'db/functions/release_safety.sql',
    ],
    /**
     * ★ CONTROLS THAT FAIL IF THE PHASE IS ABSENT — AND THAT DELIBERATELY DO NOT PIN WHAT A
     * MUTATION WOULD CHANGE.
     *
     * This is the `p11b-legacy-fused-becomes-writable` lesson, which 11-K paid for twice: a control
     * pinned so tightly that the BUILD refuses a mutation means the mutation can only ever be caught
     * HERE, and nothing proves the runtime layer works at all. One defensive layer ends up hiding
     * whether the second one fires.
     *
     * ★ FOUR NEEDLES WERE REMOVED FROM THIS LIST AFTER THEY KILLED THEIR OWN MUTATIONS AT BUILD
     * TIME. The first draft pinned the exact body prose and the event name inside
     * `release_safety.sql`; four of the ten 11-L mutations then reported HARNESS_FAILURE instead of
     * DETECTED, because the build refused the edit before Postgres ever saw it. Nothing proved the
     * SQL suite could catch a leaking copy string or a hand-composed message — the build was
     * standing in front of the runtime and taking the credit.
     *
     * The division that replaced it:
     *   BUILD answers "is the phase in this artifact at all" — the event key and its category.
     *   RUNTIME answers everything about behaviour, in `release_safety_authorization.sql` §7:
     *     · prose disclosure     → §7 scans the emitted body for channel, reason, evidence, ids
     *     · catalog vs freeform  → §7 compares the emitted row against notification_event_copy()
     *     · wrong recipient      → §7 asserts the initiator, and only the initiator, holds the row
     *     · owner excluded       → §7 asserts it on an estate whose owner IS the initiator
     *     · deep link absent     → §7 asserts action_deep_link is null
     *     · estate scope         → §7 asserts an unrelated estate's initiator gets nothing
     */
    controls: [
      // Artifact completeness: the catalog must carry the new event. A copy or recipient mutation
      // leaves this key untouched, so it discriminates absence without shadowing the runtime.
      ['db/functions/lifecycle_notification_rpcs.sql', "('death_process.halted',"],
      // The category must be one the RN client already knows; `other` would render "Account update".
      ['db/functions/lifecycle_notification_rpcs.sql', "'claimUpdate',"],
      // The mechanism must exist at all — a build with no initiator capture is not this phase.
      ['db/functions/release_safety.sql', 'v_initiator'],
      // Standing guard, not new: the challenge must remain owner-only and idempotent. If either
      // disappeared, this artifact would ship a notification attached to a weakened halt.
      ['db/functions/release_safety.sql', "if v_state = 'challenge_halted' then"],
      ['db/functions/release_safety.sql', 'if not public.is_estate_owner(p_estate) then'],
    ],
    out: 'db/bundles/halt_notification_bundle.sql',
  },
  process.argv.slice(2)
);
