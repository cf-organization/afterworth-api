# Owner-notice backlog — census and settlement runbook

**Claude does not execute this.** Every destructive step here is an operator action requiring an
AAL2 admin session. This document exists so that if a backlog ever exists, the person clearing it has
a procedure rather than an instinct.

---

## 0 · The current state, derived rather than assumed

`dispatch_owner_safety_notice` is the **only** writer of `owner_notice_outbox` in the entire schema
— verified by grep across `db/migrations`, `db/functions` and `db/grants.sql`. It has no client
binding on any of the three clients, and `admin_require_gate()` refuses a Supabase SQL-editor session
because `auth.uid()` is NULL under the `postgres` role.

**So the table cannot hold a row produced by any product path.** The expected census is all zeroes,
and this runbook is a contingency, not a task.

## 1 · Census — read-only, always first

```sql
select public.owner_notice_census();
```

Requires an AAL2 admin session. Returns **counts only** — never a recipient address, never an estate
name. The `age_gate` field is computed live, so the actionable/stale split is against the gate in
force *now*, not a remembered one.

```json
{
  "total": 0, "by_status": {}, "age_gate": "8 days",
  "oldest_requested_at": null, "newest_requested_at": null,
  "actionable": 0, "stale": 0, "uncertain": 0, "purgeable": 0
}
```

**Reconciliation.** `actionable + stale + uncertain + purgeable` should account for every row in
`total` except rows in `processing` that are still inside the age gate (in flight this instant). A
gap larger than that means a status exists that no bucket names — investigate before acting.

## 2 · Classification

| Class | Census key | What it means | Action |
|---|---|---|---|
| **fresh** | `actionable` | `queued`, inside the age gate | **Leave.** The drain will send it. |
| **in flight** | — | `processing`, inside the gate | **Never touch.** A live safety message mid-send. |
| **stale** | `stale` | `queued`/`processing`, older than window + 1 day | Settled automatically on the next claim — see §3 |
| **uncertain** | `uncertain` | provider never answered | **Retain.** Terminal, never re-sent, deliberately not purgeable |
| **failed** | in `purgeable` | `failedPermanent` | Retain as evidence; purgeable once genuinely old |
| **already resolved** | in `purgeable` | `dispatched` | Purgeable once genuinely old |
| **cancelled** | in `purgeable` | `cancelled` | Purgeable once genuinely old |
| **deleted estate** | — | impossible: `estate_id` is `on delete cascade` | — |
| **unknown** | — | a status no bucket names | **STOP.** Investigate before any action. |

## 3 · Stale rows settle themselves — do not "clean them up"

The next `claim_owner_notices` call marks every row older than the age gate
`failedPermanent` / `stale_beyond_age_gate`, **before** claiming anything, and never hands it to a
sender. This is deliberate and it is not a failure to be corrected:

> Sending a notice three weeks late is worse than not sending it. The situation it describes has
> already resolved, and the message arrives as a false alarm about a window that closed, or a true
> alarm nobody can act on.

The row is retained as **the evidence that the owner was not reached in time** — which is exactly
what an operator investigating a disputed release will want. Deleting it destroys that evidence.

**Enabling the cron after a long outage therefore settles the backlog and sends nothing from it.**
That is the intended behaviour. If a genuinely fresh notice exists it will be sent; if all of them
are stale, the correct outcome is that none are sent and all are recorded as unreached.

## 4 · If rows must actually be removed

Only ever through `purge_outbox_rows`. Never a direct `delete`.

```sql
select public.purge_outbox_rows(
  'owner_notice_outbox',
  timestamptz '<explicit cutoff>',
  '<why, in a sentence a stranger could audit a year from now>'
);
```

What the routine guarantees, so the operator does not have to:

- **The audit row is written BEFORE the delete, in the same transaction.** A silent purge is
  impossible rather than discouraged. It carries the count and the age range removed.
- **A reason is required and cannot be blank.** "Cleaning up" is not a reason. The column exists so
  someone reconstructing a disputed release can tell a hygiene sweep from a deletion that removed the
  evidence of an owner who was never reached.
- **It refuses to touch actionable rows.** `queued` and `processing` are live safety messages; only
  `dispatched` / `failedPermanent` / `cancelled` are purgeable.
- **`outcomeUncertain` is NOT purgeable** — deliberately. It is the row a disputed release turns on.
- **An unknown outbox name is refused** rather than resolved dynamically.
- It returns `0` and writes no audit row when nothing matches — an audit of a no-op is noise.

### Before running it

1. Run the census and **record the numbers in the change record**.
2. Confirm the cutoff excludes anything you would want during an investigation.
3. Write the reason first. If it cannot be written, do not purge.
4. Re-run the census afterwards and confirm the delta matches the returned count.

## 5 · What is never acceptable

- Deleting rows directly. It bypasses the audit that makes the deletion reconstructible.
- Purging to make a dashboard tidy. These rows are about whether a living person was warned that a
  process was running to release their estate.
- Re-queueing a stale row to "give it another chance". The age gate is the decision, made once and
  recorded; re-queueing re-decides it in a mail queue, which is a second release authority hiding
  where nobody will look for one.
- Flushing a backlog by disabling the age gate. A shortened or removed gate means historical mail
  goes out to living owners about processes that have already concluded.
