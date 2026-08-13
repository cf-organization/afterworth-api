# Phase 11-K — deployment

**STATUS: DEPLOYED 2026-08-13.** The bundle was applied by Christ in the Supabase SQL Editor and the
post-deployment evidence is recorded in §11. The SQL/HTTP layer is verified; the ADMIN PRODUCT-PATH
half is **PENDING** on an AAL2 operator credential, and §11 says so rather than rounding it into a
pass.

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

| SHA256 | What it is |
|---|---|
| `1838971f728b3ff112e502d5881b18b6edc59787f34278aae4e552fe5052a30d` | **DEPLOYED.** Recorded at the 11-K PR head, confirmed byte-identical on disk before the paste, and applied to production. |
| `f705541cf7972a4bc4e47a60bd38d2e90391aa53006e9a7e2f46853dbca6708f` | **What source builds now**, after the comment correction below. |

**Determinism** — verified by rebuilding twice in one session and comparing digests. Identical.

### The two digests differ, and the difference is a comment. Stated rather than smoothed.

Post-deployment verification found `db/functions/outbox_safety.sql` documenting the drain's entry
point as `GET /api/claims/drain_owner_notices`. **No such route exists** — it returns 404 in
production, probed directly. The real path is `/api/claims/drain_outboxes`; `drain_owner_notices` is
only the log label for the owner-notice half inside the shared dispatcher. Correcting it rebuilt both
bundles that embed that module (`operator_console_bundle.sql` and `death_verification_bundle.sql`,
now `1c7c3ec146ff3d18673254673a733ab974f86b46149b91c25762e39beadd82fd`).

**NO RE-PASTE IS REQUIRED, and the reason is proven rather than asserted.** The change is
comment-only: every changed file is byte-identical to its deployed version once SQL comments are
stripped — verified with a stripper carrying its own positive control (it must remove comments) and
negative control (it must not remove SQL). No statement, grant, signature or body changed.

So the deployed `prosrc` of `claim_owner_notices` differs from source by exactly this comment until
the next paste of either bundle folds it in. **That delta is recorded here deliberately.** The rule
this repository enforces is against *silent* drift; a known, located, semantically inert delta with
both digests written down is the opposite of the Phase 10 near-miss. Re-pasting 56KB of production
DDL to correct a comment would be the larger risk.

Why a comment mattered enough to fix: §5 and §7 verify this channel **by probing it**. An engineer
who probes the name the source told them would get a 404 and conclude the drain was never deployed —
a false negative about the only independent channel that warns a living owner their estate is being
released.

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

Then the repository verifiers. **Note which repo each lives in** — an earlier version of this section
listed both under "from the repository", and `verifyDeployedContracts.mjs` is not in this one. Run as
instructed there it fails with a module-not-found error, which reads like a broken verifier rather
than a wrong path:

```
# in afterworth-api
node scripts/verifySourceDeploymentDrift.mjs      # source ↔ deployment, pure functions, exit 0
node scripts/verifyOperatorDoorRefusal.mjs        # the three 11-K doors, refuse half (no admin needed)

# in afterworth-mobile
node scripts/verifyDeployedContracts.mjs          # the contracts the APP consumes
```

**`verifyOperatorDoorRefusal.mjs` exists because neither of the other two touches these doors.**
`verifyDeployedContracts` probes what the app consumes and the operator console is not the app;
`verifySourceDeploymentDrift` reconciles PURE functions and all three of these read rows. Without it
the only evidence about the three new routines is the six catalog queries above — which prove the
objects and grants exist, and prove nothing about how a door behaves when a real caller arrives over
PostgREST with a real JWT.

## 6 · Read-only smoke probes

Signed in to the console as an AAL2 admin:

1. `/cases` loads and lists cases (or shows the empty state — **both are correct results**; the
   product has never created a death-verification case, so an empty queue is expected).
2. Open any case, if one exists. Confirm no email address appears anywhere on the page.
3. `owner_notice_census()` returns `total: 0` — see §7. **This one is not a click.** See below.

### The census has a client binding and NO console surface

`afterworth-admin/lib/cases/rpc.ts` exports `ownerNoticeCensus()` over the operator's own JWT, and it
is the authoritative product path. But it has **zero rendered call sites** — verified against positive
controls in the same file: `listCases`, `getCase`, `dispatchOwnerNotice` and `authorizeRelease` each
resolve to 2 non-test call sites, `ownerNoticeCensus` to 0. It appears only in test mocks. So there is
no page in the console that displays the census, and step 3 above cannot be performed by clicking.

Until a surface exists, the census is probed through the same transport the console uses — the
publishable key plus the operator's own bearer token, no service role:

```
POST {SUPABASE_URL}/rest/v1/rpc/owner_notice_census
  apikey: {publishable key}
  Authorization: Bearer {the operator's OWN aal2 access token, issued < 15 min ago}
```

Obtain that token the way the console does: password grant → `mfa.challenge` → `mfa.verify` with a
fresh TOTP code → the returned access token carries `aal2`. The sequence is in
`docs/claim-evidence-viewer-proof.md` § Mint tokens. Equivalently, run `ownerNoticeCensus()` from the
devtools console of an already-signed-in `/cases` session, which exercises the identical path with no
token handling at all.

**A `service_role` call is NOT a substitute.** It would return the same JSON and prove nothing about
operator authority, which is the only thing in question. Authority is decided by source, never by
whether a caller could obtain the values.

Whether the console *should* render a census panel is a product decision, not a deployment step, and
is deliberately left open here rather than assumed.

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

## 11 · Post-deployment verification record — 2026-08-13

Applied by Christ in the Supabase SQL Editor. Artifact digest confirmed
`1838971f…52a30d`, byte-identical to the PR head.

### The SQL-Editor `owner_notice_census()` result is an EXPECTED ADMIN-GATE REFUSAL

Verifier §5 returned `42501 auth_required` via `admin_require_gate()`. **This is not a deployment
failure, and it is stronger evidence than a pass would have been from a nonexistent routine.**

Re-derived from source: `owner_notice_census()`'s first statement is
`perform public.admin_require_gate()`; that gate's first check is
`if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'`. The SQL Editor
executes as `postgres` with no PostgREST request context, so `auth.uid()` is NULL and the FIRST check
fires — before `is_admin()`, before `require_aal2()`, before the 15-minute `iat` freshness test.

**An undeployed function raises `42883 undefined_function`, not `42501`.** The routine was therefore
found, entered, and refused by its own gate. §5 anticipated exactly this: *"run as an AAL2 admin;
refuses otherwise, which is also a correct result."* The gate requires `aal2` plus a token issued
within 15 minutes; SQL-Editor and `postgres` execution are intentionally not supported operator
paths, and **no bypass was added.**

### Deployed state

| Check | Result |
|---|---|
| Verifiers 1, 2, 3, 4, 6 (catalog) | pass, as recorded above |
| Verifier 5 (census) | EXPECTED ADMIN-GATE REFUSAL — see above |
| `verifySourceDeploymentDrift.mjs` | **exit 0** — exact agreement on all 4 reconcilable contracts; 10 stateful contracts listed UNVERIFIABLE by name |
| `afterworth-mobile verifyDeployedContracts.mjs` | **exit 0** — all required contracts deployed and behaving |
| `verifyOperatorDoorRefusal.mjs` | **exit 0** — all three 11-K doors deployed and refusing with the correct sentinel |
| API vitest | 349/349 |
| `afterworth-admin` vitest | 81/81 |

The refusal probe is the one that speaks to *these* doors: as an authenticated **non-admin owner**
each answered `admin_required` — proving in one result that the routine exists at that signature, the
`authenticated` grant is present, and the in-body gate refused. As `anon` all three answered
`permission denied`. The worker pair (`claim_owner_notices`, `record_owner_notice_outcome`) answered
`permission denied` to an authenticated client, confirming at runtime what verifier 2 proved
statically. An estate relationship did not confer an operator view. Both mutations of the probe were
killed (an undeployed name → `NOT_DEPLOYED`; an admitting door → `ADMITTED`), and the working tree was
verified byte-identical after each.

### Email drain — SCHEDULED AND RUNNABLE, verified at runtime

Not inferred from source:

| Signal | Evidence |
|---|---|
| Cron registered | `vercel crons list` → **2 jobs**, `/api/claims/drain_outboxes` at `0 4 * * *` and `/api/invitations/drain_email_outbox` at `30 4 * * *`. Neither silently dropped. |
| Route deployed and fail-closed | unauthenticated `GET /api/claims/drain_outboxes` → **401 `unauthorized`**; the `drain_purge_outbox` alias → 401; a nonexistent action → **404**. The 404 control is what makes the 401 meaningful. |
| Production env | `CRON_SECRET`, `SUPABASE_URL`, `SUPABASE_SECRET_KEY`, `RESEND_API_KEY`, `INVITATION_LINK_BASE_URL`, `INVITATION_FROM_EMAIL` all present in Production (names only were read; no value was retrieved). |
| Deployment freshness | production deployment created 15:05:14 CDT, four seconds after the 11-K merge commit; aliased to `app.minifam.com`. The admin console deployed at 15:05:42 — **blocker B5 in the fire-drill doc is resolved.** |
| Backlog | `total: 0` still derived from the writer set (§7). Not re-queried, because doing so needs the same AAL2 credential the census does. |

**Retry cadence is coarser than the backoff, and that is survivable.** `record_owner_notice_outcome`
schedules `retryPending` 1–3 hours out, but Hobby cron is daily — so the effective retry interval is
~24h and three attempts span ~3 days, inside the 8-day age gate. Worth knowing before reading the
queue; not a defect.

### PENDING — the admit half, and only it

| Property | State |
|---|---|
| Census succeeds as AAL2 admin; payload structurally valid; `uncertain` bucket present | **PENDING** — needs an AAL2 operator credential |
| Operator queue / case file succeed as AAL2 admin | **PENDING** — same |
| AAL1 **admin** refused with `mfa_required` | **PENDING** — the refusal probe's subject is a non-admin, refused one check earlier at `admin_required` |
| Two independently-held AAL2 accounts (fire-drill B2) | **UNVERIFIED** — no admin credential exists in any repo (`.env.local` holds only URL + anon key), and reaching aal2 requires a live TOTP code from a human's device |

No admin account was created and no credential was minted. **`SUPABASE 11-K: DEPLOYED · ADMIN
PRODUCT-PATH VERIFICATION PENDING.`** The fire drill remains NOT STARTED.
