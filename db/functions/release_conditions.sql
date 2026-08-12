-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- THE CANONICAL RELEASE-CONDITION AUTHORITY  ·  Phase 11-B
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
-- moves HERE first, before any death wiring exists, and every consumer becomes a caller.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ WHAT THIS MODULE DECIDES, AND WHAT IT DELIBERATELY DOES NOT
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- It answers ONE question: given a release condition and the approval fact recorded beside it, is
-- that condition presently SATISFIED?
--
-- It does NOT decide who may receive a grant, compute a disclosure tier, manufacture a grant, verify
-- a death, approve a claim, or transition any lifecycle state. Callers keep every one of those.
--
-- ★ IT TAKES NO LIFECYCLE STATE, AND THAT IS A DECISION RATHER THAN AN OMISSION.
--
-- The obvious shape for this function is `(condition, approved_at, estate_lifecycle_state)`. It is
-- deliberately NOT that shape in 11-B, because giving it one would require every read path to
-- resolve the estate's release state — and "no authorization path consults the release seam" is the
-- structural guarantee that makes an approved claim disclose nothing today. Today that is true not
-- because each read path checks the state and refuses, but because no read path knows the state
-- exists. Wiring a lifecycle argument through here would quietly spend that guarantee for nothing,
-- weeks before there is a verified event to spend it on.
--
-- The 11-D change is therefore a widening of THIS signature and nothing else, in ONE file, with the
-- firewall suite watching. That is the entire point of the phase.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ TWO POLICIES, NAMED — because the drift above is real and 11-B may not spend it
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- Collapsing the two answers into one requires choosing which is right, and both directions change
-- what a user sees:
--
--   · widening the asset surfaces to honour approval-conditioned grants would make an already-stored,
--     already-approved grant start disclosing — new disclosure, forbidden in a behaviour-preserving
--     phase, and a product decision about whether an existing grant becomes more permissive;
--   · narrowing the document surfaces would break the access-request feature outright, since
--     `approve_access_request` issues exactly an `after_access_request_approval` grant.
--
-- So 11-B centralizes the AUTHORITY without deciding the POLICY: both answers live here, each named,
-- each chosen explicitly at its call site, and the divergence is now one `case` arm in one file
-- instead of seven scattered literals nobody can enumerate. `legacy_immediate_only` is named for
-- what it is — a compatibility clamp carried forward verbatim, not a designed rule — and unifying it
-- is the first item in the Phase 11-C ledger.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ FAIL-CLOSED IN BOTH ARGUMENTS
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- An unknown condition is false. An unknown policy is false. A NULL condition is false. A NULL
-- policy is false. There is no permissive default and no `else true` anywhere below.
--
-- The `coalesce` is load-bearing rather than defensive tidiness: `null = 'immediately'` is NULL, not
-- false, and a boolean gate that returns NULL is not refused by `if not (…) then` — that branch
-- simply does not execute, and the caller carries on as though the check had passed. A three-valued
-- answer from a two-valued gate is how a fail-closed predicate fails open.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- release_condition_satisfied(condition, approved_at, policy) -> boolean   — THE AUTHORITY
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- `p_policy` has NO DEFAULT, on purpose. A default would let a new consumer inherit the wider rule by
-- saying nothing, which is the exact failure mode — silent policy by omission — that the seven
-- scattered copies represented.
create or replace function public.release_condition_satisfied(
  p_release_condition text,
  p_approved_at       timestamptz,
  p_policy            text
)
 returns boolean
 language sql
 immutable
 set search_path to 'public'
as $function$
  select coalesce(
    case p_policy
      -- Documents, the estate-documents category, and estate inventory. `after_owner_approval`
      -- (owner-initiated) and `after_access_request_approval` (beneficiary-initiated) are the SAME
      -- gate — both mean "the owner approved this access", differing only by who asked.
      when 'standard' then
        p_release_condition = 'immediately'
        or (p_release_condition in ('after_owner_approval', 'after_access_request_approval')
            and p_approved_at is not null)

      -- The asset-value surfaces (account balances, institution names, total asset value, linked
      -- account details). Carried forward EXACTLY as they were written, including their narrowness.
      -- See the note above: this is a compatibility clamp with a 11-C ledger entry, not a rule
      -- anyone designed.
      when 'legacy_immediate_only' then
        p_release_condition = 'immediately'

      -- Unknown policy -> refused. No `else true`, ever.
      else false
    end,
    false);
$function$;

comment on function public.release_condition_satisfied(text, timestamptz, text) is
  'THE canonical release-condition authority (Phase 11-B). Answers only "is this condition presently '
  'satisfied", never who may receive a grant, what tier they get, or whether anyone has died. Takes '
  'NO lifecycle state by design: wiring one through would connect the release seam to authorization, '
  'which is the structural guarantee that makes an approved claim disclose nothing. Death-, '
  'incapacity-, identity- and claim-conditioned grants are dormant under every policy. Unknown '
  'condition, unknown policy and NULL all refuse.';

revoke execute on function public.release_condition_satisfied(text, timestamptz, text) from public, anon;
grant  execute on function public.release_condition_satisfied(text, timestamptz, text) to authenticated;

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
-- ★ THE LEGACY VALUE IS NOT REINTERPRETED, AND THAT IS THE SAFE ANSWER RATHER THAN THE EASY ONE.
-- Mapping fused rows to `after_verified_death` would be a guess about owner intent that silently
-- makes a stored grant activate on an event the owner may never have chosen; mapping them to
-- `after_verified_incapacity` is the same guess pointing the other way. Both are product decisions
-- about somebody else's estate. An explicit unsatisfiable legacy state costs a re-authoring; a wrong
-- guess costs a disclosure that cannot be undone.
--
-- ★ AND BOTH NEW CONDITIONS ARE UNSATISFIABLE TODAY. Being writable is not being live: nothing
-- verifies a death, nothing verifies an incapacity, and `release_condition_satisfied` admits neither
-- under any policy. This gate widens what an owner may EXPRESS, never what anybody may SEE.
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
    -- Phase 11-B: the split. Storable, expressible, and satisfied by nothing.
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
  'and unreinterpreted. Writable is not live: neither new condition is satisfied by any policy.';

revoke execute on function public.release_condition_writable(text) from public, anon;
grant  execute on function public.release_condition_writable(text) to authenticated;
