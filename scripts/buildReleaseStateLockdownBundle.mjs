#!/usr/bin/env node
/**
 * HOTFIX ARTIFACT — estate_release_state lockdown.
 *
 * ★ A DEDICATED BUNDLE, DELIBERATELY SEPARATE FROM EVERYTHING ELSE. The same revoke also lands in
 * `db/functions/estate_discovery_rpcs.sql` (so the estate bundle can never re-grant it), but asking
 * Christ to re-paste the whole 14-part estate bundle to withdraw one privilege would put every
 * discovery routine back on the table for a one-line security fix. A security correction should have
 * the smallest blast radius available, and be reviewable in one screen.
 *
 * ★ THE ARTIFACT CONTAINS NO DDL. Nothing is created, dropped or replaced — one privilege is
 * withdrawn. There is therefore no half-defined-object failure mode, and `revoke` on an
 * already-absent privilege is a no-op, so re-pasting is safe.
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root: ROOT,
    script: 'buildReleaseStateLockdownBundle.mjs',
    parts: ['db/hotfix/estate_release_state_lockdown.sql'],
    controls: [
      // ★ STRUCTURAL: the revoke must actually be in the artifact, naming all three client roles.
      // `authenticated` is the one that matters — the other two were already revoked — so an
      // artifact that shipped the historical two-role form would look right and fix nothing.
      ['db/hotfix/estate_release_state_lockdown.sql',
        'revoke execute on function public.estate_release_state(uuid) from public, anon, authenticated;'],
    ],
    out: 'db/bundles/estate_release_state_lockdown_bundle.sql',
  },
  process.argv.slice(2)
);
