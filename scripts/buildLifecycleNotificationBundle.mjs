#!/usr/bin/env node
/**
 * Assemble the Phase 10-E lifecycle-notification bundle — the emission spine plus every mutation
 * that emits — into ONE paste-ready artifact for the Supabase SQL editor.
 *
 * ★ THE EMITTERS ARE IN THE BUNDLE, NOT JUST THE SPINE. Deploying `emit_lifecycle_notification`
 * without the rewritten `create_asset_grant` would leave the OLD emitter in place: the one that
 * concatenates a backend enum into user-facing prose and announces access for a death-conditioned
 * grant. A partial deploy here is not "fewer notifications", it is the defect still live with a fix
 * sitting next to it. So the whole set ships together or the bundle does not build.
 *
 * ★ THE SAME FILE LIST IS WHAT THE SQL AUTHORIZATION SUITE LOADS. `verifySqlAuthorization.mjs` reads
 * this bundle, so the functions the suite exercises are the exact bytes an operator pastes. That is
 * the property the preamble lost when it hand-copied `create_asset_grant`, and it is why the copy
 * was deleted rather than re-synchronized.
 *
 * ORDER: the spine first (the emitters reference it at creation time only for the function name, but
 * putting it first keeps a fresh database loadable in one pass), then the mutations.
 *
 * Usage:  node scripts/buildLifecycleNotificationBundle.mjs [--out <path>]
 *         node scripts/buildLifecycleNotificationBundle.mjs --check
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle } from './lib/sqlBundle.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

buildBundle(
  {
    root: ROOT,
    script: 'buildLifecycleNotificationBundle.mjs',
    parts: [
      // ★ FIRST (Phase 11-B): `notification_grant_is_live` is `language sql` and delegates to
      // `release_condition_satisfied`, so its CREATE fails outright on a database that lacks the
      // predicate. Carrying the canonical module here keeps this bundle single-paste runnable —
      // the property its header promises — at the cost of an idempotent re-CREATE. Since 11-D the
      // blind 3-argument overload is dropped first (0053): without the drop, a database that ran
      // the 11-B artifact would keep two authorities, and overload resolution would quietly serve
      // the lifecycle-blind one to any caller that was not rewired. This bundle needs NO lifecycle
      // seam: `notification_grant_is_live` pins the base state ('active') by decision — emission
      // never consults a lifecycle, because a "You have access" born from death_verified is the
      // release announcement 11-F owns.
      'db/migrations/0053_20260812_lifecycle_aware_release_predicate.sql',
      'db/migrations/0054_20260812_challenge_window_release_seam.sql',
      'db/functions/release_conditions.sql',
      // ★ EVERY FUNCTION BEFORE THE MIGRATION, deliberately inverted from the usual migration-first
      // order. 0050 is entirely `revoke execute on function ...` plus one index, and a REVOKE names
      // a function that must already exist — on a fresh database it does not. Guarding the revokes
      // with an exception handler would hide a genuinely missing function, which is the wrong trade
      // for a privilege change whose whole point is closing a hole.
      //
      // The privilege model is single-sourced in 0050 (see the note there: duplicating a revoke
      // beside its function made the forgery hole untestable), so this ordering is load-bearing
      // rather than cosmetic.
      'db/functions/emit_notification.sql',
      'db/functions/lifecycle_notification_rpcs.sql',
      'db/migrations/0050_20260811_lifecycle_notifications.sql',
      'db/functions/create_access_request.sql',
      'db/functions/approve_access_request.sql',
      'db/functions/deny_access_request.sql',
      'db/functions/create_asset_grant.sql',
      'db/functions/create_document_grant.sql',
      'db/functions/approve_document_grant.sql',
      'db/functions/revoke_document_grant.sql',
      'db/functions/provision_from_invitation.sql',
      'db/functions/accept_invitation.sql',
      'db/functions/decline_invitation.sql',
    ],
    /**
     * ★ CONTROLS THAT WOULD FAIL IF THE FIX WERE ABSENT, not controls that merely confirm a file is
     * a file. Each of the last four asserts a specific defect is gone or a specific gate is present —
     * a bundle built from pre-10-E sources fails here rather than deploying quietly.
     */
    controls: [
      ['db/functions/release_conditions.sql', 'create or replace function public.release_condition_satisfied'],
      ['db/migrations/0050_20260811_lifecycle_notifications.sql', 'revoke execute on function public.emit_notification'],
      ['db/functions/emit_notification.sql', 'create or replace function public.emit_notification'],
      ['db/functions/lifecycle_notification_rpcs.sql', 'create or replace function public.notification_event_copy'],
      // ★ THE 11-E OWNER SAFETY NOTICE MUST SHIP WITH ITS COPY. begin_challenge_window REQUIRES
      // this event to emit before any window can open; a catalog without it makes every window
      // opening fail loudly (owner_notification_failed) — correct, but a bundle that cannot open
      // a window is not the artifact this manifest describes.
      ['db/functions/lifecycle_notification_rpcs.sql', "'death_process.window_opened'"],
      ['db/functions/lifecycle_notification_rpcs.sql', 'create or replace function public.notification_grant_is_live'],
      // ★ THE 11-D EMISSION PIN: the speech predicate evaluates against the BASE lifecycle, so a
      // death-conditioned grant emits nothing even at death_verified. A source where this literal
      // became a seam call would emit the release announcement 11-F owns — refuse to build it.
      // (Needle stops before the closing `);` so runtime-layer mutations that WRAP the call — the
      // p11b-document-gate precedent — are still buildable and get killed by the suite instead.)
      ['db/functions/lifecycle_notification_rpcs.sql', "p_approved_at, 'standard', 'active')"],
      ['db/migrations/0053_20260812_lifecycle_aware_release_predicate.sql',
        'drop function if exists public.release_condition_satisfied(text, timestamptz, text);'],
      ['db/functions/lifecycle_notification_rpcs.sql', 'create or replace function public.emit_lifecycle_notification'],
      ['db/functions/lifecycle_notification_rpcs.sql', 'create or replace function public.estate_owner_user_id'],
      ['db/functions/lifecycle_notification_rpcs.sql', 'create or replace function public.notification_estate_home'],
      // The nine emitters each name an event rather than composing copy.
      ['db/functions/create_access_request.sql', "'access_request.created'"],
      ['db/functions/approve_access_request.sql', "'access_request.approved'"],
      ['db/functions/deny_access_request.sql', "'access_request.denied'"],
      ['db/functions/create_asset_grant.sql', "'access_grant.created'"],
      ['db/functions/create_document_grant.sql', "'access_grant.created'"],
      ['db/functions/approve_document_grant.sql', "'access_grant.created'"],
      ['db/functions/revoke_document_grant.sql', "'access_grant.revoked'"],
      ['db/functions/provision_from_invitation.sql', 'create or replace function public.provision_from_invitation'],
      ['db/functions/accept_invitation.sql', "'invitation.accepted'"],
      ['db/functions/decline_invitation.sql', "'invitation.declined'"],
      // ★ THE DEATH/CLAIM FIREWALL IS PRESENT AT BOTH GRANT-CREATION SITES.
      ['db/functions/create_asset_grant.sql', 'public.notification_grant_is_live'],
      ['db/functions/create_document_grant.sql', 'public.notification_grant_is_live'],
      ['db/functions/approve_document_grant.sql', 'public.notification_grant_is_live'],
    ],
    out: 'db/bundles/lifecycle_notifications_bundle.sql',
  },
  process.argv.slice(2)
);
