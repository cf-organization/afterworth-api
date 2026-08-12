# Phase 11-D — Lifecycle-Aware Release Predicate + Death-Condition Activation

**Date:** 2026-08-12 · **Repos:** afterworth-api (this change), afterworth-mobile (zero production changes)

Phase 11-D connects exactly one seam:

```
authoritative estate lifecycle state          (estate_lifecycle · absent row = 'active')
        ↓  read via public.estate_lifecycle_state(estate)   [SECURITY DEFINER, client-revoked]
public.release_condition_satisfied(condition, approved_at, policy, lifecycle_state)
        ↓
existing owner-authored after_verified_death grants may become live
```

No other authority is added. Activation is **evaluative**: no grant row is written, no tier
raised, no membership or designation created, no notification emitted, no `released` state made
storable or reachable.

## 1 · The canonical signature change (the one file)

`db/functions/release_conditions.sql` — `release_condition_satisfied` widened from
`(condition, approved_at, policy)` to `(condition, approved_at, policy, lifecycle_state)`.

- Fail-closed on every axis: NULL/unknown condition, NULL/unknown policy, **NULL/unknown
  lifecycle** (validity gate over the closed 0052 vocabulary, checked against the deployed CHECK by
  the SQL suite) all refuse everything.
- `standard`: `immediately`; the two approval conditions once approved; **`after_verified_death`
  exactly while lifecycle = `death_verified`** — the 11-D arm.
- `legacy_immediate_only`: `immediately` alone, lifecycle-indifferent — **preserved exactly** (R12).
- `after_verified_incapacity`, `after_verified_death_or_incapacity`, `after_claim_case_approval`,
  `after_identity_verification`, `never`: satisfied by nothing, under every policy, at every
  lifecycle (R6/R7).
- The predicate stays **pure/immutable** (no table reads): a predicate that resolved
  estate → lifecycle itself would be a client-executable death-status oracle, and a pure function
  is exhaustively truth-tabled by the suite.
- Migration `0053` **drops the 3-argument overload** — without the drop, overload resolution would
  quietly serve the lifecycle-blind rule to any consumer that was not rewired.

## 2 · Consumer census (executable: `test/releaseConditionCentralization.test.ts`, balanced-paren)

| # | Call site | Policy | Lifecycle argument |
|---|---|---|---|
| 1 | `can_access_document` | standard | `estate_lifecycle_state(v_estate)` |
| 2 | `inventory_disclosure_tier` (estate_discovery_rpcs) | standard | `estate_lifecycle_state(p_estate)` |
| 3 | `notification_grant_is_live` (lifecycle_notification_rpcs) | standard | **`'active'` — the emission pin (see §5)** |
| 4 | `asset_grant_tier` (list_estate_assets) | legacy_immediate_only | `estate_lifecycle_state(p_estate)` |
| 5 | `list_estate_assets` body | legacy_immediate_only | `estate_lifecycle_state(p_estate_id)` |
| 6 | `get_estate_net_worth` (total gate) | legacy_immediate_only | `estate_lifecycle_state(p_estate_id)` |
| 7 | `get_estate_net_worth` (breakdown exclusion) | legacy_immediate_only | `estate_lifecycle_state(p_estate_id)` |

All seven are SECURITY DEFINER, each resolving the lifecycle **of the estate whose grant it is
evaluating**, beside the grant lookup. Discipline pinned by test in both directions:
`releaseConditionCentralization` requires every 4th argument to be the seam call (or the one
notification pin); `deathVerificationFoundation` requires that outside the death module the reader
appears **only as the predicate's argument** — a local `if estate_lifecycle_state(e) =
'death_verified'` comparison is unwritable.

## 3 · Lifecycle authority

`estate_lifecycle_state` moved from `death_verification.sql` to its own source file
(`db/functions/estate_lifecycle_state.sql`). It is the ONLY lifecycle read: never
`claim_packets.status`, never evidence, never attained levels, never the label-only
`estate_release_state()` claim projection. Its only writer remains
`apply_estate_lifecycle_transition` (closed map, audited), reachable only through the admin
decision that re-derives required verification LIVE (H2).

## 4 · Standard vs legacy — R12 preserved

`standard` gains the death arm; `legacy_immediate_only` does not. A death-conditioned grant on an
asset-value category (`account_balances`, `institution_names`, `total_asset_value`,
`linked_account_details`) stays dormant **even at death_verified**. Pinned as data (truth-table
cell `death × legacy × death_verified = false`), as behaviour (activation matrix §9(c): asset rows
and net worth stay empty/hidden on a death_verified estate), and as structure (the legacy `case`
arm must not name the death condition — firewall test). Unification remains a deferred product
decision with its own row inventory and migration price.

## 5 · Notifications — the emission pin

`notification_grant_is_live` keeps its 3-argument shape and passes the **literal `'active'`** as
the predicate's lifecycle. Emission speaks only about access that holds without reference to any
lifecycle event: a "You have access" born from `death_verified` is the release announcement Phase
11-F owns. Consequences, all verified:

- every emission is byte-identical to Phase 10-E (the source↔deployment reconciler compares this
  function's full truth table EXACT against the deployed inline body — still EXACT);
- the subset property holds: everything announced is readable; the read path may allow more;
- no death or release fact can reach a notification (mutation-tested from both directions:
  repointing the pin and enriching the copy).

## 6 · Deployment (NOT performed — operator action required)

11-B, 11-C and 11-D are **source-merged, deployment-pending**. Nothing here was deployed; no
deployed behaviour changes until the operator pastes.

### Bundle contents changed in 11-D

- `release_conditions_bundle.sql` — now carries the seam: `0051 → 0052 → 0053 →
  release_conditions.sql → estate_lifecycle_state.sql → document_grantable.sql →
  can_access_document.sql`. The FIRST pasted artifact must carry the seam so no paste order has a
  broken middle (every consumer resolves the reader at read time).
- `estate_inventory_and_discovery_bundle.sql` — prepends `0052, 0053, release_conditions.sql,
  estate_lifecycle_state.sql` (self-sufficiency: `asset_grant_tier` is `language sql` and resolves
  the reader at CREATE).
- `lifecycle_notifications_bundle.sql` — prepends `0053` before the canonical module.
- `death_verification_bundle.sql` — `0052 → estate_lifecycle_state.sql → death_verification.sql`.

### Operator runbook

1. Build (or verify current): `node scripts/buildReleaseConditionBundle.mjs &&
   node scripts/buildEstateAssetBundle.mjs && node scripts/buildLifecycleNotificationBundle.mjs &&
   node scripts/buildDeathVerificationBundle.mjs` — each prints its positive-control count;
   `git status` must be clean afterwards (bundles committed current).
2. Paste, in order, each as ONE run in the Supabase SQL editor:
   1. `db/bundles/release_conditions_bundle.sql`
   2. `db/bundles/estate_inventory_and_discovery_bundle.sql`
   3. `db/bundles/lifecycle_notifications_bundle.sql`
   4. `db/bundles/death_verification_bundle.sql`
   Every intermediate state is live-safe: after paste 1 the lifecycle table is empty, so every
   estate evaluates as `active` and all behaviour is byte-identical to today.
3. Verify: `node scripts/verifySourceDeploymentDrift.mjs` — expect
   `release_condition_authority · EXACT · DEPLOYED at the 11-D shape` and
   `death_verification_authority · UNVERIFIABLE · DEPLOYED`, all other rows EXACT, exit 0.
   - **Half-deploy symptoms:** `PARTIAL DEPLOYMENT` naming the absent objects (re-paste the named
     bundle in full); or `DEPLOYED release authority is LIFECYCLE-BLIND` (0053 did not run — the
     3-arg overload is still reachable; re-paste bundle 1).
4. Post-deploy SQL smoke (read-only, run in the editor):
   `select public.release_condition_satisfied('after_verified_death', null, 'standard', 'active')`
   → false; same with `'death_verified'` → true; same with policy `'legacy_immediate_only'` →
   false; `select public.release_condition_satisfied('immediately', null, 'standard', 'active')` →
   true.
5. Information-flow smoke: as a non-owner test account holding no grant, load discovery/assets on a
   test estate — unchanged; there is no death_verified estate in production until a real case
   completes, so activation itself is exercised by the SQL suite, not by production smoke.
6. Rollback containment: the bundles are additive and idempotent. Reverting 11-D behaviour without
   a redeploy is not possible once pasted; the contained rollback is pasting a rebuilt bundle from
   the prior release tag (which restores the 3-arg predicate and lifecycle-blind consumers as one
   unit). Do not hand-edit deployed routines.

## 7 · Deferred ledger (11-D)

1. **Policy unification** (`standard` vs `legacy_immediate_only`) — unchanged from 11-B/11-C;
   requires affected-row inventory + pricing (R12). The truth-table cell and the surface matrix
   both pin the current split.
2. **Survivor UI / release notifications / challenge workflow** — 11-F/11-I (R11).
3. **Incapacity pipeline** — dormant end-to-end (R6); `after_verified_incapacity` writable,
   satisfiable by nothing.
4. **Fused legacy rows** — dormant, unreinterpreted (R7); re-authoring flow undesigned.
5. **Harness `documents_read` policy is owner-only** (a preamble stand-in, noted in the activation
   matrix §9(d)): the production policy consults `can_access_document`. The document surface is
   proven at the gate and through discovery's gate-counted `document_count`; aligning the harness
   policy with the deployed one is a harness-fidelity item, not a product gap.
6. **11-C carry-overs** unchanged: vault-delete sentinel for case evidence, case read surface,
   H1 owner notification (→ 11-F), `estates.status` vestige.

## 8 · Where the proof lives

- Truth table + dormancy + activation surface matrix: `db/tests/release_condition_authorization.sql`
  (§0 instrument self-check incl. one-authority + seam-internal; §1 full 4-axis table enumerated
  from BOTH deployed CHECKs; §2/2b dormancy + the single satisfying region; §9 activation on a
  dedicated estate through the authoritative transition writer — pending discloses nothing;
  activation honours tier/ceiling/revocation/brackets; legacy stays dormant; cross-estate isolated;
  emission refuses).
- Real-door activation + equivalence: `db/tests/death_verification_authorization.sql` (§5 —
  initiate → evidence → review → attain → verify; the delegate's death grant goes live in exactly
  its two authorized projections (discovery + workspace inventory block); every other viewer
  byte-identical; grants/memberships/designations byte-stable; the same grant on estate Y dormant).
- Structure: `test/phase11Firewall.test.ts` (death admitted only in the canonical module, conjoined;
  legacy arm clean), `test/releaseConditionCentralization.test.ts` (one authority; 4-arg; balanced-
  paren lifecycle-argument census; purity), `test/deathVerificationFoundation.test.ts` (sanctioned
  consumer set; reader only-as-argument; table touched only by reader/writer; reader revoked).
- Mutations: `scripts/mutateSqlAuthorization.mjs` — 19 new `p11d-*` mutations + 5 re-anchored.
