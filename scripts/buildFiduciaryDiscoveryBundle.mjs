#!/usr/bin/env node
/**
 * Assemble the Phase 11-MB fiduciary estate discovery routine into ONE paste-ready artifact.
 *
 * ★ ONE PART, AND THAT IS THE POINT. This artifact adds a single read-only routine and nothing else.
 * It creates no table, alters no constraint, adds no grant beyond EXECUTE on the routine it defines,
 * and changes no existing body. There is deliberately no migration: the corrected PROVISIONING
 * behaviour (dropping the forced `beneficiary` proposed_role) is NOT in here, because it must not ship
 * until the mobile selector consumes this routine — otherwise a newly provisioned fiduciary gets a
 * designation, no membership, and an estate the app cannot find. Sequencing is the safety property.
 *
 * ★ IT GRANTS NO AUTHORITY. `get_my_executor_workspace`'s gate already keys off the designation alone;
 * what did not exist was the ENUMERATION of which estates carry one. This adds exactly that. Appearing
 * in the list makes an estate selectable and readable by nothing.
 *
 * ★ WHAT IT DELIBERATELY DOES NOT CARRY, for the standing reason every other bundle states:
 * `estate_designations`, `estates`, `is_estate_executor` and `get_executor_workspace` are all deployed
 * and reconciled by their own proofs. Bundling an unreconciled SECURITY DEFINER body into a paste-ready
 * artifact is how production nearly regressed once already (`create_asset_grant`, Phase 10-E).
 *
 * Usage:  node scripts/buildFiduciaryDiscoveryBundle.mjs [--out <path>]
 *         node scripts/buildFiduciaryDiscoveryBundle.mjs --check     (verify inputs, emit nothing)
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root,
    script: 'scripts/buildFiduciaryDiscoveryBundle.mjs',
    parts: ['db/functions/fiduciary_estate_discovery.sql'],
    /**
     * ★ CONTROLS THAT FAIL IF THE PHASE IS ABSENT, and that do NOT pin what a mutation would change.
     *
     * ★ THIS COMMENT ORIGINALLY CLAIMED THE LESSON WAS APPLIED "ON THE FIRST ATTEMPT THIS TIME". IT
     * WAS NOT. The first version of this list pinned `d.user_id = auth.uid()` and `d.status = 'active'`
     * — the routine's two core security predicates — and `p11mb-discovery-enumerates-other-users` and
     * `p11mb-revoked-designation-enumerated` promptly reported HARNESS_FAILURE instead of DETECTED,
     * because the BUILD refused the edit before Postgres ever saw it. That is the third time in one
     * programme (11-K's two grant controls, 11-L's four) and the second time it happened while the
     * warning was written directly above the mistake. Recorded plainly, because a comment claiming a
     * lesson is learned is worth less than the evidence that it was not.
     *
     * The division that survives: BUILD answers "is the phase in this artifact at all". RUNTIME answers
     * every behavioural question, in `death_verification_authorization.sql` §11-MB:
     *   · self-scoping predicate    → §11-MB asserts cross-estate isolation and zero arguments
     *   · revoked still enumerated  → §11-MB asserts a revoked designation vanishes from both surfaces
     *   · extra columns / leakage   → §11-MB asserts the resolved column set verbatim
     *   · designation grants tier   → §11-MB compares the whole composed payload byte-for-byte
     *   · dual capacity duplicates  → §11-MB asserts one row and the capacity tiebreak
     *
     * The two privilege lines ARE still pinned, and that is not the same mistake: a grant is a
     * statement the artifact either carries or does not, and §11-MB asserts the anon layer separately
     * anyway, so both layers keep their own answer.
     */
    controls: [
      ['db/functions/fiduciary_estate_discovery.sql', 'create or replace function public.get_my_fiduciary_estates()'],
      ['db/functions/fiduciary_estate_discovery.sql', 'revoke execute on function public.get_my_fiduciary_estates() from public, anon;'],
      ['db/functions/fiduciary_estate_discovery.sql', 'grant  execute on function public.get_my_fiduciary_estates() to authenticated;'],
    ],
    out: 'db/bundles/fiduciary_discovery_bundle.sql',
  },
  process.argv.slice(2)
);
