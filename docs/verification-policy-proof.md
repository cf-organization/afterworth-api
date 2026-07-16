# Verification policy engine — monotonicity proof (Slice C3)

The engine (`required_verification_level`, migration `0027`) enforces one invariant:

> **`required_level = GREATEST(jurisdiction_floor, escalation_max)`** — risk factors only escalate
> UPWARD, never waive below the jurisdiction floor; an unknown/unapproved jurisdiction → the highest
> floor (`enhanced_kyc`, fail closed).

The invariant is **structural**, not conventional: the only combinator is `GREATEST()`, there is **no code
path that returns below `v_floor`**, `v_floor` defaults to `enhanced_kyc` in code on any unmapped/unapproved
lookup, and the function takes **only `p_estate`** (no client-supplied level). This doc records the live proof
that it holds — both directions. Verified **2026-07-16** on the live test estate.

## Ordered level type + the config table (`0026`)

- **`verification_level` ENUM** `('attestation','kyc','enhanced_kyc')` — the ordering IS the type (declaration
  order = rank), so `GREATEST()`/comparisons are native and single-sourced; a new level slots in via
  `ALTER TYPE … ADD VALUE … BEFORE/AFTER`. No rank column to drift.
- **`jurisdiction_policy`** — counsel-owned (`jurisdiction` PK, `floor_level`, `is_counsel_approved`, notes,
  updated_by, timestamps). **Ships EMPTY**: "unmapped = maximum" is a **code invariant** in the engine, not a
  seed row, so fail-closed can't be broken by deleting a config row. `is_counsel_approved` is the **data-gate**
  C5 reads (a row that exists but is unapproved is treated as unmapped).
- **RLS posture — the matrix is an ATTACK MAP → world-unreadable**: RLS on, **no client grants**. Readers are
  the DEFINER engine + admin RPCs only.
- **`set_jurisdiction_floor`** (admin write) — `admin_require_gate` + mandatory reason/case_ref + a
  HIGH-severity `source='admin'` audit carrying old→new. **`admin_list_jurisdiction_policy`** (admin read).

### COMMIT #1 verdicts — 9/9 pass

| leg | got | pass |
|-----|-----|:----:|
| E1 enum ordering (`GREATEST(attestation,kyc)=kyc` + `<`) | kyc + true | ✅ |
| G1 non-admin set → `admin_required` | admin_required | ✅ |
| G2 admin aal1 → `mfa_required` | mfa_required | ✅ |
| G3 missing reason → `breakglass_reason_required` | breakglass_reason_required | ✅ |
| OK1 upsert kyc+approved | kyc + true | ✅ |
| OK2 audit `old=null new=kyc` (source=admin, sev=high) | 1 | ✅ |
| OK3 update audits `old=kyc new=enhanced_kyc` | 1 | ✅ |
| L1 admin_list | 1 | ✅ |
| RLS1 matrix unreadable (`has_table_privilege auth/anon = false`) | auth=false anon=false | ✅ |

ACL born-clean: `jurisdiction_policy` has **zero** anon/authenticated/service_role grants.

## The monotonic engine (`0027`)

`required_verification_level(p_estate)` — DEFINER, STABLE, **INTERNAL** (revoked from every client role).
Body: fetch the estate's jurisdiction → its **approved** floor (or `enhanced_kyc` if none) → the estate value
tier (`normalized_assets`, a monotone CASE) → **`return greatest(v_floor, v_value_level)`**. The client door
is `preview_required_verification_level` (gated to a party of the estate).

### COMMIT #3 verdicts — 10/10 pass (real test estate; value leg reuses an existing connection)

| leg | got | pass |
|-----|-----|:----:|
| **A** unmapped jurisdiction → `enhanced_kyc` (fail closed) | enhanced_kyc | ✅ |
| **E** unapproved row → `enhanced_kyc` (is_counsel_approved gate) | enhanced_kyc | ✅ |
| **B** floor dominates (floor=enhanced_kyc) | enhanced_kyc | ✅ |
| **C** value-applied at minimal floor → the estate's value tier | attestation | ✅ |
| **D** MONOTONICITY: `required_level ≥ floor` across every floor | true | ✅ |
| **C2** low floor + injected $2M → `enhanced_kyc` (upward-only) | enhanced_kyc | ✅ |
| **F** no-bypass: `args=p_estate uuid`, engine sealed (`auth_exec=false`) | p_estate uuid \| false | ✅ |
| **G** matrix unreadable | auth=false anon=false | ✅ |
| **P1** preview non-party → `not_authorized` | not_authorized | ✅ |
| **P2** preview party (owner) → a level | attestation | ✅ |

The load-bearing legs are **A** (fail-closed on unknown), **D** (no input combination dips below the floor),
and **F** (no client level parameter to inject). The test estate's real value tier is `attestation` (low
value), so leg **C** correctly returns `attestation` (= the value level at the minimal floor); **C2** injects a
$2M asset to deterministically drive escalation to `enhanced_kyc`, proving the value factor moves the result
**up** and never down.

## What is MECHANISM vs. counsel's

This slice is **mechanism only, zero legal dependency**. The real per-jurisdiction floor VALUES are counsel's —
loaded later as `is_counsel_approved=true` rows via `set_jurisdiction_floor` (each write audited). Until then,
every estate resolves to `enhanced_kyc` (fail closed). Value thresholds are code constants today; making them
jurisdiction-dependent is a config extension in the same counsel-owned table family. International-participant /
fraud / owner-override factors have no data source yet — each is one more `GREATEST()` argument when it lands,
and by construction can only raise the result.
