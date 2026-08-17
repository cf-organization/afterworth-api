-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-OC · PHASE C — THE OPERATOR RE-NOTICE, AND THE ONE PLACE ITS ELIGIBILITY IS DECIDED
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THIS FILE OWNS.
--
--   owner_notice_episode_kinds()          the kind SET that constitutes one episode   [INTERNAL]
--   owner_notice_reissue_kind()           the kind a re-notice takes                  [INTERNAL]
--   owner_notice_reissue_assessment()     may this episode be re-noticed, and why not [INTERNAL]
--   reissue_owner_safety_notice()         the operator door                [admin, AAL2 + fresh]
--
-- ★ THE ASSESSMENT IS A SEPARATE FUNCTION FOR ONE REASON, AND IT IS NOT TIDINESS. The operator
-- console must show "Re-send owner safety notice" exactly when the door would accept it. Any second
-- opinion — a TypeScript mirror, a status list in a projection, a `case` expression in the case file
-- — is a policy that drifts, and the failure mode is an operator clicking a control the server then
-- refuses, or (worse) a control hidden on an estate that genuinely needs remediating. So the
-- projection and the door call the SAME function, and `db/tests/release_safety_authorization.sql`
-- §11 asserts they agree on every fixture rather than assuming they must.
--
-- ★ A RE-NOTICE IS AN APPEND, NEVER A RESET. It writes a NEW row and retires the previous one with a
-- pointer. Nothing about the predecessor is rewritten — not `requested_at`, not `attempts`, not
-- `failure_class`, not `dispatched_at`, not `notice_accepted_at`, not `case_id`, not `generation`.
-- That evidence is WHY the reissue was warranted, and an operator reconstructing a disputed release a
-- year later needs to see the failure that prompted it, not a row that was quietly returned to the
-- queue. Requeuing a terminal row would also destroy the one signal that distinguishes an accidental
-- retry from a deliberate second warning (see IDEMPOTENCY below).
--
-- ★ IT IS PROTECTIVE, SO IT IS NOT A TWO-PERSON ACT. `authorize_release` requires two distinct
-- reviewers because it DISCLOSES an estate irreversibly. A re-notice discloses nothing: it queues a
-- message telling a possibly-living owner that a process is running against their estate, which is
-- the control that protects them. Requiring a second operator would make the protective act harder
-- than the harmful one — and the whole D7 monotonicity property is that issuing a notice can only
-- ever ADD safety. It is nevertheless admin-gated, AAL2, freshness-bound, reason-required and fully
-- audited, because an operator who could queue mail at will is an operator who could mail a living
-- person repeatedly.
--
-- ★ WHAT A SUCCESSFUL CALL MEANS, STATED SO NOTHING DOWNSTREAM CAN RENAME IT:
--
--        NEW WARNING QUEUED.
--
--   It is NOT "the owner was warned", NOT "the provider accepted", NOT "delivered". The new row
--   starts `queued` with `notice_accepted_at` NULL and only `record_owner_notice_outcome`'s
--   `providerAccepted` branch may ever stamp it. Reissuing creates no acceptance authority
--   whatsoever, which is exactly why an operator cannot use this door to unblock a release.
--
-- ★ IDEMPOTENCY, AND THE DISTINCTION IT ENCODES. `lib/ownerNotices/drain.ts` builds the provider
-- Idempotency-Key from the ROW id (`afterworth/owner-notice/<id>`). A reclaim or a retry within one
-- generation therefore replays the SAME key — the provider is asked to no-op a repeat. A deliberate
-- re-notice is a new row with a new id, so it carries a NEW key and is a genuinely new message.
--
--        ACCIDENTAL RETRY   → same idempotency domain
--        DELIBERATE REISSUE → new idempotency domain
--
--   That distinction is a property of the id, not of a flag anybody remembers to set. Delivery
--   semantics remain AT-LEAST-ONCE; no provider exactly-once behaviour is claimed anywhere.
--
-- ★ AND THE OWNER IS TOLD NOTHING NEW. The email template takes only a link — no kind, no
-- generation, no attempt count, no failure class. The second message is byte-identical to the first.
-- Internal state is not user copy, and on this channel that rule is sharper than usual.
--
-- Source of truth — re-apply on DB reset. Deploys via `db/bundles/owner_notice_reissue_bundle.sql`,
-- after migration 0059.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- owner_notice_episode_kinds() → text[]                                                [INTERNAL]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE EPISODE IS A SET OF KINDS, AND IT IS DEFINED EXACTLY ONCE. Phase A wrote
-- `notice_kind = 'death_process.window_opened'` as a literal in the readiness census, in migration
-- 0058's blast-radius report, and in the partial unique index. The moment a re-notice takes a second
-- kind, every one of those literals becomes a filter that CANNOT SEE THE REMEDY: a remediated estate
-- would keep reporting as refused, its acceptance would never be counted, and the instrument built to
-- measure the Phase D blast radius would be blind to the mechanism built to shrink it.
--
-- A function rather than three copies, for the reason `owner_notice_claim_visibility()` gives: two
-- literals are two opinions about the same bytes, and the first time they drift the census stops
-- describing what the door actually does.
--
-- `immutable` because the vocabulary is a compile-time constant of this deployment, not a row.
create or replace function public.owner_notice_episode_kinds()
 returns text[]
 language sql
 immutable
 set search_path to 'public'
as $function$
  select array['death_process.window_opened', 'death_process.window_renotice']::text[];
$function$;
revoke execute on function public.owner_notice_episode_kinds() from public, anon, authenticated;

comment on function public.owner_notice_episode_kinds() is
  'The owner-safety notice kinds that constitute ONE episode (Phase 11-OC / Phase C): the initial '
  'window-opened dispatch and every deliberate operator re-notice. Single-sourced so the readiness '
  'census, the operator projection and the re-notice routine cannot disagree about which rows belong '
  'to the episode — a literal in any one of them would make the remedy invisible to the instrument '
  'that measures whether the remedy worked. INTERNAL: no client role may read the vocabulary.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- owner_notice_reissue_kind() → text                                                   [INTERNAL]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ A RE-NOTICE IS NOT THE WINDOW OPENING. `death_process.window_opened` records a lifecycle
-- transition that happened once, at a specific instant, and stamped `owner_notified_at`. A second row
-- carrying that kind would make the outbox assert the window opened twice — a false statement about
-- the state machine, in the table an investigator reads to reconstruct what the owner was told.
create or replace function public.owner_notice_reissue_kind()
 returns text
 language sql
 immutable
 set search_path to 'public'
as $function$
  select 'death_process.window_renotice'::text;
$function$;
revoke execute on function public.owner_notice_reissue_kind() from public, anon, authenticated;

comment on function public.owner_notice_reissue_kind() is
  'The notice_kind a deliberate operator re-notice takes (Phase 11-OC / Phase C). Distinct from '
  'death_process.window_opened so a second warning is never recorded as the initial window-opening '
  'event. Both kinds are members of owner_notice_episode_kinds().';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- owner_notice_reissue_assessment(p_case) → jsonb                                      [INTERNAL]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ ONE POLICY, TWO CALLERS. `reissue_owner_safety_notice` acts on this verdict; the operator
-- projection renders it. Neither restates it.
--
-- ★ IT IS `stable`, WHICH IS WHY THE DOOR TAKES ITS LOCKS FIRST. A stable function reads the calling
-- statement's snapshot. Called from the projection that is a read and correct; called from the door
-- it is correct ONLY because the door has already locked the case row and the current-generation row,
-- so the state it reads cannot move between the verdict and the write. The lock order is stated at
-- the door and is part of this function's contract rather than an implementation detail of its
-- caller.
--
-- ★ EVERY REFUSAL HAS A NAME, AND THE SET IS CLOSED. A fall-through would let a future status join a
-- neighbouring bucket silently — the same nameless-gap failure the censuses are written to avoid.
-- `notice_not_reissuable` exists so a seventh status shows up as an explicit unclassified refusal.
--
-- ★ IT NEVER RETURNS AN ADDRESS. `owner_channel_resolvable` answers the operator's real question —
-- "will this succeed" — and answers "what is this living person's address" not at all. That is the
-- same trade `admin_list_death_verification_cases` already makes, for the same reason.
create or replace function public.owner_notice_reissue_assessment(p_case uuid)
 returns jsonb
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare
  v_c          public.death_verification_cases%rowtype;
  v_state      text;
  v_canonical  uuid;
  v_row        public.owner_notice_outbox%rowtype;
  v_owner      uuid;
  v_resolvable boolean;
  v_reason     text;
  v_refusal    text;
begin
  if p_case is null then
    return jsonb_build_object('eligible', false, 'refusal_code', 'case_not_found');
  end if;

  select * into v_c from public.death_verification_cases c where c.id = p_case;
  if not found then
    return jsonb_build_object('eligible', false, 'refusal_code', 'case_not_found');
  end if;

  -- ★ THE EPISODE KEY IS RESOLVED CANONICALLY AND THE CALLER'S CASE IS COMPARED AGAINST IT — never
  -- trusted as the episode. Identical derivation to `dispatch_owner_safety_notice` and to the
  -- readiness census: the newest VERIFIED case for this estate. A historical case on the same estate
  -- is a real, reachable input (`rejected` and `cancelled` both return the lifecycle to `active`, and
  -- a later process opens a new case), and remediating a current death process using a notice from an
  -- older one is the estate-scope defect this whole phase exists to close.
  select c.id into v_canonical
    from public.death_verification_cases c
   where c.estate_id = v_c.estate_id and c.status = 'verified'
   order by c.decided_at desc
   limit 1;

  select l.state into v_state from public.estate_lifecycle l where l.estate_id = v_c.estate_id;
  v_state := coalesce(v_state, 'active');

  v_owner := public.estate_owner_user_id(v_c.estate_id);
  v_resolvable := exists (
    select 1 from auth.users u
     where u.id = v_owner and btrim(coalesce(u.email, '')) <> ''
  );

  -- The CURRENT generation of this episode: the row nothing supersedes, across BOTH episode kinds.
  select * into v_row
    from public.owner_notice_outbox o
   where o.case_id = p_case
     and o.channel = 'email'
     and o.notice_kind = any (public.owner_notice_episode_kinds())
     and o.superseded_by is null
   limit 1;

  -- ── THE REFUSAL LADDER, IN THE ORDER THE DOOR APPLIES IT ─────────────────────────────────────
  if v_canonical is null then
    v_refusal := 'no_verified_case';
  elsif v_canonical <> p_case then
    -- Covers BOTH "this is a historical case on an estate that has moved on" and "this case was
    -- never verified". The operator's next action is the same in either: work the current case.
    v_refusal := 'case_not_current';
  elsif v_state not in ('owner_notification_dispatched', 'challenge_window') then
    -- ★ THE PERMITTED STATES ARE THE TWO IN WHICH A WARNING STILL MEANS SOMETHING. Before dispatch
    -- there is nothing to re-send (the remedy is dispatch); after a halt or a release the process the
    -- notice describes is over, and mailing a living owner about a concluded process is a false alarm.
    v_refusal := 'invalid_reissue_state';
  elsif v_row.id is null then
    -- Fail closed, and deliberately NOT "dispatch instead". Creating an initial dispatch from this
    -- door would be a second, unaudited entry point into a lifecycle transition.
    v_refusal := 'no_current_notice';
  elsif v_row.status = 'queued' then
    v_refusal := 'notice_still_queued';        -- the ordinary drain still owns it
  elsif v_row.status = 'processing' then
    v_refusal := 'notice_still_processing';    -- OB-1 visibility/reclaim still owns it
  elsif v_row.status = 'dispatched' and v_row.notice_accepted_at is not null then
    v_refusal := 'notice_already_accepted';    -- provider acceptance is established; nothing to remedy
  elsif v_row.status = 'cancelled' then
    -- Defence in depth. Nothing in production writes 'cancelled'; one test fixture does, by direct
    -- UPDATE. Named anyway, because "currently unreachable" is a statement about today's code.
    v_refusal := 'notice_cancelled';
  elsif v_row.status = 'failedPermanent' then
    -- ★ THE VOCABULARY REASON IS DERIVED FROM THE PREDECESSOR, NEVER SUPPLIED. A caller-supplied
    -- value would let an operator relabel an outcomeUncertain reissue as a failed one.
    v_reason := case when v_row.failure_class = 'stale_beyond_age_gate'
                     then 'prior_stale_beyond_age_gate'
                     else 'prior_failed_permanent' end;
  elsif v_row.status = 'outcomeUncertain' then
    v_reason := 'prior_outcome_uncertain';
  elsif v_row.status = 'dispatched' and v_row.notice_accepted_at is null then
    -- ★ THE LEGACY CLASS, AND IT IS LOAD-BEARING. `dispatched` is NOT proof of the Phase A acceptance
    -- fact: every row written before Phase A carries that status with a NULL stamp, because the
    -- stamp did not exist. Refusing this class on the strength of its status would leave exactly the
    -- population Phase D blocks with no route to a remedy — which is the reason Phase C precedes D.
    -- It is structurally unreachable for rows written AFTER Phase A (status and acceptance are set in
    -- one UPDATE), so a row in this shape is an unambiguous pre-Phase-A marker.
    v_reason := 'legacy_no_acceptance_record';
  else
    -- NOT a fall-through: a status outside the six lands here BY NAME, so a widened CHECK constraint
    -- shows up as an explicit refusal instead of joining a neighbouring branch.
    v_refusal := 'notice_not_reissuable';
  end if;

  -- ★ RESOLVABILITY IS CHECKED LAST, AND ONLY WHEN EVERYTHING ELSE PASSED, so an unreachable owner
  -- does not mask a more informative refusal. Fail closed: a row that cannot be sent must not be
  -- manufactured merely to satisfy a remediation workflow — it would settle failedPermanent on the
  -- next drain and leave the episode worse off, with a second dead generation and the evidence of the
  -- first one retired.
  if v_refusal is null and not v_resolvable then
    v_refusal := 'owner_channel_unreachable';
  end if;

  return jsonb_build_object(
    'eligible',                v_refusal is null,
    'refusal_code',            v_refusal,
    'case_is_current',         v_canonical is not null and v_canonical = p_case,
    'lifecycle_state',         v_state,
    'owner_channel_resolvable', v_resolvable,
    'prior_notice_id',         v_row.id,
    'prior_generation',        v_row.generation,
    'prior_status',            v_row.status,
    'prior_notice_kind',       v_row.notice_kind,
    'prior_failure_class',     v_row.failure_class,
    'prior_accepted',          v_row.id is not null and v_row.notice_accepted_at is not null,
    'next_generation',         case when v_refusal is null then v_row.generation + 1 end,
    'reissue_reason',          v_reason
  );
end $function$;
revoke execute on function public.owner_notice_reissue_assessment(uuid)
  from public, anon, authenticated;

comment on function public.owner_notice_reissue_assessment(uuid) is
  'The ONE decision about whether an episode may be re-noticed (Phase 11-OC / Phase C), consumed by '
  'both reissue_owner_safety_notice and the operator case-file projection so the console can never '
  'offer an action the door refuses. Every refusal carries a NAMED code from a closed set. Reports '
  'owner_channel_resolvable as a BOOLEAN and never an address. INTERNAL — its callers are gated; a '
  'client role cannot reach it.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- reissue_owner_safety_notice(p_case, p_reason) → jsonb                       [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE PARAMETER LIST IS THE SAFETY PROPERTY, AND WHAT IS ABSENT MATTERS MORE THAN WHAT IS PRESENT.
--
--   · NO RECIPIENT. The address is resolved inside this definer from `auth.users`, exactly as the
--     initial dispatch resolves it. Re-notice is not a recipient-edit feature, and a parameter here
--     would turn a remediation door into a way to mail an arbitrary address a message about somebody
--     else's estate.
--   · NO GENERATION. Computed under the predecessor's row lock, never supplied and never from an
--     unlocked `max()`.
--   · NO `reissue_reason` VOCABULARY VALUE. Derived from the predecessor's own status and
--     failure_class, so an operator cannot relabel an uncertain outcome as a definitive failure.
--   · NO ESTATE. The episode key is the CASE; taking an estate would invite the caller to name a
--     process, and the whole defect class here is a notice from one death process authorizing
--     another.
--   · NO STATUS, NO ACCEPTANCE TIMESTAMP. The new row starts `queued` with NULL acceptance and there
--     is no parameter through which either could be seeded.
--
-- `p_reason` is the operator's own free-text justification for the AUDIT. It is a different thing
-- from `reissue_reason` — one is why THIS PERSON acted, the other is what the PREDECESSOR's state
-- was — and conflating them is how a closed vocabulary becomes a text box.
--
-- ★ LOCK ORDER, WHICH IS THE CONCURRENCY CONTROL AND NOT A DETAIL.
--
--     1. the CASE row          — the episode identity, so two operators on one episode serialize
--     2. the CURRENT generation — so the generation number is computed under the row it increments
--
--   The winner supersedes and inserts. The loser blocks on (1); once the winner commits, every
--   subsequent statement in the loser's transaction takes a fresh snapshot, so it sees the NEW
--   current generation — `queued` — and refuses with `notice_still_queued`. Two generation-N+1 rows
--   are therefore unreachable, and the partial unique index
--   `owner_notice_outbox_one_current_per_episode_idx` is the wall behind that door: even with the
--   lock removed, a second row with `superseded_by is null` for the same episode is refused by the
--   database. Two layers, because a lock is a protocol and an index is a guarantee.
--
-- ★ THE PREDECESSOR IS RETIRED BEFORE THE SUCCESSOR EXISTS, AND THAT ORDER IS FORCED. Measured
-- against Postgres in migration 0058: with the self-FK immediate, insert-first raises
-- `unique_violation` (two rows momentarily satisfy `superseded_by is null`) and update-first raises
-- `foreign_key_violation` (the successor does not exist yet). The FK is DEFERRABLE INITIALLY
-- DEFERRED, so this routine pre-generates the successor's uuid, points the predecessor at it, then
-- inserts under that id. Integrity is unchanged — 0058 §5.3(g) proves a genuinely dangling pointer is
-- still refused at commit.
create or replace function public.reissue_owner_safety_notice(p_case uuid, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid        uuid;
  v_c          public.death_verification_cases%rowtype;
  v_prior      public.owner_notice_outbox%rowtype;
  v_verdict    jsonb;
  v_owner      uuid;
  v_recipient  text;
  v_new        uuid;
  v_gen        int;
  v_reason     text;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  -- ★ THE REASON IS REQUIRED AND CANNOT BE BLANK, and it is checked BEFORE anything is locked. "Fixing
  -- it" is not a reason; the audit row exists so somebody reconstructing a disputed release a year
  -- later can tell a legitimate remediation from an operator mailing a living person repeatedly.
  --
  -- ★ "CONTAINS NO NON-WHITESPACE CHARACTER" RATHER THAN `btrim(p_reason) = ''`, AND THE DIFFERENCE
  -- IS NOT PEDANTRY — it was found by execution. Single-argument `btrim` strips SPACES only, so a
  -- reason of one tab, or of a newline, passes that test and lands in the audit as a blank field.
  -- §11.9 sends `E'\t\n'` and the `btrim` form ACCEPTED it. The sibling routines in this schema
  -- (`purge_outbox_rows`, `authorize_release`) carry the narrower spelling; that is recorded as an
  -- observation in `docs/phase11oc-phase-c-owner-notice-reissue.md` rather than changed here, because
  -- widening a deployed reason check is its own decision and `authorize_release` is Phase D's file.
  if p_reason is null or p_reason !~ '[^[:space:]]' then
    raise exception 'reissue_reason_required' using errcode = 'P0001';
  end if;
  if p_case is null then
    raise exception 'case_not_found' using errcode = 'P0002';
  end if;

  -- LOCK 1 · the episode identity.
  select * into v_c from public.death_verification_cases c where c.id = p_case for update;
  if not found then
    raise exception 'case_not_found' using errcode = 'P0002';
  end if;

  -- LOCK 2 · the current generation, so `generation + 1` is computed under the row it increments.
  -- A missing row is legitimate here (the assessment names it `no_current_notice`), so this is not
  -- an assertion — it is a lock taken when there is something to lock.
  select * into v_prior
    from public.owner_notice_outbox o
   where o.case_id = p_case
     and o.channel = 'email'
     and o.notice_kind = any (public.owner_notice_episode_kinds())
     and o.superseded_by is null
   limit 1
   for update;

  -- ★ THE VERDICT COMES FROM THE SHARED ASSESSMENT, READ UNDER THE LOCKS ABOVE. The door does not
  -- restate the policy the console renders, so the two cannot disagree.
  v_verdict := public.owner_notice_reissue_assessment(p_case);
  if not (v_verdict ->> 'eligible')::boolean then
    raise exception '%', v_verdict ->> 'refusal_code' using errcode = 'P0001';
  end if;
  v_reason := v_verdict ->> 'reissue_reason';
  if v_reason is null then
    -- Unreachable: every eligible branch derives one, and the table CHECK pairs generation > 1 with a
    -- non-null reason. Asserted rather than trusted, because the alternative is an insert that fails
    -- on a constraint with no explanation of which branch forgot.
    raise exception 'reissue_reason_underived' using errcode = 'P0001';
  end if;

  -- ★ THE RECIPIENT IS DERIVED, THROUGH THE SAME AUTHORITATIVE PATH AS THE INITIAL DISPATCH:
  -- `estate_owner_user_id` → `auth.users.email`. Not `profiles.email` (user-editable in principle,
  -- and repointable by anyone who can write a profile) and not the predecessor row's stored value.
  --
  -- ★ THE RESIDUAL RISK IS REAL AND IS RECORDED RATHER THAN HIDDEN. Re-resolving means a re-notice
  -- goes to whatever address the account carries NOW. `lib/ownerNotices/drain.ts` deliberately does
  -- NOT re-resolve at SEND time, and that is the right rule there: a worker silently changing
  -- destination between enqueue and send is unaudited and unattended. This is different — an operator
  -- decides, a reason is required, and an audit row is written. Re-sending to the predecessor's stored
  -- address would also be inert for the commonest remediable failure there is, a hard bounce on a dead
  -- address. So the audit records WHETHER the resolved address differs from the predecessor's, as a
  -- BOOLEAN, never the address: an investigator gets the signal, and the audit gains no contact detail
  -- it would then carry forever.
  v_owner := public.estate_owner_user_id(v_c.estate_id);
  if v_owner is null then
    raise exception 'owner_unresolved' using errcode = 'P0001';
  end if;
  select u.email into v_recipient from auth.users u where u.id = v_owner;
  if v_recipient is null or btrim(v_recipient) = '' then
    -- Belt and braces with the assessment's `owner_channel_unreachable`: the assessment answers for
    -- the console, this answers for the write, and neither is allowed to depend on the other having
    -- run. A row with no destination would be claimed, fail, and settle failedPermanent — leaving the
    -- episode with a second dead generation and the first one retired.
    raise exception 'owner_channel_unreachable' using errcode = 'P0001';
  end if;

  v_gen := v_prior.generation + 1;
  v_new := gen_random_uuid();

  -- RETIRE the predecessor. This is the ONLY column of it this routine touches: every forensic field
  -- — requested_at, attempts, failure_class, dispatched_at, notice_accepted_at, case_id, generation,
  -- status, claimed_at — is left exactly as the drain left it.
  update public.owner_notice_outbox
     set superseded_by = v_new
   where id = v_prior.id;

  -- CREATE the successor. Every field that could carry a stale fact forward is written explicitly,
  -- rather than left to a default, so a reader can see that none of them is inherited:
  --   status             'queued'  — a new warning has been queued, nothing more
  --   notice_accepted_at NULL      — only the providerAccepted settle path may ever stamp it
  --   requested_at       now()     — the age gate must run from THIS request, not the predecessor's
  --   attempts           0         — the successor has its own retry budget
  --   claimed_at         NULL      — unclaimed
  --   dispatched_at      NULL      — nothing has been dispatched
  --   failure_class      NULL      — the predecessor's failure is on the predecessor
  --   next_attempt_at    NULL      — claimable by the next drain
  insert into public.owner_notice_outbox
    (id, estate_id, user_id, channel, recipient, notice_kind, status, requested_at, attempts,
     claimed_at, dispatched_at, failure_class, next_attempt_at, notice_accepted_at,
     case_id, generation, superseded_by, reissue_reason, reissued_by)
  values
    (v_new, v_c.estate_id, v_owner, 'email', v_recipient, public.owner_notice_reissue_kind(),
     'queued', now(), 0, null, null, null, null, null,
     p_case, v_gen, null, v_reason, v_uid);

  -- ★ THE AUDIT IS A DISTINCT ACTION, NEVER `owner_notice_dispatched`. That action means "an operator
  -- opened the window and started the challenge clock"; this one means "an operator queued an
  -- additional warning inside a window that was already open". Reusing the first would make the audit
  -- trail assert a lifecycle transition that did not happen, and would hide the reissue from anyone
  -- counting dispatches.
  --
  -- It names both generations and both row ids, so the supersession chain is reconstructible from the
  -- audit alone. It records the operator's reason and the derived vocabulary reason as separate
  -- fields. It records NO recipient address — the same discipline as the dispatch audit it follows.
  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, v_c.estate_id, 'death_process.owner_notice_reissued', 'owner_notice_outbox', v_new,
          jsonb_build_object(
            'severity',           'high',
            'case_id',            p_case,
            'prior_notice_id',    v_prior.id,
            'prior_generation',   v_prior.generation,
            'prior_status',       v_prior.status,
            'prior_failure_class', v_prior.failure_class,
            'prior_notice_kind',  v_prior.notice_kind,
            'new_notice_id',      v_new,
            'new_generation',     v_gen,
            'notice_kind',        public.owner_notice_reissue_kind(),
            'channel',            'email',
            'reissue_reason',     v_reason,
            'reason',             p_reason,
            -- A boolean, never the address. See the recipient note above.
            'recipient_changed',  v_recipient is distinct from v_prior.recipient),
          'admin');

  -- The return value is what an operator may know, and no more. No recipient, on any branch.
  return jsonb_build_object(
    'status',            'queued',
    'case_id',           p_case,
    'notice_id',         v_new,
    'generation',        v_gen,
    'notice_kind',       public.owner_notice_reissue_kind(),
    'notice_accepted_at', null,
    'reissue_reason',    v_reason,
    'prior_notice_id',   v_prior.id,
    'prior_generation',  v_prior.generation,
    'prior_status',      v_prior.status);
end $function$;
-- ★ THE GRANT IS THE DEFINER-DOOR DISCIPLINE, NOT A WIDENING. `authenticated` is the only role
-- PostgREST ever presents for a signed-in operator, so it is the role every admin door in this
-- repository is granted to — `authorize_release`, `dispatch_owner_safety_notice`, `purge_outbox_rows`
-- and both operator projections included. Authority comes from `admin_require_gate()` INSIDE the
-- definer (auth → is_admin → AAL2 → 15-minute freshness), so an owner, an executor, a claimant and
-- any other signed-in client hit the identical refusal a direct PostgREST caller would. `anon` is
-- revoked outright: an unauthenticated caller has no business reaching a safety-queue writer at all.
revoke execute on function public.reissue_owner_safety_notice(uuid, text) from public, anon;
grant  execute on function public.reissue_owner_safety_notice(uuid, text) to authenticated;

comment on function public.reissue_owner_safety_notice(uuid, text) is
  'Queues a NEW owner-safety notice generation for the CURRENT case episode (Phase 11-OC / Phase C). '
  'Eligible only when the current generation is failedPermanent, outcomeUncertain, or dispatched with '
  'NO acceptance fact (the pre-Phase-A legacy class) — and only from owner_notification_dispatched or '
  'challenge_window. Appends a row and retires the previous one with a pointer; mutates no forensic '
  'field of the predecessor. The new row starts queued with NULL acceptance, so a successful call '
  'means NEW WARNING QUEUED and never provider acceptance or delivery. Recipient is DERIVED, never '
  'supplied, and never returned. Requires a non-blank reason and writes '
  'death_process.owner_notice_reissued. Admin-gated inside the definer.';
