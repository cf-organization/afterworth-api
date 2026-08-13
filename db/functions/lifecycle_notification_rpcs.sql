-- Phase 10-E — LIFECYCLE NOTIFICATIONS: the emission spine.
--
-- A notification answers exactly one question: *what meaningful thing happened that I was ALREADY
-- authorized to know about?* It is never a second disclosure channel, and every design decision
-- below exists to make that structurally true rather than reviewed case by case.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ THE GOVERNING RULE: NOTIFICATION COPY IS A CONSTANT, LOOKED UP BY EVENT NAME.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- No emitter composes text. No emitter interpolates. `notification_event_copy` is an IMMUTABLE
-- closed catalog keyed by an event name, and `emit_lifecycle_notification` is the ONLY way a
-- lifecycle row is written.
--
-- This is not stylistic. It is the cheapest correct answer to a whole family of leaks at once:
--
--   · WITHHOLDING IS A PROPERTY OF INFORMATION, NOT OF FIELDS. A body that concatenates anything —
--     a category, a document title, an asset name, a count, an email — is a disclosure decision
--     taken at a call site, by whoever was editing that function that day. Copy that cannot vary
--     cannot leak, and needs no reviewer to notice.
--
--   · IT IS ALREADY PROVEN NECESSARY HERE. The one lifecycle notification in production reads
--     "You've been granted access to estate assets (estate_inventory)." — a raw backend enum,
--     rendered verbatim on a real device, produced by exactly this kind of `||` in a call site.
--     The mobile client has an audit forbidding backend vocabulary on screen; it never fired,
--     because the enum arrived as server-authored prose.
--
--   · REVOCATION SEMANTICS FALL OUT FOR FREE. A revoke notification that names the document whose
--     title is no longer authorized re-discloses it forever, in a row that outlives the grant.
--     Constant copy has nothing to retain, so there is no transition to get wrong.
--
--   · AND IT IS MECHANICALLY AUDITABLE. `db/tests/lifecycle_notification_authorization.sql` asserts
--     that no emitter passes a computed title or body, which a prose rule could never enforce.
--
-- Naming an ESTATE is also refused. The row keeps `estate_id` for provenance — the client already
-- drops it at normalization and never scopes by it — but no copy says which estate, because a
-- person's relationship to an estate is exactly the kind of fact that varies by viewer.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ WHAT THIS FILE DOES NOT DO, DELIBERATELY.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- No death activation. No "the estate has been released". No "new assets are available". A
-- death-conditioned grant is DORMANT, and an APPROVED claim releases nothing — so neither may
-- produce a notification that implies otherwise. `notification_grant_is_live` is where that is
-- enforced, and it is enforced by refusing to emit at all rather than by softening the words.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- The event catalog. Adding an event means adding a row HERE, which is the only place copy exists.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ EVERY STRING IS PURE ASCII, AND THAT IS A REQUIREMENT RATHER THAN AN ACCIDENT. Copy containing
-- a typographic apostrophe cannot be extracted from a Hermes bundle in any tested encoding, so
-- "You've" would be invisible to the mobile bundle audit and its absence would prove nothing. The
-- apostrophes below are deliberately avoided by rephrasing, never by using a curly one.
--
-- ★ THE COPY DESCRIBES IMPACT, AND ONLY IMPACT THAT IS TRUE FOR THAT VIEWER. It never states a
-- capability the viewer may not have ("you can now add documents" tells a beneficiary that an
-- add-document capability exists on this estate), never diagnoses, and never claims delivery,
-- receipt or that anyone read anything.
--
-- ★ AND IT IS JURISDICTION-NEUTRAL. No "probate", no "legal representative", no "court approved",
-- no "estate settled" — none of which the data proves.
create or replace function public.notification_event_copy(p_event text)
 returns table (category text, title text, body text)
 language sql
 immutable
 set search_path to 'public'
as $function$
  select c.category, c.title, c.body
  from (values
    -- ── access requests ───────────────────────────────────────────────────────────────────────
    -- To the OWNER. Says a member requested access; says nothing about WHICH member, because the
    -- brief's own example ("A professional delegate requested access") would make copy vary by
    -- role, and role-varying copy is interpolation wearing a switch statement.
    ('access_request.created',  'accessRequest',  'Access request received',
     'A member of this estate requested access.'),
    -- To the REQUESTER, about their OWN request. Their own outcome is always theirs to know.
    ('access_request.approved', 'accessGranted',  'Access request approved',
     'Your request for access was approved.'),
    ('access_request.denied',   'accessRequest',  'Access request decided',
     'Your request for access was not approved.'),

    -- ── grants ────────────────────────────────────────────────────────────────────────────────
    -- To the GRANTEE, and only for a grant that is LIVE RIGHT NOW — see notification_grant_is_live.
    ('access_grant.created',    'accessGranted',  'Access granted',
     'You have access to shared estate information.'),
    -- ★ THE REVOKE COPY NAMES NOTHING. Not the document, not the category, not the tier. Whatever
    -- was authorized a moment ago may not be authorized now, and a notification row outlives the
    -- grant it describes.
    ('access_grant.revoked',    'accessChanged',  'Access updated',
     'Your access to shared estate information has changed.'),

    -- ── invitations ───────────────────────────────────────────────────────────────────────────
    -- To the OWNER, who issued the invitation and therefore already knows the invitee. This says
    -- LESS than the owner knows, which is the correct direction to err.
    ('invitation.accepted',     'invitationUpdate', 'Invitation accepted',
     'Someone you invited has joined this estate.'),
    ('invitation.declined',     'invitationUpdate', 'Invitation declined',
     'An invitation to this estate was declined.'),

    -- ── the owner safety notice (Phase 11-E) ────────────────────────────────────────────────────
    -- To the OWNER, and ONLY the owner, when the challenge window opens on their estate. The copy
    -- uses exactly the epistemically honest claims the 11-E brief sanctions: a process is waiting,
    -- and the owner can halt it. It asserts no death, names no claimant, no evidence, no deadline
    -- arithmetic, and no estate name. Emitted by begin_challenge_window, which REQUIRES this row
    -- to commit before the window may open — the one notification in the product that is
    -- load-bearing rather than a heads-up.
    ('death_process.window_opened', 'safetyNotice', 'A release process is waiting',
     'A release process is waiting on your estate. You can review and halt it now.')
  ) as c(event, category, title, body)
  where c.event = p_event;
$function$;

comment on function public.notification_event_copy(text) is
  'Immutable closed catalog of lifecycle notification copy, keyed by event name. Returns ZERO rows '
  'for an unknown event, which emit_lifecycle_notification treats as a refusal to emit. This is the '
  'ONLY place notification copy exists; emitters name an event and never compose text.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- ★ THE DEATH / CLAIM FIREWALL, EXPRESSED AS A REFUSAL TO EMIT.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- "You have access" may be said ONLY about a grant that confers access AT THIS MOMENT. A grant
-- conditioned on death, on a claim decision, or on identity verification confers nothing yet, and a
-- notification saying otherwise would be the release announcement Phase 11 has not built.
--
-- ★ IT MIRRORS `can_access_document`'S RELEASE RULE, AND MIRRORS IT RATHER THAN GUESSING AT IT.
--
-- The active set is: `immediately` always, plus the two approval-conditioned states once
-- `approved_at` is set — `after_owner_approval` and `after_access_request_approval` being the same
-- gate seen from the two initiators. Everything else is dormant-deny.
--
-- Enumerating what it REFUSES is the load-bearing half, so it is written down rather than implied:
--
--   never                              nothing is ever released
--   after_verified_death_or_incapacity ★ the death firewall — dormant, and stays dormant
--   after_claim_case_approval          ★ an APPROVED claim releases NOTHING and announces NOTHING
--   after_identity_verification        not a release signal this product acts on yet
--
-- ★ AND THE DIRECTION OF ERROR IS CHOSEN. A notification that announces access a read would then
-- refuse is the failure that matters — it tells a person something false about their own standing
-- and sends them to a screen that says no. Every state accepted here is accepted by
-- `can_access_document`, so that cannot happen. The reverse (staying quiet about something the
-- reader would allow) costs a heads-up and nothing else.
--
-- This is NOT a second copy of the authorization rule and must never grow into one. It decides
-- whether to SPEAK; it never decides what may be READ, and no read path consults it.
create or replace function public.notification_grant_is_live(
  p_status text,
  p_release_condition text,
  p_approved_at timestamptz
)
 returns boolean
 language sql
 immutable
 set search_path to 'public'
as $function$
  -- ★ PHASE 11-B — the release rule is no longer written here. This was one of seven copies of it;
  -- it is now one call to the canonical authority, under the SAME `'standard'` policy
  -- `can_access_document` uses. That is what makes the paragraph above ("every state accepted here
  -- is accepted by can_access_document") a structural fact rather than a claim two files apart have
  -- to keep agreeing about by hand.
  --
  -- ★ PHASE 11-D — THE LIFECYCLE ARGUMENT IS PINNED TO THE BASE STATE, DELIBERATELY. This predicate
  -- decides whether to SPEAK, and it may speak only about access that holds WITHOUT reference to any
  -- lifecycle event: a "You have access" emitted because an estate is death_verified IS the release
  -- announcement Phase 11-F owns the copy for, and 11-D emits no death or release fact (R11, §16).
  -- Pinning 'active' keeps every emission byte-identical to Phase 10-E — which the source↔deployment
  -- reconciler requires (this function's full truth table is compared EXACT against production) —
  -- and keeps the subset property: everything accepted here is still accepted by the read path,
  -- while the read path may now accept more. The quiet direction costs a heads-up and nothing else.
  -- This literal is the ONE sanctioned non-seam lifecycle argument in the codebase, pinned by
  -- `test/deathVerificationFoundation.test.ts`; every disclosure evaluator passes
  -- `public.estate_lifecycle_state(<estate>)`.
  --
  -- The STATUS half stays here, because it is not a release-condition question: a revoked grant is
  -- not a dormant condition, it is a grant that no longer exists for this purpose.
  select p_status = 'active'
     and public.release_condition_satisfied(p_release_condition, p_approved_at, 'standard', 'active');
$function$;

comment on function public.notification_grant_is_live(text, text, timestamptz) is
  'True only for a grant that confers access in the BASE lifecycle, a deliberate subset of '
  'can_access_document''s rule since 11-D: the lifecycle argument is pinned to active, so a '
  'death-conditioned grant emits NOTHING even at death_verified — release announcements are 11-F '
  'copy, not a side effect of grant emission. Claim-conditioned grants stay dormant. Decides whether '
  'to SPEAK, never what may be READ — no read path consults it.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- Recipient resolution. Server-side, from the authoritative source for each fact.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ IDENTITY AND RELATIONSHIP ARE NEVER RECONSTRUCTED FROM CAPABILITIES. Ownership comes from
-- `estates.owner_id` (the same column `is_estate_owner` reads, kept to the sanctioned single site);
-- the grantee comes from the grant row; the requester comes from the request row. No recipient is
-- ever inferred from a permission combination.
create or replace function public.estate_owner_user_id(p_estate_id uuid)
 returns uuid
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select owner_id from public.estates where id = p_estate_id;
$function$;

comment on function public.estate_owner_user_id(uuid) is
  'The estate owner user id, for server-side notification recipient resolution. INTERNAL: execute is '
  'revoked from public/authenticated, because a client that can map estate -> owner identity has been '
  'handed an identity-disclosure surface nothing in the product offers.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- Deep-link target. A CLOSED SET OF TWO, chosen server-side from authoritative membership.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ A DEEP LINK IS NOT A BEARER TOKEN, AND THIS FUNCTION IS NOT AN AUTHORIZATION. Both destinations
-- re-fetch their own authority on arrival and refuse independently — `get_professional_workspace`
-- and `get_estate_discovery` each answer for themselves, and a notification that outlived a
-- revocation simply lands on a refusal. Choosing WHICH of the two is a routing convenience, not a
-- grant, and the value discloses nothing: both routes exist for every participant.
--
-- It is derived server-side rather than client-side for the reason in the phase brief — the client
-- must not decide who should know what — even though in this instance the choice is inert.
create or replace function public.notification_estate_home(p_estate_id uuid, p_user_id uuid)
 returns text
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select case
    when exists (
      select 1 from public.estate_memberships m
      where m.estate_id = p_estate_id
        and m.user_id = p_user_id
        and m.role = 'professional_delegate'
        and m.status = 'approved'
    ) then 'afterworth://workspace'
    else 'afterworth://estate-summary'
  end;
$function$;

comment on function public.notification_estate_home(uuid, uuid) is
  'Closed set of two in-app destinations for a lifecycle notification, chosen from authoritative '
  'membership. Not an authorization: both destinations re-check their own authority on arrival.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- ★ THE ONE WAY A LIFECYCLE NOTIFICATION IS WRITTEN.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ TRANSACTIONAL SEMANTICS, STATED EXACTLY. A plpgsql function runs inside its CALLER'S
-- transaction, so this insert and the state transition that triggered it commit or roll back
-- TOGETHER. If the transition rolls back, the notification never existed. There is no queue, no
-- outbox and no window in which a notification describes something that did not happen.
--
-- The one asymmetry is deliberate and is the existing convention: if the notification insert itself
-- fails, the load-bearing event still commits. A grant is the product; a heads-up is not, and
-- failing a grant because a notification could not be written would be the wrong trade.
--
-- ★ BUT SILENT DEGRADATION IS OPERATIONAL DEBT, SO IT IS NOT SILENT. The previous convention was
-- `exception when others then null` copied into each call site — which swallows the failure AND
-- relies on every future emitter remembering to write it. Here it is swallowed in ONE place and
-- raises a WARNING, so the failure is visible to an engineer in the Postgres log rather than
-- inferred later from a missing row.
--
-- ★ AN UNKNOWN EVENT EMITS NOTHING. It does not fall back to a generic message. A fallback would
-- mean a typo produces a real notification with invented meaning, which is precisely the class of
-- bug that put a raw enum in front of a user.
create or replace function public.emit_lifecycle_notification(
  p_user_id uuid,
  p_estate_id uuid,
  p_event text,
  p_deep_link text default null
)
 returns uuid
 language plpgsql
 volatile
 security definer
 set search_path to 'public'
as $function$
declare
  v_copy record;
  v_id uuid;
begin
  -- No recipient, no notification. A null here means a caller could not resolve one, and inventing
  -- a recipient is the one mistake this whole file exists to prevent.
  if p_user_id is null or p_event is null then
    return null;
  end if;

  select c.category, c.title, c.body into v_copy
  from public.notification_event_copy(p_event) c;

  if v_copy is null then
    raise warning 'emit_lifecycle_notification: unknown event %, nothing emitted', p_event;
    return null;
  end if;

  begin
    v_id := public.emit_notification(
      p_user_id, p_estate_id, v_copy.category, v_copy.title, v_copy.body, p_deep_link, '{}'::jsonb
    );
  exception when others then
    -- Swallowed so the load-bearing transition still commits — but LOUD in the server log.
    raise warning 'emit_lifecycle_notification: event % could not be written (%)', p_event, sqlerrm;
    return null;
  end;

  return v_id;
end;
$function$;

comment on function public.emit_lifecycle_notification(uuid, uuid, text, text) is
  'The only way a lifecycle notification is written. Copy comes from the immutable event catalog; '
  'callers name an event and never compose text. Runs in the caller transaction, so it commits or '
  'rolls back with the state transition. INTERNAL: execute revoked from public/authenticated.';

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ EVERY PRIVILEGE STATEMENT FOR THESE FUNCTIONS LIVES IN 0050, AND NOT HERE.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- The revokes were originally written in BOTH this file and the migration, on the reasoning that a
-- function and its access model belong together. Mutation testing killed that idea in the most
-- direct way available: `forgery-lock-removed` flipped the migration's
-- `revoke execute ... from authenticated` to a `grant`, and the SUITE STILL PASSED — because this
-- file re-revoked it moments later, from the same bundle.
--
-- Two copies of a security control are not defence in depth when they run in sequence. They are one
-- control and one thing that silently repairs an attempt to remove it, which is strictly worse than
-- one control: it makes the hole un-testable, and it would have made a future `grant` in the
-- migration look harmless in review.
--
-- So the privilege model is single-sourced in `db/migrations/0050_20260811_lifecycle_notifications.sql`,
-- which the bundle loads AFTER this file precisely so every function exists by the time it runs.
-- The mutation is killed now.
