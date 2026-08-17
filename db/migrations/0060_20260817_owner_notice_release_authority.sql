-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-OC · PHASE D — THE RELEASE DOOR IS RE-ANCHORED ON PROVIDER ACCEPTANCE
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THIS IS THE ARTIFACT THAT CHANGES WHEN A RELEASE MAY PROCEED, AND IT IS THE ONLY ONE.
-- Migrations 0056, 0057, 0058 and 0059 each assert, about themselves, that they did NOT make this
-- change. This one makes it, and every one of those guards is amended in the same commit to ask a
-- better question — "is the door's posture consistent with the migrations actually applied" —
-- rather than to pin a literal that is now gone by design. See §5 for the full R13 disposition.
--
-- ★ WHAT THE DEFECT WAS, STATED SO THIS FILE IS SELF-EXPLAINING.
--
-- `authorize_release` gated on an owner-notice row for the ESTATE with `status <> 'cancelled'`.
-- Nothing in production ever writes `'cancelled'` — one test fixture does, by direct UPDATE — so the
-- predicate reduced to "a row exists", which is exactly what `dispatch_owner_safety_notice`
-- guaranteed by inserting it in the same transaction. The gate re-asserted its own precondition and
-- admitted `queued` (never sent), `processing` (never settled), `outcomeUncertain` (unknown) and
-- `failedPermanent` (definitively failed). Separately, the seven-day clock ran from
-- `owner_notified_at`, stamped when the row was QUEUED — so the window elapsed while the message sat
-- unsent, and kept elapsing after the provider rejected it outright.
--
-- ★ WHAT REPLACES IT — ONE FACT, FOUR AUTHORITIES, ZERO STATUS STRINGS.
--
--        THE CURRENT GENERATION OF THE CURRENT CASE EPISODE HAS `notice_accepted_at`,
--        AND now() > THAT INSTANT + challenge_window_duration(), STRICTLY.
--
--   EPISODE     the notice belongs to the CURRENT death-verification case (D3)
--   GENERATION  it is the row nothing supersedes — `superseded_by is null`, never a max() (D4)
--   ACCEPTANCE  `notice_accepted_at is not null` — no status participates (D1/D2)
--   CLOCK       strict `>` from the acceptance instant, never from provenance (D5)
--
-- ★ PROVIDER ACCEPTED IS NOT MAILBOX DELIVERED, AND NOTHING DOWNSTREAM MAY RENAME IT.
-- `notice_accepted_at` records that the email provider ACCEPTED the message for delivery. It is not
-- delivered, received, opened or read. Phase D protects on the strongest persisted provider fact
-- this system currently has; it does not claim delivery attestation, and no console label, audit
-- field or document may say otherwise.
--
-- ★ THE SEVEN-DAY POLICY IS UNCHANGED. `challenge_window_duration()` is not touched by this
-- migration, and must not be. Only the instant the seven days count FROM has moved.
--
-- ★ THIS MIGRATION CONTAINS NO DDL, AND THAT IS DELIBERATE RATHER THAN AN OMISSION. Phase A (0058)
-- added every column this phase needs and Phase C (0059) added the episode wall; Phase D changes
-- only FUNCTION BODIES, which live in `db/functions/` and are pasted by the bundle. So this file is
-- the ASSERTION and SUPERSESSION artifact: it proves the cutover took, proves it took completely
-- rather than halfway, proves the authority behaves correctly BY EXECUTION, and reports the
-- population it now refuses. A migration that only asserts is still a migration — it fails the
-- transaction when the claim is false, which is the entire job.
--
-- ★ APPLY ORDER IS INVERTED RELATIVE TO EVERY EARLIER PHASE, AND THE BUNDLE ENFORCES IT.
-- 0058 and 0059 are pasted BEFORE the function files they accompany, because they widen constraints
-- those functions then rely on. This one is pasted AFTER `release_safety.sql` and
-- `operator_console.sql`, because every assertion below inspects the bodies those files install. A
-- migration cannot assert a cutover that has not been pasted yet.
--
-- Deploys via `db/bundles/owner_notice_release_authority_bundle.sql`. Source of truth — re-apply on
-- reset. IDEMPOTENT: it contains no DDL, so re-applying it re-runs the proofs and nothing else.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · THE AUTHORITY EXISTS, WITH THE PROPERTIES ITS CALLERS DEPEND ON
-- ────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare
  v_def  text;
  v_prov boolean;
  v_vol  char;
begin
  if to_regprocedure('public.owner_notice_release_authority(uuid)') is null then
    raise exception '0060 FAILED: public.owner_notice_release_authority(uuid) is absent. The Phase D '
      'migration is being applied without the function it exists to certify — the bundle part order '
      'is wrong, or release_safety.sql was not pasted.';
  end if;

  select p.prosecdef, p.provolatile into v_prov, v_vol
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'owner_notice_release_authority';

  -- SECURITY DEFINER: it reads owner_notice_outbox and death_verification_cases, neither of which
  -- carries a client grant. An INVOKER function here would return nothing to its gated callers.
  if not v_prov then
    raise exception '0060 FAILED: owner_notice_release_authority is not SECURITY DEFINER';
  end if;
  -- STABLE, not VOLATILE: the door reads it under a row lock and relies on snapshot semantics; a
  -- VOLATILE body would also be free to write, which an authority must never be.
  if v_vol <> 's' then
    raise exception '0060 FAILED: owner_notice_release_authority must be STABLE (provolatile=%)', v_vol;
  end if;

  -- ★ INTERNAL. No client role may reach the authority directly. Its callers are gated; it is not.
  if has_function_privilege('anon', 'public.owner_notice_release_authority(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.owner_notice_release_authority(uuid)', 'execute')
  then
    raise exception '0060 FAILED: a client role can execute owner_notice_release_authority — the '
      'release authority is reachable without passing a gated door';
  end if;

  raise notice '0060 · owner_notice_release_authority present, SECURITY DEFINER, STABLE, INTERNAL';
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 2 · THE THREE CONSUMERS CARRY THE NEW CONTRACT, AND NONE CARRIES THE OLD ONE
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ TEXT IS NOT THE ONLY VOTER HERE — §4 proves the behaviour by execution. What text can prove,
-- and behaviour cannot easily, is that a SECOND policy has not been left behind beside the first.
-- These assertions exist to make a half-cutover impossible, not to stand in for runtime evidence.
do $$
declare
  v_def   text;
  v_probe text;
begin
  -- ════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ EVERY MATCH BELOW RUNS AGAINST prosrc WITH `--` COMMENTS STRIPPED, AND THAT IS LOAD-BEARING
  --   IN BOTH DIRECTIONS. IT WAS FOUND BY EXECUTION, NOT BY REVIEW.
  -- ════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- Postgres stores a plpgsql function's body VERBATIM, comments included. On the first replay of
  -- this migration the check below raised
  --
  --     0060 FAILED: begin_challenge_window requires notice_accepted_at
  --
  -- against a body that does not require it and never did. The routine's own comment explains that
  -- it deliberately does NOT gate on acceptance — and naming the term was enough to fail an absence
  -- test. The same trap fired on `authorize_release`, whose Phase D banner quotes the superseded
  -- predicate in order to say it is gone.
  --
  -- This is the exact failure the repository has shipped five times in the other direction: a
  -- documentation string counted as evidence. Here it counted as debt. Both are the same mistake.
  --
  -- ★ STRIPPING COMMENTS ALSO CLOSES THE ATTACK THE R13 DESIGN COULD ONLY FORBID. `docs/` records
  -- "plant the literal in a comment" as the worst available R13 fix, refused because prosrc includes
  -- comments and the guards would then match prose. After this, they cannot: a comment containing
  -- `status <> 'cancelled'` no longer satisfies anything. The rule moves from a promise to a wall.
  --
  -- ★ STRING LITERALS ARE DELIBERATELY **NOT** STRIPPED. The evidence class these matchers exist to
  -- find lives inside quoted SQL — `status <> 'cancelled'` IS a string literal in the predicate, and
  -- every refusal sentinel is a literal in a `raise`. Stripping them would erase exactly what is
  -- being looked for. Comments must go; strings must stay. The two views are different tools.
  --
  -- ★ AND THE PREPROCESSING CARRIES ITS OWN POSITIVE CONTROL. A stripper that removed everything
  -- would satisfy every absence assertion below and read as a clean cutover.
  v_probe := regexp_replace(
    'x := 1; -- status <> ''cancelled'' lives in this comment' || chr(10) ||
    'raise exception ''keep_me'';',
    E'--[^\n]*', '', 'g');
  if v_probe like '%status <> ''cancelled''%' then
    raise exception '0060 FAILED [preprocessing control]: the comment stripper left commented text '
      'behind, so every absence assertion below can be satisfied by prose';
  end if;
  if v_probe not like '%raise exception ''keep_me''%' then
    raise exception '0060 FAILED [preprocessing control]: the comment stripper removed a CODE string '
      'literal. It would erase the evidence class these matchers exist to find, and every absence '
      'assertion below would pass vacuously.';
  end if;

  -- ── 2.1 the release door ────────────────────────────────────────────────────────────────────
  select prosrc into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'authorize_release';
  if v_def is null then
    raise exception '0060 FAILED: authorize_release does not exist';
  end if;
  v_def := regexp_replace(v_def, E'--[^\n]*', '', 'g');
  -- Per-site non-vacuity: the stripped body must still be recognisable CODE. A body reduced to
  -- nothing would satisfy every `not like` below.
  if v_def not like '%raise exception%' or v_def not like '%public.apply_estate_lifecycle_transition%' then
    raise exception '0060 FAILED: the stripped authorize_release body contains no recognisable code '
      '— the preprocessing has eaten the routine and every assertion below is vacuous';
  end if;
  if v_def not like '%public.owner_notice_release_authority(%' then
    raise exception '0060 FAILED: authorize_release does not consume the release authority';
  end if;
  -- The superseded predicate must be GONE, not merely joined by a newer one.
  if v_def like '%status <> ''cancelled''%' then
    raise exception '0060 FAILED: authorize_release still carries the OB-1 predicate '
      '(status <> cancelled) beside the Phase D authority — a half-applied cutover leaves two '
      'owner-notice policies in one routine';
  end if;
  -- ★ THE CLOCK IS NO LONGER ANCHORED ON PROVENANCE. `owner_notified_at` may still be READ (it is
  -- kept as a required dispatch fact and recorded in the audit), but it must not appear in an
  -- interval comparison — that is the defective clock, and its absence is the cutover.
  if v_def ~ 'owner_notified_at\s*\+' then
    raise exception '0060 FAILED: authorize_release still computes a deadline from owner_notified_at '
      '— the release clock has not been re-anchored on the acceptance fact';
  end if;
  -- STRICT `>` survives the move. At the exact boundary the owner challenge wins (R14).
  if v_def like '%>=%' and v_def not like '%v_row.attempts >=%' then
    raise exception '0060 FAILED: authorize_release contains a non-strict comparison — the boundary '
      'instant must go to the owner challenge, never to release';
  end if;
  -- Two-person rule and audit reason are UNTOUCHED by Phase D. Phase D adds authority; it replaces
  -- no existing release guard.
  if v_def not like '%two_person_rule_violated%' or v_def not like '%audit_reason_required%'
     or v_def not like '%owner_not_notified%' or v_def not like '%no_verified_case%'
     or v_def not like '%invalid_release_state%' then
    raise exception '0060 FAILED: authorize_release lost a pre-Phase-D guard. Phase D ADDS owner '
      'notice authority; it replaces no existing release guard.';
  end if;

  -- ── 2.2 the window door — corrected, and deliberately NOT tightened to acceptance (D7) ──────
  select prosrc into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'begin_challenge_window';
  if v_def is null then
    raise exception '0060 FAILED: begin_challenge_window does not exist';
  end if;
  v_def := regexp_replace(v_def, E'--[^\n]*', '', 'g');
  if v_def not like '%raise exception%' then
    raise exception '0060 FAILED: the stripped begin_challenge_window body contains no code';
  end if;
  if v_def like '%status <> ''cancelled''%' then
    raise exception '0060 FAILED: begin_challenge_window still carries the inert OB-1 predicate';
  end if;
  if v_def not like '%o.case_id = v_case%' then
    raise exception '0060 FAILED: begin_challenge_window does not scope its notice check to the '
      'resolved case — an accepted notice from a PRIOR death process could open a new window';
  end if;
  -- ★ THE LOAD-BEARING ABSENCE. Opening the window releases nothing, and the initial notice is
  -- normally still `queued` at this instant. Requiring acceptance here would make the window
  -- unopenable until a worker had run, and would gate the OWNER'S OWN PROTECTION on an email
  -- provider — the exact inversion where the protective act becomes harder than the harmful one.
  if v_def like '%notice_accepted_at%' then
    raise exception '0060 FAILED: begin_challenge_window requires notice_accepted_at. Phase D '
      'tightens the IRREVERSIBLE door only; gating the owner-challenge window on a provider makes '
      'the protective act harder than the harmful one.';
  end if;

  -- ── 2.3 the operator projection — the SAME authority, no second opinion ─────────────────────
  select prosrc into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_get_death_verification_case';
  if v_def is null then
    raise exception '0060 FAILED: admin_get_death_verification_case does not exist';
  end if;
  v_def := regexp_replace(v_def, E'--[^\n]*', '', 'g');
  if v_def not like '%jsonb_build_object%' then
    raise exception '0060 FAILED: the stripped case-file body contains no code';
  end if;
  if v_def not like '%public.owner_notice_release_authority(%' then
    raise exception '0060 FAILED: the operator case file does not consume the release authority — '
      'the console would compute its own eligibility and could offer a release the door refuses';
  end if;
  if v_def ~ 'owner_notified_at\s*\+' then
    raise exception '0060 FAILED: the operator case file still computes a release deadline from '
      'owner_notified_at — the console and the door would disagree about the same estate';
  end if;

  -- ── 2.4 PHASE C IS STILL DEPLOYED AND STILL GATED — the remedy must outlive the cutover ─────
  --
  -- Phase D creates new legitimate refusal states that a running system reaches on its own. Without
  -- the re-notice remedy, the first post-cutover provider failure produces a permanently
  -- unreleasable estate whose only recovery is hand-written SQL against a safety table.
  if to_regprocedure('public.reissue_owner_safety_notice(uuid, text)') is null
     or to_regprocedure('public.owner_notice_reissue_assessment(uuid)') is null then
    raise exception '0060 FAILED: the Phase C re-notice remedy is not deployed. Phase D must not '
      'activate without it — the first provider failure after cutover would be unrecoverable.';
  end if;
  if has_function_privilege('anon', 'public.reissue_owner_safety_notice(uuid, text)', 'execute') then
    raise exception '0060 FAILED: anon can execute the re-notice door';
  end if;

  -- ── 2.5 THE ONE-PERSON LEVER IS STILL GONE, AND THE LOCKDOWN STILL HOLDS ────────────────────
  if to_regprocedure('public.release_estate(uuid)') is not null then
    raise exception '0060 FAILED: release_estate has been resurrected — a one-operator release lever '
      'beside a two-person door is the whole decision undone by an un-rewired caller';
  end if;
  if exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and table_name = 'estate_release_state'
       and grantee in ('anon', 'authenticated')
  ) then
    raise exception '0060 FAILED: estate_release_state carries a client grant — the lockdown has '
      'been reversed underneath the release cutover';
  end if;

  raise notice '0060 · door consumes the authority, old predicate absent, clock re-anchored, window '
    'door episode-scoped WITHOUT acceptance, projection shares the authority, Phase C remedy '
    'deployed and gated, release_estate absent, estate_release_state locked';
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 3 · THE TWO-PERSON WALL IS UNTOUCHED
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- Asserted separately, and on the CONSTRAINT rather than on the routine, because the routine is the
-- door and the constraint is the wall. Phase D rewrote the door; if it had disturbed the wall, a
-- single-reviewer release would become writable by a path that never reads `authorize_release`.
do $$
declare v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint where conname = 'release_authorizations_two_person_check';
  if v_def is null then
    -- Resolved from the catalog rather than guessed (the 0051 lesson): find ANY check on the table
    -- that mentions both reviewers, so a rename does not read as a deletion.
    select pg_get_constraintdef(con.oid) into v_def
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public' and rel.relname = 'release_authorizations'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) like '%reviewer_a%'
       and pg_get_constraintdef(con.oid) like '%reviewer_b%'
     limit 1;
  end if;
  if v_def is null then
    raise exception '0060 FAILED: release_authorizations carries no CHECK relating reviewer_a to '
      'reviewer_b — the two-person rule is now enforced only by a routine, and a routine can be '
      'bypassed by a direct RPC, a future admin tool, a script, or the next rewrite';
  end if;
  raise notice '0060 · the two-person CHECK constraint survives the cutover: %', v_def;
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 4 · THE AUTHORITY IS PROVEN BY EXECUTION — AND THE FIXTURE CANNOT SURVIVE THIS BLOCK
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ WHY A BEHAVIOURAL PROOF AND NOT ONLY A TEXT SEARCH. Every assertion above reads `prosrc`, and
-- `prosrc` includes comments. A body could name the authority in prose and consult nothing; a body
-- could consult the authority and misread its verdict. The rule this repository learned five times
-- over is that a scanner which inspects nothing is indistinguishable from a clean result — so the
-- load-bearing claims are executed here against constructed state, on the same database and in the
-- same transaction as the deployment.
--
-- ★ THE FIXTURE IS WRITTEN INSIDE A SUBTRANSACTION THAT ALWAYS ROLLS BACK, BY CONSTRUCTION.
-- This block is being pasted into PRODUCTION. It creates users, an estate, cases, a lifecycle row
-- and owner-notice rows — every one of them in safety tables — so "we remember to delete them" is
-- not good enough: a mid-block failure would strand synthetic rows in the tables an investigator
-- reads to reconstruct a real death process.
--
-- So the work happens in a plpgsql exception block (a real SAVEPOINT) which is ENDED by raising a
-- sentinel exception after the assertions have run. Postgres rolls the subtransaction back
-- unconditionally. plpgsql VARIABLES are memory rather than database state and survive the rollback,
-- so the verdicts are carried out and asserted afterwards. Nothing this block writes can commit,
-- on any path — success, assertion failure, or unexpected error.
--
-- ★ AND THE ESCAPE IS PROVED, NOT ASSUMED. §4.9 re-counts the affected tables after the rollback and
-- fails if a single synthetic row survived.
do $$
declare
  -- Verdicts captured OUTSIDE the rolled-back subtransaction.
  r_prior      text;   -- A · accepted notice on a PRIOR case
  r_superseded text;   -- B · accepted notice on a SUPERSEDED generation
  r_null       text;   -- C · current generation, current case, NULL acceptance
  r_boundary   text;   -- E · exact clock boundary
  r_after      boolean;-- F · one microsecond past the boundary
  r_ready_gen  int;
  r_eligible   timestamptz;
  r_accepted   timestamptz;
  r_notified   timestamptz;
  v_users_0    bigint; v_users_1 bigint;
  v_estates_0  bigint; v_estates_1 bigint;
  v_notices_0  bigint; v_notices_1 bigint;
  v_cases_0    bigint; v_cases_1 bigint;
  v_ran        boolean := false;
begin
  select count(*) into v_users_0   from auth.users;
  select count(*) into v_estates_0 from public.estates;
  select count(*) into v_notices_0 from public.owner_notice_outbox;
  select count(*) into v_cases_0   from public.death_verification_cases;

  begin
    declare
      v_owner uuid; v_actor uuid; v_estate uuid; v_desig uuid;
      v_case_prior uuid; v_case_cur uuid;
      v_gen1 uuid; v_gen2 uuid;
      v_dur interval := interval '7 days';
      v_acc timestamptz;
      v_j   jsonb;
    begin
      -- ── 4.1 the fixture: one estate, TWO episodes, and an interleaved accepted notice ────────
      --
      -- ★ IT IS BUILT TO DISAGREE WITH ITSELF, which is the whole point. An estate carrying exactly
      -- one case gives the same answer under episode scope and estate scope, so it could not
      -- distinguish a correct authority from one that forgot the episode key entirely.
      insert into auth.users default values returning id into v_owner;
      insert into auth.users default values returning id into v_actor;
      update auth.users set email = '0060-selfcheck-owner@invalid' where id = v_owner;

      insert into public.estates (owner_id, name) values (v_owner, '0060 selfcheck estate')
      returning id into v_estate;
      insert into public.estate_memberships (estate_id, user_id, role, status)
      values (v_estate, v_owner, 'primary_user', 'approved');
      insert into public.estate_designations (estate_id, user_id, designation_type, status)
      values (v_estate, v_actor, 'executor', 'active') returning id into v_desig;

      -- THE PRIOR EPISODE — verified, then REJECTED, exactly as a real superseded process ends.
      insert into public.death_verification_cases
        (estate_id, status, initiated_by, initiator_designation_id, initiator_capacity,
         required_level_at_initiation, attained_level, decided_by, decided_at)
      values (v_estate, 'rejected', v_actor, v_desig, 'executor', 'enhanced_kyc', 'enhanced_kyc',
              v_actor, now() - interval '90 days')
      returning id into v_case_prior;

      -- THE CURRENT EPISODE — verified, and the one the door must judge.
      insert into public.death_verification_cases
        (estate_id, status, initiated_by, initiator_designation_id, initiator_capacity,
         required_level_at_initiation, attained_level, decided_by, decided_at)
      values (v_estate, 'verified', v_actor, v_desig, 'executor', 'enhanced_kyc', 'enhanced_kyc',
              v_actor, now() - interval '30 days')
      returning id into v_case_cur;

      insert into public.estate_lifecycle (estate_id, state, owner_notified_at,
                                           safety_notification_id, challenge_window_started_at)
      values (v_estate, 'challenge_window', now() - interval '60 days', gen_random_uuid(),
              now() - interval '60 days')
      on conflict (estate_id) do update
        set state = 'challenge_window',
            owner_notified_at = now() - interval '60 days',
            safety_notification_id = gen_random_uuid();

      -- ★ THE PROVENANCE IS DELIBERATELY ANCIENT — 60 days, far beyond any seven-day window. Under
      -- the PRE-Phase-D clock this estate would release immediately. Every refusal below is
      -- therefore a real observation of the new anchor rather than an artefact of a fresh fixture:
      -- a body that still read `owner_notified_at` would ADMIT here, loudly.
      r_notified := now() - interval '60 days';

      -- The PRIOR episode's notice, ACCEPTED. This is the row that must authorize nothing.
      insert into public.owner_notice_outbox
        (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
         dispatched_at, notice_accepted_at)
      values (v_estate, v_owner, 'email', '0060-selfcheck-prior@invalid',
              'death_process.window_opened', 'dispatched', v_case_prior, 1,
              now() - interval '89 days', now() - interval '89 days');

      -- The CURRENT episode, generation 1: dispatched with NO acceptance fact — the legacy class.
      insert into public.owner_notice_outbox
        (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
         dispatched_at, notice_accepted_at)
      values (v_estate, v_owner, 'email', '0060-selfcheck-gen1@invalid',
              'death_process.window_opened', 'dispatched', v_case_cur, 1,
              now() - interval '59 days', null)
      returning id into v_gen1;

      -- ── 4.2 · A — AN ACCEPTED NOTICE ON A PRIOR CASE CARRIES NO AUTHORITY (D3) ───────────────
      v_j := public.owner_notice_release_authority(v_case_prior);
      r_prior := v_j ->> 'refusal_code';

      -- ── 4.3 · C — CURRENT CASE, CURRENT GENERATION, NULL ACCEPTANCE (D6) ─────────────────────
      v_j := public.owner_notice_release_authority(v_case_cur);
      r_null := v_j ->> 'refusal_code';

      -- ── 4.4 · B — AN ACCEPTED **SUPERSEDED** GENERATION CARRIES NO AUTHORITY (D4) ────────────
      --
      -- ★ THIS STATE IS UNREACHABLE THROUGH THE DEPLOYED DOORS, AND IT IS WRITTEN BY HAND HERE FOR
      -- EXACTLY THAT REASON. `record_owner_notice_outcome` no-ops on any settled row, and
      -- `owner_notice_reissue_assessment` refuses to supersede a `queued` or `processing` row — so a
      -- superseded row can never GAIN an acceptance stamp. Depending on that argument would make the
      -- door's correctness rest on two other routines never changing. It is asserted directly
      -- instead: even handed a superseded acceptance, the authority must refuse.
      v_gen2 := gen_random_uuid();
      update public.owner_notice_outbox set superseded_by = v_gen2 where id = v_gen1;
      -- Retro-stamp the now-RETIRED generation 1 with a real acceptance, old enough that the clock
      -- would long since have elapsed if it counted.
      update public.owner_notice_outbox
         set notice_accepted_at = now() - interval '59 days' where id = v_gen1;
      insert into public.owner_notice_outbox
        (id, estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation,
         reissue_reason, notice_accepted_at)
      values (v_gen2, v_estate, v_owner, 'email', '0060-selfcheck-gen2@invalid',
              'death_process.window_renotice', 'queued', v_case_cur, 2,
              'legacy_no_acceptance_record', null);

      v_j := public.owner_notice_release_authority(v_case_cur);
      r_superseded := v_j ->> 'refusal_code';

      -- ── 4.5 · E/F — THE CLOCK, AT THE BOUNDARY AND ONE MICROSECOND PAST IT (D5) ──────────────
      --
      -- ★ `now()` IS CONSTANT INSIDE A TRANSACTION, so the boundary is reachable EXACTLY by setting
      -- the acceptance instant to `now() - duration`. No sleep, no wall clock, no flake: this is the
      -- deterministic equivalent of waiting seven days, and it is the only way to observe the tie.
      if not exists (select 1 from public.release_safety_policy) then
        insert into public.release_safety_policy (id, challenge_window) values (true, v_dur);
      else
        select p.challenge_window into v_dur from public.release_safety_policy p where p.id;
      end if;

      v_acc := now() - v_dur;                      -- EXACTLY the boundary instant
      update public.owner_notice_outbox
         set status = 'dispatched', notice_accepted_at = v_acc, dispatched_at = v_acc
       where id = v_gen2;
      v_j := public.owner_notice_release_authority(v_case_cur);
      r_boundary  := v_j ->> 'refusal_code';
      r_eligible  := (v_j ->> 'release_eligible_at')::timestamptz;
      r_accepted  := (v_j ->> 'notice_accepted_at')::timestamptz;

      -- One microsecond earlier — the smallest step Postgres timestamps resolve — is STRICTLY past.
      update public.owner_notice_outbox
         set notice_accepted_at = v_acc - interval '1 microsecond' where id = v_gen2;
      v_j := public.owner_notice_release_authority(v_case_cur);
      r_after     := (v_j ->> 'ready')::boolean;
      r_ready_gen := (v_j ->> 'generation')::int;

      v_ran := true;

      -- ★ THE ESCAPE. Every row above is rolled back by this raise, unconditionally, on every path.
      raise exception 'aw_0060_selfcheck_rollback';
    end;
  exception
    when others then
      if sqlerrm <> 'aw_0060_selfcheck_rollback' then
        raise exception '0060 FAILED: the behavioural self-check could not run: % (%)',
          sqlerrm, sqlstate;
      end if;
  end;

  if not v_ran then
    raise exception '0060 FAILED: the behavioural self-check did not complete — it must not be '
      'possible to reach this line with the proofs unrun, or the migration reports a cutover it '
      'never observed';
  end if;

  -- ── 4.6 THE VERDICTS ────────────────────────────────────────────────────────────────────────
  if r_prior is distinct from 'notice_episode_mismatch' then
    raise exception '0060 FAILED [A]: an ACCEPTED notice on a PRIOR, REJECTED case produced "%" '
      'instead of notice_episode_mismatch. An accepted notice from a death process that was rejected '
      'would authorize a release under a later case whose own notice never went out.',
      coalesce(r_prior, 'AUTHORITY GRANTED');
  end if;

  if r_null is distinct from 'notice_never_accepted' then
    raise exception '0060 FAILED [C]: the current generation of the current case with NULL '
      'acceptance produced "%" instead of notice_never_accepted. Note the fixture stamped '
      'owner_notified_at SIXTY DAYS ago: a door still reading provenance admits here.',
      coalesce(r_null, 'AUTHORITY GRANTED');
  end if;

  if r_superseded is distinct from 'notice_never_accepted' then
    raise exception '0060 FAILED [B]: a SUPERSEDED generation carrying a real notice_accepted_at '
      'produced "%" instead of notice_never_accepted. A retired generation must authorize nothing — '
      'the current generation is the only row an operator can act on.',
      coalesce(r_superseded, 'AUTHORITY GRANTED');
  end if;

  -- ★ THE TIE GOES TO THE OWNER (R14/D5). At the EXACT boundary instant the door refuses.
  if r_boundary is distinct from 'release_window_not_elapsed' then
    raise exception '0060 FAILED [E]: at the exact boundary instant the authority produced "%" '
      'instead of release_window_not_elapsed. `>` has become `>=` and the tie now goes to release '
      'instead of to the owner challenge.', coalesce(r_boundary, 'AUTHORITY GRANTED');
  end if;

  -- POSITIVE CONTROL. Without it, an authority wired to refuse EVERYTHING would satisfy every
  -- assertion above and read as admirably conservative.
  if not coalesce(r_after, false) then
    raise exception '0060 FAILED [F, POSITIVE CONTROL]: one microsecond PAST the boundary the '
      'authority still refuses. It is refusing everything, so assertions A, B, C and E proved '
      'nothing at all.';
  end if;

  -- The authority admitted on the CURRENT generation, not the retired one.
  if r_ready_gen is distinct from 2 then
    raise exception '0060 FAILED [F]: the admitting verdict names generation % — it must be the '
      'CURRENT generation (2), not a retired one', r_ready_gen;
  end if;

  -- ★ THE ANCHOR IS THE ACCEPTANCE FACT, PROVED ARITHMETICALLY RATHER THAN BY READING THE SOURCE.
  -- The eligibility instant must be the ACCEPTANCE instant plus the duration, and must NOT be the
  -- provenance instant plus the duration. The fixture separates the two by ~53 days, so no
  -- coincidence can satisfy both.
  if r_eligible is distinct from r_accepted + (select p.challenge_window
                                                 from public.release_safety_policy p where p.id) then
    raise exception '0060 FAILED [D5]: release_eligible_at (%) is not notice_accepted_at (%) plus '
      'the configured window — the authority is anchored on something else', r_eligible, r_accepted;
  end if;
  if r_eligible = r_notified + (select p.challenge_window
                                  from public.release_safety_policy p where p.id) then
    raise exception '0060 FAILED [D5]: release_eligible_at equals owner_notified_at + window — the '
      'clock is still anchored on PROVENANCE, which is stamped when the row is queued';
  end if;

  -- ── 4.9 THE ESCAPE IS PROVED, NOT ASSUMED ───────────────────────────────────────────────────
  select count(*) into v_users_1   from auth.users;
  select count(*) into v_estates_1 from public.estates;
  select count(*) into v_notices_1 from public.owner_notice_outbox;
  select count(*) into v_cases_1   from public.death_verification_cases;
  if v_users_1 <> v_users_0 or v_estates_1 <> v_estates_0
     or v_notices_1 <> v_notices_0 or v_cases_1 <> v_cases_0 then
    raise exception '0060 FAILED: the self-check fixture SURVIVED its subtransaction — users %→%, '
      'estates %→%, owner notices %→%, cases %→%. Synthetic rows are stranded in the tables an '
      'investigator reads to reconstruct a real death process.',
      v_users_0, v_users_1, v_estates_0, v_estates_1, v_notices_0, v_notices_1, v_cases_0, v_cases_1;
  end if;
  if exists (select 1 from public.owner_notice_outbox where recipient like '0060-selfcheck-%') then
    raise exception '0060 FAILED: a 0060 self-check owner-notice row is present after rollback';
  end if;

  raise notice '0060 OK (behavioural): prior-case acceptance REFUSED (notice_episode_mismatch); '
    'superseded acceptance REFUSED (notice_never_accepted); NULL acceptance REFUSED despite '
    'owner_notified_at 60 days old; exact boundary REFUSED; one microsecond past ADMITTED on the '
    'CURRENT generation (positive control); release_eligible_at = notice_accepted_at + window and '
    'NOT owner_notified_at + window; fixture provably rolled back.';
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 5 · R13 — THE HISTORICAL PINS, AND HOW EACH WAS RESOLVED
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- Migrations 0056, 0057, 0058 and 0059 each pinned `authorize_release` (and 0056 also
-- `begin_challenge_window`) to text this migration deliberately removes. All FIVE in-migration
-- guards were AMENDED IN THE ASSERTION LAYER ONLY — zero DDL changed in any of them — into
-- supersession-aware forms that remain load-bearing after the cutover:
--
--   0056:begin_challenge_window   OB-1 predicate  OR  OB-2 episode scope       · never neither/both
--   0056:authorize_release        OB-1 predicate  OR  OB-2 acceptance authority · never neither/both
--   0057:authorize_release        OB-1 predicate  OR  OB-2 acceptance authority · never neither/both
--   0058:authorize_release        posture must MATCH whether 0060 is applied (catalog-decided)
--   0059:authorize_release        posture must MATCH whether 0060 is applied (catalog-decided)
--
-- Every one of them is strictly STRONGER than what it replaced: the originals could be satisfied
-- only by the old literal and could not fail on the absence of both predicates; the amendments
-- cannot be satisfied by absence, and cannot be satisfied by a comment either, because each OB-2
-- branch requires `to_regprocedure('public.owner_notice_release_authority(uuid)')` — a catalog fact
-- that no prose can supply.
--
-- ★ THIS BLOCK RE-PROVES THE AMENDMENT FROM THE OTHER SIDE. The guards above run when their own
-- migrations are pasted. This one runs when PHASE D is pasted, and asserts the thing an operator
-- actually needs to know at that moment: that no live guard anywhere in the catalog still demands
-- the superseded literal. Without it, a migration amended in source but pasted from a stale bundle
-- would be discovered only by a replay failure days later.
do $$
declare
  v_n bigint;
begin
  -- Any FUNCTION body still demanding the old literal as a precondition would now be unsatisfiable.
  -- Scoped to the two doors by name: other bodies (the reissue assessment, the censuses) mention
  -- statuses legitimately and are not release preconditions.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('authorize_release', 'begin_challenge_window')
     and p.prosrc like '%status <> ''cancelled''%';
  if v_n <> 0 then
    raise exception '0060 FAILED: % release-path routine(s) still carry the superseded OB-1 '
      'predicate. The cutover is half-applied.', v_n;
  end if;

  raise notice '0060 · R13 RESOLVED: five historical self-checks superseded in the assertion layer '
    'only (0056 x2, 0057, 0058, 0059), each now a disjunction that cannot pass on absence and '
    'cannot be satisfied by a comment; no release-path routine still demands the OB-1 literal.';
end $$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 6 · THE CUTOVER CENSUS — counts only, no ids, no addresses, no estate names
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ A MIGRATION THAT CHANGES THE RELEASE DOOR WITHOUT STATING HOW MANY LIVE ESTATES IT BLOCKS IS A
-- SILENT OPERATIONAL CHANGE. Printed AFTER the cutover has been asserted, so the numbers describe
-- the door that is now deployed. A NOTICE rather than an assertion: a non-zero refused population is
-- not an error, it is the operator's Phase C queue.
do $$
declare
  v_door bigint; v_admit bigint; v_refuse bigint;
  v_legacy bigint; v_renotices bigint;
begin
  select count(*) into v_door from public.estate_lifecycle where state = 'challenge_window';

  select
    count(*) filter (where (public.owner_notice_release_authority(cc.case_id) ->> 'accepted')::boolean),
    count(*) filter (where not coalesce(
      (public.owner_notice_release_authority(cc.case_id) ->> 'accepted')::boolean, false))
    into v_admit, v_refuse
    from (
      select (select c.id from public.death_verification_cases c
               where c.estate_id = l.estate_id and c.status = 'verified'
               order by c.decided_at desc limit 1) as case_id
        from public.estate_lifecycle l
       where l.state = 'challenge_window'
    ) cc;

  select count(*) filter (where o.status = 'dispatched' and o.notice_accepted_at is null),
         count(*) filter (where o.notice_kind = 'death_process.window_renotice')
    into v_legacy, v_renotices
    from public.owner_notice_outbox o
   where o.superseded_by is null and o.channel = 'email';

  raise notice '0060 CUTOVER CENSUS · estates at the release door=% · with a provable acceptance '
    'fact (releasable subject to the clock and the two-person rule)=% · REFUSED by Phase D=% · '
    'current generations still dispatched-with-no-acceptance-fact=% · re-notices issued to date=%',
    v_door, v_admit, v_refuse, v_legacy, v_renotices;

  if v_refuse > 0 then
    raise notice '0060 GATE · % estate(s) at the door now refuse with notice_never_accepted. This '
      'is the Phase C queue: an operator re-notice PRODUCES the missing fact. No manual SQL repair '
      'of a safety table is required, or permitted.', v_refuse;
  end if;
  raise notice '0060 NOTE · notice_accepted_at is PROVIDER ACCEPTANCE. It is not delivery, not '
    'receipt, and not proof that a living owner read anything. Phase D protects on the strongest '
    'persisted provider fact available; it claims no delivery attestation.';
end $$;
