-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- THE CANONICAL RELEASE-CONDITION AUTHORITY  ·  Phase 11-B, lifecycle-aware since Phase 11-D
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHY THIS FILE EXISTS. Before Phase 11-B the rule "is this grant's release condition satisfied?"
-- was written out SEVEN times in FIVE routines, and the seven copies gave TWO different answers:
--
--     can_access_document          immediately + the two approval conditions once approved
--     inventory_disclosure_tier    same
--     notification_grant_is_live   same
--     asset_grant_tier             immediately ONLY
--     list_estate_assets           immediately ONLY
--     get_estate_net_worth  (×2)   immediately ONLY
--
-- Phase 11 connects a verified death to disclosure. The single most likely way to get that wrong is
-- not a missing check — it is activating a condition at four sites and forgetting the other three,
-- which is precisely the shape of the four role maps that drifted apart in Phase 9. So the predicate
-- moved HERE first (11-B), before any death wiring existed, and every consumer became a caller.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ WHAT THIS MODULE DECIDES, AND WHAT IT DELIBERATELY DOES NOT
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- It answers ONE question: given a release condition, the approval fact recorded beside it, and the
-- estate's authoritative lifecycle state, is that condition presently SATISFIED?
--
-- It does NOT decide who may receive a grant, compute a disclosure tier, manufacture a grant, verify
-- a death, approve a claim, or transition any lifecycle state. Callers keep every one of those. A
-- grant whose condition is satisfied still discloses nothing unless the SAME checks that have always
-- guarded it also pass: active status, the viewer's own grant row, the read-time ceiling clamp, the
-- hidden-tier refusal. Satisfaction is one conjunct, never a bypass.
--
-- ★ IT TAKES LIFECYCLE STATE AS AN ARGUMENT, AND READS NOTHING — THAT IS THE 11-D DESIGN.
--
-- 11-B deliberately gave this function no lifecycle argument, so that "no authorization path
-- consults the release seam" stayed structurally true while there was no verified event to consult.
-- 11-D is the phase that spends that guarantee, deliberately, in ONE file: the signature widens to
--
--     release_condition_satisfied(condition, approved_at, policy, lifecycle_state)
--
-- and every consumer resolves the lifecycle through `public.estate_lifecycle_state(estate)` — the
-- authoritative reader over `estate_lifecycle`, the record whose ONLY writer is the audited
-- transition routine. The predicate itself stays a PURE function of its arguments (immutable, no
-- table reads), for three reasons:
--
--   · a pure predicate can be truth-tabled exhaustively against a written specification, which is
--     how the SQL suite proves it (every condition × approval × policy × lifecycle, enumerated);
--   · a predicate that resolved estate → lifecycle itself would be a client-reachable death-status
--     oracle for arbitrary estate ids (it is EXECUTEable by `authenticated`; the reader is not);
--   · the lifecycle READ stays in SECURITY DEFINER consumers beside the grant lookup it scopes, so
--     the estate whose lifecycle is consulted is by construction the estate whose grant is evaluated.
--
-- What no consumer may do is compare the lifecycle locally ("if death_verified then …") — that is
-- release policy leaking back out of the centre, and `test/deathVerificationFoundation.test.ts`
-- pins that the reader appears outside the death module ONLY as this function's fourth argument.
--
-- ★ NOT `claim_packets.status`. NOT evidence rows. NOT attained verification levels. NOT the
-- label-only `estate_release_state()` claim projection. The lifecycle record is the one fact that
-- can satisfy a death condition, and it moves only through `apply_estate_lifecycle_transition`,
-- behind an admin decision that re-derives the required verification level LIVE (H2).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ TWO POLICIES, STILL — 11-D activates death under `standard` and PRESERVES the legacy clamp
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- `standard` (documents, the estate-documents category, estate inventory, notification speech):
-- gains the death arm. `after_verified_death` is satisfied exactly while the lifecycle is
-- `death_verified`.
--
-- `legacy_immediate_only` (account balances, institution names, total asset value, linked account
-- details): carried forward EXACTLY as written — `immediately` alone, lifecycle-indifferent. A
-- death-conditioned grant on an asset-value surface therefore stays dormant even at death_verified.
-- That asymmetry is deliberate and is pinned by test in both directions: unifying the policies
-- changes what a survivor sees on the asset surfaces, which is a product decision with its own row
-- inventory and migration price (R12), not a tidy-up. The divergence remains one `case` arm in one
-- file instead of seven scattered literals.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ FAIL-CLOSED IN EVERY ARGUMENT
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- An unknown condition is false. An unknown policy is false. An unknown or NULL lifecycle state is
-- false — for EVERY condition, including `immediately`: the authoritative reader can only produce
-- the three CHECK-constrained states, so an out-of-vocabulary lifecycle here means a consumer wired
-- something that is not the seam, and the answer to a miswired consumer is refusal, not tolerance.
-- NULL condition and NULL policy are false. There is no permissive default and no `else true`
-- anywhere below.
--
-- The `coalesce` is load-bearing rather than defensive tidiness: `null = 'immediately'` is NULL, not
-- false, and a boolean gate that returns NULL is not refused by `if not (…) then` — that branch
-- simply does not execute, and the caller carries on as though the check had passed. A three-valued
-- answer from a two-valued gate is how a fail-closed predicate fails open.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- release_condition_satisfied(condition, approved_at, policy, lifecycle_state) — THE AUTHORITY
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- `p_policy` has NO DEFAULT, on purpose. A default would let a new consumer inherit the wider rule by
-- saying nothing, which is the exact failure mode — silent policy by omission — that the seven
-- scattered copies represented. `p_lifecycle_state` has no default for the same reason: a consumer
-- that says nothing about the lifecycle must not silently evaluate "as if active"; it must not
-- compile. (The 3-argument spelling is DROPPED by migration 0053, so an un-rewired caller fails
-- loudly at first call rather than binding to a lifecycle-blind overload.)
create or replace function public.release_condition_satisfied(
  p_release_condition text,
  p_approved_at       timestamptz,
  p_policy            text,
  p_lifecycle_state   text
)
 returns boolean
 language sql
 immutable
 set search_path to 'public'
as $function$
  select coalesce(
    -- ★ THE LIFECYCLE VALIDITY GATE COMES FIRST and refuses EVERYTHING on an out-of-vocabulary
    -- state. The set is the 0052 CHECK's, spelled here because a pure function cannot read the
    -- catalog; `db/tests/release_condition_authorization.sql` enumerates the CHECK at run time and
    -- fails if the two vocabularies ever drift.
    p_lifecycle_state in ('active', 'death_verification_pending', 'death_verified')
    and case p_policy
      -- Documents, the estate-documents category, estate inventory, and notification speech.
      -- `after_owner_approval` (owner-initiated) and `after_access_request_approval`
      -- (beneficiary-initiated) are the SAME gate — both mean "the owner approved this access",
      -- differing only by who asked.
      when 'standard' then
        p_release_condition = 'immediately'
        or (p_release_condition in ('after_owner_approval', 'after_access_request_approval')
            and p_approved_at is not null)
        -- ★ PHASE 11-D — THE DEATH ARM. Satisfied exactly while the authoritative lifecycle is
        -- death_verified; pending verification satisfies nothing, and the conjunction is the
        -- firewall: claim approval, evidence, and attained levels never appear here because they
        -- cannot move the lifecycle. Incapacity and the legacy fused value stay out of this arm
        -- entirely — dormant under every policy, every lifecycle (R6/R7).
        or (p_release_condition = 'after_verified_death'
            and p_lifecycle_state = 'death_verified')

      -- The asset-value surfaces (account balances, institution names, total asset value, linked
      -- account details). Carried forward EXACTLY as written in 11-B, including their narrowness
      -- and their lifecycle-indifference: `immediately` alone, at every lifecycle state. This is a
      -- compatibility clamp with a standing ledger entry (R12), not a rule anyone designed — and
      -- 11-D deliberately does NOT spend that product decision.
      when 'legacy_immediate_only' then
        p_release_condition = 'immediately'

      -- Unknown policy -> refused. No `else true`, ever.
      else false
    end,
    false);
$function$;

comment on function public.release_condition_satisfied(text, timestamptz, text, text) is
  'THE canonical release-condition authority (Phase 11-B; lifecycle-aware since 11-D). Answers only '
  '"is this condition presently satisfied", never who may receive a grant, what tier they get, or '
  'whether anyone has died. PURE: the lifecycle arrives as an argument, resolved by SECURITY DEFINER '
  'consumers through public.estate_lifecycle_state — never from claim status, evidence, or attained '
  'levels. after_verified_death is satisfied only under the standard policy at death_verified; '
  'incapacity, the legacy fused value, identity and claim conditions are dormant under every policy. '
  'Unknown condition, unknown policy, unknown lifecycle and NULL all refuse.';

revoke execute on function public.release_condition_satisfied(text, timestamptz, text, text) from public, anon;
grant  execute on function public.release_condition_satisfied(text, timestamptz, text, text) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- release_condition_writable(condition) -> boolean   — THE WRITE-TIME VOCABULARY GATE
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE DEATH/INCAPACITY SPLIT LIVES HERE, AND IT IS A WRITE-SIDE RULE ONLY.
--
-- `after_verified_death_or_incapacity` fused two legally distinct events into one storable value.
-- Death and incapacity differ in who is alive to contest, what evidence exists, whether the owner's
-- own instructions still govern, and whether the change is reversible. A single condition cannot
-- carry both and mean anything.
--
-- The split is done WITHOUT touching stored rows:
--
--   · the table CHECK still ACCEPTS the fused value, so every existing row remains readable and no
--     migration has to guess what an owner meant when they chose it;
--   · this gate REFUSES it for new writes, so no further row can be created carrying the ambiguity;
--   · the satisfied-predicate above treats it as dormant — exactly as it was before — so a legacy
--     row is no more permissive than it was yesterday and no less.
--
-- ★ THE LEGACY VALUE IS NOT REINTERPRETED, AND 11-D DID NOT CHANGE THAT. Now that a verified death
-- can activate `after_verified_death`, the pull to "complete the migration" by mapping fused rows
-- onto the death condition is stronger than ever — and it is still a guess about owner intent that
-- silently makes a stored grant activate on an event the owner may never have chosen alone. Mapping
-- them to `after_verified_incapacity` is the same guess pointing the other way. Both are product
-- decisions about somebody else's estate. An explicit unsatisfiable legacy state costs a
-- re-authoring; a wrong guess costs a disclosure that cannot be undone.
--
-- ★ WRITABLE IS NOT LIVE. `after_verified_death` being writable (11-B) and satisfiable (11-D) are
-- separate facts; `after_verified_incapacity` remains writable and satisfied by NOTHING — nothing
-- verifies an incapacity, and the predicate admits it under no policy. This gate widens what an
-- owner may EXPRESS, never what anybody may SEE.
create or replace function public.release_condition_writable(p_release_condition text)
 returns boolean
 language sql
 immutable
 set search_path to 'public'
as $function$
  select coalesce(p_release_condition in (
    'never',
    'immediately',
    'after_owner_approval',
    'after_identity_verification',
    'after_access_request_approval',
    -- Phase 11-B: the split. Storable and expressible; death satisfiable only since 11-D and only
    -- at death_verified under the standard policy; incapacity satisfied by nothing.
    'after_verified_death',
    'after_verified_incapacity',
    'after_claim_case_approval'
    -- 'after_verified_death_or_incapacity' is DELIBERATELY ABSENT — readable, never writable again.
  ), false);
$function$;

comment on function public.release_condition_writable(text) is
  'Write-time vocabulary gate for access_grants.release_condition (Phase 11-B). Accepts the split '
  'after_verified_death / after_verified_incapacity and REFUSES the deprecated fused '
  'after_verified_death_or_incapacity, which remains legal in the CHECK so stored rows stay readable '
  'and unreinterpreted. Writable is not live: incapacity is satisfied by no policy, and death only '
  'by the authoritative death_verified lifecycle under the standard policy (11-D).';

revoke execute on function public.release_condition_writable(text) from public, anon;
grant  execute on function public.release_condition_writable(text) to authenticated;
