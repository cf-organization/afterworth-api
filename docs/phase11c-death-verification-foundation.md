# Phase 11-C — death event + evidence + verification-state foundation

Data-and-state foundation only. **No disclosure changed, and the suite proves it byte-for-byte.**
Baseline verified, not inherited: API main `9affac7`, mobile main `ad1a289`, both clean; 202 SQL
assertions at entry, 33/33 mutations, 201 vitest; drift posture unchanged from 11-B (release
bundle built, not deployed).

---

## 1 · What exists after 11-C

Three tables (migration 0052), one routine module (`db/functions/death_verification.sql`), one
paste-ready bundle (`db/bundles/death_verification_bundle.sql`).

| Record | Purpose | Authority posture |
|---|---|---|
| `estate_lifecycle` | THE authoritative estate lifecycle: `active` / `death_verification_pending` / `death_verified`. Absent row = `active`. | Zero client grants/policies. One writer (`apply_estate_lifecycle_transition`, revoked from clients). Reader `estate_lifecycle_state()` revoked from clients — consulted by NOBODY in production, pinned. |
| `death_verification_cases` | The case: initiator + capacity snapshot, jurisdiction context, `required_level_at_initiation` (snapshot), `attained_level` (NULL baseline), open/verified/rejected/cancelled. `event_type` CHECK admits **only `'death'`**. | Zero client grants. One open case per estate (partial unique + lifecycle guard, each independently proven). |
| `death_verification_evidence` | A received document pin: case, estate, `documents` FK (no ON DELETE — deletion of pinned evidence refuses), submitted_by/at, `received` / `reviewed_accepted` / `reviewed_rejected`. | Zero client grants. Evidence KIND is the linked document's taxonomy — no invented vocabulary. |

**`estate_release_state()` is untouched** — still a label-only projection of `claim_packets.status`
with exactly one consumer. The claim workflow and the death-verification case are disjoint records
(D7): the SQL suite drives a full case to `death_verified` and asserts `estate_release_state` still
answers `active` with zero claim rows.

## 2 · The routines and their gates

| Routine | Gate | Notes |
|---|---|---|
| `initiate_death_verification_case(estate)` | `is_estate_executor` — the same canonical fiduciary predicate that gates claim submission (D2 derived, not decided: executor and trustee alike; ownership neither qualifies nor disqualifies) | Snapshots jurisdiction + required level; attained stays NULL; lifecycle → pending |
| `attach_death_verification_evidence(case, doc)` | active designee of the case's estate | Document must be in the case's estate; touches NO level, NO state |
| `cancel_death_verification_case(case)` | initiator AND still-active designee | lifecycle → active; case survives as history |
| `admin_review_death_evidence(evidence, outcome)` | `admin_require_gate` (AAL2 + ≤900 s token) | Records review; **does not move attained** (T15) |
| `admin_set_attained_verification_level(case, level)` | `admin_require_gate` | THE only attained writer; parameter typed `public.verification_level` — out-of-vocabulary unrepresentable |
| `admin_decide_death_verification_case(case, verify\|reject)` | `admin_require_gate` | **H2 closed**: `verify` refuses unless `coalesce(attained >= required_verification_level(estate), false)` — the requirement re-derived LIVE (tightened policy tightens the case; proven by withdrawing counsel approval mid-case) |

Refusal shape: `auth_required` for no session; **one exact sentinel, `not_authorized`, for every
other unauthorized cause** — nonexistent estate, foreign estate, nonexistent case, wrong role,
revoked designation — asserted byte-identical with EXACT equality, not containment.

## 3 · The firewall, proven

For beneficiary (live grant), professional delegate (death-conditioned grant), stranger and
foreign owner, the composed payload (discovery + assets + net worth + documents + readiness +
workspace + notifications) is **byte-identical** across: no case → case open → evidence received →
evidence reviewed → attained kyc → attained enhanced_kyc → **death_verified**. Paired positive
control: an authorized grant moves the payload. Also pinned: zero notifications emitted, zero
`access_grants` bytes changed (whole-flow bracket), claim workflow untouched, `released`
unrepresentable (not in the CHECK, not in the transition map — both directions asserted, plus a
vitest pin and a mutation on each).

## 4 · Suite / instrument changes

- `db/tests/death_verification_authorization.sql` — 38 assertions; sentinel wired into the runner.
- Preamble: models `audit_logs` (0011 shape) + `admins` + `jurisdiction_policy` + the
  `verification_level` enum + `estates.jurisdiction`; **`write_audit` promoted STUB → VERBATIM**
  (audit persistence became a boundary under test).
- Runner: checks the previously emitted-but-unchecked `ALL PROFESSIONAL WORKSPACE ASSERTIONS
  PASSED` sentinel (a suite aborting after the readiness file would have gone green); dead
  `if (false)` guard removed.
- `SQL_DIRECT_PARTS` gains `is_admin.sql`, `admin_require_gate.sql`,
  `required_verification_level.sql` — loaded for coverage, still in no deploy bundle (the
  `create_asset_grant` near-miss rule; promotion requires a source↔deployment equivalence check
  that does not exist yet). This is the policy engine's FIRST executable coverage.
- `test/deathVerificationFoundation.test.ts` — 30 static pins: the new seam consulted by nobody,
  the module names no disclosure surface, the transition map closed, H2 consults the live central
  engine (never the snapshot, never a local literal), one attained writer, internal routines
  revoked. `phase11Firewall.test.ts` §4 widened once, deliberately: `death_verification.sql` joins
  the `is_estate_executor` caller list.
- Mutations: **+21 (33 → 54)**, covering the phase matrix. Matrix items killed elsewhere: #7
  (`p11b-claim-approval-satisfies-a-condition`, 11-B), #21 (`p11-executor-gains-disclosure`,
  11-A), #16 (mobile-side `releaseAuthorityAbsence.test.ts`, self-proving).

## 5 · What deploys, and in what order

Nothing is deployed by this phase. When the operator deploys, the standing 11-B rule is unchanged
and extended by one line:

1. `db/bundles/release_conditions_bundle.sql` — **FIRST** (standing 11-B requirement).
2. `db/bundles/estate_inventory_and_discovery_bundle.sql`, then
   `db/bundles/lifecycle_notifications_bundle.sql` (if re-applying).
3. `db/bundles/death_verification_bundle.sql` — **LAST**. Requires migrations 0019/0026/0027,
   deployed live long ago (verified 2026-07-15/16). Contains 0052 + the routine module; 0052
   self-verifies and raises if the foundation did not take.

The drift verifier rebuilds and loads all four bundles onto its source-side container, so the
operator paste is rehearsed on every run.

## 6 · Decisions derived (not taken) and the H1 posture

- **Owner self-initiation**: derived from current semantics — the gate is the designation, full
  stop. An owner without a designation is refused as a non-designee; an owner holding one passes
  by the designation, exactly as `submit_claim_packet` has always behaved. No new product ruling.
- **Trustee vs executor**: current semantics rank them identically (`is_estate_executor`);
  preserved; the case records which capacity acted, as fact.
- **Evidence kinds**: no new vocabulary — the linked document's server-catalog taxonomy is the
  descriptor. "Which documents are legally sufficient" remains an open product/legal decision the
  schema does not prejudge.
- **H1 (owner not told of a claim/case)**: no notification added (§22 defers wording to 11-F).
  The data model does not preclude it: every case event is an attributed `audit_logs` row a future
  notification emitter can key on, and the lifecycle-notification catalog pattern (10-E) is the
  designated vehicle. Nothing in 11-C makes the owner-notification path harder.

## 7 · Deferred ledger (11-D continuation point)

| Item | Where recorded |
|---|---|
| 11-D activation seam: widen `release_condition_satisfied` (one signature, one file) AND consume `estate_lifecycle_state` in it; both pins must be re-decided loudly | `release_conditions.sql` header; `phase11Firewall.test.ts` §6; `deathVerificationFoundation.test.ts` §1 |
| `delete_vault_document` / `replace_vault_document` sentinel for open-case evidence (today: raw FK refusal, correct but unpolished; editing the deployed, unbundled function was deferred to avoid drift) | 0052 evidence FK comment |
| Case read surface for the initiator (status visibility) + owner visibility of a case (H1/D4 product copy) | §6 above; 11-F |
| Standard vs `legacy_immediate_only` policy unification (11-B carry-over, still open) | `release_conditions.sql` header |
| Promote `required_verification_level` / `get_estate_net_worth` / `require_aal2` / admin gates to a deploy bundle only with a source↔deployment equivalence check | `sqlSuiteParts.mjs` header |
| Evidence re-referencing across case generations (T6 analogue); AAL2 step-up for initiation (T4) | 11-A threat model carry-overs |
| Reviewer identity/role model beyond platform admin (jurisdiction-local reviewers) | 11-A jurisdiction register #9 |
| `estates.status` vestigial column (`in_claim` value, zero readers/writers) — retire or adopt deliberately | recon, this phase |

## 8 · Threat-matrix disposition (T1–T16)

T1/T2 designation-gated initiation + byte-identical refusals (mutations: beneficiary/delegate/
any-authenticated initiate). T3 designation creation unchanged (invitation-provisioned, admin
break-glass audited; fraudulent designation remains a 11-A register item — prevention upstream of
this phase). T4 evidence is `received`, never verified; upload moves nothing (mutation). T5 single
admin cannot release anything — verification ≠ release structurally; two-person release control is
11-D's to design (D3). T6 estate-scoped cases/evidence, cross-estate probes byte-identical
(mutations). T7 idempotent replays re-audit nothing (asserted for review/decide/cancel). T8
decided cases immutable; attained frozen post-decision (asserted). T9 exact-sentinel refusals,
no read surface, grant-less tables (mutations: leak count/claimant/estate-existence). T10 audit
metadata carries ids only (asserted). T11 stale cases cannot trigger anything — no consumer of the
lifecycle exists (pinned). T12 event_type CHECK = `'death'` only (mutation). T13 unknown
jurisdiction → `enhanced_kyc` (mutation). T14 attained writable only via admin gate + enum type
(mutations). T15 review ≠ attained ≠ verified (asserted at each step). T16 verification ≠ release:
`death_verified` changes nothing (the central firewall, 4 viewers × 7 surfaces).
