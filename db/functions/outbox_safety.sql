-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-F · OUTBOX SAFETY — age gate, stale protection, and a purge that cannot be silent
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHY A SAFETY NOTICE NEEDS DIFFERENT RULES FROM AN INVITATION EMAIL. `invitation_delivery_outbox`
-- is drained daily and its claim predicate has NO age bound: any `queued` row is claimable whenever
-- the worker next runs. For an invitation that is merely late. For the notice that tells a living
-- owner a process is running to release their estate, sending it three weeks after the fact is
-- worse than not sending it — the situation it describes has already resolved, and the message
-- would arrive as a false alarm about a window that closed, or a true alarm nobody can act on.
--
-- ★ SO STALENESS IS A DECISION, MADE ONCE, RECORDED. A notice older than the age gate is never
-- quietly sent and never quietly deleted: it is marked `failedPermanent` with an explicit failure
-- class, which leaves the evidence in place. Whether the estate should then still be releasable is
-- NOT this module's call — dispatch INITIATION already happened (Stage 2), and re-deciding that
-- here would be a second release authority hiding in a mail queue.
--
-- ★ AND NOTHING IS EVER SILENTLY DELETED (Stage 3). `purge_outbox_rows` writes an
-- `outbox_purge_audit` row BEFORE it deletes, in the same transaction, carrying the count and the
-- age range it removed. A purge with no audit row is impossible rather than discouraged.
--
-- Source of truth — re-apply on DB reset. Deploys with the release-authorization bundle.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- owner_notice_age_gate() → interval                                                   [INTERNAL]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ DERIVED FROM THE CHALLENGE WINDOW, NOT CONFIGURED SEPARATELY. A notice is worth sending while
-- the window it announces could still matter; the window is 7 days (D2), so the gate is the window
-- plus one day of slack for a queue that fell behind. Two independently-tunable numbers would drift
-- apart, and the failure mode of that drift is a notice sent after its own window closed.
--
-- Fail-closed: an unconfigured window yields NULL, and a NULL gate makes `claim_owner_notices`
-- refuse to claim anything rather than treat everything as fresh.
create or replace function public.owner_notice_age_gate()
 returns interval
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select public.challenge_window_duration() + interval '1 day';
$function$;
revoke execute on function public.owner_notice_age_gate() from public, anon, authenticated;

comment on function public.owner_notice_age_gate() is
  'How old an owner safety notice may be and still be worth sending (Phase 11-F): the challenge '
  'window plus one day of queue slack, DERIVED so the two cannot drift apart. NULL when the window '
  'is unconfigured, which makes the claim routine refuse rather than treat everything as fresh.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- claim_owner_notices(p_max) → setof                                                   [INTERNAL]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- The claim side of the owner-notice channel, with the age gate applied BEFORE anything is handed
-- to a sender. Two populations leave the queue on every call:
--
--   · STALE  — older than the gate. Marked `failedPermanent`, class `stale_beyond_age_gate`. Never
--              sent, never deleted. The row is the evidence that the owner was not reached in time,
--              which an operator investigating a disputed release will want.
--   · FRESH  — claimed for delivery with `for update skip locked`, so two concurrent drains never
--              hand the same notice out twice.
--
-- ★ PHASE 11-K WIRED THE CRON. 11-F's note read: "NO CRON IS WIRED TO THIS IN 11-F, DELIBERATELY.
-- Enabling a new delivery path is a deployment decision with its own operator step, and the phase
-- brief's own instruction is to build the safety BEFORE enabling the path. The routine exists, is
-- tested, and waits." The safety was built; 11-K enables the path. The drain is
-- `lib/ownerNotices/drain.ts`, reached by `GET /api/claims/drain_outboxes` under CRON_SECRET, and it
-- claims through this routine as `service_role` — the grant is at the foot of this section.
--
-- ★ THE ROUTE NAME IS NOT `drain_owner_notices`, AND THIS COMMENT USED TO SAY IT WAS. There is no
-- such endpoint: it returns 404 in production, verified by probing it. `drain_owner_notices` is only
-- the LOG LABEL for the owner-notice half inside the shared dispatcher. The half shares the claims
-- cron slot because Vercel Hobby permits exactly two cron jobs, so it could never have its own path.
-- A comment naming a 404 is not cosmetic in THIS module: §5/§7 of the deployment doc verify the
-- channel by probing it, and an engineer who probes the name written here gets a 404 and concludes
-- the drain was never deployed — a false negative about the only independent channel that warns a
-- living owner their estate is being released.
create or replace function public.claim_owner_notices(p_max int default 25)
 returns table (id uuid, estate_id uuid, recipient text, notice_kind text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_gate interval;
  v_max  int;
begin
  v_gate := public.owner_notice_age_gate();
  if v_gate is null then
    -- Fail-closed: with no configured window there is no defensible notion of "too old", so the
    -- queue is not drained at all rather than drained by a guess.
    raise exception 'owner_notice_age_gate_unconfigured' using errcode = 'P0001';
  end if;
  v_max := least(greatest(coalesce(p_max, 25), 1), 100);

  -- STALE FIRST, so a stale row can never be claimed for sending by the same call.
  update public.owner_notice_outbox o
     set status = 'failedPermanent',
         failure_class = 'stale_beyond_age_gate',
         next_attempt_at = null
   where o.status in ('queued', 'processing')
     and o.requested_at < now() - v_gate;

  return query
  with candidate as (
    select o.id
      from public.owner_notice_outbox o
     where o.status = 'queued'
       and o.requested_at >= now() - v_gate
       and (o.next_attempt_at is null or o.next_attempt_at <= now())
     order by o.requested_at
     limit v_max
     for update skip locked
  )
  update public.owner_notice_outbox o
     set status = 'processing', attempts = o.attempts + 1
    from candidate c
   where o.id = c.id
  returning o.id, o.estate_id, o.recipient, o.notice_kind;
end $function$;
-- ★ THE WORKER GRANT (11-K), AND WHY IT IS NOT `authenticated`. Claiming is a WORKER act, not an
-- operator act: it moves a live safety message into `processing` and hands it to a sender. An
-- operator who could claim could also strand a notice in `processing`, where the stale sweep will
-- eventually mark it failedPermanent — an owner silently un-notified by a console click. The 0043
-- precedent exactly: the claim/record pair is service_role only, revoked from every client role.
revoke execute on function public.claim_owner_notices(int) from public, anon, authenticated;
grant  execute on function public.claim_owner_notices(int) to service_role;

comment on function public.claim_owner_notices(int) is
  'Claims owner safety notices for delivery, applying the age gate FIRST (Phase 11-F, Stage 3): '
  'rows older than the gate are marked failedPermanent/stale_beyond_age_gate and are never sent and '
  'never deleted. Fresh rows are claimed with skip-locked so concurrent drains cannot double-send. '
  'Refuses entirely when the age gate is unconfigured. service_role ONLY (Phase 11-K wired the '
  'drain); no client role may claim.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- record_owner_notice_outcome(p_id, p_outcome, p_failure_class) → text            [service_role]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE HALF 11-F LEFT OUT, AND THE REASON A DRAIN COULD NOT BE WRITTEN UNTIL NOW.
-- `claim_owner_notices` moves a row to `processing` and returns it. Nothing wrote back what the
-- sender then learned — so any worker built on the 11-F schema would have claimed rows and stranded
-- every one of them in `processing`, where the stale sweep would later mark them failedPermanent.
-- The queue would have looked drained and no owner would have been reached.
--
-- Modelled on `record_invitation_delivery_outcome` (0043) with three deliberate differences, each
-- forced by what THIS channel is for:
--
--   · NO GENERATION GUARD, because there is no generation column and no reissue concept. A safety
--     notice is dispatched once, by one transition, and is never re-minted. What replaces the guard
--     is the settled-status check below: a row that has already settled is a no-op.
--
--   · NO PROVIDER MESSAGE ID IS STORED. The table has no column for one and gains none. A provider
--     handle is a lookup key into a third party's log of a message addressed to a living owner; the
--     operational fact this product needs is the outcome, and that is what is recorded.
--
--   · A LOWER CAP AND A SHORTER BACKOFF. Invitations retry 5 times with up to 12h between attempts,
--     which is right for a message that is merely late. This notice is only worth sending inside
--     the age gate (window + 1 day), so a 12h backoff would spend the whole gate on two attempts.
--     Three attempts at ~1h/2h/3h all land comfortably inside it.
--
-- ★ ACCEPTED AND UNCERTAIN ARE BOTH TERMINAL, for the same reason: the message may already be in
-- the owner's inbox, and this product will not send a second copy of a notice about their own death
-- on the strength of a lost HTTP response. Only `retryPending` — where the provider ANSWERED and
-- refused, proving nothing was accepted — returns a row to `queued`.
create or replace function public.record_owner_notice_outcome(
  p_id            uuid,
  p_outcome       text,
  p_failure_class text default null
)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_row    public.owner_notice_outbox%rowtype;
  v_status text;
  v_next   timestamptz;
  v_class  text;
  c_max_attempts constant int := 3;
begin
  if p_outcome not in ('providerAccepted', 'outcomeUncertain', 'retryPending', 'failedPermanent') then
    raise exception 'invalid_outcome' using errcode = 'P0001';
  end if;

  select * into v_row from public.owner_notice_outbox where id = p_id for update;
  if not found then
    raise exception 'outbox_entry_not_found' using errcode = 'P0002';
  end if;

  -- Already settled: report current state, change nothing, write no second audit row. Covers a
  -- duplicate callback and an operator-cancelled row alike.
  if v_row.status in ('dispatched', 'outcomeUncertain', 'failedPermanent', 'cancelled') then
    return v_row.status;
  end if;

  v_class := case when p_outcome in ('retryPending', 'failedPermanent') then p_failure_class else null end;
  v_next  := null;

  if p_outcome = 'providerAccepted' then
    v_status := 'dispatched';
  elsif p_outcome = 'outcomeUncertain' then
    v_status := 'outcomeUncertain';
  elsif p_outcome = 'failedPermanent' then
    v_status := 'failedPermanent';
  else
    if v_row.attempts >= c_max_attempts then
      v_status := 'failedPermanent';
      v_class  := coalesce(v_class, 'retry_cap_exhausted');
    else
      v_status := 'queued';
      v_next   := now() + make_interval(hours => least(greatest(v_row.attempts, 1), 3));
    end if;
  end if;

  update public.owner_notice_outbox
     set status          = v_status,
         failure_class   = v_class,
         next_attempt_at = v_next,
         dispatched_at   = case when v_status = 'dispatched' then now() else dispatched_at end
   where id = p_id;

  -- ★ THE AUDIT NAMES THE OUTCOME AND THE CHANNEL CLASS, NEVER THE ADDRESS — the same discipline as
  -- the dispatch audit it follows. An audit row outlives every reason anyone had to read it.
  -- actor_id is NULL because the actor is a scheduled worker, not a person; `source = 'worker'`
  -- says so without inventing a synthetic operator identity.
  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (null, v_row.estate_id, 'death_process.owner_notice_outcome', 'owner_notice_outbox', p_id,
          jsonb_build_object('severity', 'high', 'outcome', v_status,
                            'failure_class', v_class, 'attempts', v_row.attempts,
                            'channel', v_row.channel, 'notice_kind', v_row.notice_kind),
          'worker');
  return v_status;
end $function$;
revoke execute on function public.record_owner_notice_outcome(uuid, text, text)
  from public, anon, authenticated;
grant  execute on function public.record_owner_notice_outcome(uuid, text, text) to service_role;

comment on function public.record_owner_notice_outcome(uuid, text, text) is
  'Write-back half of the owner-safety notice drain (Phase 11-K). providerAccepted -> dispatched; '
  'retryPending -> queued with backoff until a 3-attempt cap, then failedPermanent; '
  'outcomeUncertain and failedPermanent are terminal. An already-settled row is a no-op, so a '
  'duplicate callback can never produce a second send. Records no recipient address. service_role only.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- purge_outbox_rows(p_outbox, p_before, p_reason) → int                       [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE AUDIT ROW IS WRITTEN BEFORE THE DELETE, IN THE SAME TRANSACTION. Not after — an audit
-- written afterwards is an audit that a failure can skip, leaving rows gone and no record of who
-- removed them or why. Here the audit and the deletion commit together or neither happens.
--
-- ★ A REASON IS REQUIRED AND CANNOT BE BLANK. "Cleaning up" is not a reason; the column exists so
-- that someone reconstructing a disputed release a year later can tell a routine hygiene sweep from
-- a deletion that removed the evidence of an owner who was never reached.
--
-- ★ IT REFUSES TO TOUCH ROWS THAT ARE STILL ACTIONABLE. `queued` and `processing` notices are live
-- safety messages; purging those would be deleting an owner's warning while it is still in flight.
-- Only settled rows (dispatched / failedPermanent / cancelled) can be purged, and only ones older
-- than an explicit cutoff the caller states.
create or replace function public.purge_outbox_rows(
  p_outbox text,
  p_before timestamptz,
  p_reason text
)
 returns int
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid    uuid;
  v_count  int;
  v_oldest timestamptz;
  v_newest timestamptz;
  v_audit  uuid;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'purge_reason_required' using errcode = 'P0001';
  end if;
  if p_before is null then
    raise exception 'purge_cutoff_required' using errcode = 'P0001';
  end if;
  -- A closed vocabulary of purgeable outboxes. An unknown name is refused rather than resolved
  -- dynamically: `execute format('delete from %I')` on a caller-supplied table is how an admin
  -- routine becomes a general-purpose delete.
  if p_outbox is distinct from 'owner_notice_outbox' then
    raise exception 'unknown_outbox' using errcode = 'P0001';
  end if;

  select count(*), min(requested_at), max(requested_at)
    into v_count, v_oldest, v_newest
    from public.owner_notice_outbox
   where status in ('dispatched', 'failedPermanent', 'cancelled')
     and requested_at < p_before;

  if v_count = 0 then
    return 0; -- nothing to purge writes no audit row: an audit of a no-op is noise, not evidence
  end if;

  insert into public.outbox_purge_audit
    (outbox_name, actor_id, row_count, oldest_row_at, newest_row_at, reason)
  values (p_outbox, v_uid, v_count, v_oldest, v_newest, p_reason)
  returning id into v_audit;

  -- Stamp the audit id onto the rows first, so even a partial failure leaves the link.
  update public.owner_notice_outbox
     set purge_audit_id = v_audit
   where status in ('dispatched', 'failedPermanent', 'cancelled')
     and requested_at < p_before;

  delete from public.owner_notice_outbox
   where status in ('dispatched', 'failedPermanent', 'cancelled')
     and requested_at < p_before;

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, null, 'outbox.purged', 'outbox_purge_audit', v_audit,
          jsonb_build_object('severity', 'high', 'outbox', p_outbox, 'row_count', v_count,
                            'oldest_row_at', v_oldest, 'newest_row_at', v_newest,
                            'reason', p_reason),
          'admin');
  return v_count;
end $function$;
revoke execute on function public.purge_outbox_rows(text, timestamptz, text) from public, anon;
grant  execute on function public.purge_outbox_rows(text, timestamptz, text) to authenticated;

comment on function public.purge_outbox_rows(text, timestamptz, text) is
  'Purges SETTLED owner-notice rows older than an explicit cutoff (Phase 11-F, Stage 3). Writes the '
  'outbox_purge_audit row BEFORE deleting, in the same transaction, so a silent purge is impossible. '
  'Requires a non-blank reason, refuses an unknown outbox name, and never touches queued or '
  'processing rows — those are live safety messages still in flight.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- owner_notice_census() → jsonb                                                [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- The read-only classification Stage 3 requires before any delivery path is enabled: totals, status
-- distribution, age distribution, and the actionable/stale split — computed against the CURRENT age
-- gate rather than against a remembered one. Counts only; no recipient address, no estate name.
create or replace function public.owner_notice_census()
 returns jsonb
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare v_gate interval; v_out jsonb;
begin
  perform public.admin_require_gate();
  v_gate := public.owner_notice_age_gate();

  -- ★ TWO SEPARATE AGGREGATIONS, COMBINED — NOT A LATERAL JOIN. The first draft joined a
  -- per-status GROUP BY laterally onto the row set, which returns every status group for EVERY row:
  -- three rows across three statuses became nine, and `total` reported 9. The status map looked
  -- right (duplicate keys resolve last-wins), so a test asserting only the presence of keys passed
  -- while the headline number was triple the truth. A census whose total is wrong is worse than no
  -- census — it is the number an operator would quote when deciding whether to purge.
  with rows as (
    select o.status, o.requested_at from public.owner_notice_outbox o
  ),
  by_status as (
    select coalesce(jsonb_object_agg(t.status, t.n), '{}'::jsonb) as m
      from (select r.status, count(*) as n from rows r group by r.status) t
  )
  select jsonb_build_object(
    'total', (select count(*) from rows),
    'by_status', (select m from by_status),
    'age_gate', v_gate::text,
    'oldest_requested_at', (select min(r.requested_at) from rows r),
    'newest_requested_at', (select max(r.requested_at) from rows r),
    'actionable', (select count(*) from rows r
                    where r.status = 'queued'
                      and v_gate is not null and r.requested_at >= now() - v_gate),
    'stale', (select count(*) from rows r
               where r.status in ('queued', 'processing')
                 and v_gate is not null and r.requested_at < now() - v_gate),
    -- ★ 11-K: without this key an `outcomeUncertain` row would appear in `total` and `by_status`
    -- and in NONE of the three splits, so an operator reconciling actionable+stale+purgeable
    -- against the total would find a gap with no name — and a nameless gap in a safety queue is
    -- the number someone eventually explains away. It is counted separately rather than folded
    -- into `purgeable` because it is deliberately NOT purgeable.
    'uncertain', (select count(*) from rows r where r.status = 'outcomeUncertain'),
    'purgeable', (select count(*) from rows r
                   where r.status in ('dispatched', 'failedPermanent', 'cancelled'))
  ) into v_out;

  return v_out;
end $function$;
revoke execute on function public.owner_notice_census() from public, anon;
grant  execute on function public.owner_notice_census() to authenticated;

comment on function public.owner_notice_census() is
  'Read-only owner-notice outbox classification (Phase 11-F, Stage 3): totals, status and age '
  'distribution, and the actionable/stale/purgeable split against the CURRENT age gate. Counts '
  'only — never a recipient address. Admin-gated.';
