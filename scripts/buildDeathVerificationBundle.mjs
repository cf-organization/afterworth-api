#!/usr/bin/env node
/**
 * Assemble the Phase 11-C death-verification foundation into ONE paste-ready artifact for the
 * Supabase SQL editor: migration 0052 (lifecycle + case + evidence tables) followed by the
 * routines that are their only writers.
 *
 * The assembly lives in `scripts/lib/sqlBundle.mjs`, shared with the other three bundles. This
 * file is the MANIFEST — what goes in, in what order, and what must be true of the inputs.
 *
 * ★ WHAT THIS BUNDLE DELIBERATELY DOES NOT CARRY.
 *
 *   · `required_verification_level` / the 0026/0027 policy engine. The routines call it at
 *     EXECUTION time (plpgsql), and production has carried it since 2026-07-16 (verified live —
 *     `docs/verification-policy-proof.md`). Bundling an unreconciled SECURITY DEFINER body into a
 *     paste-ready artifact is how production nearly regressed once already (`create_asset_grant`,
 *     Phase 10-E); the 11-B ledger says promote it only WITH a source↔deployment equivalence
 *     check, and that check does not exist yet. Loaded directly by the SQL suite for coverage
 *     instead (`SQL_DIRECT_PARTS`).
 *   · `admin_require_gate` / `is_admin` / `require_aal2` / `write_audit` / `is_estate_executor` —
 *     same posture, same reason: deployed long before this phase, reconciled by their own proofs.
 *
 * APPLY ORDER (operator): the standing Phase 11-B rule is unchanged — `release_conditions_bundle.sql`
 * is pasted FIRST before any other bundle re-application. This bundle has no load-time dependency
 * on the other three (every function here is plpgsql except `estate_lifecycle_state`, which reads
 * only the table 0052 creates above it), so it applies LAST, after the existing three, on a
 * database that already carries migrations 0019/0026/0027.
 *
 * ★ SINCE PHASE 11-D `estate_lifecycle_state` LIVES IN ITS OWN SOURCE FILE and ships FIRST with the
 * release-conditions bundle (the disclosure evaluators resolve it at read time, so the first pasted
 * artifact must carry the seam). It is carried here TOO — same file, idempotent — because the
 * routines below call it at execution time and this artifact's header promises single-paste
 * runnability.
 *
 * Usage:  node scripts/buildDeathVerificationBundle.mjs [--out <path>]
 *         node scripts/buildDeathVerificationBundle.mjs --check     (verify inputs, emit nothing)
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root: ROOT,
    script: 'buildDeathVerificationBundle.mjs',
    // ★ ORDER IS LOAD-BEARING: 0052 creates the tables; `estate_lifecycle_state` is `language sql`
    // and resolves its body at CREATE time, so the table must already exist when the reader loads,
    // and the reader must exist before anything calls the routines that consult it.
    parts: [
      'db/migrations/0052_20260812_death_verification_foundation.sql',
      'db/functions/estate_lifecycle_state.sql',
      'db/functions/death_verification.sql',
    ],
    controls: [
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'create table if not exists public.estate_lifecycle'],
      ['db/functions/estate_lifecycle_state.sql', 'create or replace function public.estate_lifecycle_state'],
      ['db/functions/estate_lifecycle_state.sql',
        'revoke execute on function public.estate_lifecycle_state(uuid) from public, anon, authenticated'],
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'create table if not exists public.death_verification_cases'],
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'create table if not exists public.death_verification_evidence'],
      // The migration's own self-check must ship with it — the guard that a CHECK which silently
      // failed to apply raises at paste time rather than reading as success.
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'a release-shaped state is storable'],
      ['db/functions/death_verification.sql', 'create or replace function public.initiate_death_verification_case'],
      ['db/functions/death_verification.sql', 'create or replace function public.attach_death_verification_evidence'],
      ['db/functions/death_verification.sql', 'create or replace function public.admin_review_death_evidence'],
      ['db/functions/death_verification.sql', 'create or replace function public.admin_set_attained_verification_level'],
      ['db/functions/death_verification.sql', 'create or replace function public.admin_decide_death_verification_case'],
      ['db/functions/death_verification.sql', 'create or replace function public.apply_estate_lifecycle_transition'],
      // ★ THE H2 ENFORCEMENT MUST SHIP. A bundle carrying a decision routine without the
      // attained-vs-required refusal would deploy death verification with an advisory policy
      // engine — the exact defect (H2) this phase exists to close.
      ['db/functions/death_verification.sql', 'verification_level_insufficient'],
      // ★ THE GATES MUST SHIP. The designee gate and the admin gate are what make these routines
      // safe to expose to `authenticated`.
      ['db/functions/death_verification.sql', 'public.is_estate_executor(p_estate, v_uid)'],
      ['db/functions/death_verification.sql', 'public.admin_require_gate()'],
    ],
    out: 'db/bundles/death_verification_bundle.sql',
  },
  process.argv.slice(2)
);
