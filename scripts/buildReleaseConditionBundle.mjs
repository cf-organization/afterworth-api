#!/usr/bin/env node
/**
 * Assemble the Phase 11-B release-condition engine into ONE paste-ready artifact.
 *
 * ★ THIS BUNDLE MUST BE APPLIED BEFORE THE OTHER TWO. `notification_grant_is_live` is
 * `language sql`, so Postgres parses and resolves its body at CREATE time — applying the lifecycle
 * bundle against a database without `release_condition_satisfied` fails outright rather than
 * degrading. `inventory_disclosure_tier` and the asset paths are plpgsql and would create happily
 * and then raise at first call, which is worse. Ordering is therefore load-bearing at deploy time
 * and not merely tidy, and it is stated here because a bundle whose prerequisite is unwritten is the
 * defect Phase 10-E shipped (`create_asset_grant` missing from a bundle that patched it).
 *
 * ★ AND IT CARRIES ITS OWN DEPENDENTS. `can_access_document` and `document_grantable` are extracted
 * to `db/functions/` in this phase — until now their only definitions lived inside migrations, with
 * hand-written copies in the test preamble that the harness's anti-shadow guard could not see. They
 * ship here so the rewired document gate reaches a database through the same door as everything
 * else, rather than by someone remembering to re-run migration 0004.
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
    // exist), then the canonical predicate, then the ceiling it needs, then the gate that calls both.
    parts: [
      'db/migrations/0051_20260812_release_condition_engine.sql',
      'db/functions/release_conditions.sql',
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
      ['db/functions/release_conditions.sql', 'create or replace function public.release_condition_satisfied'],
      ['db/functions/release_conditions.sql', 'create or replace function public.release_condition_writable'],
      ['db/functions/release_conditions.sql', "when 'legacy_immediate_only' then"],
      ['db/functions/document_grantable.sql', 'create or replace function public.document_grantable'],
      ['db/functions/can_access_document.sql', 'create or replace function public.can_access_document'],
      // ★ THE DOCUMENT GATE DELEGATES. A bundle built from a source that had quietly kept its own
      // copy of the release rule would ship the centralization's appearance without its substance.
      ['db/functions/can_access_document.sql', "public.release_condition_satisfied(g.release_condition, g.approved_at, 'standard')"],
    ],
    out: 'db/bundles/release_conditions_bundle.sql',
  },
  process.argv.slice(2)
);
