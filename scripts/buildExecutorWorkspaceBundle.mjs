#!/usr/bin/env node
/**
 * PHASE 11-I — the paste-ready artifact for `get_executor_workspace`.
 *
 * ★ THE SMALLEST BUNDLE THIS PROGRAMME HAS PRODUCED, AND DELIBERATELY SO. Phase 11-I adds ONE
 * function and changes nothing already deployed: no table, no column, no enum, no policy, and no
 * grant widened on any existing object. Every dependency it consumes — `is_estate_executor`,
 * `estate_lifecycle_state`, `preview_required_verification_level`, `death_verification_cases`,
 * `claim_packets` — is already live, which is why they are NOT re-shipped here. Re-pasting a
 * dependency to "be safe" would enlarge the blast radius of an artifact whose whole safety argument
 * is that it touches one new name.
 *
 * ★ WHAT A HALF-DEPLOY LOOKS LIKE. Because the only object is new, a failed paste leaves the
 * function absent — which is precisely today's state. There is no intermediate configuration in
 * which an existing surface behaves differently, so the rollback story is "nothing to roll back".
 * The transaction wrapper is still asserted, because that argument must hold structurally rather
 * than by my reading of it.
 *
 * ★ THE CONTROLS PIN STRUCTURE, NOT POLICY TEXT. This distinction was learned three times across
 * 11-D/11-E/11-F: a needle quoting the exact authorization expression makes the BUILD refuse a
 * mutation of that expression, so the bundler testifies instead of the SQL suite, and nothing ever
 * proves the instrument written to catch it would have. The gate's BEHAVIOUR is pinned in
 * `db/tests/executor_workspace_authorization.sql` (executed, mutation-proven). What is pinned here
 * is that the artifact carries the function, its capacity gate, and its client posture at all.
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root: ROOT,
    script: 'buildExecutorWorkspaceBundle.mjs',
    // One part. Its dependencies are all already deployed and are deliberately not re-shipped.
    parts: ['db/functions/executor_workspace.sql'],
    controls: [
      // The function itself must be in the artifact.
      ['db/functions/executor_workspace.sql', 'create or replace function public.get_executor_workspace'],
      /**
       * ★ THE CAPACITY GATE IS DELIBERATELY *NOT* PINNED HERE, AND REMOVING IT WAS A CORRECTION.
       *
       * A control quoting the gate expression made the BUILD refuse the `p11i-workspace-ungated`
       * mutation, which reported HARNESS_FAILURE — so the bundler testified instead of the SQL
       * suite, and nothing proved that the instrument written to catch an ungated projection
       * actually would. That is the same defensive-layer-masking-another shape found three times
       * across 11-D/11-E/11-F, and this file's own header warns about it.
       *
       * The gate's BEHAVIOUR is pinned where it can be exercised: `executor_workspace_authorization.sql`
       * §0/§1/§2 put a non-fiduciary, a beneficiary, a delegate, a revoked designee, a stranger, an
       * owner and a foreign owner in front of the projection and require one identical refusal —
       * mutation-proven by `p11i-workspace-ungated`, which now reaches the database and dies there.
       */
      // ★ AND THE CLIENT POSTURE MUST SHIP. A definer function left granted to `public`/`anon`
      // would be reachable without a session at all.
      ['db/functions/executor_workspace.sql', 'revoke execute on function public.get_executor_workspace(uuid) from public, anon'],
      ['db/functions/executor_workspace.sql', 'grant  execute on function public.get_executor_workspace(uuid) to authenticated'],
    ],
    out: 'db/bundles/executor_workspace_bundle.sql',
  },
  process.argv.slice(2)
);
