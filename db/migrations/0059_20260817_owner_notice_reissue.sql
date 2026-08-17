-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-OC · PHASE C — A SECOND WARNING IS A NEW ROW, AND IT SAYS SO
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THIS MIGRATION CHANGES NO RELEASE BEHAVIOUR EITHER, AND ASSERTS THAT INVERSION ABOUT ITSELF.
-- Phase C makes RECOVERY possible; Phase D re-anchors the door. §4 below reads the deployed
-- `authorize_release` and requires the pre-Phase-D predicate to still be there, exactly as 0056,
-- 0057 and 0058 do. If Phase C ever makes one of those guards fail, the cutover has been smuggled in
-- and the paste must stop.
--
-- ★ WHY PHASE C EXISTS AT ALL, WHEN TODAY'S PRODUCTION CENSUS IS ZERO. Phase D creates NEW legitimate
-- refusal states that a running system reaches on its own: a notice that settles `failedPermanent` or
-- `outcomeUncertain` has no provable acceptance, and the drain will never re-send a terminal row —
-- by design, because a settled row may already be in the owner's inbox. Without a remedy the first
-- post-cutover provider failure produces a permanently unreleasable estate whose only recovery is
-- hand-written SQL against a safety table. Today's zero is a statement about today's data, never
-- about the system's ability to recover.
--
-- ★ WHAT THIS MIGRATION ADDS, AND WHY EACH PIECE IS STRUCTURAL RATHER THAN CONVENTIONAL.
--
--   1 · A SECOND `notice_kind`. A re-notice is not the initial window-opening event and must not be
--       recorded as one. `death_process.window_opened` is a FACT about a lifecycle transition that
--       happened once; a second row carrying it would make the outbox claim the window opened twice.
--   2 · THE EPISODE INDEX LOSES `notice_kind`. This is the load-bearing consequence of (1) and the
--       reason the two ship together: with two kinds in one episode, a unique index keyed on the kind
--       permits one CURRENT `window_opened` row AND one CURRENT `window_renotice` row for the same
--       case. That is two live generations, which is precisely the state 0058's wall exists to make
--       unwritable. The invariant is per EPISODE — `(case_id, channel)` — and it is strictly stronger
--       than the index it replaces.
--
-- ★ THE REPLACEMENT IS PROVABLY LOSSLESS ON EXISTING DATA, AND §3.1 PROVES IT BEFORE DROPPING
-- ANYTHING. Until this migration `notice_kind` admitted exactly one value, so
-- `(case_id, channel, notice_kind)` and `(case_id, channel)` partition every extant row identically.
-- A pre-flight scan asserts that rather than assuming it: a violation would otherwise surface as an
-- opaque `unique_violation` in the middle of a hand-paste, with the old index already dropped.
--
-- ★ NO BACKFILL, AGAIN. Nothing here writes `notice_accepted_at`, `case_id`, `reissue_reason` or
-- `reissued_by` on any existing row. A re-notice PRODUCES the missing acceptance fact by ordinary
-- operation; it never excuses its absence, and this migration never invents one.
--
-- Deploys via `db/bundles/owner_notice_reissue_bundle.sql`. Source of truth — re-apply on reset.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · THE RE-NOTICE KIND
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE VOCABULARY STAYS CLOSED. The CHECK is REPLACED, never dropped: an outbox whose kind column
-- accepts arbitrary text is an outbox whose rows can claim to be any event, and the release
-- predicate reads that column. §3.2 proves the replacement is a replacement by inserting a nonsense
-- kind and requiring refusal — without that control, "the new kind is admitted" would also pass on a
-- table with no constraint at all.
--
-- ★ AND THE OWNER IS NOT TOLD WHICH ATTEMPT THIS IS. The kind is OPERATOR vocabulary. The email
-- copy is rendered by `lib/ownerNotices/ownerNoticeTemplate.ts` from the link alone — it takes no
-- kind, no generation and no attempt count, so it is structurally incapable of saying "this is the
-- second time we have tried to reach you". Internal state is not user copy, and on this channel the
-- rule is sharper than usual: the recipient may be the target of a false claim, and a message that
-- narrated our delivery troubles would spend their attention on our problem instead of theirs.
do $$
declare v_name text;
begin
  select con.conname into v_name
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'owner_notice_outbox'
     and con.contype = 'c'
     and pg_get_constraintdef(con.oid) ilike '%notice_kind%';
  if v_name is not null then
    execute format('alter table public.owner_notice_outbox drop constraint %I', v_name);
  end if;
end $$;

alter table public.owner_notice_outbox
  add constraint owner_notice_outbox_notice_kind_check
  check (notice_kind in ('death_process.window_opened', 'death_process.window_renotice'));

comment on column public.owner_notice_outbox.notice_kind is
  'Which owner-safety event this row carries (Phase 11-OC). `death_process.window_opened` is the '
  'INITIAL dispatch, written once per episode by dispatch_owner_safety_notice. '
  '`death_process.window_renotice` is a deliberate operator re-issue (Phase C) and is never written '
  'by the drain, the settle path or the stale sweep. Both kinds belong to the SAME episode — see '
  'owner_notice_episode_kinds() — so the release predicate and the readiness census read the set, '
  'never one literal. OPERATOR vocabulary only: the email template takes no kind and cannot tell a '
  'recipient which attempt they are receiving.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 2 · ONE CURRENT GENERATION PER EPISODE — the index follows the episode, not the kind
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE PRE-FLIGHT IS NOT CEREMONY. It runs BEFORE the drop, so a database that somehow already
-- holds two current rows for one (case, channel) fails with a sentence naming the problem while the
-- old index is still in place, rather than failing opaquely with the table unprotected.
do $$
declare v_bad bigint;
begin
  select count(*) into v_bad
    from (
      select o.case_id, o.channel
        from public.owner_notice_outbox o
       where o.superseded_by is null and o.case_id is not null
       group by o.case_id, o.channel
      having count(*) > 1
    ) t;
  if v_bad > 0 then
    raise exception '0059 FAILED: % episode(s) already hold more than one CURRENT owner-notice row. '
      'The per-episode unique index cannot be created and the per-kind index has NOT been dropped. '
      'Resolve the duplicate generations before re-running — this is a data question, not a schema '
      'question, and guessing which row is current is exactly the max() this model refuses.', v_bad;
  end if;
end $$;

-- The predecessor. Dropped only after the pre-flight above proved the replacement is admissible.
drop index if exists public.owner_notice_outbox_one_current_per_case_idx;

create unique index if not exists owner_notice_outbox_one_current_per_episode_idx
  on public.owner_notice_outbox (case_id, channel)
  where superseded_by is null;

comment on index public.owner_notice_outbox_one_current_per_episode_idx is
  'Exactly ONE current generation per episode (Phase 11-OC / Phase C). Replaces the Phase A index on '
  '(case_id, channel, notice_kind), which became insufficient the moment an episode could hold two '
  'kinds: it would have permitted one current window_opened row AND one current window_renotice row '
  'for the same case — two live generations. Strictly stronger than its predecessor and lossless on '
  'every extant row, because notice_kind admitted one value until this migration. Legacy rows carry '
  'a NULL case_id and NULLs are distinct in a unique index, so they neither collide nor are blocked.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 3 · PROVE THE SEAM TOOK, BY EXECUTION (the 0051/0052/0054/0057/0058 discipline)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare
  v_def     text;
  v_estate  uuid;
  v_user    uuid;
  v_case    uuid;
  v_a       uuid;
  v_b       uuid;
  v_ok      boolean;
begin
  -- ── 3.1 the constraint and the index are the ones this migration claims ──────────────────────
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint where conname = 'owner_notice_outbox_notice_kind_check';
  if v_def is null then
    raise exception '0059 FAILED: the notice_kind CHECK is absent — the vocabulary is open and any '
      'row can claim to be any event';
  end if;
  if v_def not like '%window_renotice%' then
    raise exception '0059 FAILED: the notice_kind CHECK does not admit the re-notice kind: %', v_def;
  end if;
  if v_def not like '%window_opened%' then
    raise exception '0059 FAILED: the notice_kind CHECK no longer admits the INITIAL kind — the '
      'replacement narrowed the vocabulary instead of widening it, and dispatch is now unwritable: %',
      v_def;
  end if;

  if not exists (select 1 from pg_indexes where schemaname = 'public'
                  and indexname = 'owner_notice_outbox_one_current_per_episode_idx') then
    raise exception '0059 FAILED: the per-EPISODE one-current-generation unique index is absent';
  end if;
  if exists (select 1 from pg_indexes where schemaname = 'public'
              and indexname = 'owner_notice_outbox_one_current_per_case_idx') then
    raise exception '0059 FAILED: the per-KIND index survived the replacement. Two indexes expressing '
      'overlapping claims about the same invariant is how a mutation of one is masked by the other.';
  end if;
  -- The replacement must still be UNIQUE. A plain index would satisfy the presence check above and
  -- enforce nothing, which is exactly the shape mutation `p11c-one-current-per-episode-not-enforced`
  -- writes.
  if not exists (select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
                  where c.relname = 'owner_notice_outbox_one_current_per_episode_idx'
                    and i.indisunique) then
    raise exception '0059 FAILED: the per-episode index exists but is NOT unique — nothing '
      'structurally identifies the active generation and the release door would need a max()';
  end if;

  -- ── 3.2 THE FOUR DIRECTIONS, BY EXECUTION ────────────────────────────────────────────────────
  --
  -- (a) the re-notice kind is admitted   (b) a nonsense kind is refused
  -- (c) a supersession pair spanning TWO kinds is writable
  -- (d) two CURRENT rows in one episode are refused EVEN WHEN THEIR KINDS DIFFER — the direction
  --     the Phase A index could not see, and the entire reason it was replaced.
  select e.id into v_estate from public.estates e limit 1;
  if v_estate is null then
    raise notice '0059 · no estates in this database — the execution controls in 3.2 are SKIPPED. '
      'This is REPORTED rather than silently passed: on an empty database they would assert nothing. '
      'They run in the SQL suite (release_safety_authorization.sql §11) against furnished fixtures.';
  else
    select m.user_id into v_user from public.estate_memberships m where m.estate_id = v_estate limit 1;
    select c.id into v_case from public.death_verification_cases c
     where c.estate_id = v_estate order by c.created_at desc limit 1;

    if v_user is null or v_case is null then
      raise notice '0059 · no (user, case) pair available for estate % — execution controls SKIPPED '
        'and reported, never assumed.', v_estate;
    else
      -- (a) POSITIVE CONTROL FIRST. Without it, a table whose CHECK refused everything would satisfy
      -- (b) and read as correct.
      begin
        insert into public.owner_notice_outbox
          (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
           reissue_reason)
        values (v_estate, v_user, 'email', '0059-selfcheck-renotice@invalid',
                'death_process.window_renotice', 'queued', v_case, 2, 'prior_failed_permanent')
        returning id into v_a;
        v_ok := v_a is not null;
      exception when others then
        v_ok := false;
      end;
      if not v_ok then
        raise exception '0059 FAILED: the re-notice kind was REFUSED — Phase C cannot write the row '
          'it exists to write, and control (b) below would prove nothing';
      end if;

      -- (b) a kind outside the closed vocabulary is still refused
      begin
        insert into public.owner_notice_outbox
          (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation)
        values (v_estate, v_user, 'email', '0059-selfcheck-vocab@invalid',
                'death_process.definitely_not_a_kind', 'queued', v_case, 1);
        v_ok := false;
      exception when check_violation then
        v_ok := true;
      when others then
        v_ok := false;
      end;
      if not v_ok then
        raise exception '0059 FAILED: notice_kind accepted a value outside the closed vocabulary — '
          'the CHECK was dropped, not replaced';
      end if;

      -- (d) ★ THE REPLACEMENT'S WHOLE PURPOSE. A second CURRENT row for the same episode must be
      -- refused even though its kind DIFFERS from the row already there. Under the Phase A index
      -- this insert SUCCEEDS, and the episode then holds two live generations.
      begin
        insert into public.owner_notice_outbox
          (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation)
        values (v_estate, v_user, 'email', '0059-selfcheck-crosskind@invalid',
                'death_process.window_opened', 'queued', v_case, 1);
        v_ok := false; -- reached = two current generations coexist across kinds
      exception when unique_violation then
        v_ok := true;
      when others then
        v_ok := false;
      end;
      if not v_ok then
        raise exception '0059 FAILED: two CURRENT generations coexist for one episode because their '
          'notice_kinds differ. The one-current-generation wall is keyed on the KIND rather than the '
          'EPISODE, so a re-notice creates a second live notice instead of retiring the first.';
      end if;

      -- (c) a supersession pair that CROSSES kinds is writable — the exact ordering the re-notice
      -- routine uses, exercised here so the deferred FK is proven on the path Phase C takes.
      declare
        v_succ uuid := gen_random_uuid();
      begin
        begin
          update public.owner_notice_outbox set superseded_by = v_succ where id = v_a;
          insert into public.owner_notice_outbox
            (id, estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
             reissue_reason)
          values (v_succ, v_estate, v_user, 'email', '0059-selfcheck-gen3@invalid',
                  'death_process.window_renotice', 'queued', v_case, 3, 'prior_outcome_uncertain');
          v_b := v_succ;
          v_ok := true;
        exception when others then
          v_ok := false;
        end;
        if not v_ok then
          raise exception '0059 FAILED: a supersession pair spanning two notice kinds could not be '
            'written. The re-notice routine retires the predecessor and inserts the successor under a '
            'pre-generated id, which is legal only while owner_notice_outbox_superseded_fk stays '
            'DEFERRABLE INITIALLY DEFERRED (migration 0058).';
        end if;
      end;

      -- Clean up every control row, and prove it. The self-check must not leave a row in a safety
      -- queue — one of these would be claimed by the next drain and mailed to a living owner.
      update public.owner_notice_outbox set superseded_by = null
       where recipient like '0059-selfcheck-%@invalid';
      delete from public.owner_notice_outbox where recipient like '0059-selfcheck-%@invalid';
      if exists (select 1 from public.owner_notice_outbox
                  where recipient like '0059-selfcheck-%@invalid') then
        raise exception '0059 FAILED: the self-check left rows in the owner notice outbox';
      end if;
    end if;
  end if;

  -- ── 3.3 THE INVERSION: PHASE C HAS NOT CHANGED THE RELEASE DOOR ──────────────────────────────
  --
  -- Identical in form to 0058 §5.4, and repeated rather than referenced because a guard that lives
  -- only in an earlier artifact does not run when THIS one is pasted. Phase D (migration 0060) is
  -- the artifact allowed to change this.
  if to_regprocedure('public.authorize_release(uuid, text)') is not null then
    select prosrc into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'authorize_release';
    if v_def not like '%status <> ''cancelled''%' then
      raise exception '0059 FAILED: authorize_release no longer carries the pre-Phase-D predicate. '
        'Phase C makes RECOVERY possible; it must not change when a release may proceed. That is '
        'Phase D (migration 0060), and folding it in here would deploy the cutover as a side effect '
        'of deploying its remedy.';
    end if;
    if v_def like '%notice_accepted_at%' then
      raise exception '0059 FAILED: authorize_release already reads notice_accepted_at — the Phase D '
        'cutover has been pasted as part of Phase C';
    end if;
  end if;

  raise notice '0059 OK: the re-notice kind is admitted and the vocabulary stays closed; the '
    'one-current-generation wall now follows the EPISODE rather than the kind (proved by execution, '
    'across kinds, with a positive control); a cross-kind supersession pair is writable; release '
    'door PROVABLY unchanged.';
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 4 · THE REMEDIATION REPORT — counts only, no ids, no addresses, no estate names
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ HOW MUCH WORK PHASE C HAS TO DO ON THE DAY IT LANDS. A NOTICE rather than an assertion: a
-- non-zero remediable population is not an error, it is the operator's queue. It is printed here so
-- the number is known at paste time rather than discovered from the console.
do $$
declare
  v_failed    bigint;
  v_uncertain bigint;
  v_legacy    bigint;
  v_renotices bigint;
begin
  select
    count(*) filter (where o.status = 'failedPermanent'),
    count(*) filter (where o.status = 'outcomeUncertain'),
    count(*) filter (where o.status = 'dispatched' and o.notice_accepted_at is null),
    count(*) filter (where o.notice_kind = 'death_process.window_renotice')
    into v_failed, v_uncertain, v_legacy, v_renotices
    from public.owner_notice_outbox o
   where o.superseded_by is null
     and o.channel = 'email';

  raise notice '0059 REMEDIATION CENSUS · current generations eligible for re-notice: '
    'failedPermanent=% · outcomeUncertain=% · dispatched-with-no-acceptance-fact=% · '
    're-notices already issued=%', v_failed, v_uncertain, v_legacy, v_renotices;
  raise notice '0059 NOTE · a re-notice QUEUES a new warning. It is not an acceptance, not a '
    'delivery, and not a statement that the owner has been reached — only the providerAccepted '
    'settlement path may ever stamp notice_accepted_at.';
end $$;
