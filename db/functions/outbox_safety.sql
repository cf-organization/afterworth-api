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
-- ★ NO CRON IS WIRED TO THIS IN 11-F, DELIBERATELY. Enabling a new delivery path is a deployment
-- decision with its own operator step (the runbook says so), and the phase brief's own instruction
-- is to build the safety BEFORE enabling the path. The routine exists, is tested, and waits.
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
revoke execute on function public.claim_owner_notices(int) from public, anon, authenticated;

comment on function public.claim_owner_notices(int) is
  'Claims owner safety notices for delivery, applying the age gate FIRST (Phase 11-F, Stage 3): '
  'rows older than the gate are marked failedPermanent/stale_beyond_age_gate and are never sent and '
  'never deleted. Fresh rows are claimed with skip-locked so concurrent drains cannot double-send. '
  'Refuses entirely when the age gate is unconfigured. INTERNAL: no client role, no cron wired yet.';

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
