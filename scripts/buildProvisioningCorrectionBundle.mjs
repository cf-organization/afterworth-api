#!/usr/bin/env node
/**
 * Assemble the Phase 11-MC provisioning correction into ONE paste-ready artifact.
 *
 * ★ WHAT IT CHANGES: a fiduciary (executor/trustee) invitation stops manufacturing an approved
 * beneficiary `estate_memberships` row. The designation is unaffected; the recipient becomes
 * discoverable through `get_my_fiduciary_estates()` and authorized through `get_executor_workspace`,
 * and gains NO disclosure class.
 *
 * ★ APPLY ORDER, AND WHY IT IS THIS ONE.
 *
 *   1 · `provision_from_invitation.sql` — the correction itself. Gates the membership insert and the
 *       beneficiary self-link on the invitation's `kind`.
 *   2 · `accept_invitation.sql` and 3 · `bind_invitation_token.sql` — the two callers. They must stop
 *       reporting a role and status for an acceptance that created no membership. Pasted AFTER the
 *       provisioner because they are the ones whose output changes shape; either order commits in one
 *       transaction, but this is the order the change reads in.
 *   4 · `create_invitation.sql` — DOCUMENTATION ONLY in this artifact. The forced `proposed_role` line
 *       is unchanged (the column is NOT NULL with a two-value CHECK), and the file is included so the
 *       deployed body carries the comment explaining why it is now inert. Excluding it would leave
 *       production holding a body whose comment still claims the value drives provisioning.
 *
 * ★ THE VERCEL SIDE MUST ALREADY BE LIVE BEFORE THIS IS PASTED, and that is not a preference.
 * `lib/invitations/accept.ts` and `lib/invitations/bind.ts` previously required all five RPC columns to
 * be strings and returned 502 `upstream_unexpected_shape` otherwise. A fiduciary acceptance now returns
 * three nulls, so pasting this against the OLD routes would make every executor acceptance look like a
 * server fault to the invitee — while the designation had in fact committed. Those routes ship with the
 * Vercel build on merge to main, so merging this PR satisfies the prerequisite; the SQL paste comes
 * after that deploy is green.
 *
 * ★ NO MIGRATION, AND THAT IS DELIBERATE. No table, column, constraint or grant changes. Making
 * `invitations.proposed_role` nullable would be the tidier end state and is recorded as a follow-up —
 * it is not needed for the authority correction and would turn a function replacement into DDL on a
 * live table.
 *
 * ★ IT FIXES OUTSTANDING INVITATIONS TOO. `proposed_role` is persisted at CREATE time, so every
 * executor invitation already in the table carries 'beneficiary'. The correction keys on `kind`, which
 * is immutable and authoritative, so invitations minted before the paste and accepted after it are
 * handled correctly with no data migration and nothing to cancel.
 *
 * Usage:  node scripts/buildProvisioningCorrectionBundle.mjs [--out <path>]
 *         node scripts/buildProvisioningCorrectionBundle.mjs --check
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root,
    script: 'scripts/buildProvisioningCorrectionBundle.mjs',
    parts: [
      'db/functions/provision_from_invitation.sql',
      'db/functions/accept_invitation.sql',
      'db/functions/bind_invitation_token.sql',
      'db/functions/create_invitation.sql',
    ],
    /**
     * ★ CONTROLS THAT FAIL IF THE PHASE IS ABSENT, and that do NOT pin what a mutation would change.
     *
     * Applied first-time-right here, after walking into it three times earlier in this programme: the
     * `kind` gate expression, the null-safe `coalesce`, the designation insert and the caller null-guards
     * are all live mutation targets, so NONE of them is pinned. Each is owned by
     * `death_verification_authorization.sql` §11-MC, which exercises executor AND trustee separately
     * (a mutation narrowing the gate to executor alone survived until the trustee case existed) and a
     * delegate dual-role case (a mutation overwriting the access class survived until that case existed).
     *
     * What IS pinned is the presence of the branch at all, and the two things whose ABSENCE would mean
     * the artifact is not this phase.
     */
    controls: [
      // The correction exists as a branch. HOW it decides is §11-MC's business.
      ['db/functions/provision_from_invitation.sql', 'v_is_fiduciary'],
      ['db/functions/provision_from_invitation.sql', 'if not v_is_fiduciary then'],
      // Both callers must carry a null-membership path at all.
      ['db/functions/accept_invitation.sql', 'v_membership_id is null'],
      ['db/functions/bind_invitation_token.sql', 'v_membership_id is null'],
      // create_invitation is here for its comment; this proves the comment shipped.
      ['db/functions/create_invitation.sql', 'INERT'],
    ],
    out: 'db/bundles/provisioning_correction_bundle.sql',
  },
  process.argv.slice(2)
);
