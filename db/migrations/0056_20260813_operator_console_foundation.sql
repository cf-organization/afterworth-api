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
  -- Phase D supersession bookkeeping — see the banner beside the release/window guards below.
  v_ob2    boolean;
  v_old    boolean;
  v_new    boolean;
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

  -- ════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ SUPERSEDED BY MIGRATION 0060 (PHASE 11-OC / PHASE D) — AMENDED 2026-08-17, ASSERTION LAYER
  --   ONLY. NO DEPLOYED SCHEMA BEHAVIOUR OF THIS MIGRATION CHANGED.
  -- ════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- ORIGINAL INVARIANT (OB-1 era, correct when written): a new `outcomeUncertain` status must not
  -- have widened the two predicates that decide whether a window may open and whether an estate may
  -- release. Both read `status <> 'cancelled'`, and this asserted that exact text on both bodies.
  --
  -- SUPERSEDING INVARIANT (OB-2, migration 0060): the release door no longer consults ANY status
  -- string. It consults `owner_notice_release_authority`, which requires the CURRENT generation of
  -- the CURRENT case episode to carry `notice_accepted_at`. `begin_challenge_window` likewise now
  -- requires a committed email notice for the CURRENT EPISODE rather than a non-cancelled row on the
  -- estate. Both original literals are therefore GONE by design, and exact-text pinning of them
  -- would fail every replay from 0060 onward.
  --
  -- WHY THE PIN COULD NOT SIMPLY BE DELETED, AND WHY IT IS NOT A DECORATION. Three "fixes" were
  -- refused: planting the literal in a comment (prosrc INCLUDES comments, so it would satisfy the
  -- old check while inspecting nothing — the vacuous-audit failure this repository has shipped five
  -- times); deleting the guard outright (a future edit could then remove BOTH predicates with
  -- nothing objecting); and teaching the replay harness to skip it (the self-checks live inside the
  -- migration text embedded in the bundles, so neutralizing them would mean rewriting the bytes an
  -- operator pastes).
  --
  -- THE AMENDMENT IS A SUPERSESSION-AWARE DISJUNCTION, AND IT IS STRICTLY STRONGER THAN THE
  -- ORIGINAL. Each body must carry the OB-1 predicate **or** the OB-2 authority — and NEVER
  -- NEITHER, and never BOTH. The original could be satisfied only by the old text; this cannot be
  -- satisfied by the absence of both, so a future edit that deletes the guard with nothing replacing
  -- it still raises here. The OB-2 branch is anchored on `to_regprocedure` — a CATALOG fact about a
  -- function that must genuinely exist — precisely so a comment cannot supply it.
  --
  -- ★ AND A TEXT SEARCH IS NOT THE ONLY VOTER. Migration 0060 §4 proves the authority BEHAVIOURALLY
  -- by executing it against constructed fixtures, and `db/tests/release_safety_authorization.sql`
  -- §12 proves the door. This guard's job is to make a HALF-cutover impossible; runtime semantics
  -- are proven where runtime semantics can be observed.
  --
  -- ★ COMMENTS ARE STRIPPED BEFORE EVERY MATCH, AND THAT IS WHAT MAKES "PLANT THE LITERAL IN A
  -- COMMENT" UNAVAILABLE RATHER THAN MERELY FORBIDDEN. Postgres stores a plpgsql body verbatim, so
  -- prose containing `status <> 'cancelled'` used to satisfy this check while inspecting nothing —
  -- and, in the other direction, the Phase D banner that QUOTES the superseded predicate in order to
  -- say it is gone would have read as the predicate still being present. Measured on the first Phase
  -- D replay, in both directions. String literals are deliberately NOT stripped: the predicate being
  -- looked for IS a quoted literal, so removing them would erase the evidence class itself.
  v_ob2 := to_regprocedure('public.owner_notice_release_authority(uuid)') is not null;

  if to_regprocedure('public.begin_challenge_window(uuid)') is not null then
    select prosrc into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'begin_challenge_window';
    v_def := regexp_replace(v_def, E'--[^\n]*', '', 'g');
    -- Non-vacuity: a stripper that ate the body would satisfy every negative test below.
    if v_def not like '%raise exception%' then
      raise exception '0056 FAILED: the stripped begin_challenge_window body contains no code — the '
        'preprocessing has eaten the routine and this guard is inspecting an empty string';
    end if;
    v_old := v_def like '%status <> ''cancelled''%';
    -- The OB-2 posture for THIS door is episode scope, not the acceptance fact — Phase D
    -- deliberately does not require provider acceptance to open a window (D7).
    v_new := v_ob2 and v_def like '%owner_notice_episode_kinds%' and v_def like '%o.case_id = v_case%';
    if not (v_old or v_new) then
      raise exception '0056 FAILED: begin_challenge_window gates on NEITHER the OB-1 predicate '
        '(status <> cancelled) NOR the OB-2 episode scope (a current-generation email notice for '
        'the resolved case). The window-opening precondition has been removed rather than '
        'superseded, and a window can now open with no committed notice at all.';
    end if;
    if v_old and v_new then
      raise exception '0056 FAILED: begin_challenge_window carries BOTH the OB-1 predicate and the '
        'OB-2 episode scope — a half-applied Phase D cutover, which is neither posture and cannot '
        'be reasoned about.';
    end if;
  end if;

  if to_regprocedure('public.authorize_release(uuid, text)') is not null then
    select prosrc into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'authorize_release';
    v_def := regexp_replace(v_def, E'--[^\n]*', '', 'g');
    if v_def not like '%raise exception%' then
      raise exception '0056 FAILED: the stripped authorize_release body contains no code';
    end if;
    v_old := v_def like '%status <> ''cancelled''%';
    v_new := v_ob2 and v_def like '%public.owner_notice_release_authority(%';
    if not (v_old or v_new) then
      raise exception '0056 FAILED: authorize_release gates on NEITHER the OB-1 predicate '
        '(status <> cancelled) NOR the OB-2 acceptance authority '
        '(owner_notice_release_authority). The owner-notice precondition has been removed rather '
        'than superseded, and an estate can now release with no provable owner notice of any kind.';
    end if;
    if v_old and v_new then
      raise exception '0056 FAILED: authorize_release carries BOTH the OB-1 predicate and the OB-2 '
        'acceptance authority — a half-applied Phase D cutover.';
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
    'purged); window and release predicates carry exactly one posture each (OB-1 status <> '
    'cancelled, or OB-2 acceptance authority — never neither, never both); no client table grant';
end $$;
