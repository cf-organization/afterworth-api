#!/usr/bin/env node
/**
 * Assemble the release-condition engine (Phase 11-B, lifecycle-aware since 11-D) into ONE
 * paste-ready artifact.
 *
 * ★ THIS BUNDLE MUST BE APPLIED BEFORE THE OTHER THREE. `notification_grant_is_live` and
 * `asset_grant_tier` are `language sql`, so Postgres parses and resolves their bodies at CREATE
 * time — applying the lifecycle or estate bundle against a database without the 4-argument
 * `release_condition_satisfied` (and, since 11-D, without `estate_lifecycle_state` and its table)
 * fails outright rather than degrading. The plpgsql consumers would create happily and then raise
 * at first call, which is worse. Ordering is therefore load-bearing at deploy time and not merely
 * tidy, and it is stated here because a bundle whose prerequisite is unwritten is the defect Phase
 * 10-E shipped (`create_asset_grant` missing from a bundle that patched it).
 *
 * ★ AND IT CARRIES ITS OWN DEPENDENTS. `can_access_document` and `document_grantable` were
 * extracted to `db/functions/` in 11-B; 11-D adds the LIFECYCLE SEAM (migration 0052's tables plus
 * `estate_lifecycle_state`) because the document gate this bundle ships now resolves the estate's
 * lifecycle at read time. The first pasted artifact carries the seam so no paste order has a
 * broken middle.
 *
 * Usage:  node scripts/buildReleaseConditionBundle.mjs [--out <path>]
 *         node scripts/buildReleaseConditionBundle.mjs --check
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root: ROOT,
    script: 'buildReleaseConditionBundle.mjs',
    // ★ ORDER IS LOAD-BEARING. The CHECK widening first (so a row carrying a split condition can
    // exist), then the lifecycle foundation (0052 — the table the seam reader resolves at CREATE
    // time), then the removal of the lifecycle-blind predicate (0053), then the 4-argument
    // canonical predicate, the authoritative lifecycle reader, the ceiling, and the gate that
    // calls all of them.
    //
    // ★ 0052 SHIPS HERE SINCE PHASE 11-D, and in the death bundle too — same source file, both
    // idempotent. This is the FIRST artifact an operator pastes, and from 11-D on every disclosure
    // evaluator resolves `estate_lifecycle_state(estate)` at read time: if the seam arrived only
    // with the LAST bundle, every intermediate paste state would crash each read surface on a
    // function that does not exist yet. The first paste must carry the seam so no paste order has
    // a broken middle.
    parts: [
      'db/migrations/0051_20260812_release_condition_engine.sql',
      'db/migrations/0052_20260812_death_verification_foundation.sql',
      'db/migrations/0053_20260812_lifecycle_aware_release_predicate.sql',
      // ★ PHASE 11-E: the six-state safety vocabulary rides with the predicate whose validity gate
      // names it. Pasting this bundle FIRST is what makes the whole sequence safe: the predicate it
      // carries satisfies the death condition ONLY at `released`, and nothing this bundle installs
      // can write that state — the transition routines arrive with the LAST bundle, the release
      // routine is client-revoked with no caller, and the window duration table ships EMPTY.
      'db/migrations/0054_20260812_challenge_window_release_seam.sql',
      'db/functions/release_conditions.sql',
      'db/functions/estate_lifecycle_state.sql',
      'db/functions/document_grantable.sql',
      'db/functions/can_access_document.sql',
    ],
    /**
     * ★ CONTROLS THAT FAIL IF THE PHASE IS ABSENT, not controls that confirm a file is a file.
     *
     * Each names something that did not exist before 11-B, or something whose removal would silently
     * un-do it: the split vocabulary in the CHECK, the legacy value still present (dropping it would
     * orphan stored rows), the two canonical functions, the fused value ABSENT from the write gate,
     * and the document gate actually delegating rather than keeping its own copy of the rule.
     */
    controls: [
      ['db/migrations/0051_20260812_release_condition_engine.sql', "'after_verified_death',"],
      ['db/migrations/0051_20260812_release_condition_engine.sql', "'after_verified_incapacity',"],
      /**
       * ★ THE NEEDLE IS THE MIGRATION'S SELF-CHECK, NOT THE CONSTRAINT LITERAL — deliberately.
       *
       * The first version required `'after_verified_death_or_incapacity',` (the CHECK-list entry)
       * to be present in the file. That control MASKED the runtime layer beneath it: the mutation
       * that drops the legacy value from the constraint could only ever be caught by the build
       * refusing, so nothing ever proved the migration's own apply-time guard fires. One defensive
       * layer was hiding whether the second one worked at all — the Stage-17 failure shape.
       *
       * Requiring the GUARD keeps the build honest (a migration that lost its self-check cannot
       * ship) while leaving constraint edits to be caught where they should be: at apply time, by
       * the guard, inside the SQL suite. `p11b-legacy-rows-orphaned` proves that path fires.
       */
      ['db/migrations/0051_20260812_release_condition_engine.sql', 'the legacy fused value was dropped'],
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'create table if not exists public.estate_lifecycle'],
      // ★ THE BLIND OVERLOAD MUST BE DROPPED IN THE SAME PASTE THAT CREATES THE WIDE ONE, or a
      // database that ran the 11-B artifact keeps two authorities and overload resolution quietly
      // serves the lifecycle-blind one to any consumer that was not rewired.
      ['db/migrations/0053_20260812_lifecycle_aware_release_predicate.sql',
        'drop function if exists public.release_condition_satisfied(text, timestamptz, text);'],
      // ★ THE 11-E SAFETY VOCABULARY AND ITS EMPTY CONFIGURATION. A bundle built from sources where
      // the six-state widening or the unseeded policy table regressed must refuse to build.
      ['db/migrations/0054_20260812_challenge_window_release_seam.sql', "'challenge_window',"],
      ['db/migrations/0054_20260812_challenge_window_release_seam.sql',
        'create table if not exists public.release_safety_policy'],
      ['db/functions/release_conditions.sql', 'create or replace function public.release_condition_satisfied'],
      // ★ THE PREDICATE IS THE 11-D SHAPE: it takes the lifecycle argument. A bundle built from a
      // pre-11-D source must refuse to build. The death-arm CONJUNCTION is deliberately NOT a build
      // control: it is pinned at the runtime layer (the SQL truth table) and the structural layer
      // (phase11Firewall), and a build needle here would testify INSTEAD of them — the 0051
      // legacy-value lesson: one defensive layer hiding whether the ones beneath it work at all.
      ['db/functions/release_conditions.sql', 'p_lifecycle_state   text'],
      ['db/functions/release_conditions.sql', 'create or replace function public.release_condition_writable'],
      ['db/functions/release_conditions.sql', "when 'legacy_immediate_only' then"],
      // ★ THE SEAM SHIPS WITH THE AUTHORITY, revoked from every client role — the reader is a
      // death-status oracle if a client can execute it.
      ['db/functions/estate_lifecycle_state.sql', 'create or replace function public.estate_lifecycle_state'],
      ['db/functions/estate_lifecycle_state.sql',
        'revoke execute on function public.estate_lifecycle_state(uuid) from public, anon, authenticated'],
      ['db/functions/document_grantable.sql', 'create or replace function public.document_grantable'],
      ['db/functions/can_access_document.sql', 'create or replace function public.can_access_document'],
      // ★ THE DOCUMENT GATE DELEGATES, AND PASSES THE SEAM. A bundle built from a source that had
      // quietly kept its own copy of the release rule — or one that dropped the lifecycle argument —
      // would ship the centralization's appearance without its substance.
      ['db/functions/can_access_document.sql',
        "g.release_condition, g.approved_at, 'standard', public.estate_lifecycle_state(v_estate)"],
    ],
    out: 'db/bundles/release_conditions_bundle.sql',
  },
  process.argv.slice(2)
);
