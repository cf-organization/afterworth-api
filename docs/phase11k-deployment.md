# Phase 11-K — deployment

**STATUS: DEPLOYMENT_REQUIRED.** Nothing in this phase is deployed. Claude does not execute
production DDL. The console in `afterworth-admin` cannot be exercised until this bundle is applied.

---

## 1 · The artifact

```
build:   node scripts/buildOperatorConsoleBundle.mjs
verify:  node scripts/buildOperatorConsoleBundle.mjs --check
path:    db/bundles/operator_console_bundle.sql
```

Rebuild before pasting and confirm the SHA256 matches what the PR recorded. **A mismatch means the
inputs changed and the bundle in your clipboard is not the one that was reviewed.**

```
shasum -a 256 db/bundles/operator_console_bundle.sql
```

Recorded at PR head: `1838971f728b3ff112e502d5881b18b6edc59787f34278aae4e552fe5052a30d`

**Determinism** — verified by rebuilding twice in one session and comparing digests. Identical.

## 2 · What is in it, in paste order

| # | Part | Why here |
|---|---|---|
| 1 | `db/migrations/0056_20260813_operator_console_foundation.sql` | Widens the `owner_notice_outbox` status CHECK by one value |
| 2 | `db/functions/outbox_safety.sql` | The whole outbox module: age gate, claim (now `service_role`-granted), the new `record_owner_notice_outcome`, purge, census |
| 3 | `db/functions/operator_console.sql` | `admin_list_death_verification_cases`, `admin_get_death_verification_case` |

**The order is load-bearing.** `record_owner_notice_outcome` writes `'outcomeUncertain'`, which the
un-widened constraint refuses. Pasting the function before the migration would leave a routine that
raises `check_violation` on its most important branch and only on that branch — the class of failure
nobody notices until an owner is not warned.

Part 2 is re-pasted **in full** rather than patched: `create or replace` cannot patch a body, and a
bundle carrying only the new function would leave the census without its `uncertain` key while
claiming the phase had shipped.

## 3 · Pre-flight checks, already run

| Check | Result |
|---|---|
| `--check` (10 positive controls) | pass |
| Pure SQL, no `psql` meta-commands | pass (0 meta-commands; source migration has 1, so the check discriminates) |
| Exactly one `begin;` / `commit;` | pass |
| Applies cleanly against real Postgres | pass |
| **Rolls back completely when corrupted mid-file** | pass — executed twice against a real database, once corrupted (must fail and leave nothing) and once intact |
| Determinism (two rebuilds) | identical digests |
| SQL authorization suite | 352 assertions pass |
| Security mutations | 5/5 Phase 11-K mutations killed |

**Not established:** how the Supabase Web SQL Editor itself splits or wraps a paste. That is why the
artifact carries its own `begin;`/`commit;` — correctness does not depend on the editor. This residual
unknown is *unverifiable*, not assumed away.

## 4 · Safe intermediate states

There is one transaction, so there is no intermediate state to be safe in: the bundle either applies
whole or leaves nothing. If the editor errors mid-paste, **nothing landed** — re-paste from the top.

The migration's own self-check runs inside that transaction and raises on any failure, so a partial
or wrong application aborts rather than committing. It inserts one probe row into
`owner_notice_outbox`, proves the constraint admits `outcomeUncertain` and refuses a nonsense value,
then deletes the probe and asserts it is gone. **The self-check leaves no row in a safety queue.**

## 5 · Post-deployment verifiers

Run in order. Each is read-only.

```sql
-- 1 · the sixth status is admitted
select pg_get_constraintdef(oid) like '%outcomeUncertain%' as admits_uncertain
  from pg_constraint where conname = 'owner_notice_outbox_status_check';
-- expect: t

-- 2 · the worker pair is service_role ONLY
select has_function_privilege('service_role','public.claim_owner_notices(int)','execute')      as worker_can_claim,
       has_function_privilege('authenticated','public.claim_owner_notices(int)','execute')     as client_can_claim,
       has_function_privilege('service_role','public.record_owner_notice_outcome(uuid,text,text)','execute') as worker_can_record,
       has_function_privilege('authenticated','public.record_owner_notice_outcome(uuid,text,text)','execute') as client_can_record;
-- expect: t, f, t, f

-- 3 · both projections exist and are admin-only
select to_regprocedure('public.admin_list_death_verification_cases(text,timestamptz,uuid,int)') is not null as queue,
       to_regprocedure('public.admin_get_death_verification_case(uuid)') is not null            as case_file,
       has_function_privilege('anon','public.admin_get_death_verification_case(uuid)','execute') as anon_can_read;
-- expect: t, t, f

-- 4 · the case file does not select the owner's address
select prosrc not like '%o.recipient%' as address_withheld
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname='admin_get_death_verification_case';
-- expect: t

-- 5 · the census reports the new bucket
select public.owner_notice_census() ? 'uncertain' as has_uncertain_key;
-- expect: t   (run as an AAL2 admin; refuses otherwise, which is also a correct result)

-- 6 · the downstream gates were NOT widened
select prosrc like '%status <> ''cancelled''%' as window_gate_intact
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='begin_challenge_window';
-- expect: t
```

Then, from the repository:

```
node scripts/verifyDeployedContracts.mjs
node scripts/verifySourceDeploymentDrift.mjs
```

## 6 · Read-only smoke probes

Signed in to the console as an AAL2 admin:

1. `/cases` loads and lists cases (or shows the empty state — **both are correct results**; the
   product has never created a death-verification case, so an empty queue is expected).
2. Open any case, if one exists. Confirm no email address appears anywhere on the page.
3. `owner_notice_census()` returns `total: 0` — see §7.

**Do not dispatch, decide, open a window, or authorize anything as a smoke test.** Four of the six
actions are irreversible on a real estate.

## 7 · The owner-notice backlog — derived, not queried

`dispatch_owner_safety_notice` is the **only** writer of `owner_notice_outbox` anywhere in `db/`
(verified by grep across migrations, functions and `grants.sql`). It has never had a client binding
and `admin_require_gate()` refuses a SQL-editor session (`auth.uid()` is NULL as `postgres`).

**Therefore the table cannot contain a row produced by any product path, and the drain has no
backlog to flush.** That is a derivation from the writer set, which is stronger than a query — but
confirm it before enabling the cron:

```sql
select public.owner_notice_census();
-- expect: total 0, actionable 0, stale 0, uncertain 0, purgeable 0
```

**If `total` is not 0, STOP and do not deploy the cron.** Any row predates this analysis, and the
runbook in `docs/phase11k-stale-notice-runbook.md` applies. No cleanup is required for `total: 0`,
and none should be performed "for tidiness" — `purge_outbox_rows` writes a high-severity audit row
and requires a non-blank reason precisely because purging a safety queue is not routine hygiene.

## 8 · The cron

`vercel.json` changes the claims cron path from `/api/claims/drain_purge_outbox` to
`/api/claims/drain_outboxes`, which runs **both** claims-domain drains.

**Vercel Hobby permits exactly two cron jobs.** A third entry is silently dropped — plausibly
dropping the invitation drain rather than the new one. `deploymentAudit.test.ts` caught exactly that
and now pins the arrangement from both ends.

Required environment (all already set for the invitation drain — **no new secret**):

| Var | Used for |
|---|---|
| `CRON_SECRET` | Gates the drain. **Unset fails closed.** |
| `SUPABASE_URL`, `SUPABASE_SECRET_KEY` | The service-role client that claims and records |
| `RESEND_API_KEY` | The provider |
| `INVITATION_LINK_BASE_URL` | The entry link. **Unset → the drain claims nothing** rather than burning live rows on a config error. |

**Delivery lag is real and bounded.** Hobby caps cron frequency at daily, so a queued notice can wait
up to ~24h. The challenge clock is stamped at *dispatch*, not delivery, so that lag is subtracted
from the owner's 7 days — worst case ~6 days of email-aware window. The in-app notice commits in the
same transaction as the dispatch, so an owner who opens the app is notified immediately; this channel
exists for the owner who does not. The age gate (8 days) is comfortably wider than the lag, so lag
alone can never turn a fresh notice stale.

**Raising this to hourly requires Vercel Pro and one line in `vercel.json`.** Recorded as a launch
consideration, not a defect.

## 9 · Rollback

The bundle adds a constraint value, two grants, and three functions. Rolling back is not symmetrical
and mostly should not be attempted:

- **The functions** can be dropped (`drop function if exists public.admin_get_death_verification_case(uuid);`
  and the two others). The console then fails loudly, which is the correct failure.
- **The constraint value cannot safely be narrowed** if any row already holds `outcomeUncertain` —
  narrowing would make those rows unwritable and unreadable-by-update, the `p11b-legacy-rows-orphaned`
  shape. Check first: `select count(*) from owner_notice_outbox where status='outcomeUncertain';`
- **The `service_role` grants** can be revoked, which stops the drain. Do that first if the intent is
  "stop sending", because it is reversible and immediate.
- To stop delivery without any DDL: **remove the cron entry from `vercel.json` and redeploy.**

## 10 · Recovery / re-paste

The bundle is idempotent. Re-pasting it is safe and is the correct response to any partial or failed
apply. If the self-check raises, read the message — it names which property failed — and do not
re-run until the cause is understood. `0056 FAILED: …` messages are deliberate and specific.
