-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 0052 · PHASE 11-C — death event + evidence + verification-state FOUNDATION (data model only)
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THIS MIGRATION CHANGES NO DISCLOSURE. It creates three tables and grants NOTHING to any client
-- role. Every read path answers exactly what it answered before, for every stored row — the Phase
-- 11-C SQL suite compares composed viewer payloads across every new state to prove it.
--
-- What exists after this migration:
--
--   1 · `estate_lifecycle` — the AUTHORITATIVE estate lifecycle record Phase 11-B deferred here.
--       One current state per estate. `claim_packets.status` stops being the only carrier of
--       anything lifecycle-shaped: the claim row is EVIDENCE FOR a lifecycle event, never the event.
--       (`estate_release_state()` remains what it was — a label-only projection of claim status
--       with one consumer — untouched, still consulted by no authorization path.)
--
--   2 · `death_verification_cases` — the death-verification case: who initiated, in what fiduciary
--       capacity, under what jurisdiction context, what the policy REQUIRED at initiation, and what
--       has actually been ATTAINED. Required and attained are different columns with different
--       writers, and the attained baseline is NULL — nothing attained — which is the fail-closed
--       floor every comparison must coalesce against.
--
--   3 · `death_verification_evidence` — evidence received for a case. Evidence KIND is not modelled
--       here as a new vocabulary: an evidence row references a `documents` row, and the document
--       taxonomy (a server catalog) is the authoritative descriptor of what a document is. Review
--       status says only what the platform actually did — `received` / `reviewed_accepted` /
--       `reviewed_rejected` — never "verified": no authenticity vendor exists, and a status that
--       claimed verification would be a fact the system does not possess.
--
-- ★ WHAT IS DELIBERATELY IMPOSSIBLE HERE:
--
--   · `released` is NOT in the lifecycle CHECK. Making an estate released is not a state this
--     schema can store, let alone a transition a routine could take. Widening that CHECK is 11-D's
--     controlled, reviewed change — not a value waiting for a writer.
--   · `event_type` admits ONLY 'death'. Incapacity is a legally distinct event (D9); the fused
--     death-or-incapacity shape is unrepresentable for new rows. Widening the CHECK is an explicit
--     future migration, not an accepted value.
--   · No client role can read or write any of the three tables. RLS is enabled and there are ZERO
--     grants and ZERO policies — the tables are reachable only through the SECURITY DEFINER
--     routines in `db/functions/death_verification.sql`, each of which carries its own gate.
--   · Nothing here manufactures a grant, a disclosure tier, or a fiduciary capacity. The case
--     records facts ABOUT verification; it is not itself an access instrument.
--
-- ★ REQUIRED vs ATTAINED. `required_level_at_initiation` is a SNAPSHOT of what
-- `public.required_verification_level(estate)` answered when the case was opened — recorded so the
-- case file is honest about the policy in force at initiation. It is NEVER the enforcement input:
-- the decision routine re-derives the requirement live at decision time, so a policy tightened
-- mid-case tightens the case. The snapshot cannot leak into `attained_level` — different columns,
-- different writers, and the suite mutation-proves that initiation leaves attained NULL.
--
-- IDEMPOTENT. Safe to re-apply: `create table if not exists`, `create index if not exists`, and
-- the self-checks at the end raise rather than silently no-op.
--
-- APPLY ORDER: requires migrations 0019 (estate_designations), 0026/0027 (verification_level enum +
-- policy engine), 0035 (documents write path exists in practice) — all deployed long before this
-- file. Standing Phase 11-B rule unchanged: `release_conditions_bundle.sql` is pasted FIRST before
-- any other bundle re-application. The `death_verification_bundle.sql` artifact bundles this file
-- with its routines in the right order for a single paste.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · THE ESTATE LIFECYCLE RECORD — one authoritative current state per estate
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ ABSENT ROW = 'active'. Every estate that has never seen a death-verification case has no row
-- here, and `estate_lifecycle_state()` reads that absence as the base state. That keeps the table
-- append-on-first-event rather than requiring a backfill trigger on estate creation, and it means
-- the empty table is a correct table, not a missing one.
--
-- ★ HISTORY LIVES IN `audit_logs`. Every transition writes an audit row carrying from/to/case/actor
-- (see `apply_estate_lifecycle_transition`), so the current-state row can stay a single row per
-- estate without losing the append-only trail the 11-A forensics review required.
create table if not exists public.estate_lifecycle (
  estate_id  uuid primary key references public.estates(id) on delete cascade,
  -- 'released', 'frozen', 'release_pending' are DELIBERATELY NOT HERE. A value with no writer is a
  -- value waiting for one; the 11-D activation adds states the same reviewed way this file adds
  -- these three. `death_verified` IS reachable in 11-C — through exactly one admin-gated routine
  -- that enforces attained ≥ required — and the Phase 11-C suite proves reaching it changes no
  -- viewer payload by one byte.
  state           text        not null default 'active'
    check (state in ('active', 'death_verification_pending', 'death_verified')),
  updated_at      timestamptz not null default now(),
  -- The case that most recently moved this estate's state (null for the base row shape). Kept as a
  -- plain FK for forensics; authority never flows FROM this column.
  updated_case_id uuid
);

alter table public.estate_lifecycle enable row level security;
-- ZERO grants, ZERO policies — not client-readable, not client-writable, by construction. The
-- jurisdiction_policy precedent: a table only DEFINER routines may touch needs no latent policy
-- inviting a future grant to widen it.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 2 · THE DEATH-VERIFICATION CASE
-- ────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists public.death_verification_cases (
  id                           uuid        primary key default gen_random_uuid(),
  estate_id                    uuid        not null references public.estates(id) on delete cascade,
  -- ★ ONLY 'death'. Incapacity is a distinct event with a deferred workflow (D9); admitting it here
  -- before that workflow exists would be vocabulary ahead of authorization. The fused value is
  -- unrepresentable — that is the point.
  event_type                   text        not null default 'death'
    check (event_type in ('death')),
  status                       text        not null default 'open'
    check (status in ('open', 'verified', 'rejected', 'cancelled')),
  initiated_by                 uuid        not null references auth.users(id),
  -- The designation row that AUTHORIZED initiation, and the capacity it carried at that moment.
  -- Capacity is a snapshot of fact ("this person acted as executor"), never an authority the case
  -- can later re-assert — a revoked designee does not keep acting because a case remembers them.
  initiator_designation_id     uuid        not null references public.estate_designations(id),
  initiator_capacity           text        not null
    check (initiator_capacity in ('executor', 'trustee')),
  -- Snapshot of `estates.jurisdiction` at initiation. NULL is a legal, honest value — an estate
  -- with no jurisdiction resolves to the fail-closed maximum requirement, and recording NULL here
  -- says "unknown at initiation" rather than inventing a jurisdiction.
  jurisdiction_context         text,
  -- What the policy engine REQUIRED when the case opened. A record, not the enforcement input —
  -- the decision routine re-derives live. Typed to the same enum as the requirement engine so the
  -- two can never drift vocabularies.
  required_level_at_initiation public.verification_level not null,
  -- What has actually been ATTAINED. NULL = nothing attained — the fail-closed baseline every
  -- comparison must coalesce against. Written by exactly one admin-gated routine; the enum type
  -- makes an out-of-vocabulary level unrepresentable rather than merely refused.
  attained_level               public.verification_level,
  decided_by                   uuid        references auth.users(id),
  decided_at                   timestamptz,
  decision_note                text,
  created_at                   timestamptz not null default now(),
  updated_at                   timestamptz not null default now()
);

-- ★ ONE OPEN CASE PER ESTATE — the claim_packets_one_active_per_estate precedent. Decided cases
-- (verified / rejected / cancelled) are history and coexist; a second OPEN case is a conflict, not
-- a queue.
create unique index if not exists death_verification_cases_one_open_per_estate
  on public.death_verification_cases (estate_id) where status = 'open';
create index if not exists death_verification_cases_estate_idx
  on public.death_verification_cases (estate_id);

alter table public.death_verification_cases enable row level security;
-- ZERO grants, ZERO policies. Unlike `claim_packets` (which the mobile client reads directly under
-- `claim_own_read`), no client surface reads cases in 11-C — so nothing is granted, and an
-- unauthorized viewer cannot learn a case EXISTS, which is itself protected information (T9/H1:
-- whether a death claim is in flight is a fact about a person).

-- The lifecycle FK arrives after the cases table exists (forward reference above).
do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'estate_lifecycle_updated_case_id_fkey'
  ) then
    alter table public.estate_lifecycle
      add constraint estate_lifecycle_updated_case_id_fkey
      foreign key (updated_case_id) references public.death_verification_cases(id);
  end if;
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 3 · EVIDENCE — received, reviewed, never "verified"
-- ────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists public.death_verification_evidence (
  id            uuid        primary key default gen_random_uuid(),
  case_id       uuid        not null references public.death_verification_cases(id) on delete cascade,
  -- Denormalized estate scope so cross-estate smuggling is refusable without a join, and provable
  -- by constraint in the routines (the attach routine asserts document.estate_id = case.estate_id).
  estate_id     uuid        not null references public.estates(id) on delete cascade,
  -- ★ NO `on delete` CLAUSE — deliberate. `documents` is the single secure store (the Vault); an
  -- evidence pin does not copy bytes, it references them. A vault deletion that would orphan
  -- OPEN-case evidence fails the FK instead of silently un-evidencing a case. (The claim pins chose
  -- `on delete set null` + an explicit `blocked_active_claim` guard inside the delete routine;
  -- giving this FK the same polished sentinel is recorded in the 11-C deferred ledger rather than
  -- edited into `delete_vault_document` here, because that function is deployed and unbundled, and
  -- editing it would open a source↔deployment drift this phase does not need.)
  document_id   uuid        not null references public.documents(id),
  submitted_by  uuid        not null references auth.users(id),
  submitted_at  timestamptz not null default now(),
  -- What the platform actually did with it. 'received' is the entire truth at insert time — no
  -- authenticity vendor exists, and nothing here may claim one does (D1; brief §13).
  review_status text        not null default 'received'
    check (review_status in ('received', 'reviewed_accepted', 'reviewed_rejected')),
  reviewed_by   uuid        references auth.users(id),
  reviewed_at   timestamptz,
  review_note   text
);

create index if not exists death_verification_evidence_case_idx
  on public.death_verification_evidence (case_id);
create index if not exists death_verification_evidence_document_idx
  on public.death_verification_evidence (document_id);

alter table public.death_verification_evidence enable row level security;
-- ZERO grants, ZERO policies — same posture, same reason.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 4 · PROVE THE FOUNDATION TOOK, IN THE MIGRATION ITSELF
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ BOTH DIRECTIONS, LIKE 0051: the states this phase needs must be admitted, and the states this
-- phase must NOT make storable must be absent from the constraint text. A CHECK that silently
-- failed to apply reads identically from the accepting side.
do $$
declare
  v_def text;
begin
  -- Lifecycle vocabulary: exactly the three 11-C states, and no release-shaped value.
  select pg_get_constraintdef(con.oid) into v_def
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'estate_lifecycle'
     and con.contype = 'c' and pg_get_constraintdef(con.oid) ilike '%state%';
  if v_def is null then
    raise exception '0052 FAILED: estate_lifecycle has no state CHECK';
  end if;
  if position('death_verification_pending' in v_def) = 0
     or position('death_verified' in v_def) = 0 then
    raise exception '0052 FAILED: lifecycle CHECK is missing an 11-C state: %', v_def;
  end if;
  if position('released' in v_def) > 0 or position('frozen' in v_def) > 0 then
    raise exception '0052 FAILED: a release-shaped state is storable — that is the 11-D change, '
      'not a value waiting for a writer: %', v_def;
  end if;

  -- Event vocabulary: death only; the fused shape unrepresentable.
  select pg_get_constraintdef(con.oid) into v_def
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'death_verification_cases'
     and con.contype = 'c' and pg_get_constraintdef(con.oid) ilike '%event_type%';
  if v_def is null then
    raise exception '0052 FAILED: death_verification_cases has no event_type CHECK';
  end if;
  if position('incapacity' in v_def) > 0 then
    raise exception '0052 FAILED: event_type admits an incapacity value — D9 keeps the events '
      'distinct and the incapacity workflow deferred: %', v_def;
  end if;

  -- Required and attained are BOTH the policy engine's enum — no duplicate ladder, no drift.
  if (select count(*)
        from information_schema.columns
       where table_schema = 'public' and table_name = 'death_verification_cases'
         and column_name in ('required_level_at_initiation', 'attained_level')
         and udt_name = 'verification_level') <> 2 then
    raise exception '0052 FAILED: required/attained levels are not both typed '
      'public.verification_level — a second vocabulary would drift from the policy engine';
  end if;

  -- The attained baseline is fail-closed: no default may exist on the column.
  if (select column_default
        from information_schema.columns
       where table_schema = 'public' and table_name = 'death_verification_cases'
         and column_name = 'attained_level') is not null then
    raise exception '0052 FAILED: attained_level has a DEFAULT — the baseline must be NULL '
      '(nothing attained), not a granted starting level';
  end if;

  -- No client role can touch any of the three tables.
  if exists (
    select 1
      from information_schema.role_table_grants
     where table_schema = 'public'
       and table_name in ('estate_lifecycle', 'death_verification_cases', 'death_verification_evidence')
       and grantee in ('anon', 'authenticated')
  ) then
    raise exception '0052 FAILED: a client role holds a table grant on the death-verification '
      'foundation — these tables are DEFINER-routine-only';
  end if;

  raise notice '0052 · death-verification foundation in place (lifecycle, case, evidence; '
    'released unrepresentable; attained baseline NULL; client roles grant-less)';
end $$;
