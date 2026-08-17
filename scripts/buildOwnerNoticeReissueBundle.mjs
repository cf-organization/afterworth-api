#!/usr/bin/env node
/**
 * Assemble PHASE 11-OC · PHASE C into ONE paste-ready artifact.
 *
 * ★ WHAT THIS ARTIFACT IS, AND WHAT IT DELIBERATELY IS NOT.
 *
 * It is the RECOVERY half of Phase 11-OC: the re-notice kind, the per-episode one-current-generation
 * wall, the operator door that appends a generation, and the two surfaces that have to know about it
 * (the readiness census and the operator case file). It changes NO release behaviour, and migration
 * 0059 asserts that inversion about itself by reading `authorize_release` and requiring the
 * pre-Phase-D predicate to still be there.
 *
 * The release door is re-anchored in PHASE D (migration 0060), which is a separate artifact and a
 * separate decision. Phase C ships FIRST on operability grounds rather than on today's legacy count:
 * Phase D creates new legitimate refusal states (`failedPermanent`, `outcomeUncertain`) that a
 * running system reaches on its own, and without a remedy the first post-cutover provider failure
 * produces a permanently unreleasable estate whose only recovery is hand-written SQL against a
 * safety table.
 *
 * ★ WHY IT CARRIES `outbox_safety.sql` AND `operator_console.sql` WHOLE, AND WHY IT MUST.
 *
 * Both changed. `create or replace` only replaces what the artifact contains, so a bundle that
 * carried the new routine but not the two files that read it would deploy a re-notice mechanism
 * INVISIBLE to the readiness census and to the console — the remedy working while every instrument
 * reported it had not. The controls below assert every routine each file defines is present, so a
 * part that had lost one cannot silently leave a stale body deployed.
 *
 * ★ THE PART ORDER IS LOAD-BEARING.
 *
 *   1. migration 0059 — widens the `notice_kind` CHECK and replaces the episode index. The routine
 *      below writes a row with the new kind; pasting it first would leave a window in which that
 *      write is refused by a constraint.
 *   2. owner_notice_reissue.sql — defines `owner_notice_episode_kinds()`, which (3) and (4) call.
 *      plpgsql resolves at runtime so this is not a load-time dependency, but it IS the order an
 *      operator wants: the vocabulary exists before its consumers are replaced.
 *   3. outbox_safety.sql — the readiness census, now reading the episode kind SET.
 *   4. operator_console.sql — the case file, now projecting the episode and the re-notice verdict.
 *
 * ★ CONTROLS PIN STRUCTURE, NEVER THE POLICY THE SQL SUITE TESTS.
 *
 * This programme has put a build control in front of a runtime control seven times now (11-K twice,
 * 11-L four needles, 11-MB twice, OB-1, and Phase A under a comment warning against it), each time
 * converting a mutation from DETECTED to HARNESS_FAILURE: the builder refused the mutated input, the
 * bundle never built, Postgres never saw the change, and nothing proved the suite could catch it.
 *
 * So there is deliberately NO needle here for:
 *   · the eligibility ladder, any refusal code, or the derived reissue_reason
 *   · the lock order, the supersession write, or the fields the successor resets
 *   · the episode kind SET in the census or in the projection
 *   · the audit action name or any of its metadata
 *   · any grant or revoke line
 *
 * Every one of those is answered by `db/tests/release_safety_authorization.sql` §11 and
 * `db/tests/operator_console_authorization.sql` against a real Postgres, and by the `p11c-*`
 * mutations that must each be DETECTED there.
 *
 * Usage:  node scripts/buildOwnerNoticeReissueBundle.mjs [--out <path>]
 *         node scripts/buildOwnerNoticeReissueBundle.mjs --check
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root,
    script: 'scripts/buildOwnerNoticeReissueBundle.mjs',
    parts: [
      'db/migrations/0059_20260817_owner_notice_reissue.sql',
      'db/functions/owner_notice_reissue.sql',
      'db/functions/outbox_safety.sql',
      'db/functions/operator_console.sql',
    ],
    controls: [
      // The two schema changes the whole phase rests on. Absent, a re-notice is unwritable and the
      // episode wall is keyed on the wrong thing.
      ['db/migrations/0059_20260817_owner_notice_reissue.sql', 'window_renotice'],
      ['db/migrations/0059_20260817_owner_notice_reissue.sql',
        'owner_notice_outbox_one_current_per_episode_idx'],
      // The migration's own inversion proof must ship with it, or the artifact loses its evidence
      // that this paste did not change when a release may proceed.
      ['db/migrations/0059_20260817_owner_notice_reissue.sql', 'authorize_release'],
      // Every routine each file defines must be present — `create or replace` only replaces what the
      // artifact carries, so a missing one silently leaves the deployed body in place.
      ['db/functions/owner_notice_reissue.sql',
        'create or replace function public.owner_notice_episode_kinds'],
      ['db/functions/owner_notice_reissue.sql',
        'create or replace function public.owner_notice_reissue_kind'],
      ['db/functions/owner_notice_reissue.sql',
        'create or replace function public.owner_notice_reissue_assessment'],
      ['db/functions/owner_notice_reissue.sql',
        'create or replace function public.reissue_owner_safety_notice'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.claim_owner_notices'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.record_owner_notice_outcome'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.purge_outbox_rows'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.owner_notice_census'],
      ['db/functions/outbox_safety.sql',
        'create or replace function public.owner_notice_release_readiness_census'],
      ['db/functions/operator_console.sql',
        'create or replace function public.admin_list_death_verification_cases'],
      ['db/functions/operator_console.sql',
        'create or replace function public.admin_get_death_verification_case'],
    ],
    out: 'db/bundles/owner_notice_reissue_bundle.sql',
  },
  process.argv.slice(2)
);
