# Phase 11-M — fiduciary initiation slice: recon, state graph, and the design

**NOTHING WAS IMPLEMENTED. NO DEATH PROCESS WAS STARTED. NO PRODUCTION DATA WAS CREATED.**
This is Stages 0–7. It stops at the Stage 8 boundary for one reason, stated in §8.

> **TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE.** Production customer release requires two
> distinct human operators.

---

## Stage 0 · Baseline

| Repo | HEAD == origin/main | Tree |
|---|---|---|
| afterworth-api | `ac2e6a0` ✓ | clean |
| afterworth-mobile | `2acd54e` ✓ | clean |
| afterworth-admin | `fd7ef03` ✓ | foreign: `M .gitignore` (+`.env*`), `?? python3` (empty, 2026-07-20) — classified, untouched |

Deployed prerequisites, all re-verified rather than inherited:

| Check | Result |
|---|---|
| `get_executor_workspace` deployed | PRESENT |
| `estate_release_state` LOCKED | execute revoked, "permission denied" confirmed |
| Operator console deployed | `admin.minifam.com` ● Ready |
| `verifyOperatorDoorRefusal.mjs` | **exit 0** |
| `verifyOperatorAdmitPath.mjs` | **exit 0** |
| `verifyDeployedContracts.mjs` (mobile) | **exit 0** |
| Owner-notice drain scheduled | 2 crons; `/api/claims/drain_outboxes` `0 4 * * *` |
| Drain endpoint live + fail-closed | 401 unauthenticated · 404 for a nonexistent action (the control) |

## Stage 1 · The three routines, re-derived from source

All three are `security definer`, `revoke ... from public, anon`, `grant ... to authenticated`. None
is admin-gated: the gate is a **designation**, not a privilege, so an AAL2 operator cannot substitute.

### `initiate_death_verification_case(p_estate) → uuid`

| | |
|---|---|
| Authorization | `auth.uid()` → `auth_required`; then `is_estate_executor(p_estate, uid)` → `not_authorized`. **The gate runs before any existence lookup**, so a nonexistent and a foreign estate refuse with identical bytes. |
| Preconditions | `estate_lifecycle_state(p_estate) = 'active'`, else `lifecycle_conflict` (P0001) |
| Postconditions | one case row `status='open'`; lifecycle → `death_verification_pending`; captures designation id, capacity (`executor` sorts before `trustee`), jurisdiction snapshot, and `required_verification_level` **at initiation** — recorded as history, never copied into `attained` |
| Audit | `death_case.initiated` |
| Notification | **NONE** |
| Idempotency | **NOT idempotent.** A second call raises `lifecycle_conflict`; `death_verification_cases_one_open_per_estate` (partial unique index on `estate_id where status='open'`) is the structural backstop |

### `attach_death_verification_evidence(p_case, p_document) → uuid`

| | |
|---|---|
| Authorization | case must exist **and** caller must be an active designee of the case's estate — one sentinel for nonexistent and foreign alike |
| Preconditions | case `status='open'` → else `case_not_open`; document must be in the same estate → else `doc_not_in_estate` (again one sentinel for missing and foreign) |
| Postconditions | one evidence row. **No lifecycle transition. No verification-level change** — a thousand attachments leave `attained` where it was |
| Audit | `death_case.evidence_attached` |
| Notification | **NONE** |
| Idempotency | **NOT idempotent, and no detach path exists.** Re-attaching the same document inserts a second row |

### `cancel_death_verification_case(p_case) → text`

| | |
|---|---|
| Authorization | `auth_required`; then **three** conditions, all required: case exists, `initiated_by = auth.uid()`, **and** `is_estate_executor(estate, uid)` still true |
| Preconditions | `status='open'`; `'cancelled'` returns unchanged; anything else → `case_already_decided` |
| Postconditions | `status='cancelled'`; lifecycle → **`active`**; the case row survives as history |
| Audit | `death_case.cancelled` |
| Notification | **NONE** |
| Idempotency | **Idempotent** — a replay returns `'cancelled'` with no re-stamp and no second audit row |

**The asymmetry worth naming.** 11-L established that a *revoked* designee is still **notified** when
their process halts, because a notification reports a fact. `cancel` goes the other way: a revoked
designee **cannot cancel**, because cancellation exercises authority. Both are correct, and they are
not in tension — but they mean a fiduciary whose designation is revoked while their case is open has
no exit of their own. See §2.

### Existing bindings, tests, mutations

- **Bindings:** none for all three. See Stage 4.
- **Tests:** `db/tests/death_verification_authorization.sql` — 12 references to initiation; the full
  actor matrix; cancel's initiator-only + idempotency assertions.
- **Mutations:** 7 already exist and are killed — `p11c-beneficiary-initiates`,
  `p11c-delegate-initiates`, `p11c-any-authenticated-initiates`,
  `p11c-initiation-activates-death-grants`, `p11c-evidence-activates-death-grants`,
  `p11c-refusal-leaks-evidence-count`, `p11c-notification-composes-evidence`.

## Stage 2 · The lifecycle state graph

Seven states, from the `check (state in (…))` constraint in migration 0055 — the source of truth.

```
                    ┌──────────────────────────── active ◄──────────────────────┐
                    │                               │                          │
                    │                    initiate (designee only)              │
                    │                               ▼                          │
                    │                  death_verification_pending              │
                    │                               │                          │
   admin decide 'reject' ────────────────────────────┤                          │
                    │        cancel (initiator + STILL-ACTIVE designation) ─────┘
                    │                               │
                    │                    admin decide 'verify'
                    │                               ▼
                    │                        death_verified
                    │                               │
                    │       dispatch_owner_safety_notice   ★ IRREVERSIBLE
                    │                               ▼
                    │                owner_notification_dispatched
                    │                               │
                    │          begin_challenge_window      ★ IRREVERSIBLE
                    │                               ▼
                    │                       challenge_window
                    │                               │
                    │   authorize_release (two-person, window strictly elapsed)  ★ IRREVERSIBLE
                    │                               ▼
                    │                          released  ■ TERMINAL
                    │
   owner challenge, from pending / verified / dispatched / window
                    └──────────────────────► challenge_halted  ■ TERMINAL
```

`attach_death_verification_evidence` causes **no transition** — the estate stays at
`death_verification_pending`.

| Class | States / transitions |
|---|---|
| **Reversible** | `initiate` (via `cancel`), `verify` (via `reject` → `active`) |
| **Irreversible** | `dispatch_owner_safety_notice` (commits an email row + in-app notice and stamps the challenge clock), `begin_challenge_window`, `authorize_release` |
| **Terminal / dead-end** | `released`; `challenge_halted` (deliberate in 11-E — nothing transitions out) |
| **Orphaned** | **none** — all seven states are reachable, and each has a defined exit except the two intentional terminals |

### Missing transitions

1. **No exit from `challenge_halted`.** Deliberate (11-E): the owner said no, and that is final.
2. **No fiduciary exit from `death_verification_pending` after their designation is revoked.**
   `cancel` requires an active designation, so the only resolutions left are operator `decide` or
   owner `challenge`. **This is the one real gap**, and it is not hypothetical: an owner who
   discovers a process and revokes the designee — the natural first move — locks that designee out
   of withdrawing it.
3. **No `attach` reversal.** No detach, no delete. Evidence attached in error is permanent.

## Stage 3 · `submit_claim_packet` — independently verified

Source evidence, both directions:

- `db/functions/submit_claim_packet.sql` contains **0** references to `death_verification*`.
- **No** claim routine references `death_verification_cases`.
- `death_verification.sql`'s only mention of `claim_packets` is a comment naming what it does *not*
  touch.
- `admin_decide_claim_packet` performs **no** `apply_estate_lifecycle_transition` and touches
  `estate_lifecycle` not at all.

**Verdict: not an integration point of any kind — no seam exists in either direction.** Of the three
offered labels, "abandoned contract" is the closest, but it is imprecise: there is no evidence a
contract ever existed to abandon. The accurate statement is that `claim_packets` and
`death_verification_cases` are **two independent systems that were never joined**. Approving a claim
starts no death process, and initiating a death case creates no claim. `submit_claim_packet` therefore
cannot substitute for the unbound initiation door.

## Stage 4 · Route census (mobile, non-test)

| Routine | Call sites | Classification |
|---|---|---|
| `initiate_death_verification_case` | `features/executor/model.ts:17`, `features/executor/wire.ts:168` | **COMMENT ONLY** ×2 |
| `attach_death_verification_evidence` | `features/executor/wire.ts:164` | **COMMENT ONLY** |
| `cancel_death_verification_case` | `features/executor/wire.ts:164` | **COMMENT ONLY** |
| `submit_claim_packet` | `features/claims/wiring.ts:39` | **EXECUTABLE BINDING** (`.rpc(...)`) |
| | 9 further sites | COMMENT ONLY |

**Zero executable bindings for all three doors.** Every hit that might suggest otherwise is prose in a
comment — the "a token match is not a usage match" rule, and this is the case that proves it.

## Stage 5 · The bounded design

`initiate` and `cancel` ship **together, as one slice**. 11-J's finding still applies and §2's gap
sharpens it: a fiduciary who can start a process they cannot withdraw creates state only an operator
or the owner can resolve. Evidence attach follows in a second slice (it needs a Vault document to
exist first, so it composes with a different feature).

Layering, matching the existing `features/executor/` shape:

| Layer | Responsibility |
|---|---|
| `wire.ts` | strict decode of the two payloads (a uuid; a status string). A decoder failure is `malformed`, **never** a refusal |
| `service.ts` | maps PostgREST errors to a closed union: `auth_required` \| `not_authorized` \| `lifecycle_conflict` \| `case_already_decided` \| `malformed` \| `unavailable` |
| `wiring.ts` | the injectable seam; the production default must be executed by at least one test, not only injected |
| `presentation.ts` | one state per outcome. **`unauthorized` ≠ `empty` ≠ `not_found` ≠ `error`** — four distinct renderings, never collapsed |
| screen | initiate action behind a confirm; cancel available only while `status='open'` **and** the viewer is the initiator **and** still designated |
| routing | inside `/executor`, which already re-checks its own authority on arrival |

**Disclosure firewall (Stage 9) must hold:** the two payloads are a uuid and a status. Nothing in
this slice may render owner identity, recipient addresses, reviewer or operator identity,
administrative notes, or any unbounded server text. Capacity must not become disclosure.

## Stage 6 · Authorization matrix — ALREADY EXECUTED

Against **real Postgres**, under `set role authenticated` with RLS enforced, in
`db/tests/death_verification_authorization.sql`. Full suite: **364 assertions, exit 0.**

Initiation — refused byte-identically across **8** causes:

| # | Actor |
|---|---|
| 1 | beneficiary |
| 2 | professional delegate without designation |
| 3 | non-member (stranger) |
| 4 | **owner WITHOUT designation** |
| 5 | **revoked designee** |
| 6 | foreign designee (cross-estate) |
| 7 | foreign owner |
| 8 | designee against a NONEXISTENT estate |

Plus, observed in the same run:

- `ok anonymous initiation refused (auth_required)`
- `ok denied initiations wrote no audit row and created no state`
- `ok executor designee initiates (the working case)`
- `ok trustee designee initiates; capacity recorded as fact; lifecycle pending`
- `ok cancel: initiator-only, restores lifecycle, idempotent replay writes nothing`
- `ok FIREWALL: initiation changed no composed payload and touched no grant row`
- `ok reject returns lifecycle to active; the estate can be re-initiated`
- `ok a revoked designation reports no capacity`

**Every actor the stage asked for is covered, executed, and green.** What is *not* covered is the same
matrix against the **deployed** database — see §8.

## Stage 7 · Notification census — ABSENCE, recorded not invented

| Routine | `emit_*` calls | Audit event |
|---|---|---|
| `initiate_death_verification_case` | **0** | `death_case.initiated` |
| `attach_death_verification_evidence` | **0** | `death_case.evidence_attached` |
| `cancel_death_verification_case` | **0** | `death_case.cancelled` |

The copy catalog contains exactly two death-domain events — `death_process.window_opened` (11-E) and
`death_process.halted` (11-L, undeployed). **There is no initiation or cancellation notification, and
none was invented here.** Whether the owner should be told a process has begun is a live product
question with a real argument on both sides, and it is not this slice's to answer.

## Stage 8 · Why implementation stops here

Two things are missing, and one of them is Christ's decision rather than an engineering step.

### There is no designated-executor fixture on the deployed database

Verified in this session through the product's authoritative resolver across all five E2E personas
and both operator identities — 11 estate contexts, positive control passed — every one answers
`get_executor_workspace.authorized = false`. **No identity we hold is an active designee**, so the
authorized branch of `initiate` and `cancel` cannot be exercised against the deployed backend by any
route, product or raw.

Consequences, stated plainly:

- **Stage 6 against deployed:** impossible. (Against real Postgres it is complete — §6.)
- **Stage 12 device evidence:** Detox is configured (`.detoxrc.js`, `e2e:ios`, `e2e:android`), but
  every run would render the *unauthorized* branch. The authorized path — the one that writes a case
  row and moves the lifecycle — would be **UNPROVEN** on both platforms.

That last point is why this stops rather than shipping. The `vaultWrite` precedent is exact: 3166
green tests, every injected seam passing, and **every** Add-document attempt broken on **every**
device, found by uploading one real file. Shipping a mutation door that starts a death process, with
its authorized path never once exercised against the real backend, is that failure class by
construction.

### The fixture is reachable — through product paths — and needs authorization

The chain exists and requires no SQL and no `service_role`:

1. **As an AAL2 admin** (both test operators qualify): `admin_create_executor_invitation` for a
   persona's email on a synthetic persona estate.
2. **As that persona**: `accept_invitation` → `provision_from_invitation` → an `active` executor
   designation, audited as `designation.created`.

**What this would do, said without softening:**

- It **creates production data** on the live database and **grants real fiduciary authority** over a
  synthetic estate. Revocable, and revocation is itself a matrix row worth exercising.
- Proving the round trip means **starting a death process** on that synthetic estate — `initiate`,
  then `cancel` back to `active`. The pair is reversible, and it stops well short of dispatch, window
  or release, all three of which are irreversible and none of which this slice touches.
- Every prior phase in this programme carried an explicit standing gate: *do not start a death
  process.* This prompt neither repeats it nor rescinds it, so I am treating it as still standing.

**Recommendation: authorize the fixture, then implement.** It is cheap, uses only product paths, is
confined to synthetic identities, and converts Stage 12's authorized branch from UNPROVEN to proven —
which is the difference between this slice meeting the project's evidence standard and merely looking
like it does.

**Stage 13 classification: `INCOMPLETE` — prerequisite not satisfied.** Not `BLOCKED`: nothing is
broken and no defect was found. Stages 0–7 are complete and green; Stages 8–12 are deliberately not
begun, because the prompt's own instruction is to stop and say why rather than partially implement.
