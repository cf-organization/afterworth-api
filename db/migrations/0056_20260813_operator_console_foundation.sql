-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 0056 · PHASE 11-K — a sixth outbox status, so "we do not know" has somewhere honest to land
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT PHASE 11 IS MISSING, RE-DERIVED FROM SOURCE RATHER THAN INHERITED. Every Phase 11 write
-- door exists, is deployed, and is admin-gated. Two things do not exist, and between them they make
-- the whole lifecycle unreachable by any operator:
--
--   1 · NOTHING CAN RECORD A DELIVERY OUTCOME. `claim_owner_notices` moves a row to `processing`
--       and hands it to a sender — and there is no routine to write back what the sender learned.
--       A drain built on the deployed schema would strand every row it claimed. There is also no
--       `service_role` grant on the claim routine, so no worker could call it at all.
--
--   2 · NOTHING CAN READ A CASE. `death_verification_cases`, `death_verification_evidence` and
--       `estate_lifecycle` were created with ZERO grants and ZERO policies (0052 asserts it), and
--       no `admin_list_*` / `admin_get_*` routine was ever written for them. An operator holding a
--       valid AAL2 admin JWT can DECIDE a case they have no way to see. The nine admin write doors
--       are not merely unbound — they are unusable, because the console cannot name a case id.
--
-- ★ THIS MIGRATION OWNS ONLY THE SCHEMA HALF, and deliberately so. The 0055 precedent is the
-- standing rule here: *a migration must be checkable against the schema it changed, not against a
-- function some other artifact happens to carry.* The routines that close (1) and (2) are single-
-- sourced in `db/functions/outbox_safety.sql` and `db/functions/operator_console.sql`, with their
-- own grants beside them, and the bundle asserts the assembled result. So this file changes ONE
-- constraint and proves ONE thing.
--
-- ★ IT CREATES NO NEW AUTHORITY. No gate is touched, no lifecycle moves, no level changes, no
-- notice dispatches, no window opens, nothing releases. The console this unblocks calls the SAME
-- nine deployed doors, which keep enforcing themselves.
--
-- IDEMPOTENT. Safe to re-apply. APPLY ORDER: after 0055.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · A SIXTH OUTBOX STATUS — because "we do not know" is a real answer and must not be renamed
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE PROVIDER MODULE ALREADY DISTINGUISHES FOUR OUTCOMES, and one of them has nowhere to land.
-- `resendProvider.send()` returns `outcomeUncertain` when the request left the process and no
-- answer came back — not a success, not a failure. The deployed CHECK admits five statuses and
-- none of them says that:
--
--   · `dispatched`      would claim delivery was accepted. It may not have been.
--   · `failedPermanent` would claim nothing was sent. Something may have been.
--   · `queued`          would invite a later drain to send a SECOND copy of the message telling
--                       someone a process is running to release their estate.
--   · `processing`      would strand the row, which is the same thing one drain later.
--
-- So the sixth value exists to keep the status column honest. It is TERMINAL: never claimed again
-- (the claim predicate reads `queued` only), never swept as stale (the stale sweep reads
-- `queued`/`processing` only), and never re-sent.
--
-- ★ IT IS DELIBERATELY NOT PURGEABLE. `purge_outbox_rows` settles `dispatched`, `failedPermanent`
-- and `cancelled`; an uncertain row is exactly the row an operator reconstructing a disputed
-- release needs most, so it is retained rather than made deletable. That is a retention decision,
-- not an oversight — it is written down here so the next reader does not "complete" the list.
--
-- ★ AND IT STILL SATISFIES THE DOWNSTREAM GATES, CORRECTLY. `begin_challenge_window` and
-- `authorize_release` both require an email row with `status <> 'cancelled'`, because the deployed
-- contract is DISPATCH INITIATION, never delivery confirmation. An uncertain row WAS dispatched;
-- the window may open on it. Nothing about this value weakens or widens either gate — and the
-- self-check below proves both predicates still read the way they did before this migration.
do $$
declare v_name text;
begin
  for v_name in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public' and rel.relname = 'owner_notice_outbox'
       and con.contype = 'c' and pg_get_constraintdef(con.oid) ilike '%status%'
  loop
    execute format('alter table public.owner_notice_outbox drop constraint %I', v_name);
  end loop;

  alter table public.owner_notice_outbox
    add constraint owner_notice_outbox_status_check
    check (status in (
      'queued',
      'processing',
      'dispatched',
      -- Phase 11-K: the provider never answered. Terminal, never re-sent, never purged.
      'outcomeUncertain',
      'failedPermanent',
      'cancelled'
    ));
end $$;

comment on column public.owner_notice_outbox.status is
  'queued -> processing -> {dispatched | outcomeUncertain | failedPermanent}, or cancelled. '
  'outcomeUncertain (Phase 11-K) means the provider never answered: the message may or may not '
  'have been accepted, so the row is TERMINAL — never re-claimed, never re-sent, never purged.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 2 · SELF-CHECK — schema facts only, proven by execution rather than asserted
-- ────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare
  v_estate uuid;
  v_owner  uuid;
  v_id     uuid;
  v_def    text;
begin
  -- ★ A POSITIVE CONTROL BEFORE THE ABSENCE CHECK. Find a real estate with a resolvable owner; if
  -- none exists the constraint cannot be exercised, and this migration says so rather than passing
  -- vacuously on a database where the INSERT would have failed for an unrelated reason.
  select e.id, public.estate_owner_user_id(e.id) into v_estate, v_owner
    from public.estates e
   where public.estate_owner_user_id(e.id) is not null
   limit 1;

  if v_estate is null then
    raise notice '0056 · no estate with a resolvable owner exists; the CHECK was altered but could '
      'not be exercised by insertion. Constraint definition is asserted textually below.';
  else
    -- The sixth status is admitted…
    begin
      insert into public.owner_notice_outbox
        (estate_id, user_id, channel, recipient, notice_kind, status)
      values (v_estate, v_owner, 'email', '0056-self-check@invalid',
              'death_process.window_opened', 'outcomeUncertain')
      returning id into v_id;
    exception when check_violation then
      raise exception '0056 FAILED: outcomeUncertain is not an admitted owner_notice_outbox status';
    end;

    -- …and a nonsense status is still refused. Without this the CHECK could have been dropped
    -- rather than replaced, and the insert above would pass for the wrong reason.
    begin
      update public.owner_notice_outbox set status = 'definitelyNotAStatus' where id = v_id;
      raise exception '0056 FAILED: the owner_notice_outbox status CHECK admits arbitrary values — '
        'it was dropped, not replaced';
    exception when check_violation then
      null; -- refused, which is the point
    end;

    -- ★ THE SELF-CHECK MUST NOT LEAVE A ROW IN A SAFETY QUEUE.
    delete from public.owner_notice_outbox where id = v_id;
    if exists (select 1 from public.owner_notice_outbox where recipient = '0056-self-check@invalid') then
      raise exception '0056 FAILED: the self-check left a row in the owner notice outbox';
    end if;
  end if;

  -- The constraint text carries all six values and no more.
  select pg_get_constraintdef(con.oid) into v_def
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'owner_notice_outbox'
     and con.conname = 'owner_notice_outbox_status_check';
  if v_def is null then
    raise exception '0056 FAILED: owner_notice_outbox_status_check does not exist';
  end if;
  if v_def not like '%outcomeUncertain%' then
    raise exception '0056 FAILED: the status CHECK does not carry outcomeUncertain';
  end if;

  -- ★ THE DOWNSTREAM GATES ARE UNCHANGED. A new status value must not have widened the two
  -- predicates that decide whether a window may open and whether an estate may release. Both read
  -- `status <> 'cancelled'`; if a later edit ever narrows them to `= 'dispatched'`, dispatch
  -- INITIATION would silently have become delivery CONFIRMATION, and this fails.
  if to_regprocedure('public.begin_challenge_window(uuid)') is not null then
    select prosrc into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'begin_challenge_window';
    if v_def not like '%status <> ''cancelled''%' then
      raise exception '0056 FAILED: begin_challenge_window no longer gates on status <> cancelled — '
        'the dispatch-initiation contract changed underneath this migration';
    end if;
  end if;
  if to_regprocedure('public.authorize_release(uuid, text)') is not null then
    select prosrc into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'authorize_release';
    if v_def not like '%status <> ''cancelled''%' then
      raise exception '0056 FAILED: authorize_release no longer gates on status <> cancelled';
    end if;
  end if;

  -- Nothing here became a table grant.
  if exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public'
       and table_name in ('death_verification_cases', 'death_verification_evidence',
                          'estate_lifecycle', 'owner_notice_outbox')
       and grantee in ('anon', 'authenticated')
  ) then
    raise exception '0056 FAILED: a client role holds a table grant on a lifecycle table';
  end if;

  raise notice '0056 · owner_notice_outbox admits outcomeUncertain (terminal, never re-sent, never '
    'purged); window and release predicates unchanged; no client table grant';
end $$;
