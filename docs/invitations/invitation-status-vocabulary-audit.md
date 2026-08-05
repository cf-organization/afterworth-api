# Invitation status-vocabulary audit

Branch `feature/invitation-status-vocabulary-audit`, baseline `b9f4e65`. Static audit only — no
migration is proposed, no database object was changed, and no behavioural harness was executed.

## Why this audit exists

0043 replaced the delivery-outbox status vocabulary wholesale. `revoke_estate_invitation` kept
0042's statement:

```sql
update public.invitation_delivery_outbox
   set status = 'failed', last_error = 'invitation_revoked'
 where invitation_id = v_inv.id and status = 'pending';
```

Both `'pending'` and `'failed'` had ceased to exist on that table. The predicate matched nothing, so
**revoking an invitation never cancelled its queued email, and nothing raised.** A `WHERE` clause
that matches zero rows is a successful statement. 0047 fixed it; this audit asks whether the same
mistake is anywhere else.

The defect is invisible to the obvious tool. `pending` is still perfectly valid — for
`invitations.status`. It is obsolete only for `invitation_delivery_outbox.status`. A repo-wide grep
for `'pending'` returns dozens of correct lines and buries the one that matters. It also flags
`storage_deletion_outbox`, a different table whose CHECK legitimately admits `('pending','purged',
'failed')`. **The audit is therefore column-aware: it classifies each statement by the table it
operates on and judges literals against that table's current constraint.**

Migrations are immutable, so 0042 still contains its original bodies verbatim. Only the last
`create or replace` of a function is deployed, so only that one is judged — otherwise every fix
would permanently fail its own audit.

## Authoritative vocabularies

| Column | Source | Values |
|---|---|---|
| `invitations.status` | `db/tables/invitations.sql` | `pending`, `matched`, `accepted`, `declined`, `expired`, `revoked` |
| `invitation_delivery_outbox.status` | 0043 CHECK (replaced 0042's) | `queued`, `processing`, `providerAccepted`, `outcomeUncertain`, `retryPending`, `failedPermanent`, `cancelled` |
| *(0042, obsolete on the outbox)* | superseded | `pending`, `issued`, `failed` |

`pending` appears in both the live invitation vocabulary and the obsolete outbox one. That overlap is
the entire reason a literal scan cannot work.

## Stage 3 — final-definition verdicts

Last `create or replace` wins. Every function that touches the outbox:

| Function | Final def | Verdict |
|---|---|---|
| `claim_invitation_deliveries` | 0043 | OK |
| `create_estate_invitation` | 0045 | OK |
| `invitation_delivery_health` | 0043 | OK |
| `issue_invitation_delivery_notice` | 0044 | OK |
| `issue_invitation_delivery_token` | 0043 | OK |
| `list_estate_invitations` | 0043 | OK |
| `record_invitation_delivery_outcome` | 0043 | OK |
| `request_invitation_redelivery` | 0042 | OK — see note |
| `revoke_estate_invitation` | 0047 | OK (was the defect) |
| `issue_invitation_delivery` | 0042 | **obsolete: `pending`, `issued`, `failed`** |
| `record_invitation_delivery_failure` | 0042 | **obsolete: `failed`** |

`request_invitation_redelivery` is a 0042 function that survived the vocabulary change untouched
because **it names no status literal at all** — it inserts and lets the column default apply, and
0043 repointed that default to `'queued'`. Depending on the default rather than restating it is what
made it immune.

## Stage 4 — delivery transition matrix

| From | To | By |
|---|---|---|
| *(insert)* | `queued` | `create_estate_invitation` / `request_invitation_redelivery`, via column default |
| `queued`, `retryPending` (due) | `processing` | `claim_invitation_deliveries` |
| `processing` | `providerAccepted`, `retryPending`, `outcomeUncertain`, `failedPermanent` | `record_invitation_delivery_outcome` |
| `retryPending` (attempt cap) | `failedPermanent` | same, escalation branch |
| `queued`, `retryPending` | `cancelled` | `revoke_estate_invitation` (0047) |
| `providerAccepted`, `cancelled` | *(frozen)* | outcome recorder returns early without mutating |

Two properties fall out of this that are worth stating explicitly:

**Revoke deliberately does not cancel `processing`.** Once the worker has claimed a row the send may
already be in flight; marking it `cancelled` would assert a recall that never happened. Leaving it to
resolve to its true outcome keeps the record honest.

**A late outcome cannot resurrect a revoked row.** The recorder returns early on `providerAccepted`
and `cancelled`, so a worker finishing after a revoke cannot overwrite the cancellation.

## Stage 5 — the claimable set agrees in all three places

| Location | Predicate |
|---|---|
| `invitation_delivery_outbox_claimable_idx` | `status in ('queued','retryPending')` |
| `claim_invitation_deliveries` | `'queued'` or `'retryPending'` past `next_attempt_at` |
| `revoke_estate_invitation` (0047) | `status in ('queued','retryPending')` |

This agreement is the substantive result. Revoke cancels **exactly** what is still claimable —
cancelling less would let a revoked invitation's email go out (the original defect); cancelling more
would rewrite delivery history.

No trigger, view, RLS policy, or generated column carries an outbox status literal.

## Stage 6/7 — API, worker, mobile

The worker calls `issue_invitation_delivery_notice` (0044) and `record_invitation_delivery_outcome`
(0043). No shipped TypeScript references either obsolete function.

`list_estate_invitations` collapses worker mechanics and passes honest outcomes through:
`queued`/`processing`/`retryPending` → `queued`; everything else unchanged; no outbox row → `none`.
The emitted set is therefore `none, queued, providerAccepted, outcomeUncertain, failedPermanent,
cancelled`.

Mobile `features/ownerInvitations/model.ts` decodes exactly those six and adds a fail-closed
`unrecognized` → "Delivery status unknown". `cancelled` reads "Delivery cancelled"; `providerAccepted`
reads "Email provider accepted", **not** "Delivered", which is correct because no provider webhook
exists to confirm delivery. No obsolete value is assumed anywhere. **No mobile change is required and
none was made.**

All three affordances (`can_revoke`, `can_extend`, `can_redeliver`) derive from *invitation* status,
not delivery status — which is why they go false together on revoke.

## Stage 10 — classification

**No active defect.** Nothing reachable can produce a wrong result today.

| # | Finding | Class |
|---|---|---|
| 1 | `issue_invitation_delivery` (0042) uses `pending`/`issued`/`failed` | **LATENT** |
| 2 | `record_invitation_delivery_failure` (0042) uses `failed` | **LATENT** |
| 3 | `invitation_delivery_outbox_unissued_idx` has an unsatisfiable predicate | **LATENT — dead weight** |
| 4 | 0042's original bodies contain the obsolete vocabulary | **HISTORICAL ONLY** |
| 5 | `storage_deletion_outbox` uses `pending`/`failed` | **FALSE POSITIVE** — different table, both legal |

**1 and 2 are latent, not active,** on three independent grounds: 0044 records both as "superseded,
kept, service_role only"; no caller exists in `lib/`, `api/`, or any other function; and both are
`service_role` only, so no client can reach them. Their failure mode is also loud rather than silent
— every obsolete write would violate 0043's CHECK constraint and raise. They are the opposite of the
0047 defect, which was silent precisely because it *read* an obsolete value instead of writing one.

**3** is `... where status = 'pending'`, created by 0042 and never dropped. Since 0043 removed
`pending` from the CHECK, the predicate is unsatisfiable and the index is permanently empty. It
cannot yield a wrong answer and writes skip it; the cost is a schema that implies a state the
database no longer accepts.

Dropping the index and the two superseded functions each require a migration, which requires
authorization. Per the audit's terms — no active defect means documentation only — **none is
proposed here.** All three are pinned by test instead, so they cannot drift further unnoticed.

## Stage 8 — the durable audit

`test/invitationStatusVocabulary.test.ts`, 23 tests. Companion to `plpgsqlShadowing.test.ts`, which
covers the unrelated 42702 OUT-variable class.

Required regression cases, all present: `WHERE status = 'pending'` on the outbox; `SET status =
'failed'`; an obsolete claimable state; a valid `queued`/`retryPending` predicate not flagged;
terminal states not flagged; **`pending` on `invitations` not flagged**; and final-definition
supersession. Two more earn their place from this audit: an obsolete value hidden behind a valid one
inside an `IN` list, and the real `storage_deletion_outbox` line that a naive grep misreports.

### The audit was verified by mutation, not by passing

A green audit proves nothing on its own — a scanner that finds nothing passes identically to one that
looks at nothing. Two probes were run and reverted:

1. **Exemption removed** → failed, naming both functions with their exact literals
   (`public.issue_invitation_delivery: pending,failed,issued`). The detector genuinely finds them;
   the exemption list is doing real work rather than masking a blind scan.
2. **A caller planted in `lib/`** → the reachability guard fired. Meanwhile the baseline stays green
   *while* `lib/invitations/delivery.ts:139` calls `issue_invitation_delivery_notice`, which proves
   the negative lookahead distinguishes it from the `issue_invitation_delivery` prefix rather than
   getting lucky.

The exemption in test 2 is guarded by the reachability check: the moment either function acquires a
caller in shipped code, the suite fails. The exemption cannot silently outlive its own justification.

## Stage 9 — behavioural harness design (NOT executed)

A static audit cannot prove a `WHERE` clause matches rows; that is exactly how the original defect
survived. The following is specified but **was not run**, as it mutates delivery rows:

1. Seed an invitation plus a `queued` outbox row, and a second unrelated invitation with its own
   queued row.
2. Revoke the first. Assert its row moves to `cancelled` **and the second row is untouched** —
   scoping, which a missing `invitation_id` predicate would break while still passing a row-count check.
3. Seed a `retryPending` row, revoke, assert `cancelled` — the arm the original `= 'pending'`
   predicate could never reach.
4. Seed `providerAccepted` and `failedPermanent` rows, revoke, assert both unchanged.
5. Assert the affected row count is non-zero at each step. **A zero-row update must fail the harness**
   — that is the assertion whose absence let 0047 ship.

Running it requires authorization and must use synthetic data in a transaction that rolls back.

## Verification

`npx vitest run` — 8 files, 138 tests, all passing (23 new). `tsc --noEmit` clean. `gitleaks` clean.
No migration written, no database object altered, no invitation sent, no worker run, no production
data touched, no mobile file modified.
