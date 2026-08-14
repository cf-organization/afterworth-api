# Phase 11-L — fiduciary door census and fire-drill readiness

**THE DRILL WAS NOT RUN. No death process was started, no notice dispatched, no window opened, no
release authorized.** This is a readiness assessment.

> ## TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE
>
> Two synthetic AAL2 admin accounts, one holder. Distinct-account mechanics only.
> **Production customer release requires TWO DISTINCT HUMAN OPERATORS.**

---

## 1 · The fiduciary mutation doors

Re-derived from source. Binding counts exclude test files.

| Routine | Authorized actor | AAL | Mobile | Admin | Reversible? | Lifecycle transition |
|---|---|---|---|---|---|---|
| `initiate_death_verification_case(estate)` | active executor **or** trustee designee | aal1 | **NONE** | none | yes — `cancel` | `active` → `death_verification_pending` |
| `attach_death_verification_evidence(case, doc)` | the same designee, case must be `open` | aal1 | **NONE** | none | no delete path | none |
| `cancel_death_verification_case(case)` | the same designee, case must be `open` | aal1 | **NONE** | none | terminal | → `active` |
| `submit_claim_packet(...)` | claimant | aal1 | **BOUND** | none | admin decide | none — separate table |

**All four are granted to `authenticated` and none is admin-gated.** They are reachable; they are
unbound. An AAL2 operator cannot substitute — the gate is `is_estate_executor`, a designation, not a
privilege.

### The three initiation doors have no client binding anywhere — confirmed, not assumed

A grep for the routine names finds three mobile hits, and **all three are comments**:
`features/executor/wire.ts:164`, `:168` and `features/executor/model.ts:17`. Zero `.rpc()` calls. A
token match is not a usage match, and this is the case that proves it.

### `submit_claim_packet` is genuinely bound and does NOT help

It is a real call (`features/claims/wiring.ts:39`), but it writes `public.claim_packets` and has **no
link to `death_verification_cases`**. `admin_decide_claim_packet` does not create a death case either.
The claim path and the death-verification path are separate systems; approving a claim starts no
death process. So the bound door cannot stand in for the unbound one.

### Side effects and abandonment

- **initiate** — inserts one case, transitions the lifecycle, writes a `high` audit row. A partial
  unique index (`death_verification_cases_one_open_per_estate`) permits exactly one open case per
  estate, so a second attempt raises `lifecycle_conflict` rather than duplicating.
- **attach** — inserts an evidence row referencing an existing document; refuses a document outside
  the estate (`doc_not_in_estate`). **No detach or delete path exists.** Abandoning mid-flow leaves
  evidence attached to an open case, which is inert but permanent.
- **cancel** — idempotent (`cancelled` returns unchanged), refuses a decided case, and **returns the
  lifecycle to `active`**. This is the round trip that matters.
- **Abandon mid-flow generally**: the case stays `open` and the estate stays
  `death_verification_pending` indefinitely. No timeout, no sweeper. It blocks a second initiation
  until someone resolves it.

## 2 · Is the 11-J trap closed?

11-J's trap: *a user must not be able to create a state no operator path can later resolve.*

An open case at `death_verification_pending` now has **three** resolutions, and two are bound:

| Resolution | Routine | Bound where |
|---|---|---|
| Operator verifies or rejects | `admin_decide_death_verification_case` | **admin console** `/cases/[id]` |
| Owner halts | `challenge_death_process` | **mobile** `/challenge` |
| Initiator withdraws | `cancel_death_verification_case` | nowhere |

**The trap is closed on the operator side — that is what 11-K bought.** It is also *vacuously* closed
today, because nothing can create the state in the first place. It becomes a live property the moment
initiation is bound, and at that point the operator console can already resolve every case a
fiduciary can open.

**The remaining gap is the fiduciary's own exit.** A designee who opens a case by mistake cannot
withdraw it; only an operator or the owner can end it. That is a dignity and support-load problem
rather than a stuck-state problem — recorded, not solved.

## 3 · Can the fire drill be completed through existing surfaces?

**No.** Step 2 (initiation) has no client on any surface, and it cannot be reached by raw RPC either
with any credential we hold.

Probed through the product's authoritative resolver (`POST /api/invitations/resolve`) for all five
E2E personas and both operator identities — 11 estate contexts, positive control passed:

```
every persona × every resolved estate → get_executor_workspace.authorized = false
```

**No held identity is an active executor or trustee designee.** So initiation is unreachable by
product path *and* by raw PostgREST. Creating a designee requires a write to
`estate_designations`, which needs either the owner's designation flow (no binding for this) or a
human running SQL — `service_role` holds no grant on that table.

> An earlier version of this probe read `public.estates` directly and reported "0 estates" for every
> persona, including one that provably owns one. `authenticated` has no direct SELECT on `estates`;
> the instrument was blind and its conclusion void. Recorded because the corrected answer happens to
> agree, and agreement is not evidence.

## 4 · Jurisdiction / enhanced_kyc (B4)

`required_verification_level(estate)` computes a floor then escalates:

1. **Jurisdiction floor** — `jurisdiction_policy` where `is_counsel_approved = true`. Unmapped *or*
   unapproved → **`enhanced_kyc`**, structurally fail-closed.
2. **Escalation factors** — estate value tiers etc. Each can only *raise* the level.

`jurisdiction_policy` is empty, so every estate requires `enhanced_kyc`. **This is a safe default
working as designed, and it must not be weakened.**

### Can an operator legitimately satisfy `enhanced_kyc` by hand?

**Yes, and that is the intended workflow — not a loophole.** The console carries the two acts as
separate, separately-audited doors:

1. `admin_review_death_evidence` — records the platform's review of one evidence item. **Moves no
   verification level**, by design.
2. `admin_set_attained_verification_level` — the **only** writer of `attained_level`. An operator
   asserts `enhanced_kyc` with a written basis.
3. `admin_decide_death_verification_case('verify')` — refuses unless `attained >= the LIVE
   requirement`, re-derived at decision time rather than read from the case's snapshot.

So an operator can reach `death_verified` under `enhanced_kyc` today, through bound doors, with an
audit trail naming who asserted what and why.

### The two questions kept apart

- **FIRE-DRILL TECHNICAL FEASIBILITY — SATISFIABLE.** A synthetic drill can legitimately exercise the
  `enhanced_kyc` path end to end. The requirement is not a technical blocker and must not be reported
  as one.
- **PRODUCTION JURISDICTION READINESS — BLOCKED, COUNSEL.** For a real customer, an operator
  hand-asserting `enhanced_kyc` with no counsel-approved `jurisdiction_policy` row means the platform
  is deciding what a jurisdiction requires. That is a legal determination, not an engineering one.
  **Counsel approval is required before real customer use.**

## 5 · Fire-drill readiness matrix

| # | Step | Classification | Note |
|---|---|---|---|
| 1 | Synthetic fiduciary designation | **MISSING BINDING** | no owner-facing designation flow; needs SQL or a binding |
| 2 | Initiation | **MISSING BINDING** | the blocker — see §3 |
| 3 | Evidence attach | **MISSING BINDING** | also needs a document in the estate first |
| 4 | Operator review | **ADMIN PATH READY** | `/cases/[id]` |
| 5 | Attained verification level | **ADMIN PATH READY** | `/cases/[id]` |
| 6 | Death verification (decide) | **ADMIN PATH READY** | re-derives the live requirement |
| 7 | Owner notice dispatch | **ADMIN PATH READY** · **IRREVERSIBLE** | commits email + in-app, stamps the challenge clock |
| 8a | Owner challenge / halt | **PRODUCT PATH READY** | mobile `/challenge`; 11-L adds the fiduciary notification |
| 8b | Uninterrupted path | **CALENDAR-BOUND** | requires the full challenge window to elapse |
| 9 | Challenge window open | **ADMIN PATH READY** · **IRREVERSIBLE** | only legal input is `owner_notification_dispatched` |
| 10 | Reviewer A | **ADMIN PATH READY** | derived server-side from the verified case's decider |
| 11 | Reviewer B | **ADMIN PATH READY** | second distinct AAL2 identity exists (test mode) |
| 12 | Release | **ADMIN PATH READY** · **IRREVERSIBLE** | two-person; window must be strictly elapsed |
| 13 | Survivor rendering | **PRODUCT PATH READY** | 11-G |
| 14 | Executor rendering | **PRODUCT PATH READY** | 11-I `/executor` |
| 15 | Notification outcomes | **PRODUCT DECISION** partly | halt→initiator approved and built (11-L, undeployed); release→grantees deferred |

**Email delivery is `EXTERNAL` + `CALENDAR-BOUND`:** Vercel Hobby cron is daily, so an owner notice
can wait ~24h for the drain.

## 6 · Decision

**B — one bounded fiduciary initiation slice remains.**

Steps 4–14 are ready through bound surfaces. The drill is blocked at steps 1–3, and the minimum work
is a client binding, ranked:

1. **Required to start** — `initiate_death_verification_case`, plus a way for a designation to exist.
   The designation is the deeper gap: nothing binds it either.
2. **Required for evidence** — `attach_death_verification_evidence` (needs an existing estate document,
   so it composes with the Vault).
3. **Required to cancel safely** — `cancel_death_verification_case`. **Ship this in the same slice as
   (1).** Binding initiation without cancellation is precisely the 11-J shape from the user's side: a
   fiduciary could open a case and have no way out, needing an operator for a mistake they could undo
   themselves.
4. **Optional convenience** — richer evidence management, detach.

Not A: initiation is unreachable. Not C: jurisdiction blocks *production*, not the drill. Not D: no
operational defect was found in the deployed operator path — both verifiers pass and the census,
queue and case file all work through the real AAL2 product path.

## 7 · What this phase delivered toward it

The approved halt→initiator notification, built and mutation-tested — `SOURCE_ONLY`,
**DEPLOYMENT_REQUIRED**, see `docs/phase11l-halt-notification.md`. It matters for the drill because
step 8a currently tells the fiduciary nothing: their process stops and the product goes silent.
