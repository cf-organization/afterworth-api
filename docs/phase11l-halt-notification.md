# Phase 11-L — the halt notification

**STATUS: DEPLOYMENT_REQUIRED.** Nothing in this phase is deployed. Claude does not execute
production SQL. The owner challenge continues to work exactly as today until this artifact is
applied; what is missing until then is the message to the fiduciary.

---

> ## ⚠ SUPERSEDED IN PART BY PHASE 11-NR — read `docs/phase11nr-challenge-settlement.md` first
>
> **This phase shipped, was proved green, and did not work on the path that matters.** The
> Branch A production fire drill (2026-08-15) measured it: the notification described below is
> **never emitted on any operator-driven process**.
>
> `challenge_death_process` settled the case with `where … and status = 'open'`. That is the case
> status at exactly ONE of the four lifecycle states the owner challenge is reachable from. On the
> canonical path — initiate → verify → dispatch → window → challenge — the case is `verified`, the
> UPDATE matched no row, its `returning initiated_by` yielded NULL, and the emission was skipped.
>
> **Nothing below is retracted; the record stands as written.** Two things in it are, however,
> narrower than they read, and a future operator should know which:
>
> - §5 verifier 6's note — *"the `'halted'` value is written by `challenge_death_process` on every
>   halt **where a case is open**"* — is literally true and was the defect stated in passing. It was
>   read at the time as a caveat about an edge case; it was in fact a description of the only branch
>   that worked.
> - §5 has **no verifier for the settlement predicate itself**, which is why a post-deployment
>   check could pass on a database where the notification could never fire. 11-NR adds one.
>
> The 11-NR remediation widens the settlement set to `('open','verified')`, re-anchors the SQL suite
> on the canonical path (`release_safety_authorization.sql` §8 — §7 here only ever halted from
> `death_verification_pending`), and ships `db/bundles/challenge_settlement_bundle.sql`.

---

## 1 · The artifact

```
build:   node scripts/buildHaltNotificationBundle.mjs
verify:  node scripts/buildHaltNotificationBundle.mjs --check
path:    db/bundles/halt_notification_bundle.sql
```

```
shasum -a 256 db/bundles/halt_notification_bundle.sql
```

Recorded at PR head: `b3a275488a03200a8213adaba5ca518a9f4f3dbcdd2bbca40e050ac4eedfdd5b`

**Determinism** — verified by rebuilding three times in one session; identical digests.

**Rebuild before pasting and confirm the digest.** A mismatch means the inputs changed and the
bundle in your clipboard is not the one that was reviewed.

## 2 · What is in it, in paste order

| # | Part | Why here |
|---|---|---|
| 1 | `db/functions/lifecycle_notification_rpcs.sql` | The copy catalog gains `death_process.halted` |
| 2 | `db/functions/release_safety.sql` | `challenge_death_process` gains the emission |

**Order is load-bearing, though not fatally.** `emit_lifecycle_notification` resolves the event at
execution time and treats an unknown event as a refusal to emit — a warning and a null, never a
generic fallback. So pasting part 2 first would not error; it would silently emit **nothing** for
every halt in between, which is the exact failure this phase removes. Catalog first means that
window does not exist.

**No migration, and that is a property rather than an omission.** No column, no constraint value, no
grant. `death_verification_cases.status` already admits `'halted'` (migration 0054 widened it and
self-checks the widening), and `claimUpdate` is already in the RN client's known-category set.

**It carries no new authority.** Nothing here decides a case, moves a verification level, dispatches
a notice, opens a window, or releases anything. One catalog row, one `perform`.

## 3 · Pre-flight checks, already run

| Check | Result |
|---|---|
| `--check` (5 positive controls) | pass |
| Pure SQL, no `psql` meta-commands | pass (0) |
| Exactly one `begin;` / `commit;` | pass |
| Applies cleanly against real Postgres | pass |
| Rolls back completely when corrupted mid-file | pass (corrupted run errors and leaves nothing) |
| Determinism (three rebuilds) | identical digests |
| SQL authorization suite | **364** assertions pass (+12 for this phase) |
| Security mutations | **11/11 killed** |
| vitest | 352 pass |
| `tsc` | clean |
| source ↔ deployment drift | exit 0 |

**Atomicity is classified `NO_STATE_DELTA`, and that is the honest result.** This artifact creates no
new object name — it replaces two existing functions — so the only observable delta is catalog
content, which is already true at baseline in a database seeded from current source. The harness
excludes such a witness from its verdict rather than scoring it. Atomicity here rests on structure:
pure SQL, exactly one transaction, both asserted. Picking a different observable to make the number
come out right was the alternative, and it was declined.

## 4 · Safe intermediate states

One transaction, so there is no intermediate state. If the editor errors mid-paste, **nothing
landed** — re-paste from the top. The artifact is idempotent; re-pasting is always safe.

## 5 · Post-deployment verifiers

Read-only. Run in order.

```sql
-- 1 · the catalog answers for the new event, with the client-known category
select category, title, body
  from public.notification_event_copy('death_process.halted');
-- expect: claimUpdate | Estate process halted | The estate process you initiated has been halted.

-- 2 · the catalog still refuses an unknown event (the closed-catalog property)
select count(*) as should_be_zero
  from public.notification_event_copy('death_process.aw_probe_not_an_event');
-- expect: 0

-- 3 · the transition emits, and names the catalog event rather than composing text
select prosrc like '%death_process.halted%'          as names_the_event,
       prosrc like '%emit_lifecycle_notification%'    as uses_the_catalog_emitter,
       prosrc not like '%emit_notification(%'         as composes_no_text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'challenge_death_process';
-- expect: t, t, t

-- 4 · the owner-only gate and the idempotent replay guard are still there
select prosrc like '%is_estate_owner(p_estate)%'      as owner_gated,
       prosrc like '%challenge_halted%'               as replay_guarded
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'challenge_death_process';
-- expect: t, t

-- 5 · the emitter is still INTERNAL (create-or-replace must not have re-opened it)
select has_function_privilege('authenticated','public.emit_lifecycle_notification(uuid,uuid,text,text)','execute') as client_can_emit,
       has_function_privilege('anon','public.emit_lifecycle_notification(uuid,uuid,text,text)','execute')          as anon_can_emit;
-- expect: f, f

-- 6 · the case status vocabulary admits 'halted' (0054, asserted here because §7 depends on it)
select pg_get_constraintdef(oid) like '%halted%' as admits_halted
  from pg_constraint where conname = 'death_verification_cases_status_check';
-- expect: t
```

Then, from `afterworth-api`:

```
node scripts/verifySourceDeploymentDrift.mjs      # expect exit 0
node scripts/verifyOperatorDoorRefusal.mjs        # expect exit 0
node scripts/verifyOperatorAdmitPath.mjs          # expect exit 0
```

**Verifier 6 is the one worth not skipping.** The `'halted'` value is written by
`challenge_death_process` on every halt where a case is open. If 0054's widening were somehow absent
from this database, the halt would raise `check_violation` on exactly the estates it exists to
protect — and only on those. Nothing else in the deployed set probes it.

## 6 · Deep link — deliberately absent, and what it would take

The emitted row carries `action_deep_link = null`.

The recipient's own surface exists: `/executor` in the RN app, backed by `get_executor_workspace`,
which refuses a revoked designee and answers `{authorized:false}` rather than erroring. It is a
legitimate destination. What does **not** exist is an allowlist entry:
`features/notifications/actions.ts` maps a closed table of `afterworth://…` keys, and `executor` is
not among them. An unmatched string resolves to `null` and renders as a non-navigating row, so
emitting one would assert a destination the product has not wired.

Wiring it is a bounded mobile follow-up, **not** included here:

1. `features/notifications/model.ts` — add `'executor'` to `NotificationAction['kind']`.
2. `features/notifications/actions.ts` — add `'afterworth://executor': { kind: 'executor' }`.
3. The row-tap router — map `executor` to `/executor`.
4. Change part 2's emission to pass `'afterworth://executor'`.
5. §7's "no deep link is attached" assertion must be re-anchored to assert the **allowlisted** key
   rather than null, or it will correctly fail.

It is left out because the approved semantic for this phase is the notification, the deep link is
discretionary, and steps 1–3 are a client release that this artifact does not need.

## 7 · Rollback

Re-paste the **previous** `release_safety.sql` and `lifecycle_notification_rpcs.sql` bodies (that is,
this artifact built from the parent commit). Both are `create or replace` on unchanged signatures, so
privileges are preserved in both directions and no grant is disturbed.

Rolling back is genuinely low-risk here, and the asymmetry is worth stating: removing the catalog row
while leaving the emission in place is **safe** — the emitter would warn and emit nothing, which is
the pre-11-L behaviour. There is no state to strand: notification rows already written stay valid and
readable, and nothing else reads `death_process.halted`.

**To stop the notification without any SQL:** there is no runtime switch. That is deliberate — a
notification that can be silenced by configuration is a notification nobody can rely on having been
sent.

## 8 · Recovery / re-paste

Idempotent. Re-pasting is safe and is the correct response to any partial or failed apply.
