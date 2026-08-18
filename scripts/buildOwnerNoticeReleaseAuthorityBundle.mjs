#!/usr/bin/env node
/**
 * Assemble PHASE 11-OC · PHASE D into ONE paste-ready artifact.
 *
 * ★ WHAT THIS ARTIFACT IS. The complete, atomic owner-notice release cutover: the canonical release
 * authority, both doors that consume it, the operator projection that must never disagree with them,
 * and the migration whose self-checks refuse the whole transaction if any of it is wrong. One
 * `begin; … commit;`. Pure SQL, no psql meta-commands.
 *
 * ★ THE PART ORDER IS INVERTED RELATIVE TO EVERY EARLIER PHASE, AND THAT IS THE POINT.
 *
 * Phases A and C put the migration FIRST, because each widened a constraint the routines below then
 * relied on. Phase D contains NO DDL — 0058 added every column and 0059 added the episode wall — so
 * its migration is an ASSERTION artifact, and every one of its assertions inspects the function
 * bodies. A migration cannot certify a cutover that has not been pasted yet.
 *
 *   1. release_safety.sql    — `owner_notice_release_authority`, plus both doors that consume it.
 *   2. operator_console.sql  — the case file, now reading the SAME authority for `window` and
 *                              `release_authority`. It must be re-pasted rather than left alone:
 *                              `create or replace` only replaces what the artifact carries, so a
 *                              bundle that shipped the new door without the projection would deploy
 *                              a console still computing the OLD clock beside a door using the new
 *                              one — the precise console/door disagreement this phase exists to make
 *                              impossible, introduced by the deployment of its own fix.
 *   3. migration 0060        — LAST. Certifies (1) and (2) took, proves the authority BEHAVIOURALLY
 *                              against a fixture that provably cannot survive its own subtransaction,
 *                              re-proves the R13 supersession from the catalog side, and prints the
 *                              cutover census.
 *
 * ★ THE R13 AMENDMENTS ARE NOT IN THIS BUNDLE, AND THAT IS DELIBERATE. Migrations 0056–0059 were
 * amended in their assertion layer only. They ship in the bundles that already carry them
 * (`operator_console_bundle`, `owner_notice_claim_visibility_bundle`,
 * `owner_notice_acceptance_bundle`, `owner_notice_reissue_bundle`), every one of which must be
 * REGENERATED in this commit — the generalized artifact-freshness audit fails otherwise. Copying
 * those migrations in here as well would paste four historical migrations a second time in a
 * different order, which is a bigger blast radius than the change warrants. §5 of 0060 covers the
 * gap from the other side: it asserts, at Phase D paste time, that no release-path routine still
 * demands the superseded literal.
 *
 * ★ CONTROLS PIN STRUCTURE, NEVER THE POLICY THE SQL SUITE TESTS.
 *
 * This programme has put a build control in front of a runtime control eight times now, each time
 * converting a mutation from DETECTED to HARNESS_FAILURE: the builder refused the mutated input, the
 * bundle never built, Postgres never saw the change, and nothing proved the suite could catch it.
 *
 * So there is deliberately NO needle here for:
 *   · the refusal ladder, any refusal code, or their order
 *   · `superseded_by is null`, `case_id`, `notice_accepted_at` or any clock expression
 *   · the strict `>` boundary
 *   · the two-person rule, the audit reason, or any audit metadata key
 *   · any grant or revoke line
 *
 * Every one of those is answered by `db/tests/release_safety_authorization.sql` §12 against a real
 * Postgres, by migration 0060 §4 by execution, and by the `p11ocd-*` mutations that must each be
 * DETECTED there. The controls below assert only that each part is WHOLE — that every routine a file
 * defines is present — because `create or replace` silently leaves a stale body deployed for any
 * routine the artifact forgot to carry, and that failure is invisible from the outside.
 *
 * Usage:  node scripts/buildOwnerNoticeReleaseAuthorityBundle.mjs [--out <path>]
 *         node scripts/buildOwnerNoticeReleaseAuthorityBundle.mjs --check
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root,
    script: 'scripts/buildOwnerNoticeReleaseAuthorityBundle.mjs',
    parts: [
      'db/functions/release_safety.sql',
      'db/functions/operator_console.sql',
      'db/migrations/0060_20260817_owner_notice_release_authority.sql',
    ],
    controls: [
      // Every routine each file defines must be present. `create or replace` only replaces what the
      // artifact carries; a missing one silently leaves the deployed body in place, which for
      // `authorize_release` would mean shipping the authority and NOT the door that consumes it.
      ['db/functions/release_safety.sql',
        'create or replace function public.owner_notice_release_authority'],
      ['db/functions/release_safety.sql',
        'create or replace function public.challenge_window_duration'],
      ['db/functions/release_safety.sql',
        'create or replace function public.dispatch_owner_safety_notice'],
      ['db/functions/release_safety.sql',
        'create or replace function public.begin_challenge_window'],
      ['db/functions/release_safety.sql', 'create or replace function public.authorize_release'],
      ['db/functions/release_safety.sql',
        'create or replace function public.challenge_death_process'],
      ['db/functions/release_safety.sql',
        'create or replace function public.get_owner_safety_status'],
      ['db/functions/operator_console.sql',
        'create or replace function public.admin_list_death_verification_cases'],
      ['db/functions/operator_console.sql',
        'create or replace function public.admin_get_death_verification_case'],
      // The migration's own certification must ship with it, or the artifact loses the evidence that
      // this paste is a complete cutover rather than half of one.
      ['db/migrations/0060_20260817_owner_notice_release_authority.sql',
        'owner_notice_release_authority'],
      ['db/migrations/0060_20260817_owner_notice_release_authority.sql',
        'aw_0060_selfcheck_rollback'],
    ],
    out: 'db/bundles/owner_notice_release_authority_bundle.sql',
  },
  process.argv.slice(2)
);
