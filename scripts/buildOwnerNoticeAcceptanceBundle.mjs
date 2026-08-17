#!/usr/bin/env node
/**
 * Assemble PHASE 11-OC · PHASE A into ONE paste-ready artifact.
 *
 * ★ WHAT THIS ARTIFACT IS, AND WHAT IT DELIBERATELY IS NOT.
 *
 * It is the ADDITIVE half of Phase 11-OC: the acceptance fact, the case-episode columns, the walls
 * that keep them honest, the acceptance stamp, the episode key on dispatch, and the observation
 * surface (two censuses). It changes NO release behaviour, and migration 0058 asserts that inversion
 * about itself by reading `authorize_release` and requiring the pre-Phase-D predicate to still be
 * there.
 *
 * The release door is re-anchored in PHASE D (migration 0060), which is a separate artifact and a
 * separate decision — gated on the blast-radius count this one produces. Pasting Phase A tells you
 * how many live estates Phase D would block; pasting them together would deploy the cutover before
 * anyone had that number, which is the whole reason the rollout is staged.
 *
 * ★ WHY THE ACCEPTANCE STAMP SHIPS HERE RATHER THAN WITH THE POLICY THAT READS IT. Nothing reads
 * `notice_accepted_at` until Phase D, so stamping it now is observational. It also means every notice
 * the provider accepts between Phase A and Phase D accumulates a REAL acceptance fact, so the blocked
 * population shrinks by ordinary operation instead of by remediation. The same argument forces
 * `case_id` to ship here: without it new dispatches keep landing with no episode, and the Phase B
 * census would be measuring a population that cannot stop growing.
 *
 * ★ IT CARRIES `outbox_safety.sql` AND `release_safety.sql` WHOLE. `create or replace` only replaces
 * what the artifact contains, so the file is the unit the repository maintains. The controls below
 * assert every routine each file defines is present, so a part that had lost one cannot silently
 * leave a stale body deployed.
 *
 * ★ CONTROLS PIN STRUCTURE, NEVER THE POLICY THE SQL SUITE TESTS.
 *
 * This programme has now put a build control in front of a runtime control SIX times (11-K twice,
 * 11-L four needles, 11-MB twice, and OB-1 under a comment warning against it), each time converting
 * a mutation from DETECTED to HARNESS_FAILURE: the builder refused the mutated input, the bundle never
 * built, Postgres never saw the change, and nothing proved the suite could catch it.
 *
 * So there is deliberately NO needle here for:
 *   · the acceptance stamp expression or the branch it keys on
 *   · the episode wall, the trigger, or the partial unique index predicate
 *   · the census bucket vocabulary or its reconciliation
 *   · any grant or revoke line
 *
 * Every one of those is answered by `db/tests/release_safety_authorization.sql` §10 against a real
 * Postgres, and by the `p11oc-*` mutations that must each be DETECTED there.
 *
 * Usage:  node scripts/buildOwnerNoticeAcceptanceBundle.mjs [--out <path>]
 *         node scripts/buildOwnerNoticeAcceptanceBundle.mjs --check
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root,
    script: 'scripts/buildOwnerNoticeAcceptanceBundle.mjs',
    // ★ MIGRATION FIRST, AND THAT ORDER IS REQUIRED RATHER THAN CONVENTIONAL. The migration creates
    // the trigger function and the trigger that refuses an owner-notice INSERT with no case_id.
    // `dispatch_owner_safety_notice` in `release_safety.sql` is the routine that satisfies it. Pasting
    // the routines first would leave a window in which the columns they write do not exist.
    parts: [
      'db/migrations/0058_20260817_owner_notice_acceptance_episode.sql',
      'db/functions/outbox_safety.sql',
      'db/functions/release_safety.sql',
    ],
    controls: [
      // The three columns the whole phase rests on. Absent, there is no fact and no episode.
      ['db/migrations/0058_20260817_owner_notice_acceptance_episode.sql',
        'add column if not exists notice_accepted_at timestamptz'],
      ['db/migrations/0058_20260817_owner_notice_acceptance_episode.sql',
        'add column if not exists case_id uuid'],
      ['db/migrations/0058_20260817_owner_notice_acceptance_episode.sql',
        'add column if not exists superseded_by uuid'],
      // The migration's own inversion proof must ship with it, or the artifact loses its evidence
      // that this paste did not change when a release may proceed.
      ['db/migrations/0058_20260817_owner_notice_acceptance_episode.sql', 'authorize_release'],
      // Every routine each file defines must be present — `create or replace` only replaces what the
      // artifact carries, so a missing one silently leaves the deployed body in place.
      ['db/functions/outbox_safety.sql', 'create or replace function public.claim_owner_notices'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.record_owner_notice_outcome'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.purge_outbox_rows'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.owner_notice_census'],
      ['db/functions/outbox_safety.sql',
        'create or replace function public.owner_notice_release_readiness_census'],
      ['db/functions/release_safety.sql', 'create or replace function public.dispatch_owner_safety_notice'],
      ['db/functions/release_safety.sql', 'create or replace function public.begin_challenge_window'],
      ['db/functions/release_safety.sql', 'create or replace function public.authorize_release'],
      ['db/functions/release_safety.sql', 'create or replace function public.challenge_death_process'],
      ['db/functions/release_safety.sql', 'create or replace function public.get_owner_safety_status'],
    ],
    out: 'db/bundles/owner_notice_acceptance_bundle.sql',
  },
  process.argv.slice(2)
);
