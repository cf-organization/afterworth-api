# Phase 11-MF — the cancel handle, and the advisory list that over-promised

**Status: SOURCE COMPLETE · DEPLOYMENT_REQUIRED.** Claude does not deploy. Christ pastes the bundle.

**Bundle:** `db/bundles/executor_workspace_bundle.sql`
**SHA256:** `15623877658ddbe76ff006a2c3603a0dfb0e7a375cfdba8dfa310bc632618863`

---

## 1 · Two defects, one root

`get_executor_workspace` answered questions about a verification case without ever naming it.

### Defect A — cancellation was unreachable from any read

`cancel_death_verification_case(p_case uuid)` takes a **case** id. The only routine that ever handed a
fiduciary one was `initiate_death_verification_case`, as its return value. Every read surface omitted it:

- the workspace's case `select` did not include `c.id`
- no other routine granted to `authenticated` returns a case id to a fiduciary
  (`get_owner_safety_status` is owner-only and returns none; `operator_console` is admin-gated)

So the handle existed for exactly as long as the client process that received it. An initiator who
restarted the app, force-quit, crashed, ran out of memory, or picked up a second device could **never
cancel the process they had started**, and no product path could recover the id.

That is initiation without cancellation from the user's side — the shape Phase 11-L already named as the
reason to bind `initiate` and `cancel` together.

### Defect B — the advisory list promised a cancel the door refuses

The two open-case actions were emitted as one literal:

```sql
if v_case_state = 'open' then
  v_actions := v_actions || '["attach_evidence","cancel_verification"]'::jsonb;
end if;
```

They do not share a gate:

| action | gate |
|---|---|
| `attach_death_verification_evidence` | `is_estate_executor` + case open — **any** active executor |
| `cancel_death_verification_case` | `is_estate_executor` + `initiated_by = auth.uid()` — **the initiator** |

So a co-fiduciary who did not start the process was offered a cancel that answers `not_authorized`.
The function's own header claimed the list "cannot promise something the door would refuse" — that
sentence was false for exactly one entry, and the entry it was false for is the destructive one.

A list that over-promises is worse than no list: a client that trusts it renders a control that always
fails, and a client that distrusts it has no reason to consult it at all.

## 2 · The correction

Three changes inside the already-authorized branch. No new routine, no grant change, no DDL.

1. **Select the handle and the caller-scoped fact.**
   `c.id as case_id, (c.initiated_by = v_uid) as is_initiator`.
   The uid is **compared and discarded** — the replaced comment said "Identity of the initiator is NOT
   selected", and that instinct was right. `is_initiator` answers *"did you start this"*, never *"who
   did"*.

2. **Scope the handle to the one caller who can use it.**
   `'case_id', case when v_is_initiator then v_case.case_id else null end`.
   A co-fiduciary already learns the case's state, level and timestamps here, so the uuid carries no
   further estate content — but they cannot cancel, so handing them the handle would serve nothing.
   `attach_evidence` is an any-executor action that will need this id too; extending it is a deliberate
   decision for the phase that binds attach, **not** a default granted in advance.

3. **Split the advisory entries onto their real gates.** `attach_evidence` on case-open;
   `cancel_verification` on case-open **and** `v_is_initiator`.

`v_is_initiator boolean := false` and `coalesce(v_case.is_initiator, false)` — no case means not the
initiator. Absence must never read as authority.

## 3 · What is proven

`db/tests/death_verification_authorization.sql` §11-MF — **8 assertions**, executed against real
Postgres under role `authenticated`. Suite total **398** (was 390).

The fixture is **two active executors on one estate**, which is the state the old code could not
distinguish. With one executor the initiator *is* every executor and every assertion below is vacuous.

| | |
|---|---|
| CONTROL | the loaded body contains `v_is_initiator`, else the run is about the wrong routine |
| A | no case ⇒ `case_id` null, `is_initiator` false, no cancel offer — **with a positive control** that `initiate_verification` IS offered, so the absences are not an unread array |
| B | initiator ⇒ `case_id` equals the initiated case, `is_initiator` true, cancel **and** attach offered |
| C | co-executor ⇒ attach offered, cancel **not** offered, no handle, **and case state still visible** (so the scoping assertions are measuring a scoped payload, not a refusal) |
| D | no third-party uid anywhere in the co-executor's payload |
| **E** | **★ the initiator cancels using the handle the WORKSPACE published** — deliberately not `initiate`'s return value. Before this change the variable did not exist and the statement was unwritable. This is the defect reproduced and closed. |
| F | the door refuses a non-initiator **holding the real id** — the list is advisory, never the boundary |
| teardown | no open case survives the section |

**Four mutations, all DETECTED** (`scripts/mutateSqlAuthorization.mjs`):

| id | what it restores |
|---|---|
| `mf-cancel-refused-to-initiator-only-undone` | the over-promise: attach + cancel re-fused into one literal |
| `mf-case-handle-unscoped` | the handle published to every executor |
| `mf-case-handle-withheld` | **the original defect** — no handle in any read |
| `mf-is-initiator-fails-open` | `coalesce(..., true)` — absence read as authority |

Bundle: pure SQL, one `begin;`/`commit;`, 3 positive controls, and
`verifyBundleAtomicity.mjs` exit 0 — applies cleanly intact, leaves nothing behind when corrupted
mid-file.

## 4 · ★ DEPLOY ORDER IS A SAFETY PROPERTY

**The mobile client must ship BEFORE this bundle is pasted.**

`features/executor/wire.ts` decodes with `.strict()`. A client that does not know `case_id` and
`is_initiator` **rejects** the corrected payload — so deploying the SQL first would break the executor
workspace on every installed build, for every fiduciary, immediately.

The mobile change (`afterworth-mobile`, Phase 11-MF) decodes both keys as **optional** precisely so the
two can land in either order, and normalizes absent → `null` / `false` so a pre-deployment server yields
no handle and no initiator claim. That tolerance is a transition, not the destination:
`features/executor/__tests__/cancelHandle.test.ts` §4 records tightening as owed work once this bundle is
live.

1. mobile 11-MF merged and shipped ← **tolerant decoder**
2. paste `executor_workspace_bundle.sql`
3. verify (below)
4. later, as its own change: make both fields required, delete §4

## 5 · Verifiers after the paste

```
node scripts/verifySqlAuthorization.mjs          # 398 assertions
node scripts/verifyDeployedContracts.mjs         # (mobile repo) get_executor_workspace PRESENT
```

Live check, as the standing fiduciary fixture, with **no open case** — `case_id` must be `null` and
`is_initiator` must be `false`:

```
get_executor_workspace(<estate>) -> verification.case_id     = null
get_executor_workspace(<estate>) -> verification.is_initiator = false
```

The full round trip — initiate, confirm `case_id` is published and equals the case, cancel **using that
published handle**, confirm restoration — is Phase 11-MF's device work and is blocked on this paste.

## 6 · What this phase did NOT change

- No grant, revoke, or DDL. `revoke ... from public, anon` / `grant ... to authenticated` unchanged.
- `cancel_death_verification_case` itself is **untouched**. The rule that a **revoked** initiator cannot
  cancel (cancellation still requires *current* fiduciary authority) stands, deliberately — it remains a
  separate product decision.
- `attach_evidence` remains any-executor and is still unbound in the client.
- No lifecycle transition, audit event, or notification was added or altered.
