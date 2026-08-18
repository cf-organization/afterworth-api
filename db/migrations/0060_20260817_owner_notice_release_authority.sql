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
-- 4 · THE AUTHORITY IS PROVEN BY EXECUTION — READ-ONLY, AGAINST WHATEVER THIS DATABASE HOLDS
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ WHY BEHAVIOURAL AT ALL. Every assertion in §2 reads `prosrc`, and `prosrc` includes comments. A
-- body could name the authority in prose and consult nothing; a body could consult it and misread
-- the verdict. So the load-bearing claims are EXECUTED on the same database and in the same
-- transaction as the deployment.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ THIS BLOCK WROTE A SYNTHETIC FIXTURE ONCE, AND IT FAILED THE FIRST PRODUCTION PASTE.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- The original §4 created two `auth.users`, an estate, two cases, a lifecycle row and three owner
-- notices inside a subtransaction that always rolled back. It passed every local replay and aborted
-- production immediately:
--
--     0060 FAILED: the behavioural self-check could not run:
--     null value in column "id" of relation "users" violates not-null constraint (23502)
--
-- `insert into auth.users default values` works ONLY against the test harness, whose
-- `preamble_real_auth.sql` defines a simplified `auth.users` with `id uuid default gen_random_uuid()`.
-- Real Supabase has NO default there — GoTrue supplies the id. The self-check had therefore only
-- ever been exercised against a FAKE boundary, which is this repository's own recorded failure class:
-- a default that is never executed by any test, and a runtime that the local harness does not model.
--
-- ★ AND THE FAIL-CLOSED DESIGN HELD, which is the one good thing to record about it. The artifact is
-- a single transaction, so the abort deployed nothing, applied no half-cutover, and left no
-- synthetic row anywhere. A migration that had "helpfully" continued past a failed self-check would
-- have shipped an uncertified cutover instead.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ THE REPLACEMENT WRITES NOTHING, AND IS STRONGER EVIDENCE RATHER THAN WEAKER.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- A production migration has no business creating estates, cases or owner notices in safety tables —
-- not even transiently, and not even attached to a real person's account, which is what reusing an
-- existing `auth.users` row would have required. So this block now proves the authority by RUNNING
-- it, with zero writes, in two ways:
--
--   · FAIL-CLOSED PROBES on inputs that need no fixture at all (§4.1);
--   · THE INVARIANTS, EVALUATED OVER EVERY CASE THIS DATABASE ACTUALLY HOLDS (§4.2-§4.4) — real
--     production rows, which no synthetic fixture can imitate.
--
-- ★ THE EXHAUSTIVE A-J MATRIX LIVES WHERE IT CAN BE BUILT SAFELY, AND THAT IS NOT HERE.
-- `db/tests/release_safety_authorization.sql` §12.1-§12.11 constructs interleaved episodes,
-- superseded generations carrying acceptance, prior rejected cases, exact clock boundaries and the
-- two-person matrix — against an ephemeral Postgres where fabricating an `auth.users` row is
-- legitimate. It runs on every replay and gates every PR. Build type follows evidence type: paste
-- time gets the evidence a paste can safely produce, and the suite gets the rest.
do $$
declare
  v_probe    jsonb;
  v_cases    bigint;
  v_bad      bigint;
  v_dur      interval;
begin
  -- ── 4.1 THE AUTHORITY EXECUTES, AND FAILS CLOSED ON INPUTS THAT NEED NO FIXTURE ─────────────
  --
  -- ★ THIS IS A REAL CALL, NOT A CATALOG LOOKUP. If the body were syntactically present but broken —
  -- a bad column reference, a missing helper, a wrong signature on `owner_notice_episode_kinds()` —
  -- it would raise here rather than pass a text match.
  v_probe := public.owner_notice_release_authority(null);
  if coalesce((v_probe ->> 'ready')::boolean, true) then
    raise exception '0060 FAILED [4.1]: the authority returned ready for a NULL case (%)', v_probe;
  end if;
  if v_probe ->> 'refusal_code' is distinct from 'case_not_found' then
    raise exception '0060 FAILED [4.1]: a NULL case produced refusal_code %, expected case_not_found',
      v_probe ->> 'refusal_code';
  end if;

  -- An id that certainly names no case. Fail closed, by name, rather than by crashing.
  v_probe := public.owner_notice_release_authority('00000000-0000-4000-8000-000000000000'::uuid);
  if coalesce((v_probe ->> 'ready')::boolean, true) then
    raise exception '0060 FAILED [4.1]: the authority returned ready for an unknown case (%)', v_probe;
  end if;
  if v_probe ->> 'refusal_code' is distinct from 'case_not_found' then
    raise exception '0060 FAILED [4.1]: an unknown case produced refusal_code %, expected '
      'case_not_found', v_probe ->> 'refusal_code';
  end if;
  raise notice '0060 · 4.1 the authority EXECUTES and fails closed on null and unknown cases';

  -- ── 4.2 NO CASE IS READY WITHOUT AN ACCEPTANCE FACT — over every real case ──────────────────
  --
  -- ★ THE CENTRAL PHASE D CLAIM, EVALUATED AGAINST PRODUCTION DATA RATHER THAN A FIXTURE. If any
  -- case in this database reports `ready` while `accepted` is false, the acceptance authority is not
  -- what is deciding releases and the cutover must not commit.
  select count(*) into v_cases from public.death_verification_cases;
  select count(*) into v_bad
    from public.death_verification_cases c
   where (public.owner_notice_release_authority(c.id) ->> 'ready')::boolean
     and not coalesce((public.owner_notice_release_authority(c.id) ->> 'accepted')::boolean, false);
  if v_bad > 0 then
    raise exception '0060 FAILED [4.2]: % case(s) report READY with no acceptance fact — the '
      'authority is not gating on notice_accepted_at', v_bad;
  end if;

  -- ── 4.3 THE ANCHOR IS THE ACCEPTANCE FACT, ARITHMETICALLY — over every real case ────────────
  --
  -- `release_eligible_at` must be NULL exactly when there is no acceptance fact, and must equal
  -- acceptance + the configured window whenever there is one. A body still anchored on
  -- `owner_notified_at` produces a NON-NULL date on every dispatched case with no acceptance, which
  -- is precisely the production population this deployment refuses.
  v_dur := public.challenge_window_duration();
  select count(*) into v_bad
    from public.death_verification_cases c
    cross join lateral (select public.owner_notice_release_authority(c.id) as a) x
   where (x.a ->> 'notice_accepted_at') is null
     and (x.a -> 'release_eligible_at') is not null
     and (x.a -> 'release_eligible_at') <> 'null'::jsonb;
  if v_bad > 0 then
    raise exception '0060 FAILED [4.3]: % case(s) carry a release_eligible_at with NO acceptance '
      'fact — the clock is still anchored on provenance', v_bad;
  end if;

  if v_dur is not null then
    select count(*) into v_bad
      from public.death_verification_cases c
      cross join lateral (select public.owner_notice_release_authority(c.id) as a) x
     where (x.a ->> 'notice_accepted_at') is not null
       and (x.a ->> 'release_eligible_at')::timestamptz
           is distinct from (x.a ->> 'notice_accepted_at')::timestamptz + v_dur;
    if v_bad > 0 then
      raise exception '0060 FAILED [4.3]: % case(s) have release_eligible_at <> notice_accepted_at '
        '+ challenge_window_duration()', v_bad;
    end if;
  end if;

  -- ── 4.4 NON-VACUITY, REPORTED HONESTLY RATHER THAN ASSERTED ─────────────────────────────────
  --
  -- ★ A GREEN CHECK OVER ZERO ROWS IS NOT A PASS, AND THIS SAYS SO OUT LOUD. On a database with no
  -- death-verification cases §4.2 and §4.3 are vacuous — true, and evidence of nothing. That is
  -- REPORTED rather than silently counted as a pass, and it is not raised as an error either: an
  -- empty database is a legitimate state, and the exhaustive proof lives in the suite regardless.
  if v_cases = 0 then
    raise notice '0060 · 4.2-4.3 SKIPPED-VACUOUS: this database holds no death-verification cases, '
      'so the over-all-cases invariants asserted nothing. The exhaustive A-J proof is in '
      'db/tests/release_safety_authorization.sql §12, run on every replay.';
  else
    raise notice '0060 · 4.2-4.3 evaluated over % real case(s): none reports READY without an '
      'acceptance fact; release_eligible_at is NULL exactly where acceptance is NULL and equals '
      'acceptance + the configured window everywhere else', v_cases;
  end if;

  raise notice '0060 OK (behavioural, READ-ONLY): the authority executes, fails closed on null and '
    'unknown cases, and holds its acceptance and anchor invariants over every case this database '
    'contains. This block writes NOTHING — no auth.users, no estate, no case, no owner notice.';
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
