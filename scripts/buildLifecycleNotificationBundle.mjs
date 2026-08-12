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
      ['db/migrations/0050_20260811_lifecycle_notifications.sql', 'revoke execute on function public.emit_notification'],
      ['db/functions/emit_notification.sql', 'create or replace function public.emit_notification'],
      ['db/functions/lifecycle_notification_rpcs.sql', 'create or replace function public.notification_event_copy'],
      ['db/functions/lifecycle_notification_rpcs.sql', 'create or replace function public.notification_grant_is_live'],
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
