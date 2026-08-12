-- 0050 — Phase 10-E lifecycle notifications.
--
-- The notification STORE already exists (0009 reconciled it from live and gave it self-scoped RLS
-- plus the anti-forge lock). This migration adds nothing to the store's shape. It does two things:
-- it closes a privilege hole 0009 left open, and it adds the index the unread path deserves.
--
-- The emission spine and the rewritten emitters are functions and travel in
-- `db/bundles/lifecycle_notifications_bundle.sql`, which includes this file as its first part.
--
-- IDEMPOTENT: safe to re-apply. Revokes are no-ops when already revoked; the index is IF NOT EXISTS.

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ HIGH — CLOSE THE FORGERY HOLE. `emit_notification` COULD BE CALLED BY ANY AUTHENTICATED USER.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- 0009 revoked INSERT on `public.notifications` from `authenticated`, enabled self-scoped RLS, and
-- recorded the posture as: "a client calling emit_notification directly can still only create a
-- notification (it can't read others' — that's RLS on SELECT)."
--
-- That reasoned about READ and never about WRITE-TO-SOMEONE-ELSE. `emit_notification` is SECURITY
-- DEFINER, is exposed by PostgREST, takes `p_user_id` AS A PARAMETER, and — like every Postgres
-- function — was granted EXECUTE to PUBLIC by default. So any authenticated user could write an
-- arbitrary title, body and `action_deep_link` into ANY other user's notification centre. RLS on
-- SELECT is no defence: the victim is supposed to read it. That is the entire attack.
--
-- CONFIRMED AGAINST THE DEPLOYED DATABASE BEFORE THIS WAS WRITTEN, without creating a row: called as
-- an ordinary authenticated fixture user with a non-UUID argument it answered
-- `22P02 invalid input syntax for type uuid` — a coercion failure, which happens AFTER the EXECUTE
-- check, and identical to the answer from a routine the product genuinely grants. A `42501` would
-- have meant the privilege was already absent. It was not.
--
-- It matters more in 10-E than it did before: lifecycle notifications carry real deep links and ask
-- users to trust this surface, so a forged "Access request approved" with a link is a credible
-- phishing primitive rather than a curiosity.
--
-- SAFE: no client calls it. The mobile notification service states outright that there is nothing to
-- create there, and the endpoint exposes only list / mark_read / mark_all_read / unread_count. Every
-- real caller is a SECURITY DEFINER function executing as the owner, who retains EXECUTE inherently.
revoke execute on function public.emit_notification(uuid, uuid, text, text, text, text, jsonb) from public;
revoke execute on function public.emit_notification(uuid, uuid, text, text, text, text, jsonb) from anon;
revoke execute on function public.emit_notification(uuid, uuid, text, text, text, text, jsonb) from authenticated;

-- ★ THE 10-E SPINE IS INTERNAL TOO, AND THESE REVOKES LIVE HERE RATHER THAN BESIDE THE FUNCTIONS.
--
-- They were originally written in both places, which felt tidier and was actively harmful: mutation
-- testing flipped the `emit_notification` revoke above to a `grant` and the authorization suite
-- still passed, because the duplicate in `lifecycle_notification_rpcs.sql` re-revoked it moments
-- later from the same bundle. Two copies of a control that run in sequence are not defence in depth;
-- they are one control plus a mechanism that silently repairs attempts to remove it, which makes the
-- hole untestable and would make a future `grant` look harmless in review.
--
-- Single-sourced here. The bundle loads this file AFTER the function definitions so every name below
-- exists by the time it runs.
revoke execute on function public.emit_lifecycle_notification(uuid, uuid, text, text) from public;
revoke execute on function public.emit_lifecycle_notification(uuid, uuid, text, text) from anon;
revoke execute on function public.emit_lifecycle_notification(uuid, uuid, text, text) from authenticated;

-- Recipient resolution is internal for the same reason: a client able to map estate -> owner id, or
-- to ask which destination another user would be routed to, has been handed a membership oracle.
revoke execute on function public.estate_owner_user_id(uuid) from public;
revoke execute on function public.estate_owner_user_id(uuid) from anon;
revoke execute on function public.estate_owner_user_id(uuid) from authenticated;

revoke execute on function public.notification_estate_home(uuid, uuid) from public;
revoke execute on function public.notification_estate_home(uuid, uuid) from anon;
revoke execute on function public.notification_estate_home(uuid, uuid) from authenticated;

-- The two pure catalog functions (`notification_event_copy`, `notification_grant_is_live`) are left
-- callable. Neither reads a row; one returns product copy, the other a boolean over two literals.
-- Revoking them would be ceremony, and ceremony around a security control makes the real ones harder
-- to see.

-- ★ THE UNREAD PATH HAS ITS OWN SHAPE. `notifications_recipient_idx (user_id, created_at desc)` from
-- 0009 serves the list; the badge counts unread for one user, which is a different leading edge.
-- Partial, because the read rows are the ones that accumulate and none of them are ever counted.
create index if not exists notifications_unread_idx
  on public.notifications (user_id)
  where read = false;

comment on table public.notifications is
  'Self-scoped notification store. Rows are written ONLY by SECURITY DEFINER emitters — authenticated '
  'holds no INSERT grant and, since 0050, no EXECUTE on emit_notification either. Lifecycle copy is a '
  'constant looked up by event name in notification_event_copy; no emitter composes or interpolates text.';
