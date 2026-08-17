-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-OC · PHASE A — ACCEPTANCE IS A FACT, AND A NOTICE BELONGS TO A CASE EPISODE
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THIS MIGRATION CHANGES NO RELEASE BEHAVIOUR, AND ASSERTS THAT INVERSION ABOUT ITSELF.
-- It is the additive half of Phase 11-OC (docs/phase11oc-release-acceptance-authority.md): the
-- columns, the walls, and the observation surface. The release door is re-anchored in Phase D
-- (migration 0060) and not one instant sooner. §5 below proves it by reading `authorize_release`.
--
-- ★ WHY THE STAMP AND THE EPISODE KEY SHIP HERE, AHEAD OF THE POLICY THAT READS THEM.
-- Nothing reads `notice_accepted_at` until Phase D. Landing it now means every notice the provider
-- accepts between Phase A and Phase D accumulates a REAL acceptance fact, so the legacy population
-- measured in Phase B shrinks by ordinary operation rather than by remediation. Deferring the stamp
-- to Phase D would guarantee a larger blocked population on cutover day. The same argument applies
-- to `case_id`: without it, new dispatches keep landing with no episode and the Phase B census would
-- be measuring a population that cannot stop growing.
--
-- ★ THE DEFECT PHASE D FIXES, RESTATED SO THIS FILE IS SELF-EXPLAINING. `authorize_release` gates on
-- an owner-notice row with `status <> 'cancelled'`. Nothing in production ever writes `'cancelled'` —
-- one test fixture does, by direct UPDATE — so the predicate reduces to "a row exists", which is
-- exactly what `dispatch_owner_safety_notice` guaranteed by inserting it in the same transaction.
-- The gate re-asserts its own precondition, and admits `queued` (never sent), `processing` (never
-- settled), `outcomeUncertain` (unknown) and `failedPermanent` (definitively failed).
--
-- ★ NO BACKFILL OF ACCEPTANCE, AND NO BACKFILL OF `case_id`. NULL acceptance is a TRUE statement
-- about every pre-existing row and a guess about none of them. `case_id` is backfillable in
-- principle — the dispatch audit row carries it in metadata JSON — which is exactly why it is
-- refused in writing: populating an FK that will govern release authority by joining an audit blob
-- is the softened-load-bearing-identifier pattern. Legacy rows keep NULL and route to the explicit
-- legacy branch, whose remediation is an operator re-notice that PRODUCES the missing fact.
--
-- Deploys via `db/bundles/owner_notice_acceptance_bundle.sql`. Source of truth — re-apply on reset.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · THE ACCEPTANCE FACT
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- Nullable, and PERMANENTLY so. It is written by exactly one branch of exactly one routine
-- (`record_owner_notice_outcome`, `providerAccepted`), in the same UPDATE that sets `status` and
-- `dispatched_at`. A NOT NULL column would have demanded a backfill default, and every value it
-- invented would be a fabricated provider acceptance on a row whose real acceptance never happened.
alter table public.owner_notice_outbox
  add column if not exists notice_accepted_at timestamptz;

comment on column public.owner_notice_outbox.notice_accepted_at is
  'The instant the email provider ACCEPTED this specific message (Phase 11-OC). Written ONLY by '
  'record_owner_notice_outcome on the providerAccepted branch, in the same UPDATE as status and '
  'dispatched_at. It is NOT delivery: providerAccepted is not delivered, received, opened or viewed, '
  'and nothing downstream may rename it. From Phase D this is the ONE fact that makes a release '
  'qualify, and the anchor of the challenge window. Never backfilled, never synthesized, never '
  'coalesced to dispatched_at or owner_notified_at — authority is decided by SOURCE, and both of '
  'those were written by paths that could not have been telling the truth about acceptance.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 2 · THE EPISODE — case_id, generation, superseded_by
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE EPISODE KEY IS THE CASE, NOT THE ESTATE, AND THAT IS NOT A STYLE CHOICE.
-- `challenge_death_process` and the case-decision paths return the lifecycle to `active` on
-- `rejected` and `cancelled`. A later, unrelated case can then run the whole path again and dispatch
-- a second notice. Estate-scoping the release predicate would let an accepted notice from a PRIOR,
-- REJECTED process authorize a release under a NEW case whose own notice never went out.
alter table public.owner_notice_outbox
  add column if not exists case_id uuid;
alter table public.owner_notice_outbox
  add column if not exists generation int not null default 1;
alter table public.owner_notice_outbox
  add column if not exists superseded_by uuid;
alter table public.owner_notice_outbox
  add column if not exists reissue_reason text;
alter table public.owner_notice_outbox
  add column if not exists reissued_by uuid;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'owner_notice_outbox_case_fk') then
    alter table public.owner_notice_outbox
      add constraint owner_notice_outbox_case_fk
      foreign key (case_id) references public.death_verification_cases(id);
  end if;
  -- ★ ON DELETE SET NULL IS LOAD-BEARING. Without it a purge whose set spans a superseded pair can
  -- fail on intra-statement delete ordering. The FK prevents the crash; `purge_outbox_rows`'
  -- supersession-closure assertion prevents an incoherent leftover. Both, because they answer
  -- different questions.
  --
  -- ★ AND `DEFERRABLE INITIALLY DEFERRED` IS NOT A RELAXATION — IT IS WHAT MAKES A SUPERSESSION PAIR
  -- WRITABLE AT ALL. Measured against Postgres, with this FK immediate, BOTH possible orderings are
  -- refused and the pair is unwritable:
  --
  --   · INSERT the successor first  → `unique_violation`: the predecessor is still current, so two
  --     rows momentarily satisfy `superseded_by is null` for one case and the partial unique index
  --     (correctly) refuses.
  --   · UPDATE the predecessor first → `foreign_key_violation`: it must point at a successor row that
  --     does not exist yet.
  --
  -- A partial unique INDEX cannot be deferred (and PostgreSQL has no partial unique CONSTRAINT), so
  -- the FK is the half that must yield. The re-notice routine therefore pre-generates the successor's
  -- uuid, retires the predecessor, then inserts the successor under that id — legal only because this
  -- check is deferred to commit.
  --
  -- ★ INTEGRITY IS UNCHANGED, AND THAT WAS PROVEN BY A POSITIVE CONTROL RATHER THAN ASSUMED. A
  -- genuinely dangling `superseded_by` is still rejected — at constraint-check time instead of
  -- statement time. Deferral relaxes the intra-transaction ORDERING, never the guarantee; without
  -- that control, "deferrable" could have quietly meant "unenforced". §5.5 re-proves both directions
  -- by execution.
  if not exists (select 1 from pg_constraint where conname = 'owner_notice_outbox_superseded_fk') then
    alter table public.owner_notice_outbox
      add constraint owner_notice_outbox_superseded_fk
      foreign key (superseded_by) references public.owner_notice_outbox(id)
      on delete set null deferrable initially deferred;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'owner_notice_outbox_reissued_by_fk') then
    alter table public.owner_notice_outbox
      add constraint owner_notice_outbox_reissued_by_fk
      foreign key (reissued_by) references auth.users(id);
  end if;
end $$;

comment on column public.owner_notice_outbox.case_id is
  'The death-verification case this notice belongs to (Phase 11-OC) — the EPISODE key. Estate id is '
  'insufficient: one estate may legitimately experience several independent death processes over '
  'time, and an accepted notice from a prior REJECTED case must never authorize a later one. NULL '
  'only on rows written before Phase A; those belong to no episode, satisfy no release predicate, '
  'and are remediated by operator re-notice rather than by a backfill.';

comment on column public.owner_notice_outbox.generation is
  'Which attempt this row is within its episode (Phase 11-OC). 1 for an original dispatch; n+1 for a '
  'deliberate operator re-notice, computed under the predecessor row lock and never from an unlocked '
  'max(). Every pre-Phase-A row is definitionally generation 1 — no re-notice mechanism has ever '
  'existed — which is the ONLY backfill in this phase and is vacuous rather than inferred.';

comment on column public.owner_notice_outbox.superseded_by is
  'The successor generation that retired this row (Phase 11-OC). NULL means this is the CURRENT '
  'generation of its episode. This is a LOOKUP enforced by a partial unique index, deliberately not '
  'a derived max(): a derived-max invariant cannot be expressed as a constraint, so the release door '
  'would depend on an invariant only the writer maintains, and a concurrent double-reissue would '
  'produce two rows that both believe they are latest. A retired row keeps its terminal status and '
  'its failure_class — that evidence is why the reissue was warranted — and gains only this pointer.';

comment on column public.owner_notice_outbox.reissue_reason is
  'Why a generation >= 2 exists (Phase 11-OC), from a closed four-value vocabulary. DERIVED from the '
  'predecessor row inside the definer, never a caller parameter: a caller-supplied reason would let '
  'an operator relabel an outcomeUncertain reissue as a failed one and skip its acknowledgement.';

comment on column public.owner_notice_outbox.reissued_by is
  'The operator who authorized a re-notice (Phase 11-OC). Derived from auth.uid() inside the '
  'definer — the reviewer_a discipline — so the routine has no parameter of this type and '
  'nominating somebody else is unwritable rather than merely forbidden.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 3 · THE WALLS
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ WHY A BEFORE-INSERT TRIGGER AND NOT `CHECK (case_id IS NOT NULL) NOT VALID`.
--
-- `NOT VALID` was the obvious choice and it is WRONG HERE, proven by execution against Postgres
-- rather than reasoned about: a NOT VALID check skips the initial table scan, so legacy NULL rows do
-- persist — but it is still enforced on every subsequent INSERT **and UPDATE**. The owner-notice
-- drain UPDATEs legacy rows as a matter of routine: the stale sweep moves `queued`/`processing` rows
-- to `failedPermanent`, and `record_owner_notice_outcome` settles them. Every one of those UPDATEs
-- would have raised `check_violation` on a legacy row, so a migration whose whole claim is "changes
-- no behaviour" would have broken the only independent channel that warns a living owner.
--
-- Measured: with a NOT VALID check, `update … where case_id is null` is REFUSED. With this trigger it
-- succeeds, while a NULL-case_id INSERT is still refused and a populated INSERT still passes. Four
-- directions, all four asserted in §5.
--
-- The requirement is "no NEW row without an episode", which is a statement about INSERT. So it is
-- enforced on INSERT, by a wall rather than by a routine's promise.
create or replace function public.owner_notice_require_episode()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
begin
  if new.case_id is null then
    raise exception 'owner_notice_case_required' using errcode = 'P0001';
  end if;
  return new;
end $function$;

comment on function public.owner_notice_require_episode() is
  'Phase 11-OC: every NEW owner-notice row must name its death-verification case. Enforced on INSERT '
  'only, deliberately — legacy rows carry a NULL case_id and MUST stay updatable, because the stale '
  'sweep and the settle path both UPDATE them. A NOT VALID CHECK constraint would have refused those '
  'UPDATEs and broken the drain; that was measured, not assumed.';

drop trigger if exists owner_notice_outbox_require_episode on public.owner_notice_outbox;
create trigger owner_notice_outbox_require_episode
  before insert on public.owner_notice_outbox
  for each row execute function public.owner_notice_require_episode();

-- The reason vocabulary is closed, and paired with generation so neither can drift from the other.
-- Added VALID rather than NOT VALID: every legacy row is generation 1 with a NULL reason and already
-- satisfies both, so validating them is a real proof rather than a deferred one.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'owner_notice_outbox_reissue_reason_check') then
    alter table public.owner_notice_outbox
      add constraint owner_notice_outbox_reissue_reason_check
      check (reissue_reason is null or reissue_reason in (
        'prior_failed_permanent',
        'prior_stale_beyond_age_gate',
        'prior_outcome_uncertain',
        'legacy_no_acceptance_record'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'owner_notice_outbox_reissue_pairing') then
    alter table public.owner_notice_outbox
      add constraint owner_notice_outbox_reissue_pairing
      check ((generation = 1 and reissue_reason is null)
          or (generation > 1 and reissue_reason is not null));
  end if;
end $$;

-- ★ EXACTLY ONE CURRENT GENERATION PER EPISODE, AS A WALL RATHER THAN A CONVENTION.
-- Legacy rows carry a NULL case_id, and NULLs are distinct in a unique index, so they neither
-- collide with each other nor are blocked. A concurrent double-reissue fails here instead of
-- producing two rows that both believe they are current.
create unique index if not exists owner_notice_outbox_one_current_per_case_idx
  on public.owner_notice_outbox (case_id, channel, notice_kind)
  where superseded_by is null;

-- The episode lookup the release predicate and the console both perform. No index on
-- `notice_accepted_at`: the predicate is always per-case and this covers it, and an unused index is
-- a claim about a query nobody runs.
create index if not exists owner_notice_outbox_case_idx
  on public.owner_notice_outbox (case_id);

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 4 · BACKFILL — ONE, AND IT IS VACUOUS
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- `generation` arrives with DEFAULT 1, which every existing row therefore already carries. Stated
-- explicitly so the absence of an UPDATE here is legible as a decision rather than an omission.
-- There is deliberately NO statement setting `notice_accepted_at`, `case_id`, `superseded_by`,
-- `reissue_reason` or `reissued_by` on any existing row.
--
-- ★ AND IT MUST NOT ASSERT ONE-ROW-PER-ESTATE. Multiple rows per estate are legitimate — separate
-- death processes over time — so an assertion of uniqueness per estate would fail on correct data.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 5 · PROVE THE SEAM TOOK, BY EXECUTION (the 0051/0052/0054/0057 discipline)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare
  v_type      text;
  v_nullable  text;
  v_def       text;
  v_estate    uuid;
  v_user      uuid;
  v_case      uuid;
  v_a         uuid;
  v_b         uuid;
  v_ok        boolean;
begin
  -- ── 5.1 every column present, with the stated type and nullability ──────────────────────────
  for v_type, v_nullable in
    select column_name, data_type from information_schema.columns
     where table_schema = 'public' and table_name = 'owner_notice_outbox'
       and column_name in ('notice_accepted_at', 'case_id', 'generation',
                           'superseded_by', 'reissue_reason', 'reissued_by')
  loop
    null; -- presence is asserted individually below, with the specific expectation each one carries
  end loop;

  select data_type, is_nullable into v_type, v_nullable
    from information_schema.columns
   where table_schema = 'public' and table_name = 'owner_notice_outbox'
     and column_name = 'notice_accepted_at';
  if v_type is null then
    raise exception '0058 FAILED: notice_accepted_at was not added';
  end if;
  if v_type <> 'timestamp with time zone' then
    raise exception '0058 FAILED: notice_accepted_at is %, expected timestamptz', v_type;
  end if;
  -- ★ NULLABLE IS LOAD-BEARING. A NOT NULL acceptance column would have required a backfill
  -- default, and every value it invented would be a fabricated provider acceptance.
  if v_nullable <> 'YES' then
    raise exception '0058 FAILED: notice_accepted_at must remain nullable (it is %), or every '
      'pre-Phase-A row carries a fabricated provider acceptance', v_nullable;
  end if;

  select is_nullable, column_default into v_nullable, v_def
    from information_schema.columns
   where table_schema = 'public' and table_name = 'owner_notice_outbox'
     and column_name = 'generation';
  if v_nullable is null then
    raise exception '0058 FAILED: generation was not added';
  end if;
  if v_nullable <> 'NO' or coalesce(v_def, '') not like '1%' then
    raise exception '0058 FAILED: generation must be NOT NULL DEFAULT 1 (nullable=%, default=%)',
      v_nullable, v_def;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'owner_notice_outbox'
                    and column_name = 'case_id' and data_type = 'uuid') then
    raise exception '0058 FAILED: case_id was not added as uuid';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'owner_notice_outbox'
                    and column_name = 'superseded_by' and data_type = 'uuid') then
    raise exception '0058 FAILED: superseded_by was not added as uuid';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'owner_notice_outbox'
                    and column_name = 'reissued_by' and data_type = 'uuid') then
    raise exception '0058 FAILED: reissued_by was not added as uuid';
  end if;

  -- ── 5.2 the indexes and the FKs ─────────────────────────────────────────────────────────────
  if not exists (select 1 from pg_indexes where schemaname = 'public'
                  and indexname = 'owner_notice_outbox_one_current_per_case_idx') then
    raise exception '0058 FAILED: the one-current-generation-per-case unique index is absent';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'public'
                  and indexname = 'owner_notice_outbox_case_idx') then
    raise exception '0058 FAILED: the case_id index is absent';
  end if;
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint where conname = 'owner_notice_outbox_superseded_fk';
  if v_def is null then
    raise exception '0058 FAILED: the superseded_by self-FK is absent';
  end if;
  -- Without ON DELETE SET NULL a purge spanning a superseded pair can fail on delete ordering.
  if v_def not like '%ON DELETE SET NULL%' then
    raise exception '0058 FAILED: superseded_by FK must be ON DELETE SET NULL, got %', v_def;
  end if;

  -- ── 5.3 THE FOUR DIRECTIONS OF THE EPISODE WALL, BY EXECUTION ───────────────────────────────
  --
  -- A legacy row that persists, a NULL insert that is refused, a populated insert that succeeds,
  -- and — the direction a NOT VALID check got wrong — an UPDATE of a legacy row that still works.
  -- The third is the positive control: without it, a trigger that refused EVERYTHING would satisfy
  -- the second and look like a pass.
  select e.id into v_estate from public.estates e limit 1;
  if v_estate is null then
    raise notice '0058 · no estates in this database — the execution controls in 5.3/5.4 are '
      'SKIPPED. This is reported rather than silently passed: on an empty database they would '
      'assert nothing. They run in the SQL suite and on any database with real rows.';
  else
    select o.user_id into v_user from public.owner_notice_outbox o where o.user_id is not null limit 1;
    if v_user is null then
      select m.user_id into v_user from public.estate_memberships m
       where m.estate_id = v_estate limit 1;
    end if;
    select c.id into v_case from public.death_verification_cases c
     where c.estate_id = v_estate order by c.created_at desc limit 1;

    if v_user is null or v_case is null then
      raise notice '0058 · no (user, case) pair available for estate % — execution controls '
        'SKIPPED and reported, never assumed.', v_estate;
    else
      -- (a) a LEGACY-shaped row, inserted with the trigger disabled exactly as history produced it
      alter table public.owner_notice_outbox disable trigger owner_notice_outbox_require_episode;
      insert into public.owner_notice_outbox
        (estate_id, user_id, channel, recipient, notice_kind, status, case_id)
      values (v_estate, v_user, 'email', '0058-selfcheck-legacy@invalid',
              'death_process.window_opened', 'queued', null)
      returning id into v_a;
      alter table public.owner_notice_outbox enable trigger owner_notice_outbox_require_episode;

      if v_a is null then
        raise exception '0058 FAILED: could not create the legacy-shaped control row';
      end if;

      -- (b) the legacy row must remain UPDATABLE — the stale sweep and the settle path both do this
      begin
        update public.owner_notice_outbox
           set status = 'failedPermanent', failure_class = 'stale_beyond_age_gate'
         where id = v_a;
        v_ok := true;
      exception when others then
        v_ok := false;
      end;
      if not v_ok then
        raise exception '0058 FAILED: a legacy NULL-case_id row is not updatable. The stale sweep '
          'and record_owner_notice_outcome both UPDATE such rows, so the owner-notice drain is '
          'broken by this migration — which claims to change no behaviour.';
      end if;

      -- (c) a NEW row with no episode must be REFUSED
      begin
        insert into public.owner_notice_outbox
          (estate_id, user_id, channel, recipient, notice_kind, status, case_id)
        values (v_estate, v_user, 'email', '0058-selfcheck-noepisode@invalid',
                'death_process.window_opened', 'queued', null);
        v_ok := false; -- reached = the wall did not hold
      exception when others then
        v_ok := true;
      end;
      if not v_ok then
        raise exception '0058 FAILED: a new owner-notice row was accepted with no case_id — every '
          'future notice can be written outside an episode and the release predicate has no key';
      end if;

      -- (d) POSITIVE CONTROL: a new row WITH an episode must SUCCEED. Without this, a trigger that
      -- refused every insert would satisfy (c) and read as correct.
      begin
        insert into public.owner_notice_outbox
          (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation)
        values (v_estate, v_user, 'email', '0058-selfcheck-episode@invalid',
                'death_process.window_opened', 'queued', v_case, 1)
        returning id into v_b;
        v_ok := v_b is not null;
      exception when others then
        v_ok := false;
      end;
      if not v_ok then
        raise exception '0058 FAILED: positive control — a new row WITH a case_id was refused, so '
          'the episode wall is refusing everything and control (c) proved nothing';
      end if;

      -- (e) the partial unique index refuses a SECOND current generation for one case
      begin
        insert into public.owner_notice_outbox
          (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation)
        values (v_estate, v_user, 'email', '0058-selfcheck-dup@invalid',
                'death_process.window_opened', 'queued', v_case, 1);
        v_ok := false;
      exception when unique_violation then
        v_ok := true;
      when others then
        v_ok := false;
      end;
      if not v_ok then
        raise exception '0058 FAILED: two CURRENT generations coexist for one case — the active '
          'generation is not structurally identified and the door would need a max()';
      end if;

      -- (f) the pairing CHECK refuses generation 2 with no reason, and the vocabulary is closed
      begin
        insert into public.owner_notice_outbox
          (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation)
        values (v_estate, v_user, 'email', '0058-selfcheck-pairing@invalid',
                'death_process.window_opened', 'queued', v_case, 2);
        v_ok := false;
      exception when check_violation then
        v_ok := true;
      when others then
        v_ok := false;
      end;
      if not v_ok then
        raise exception '0058 FAILED: generation 2 was accepted with a NULL reissue_reason';
      end if;

      begin
        insert into public.owner_notice_outbox
          (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
           reissue_reason)
        values (v_estate, v_user, 'email', '0058-selfcheck-vocab@invalid',
                'death_process.window_opened', 'queued', v_case, 2, 'because_i_said_so');
        v_ok := false;
      exception when check_violation then
        v_ok := true;
      when others then
        v_ok := false;
      end;
      if not v_ok then
        raise exception '0058 FAILED: reissue_reason accepted a value outside the closed vocabulary';
      end if;

      -- (g) ★ A SUPERSESSION PAIR IS WRITABLE, AND A DANGLING POINTER IS STILL REFUSED.
      --
      -- The whole re-notice mechanism depends on this ordering being legal. With the FK immediate it
      -- is NOT: insert-first raises unique_violation and update-first raises foreign_key_violation, so
      -- the pair cannot be written in either direction. Asserted by EXECUTION because a constraint
      -- definition that merely reads `deferrable` is not proof that the sequence works.
      declare
        v_succ uuid := gen_random_uuid();
      begin
        begin
          -- retire the current generation by pointing it at a successor that does not exist yet…
          update public.owner_notice_outbox set superseded_by = v_succ where id = v_b;
          -- …then create that successor, which is free of the unique index only because of the line
          -- above, and legal only because the FK check is deferred to commit.
          insert into public.owner_notice_outbox
            (id, estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
             reissue_reason)
          values (v_succ, v_estate, v_user, 'email', '0058-selfcheck-gen2@invalid',
                  'death_process.window_opened', 'queued', v_case, 2, 'prior_failed_permanent');
          v_ok := true;
        exception when others then
          v_ok := false;
        end;
        if not v_ok then
          raise exception '0058 FAILED: a supersession pair could not be written. The superseded_by '
            'FK must be DEFERRABLE INITIALLY DEFERRED — with it immediate, insert-first raises '
            'unique_violation and update-first raises foreign_key_violation, so a re-notice can never '
            'be written in either direction.';
        end if;

        -- ★ POSITIVE CONTROL ON THE DEFERRAL: integrity must still hold. A `superseded_by` pointing at
        -- no row must be refused when the constraint is checked. Without this control, "deferrable"
        -- could silently mean "unenforced" — and the whole supersession model would rest on a pointer
        -- nothing validates. The failed subtransaction rolls the bad UPDATE back on its own, so the
        -- pair written above survives intact.
        begin
          update public.owner_notice_outbox set superseded_by = gen_random_uuid() where id = v_b;
          set constraints owner_notice_outbox_superseded_fk immediate;
          v_ok := false;
        exception when foreign_key_violation then
          v_ok := true;
        when others then
          v_ok := false;
        end;
        if not v_ok then
          raise exception '0058 FAILED: a DANGLING superseded_by pointer was accepted — deferring the '
            'FK has weakened integrity instead of only relaxing intra-transaction ordering';
        end if;
      end;

      -- clean up every control row this block created, and prove it. Order matters: the successor is
      -- referenced by the predecessor, and ON DELETE SET NULL handles it, but deleting in one
      -- statement keeps the set closed.
      update public.owner_notice_outbox set superseded_by = null
       where recipient like '0058-selfcheck-%@invalid';
      delete from public.owner_notice_outbox where recipient like '0058-selfcheck-%@invalid';
      if exists (select 1 from public.owner_notice_outbox
                  where recipient like '0058-selfcheck-%@invalid') then
        raise exception '0058 FAILED: the self-check left rows in the owner notice outbox';
      end if;
    end if;
  end if;

  -- ── 5.4 THE INVERSION: THIS MIGRATION HAS NOT CHANGED THE RELEASE DOOR ──────────────────────
  --
  -- Phase A is provably schema-and-observation only, asserted the same way 0056 and 0057 assert it.
  -- Phase D (0060) is the artifact allowed to change this, and it says so loudly.
  if to_regprocedure('public.authorize_release(uuid, text)') is not null then
    select prosrc into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'authorize_release';
    if v_def not like '%status <> ''cancelled''%' then
      raise exception '0058 FAILED: authorize_release no longer carries the pre-Phase-D predicate. '
        'Phase A must not change when a release may proceed — that is Phase D (migration 0060), '
        'and folding it in here would deploy the cutover without its census or its remedy.';
    end if;
    if v_def like '%notice_accepted_at%' then
      raise exception '0058 FAILED: authorize_release already reads notice_accepted_at — the Phase D '
        'cutover has been pasted as part of Phase A, ahead of the blast-radius census';
    end if;
  end if;

  raise notice '0058 OK: acceptance fact + episode columns present and nullable-correct; episode '
    'wall holds on INSERT and leaves legacy rows updatable (both proved by execution, with a '
    'positive control); one-current-generation index enforced; reason vocabulary closed; release '
    'door PROVABLY unchanged.';
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 6 · THE BLAST-RADIUS REPORT — counts only, no ids, no addresses, no estate names
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ A MIGRATION THAT PREPARES A RELEASE-PREDICATE CHANGE WITHOUT STATING HOW MANY LIVE ESTATES IT
-- WILL BLOCK IS A SILENT OPERATIONAL CHANGE. This is a NOTICE rather than an assertion: a non-zero
-- legacy population is not an error, it is the number Phase B exists to learn and the input to the
-- gate in front of Phase D. It is printed HERE — the schema-only step — so it is known BEFORE any
-- behaviour changes.
do $$
declare
  v_total       bigint;
  v_legacy_case bigint;
  v_legacy_acc  bigint;
  v_cw          bigint;
  v_cw_blocked  bigint;
begin
  select count(*) into v_total from public.owner_notice_outbox;
  select count(*) into v_legacy_case from public.owner_notice_outbox where case_id is null;
  select count(*) into v_legacy_acc from public.owner_notice_outbox
   where status = 'dispatched' and notice_accepted_at is null;

  select count(*) into v_cw from public.estate_lifecycle where state = 'challenge_window';
  -- Estates in the window that Phase D would refuse: no notice in the CURRENT episode carries an
  -- acceptance fact. Scoped by case exactly as the Phase D predicate will be.
  select count(*) into v_cw_blocked
    from public.estate_lifecycle l
   where l.state = 'challenge_window'
     and not exists (
       select 1
         from public.death_verification_cases c
         join public.owner_notice_outbox o on o.case_id = c.id
        where c.estate_id = l.estate_id
          and c.status = 'verified'
          and o.channel = 'email'
          and o.notice_kind = 'death_process.window_opened'
          and o.notice_accepted_at is not null
     );

  raise notice '0058 CENSUS · outbox rows=% · no episode (case_id NULL)=% · dispatched with no '
    'acceptance fact=% · estates at challenge_window=% · of those, estates Phase D would REFUSE '
    'with notice_never_accepted=%', v_total, v_legacy_case, v_legacy_acc, v_cw, v_cw_blocked;
  if v_cw_blocked > 0 then
    raise notice '0058 GATE · % challenge-window estate(s) have NO provable provider acceptance in '
      'their current case. Phase D MUST NOT be activated for that class until the operator '
      're-notice remedy (Phase C) is deployed and operational. This is the Phase B decision.',
      v_cw_blocked;
  end if;
end $$;
