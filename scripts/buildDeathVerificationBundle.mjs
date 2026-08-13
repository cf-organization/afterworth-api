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
      // ★ PHASE 11-E: the seam vocabulary and the EMPTY duration table must exist before
      // `challenge_window_duration` (language sql) resolves its body at CREATE time below.
      'db/migrations/0054_20260812_challenge_window_release_seam.sql',
      'db/migrations/0055_20260812_release_authorization.sql',
      'db/functions/estate_lifecycle_state.sql',
      'db/functions/death_verification.sql',
      // ★ LAST: the safety routines (plpgsql; they call the transition map and the emitter at
      // execution time). Applying this bundle is what makes the owner challenge AVAILABLE; it
      // makes release REACHABLE by nothing — release_estate is client-revoked, has no caller, and
      // refuses until an operator explicitly configures the window duration.
      'db/functions/release_safety.sql',
      // ★ PHASE 11-F: the outbox age gate, stale protection and audited purge. Loaded after
      // the safety routines because `owner_notice_age_gate` derives from the window duration.
      'db/functions/outbox_safety.sql',
    ],
    controls: [
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'create table if not exists public.estate_lifecycle'],
      ['db/functions/estate_lifecycle_state.sql', 'create or replace function public.estate_lifecycle_state'],
      ['db/functions/estate_lifecycle_state.sql',
        'revoke execute on function public.estate_lifecycle_state(uuid) from public, anon, authenticated'],
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'create table if not exists public.death_verification_cases'],
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'create table if not exists public.death_verification_evidence'],
      // The migration's own self-check must ship with it — the guard that a CHECK which silently
      // failed to apply raises at paste time rather than reading as success. (11-E: the check pins
      // the FOUNDATION states; the six-state vocabulary and its own guard live in 0054 below.)
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'missing an 11-C foundation state'],
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
      /**
       * ★ PHASE 11-E: THE SAFETY SEAM SHIPS WHOLE — AND THESE CONTROLS PIN STRUCTURE, NEVER POLICY
       * TEXT THE RUNTIME LAYERS ALREADY TEST.
       *
       * This distinction was learned the hard way in 11-D and re-learned here by a smoke test: a
       * build needle quoting the exact guard (`now() > … + v_duration`, the notification-required
       * raise, the release revoke) makes the BUILD refuse a mutation of that guard — so the bundler
       * testifies INSTEAD of the instrument written for it, and nothing ever proves the SQL suite
       * or the structural audit would have caught the weakening. One defensive layer hiding whether
       * the layer beneath it works is the Stage-17 shape, and it is exactly what these three
       * removed needles were doing.
       *
       * So the controls below assert that the ARTIFACT CARRIES THE SEAM — the vocabulary, the map
       * edges, the four routines. The guards themselves are pinned where they can be exercised:
       *   · the strict boundary, the notice precondition, the release privilege and the owner gate →
       *     `db/tests/release_safety_authorization.sql` (executed) and
       *     `test/deathVerificationFoundation.test.ts` (structural), both mutation-proven.
       */
      ['db/migrations/0054_20260812_challenge_window_release_seam.sql', "'challenge_window',"],
      ['db/migrations/0054_20260812_challenge_window_release_seam.sql',
        'create table if not exists public.release_safety_policy'],
      ['db/functions/death_verification.sql', "(v_from = 'challenge_window'           and p_to = 'challenge_halted')"],
      ['db/functions/death_verification.sql', "(v_from = 'challenge_window'           and p_to = 'released')"],
      ['db/functions/release_safety.sql', 'create or replace function public.begin_challenge_window'],
      ['db/functions/release_safety.sql', 'create or replace function public.challenge_death_process'],
      ['db/functions/release_safety.sql', 'create or replace function public.authorize_release'],
      ['db/functions/release_safety.sql', 'create or replace function public.dispatch_owner_safety_notice'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.claim_owner_notices'],
      ['db/functions/outbox_safety.sql', 'create or replace function public.purge_outbox_rows'],
      ['db/migrations/0055_20260812_release_authorization.sql',
        'create table if not exists public.owner_notice_outbox'],
      ['db/migrations/0055_20260812_release_authorization.sql',
        'create table if not exists public.release_authorizations'],
      ['db/functions/release_safety.sql', 'create or replace function public.get_owner_safety_status'],
      ['db/functions/release_safety.sql', 'create or replace function public.challenge_window_duration'],
    ],
    out: 'db/bundles/death_verification_bundle.sql',
  },
  process.argv.slice(2)
);
