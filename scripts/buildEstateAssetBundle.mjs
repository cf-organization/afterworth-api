#!/usr/bin/env node
/**
 * Assemble the estate-inventory + discovery + readiness + workspace bundle into ONE paste-ready
 * artifact for the Supabase SQL editor.
 *
 * The assembly itself lives in `scripts/lib/sqlBundle.mjs`, shared with the lifecycle-notification
 * bundle. This file is the MANIFEST — what goes in, in what order, and what must be true of the
 * inputs — and nothing else.
 *
 * The extraction was verified the only way that means anything: this bundle rebuilds BYTE-FOR-BYTE
 * identical to the artifact that was deployed before it.
 *
 * Usage:  node scripts/buildEstateAssetBundle.mjs [--out <path>]
 *         node scripts/buildEstateAssetBundle.mjs --check     (verify inputs, emit nothing)
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root: ROOT,
    script: 'buildEstateAssetBundle.mjs',
    // ★ ORDER IS LOAD-BEARING: each migration precedes the functions that depend on it, and 0049's
    // functions rewrite `create_asset_grant`, which 0008 must already have created.
    parts: [
      // ★ FIRST, AND ADDED THE DAY THE DEPENDENCY WAS CREATED — not discovered missing later.
      //
      // Phase 11-B moved the release rule into `public.release_condition_satisfied`, and four
      // functions in this bundle call it (`inventory_disclosure_tier`, the two
      // `list_estate_assets` sites, `create_asset_grant`'s write gate). Phase 11-D widened the
      // predicate with a lifecycle argument that those consumers resolve through
      // `estate_lifecycle_state` — `asset_grant_tier` is `language sql`, so its CREATE fails
      // outright against a database missing the reader or the table it reads. A bundle whose
      // header says "paste this whole file and run it once" but which references objects it does
      // not carry is the Phase 10-F missing-bracket-functions defect with a new name. Everything
      // below is idempotent, so carrying the seam here AND in the release-conditions bundle costs
      // nothing and keeps every artifact self-sufficient.
      'db/migrations/0052_20260812_death_verification_foundation.sql',
      'db/migrations/0053_20260812_lifecycle_aware_release_predicate.sql',
      'db/functions/release_conditions.sql',
      'db/functions/estate_lifecycle_state.sql',
      'db/migrations/0048_20260810_estate_assets.sql',
      'db/functions/estate_asset_rpcs.sql',
      // ★ ADDED IN PHASE 10-E, AND THE BUNDLE WAS NOT SELF-SUFFICIENT WITHOUT IT.
      //
      // `estate_discovery_rpcs.sql` patches `create_asset_grant` in place (it reads
      // `pg_get_functiondef` and re-executes a widened body) and raises
      // "create_asset_grant not found — apply migration 0008 first" when it is absent. So this
      // artifact, whose header says "paste this whole file and run it once", could not in fact be
      // run once on a fresh database: it carried an unstated dependency on a migration that is not
      // in it. The SQL harness was hiding that by hand-copying the function into the preamble.
      //
      // It must precede 0049, which patches it.
      'db/functions/create_asset_grant.sql',
      // ★ ADDED IN 10-F — THE BRACKETS SHIPPED IN NO BUNDLE AT ALL.
      //
      // `asset_bracket_low` / `asset_bracket_high` are the anti-oracle mechanism: they are what stop
      // a category aggregate from republishing an exact value. `estate_discovery_rpcs.sql` calls
      // them, and neither bundle carried them — production has them from an older migration, and the
      // SQL harness has its own copy, so nothing noticed. A fresh database built from these bundles
      // would have created `get_estate_discovery` referencing functions that do not exist.
      //
      // Found by a mutation aimed at collapsing the bracket, which reported HARNESS_FAILURE — "the
      // mutation is in no rebuilt bundle" — rather than a verdict. The harness refusing to vote is
      // what surfaced it; a mutation runner that had silently defaulted to NOT_DETECTED would have
      // sent someone looking for a missing assertion instead.
      'db/functions/list_estate_assets.sql',
      'db/migrations/0049_20260811_estate_discovery.sql',
      'db/functions/estate_discovery_rpcs.sql',
      'db/functions/estate_readiness_rpcs.sql',
      'db/functions/professional_workspace_rpcs.sql',
    ],
    controls: [
      ['db/functions/release_conditions.sql', 'create or replace function public.release_condition_satisfied'],
      // ★ THE 11-D SEAM IS CARRIED WHOLE: the table (0052), the blind-overload drop (0053), the
      // reader, and consumers that actually pass the seam. A bundle built from sources where any of
      // these regressed must refuse to build rather than paste a half-wired evaluator.
      ['db/migrations/0052_20260812_death_verification_foundation.sql', 'create table if not exists public.estate_lifecycle'],
      ['db/migrations/0053_20260812_lifecycle_aware_release_predicate.sql',
        'drop function if exists public.release_condition_satisfied(text, timestamptz, text);'],
      ['db/functions/estate_lifecycle_state.sql', 'create or replace function public.estate_lifecycle_state'],
      ['db/functions/list_estate_assets.sql', "'legacy_immediate_only',\n                                           public.estate_lifecycle_state(p_estate)"],
      ['db/functions/estate_discovery_rpcs.sql', "public.estate_lifecycle_state(p_estate)"],
      ['db/migrations/0048_20260810_estate_assets.sql', 'create table if not exists public.estate_assets'],
      ['db/migrations/0048_20260810_estate_assets.sql', 'estate_assets_read_owner'],
      ['db/functions/estate_asset_rpcs.sql', 'create or replace function public.create_estate_asset'],
      ['db/functions/estate_asset_rpcs.sql', 'create or replace function public.archive_estate_asset'],
      ['db/functions/estate_asset_rpcs.sql', 'create or replace function public.get_estate_asset_taxonomy'],
      ['db/migrations/0049_20260811_estate_discovery.sql', "'estate_inventory'"],
      /**
       * ★ THE SOURCE FILE MUST ALREADY ADMIT `estate_inventory`.
       *
       * For most of Phase 9/10 it did not: only the DEPLOYED body carried the category, added by
       * 0049's string surgery, while version control still refused it. Re-applying the source would
       * have silently reverted grantability, and the deployed-contract verifier would have stayed
       * green because it probes `asset_category_grantable` — a different function.
       *
       * This control is the thing that stops that from coming back. It fails the BUILD, before an
       * operator can paste a bundle that quietly narrows a live authorization vocabulary.
       */
      ['db/functions/create_asset_grant.sql', "'linked_account_details', 'estate_inventory'"],
      ['db/functions/list_estate_assets.sql', 'create or replace function public.asset_bracket_low'],
      ['db/functions/list_estate_assets.sql', 'create or replace function public.asset_bracket_high'],
      ['db/functions/estate_discovery_rpcs.sql', 'create or replace function public.get_estate_discovery'],
      ['db/functions/estate_discovery_rpcs.sql', 'create or replace function public.inventory_disclosure_tier'],
      ['db/functions/estate_readiness_rpcs.sql', 'create or replace function public.get_estate_readiness'],
      ['db/functions/professional_workspace_rpcs.sql', 'create or replace function public.get_professional_workspace'],
    ],
    out: 'db/bundles/estate_inventory_and_discovery_bundle.sql',
  },
  process.argv.slice(2)
);
