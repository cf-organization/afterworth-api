# Phase 11-B — canonical release-condition engine + lifecycle foundations

Behaviour-preserving architecture phase. **No new disclosure exists.** Baseline verified, not
inherited: API main `05e0b36` (11-A merged), mobile main `f02bd06`, both clean; 160 SQL assertions
at entry, drift EXACT, notification emitters LOCKED.

---

## 1 · The consumer census — re-derived, and the 11-A count was wrong in an instructive way

11-A reported "six sites". Re-derivation against current source found **seven comparisons in five
routines** (11-A counted `notification_grant_is_live` once but missed that `asset_grant_tier`
inside `list_estate_assets.sql` is a separate helper from the inline site), plus two write-side
touchpoints that store conditions without evaluating them:

| # | Site | File | Rule before 11-B | Exercised by any test at entry? |
|---|---|---|---|---|
| 1 | `can_access_document` (final return) | migration 0004 (no source file!) | standard | ✓ SQL suite |
| 2 | `inventory_disclosure_tier` | `estate_discovery_rpcs.sql` | standard | ✓ SQL suite |
| 3 | `notification_grant_is_live` | `lifecycle_notification_rpcs.sql` | standard | ✓ SQL suite + drift |
| 4 | `asset_grant_tier` | `list_estate_assets.sql` | immediate-only | **✗ never executed** |
| 5 | `list_estate_assets` (account_balances gate) | `list_estate_assets.sql` | immediate-only | **✗ never executed** |
| 6 | `get_estate_net_worth` (total grant) | `get_estate_net_worth.sql` | immediate-only | **✗ never executed** |
| 7 | `get_estate_net_worth` (exclusion EXISTS) | `get_estate_net_worth.sql` | immediate-only | **✗ never executed** |
| W1 | `create_asset_grant` / `create_document_grant` | store `p_release_condition` verbatim | n/a (write) | ✓ |
| W2 | `approve_access_request` | stores the constant `'after_access_request_approval'` | n/a (write) | ✓ |

Machine-readable manifest: `test/releaseConditionCentralization.test.ts` § 3 enumerates the
evaluator set from source at every CI run — the census is now an executable artifact, not a table
in a document.

**The coverage finding is the headline.** Four of seven copies had never executed in any test:
`get_estate_net_worth` was loaded by no bundle and no suite (it reads `normalized_assets`, which the
harness did not model), and `list_estate_assets` was *created* by the estate bundle and *called* by
no assertion. The suite reported 160 green assertions while two entire disclosure surfaces — asset
rows and the net-worth aggregate — had never been exercised against a live, dormant, revoked or
foreign grant. Closed in this phase: the harness models `normalized_assets` + `auth.jwt()`, both
functions load, and `db/tests/release_condition_authorization.sql` drives both surfaces with
positive controls before every withholding assertion.

Also surfaced and closed: the anti-shadow guard in `verifySqlAuthorization.mjs` searched
`db/functions/` only, so `can_access_document`, `document_grantable` and `asset_category_grantable`
— defined only in migrations — were exempt from the drift comparison their preamble copies needed.
The guard now searches migrations (newest definition wins), has positive controls for both
directions, and the first two bodies are extracted to `db/functions/` and held VERBATIM.

## 2 · The canonical predicate

`public.release_condition_satisfied(condition, approved_at, policy) → boolean`
(`db/functions/release_conditions.sql`) — immutable, table-free, fail-closed on NULL/unknown in
both arguments, `coalesce(…, false)` against the three-valued-logic trap.

Two named policies, because the census found **two rules**, and collapsing them either direction is
a product decision 11-B is not allowed to take:

- `'standard'` — `immediately`, plus the two approval conditions once approved (documents,
  inventory, notifications; unchanged);
- `'legacy_immediate_only'` — `immediately` alone (all four asset/net-worth sites; unchanged,
  carried forward verbatim and named for what it is).

`p_policy` has **no default** — a new consumer must say which rule it wants.

**It takes no lifecycle state, deliberately.** "No authorization path consults the release seam" is
the structural firewall; a lifecycle argument would spend it early for nothing. 11-D's change is a
widening of this one signature in this one file, with `test/phase11Firewall.test.ts` § 6 pinning the
signature until then.

Equivalence proof: `verifySourceDeploymentDrift.mjs` compares `notification_grant_is_live` — whose
SOURCE now delegates to the new predicate while DEPLOYMENT still inlines the old rule — across the
full input matrix. EXACT agreement there is the refactor being checked against the bytes it
replaced, executed on both sides.

## 3 · The death/incapacity split (D9)

- CHECK **widened** (migration 0051): `after_verified_death`, `after_verified_incapacity` added;
  the fused `after_verified_death_or_incapacity` **stays legal** so stored rows remain readable,
  updatable and unreinterpreted. The migration resolves the constraint name from the catalog
  (never guessed) and self-verifies all three facts, raising if the widening failed.
- Write gate `public.release_condition_writable` **refuses the fused value** for new rows; both
  grant-creation RPCs call it. Update RPCs cannot touch `release_condition` at all.
- **No compatibility mapping exists anywhere** — a fused row satisfied nothing before and satisfies
  nothing now (proven per-surface). Interpreting it as death-only or incapacity-only is a stop-listed
  product decision; the safe state is *explicit legacy, dormant, re-authorable*. The centralization
  audit fails on any source that maps the fused value onto either split value.
- Neither split value is satisfiable under any policy. Writable ≠ live.
- Incapacity remains workflow-less; the mobile audit fails if the death/incapacity vocabulary
  appears in client code at all.

## 4 · Stage 5 — estate lifecycle record: **deferred to 11-C, by design**

Recon: no lifecycle table exists; `estate_release_state` remains a pure projection of
`claim_packets.status`, called only by `get_estate_discovery`, only for a label. 11-B needs no
lifecycle storage: the predicate deliberately consumes none, and no 11-B consumer reads any. An
inert table now would be architecture from a roadmap rather than from a consumer, would add
deploy/drift/bundle surface with no reader, and would sit unexercised — this phase's own findings
show what unexercised schema becomes. Constraints recorded for 11-C:

1. a **distinct estate-lifecycle record**, never `claim_packets.status` as carrier (11-A § 8);
2. claims remain *evidence for* a lifecycle event, not the event;
3. transitions must be transactional and audited with policy-evaluated + grants-affected metadata
   (11-A § 7 gap 3);
4. the shipping product stays effectively ACTIVE-only until 11-D's controlled activation.

## 5 · Stage 6 — attained verification level: **deferred to 11-C, by design**

`required_verification_level` (policy side) exists and is advisory; there is no attained-level
storage and 11-B's predicate does not need one (identity-conditioned grants are dormant under both
policies). An attained-level column with no writer and no reader would be inert in the bad sense.
It belongs in 11-C beside the verification workflow that writes it, at which point H2 (advisory
policy engine) must be resolved by *enforcing* attained ≥ required before claim acceptance.

## 6 · What deploys, and in what order

Nothing is deployed by this phase. Production continues to run the pre-11-B bodies, which the drift
reconciler proves behaviourally identical on every reconcilable contract.

When the operator does deploy: **`db/bundles/release_conditions_bundle.sql` must be pasted FIRST.**
`notification_grant_is_live` is `language sql` — the lifecycle bundle will not load without the
predicate — and `inventory_disclosure_tier` (plpgsql) would create and then raise at first call.
The drift reconciler now detects the half-deployed state by name and exits 1 with the re-apply
instruction.

## 7 · Deferred ledger (11-C continuation point)

| Item | Where recorded |
|---|---|
| Unify `standard` / `legacy_immediate_only` (product decision: do approval-conditioned grants belong on asset surfaces?) | `release_conditions.sql` header |
| Estate lifecycle record + transitions | § 4 above |
| Attained verification level + enforcement of H2 | § 5 above |
| Owner notification of claims (H1) → D4 challenge window | 11-A threat model T9 |
| `encrypted_instructions.release_condition` vocabulary (`on_death`/`on_executor_claim`/`manual`) unaligned with grants — dormant today (no grant to `authenticated`, no unwrap, nothing sets `released`); align when 11-E wires instructions | 11-A § 1.5 |
| `get_estate_net_worth` / `require_aal2` have no deploy bundle; loaded by the suite directly. Promote only with a source↔deployment equivalence check first | `scripts/lib/sqlSuiteParts.mjs` header |
| Claim evidence re-referencable across claim generations (T6) | 11-A threat model |
| AAL2 step-up for claim submission (T4) | 11-A threat model |
