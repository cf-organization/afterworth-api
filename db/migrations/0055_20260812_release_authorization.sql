-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 0055 · PHASE 11-F — owner-liveness delivery, the two-person release rule, and the release record
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THE FIVE APPROVED DECISIONS CHANGE, AND WHY EACH NEEDS SCHEMA.
--
-- D1 · TWO-PERSON RULE. The operator who verifies a death may not be the operator who authorizes
--      release, and that is enforced in the DATABASE, not in a console. `release_authorizations`
--      records both reviewers as first-class columns with a CHECK that they differ — so the rule
--      survives a UI rewrite, a direct RPC call, and a future admin tool nobody has written yet.
--
-- D2 · THE CLOCK STARTS AT DISPATCH, NOT AT VERIFICATION. A seventh lifecycle state
--      (`owner_notification_dispatched`) sits between `death_verified` and `challenge_window`
--      precisely so "we accepted the death" and "we told the owner" cannot be the same fact. The
--      duration is 7 x 24h — now an approved decision, so 0055 SEEDS it (0054 deliberately did not,
--      because in 11-E it was not yet decided).
--
-- D4 · IN-APP ALONE IS INSUFFICIENT. `owner_notice_outbox` is the independently-reachable channel:
--      an email row committed in the same transaction as the dispatch transition. The requirement is
--      DISPATCH INITIATION — the row exists and is addressed — never a read receipt, an open, or an
--      acknowledgement, none of which the product can honestly observe.
--
-- ★ WHAT THIS MIGRATION STILL CANNOT DO. It creates no grant, tier, membership or designation, and
-- it makes `released` no easier to reach: the route is still `challenge_window -> released` alone,
-- now additionally gated on two distinct reviewers and a dispatched notice (D5).
--
-- IDEMPOTENT. Safe to re-apply. APPLY ORDER: after 0054, inside the bundles that carry it.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · THE SEVENTH LIFECYCLE STATE — "we told the owner" is its own fact
-- ────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare v_name text;
begin
  for v_name in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public' and rel.relname = 'estate_lifecycle'
       and con.contype = 'c' and pg_get_constraintdef(con.oid) ilike '%state%'
  loop
    execute format('alter table public.estate_lifecycle drop constraint %I', v_name);
  end loop;

  alter table public.estate_lifecycle
    add constraint estate_lifecycle_state_check
    check (state in (
      'active',
      'death_verification_pending',
      'death_verified',
      -- Phase 11-F (D2): the owner has been told, and the challenge clock has started.
      'owner_notification_dispatched',
      'challenge_window',
      'challenge_halted',
      'released'
    ));
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 2 · THE OWNER NOTICE OUTBOX — the independently reachable channel (D4)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ A SEPARATE TABLE FROM `invitation_delivery_outbox`, DELIBERATELY. That outbox is FK-bound to an
-- invitation and drained by a daily cron whose claim predicate has no age bound — the right class
-- for an invitation email and the wrong one for the notice that starts a release clock. Sharing it
-- would silently inherit both properties.
--
-- ★ THE RECIPIENT IS RESOLVED AND STORED AT DISPATCH. Storing the address is what makes
-- "independently reachable" a checkable fact rather than an assumption: a dispatch with no
-- resolvable address must FAIL, not queue a row nobody can deliver.
create table if not exists public.owner_notice_outbox (
  id            uuid        primary key default gen_random_uuid(),
  estate_id     uuid        not null references public.estates(id) on delete cascade,
  user_id       uuid        not null references auth.users(id),
  -- Email is the minimum bar (D4). Push, when it exists, is SUPPLEMENTAL and joins this CHECK by a
  -- reviewed migration — it never replaces the email row.
  channel       text        not null default 'email' check (channel in ('email')),
  recipient     text        not null,
  notice_kind   text        not null check (notice_kind in ('death_process.window_opened')),
  status        text        not null default 'queued'
    check (status in ('queued', 'processing', 'dispatched', 'failedPermanent', 'cancelled')),
  requested_at  timestamptz not null default now(),
  dispatched_at timestamptz,
  attempts      int         not null default 0,
  next_attempt_at timestamptz,
  failure_class text,
  purge_audit_id uuid
);

create index if not exists owner_notice_outbox_estate_idx on public.owner_notice_outbox (estate_id);
create index if not exists owner_notice_outbox_claimable_idx
  on public.owner_notice_outbox (requested_at) where status in ('queued', 'processing');

alter table public.owner_notice_outbox enable row level security;
-- ZERO grants, ZERO policies: a row here names a living owner's email address and the fact that a
-- death process is running against their estate. Only DEFINER routines may touch it.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 3 · THE RELEASE AUTHORIZATION RECORD — its own model, never overloaded (Stage 5)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ NOT A CLAIM PACKET, NOT A MEMBERSHIP, NOT A DESIGNATION. Each of those answers a different
-- question with a different actor, evidence and reversibility; overloading one of them to carry
-- "two operators authorized this release" is how a fact acquires the wrong lifecycle. This table
-- exists so the release event has a home with exactly the fields the audit needs.
--
-- ★ THE TWO-PERSON RULE IS A TABLE CONSTRAINT (D1). Not a trigger, not a routine-only check: a CHECK
-- means no INSERT anywhere — routine, migration, console, future admin tool — can record a release
-- authorized by one person. The routine enforces it too; this is the layer that cannot be bypassed.
create table if not exists public.release_authorizations (
  id            uuid        primary key default gen_random_uuid(),
  estate_id     uuid        not null references public.estates(id) on delete cascade,
  case_id       uuid        not null references public.death_verification_cases(id),
  -- reviewer_a VERIFIED THE DEATH. reviewer_b AUTHORIZED THE RELEASE. They must differ.
  reviewer_a    uuid        not null references auth.users(id),
  reviewer_b    uuid        not null references auth.users(id),
  verified_at   timestamptz not null,
  authorized_at timestamptz not null default now(),
  released_at   timestamptz,
  audit_reason  text        not null,
  constraint release_authorizations_two_person check (reviewer_a <> reviewer_b)
);

-- One authorization per estate: release is not a thing that happens twice.
create unique index if not exists release_authorizations_one_per_estate
  on public.release_authorizations (estate_id);

alter table public.release_authorizations enable row level security;
-- ZERO grants, ZERO policies — DEFINER-routine-only, like every other record on this path.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 4 · THE PURGE AUDIT — nothing is ever silently deleted (Stage 3)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists public.outbox_purge_audit (
  id            uuid        primary key default gen_random_uuid(),
  outbox_name   text        not null,
  purged_at     timestamptz not null default now(),
  actor_id      uuid,
  row_count     int         not null,
  oldest_row_at timestamptz,
  newest_row_at timestamptz,
  reason        text        not null
);
alter table public.outbox_purge_audit enable row level security;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 5 · THE CHALLENGE WINDOW DURATION — 7 x 24h, now an APPROVED decision (D2)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ 0054 DELIBERATELY SEEDED NOTHING, AND THAT WAS RIGHT THEN. In 11-E the duration was undecided,
-- so the fail-closed posture was "no window can ever elapse". D2 decides it, so it is recorded here
-- — in a migration, reviewably, once — rather than left to an operator's console session where
-- nobody could later say what value production carries or when it changed.
--
-- `on conflict do update` is deliberate: re-applying this migration re-asserts the approved value,
-- so a hand-edited production row is corrected by the next paste rather than silently kept.
insert into public.release_safety_policy (id, challenge_window)
values (true, interval '7 days')
on conflict (id) do update set challenge_window = excluded.challenge_window, updated_at = now();

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 6 · REMOVE the one-person release lever
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE 0053 PRECEDENT, APPLIED TO AN ACTOR RATHER THAN AN ARGUMENT. 11-E's `release_estate(uuid)`
-- had no concept of a second reviewer. Leaving it in place beside the two-person door would be a
-- second release path that bypasses D1 entirely — and `create or replace` cannot remove it, because
-- the replacement has a different name and signature. It is DROPPED, so a caller that was never
-- rewired fails loudly instead of releasing on one person's say-so.
drop function if exists public.release_estate(uuid);

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 7 · PROVE IT TOOK, IN THE MIGRATION ITSELF (both directions)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare v_def text; v_n int;
begin
  select pg_get_constraintdef(con.oid) into v_def
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'estate_lifecycle'
     and con.contype = 'c' and pg_get_constraintdef(con.oid) ilike '%state%';
  if v_def is null or position('owner_notification_dispatched' in v_def) = 0 then
    raise exception '0055 FAILED: the dispatch state is not storable: %', coalesce(v_def, '<absent>');
  end if;
  if (select count(*) from regexp_matches(v_def, '''[a-z_]+''', 'g')) <> 7 then
    raise exception '0055 FAILED: the lifecycle vocabulary is not exactly seven states: %', v_def;
  end if;

  -- The two-person CHECK must exist as a CONSTRAINT, not merely as routine logic.
  if not exists (
    select 1 from pg_constraint where conname = 'release_authorizations_two_person'
  ) then
    raise exception '0055 FAILED: the two-person rule is not a table constraint — routine-only '
      'enforcement can be bypassed by any other writer';
  end if;
  -- …and it must actually refuse. Proven, not assumed.
  begin
    insert into public.release_authorizations
      (estate_id, case_id, reviewer_a, reviewer_b, verified_at, audit_reason)
    select e.id, c.id, c.initiated_by, c.initiated_by, now(), '0055 self-check'
      from public.estates e join public.death_verification_cases c on c.estate_id = e.id limit 1;
    -- If a row existed to try with AND the insert succeeded, the constraint is not working.
    get diagnostics v_n = row_count;
    if v_n > 0 then
      raise exception '0055 FAILED: a single-reviewer release authorization was insertable';
    end if;
  exception when check_violation then
    null; -- the constraint refused, which is the point
  end;

  -- ★ THE TABLE, NOT THE READER. `challenge_window_duration()` lives in `release_safety.sql`, which
  -- ships in a LATER bundle — so a migration that asked the function would raise on the first paste
  -- of the release-conditions bundle, where 0055 legitimately runs before that function exists. A
  -- migration must be checkable against the schema it changed, not against a function some other
  -- artifact happens to carry.
  if (select p.challenge_window from public.release_safety_policy p where p.id)
     is distinct from interval '7 days' then
    raise exception '0055 FAILED: the challenge window is % (expected 7 days per D2)',
      (select p.challenge_window from public.release_safety_policy p where p.id);
  end if;

  if to_regprocedure('public.release_estate(uuid)') is not null then
    raise exception '0055 FAILED: the one-person release lever still exists — D1 would be bypassable';
  end if;

  if exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public'
       and table_name in ('owner_notice_outbox', 'release_authorizations', 'outbox_purge_audit')
       and grantee in ('anon', 'authenticated')
  ) then
    raise exception '0055 FAILED: a client role holds a grant on a release-path table';
  end if;

  raise notice '0055 · release authorization in place (7 lifecycle states; owner notice outbox; '
    'two-person CHECK enforced; window = 7 days; one-person lever dropped)';
end $$;
