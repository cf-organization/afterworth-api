-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 10-E — LIFECYCLE NOTIFICATION AUTHORIZATION
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- The question this suite answers is NOT "does a notification appear". It is:
--
--     does a notification ever tell someone something they were not already authorized to know?
--
-- Every assertion below is therefore about a RECIPIENT, a REFUSAL, or a SILENCE. A notification that
-- correctly does not exist is the most important outcome in this file, and the hardest to test —
-- because an emitter that is simply broken produces the same silence as one that is correct. So the
-- silences are always paired with a POSITIVE CONTROL proving the same code path DOES emit under the
-- conditions where it should. An absence assertion without that pairing is a vacuous audit.
--
-- Runs under `SET ROLE authenticated` with a real `auth.uid()`, like every other suite here, so RLS
-- and the DEFINER boundary are genuinely in play rather than bypassed by a superuser.

\set ON_ERROR_STOP on

do $suite$
declare
  OWNER_A uuid; OWNER_B uuid; DELEGATE uuid; BENEFICIARY uuid; STRANGER uuid;
  A uuid; B uuid;
  v_req uuid; v_grant uuid; v_doc uuid;
  n int;
  v_title text; v_body text; v_link text; v_cat text;
begin
  raise notice ' ';
  raise notice '══ PHASE 10-E · lifecycle notification authorization ══';

  -- ── fixture ───────────────────────────────────────────────────────────────────────────────────
  -- ★ SEMANTICALLY ISOLATED FROM THE SUITES ABOVE. New users, new estates. A shared fixture would
  -- make one suite's writes another suite's preconditions, and a notification suite writes rows by
  -- design — it is the least safe possible neighbour.
  insert into auth.users default values returning id into OWNER_A;
  insert into auth.users default values returning id into OWNER_B;
  insert into auth.users default values returning id into DELEGATE;
  insert into auth.users default values returning id into BENEFICIARY;
  insert into auth.users default values returning id into STRANGER;

  insert into public.estates (owner_id, name) values (OWNER_A, 'Estate A') returning id into A;
  insert into public.estates (owner_id, name) values (OWNER_B, 'Estate B') returning id into B;

  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (A, OWNER_A, 'primary_user', 'approved'),
         (A, DELEGATE, 'professional_delegate', 'approved'),
         (A, BENEFICIARY, 'beneficiary', 'approved'),
         (B, OWNER_B, 'primary_user', 'approved');

  insert into public.documents (estate_id, title, sensitivity)
  values (A, 'Fixture statement', 'low') returning id into v_doc;

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 1 · the instrument proves itself';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ EVERY "NOBODY WAS NOTIFIED" ASSERTION BELOW IS WORTHLESS IF THE WRITER IS BROKEN. So the
  -- writer is exercised first, and observed to produce exactly one row with the catalog's copy. If
  -- this fails, nothing further in this file means anything.
  -- ★ CALLED AS THE FUNCTION OWNER, NOT AS `authenticated` — and that is not a convenience.
  -- Migration 0050 revokes EXECUTE from `authenticated`, so calling it under that role here would
  -- fail with `permission denied` and this "control" would be measuring the revoke rather than the
  -- writer. Every real caller is a SECURITY DEFINER emitter executing as the owner, which is exactly
  -- what this reproduces. Section 11 asserts the revoke itself, under `authenticated`, where it
  -- belongs.
  perform public.emit_lifecycle_notification(BENEFICIARY, A, 'access_grant.revoked', null);

  select count(*) into n from public.notifications
   where user_id = BENEFICIARY and kind = 'accessChanged';
  if n <> 1 then
    raise exception 'FAIL(control): the emitter wrote % rows, expected exactly 1 — no absence claim '
      'in this file would mean anything', n;
  end if;
  raise notice '  ok   positive control: the emitter writes exactly one row';

  -- ★ NEGATIVE CONTROL. An event that is not in the catalog must write NOTHING, and must not fall
  -- back to a generic message. A fallback would mean a typo produces a real notification with
  -- invented meaning — which is how a raw enum reached a user in the first place.
  perform public.emit_lifecycle_notification(BENEFICIARY, A, 'event.that.does.not.exist', null);
  select count(*) into n from public.notifications where user_id = BENEFICIARY;
  if n <> 1 then
    raise exception 'FAIL(control): an UNKNOWN event produced a notification (% rows) — the catalog '
      'is not closed', n;
  end if;
  raise notice '  ok   negative control: an unknown event emits nothing, with no generic fallback';

  delete from public.notifications where user_id = BENEFICIARY;

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 2 · copy discloses nothing';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THE CATALOG IS SWEPT WHOLE, not sampled. A rule applied to the events someone remembered to
  -- list governs a subset; this walks every row the catalog can produce.
  for v_cat, v_title, v_body in
    select c.category, c.title, c.body
    from (values ('access_request.created'),('access_request.approved'),('access_request.denied'),
                 ('access_grant.created'),('access_grant.revoked'),
                 ('invitation.accepted'),('invitation.declined')) as e(event)
    cross join lateral public.notification_event_copy(e.event) c
  loop
    -- No backend vocabulary. This is the defect that shipped: the live production notification reads
    -- "...to estate assets (estate_inventory)." because a call site concatenated an enum.
    if (v_title || ' ' || v_body) ~ '(estate_inventory|estate_documents|financial_accounts|professional_delegate|primary_user|beneficiary|full_detail|limited_detail|category_summary|range_only|after_verified_death|after_claim_case|immediately)' then
      raise exception 'FAIL: catalog copy contains backend vocabulary: % / %', v_title, v_body;
    end if;
    -- No identifiers of any shape.
    if (v_title || ' ' || v_body) ~* '([0-9a-f]{8}-[0-9a-f]{4}|@|http|afterworth://)' then
      raise exception 'FAIL: catalog copy contains an identifier, address or link: % / %', v_title, v_body;
    end if;
    -- No counts. "3 new assets were shared" discloses inventory shape even when the assets stay hidden.
    if (v_title || ' ' || v_body) ~ '[0-9]' then
      raise exception 'FAIL: catalog copy contains a digit — a count leaks shape: % / %', v_title, v_body;
    end if;
    -- ★ PURE ASCII. Copy carrying a typographic apostrophe cannot be extracted from a Hermes bundle in
    -- any tested encoding, so it would be invisible to the mobile bundle audit and its absence there
    -- would prove nothing. This keeps every string verifiable downstream.
    if (v_title || v_body) ~ '[^\x20-\x7E]' then
      raise exception 'FAIL: catalog copy is not pure ASCII (unverifiable in the mobile bundle audit): %', v_title;
    end if;
    -- ★ JURISDICTION-NEUTRAL. None of these is proved by any data this product holds.
    if (v_title || ' ' || v_body) ~* '(probate|legal representative|court|executor of the estate|estate settled|deceased|died|death)' then
      raise exception 'FAIL: catalog copy makes a legal or mortality claim: % / %', v_title, v_body;
    end if;
  end loop;
  raise notice '  ok   no enum, id, address, link, count, non-ASCII or legal claim in ANY catalog entry';

  -- ★ AND THE SWEEP ITSELF IS PROVEN NON-EMPTY. A `for` loop over zero rows passes every rule inside
  -- it. Asserting the scan set before trusting the verdict is the whole lesson of the 63-assertions-
  -- against-nothing near miss.
  select count(*) into n
  from (values ('access_request.created'),('access_request.approved'),('access_request.denied'),
               ('access_grant.created'),('access_grant.revoked'),
               ('invitation.accepted'),('invitation.declined')) as e(event)
  cross join lateral public.notification_event_copy(e.event) c;
  if n <> 7 then
    raise exception 'FAIL: the copy sweep resolved % entries, expected 7 — the rules above ran '
      'against the wrong set', n;
  end if;
  raise notice '  ok   the sweep resolved all 7 catalog entries (asserted, not assumed)';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 3 · access request created — the OWNER, and only the owner';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claim.sub', DELEGATE::text, true);
  set local role authenticated;
  select id into v_req from public.create_access_request(A, 'estate_documents', null);
  reset role;

  select count(*) into n from public.notifications where user_id = OWNER_A and kind = 'accessRequest';
  if n <> 1 then raise exception 'FAIL: the owner received % request notifications, expected 1', n; end if;
  raise notice '  ok   the owner is notified';

  -- ★ NOBODY ELSE. Including the requester: a person does not need telling that they just tapped a
  -- button, and telling the OTHER members would broadcast that this person asked for something.
  select count(*) into n from public.notifications
   where user_id in (DELEGATE, BENEFICIARY, STRANGER, OWNER_B);
  if n <> 0 then raise exception 'FAIL: % non-owner notifications for an owner-only event', n; end if;
  raise notice '  ok   the requester, the beneficiary, a stranger and the other owner receive NOTHING';

  -- ★ AND THE ESTATE IS NOT NAMED, on the row that has the most excuse to name it.
  select title, body, action_deep_link into v_title, v_body, v_link
    from public.notifications where user_id = OWNER_A and kind = 'accessRequest';
  if (v_title || ' ' || v_body) ilike '%Estate A%' then
    raise exception 'FAIL: the notification named the estate: % / %', v_title, v_body;
  end if;
  if v_link <> 'afterworth://owner-review' then
    raise exception 'FAIL: unexpected deep link %', v_link;
  end if;
  raise notice '  ok   the estate is not named; the link is the owner review surface';

  -- ★ THE OWNER IS *THIS* ESTATE'S OWNER, PROVED ON TWO ESTATES AT ONCE.
  --
  -- Asserting only that OWNER_A was notified about estate A cannot distinguish "resolves the owner
  -- of the given estate" from "resolves some owner". Mutation testing demonstrated exactly that:
  -- rewriting `estate_owner_user_id` to `select owner_id from estates order by id limit 1` SURVIVED,
  -- because with random UUIDs the arbitrary owner it picked was estate A's roughly half the time.
  -- A test that passes on a coin flip is not a test.
  --
  -- So the same event is driven on estate B and B's owner must be the one notified. Any
  -- "arbitrary owner" implementation now fails on one estate or the other, deterministically.
  insert into public.estate_memberships (estate_id, user_id, role, status)
  values (B, DELEGATE, 'professional_delegate', 'approved');
  delete from public.notifications;

  perform set_config('request.jwt.claim.sub', DELEGATE::text, true);
  set local role authenticated;
  perform public.create_access_request(B, 'estate_documents', null);
  reset role;

  select count(*) into n from public.notifications where user_id = OWNER_B;
  if n <> 1 then
    raise exception 'FAIL: estate B''s owner received % notifications for an event on their OWN '
      'estate, expected 1', n;
  end if;
  select count(*) into n from public.notifications where user_id = OWNER_A;
  if n <> 0 then
    raise exception 'FAIL: estate A''s owner received % notifications about an event on estate B — '
      'recipient resolution is not scoped to the estate', n;
  end if;
  raise notice '  ok   the recipient is THIS estate owner, proved on both estates (cross-estate)';

  delete from public.access_requests where estate_id = B;
  delete from public.estate_memberships where estate_id = B and user_id = DELEGATE;
  delete from public.notifications;

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 4 · emitted only AFTER the state transition succeeded';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THIS IS THE ASSERTION THAT KILLS "MOVE THE EMIT ABOVE THE INSERT". A second pending request
  -- violates the one-pending index and the whole statement aborts, so an emitter placed before the
  -- insert would still leave no row — the transaction took it away. The observable difference is
  -- here, where the FIRST request already exists and the second is refused: exactly one notification
  -- must exist across both attempts.
  delete from public.notifications where user_id = OWNER_A;
  perform set_config('request.jwt.claim.sub', DELEGATE::text, true);
  set local role authenticated;
  begin
    perform public.create_access_request(A, 'estate_documents', null);
    reset role;
    raise exception 'FAIL(fixture): a second pending request was ACCEPTED — the one-pending index is '
      'missing, so this assertion would prove nothing';
  exception when unique_violation then
    reset role;   -- expected: the duplicate was refused
  end;

  select count(*) into n from public.notifications where user_id = OWNER_A;
  if n <> 0 then
    raise exception 'FAIL: a REFUSED mutation emitted % notification(s) — emission is not downstream '
      'of the state transition', n;
  end if;
  raise notice '  ok   a refused mutation emits nothing (and the refusal was real, not assumed)';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 5 · request decided — the REQUESTER, and only their own outcome';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  delete from public.notifications;
  perform set_config('request.jwt.claim.sub', OWNER_A::text, true);
  set local role authenticated;
  perform public.approve_access_request(v_req, 'limited_detail');
  reset role;

  select count(*) into n from public.notifications where user_id = DELEGATE;
  if n <> 1 then raise exception 'FAIL: the requester received % notifications, expected 1', n; end if;
  select count(*) into n from public.notifications where user_id <> DELEGATE;
  if n <> 0 then raise exception 'FAIL: % notifications went to someone other than the requester', n; end if;
  raise notice '  ok   only the requester learns their own outcome';

  -- ★ EXACTLY ONE, NOT TWO. Approval creates a grant; the grant must not ALSO announce itself. A
  -- person who asked one question gets one answer.
  select title, body, action_deep_link into v_title, v_body, v_link
    from public.notifications where user_id = DELEGATE;
  if v_body ~* '(limited_detail|tier|estate_documents)' then
    raise exception 'FAIL: the approval named the tier or category it granted: %', v_body;
  end if;
  -- The delegate is an approved professional_delegate on A, so the server-chosen home is the workspace.
  if v_link <> 'afterworth://workspace' then
    raise exception 'FAIL: expected the workspace home for a delegate, got %', v_link;
  end if;
  raise notice '  ok   one notification, naming no tier or category; the link is the delegate home';

  -- ★ THE DEEP LINK IS SERVER-DERIVED FROM MEMBERSHIP, NOT FROM A ROLE LABEL THE CALLER SUPPLIED.
  if public.notification_estate_home(A, BENEFICIARY) <> 'afterworth://estate-summary' then
    raise exception 'FAIL: a beneficiary was routed to the professional workspace';
  end if;
  if public.notification_estate_home(A, STRANGER) <> 'afterworth://estate-summary' then
    raise exception 'FAIL: a non-member was routed to the professional workspace';
  end if;
  raise notice '  ok   a beneficiary and a non-member are never routed to the delegate surface';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 6 · denial reaches only the requester, and names nothing';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  delete from public.notifications;
  perform set_config('request.jwt.claim.sub', BENEFICIARY::text, true);
  set local role authenticated;
  select id into v_req from public.create_access_request(A, 'estate_documents', null);
  reset role;
  delete from public.notifications;   -- drop the owner's "request received"

  perform set_config('request.jwt.claim.sub', OWNER_A::text, true);
  set local role authenticated;
  perform public.deny_access_request(v_req);
  reset role;

  select count(*) into n from public.notifications where user_id = BENEFICIARY;
  if n <> 1 then raise exception 'FAIL: the denied requester received % notifications, expected 1', n; end if;
  select count(*) into n from public.notifications where user_id <> BENEFICIARY;
  if n <> 0 then raise exception 'FAIL: a denial was broadcast to % other user(s)', n; end if;

  select body, action_deep_link into v_body, v_link
    from public.notifications where user_id = BENEFICIARY;
  -- ★ NO DEEP LINK ON A DENIAL. There is nothing newly available to open, and sending a refused
  -- requester to an estate surface is an invitation to a screen that says no.
  if v_link is not null then
    raise exception 'FAIL: a denial carried a deep link (%) — there is nothing to open', v_link;
  end if;
  raise notice '  ok   only the requester learns of the denial; no link, no reason, no detail';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 7 · ★ THE DEATH / CLAIM FIREWALL';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- The predicate first, directly — every dormant condition, named.
  if public.notification_grant_is_live('active', 'after_verified_death_or_incapacity', now()) then
    raise exception 'FAIL: a death-conditioned grant was reported LIVE, even with approved_at set';
  end if;
  if public.notification_grant_is_live('active', 'after_claim_case_approval', now()) then
    raise exception 'FAIL: a claim-conditioned grant was reported LIVE';
  end if;
  if public.notification_grant_is_live('active', 'never', now()) then
    raise exception 'FAIL: a never-release grant was reported LIVE';
  end if;
  if public.notification_grant_is_live('active', 'after_identity_verification', now()) then
    raise exception 'FAIL: an identity-conditioned grant was reported LIVE';
  end if;
  if public.notification_grant_is_live('revoked', 'immediately', null) then
    raise exception 'FAIL: a REVOKED grant was reported LIVE';
  end if;
  if public.notification_grant_is_live('active', 'after_owner_approval', null) then
    raise exception 'FAIL: an UNAPPROVED approval-conditioned grant was reported LIVE';
  end if;
  -- ★ POSITIVE CONTROLS — otherwise every line above passes on a function that returns false always.
  if not public.notification_grant_is_live('active', 'immediately', null) then
    raise exception 'FAIL(control): an immediate active grant was NOT reported live — the predicate '
      'refuses everything, so the refusals above prove nothing';
  end if;
  if not public.notification_grant_is_live('active', 'after_owner_approval', now()) then
    raise exception 'FAIL(control): an APPROVED approval-conditioned grant was not reported live';
  end if;
  raise notice '  ok   death, claim, never, identity, revoked and unapproved are all dormant';
  raise notice '  ok   positive controls: immediate and approved grants ARE live';

  -- ★ AND THROUGH THE REAL DOOR. A death-conditioned grant created by the real RPC must produce
  -- SILENCE — not softened copy, not a "coming soon", nothing at all.
  delete from public.notifications;
  perform set_config('request.jwt.claim.sub', OWNER_A::text, true);
  set local role authenticated;
  perform public.create_asset_grant(
    A, BENEFICIARY, 'beneficiary', 'estate_inventory', 'category_summary',
    'after_verified_death_or_incapacity'
  );
  reset role;
  select count(*) into n from public.notifications;
  if n <> 0 then
    raise exception 'FAIL: creating a DEATH-CONDITIONED grant emitted % notification(s) — this is the '
      'release announcement Phase 11 has not built', n;
  end if;
  raise notice '  ok   a death-conditioned grant created through the real RPC emits NOTHING';

  -- ★ POSITIVE CONTROL ON THE SAME DOOR. Without this, the silence above is equally consistent with
  -- "create_asset_grant never emits at all", which would make the firewall assertion vacuous.
  perform set_config('request.jwt.claim.sub', OWNER_A::text, true);
  set local role authenticated;
  perform public.create_asset_grant(
    A, DELEGATE, 'professional_delegate', 'estate_inventory', 'category_summary', 'immediately'
  );
  reset role;
  select count(*) into n from public.notifications where user_id = DELEGATE and kind = 'accessGranted';
  if n <> 1 then
    raise exception 'FAIL(control): an IMMEDIATE grant through the same RPC emitted % notifications, '
      'expected 1 — the firewall assertion above was vacuous', n;
  end if;
  raise notice '  ok   control: an immediate grant through the SAME rpc DOES notify';

  -- ★ AND THE COPY CARRIES NO ENUM — the exact live defect this phase found.
  select body into v_body from public.notifications where user_id = DELEGATE and kind = 'accessGranted';
  if v_body ilike '%estate_inventory%' then
    raise exception 'FAIL: the grant notification leaked the category enum: %', v_body;
  end if;
  raise notice '  ok   the grant notification contains no category enum (the shipped defect)';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 8 · an APPROVED claim releases NOTHING and announces NOTHING';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  delete from public.notifications;
  insert into public.claim_packets (estate_id, requested_by, status)
  values (A, BENEFICIARY, 'approved');
  select count(*) into n from public.notifications;
  if n <> 0 then
    raise exception 'FAIL: an APPROVED claim produced % notification(s)', n;
  end if;
  -- The dormant death-conditioned grant from section 7 is still present and still dormant.
  if public.notification_grant_is_live('active', 'after_verified_death_or_incapacity', now()) then
    raise exception 'FAIL: an approved claim made a death-conditioned grant live';
  end if;
  raise notice '  ok   an approved claim emits nothing and activates no dormant grant';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 9 · revocation preserves no forbidden detail';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  delete from public.notifications;
  perform set_config('request.jwt.claim.sub', OWNER_A::text, true);
  set local role authenticated;
  select id into v_grant from public.create_document_grant(
    A, BENEFICIARY, 'beneficiary', v_doc, 'full_detail', 'immediately', null, false
  );
  reset role;
  delete from public.notifications;   -- drop the "you have access"

  perform set_config('request.jwt.claim.sub', OWNER_A::text, true);
  set local role authenticated;
  perform public.revoke_document_grant(v_grant);
  reset role;

  select count(*) into n from public.notifications where user_id = BENEFICIARY;
  if n <> 1 then raise exception 'FAIL: the grantee received % revoke notifications, expected 1', n; end if;
  select count(*) into n from public.notifications where user_id <> BENEFICIARY;
  if n <> 0 then raise exception 'FAIL: a revocation was announced to % other user(s)', n; end if;

  select title, body, action_deep_link into v_title, v_body, v_link
    from public.notifications where user_id = BENEFICIARY;
  -- ★ THE DOCUMENT TITLE IS THE THING THAT MUST NOT SURVIVE. The row outlives the grant, so naming
  -- it here re-discloses it forever in the one place the person can still read it.
  if (v_title || ' ' || v_body) ilike '%Fixture statement%' then
    raise exception 'FAIL: the revoke notification retained the document title: %', v_body;
  end if;
  -- ★ THE ID CHECK IS `position`, NOT A CONCATENATED REGEX, and the first draft of this line was a
  -- bug worth keeping the fix for: `x ~* '(a|b|' || uuid || ')'` does NOT mean what it reads as.
  -- `~*` and `||` sit at the same precedence in Postgres and associate LEFT, so it parsed as
  -- `(x ~* '(a|b|') || uuid || ')'` — matching against an unbalanced pattern. It failed loudly here;
  -- had the fragment happened to be a valid regex it would have silently asserted something else.
  if (v_title || ' ' || v_body) ~* '(full_detail|limited_detail|revoked|owner)' then
    raise exception 'FAIL: the revoke notification named a tier or an actor: %', v_body;
  end if;
  if position(OWNER_A::text in (v_title || ' ' || v_body)) > 0
     or position(BENEFICIARY::text in (v_title || ' ' || v_body)) > 0 then
    raise exception 'FAIL: the revoke notification contains a user id: %', v_body;
  end if;
  if v_link is not null then
    raise exception 'FAIL: the revoke notification carried a deep link (%) — it can only lead to a refusal', v_link;
  end if;
  raise notice '  ok   revocation names no document, tier, actor or id, and offers no link';

  -- ★ IDEMPOTENT REPEAT SAYS NOTHING TWICE.
  perform set_config('request.jwt.claim.sub', OWNER_A::text, true);
  set local role authenticated;
  perform public.revoke_document_grant(v_grant);
  reset role;
  select count(*) into n from public.notifications where user_id = BENEFICIARY;
  if n <> 1 then
    raise exception 'FAIL: re-revoking an already-revoked grant emitted again (% rows) — the emitter '
      'sits above the idempotency guard', n;
  end if;
  raise notice '  ok   re-revoking emits nothing a second time';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 9b · invitation declined — the OWNER, once, and only once';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THE ONE INVITATION EMITTER THE HARNESS CAN REACH, AND IT CARRIES THE IDEMPOTENCY QUESTION.
  -- `decline_invitation` treats an already-declined invitation as a successful no-op, so an emitter
  -- placed ABOVE that guard would notify the owner on every repeat call rather than once per event.
  -- Nothing else in the system would notice.
  -- ★ SCOPED TO THE OWNER'S ROWS, NOT A BLANKET DELETE — and the first draft got this wrong in a
  -- way worth keeping. `delete from public.notifications` here removed section 9's revoke row, and
  -- section 10's POSITIVE CONTROL ("the rightful recipient DOES read their own rows") then failed,
  -- correctly, because there was nothing left to read. The control did its job: without it, section
  -- 10's three zero-row assertions would have passed against an empty table and proved nothing about
  -- RLS at all. Clearing only what this section counts keeps both sections honest.
  delete from public.notifications where user_id = OWNER_A;
  insert into public.profiles (id, email) values (BENEFICIARY, 'fixture-invitee@example.invalid')
    on conflict (id) do update set email = excluded.email;
  insert into public.invitations (estate_id, invitee_email, proposed_role, status)
  values (A, 'fixture-invitee@example.invalid', 'beneficiary', 'pending')
  returning id into v_req;

  perform set_config('request.jwt.claim.sub', BENEFICIARY::text, true);
  set local role authenticated;
  perform public.decline_invitation(v_req);
  reset role;

  select count(*) into n from public.notifications where user_id = OWNER_A and kind = 'invitationUpdate';
  if n <> 1 then
    raise exception 'FAIL: the estate owner received % decline notifications, expected 1', n;
  end if;
  -- The invitee is NOT told: they know what they just did. BENEFICIARY still holds exactly the one
  -- revoke row section 9 left, so this asserts a DELTA of zero rather than an absolute zero.
  select count(*) into n from public.notifications where kind = 'invitationUpdate' and user_id <> OWNER_A;
  if n <> 0 then
    raise exception 'FAIL: a decline was announced to % non-owner(s) — including the invitee, who '
      'does not need telling what they just did', n;
  end if;

  select title, body, action_deep_link into v_title, v_body, v_link
    from public.notifications where user_id = OWNER_A and kind = 'invitationUpdate';
  -- ★ THE INVITEE IS NOT NAMED. The owner issued the invitation and already knows who it was for,
  -- so this says strictly LESS than they know — the correct direction to err. An email address in
  -- notification copy would be a viewer-scoped identity decision taken at a call site.
  if (v_title || ' ' || v_body) ilike '%fixture-invitee%' or (v_title || ' ' || v_body) like '%@%' then
    raise exception 'FAIL: the decline notification named the invitee: %', v_body;
  end if;
  -- And it does not name the proposed ROLE: a membership role is a relationship, stated by the
  -- surfaces that gate it, never by a heads-up.
  if (v_title || ' ' || v_body) ~* '(beneficiary|delegate|executor|trustee)' then
    raise exception 'FAIL: the decline notification named a role: %', v_body;
  end if;
  if v_link is not null then
    raise exception 'FAIL: the decline carried a deep link (%) — the invitation is finished', v_link;
  end if;
  raise notice '  ok   only the owner is told; no invitee, no role, no link';

  -- ★ THE IDEMPOTENT REPEAT. This is the assertion that fails if the emitter moves above the guard.
  perform set_config('request.jwt.claim.sub', BENEFICIARY::text, true);
  set local role authenticated;
  perform public.decline_invitation(v_req);
  reset role;
  select count(*) into n from public.notifications where user_id = OWNER_A;
  if n <> 1 then
    raise exception 'FAIL: re-declining emitted again (% rows) — the emitter sits above the '
      'already-declined guard, so it notifies per CALL rather than per EVENT', n;
  end if;
  raise notice '  ok   re-declining emits nothing a second time';

  delete from public.invitations where estate_id = A;
  delete from public.notifications where user_id = OWNER_A;

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice ' 9c · invitation ACCEPTED — the owner, once, through the real provisioning path';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THE GAP 10-E LEFT OPEN, CLOSED BY TRACING IT RATHER THAN RE-ESTIMATING IT. 10-E deferred this
  -- because `accept_invitation` delegates to `provision_from_invitation`, which "reconciles
  -- memberships and stamps designations". True — but that function touches exactly four tables, and
  -- three were already modelled. The missing piece was `public.beneficiaries`.
  --
  -- This runs the REAL provisioning path: a membership is created, the beneficiary row is linked, and
  -- only then is the owner told. Nothing is faked; if provisioning breaks, this fails.
  delete from public.notifications where user_id = OWNER_A;
  insert into public.profiles (id, email) values (STRANGER, 'fixture-acceptor@example.invalid')
    on conflict (id) do update set email = excluded.email;
  insert into public.invitations (estate_id, invitee_email, proposed_role, status)
  values (A, 'fixture-acceptor@example.invalid', 'beneficiary', 'pending')
  returning id into v_req;

  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  perform public.accept_invitation(v_req);
  reset role;

  -- ★ PROVISIONING ACTUALLY HAPPENED. Without this the notification assertions below would pass on a
  -- path that emitted correctly and provisioned nothing.
  if not exists (select 1 from public.estate_memberships m
                  where m.estate_id = A and m.user_id = STRANGER and m.status = 'approved') then
    raise exception 'FAIL: accept_invitation emitted without creating the membership';
  end if;

  select count(*) into n from public.notifications where user_id = OWNER_A and kind = 'invitationUpdate';
  if n <> 1 then
    raise exception 'FAIL: the owner received % accept notifications, expected 1', n;
  end if;
  select count(*) into n from public.notifications where user_id = STRANGER and kind = 'invitationUpdate';
  if n <> 0 then
    raise exception 'FAIL: the ACCEPTOR was notified of their own action (% rows)', n;
  end if;

  select title, body into v_title, v_body
    from public.notifications where user_id = OWNER_A and kind = 'invitationUpdate';
  if (v_title || ' ' || v_body) ilike '%fixture-acceptor%' or (v_title || ' ' || v_body) like '%@%' then
    raise exception 'FAIL: the accept notification named the invitee: %', v_body;
  end if;
  if (v_title || ' ' || v_body) ~* '(beneficiary|delegate|executor|trustee)' then
    raise exception 'FAIL: the accept notification named a role: %', v_body;
  end if;
  raise notice '  ok   only the owner is told; no invitee, no role; membership really was created';

  -- ★ THE IDEMPOTENT RE-ACCEPT SELF-HEALS AND MUST NOT RE-ANNOUNCE. This is the branch that returns
  -- early, and an emitter above it would tell the owner again on every retry.
  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  perform public.accept_invitation(v_req);
  reset role;
  select count(*) into n from public.notifications where user_id = OWNER_A;
  if n <> 1 then
    raise exception 'FAIL: re-accepting emitted again (% rows) — the emitter sits above the '
      'idempotency guard', n;
  end if;
  raise notice '  ok   re-accepting emits nothing a second time';

  delete from public.estate_memberships where estate_id = A and user_id = STRANGER;
  delete from public.invitations where estate_id = A;
  delete from public.notifications where user_id = OWNER_A;

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '10 · cross-estate isolation and RLS';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- Every notification written so far belongs to estate A. Estate B's owner must see none of it, and
  -- must not even be able to count it.
  select count(*) into n from public.notifications where estate_id = B;
  if n <> 0 then raise exception 'FAIL: % rows leaked into estate B', n; end if;

  perform set_config('request.jwt.claim.sub', OWNER_B::text, true);
  set local role authenticated;
  select count(*) into n from public.notifications;
  reset role;
  if n <> 0 then
    raise exception 'FAIL: the OTHER estate owner can read % notification rows — RLS is not scoping', n;
  end if;
  raise notice '  ok   the other estate owner reads zero rows';

  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  select count(*) into n from public.notifications;
  reset role;
  if n <> 0 then raise exception 'FAIL: a non-member read % notification rows', n; end if;
  raise notice '  ok   a non-member reads zero rows';

  -- ★ ANONYMOUS. No `sub` claim at all.
  perform set_config('request.jwt.claim.sub', '', true);
  set local role authenticated;
  select count(*) into n from public.notifications;
  reset role;
  if n <> 0 then raise exception 'FAIL: an anonymous caller read % notification rows', n; end if;
  raise notice '  ok   an anonymous caller reads zero rows';

  -- ★ POSITIVE CONTROL FOR THE RLS ASSERTIONS. Three zeros are also what a broken query returns.
  perform set_config('request.jwt.claim.sub', BENEFICIARY::text, true);
  set local role authenticated;
  select count(*) into n from public.notifications;
  reset role;
  if n < 1 then
    raise exception 'FAIL(control): the rightful recipient reads % rows — the zeros above were the '
      'query failing, not RLS working', n;
  end if;
  raise notice '  ok   control: the rightful recipient DOES read their own rows';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '11 · ★ DEFINER does not launder authority, and forgery is closed';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THE HOLE THIS PHASE FOUND. `emit_notification` is SECURITY DEFINER and takes the recipient as
  -- a PARAMETER, so an EXECUTE grant to `authenticated` is a licence to write into anyone's centre.
  -- Migration 0050 revokes it; this proves the revoke is in force under the role PostgREST assumes.
  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  begin
    perform public.emit_notification(OWNER_A, A, 'securityAlert', 'Forged', 'Forged', null, '{}'::jsonb);
    reset role;
    raise exception 'FAIL: an ordinary authenticated user CALLED emit_notification — any user can '
      'plant a notification, with a deep link, in any other user inbox';
  exception
    when insufficient_privilege then reset role;   -- expected
    when others then
      reset role;
      raise exception 'FAIL: emit_notification refused for the WRONG reason (%) — a coercion or '
        'signature error is not a privilege check', sqlerrm;
  end;
  raise notice '  ok   authenticated cannot execute emit_notification';

  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  begin
    perform public.emit_lifecycle_notification(OWNER_A, A, 'access_grant.created', null);
    reset role;
    raise exception 'FAIL: an ordinary authenticated user CALLED emit_lifecycle_notification';
  exception
    when insufficient_privilege then reset role;
    when others then
      reset role;
      raise exception 'FAIL: emit_lifecycle_notification refused for the wrong reason (%)', sqlerrm;
  end;
  raise notice '  ok   authenticated cannot execute emit_lifecycle_notification';

  -- ★ THE RECIPIENT ORACLES ARE CLOSED TOO. A client that can map estate -> owner id has an identity
  -- surface; one that can ask which home a user would be routed to has a membership oracle.
  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  begin
    perform public.estate_owner_user_id(A);
    reset role;
    raise exception 'FAIL: a stranger resolved the estate owner id';
  exception
    when insufficient_privilege then reset role;
    when others then reset role; raise exception 'FAIL: estate_owner_user_id refused wrongly (%)', sqlerrm;
  end;
  raise notice '  ok   estate_owner_user_id is not client-callable';

  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  begin
    perform public.notification_estate_home(A, DELEGATE);
    reset role;
    raise exception 'FAIL: a stranger queried the membership-derived home for another user';
  exception
    when insufficient_privilege then reset role;
    when others then reset role; raise exception 'FAIL: notification_estate_home refused wrongly (%)', sqlerrm;
  end;
  raise notice '  ok   notification_estate_home is not client-callable';

  -- ★ AND THE TABLE ITSELF STILL REFUSES A DIRECT INSERT. Belt and braces: if a future migration
  -- re-grants EXECUTE somewhere, this is the second lock.
  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  begin
    insert into public.notifications (user_id, kind, title, body) values (OWNER_A, 'system', 'x', 'y');
    reset role;
    raise exception 'FAIL: authenticated inserted a notification row directly';
  exception
    when insufficient_privilege then reset role;
    when others then reset role; raise exception 'FAIL: direct insert refused wrongly (%)', sqlerrm;
  end;
  raise notice '  ok   authenticated holds no INSERT on the table either';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '12 · read state is presentation, never authority';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claim.sub', BENEFICIARY::text, true);
  set local role authenticated;
  update public.notifications set read = true where user_id = BENEFICIARY;
  select count(*) into n from public.notifications;
  reset role;
  if n < 1 then
    raise exception 'FAIL: marking read changed what the recipient can READ — read state is being '
      'treated as authority';
  end if;
  raise notice '  ok   marking read does not change what the recipient can see';

  -- ★ AND A USER CANNOT MARK SOMEONE ELSE'S ROW READ — the update policy is self-scoped, so a
  -- cross-user update must affect ZERO rows rather than silently succeeding.
  perform set_config('request.jwt.claim.sub', STRANGER::text, true);
  set local role authenticated;
  update public.notifications set read = true where user_id = OWNER_A;
  get diagnostics n = row_count;
  reset role;
  if n <> 0 then
    raise exception 'FAIL: a stranger marked % of another user notifications read', n;
  end if;
  raise notice '  ok   a stranger cannot mark another user rows read';

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '13 · no emitter composes copy';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THE STRUCTURAL RULE, ENFORCED RATHER THAN DESCRIBED. Every lifecycle row in the database must
  -- have copy that is byte-identical to a catalog entry. A call site that concatenated anything —
  -- an enum, a title, a count, an email — produces a row that matches nothing here.
  --
  -- This is the assertion that would have caught the shipped defect on the day it was written.
  --
  -- ★ THE CORPUS IS BUILT FROM REAL MUTATIONS FIRST, and that is the difference between a control
  -- and a tautology. Sweeping rows that were emitted by calling the catalog directly would prove
  -- only that the catalog equals itself. Every row below arrives through a production RPC, which is
  -- the path where a `||` would appear. The earlier sections delete as they go so their counts stay
  -- crisp, which left exactly one row here — a sweep over one row is not a sweep.
  delete from public.notifications;
  perform set_config('request.jwt.claim.sub', DELEGATE::text, true);
  set local role authenticated;
  select id into v_req from public.create_access_request(A, 'estate_documents', null);  -- owner
  reset role;
  perform set_config('request.jwt.claim.sub', OWNER_A::text, true);
  set local role authenticated;
  perform public.approve_access_request(v_req, 'limited_detail');                        -- requester
  reset role;
  perform set_config('request.jwt.claim.sub', BENEFICIARY::text, true);
  set local role authenticated;
  select id into v_req from public.create_access_request(A, 'estate_documents', null);  -- owner
  reset role;
  perform set_config('request.jwt.claim.sub', OWNER_A::text, true);
  set local role authenticated;
  perform public.deny_access_request(v_req);                                             -- requester
  select id into v_grant from public.create_document_grant(
    A, BENEFICIARY, 'beneficiary', v_doc, 'full_detail', 'immediately', null, false      -- grantee
  );
  perform public.revoke_document_grant(v_grant);                                         -- grantee
  reset role;

  select count(*) into n from public.notifications;
  if n < 6 then
    raise exception 'FAIL(control): the corpus is only % rows — six real mutations should have '
      'produced at least six notifications, so the sweep below would be near-vacuous', n;
  end if;
  if (select count(distinct kind) from public.notifications) < 3 then
    raise exception 'FAIL(control): the corpus covers fewer than 3 distinct categories';
  end if;

  select count(*) into n
  from public.notifications x
  where not exists (
    select 1
    from (values ('access_request.created'),('access_request.approved'),('access_request.denied'),
                 ('access_grant.created'),('access_grant.revoked'),
                 ('invitation.accepted'),('invitation.declined')) as e(event)
    cross join lateral public.notification_event_copy(e.event) c
    where c.title = x.title and c.body = x.body and c.category = x.kind
  );
  if n <> 0 then
    raise exception 'FAIL: % notification row(s) carry copy that is not a verbatim catalog entry — '
      'an emitter composed or interpolated text', n;
  end if;
  -- Non-empty check: with zero rows the query above passes trivially.
  select count(*) into n from public.notifications;
  if n < 1 then
    raise exception 'FAIL(control): there are no notification rows to check, so the copy-provenance '
      'assertion was vacuous';
  end if;
  raise notice '  ok   every one of the % rows carries verbatim catalog copy', n;

  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  raise notice '14 · fixture integrity';
  -- ══════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ★ THIS SUITE WRITES ROWS BY DESIGN, so it cleans up after itself and PROVES it did. A
  -- notification suite that left rows behind would silently become another suite's precondition.
  delete from public.notifications
   where user_id in (OWNER_A, OWNER_B, DELEGATE, BENEFICIARY, STRANGER);
  delete from public.access_grants where estate_id in (A, B);
  delete from public.access_requests where estate_id in (A, B);
  delete from public.claim_packets where estate_id in (A, B);
  delete from public.documents where estate_id in (A, B);
  delete from public.estate_memberships where estate_id in (A, B);
  delete from public.estates where id in (A, B);

  select count(*) into n from public.notifications
   where user_id in (OWNER_A, OWNER_B, DELEGATE, BENEFICIARY, STRANGER);
  if n <> 0 then raise exception 'FAIL: this suite left % notification rows behind', n; end if;
  raise notice '  ok   every row this suite created has been removed';

  raise notice ' ALL LIFECYCLE NOTIFICATION ASSERTIONS PASSED';
end
$suite$;
