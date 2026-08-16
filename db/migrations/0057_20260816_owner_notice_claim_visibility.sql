-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-OBR · OB-1 — A CLAIMED OWNER NOTICE MUST BE RECOVERABLE
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THE DEFECT, MEASURED IN PRODUCTION, NOT INFERRED. On 2026-08-16 the Branch A owner-safety
-- notice `7ec99457-38af-4e2c-b2eb-eca771fe7d5e` was observed at `status = 'processing'`,
-- `attempts = 1`, `dispatched_at = null`, `failure_class = null`, `provider_result = null`. The
-- 04:00Z drain had claimed it and never settled it.
--
-- `claim_owner_notices` selects `where o.status = 'queued'` only. A row in `processing` is therefore
-- never handed out again by any future drain. Its ONLY remaining transition is the stale sweep, which
-- marks it `failedPermanent` once it passes the age gate — and the age gate is `challenge_window + 1
-- day`, so a lost notice is not even marked failed until a DAY AFTER the release window it was meant
-- to protect has already elapsed.
--
-- The owner is never warned, and nothing anywhere says so.
--
-- ★ WHY THE FIX IS A COLUMN AND NOT A PREDICATE. The reclaim condition everyone reaches for is
-- "processing for too long". That sentence cannot be written against this table: there is no record
-- of WHEN a row was claimed. `requested_at` is when the notice was created (it does not move on
-- claim), and `attempts` is a counter with no clock. **You cannot time out a claim you never
-- timestamped.** That absence — not the `= 'queued'` predicate — is the root enabler, and it is what
-- this migration closes.
--
-- ★ WHAT THIS MIGRATION DELIBERATELY DOES NOT DO.
--
--   · It does NOT touch the release precondition. `authorize_release` accepts any owner-notice row
--     whose status is `<> 'cancelled'` — so `processing` and even `failedPermanent` satisfy the
--     "owner is independently reachable" guard today. That is OB-2, it is a product/safety decision
--     about when a release may proceed, and folding it into a recovery fix would be deciding it
--     silently. `db/tests/release_safety_authorization.sql` asserts the precondition is UNCHANGED by
--     this artifact, so OB-1 cannot drift into OB-2 unnoticed.
--
--   · It does NOT backfill `claimed_at` for existing rows, and it does NOT special-case the one
--     stranded row. A backfill would be a guess about when a claim happened, written into the column
--     whose whole purpose is to stop guessing. Legacy `processing` rows land with `claimed_at IS
--     NULL` and are handled by the reclaim contract as a class (see `claim_owner_notices`), never by
--     name.
--
-- Deploys via `db/bundles/owner_notice_claim_visibility_bundle.sql`. Source of truth — re-apply on
-- DB reset.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · THE CLAIM TIMESTAMP
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- Nullable, and permanently so. NULL means "claimed before this column existed" for the legacy rows
-- that exist at deployment, and "not currently claimed" for every row that has never been claimed.
-- Both are read through the same predicate; neither is inferred from `attempts`.
alter table public.owner_notice_outbox
  add column if not exists claimed_at timestamptz;

comment on column public.owner_notice_outbox.claimed_at is
  'When claim_owner_notices last moved this row into `processing` (Phase 11-OBR / OB-1). NULL means '
  'never claimed, or claimed before this column existed. It is the ONLY basis for deciding that a '
  'claim has gone stale — attempts is a counter with no clock, and requested_at does not move on '
  'claim. Never backfilled: a guessed claim time defeats the column.';

-- ★ THE PARTIAL INDEX MATCHES THE RECLAIM PREDICATE, INCLUDING ITS NULL BRANCH. The drain asks for
-- rows that are `processing` and stale; ordering is by `requested_at`, oldest first, exactly as the
-- queued branch orders. Partial so it stays small: `processing` is a transient state and in a
-- healthy system this index is nearly empty — which is itself the point.
create index if not exists owner_notice_outbox_processing_claimed_idx
  on public.owner_notice_outbox (requested_at)
  where status = 'processing';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 2 · OB-4 — THE AUDIT SOURCE THE WORKER HAS ALWAYS WRITTEN AND HAS NEVER BEEN ALLOWED TO
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THIS IS THE ROOT CAUSE OF OB-1, AND IT IS NOT A STRANDED-CLAIM PROBLEM AT ALL.
--
-- `record_owner_notice_outcome` closes by writing an audit row with `source = 'worker'` — a
-- deliberate 11-K choice, documented there: the actor is a scheduled worker, not a person, so
-- `actor_id` is NULL and the source says so rather than inventing a synthetic operator identity.
--
-- `audit_logs_source_check` has admitted `('server', 'ios_forward', 'admin')` since migration 0014
-- and was NEVER widened. So the final statement of `record_owner_notice_outcome` raises
-- `check_violation` on EVERY call. The routine cannot settle any notice, ever. `recordOutcome` in
-- `lib/ownerNotices/drain.ts` catches the RPC error, logs the code, and returns — so the row is left
-- exactly where the claim put it: `processing`, `attempts = 1`, `dispatched_at = null`.
--
-- That is the Branch A row, precisely. The claim was never the problem; the SETTLE was, and it has
-- been totally broken since 11-K wired the cron. The email itself is sent BEFORE the settle, so the
-- owner may well have received it — the system simply cannot record that it did.
--
-- ★ WHY THIS MUST SHIP WITH OB-1 RATHER THAN AFTER IT. A visibility timeout alone makes an
-- unsettleable row reclaimable, and a reclaimed row is sent again and still cannot be settled. The
-- result is a daily resend loop that runs until the age gate — turning one silent lost notice into
-- eight days of repeated mail to a living owner about their own death process. Fixing the reclaim
-- without fixing the settle is strictly worse than fixing neither.
--
-- ★ THE VALUE IS SERVER-STAMPED, NEVER A CLIENT PARAMETER — the same property that justified
-- admitting 'admin' in 0014. No client can reach this routine: EXECUTE is service_role only.
alter table public.audit_logs drop constraint if exists audit_logs_source_check;
alter table public.audit_logs add constraint audit_logs_source_check
  check (source in ('server', 'ios_forward', 'admin', 'worker'));

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 3 · PROVE THE SEAM TOOK, IN THE MIGRATION ITSELF (the 0051/0052/0054 discipline)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare
  v_type text;
  v_nullable text;
begin
  select data_type, is_nullable into v_type, v_nullable
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'owner_notice_outbox'
     and column_name = 'claimed_at';

  if v_type is null then
    raise exception '0057 FAILED: owner_notice_outbox.claimed_at was not added';
  end if;
  if v_type <> 'timestamp with time zone' then
    raise exception '0057 FAILED: claimed_at is %, expected timestamptz', v_type;
  end if;
  -- ★ NULLABLE IS LOAD-BEARING, NOT AN OVERSIGHT. A NOT NULL column would have required a backfill
  -- default, and every value it invented would be a fabricated claim time on a row whose real claim
  -- time is unknowable. The reclaim contract reads NULL as a first-class case.
  if v_nullable <> 'YES' then
    raise exception '0057 FAILED: claimed_at must remain nullable (it is %), or legacy rows carry a '
      'fabricated claim time', v_nullable;
  end if;

  if not exists (
    select 1 from pg_indexes
     where schemaname = 'public'
       and tablename = 'owner_notice_outbox'
       and indexname = 'owner_notice_outbox_processing_claimed_idx'
  ) then
    raise exception '0057 FAILED: the processing/claimed index is absent';
  end if;

  -- ★ AND THE RELEASE PRECONDITION IS UNTOUCHED BY THIS MIGRATION. Asserted here rather than
  -- promised in prose: OB-2 is a separate decision and this artifact must not have made it.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'authorize_release'
       and p.prosrc like '%o.status <> ''cancelled''%'
  ) then
    raise exception '0057 FAILED: authorize_release no longer carries the OB-2 precondition this '
      'migration is required to leave alone — OB-1 has silently implemented OB-2';
  end if;

  -- ★ OB-4: the settle path must actually be able to write its audit row. Asserted by EXECUTING an
  -- insert rather than by reading the constraint text — a constraint that merely mentions 'worker'
  -- is not proof that the value is storable, and this whole defect existed because nobody ever tried.
  begin
    insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
    values (null, null, 'aw.migration_0057_probe', 'audit_logs', null, '{}'::jsonb, 'worker');
    delete from public.audit_logs where action = 'aw.migration_0057_probe';
  exception when check_violation then
    raise exception '0057 FAILED: audit_logs still refuses source = ''worker'' — '
      'record_owner_notice_outcome cannot settle any notice and every claimed owner notice will '
      'strand in processing exactly as the Branch A row did';
  end;

  -- And the widening is EXACTLY one value: a source vocabulary that had quietly grown would be a
  -- different problem wearing this fix as cover.
  select pg_get_constraintdef(oid) into v_type
    from pg_constraint where conname = 'audit_logs_source_check';
  if (select count(*) from regexp_matches(v_type, '''[a-z_]+''', 'g')) <> 4 then
    raise exception '0057 FAILED: the audit source vocabulary is not exactly four values: %', v_type;
  end if;

  raise notice '0057 OK: claimed_at present and nullable, reclaim index present, OB-2 untouched, '
    'audit source admits worker (proved by execution)';
end $$;
