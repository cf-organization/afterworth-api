# Phase 11-OB / 11-OBR — the owner-notice delivery path

**STATUS: OB-1 + OB-4 IMPLEMENTATION_COMPLETE · DEPLOYMENT_REQUIRED. OB-2 DECISION_REQUIRED.**

Claude does not execute production SQL. Branch B remains **NOT STARTED — GATE CLOSED**.

---

## 1 · Production evidence

The Branch A owner-safety notice was observed read-only on 2026-08-16T20:19:32Z, **16.3 hours after
its first scheduled drain opportunity** (`0 4 * * *` UTC; the notice was enqueued at 06:46:18Z on
2026-08-15, after that day's run):

| Field | Value |
|---|---|
| outbox row | `7ec99457-38af-4e2c-b2eb-eca771fe7d5e` |
| status | **`processing`** |
| attempts | **1** |
| requested_at | `2026-08-15T06:46:18.161913Z` |
| dispatched_at | `null` |
| failure_class | `null` |
| provider_result | `null` |

Classification: **`T2_UNVERIFIABLE` — `claimed_but_unsettled`.**

Not `T2_DRAIN_DID_NOT_RUN`: the drain demonstrably ran. It moved the row `queued → processing` and
incremented `attempts` 0 → 1. It then never settled it.

## 2 · OB-4 — the root cause (HIGH)

**`record_owner_notice_outcome` has never been able to settle a single notice.**

Its final statement writes an audit row with `source = 'worker'` — a deliberate 11-K choice,
documented there: the actor is a scheduled worker, not a person, so `actor_id` is NULL and the source
says so rather than inventing a synthetic operator identity.

`audit_logs_source_check` has admitted `('server', 'ios_forward', 'admin')` since migration 0014 and
**was never widened**. `'worker'` is written in exactly one place and appears in no migration.

So the insert raises `check_violation` on **every** call. `recordOutcome` in
`lib/ownerNotices/drain.ts` catches the RPC error, logs the code, and returns — so the row is left
exactly where the claim put it.

That is the Branch A row, precisely. **The claim was never the problem; the settle was**, and it has
been totally broken since 11-K wired the cron.

**The email itself is sent BEFORE the settle**, so the owner may well have received it. The system
simply cannot record that it did — which is why T2 is unverifiable rather than failed.

This was found by the test harness, not by inspection: `preamble_real_auth.sql` mirrors the
production constraint verbatim, so the suite reproduced the production failure exactly.

## 3 · OB-1 — the strand (HIGH)

`claim_owner_notices` selected `where o.status = 'queued'` only. A row in `processing` was therefore
never handed out again by any drain. Its only remaining transition was the stale sweep, which marks
it `failedPermanent` once past the age gate (`challenge_window + 1 day` = 8 days) — **a day after the
7-day release window it exists to protect has already elapsed.**

The enabling cause is structural: `owner_notice_outbox` had **no claim timestamp**. `requested_at`
does not move on claim and `attempts` is a counter with no clock. **You cannot time out a claim you
never timestamped.**

**OB-1 and OB-4 are inseparable.** A visibility timeout alone makes an unsettleable row reclaimable,
and a reclaimed row is sent again and still cannot be settled — a daily resend loop running until the
age gate, turning one silently lost notice into eight days of repeated mail to a living owner about
their own death process. Fixing the reclaim without fixing the settle is strictly worse than fixing
neither. They ship in one artifact.

## 4 · OB-3 — the swallowed settle failure (MEDIUM, NOT fixed here)

`recordOutcome` logs `console.error("record_owner_notice_outcome error:", error.code)` and returns.
No retry, no escalation. This is what converted OB-4 from a loud, immediate failure into a year of
silence.

**Deliberately left as a bounded follow-up.** With OB-4 fixed the swallow no longer fires on the
common path, and with OB-1 fixed a swallowed failure is now *recoverable* rather than terminal — the
next drain reclaims the row. Adding retry logic in the same change would have made the artifact both
a schema migration and a worker-behaviour change, and the worker half needs its own deploy and its
own failure-injection tests. Recorded, scoped, not silently skipped.

## 5 · The remediation

**Migration `0057_20260816_owner_notice_claim_visibility.sql`**

1. `owner_notice_outbox.claimed_at timestamptz` — nullable, permanently. NULL means "never claimed"
   or "claimed before this column existed". **Never backfilled**: a guessed claim time defeats the
   column whose purpose is to stop guessing.
2. A partial index on `(requested_at) where status = 'processing'`, matching the reclaim predicate.
3. `audit_logs_source_check` widened to admit `'worker'` (OB-4). The value is server-stamped inside a
   DEFINER routine, never a client parameter — the same property that justified admitting `'admin'`
   in 0014.

The migration verifies itself, and the OB-4 check is **by execution**: it INSERTs a worker-sourced
row and catches `check_violation`, because a constraint that merely *mentions* `'worker'` is not
proof the value is storable — and this whole defect existed because nobody ever tried.

It also asserts `authorize_release` still carries the OB-2 precondition, so **OB-1 cannot silently
implement OB-2**.

**`claim_owner_notices`** now claims a closed, named set:

```
A · queued            — subject to its backoff. Unchanged.
B · processing, stale — claimed_at IS NULL, or older than the visibility timeout.
```

Every other status is excluded **by name**, never by a `status <> terminal` predicate: `dispatched`
and `outcomeUncertain` are terminal precisely because the message may already be in the owner's
inbox, and a broad "not terminal" test is how a future status added to the CHECK would silently
become re-sendable.

`claimed_at = now()` is stamped on **every** claim, first or repeat, so the timeout runs from *this*
claim.

**The visibility timeout is one hour**, derived rather than chosen: the provider request timeout is
10s (`REQUEST_TIMEOUT_MS`), retried at most once, so a row legitimately occupies a worker for ~20s;
the serverless execution ceiling is at most 300s. One hour is 12× the highest possible platform
ceiling and ~180× the real per-row cost — a row still `processing` an hour later is not slow, it is
abandoned. It is far inside the 8-day age gate, so every daily drain remains a recovery opportunity.

It lives in `owner_notice_claim_visibility()` so the claim routine and the census cannot disagree
about what is stale. Not a policy table: the challenge window is a product decision an operator must
be able to state; this is an operational property of this worker whose only failure mode is being set
below the platform ceiling.

**`legacy processing + claimed_at IS NULL` is reclaimable, and that is a decision.** Such a row was
claimed before the column existed, so it has been stuck since at least deployment — already far
beyond any timeout. It is a **class rule; no row is named.**

**`owner_notice_census`** gains `processing_total`, `processing_stale`, `oldest_processing_age`.
`processing_stale` uses the same predicate the drain reclaims by, read from the shared function, so
it is exactly "rows the next drain will pick up" rather than an approximation.

## 6 · Delivery semantics

**`DELIVERY SEMANTICS: AT_LEAST_ONCE.`**

A reclaimed row is re-sent under the **same** deterministic key —
`afterworth/owner-notice/<row id>`, built in `drain.ts` from the row id with no generation counter —
transmitted as the `Idempotency-Key` HTTP header (`lib/email/resendProvider.ts:127`). So a reclaim
asks the provider to no-op a repeat. This is the same operation the worker **already** performs when
it retries an ambiguous first attempt: it replays a message, it does not re-mint one.

**This is mitigation, not exactly-once, and the repository already says so.** The provider comment
calls the key *"defence in depth, not the primary guard"*, and the provider's dedupe **retention
window is a vendor property this repository does not pin anywhere**. A reclaim landing outside that
window could produce a second copy.

**Per the stage instruction, this sub-decision is reported rather than guessed:** confirming the
retention window requires current provider documentation. Until it is confirmed and pinned, the
duplicate risk is bounded by the daily cron cadence — at most one replay per day per stranded row,
for at most 8 days — and by the fact that with OB-4 fixed, rows settle on the first attempt and
reclaim becomes the exception rather than the rule.

## 7 · Test matrix

`db/tests/release_safety_authorization.sql` §9, against a real Postgres. Claim age is moved by ageing
`claimed_at`, the deterministic equivalent of waiting — `now()` is transaction-constant, so a test
that did not move the clock could not distinguish inside the timeout from outside it.

| # | Case | Result |
|---|---|---|
| — | CONTROL: `claimed_at` exists | ✅ |
| 1 | a queued row is claimed, stamped, `attempts = 1` | ✅ |
| 2 | a freshly claimed row is NOT reclaimed | ✅ |
| 3 | just inside the timeout is NOT reclaimed | ✅ |
| 4 | **exactly at the boundary is NOT reclaimed** (strict `<`, asserted not assumed) | ✅ |
| 5/6/7 | past the timeout IS reclaimed; attempts increments; `claimed_at` refreshes | ✅ |
| 14 | legacy `processing` + NULL `claimed_at` IS reclaimed | ✅ |
| 10/11/12 | `dispatched` / `outcomeUncertain` / `failedPermanent` / `cancelled` never reclaimed | ✅ |
| 9 | the age gate still beats the reclaim (stale, not re-sent) | ✅ |
| 13 | an unrelated estate's in-flight row is untouched | ✅ |
| **6** | **CRASH WINDOW** — claim → worker dies → clock advances → later drain recovers and settles | ✅ |
| — | OB-4: the settle writes a worker-sourced audit row, `actor_id` NULL | ✅ |
| 10 | census separates stale claims from live ones; no address in the projection | ✅ |

**Case 8 (concurrency) is stated honestly rather than overclaimed.** `for update skip locked` is what
stops two simultaneous drains taking one row, and a single psql session cannot hold two concurrent
transactions to prove it. What *is* proved is the property that makes the race rare — a claim
refreshes `claimed_at`, so a second drain arriving immediately finds nothing eligible (case 2). The
`skip locked` clause itself is asserted structurally by the deployment verifiers.

**The census fixture is deliberately non-zero** — one stale claim and one live one, with a
discrimination control requiring `stale < total`. A census reporting `processing_stale: 0` on a
database with nothing stuck is indistinguishable from one that cannot count, and "nothing is stuck"
is exactly the false reassurance this defect hid behind.

## 8 · Mutation evidence

Eight new mutations, all **DETECTED** by the runtime SQL suite, each in a throwaway worktree with the
primary checkout verified byte-identical afterwards.

| id | injection |
|---|---|
| `p11obr-reclaim-removed` | **the production defect** — queued-only claim restored |
| `p11obr-claimed-at-not-stamped` | the claim clock never starts |
| `p11obr-timeout-predicate-removed` | every `processing` row reclaimable immediately |
| `p11obr-timeout-direction-reversed` | `<` → `>` (fresh reclaimed, abandoned stranded) |
| `p11obr-attempts-not-incremented` | the retry cap can never be reached |
| `p11obr-settled-row-reclaimed` | terminal states admitted to the claim set |
| `p11obr-audit-source-narrowed` | **OB-4 restored** — caught by 0057's execution probe |
| `p11obr-settle-audit-source-unwritable` | **OB-4 by a route the migration cannot see** |

The last pair is deliberate. Narrowing the constraint is caught by the migration's own probe, which
fires at load time and would stop §9 from ever running — one defensive layer taking credit for
another. So the second mutation reaches the identical defect by changing the value the *settle*
writes (`'worker'` → `'cron'`): the constraint keeps all four values, 0057's probe still passes, and
**§9's runtime assertion is the sole voter.**

No build or static audit is the only voter for any mutation here. No control in
`buildOwnerNoticeClaimVisibilityBundle.mjs` pins the timeout value, the reclaim predicate, or the
`claimed_at` stamp.

**And that list had to be corrected, which is worth recording rather than quietly fixing.** Its first
draft pinned the two `claim_owner_notices` privilege statements, on the reasoning — written in a
comment — that "no mutation edits them". Two do. `p11k-worker-pair-client-reachable` and
`p11e-release-lever-granted-to-clients` both flipped from DETECTED to **HARNESS_FAILURE**: the
builder refused the mutated input, so Postgres never saw the widened grant and nothing proved the
suite still catches a client-reachable worker routine. The needles were removed; both are DETECTED
again; the bundle bytes are unchanged, because controls gate the build and not the output. This is
the sixth time this programme has put a build control in front of a runtime one, and the third time
it happened directly underneath a comment warning against it.

## 9 · OB-2 decision packet (ANALYSIS ONLY — not implemented)

`authorize_release` currently accepts the owner-reachability precondition if **any** email row exists
with `status <> 'cancelled'`.

### What each status actually proves

| status at release | request existed | worker attempted | provider accepted | **actual delivery** | known failure | admitted today? |
|---|---|---|---|---|---|---|
| `queued` | ✅ | ❌ | ❌ | ❌ | ❌ | **✅ admitted** |
| `processing` | ✅ | ✅ | ❓ | ❓ | ❌ | **✅ admitted** |
| `dispatched` | ✅ | ✅ | ✅ | ❓ | ❌ | ✅ admitted |
| `outcomeUncertain` | ✅ | ✅ | ❓ | ❓ | ❌ | ✅ admitted |
| `failedPermanent` | ✅ | ✅ | ❌ | ❌ | ✅ | **✅ admitted** |
| `cancelled` | ✅ | — | ❌ | ❌ | — | ❌ refused |

**No status proves actual delivery.** There is no provider message id stored, no delivery webhook and
no `delivered_at` column, so `dispatched` means the provider accepted the message and nothing more.

The three bolded rows are the finding: **an estate whose notice was never sent (`queued`), never
settled (`processing`), or definitively failed (`failedPermanent`) still passes the guard.** The
precondition is satisfied by an *artifact* rather than by the *property* — structurally the same
shape as FINDING 4.

### Candidates

| | Policy | False-release risk | Availability impact | Provider-outage behaviour |
|---|---|---|---|---|
| **A** | `dispatched` only | Lowest of the implementable options | Release blocks whenever the provider never accepted | Outage → releases stall until the queue drains |
| **B** | `dispatched` + `outcomeUncertain` | Admits "we genuinely do not know" | Fewer stalls | Lost HTTP responses do not block release |
| **C** | a future `delivered` state | Lowest in principle | **Not implementable today** — needs a provider webhook, a `delivered_at` column and a new ingest surface | n/a |
| **D** | a separately attested delivery fact | Strongest evidence | Requires a human in every release | n/a |

### Interaction with the seven-day window

The window is stamped at **dispatch**, not delivery. Branch A measured the window opening **2.2
seconds** after enqueue against an email that had not been sent. Under today's guard the full seven
days can elapse and a release can be authorized while the notice sits `processing` — which is exactly
the state the Branch A row is in now. Tightening the precondition without also deciding *when the
clock starts* leaves that gap open.

### Recommendation

**A product decision is still required — but not on the whole question.** One part is not a judgement
call and should be settled now:

> **`queued` and `failedPermanent` must not satisfy the owner-reachability precondition.** Neither is
> ambiguous: one means the notice was never sent, the other means sending definitively failed. Both
> are currently admitted, and neither can be defended as "the owner was independently reachable".

The genuinely contested part is `processing` and `outcomeUncertain` — "we do not know whether it
arrived" — and that is where **Policy A vs Policy B** must be decided by product, because it trades a
false-release risk against release availability during a provider outage. My recommendation is
**Policy B (`dispatched` + `outcomeUncertain`)** *combined with* the clock change: start the
challenge window at the first successful **dispatch** rather than at enqueue. B alone permits release
on an unknown outcome; B plus a delivery-anchored clock means the owner's seven days begin only once
the provider has actually taken the message, which is the protection the window was designed to give.

Policy C is the right long-term answer and is **not implementable today**: it needs a webhook, a
`delivered_at` column, and an ingest surface that does not exist. Recording it as the target rather
than pretending it is available.

**Not implemented in this artifact.** Migration 0057 asserts the precondition is unchanged.

## 10 · Deployment

**Claude does not paste production SQL.**

```
bundle:  db/bundles/owner_notice_claim_visibility_bundle.sql
sha256:  a3826c4819bbebaeb72446b6fae937f80006a080ba53c411476f81749a450b50
size:    46,150 bytes
parts:   db/migrations/0057_20260816_owner_notice_claim_visibility.sql
         db/functions/outbox_safety.sql
```

Pure SQL, no meta-commands, one explicit transaction, deterministic (rebuilt twice byte-identical).
Atomicity proven by execution against a throwaway Postgres — and unlike its recent neighbours this
artifact produces a **real state delta** (`applies=true rollback=true`), because `claimed_at` does not
exist at baseline.

**Re-paste safe.** `add column if not exists`, `create index if not exists`, `drop constraint if
exists` + `add constraint`, and `create or replace` throughout.

**Safe intermediate state: none exists** — one transaction, so the artifact applies whole or changes
nothing.

**Rollback.** Re-paste the bundle built from the parent commit. Note the asymmetry: rolling back the
routine restores the strand, and rolling back the constraint restores the total settle failure. The
`claimed_at` column can be left in place harmlessly — it is additive and nullable, and dropping it is
neither required nor recommended.

## 11 · The forensic row after deployment

**Current state, recorded one final time before deployment:** `processing`, `attempts = 1`,
`dispatched_at = null`, `failure_class = null`, `claimed_at` will be NULL after migration (never
backfilled).

**What should happen, by the deployed mechanism and nothing else:** the row is `processing` with
`claimed_at IS NULL`, which the reclaim contract treats as infinitely stale. The **next scheduled
drain** (`0 4 * * *`) should therefore reclaim it, re-send under the same idempotency key, and — with
OB-4 fixed — settle it to `dispatched`.

**That is not a manual repair. It is the deployed recovery mechanism operating on the exact defect it
was built for, and it is the production proof for OB-1 + OB-4.**

**Do not trigger the drain. Do not use `CRON_SECRET`. Do not touch the row.** Let the scheduled worker
exercise the recovery, then observe read-only with
`node scripts/observeOwnerNoticeDelivery.mjs --case=50391819-bfc4-42da-b6fd-dac34d6d6758`.

If it settles to `dispatched`, T2 becomes classifiable for the first time — though note that
`dispatched` is provider acceptance, **not** inbox arrival, so `T2_DELIVERED` still requires the
out-of-band human attestation the observer demands.

## 12 · Branch B gate

**Branch B remains NOT STARTED — GATE CLOSED**, and this artifact does not open it. Before Branch B
may be reconsidered:

1. this artifact deployed and verified;
2. the forensic row's recovery observed through the scheduled worker;
3. an explicit **OB-2 decision**, because Branch B's B2 gate is an operational rule while the product
   still permits release on a notice that was never delivered.
