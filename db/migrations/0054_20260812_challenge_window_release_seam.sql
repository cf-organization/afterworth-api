-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 0054 · PHASE 11-E — the challenge window: the safety seam between death_verified and released
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THIS PHASE INSERTS, AND WHY IT EXISTS. 11-D let `after_verified_death` satisfy at
-- `death_verified`. That connected verification directly to irreversible disclosure — and disclosure
-- cannot be undone (R15: revoking future access is possible; undoing disclosure is not). 11-E
-- inserts the missing safety states between them:
--
--     active → death_verification_pending → death_verified
--            → challenge_window            (verification accepted; release deliberately waiting;
--                                           the owner has been notified and can object)
--            → released                    (the ONLY lifecycle at which owner-authored
--                                           death-conditioned grants may evaluate as satisfied)
--     any pre-released death-process state
--            → challenge_halted            (the authenticated owner objected; terminal in 11-E)
--
-- The predicate change rides in `release_conditions.sql`: `after_verified_death` is FALSE at
-- death_verified, FALSE throughout challenge_window, FALSE at challenge_halted, TRUE only at
-- released. So this migration making `released` STORABLE widens no disclosure: the only writer is
-- `release_estate` (client-revoked, no reachable door in 11-E), behind an elapsed, configured,
-- owner-notified, unchallenged window.
--
-- ★ THE WINDOW DURATION IS CONFIGURATION, NOT A GUESS. `release_safety_policy` ships EMPTY: no
-- default duration is seeded, because the duration is a product decision this phase does not own.
-- Fail-closed direction: an estate can always ENTER the challenge window (the owner-safety clock
-- and notice), but with no configured duration the window NEVER ELAPSES and release refuses with
-- `release_window_not_configured`. The duration is re-read LIVE at release time (the H2 precedent:
-- a policy tightened mid-window tightens the window) — never stamped at entry.
--
-- ★ THE OWNER CHALLENGE IS CHEAPER THAN THE CLAIM (R13) AND WINS TIES (R14). No evidence, no
-- review, no waiting period, no designation — one authenticated owner action. The tiebreak is
-- structural: release requires the window STRICTLY elapsed (`now() > notified_at + duration`), so
-- at the exact boundary instant release refuses while challenge still succeeds; both transitions
-- serialize on the lifecycle row lock, and nothing transitions out of challenge_halted.
--
-- IDEMPOTENT. Safe to re-apply. APPLY ORDER: after 0052/0053, inside the bundles that carry it.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · WIDEN the lifecycle vocabulary to the six-state safety machine. Additive only.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- The constraint name is resolved from the catalog, not guessed (the 0051 lesson).
do $$
declare
  v_name text;
begin
  for v_name in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public'
       and rel.relname = 'estate_lifecycle'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%state%'
  loop
    execute format('alter table public.estate_lifecycle drop constraint %I', v_name);
  end loop;

  alter table public.estate_lifecycle
    add constraint estate_lifecycle_state_check
    check (state in (
      'active',
      'death_verification_pending',
      'death_verified',
      -- Phase 11-E: the safety seam. Storable here; REACHABLE only through the closed transition
      -- map in apply_estate_lifecycle_transition, and 'released' only through release_estate.
      'challenge_window',
      'challenge_halted',
      'released'
    ));
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 2 · THE SAFETY FACTS live on the lifecycle row: when the owner was notified, when the window
--     opened, when it was halted or released, and WHICH notification row is the safety notice.
--     Facts, never authority — release re-derives everything live.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
alter table public.estate_lifecycle add column if not exists owner_notified_at            timestamptz;
alter table public.estate_lifecycle add column if not exists challenge_window_started_at  timestamptz;
alter table public.estate_lifecycle add column if not exists halted_at                    timestamptz;
alter table public.estate_lifecycle add column if not exists released_at                  timestamptz;
alter table public.estate_lifecycle add column if not exists safety_notification_id       uuid;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 3 · A HALTED CASE IS ITS OWN STATUS. The owner challenge halts any open case; 'cancelled' means
--     the initiator withdrew and reusing it would erase the difference between "the claimant
--     changed their mind" and "the owner said they are alive" — facts with different forensics.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare
  v_name text;
begin
  for v_name in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public'
       and rel.relname = 'death_verification_cases'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%status%'
       and pg_get_constraintdef(con.oid) not ilike '%event_type%'
       and pg_get_constraintdef(con.oid) not ilike '%review_status%'
       and pg_get_constraintdef(con.oid) not ilike '%initiator_capacity%'
  loop
    execute format('alter table public.death_verification_cases drop constraint %I', v_name);
  end loop;

  alter table public.death_verification_cases
    add constraint death_verification_cases_status_check
    check (status in ('open', 'verified', 'rejected', 'cancelled',
                      -- Phase 11-E: set only by the owner-challenge routine.
                      'halted'));
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 4 · THE WINDOW-DURATION CONFIGURATION — one row, definer-only, DELIBERATELY UNSEEDED.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists public.release_safety_policy (
  -- Single-row table: the PK admits exactly `true`.
  id               boolean     primary key default true check (id),
  challenge_window interval    not null,
  updated_at       timestamptz not null default now()
);

alter table public.release_safety_policy enable row level security;
-- ZERO grants, ZERO policies — reachable only through the DEFINER reader. No seed row: the
-- duration is a product/operator decision recorded by an explicit, reviewed INSERT, and until it
-- exists the release window cannot elapse anywhere.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 5 · PROVE THE SEAM TOOK, IN THE MIGRATION ITSELF (both directions, the 0051/0052 discipline).
-- ────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare
  v_def text;
begin
  select pg_get_constraintdef(con.oid) into v_def
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'estate_lifecycle'
     and con.contype = 'c' and pg_get_constraintdef(con.oid) ilike '%state%';
  if v_def is null then
    raise exception '0054 FAILED: estate_lifecycle has no state CHECK after the widening';
  end if;
  if position('challenge_window' in v_def) = 0
     or position('challenge_halted' in v_def) = 0
     or position('released' in v_def) = 0 then
    raise exception '0054 FAILED: the safety vocabulary is incomplete: %', v_def;
  end if;
  if (select count(*) from regexp_matches(v_def, '''[a-z_]+''', 'g')) <> 6 then
    raise exception '0054 FAILED: the lifecycle vocabulary is not exactly six states: %', v_def;
  end if;
  -- 'frozen' and other invented states must still be unrepresentable.
  if position('frozen' in v_def) > 0 then
    raise exception '0054 FAILED: an unapproved lifecycle state is storable: %', v_def;
  end if;

  select pg_get_constraintdef(con.oid) into v_def
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'death_verification_cases'
     and con.conname = 'death_verification_cases_status_check';
  if v_def is null or position('halted' in v_def) = 0 then
    raise exception '0054 FAILED: the case status vocabulary did not gain ''halted'': %',
      coalesce(v_def, '<absent>');
  end if;

  -- The policy table is definer-only and EMPTY: a seeded duration would be a product decision
  -- taken by a migration.
  if exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and table_name = 'release_safety_policy'
       and grantee in ('anon', 'authenticated')
  ) then
    raise exception '0054 FAILED: a client role holds a grant on release_safety_policy';
  end if;
  if (select count(*) from public.release_safety_policy) <> 0 then
    -- On RE-application to a database whose operator later configured the window, a row is
    -- legitimate — the check refuses only a duration arriving in the SAME transaction that
    -- created the table (i.e. seeded by migration).
    if (select min(updated_at) from public.release_safety_policy) >= transaction_timestamp() then
      raise exception '0054 FAILED: release_safety_policy was seeded by this migration — the '
        'window duration is a product decision, not a default';
    end if;
  end if;

  raise notice '0054 · challenge-window seam in place (6 lifecycle states; halted case status; '
    'safety facts columns; duration configuration table EMPTY and definer-only)';
end $$;
