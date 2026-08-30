# R-02 · isolated hosted event-trigger probe (v1)

```
STATUS        DESIGN ONLY — NOT AUTHORIZED FOR EXECUTION
GUARD         mutation_test_authorized = false
TARGET        afterworth-nonprod · qxzeougbaarecaiiqsay · us-west-2
R-02 STATE    R02_3_READ_ONLY_CAPABILITIES_VERIFIED
HOSTED COMPAT NOT PROVEN
```

## The one question

> **Can the hosted execution context create the class of event trigger that Model C bootstrap
> phase 120 requires?**

Not "is Model C compatible", not "can we do arbitrary DDL", not "is the role powerful". One
privilege boundary, asked once.

## Why the answer is genuinely uncertain — and probably "no"

Q1 returned **`postgres.rolsuper = false`** on the target, with `rolcreaterole`, `rolcreatedb`,
`rolreplication` and `rolbypassrls` all true. `supabase_admin` exists and *is* superuser, but that is
not the execution role.

Local validation against PostgreSQL 17 reproduced the boundary exactly. A role with
`rolcreaterole + rolcreatedb + bypassrls` and **no** superuser:

```
ERROR:  permission denied to create event trigger "r02_probe_event_trigger_v1"
HINT:   Must be superuser to create an event trigger.
```

Notably **`CREATE FUNCTION` succeeded for that same role** — so the likely hosted path is step 2
passing and step 3 failing.

**That is evidence about vanilla PostgreSQL, not about Supabase.** Supabase may grant the capability
by other means; it may not. The probe exists precisely because the two can differ, and guessing from
`rolsuper` alone would be the "a plausible cause is not a proven one" mistake this repository has
made before and written a rule about.

**A refusal is the ANSWER, not an obstacle.** If step 3 is refused: record the exact error, clean up,
stop. **No workaround is authorized** — no `SET ROLE`, no `supabase_admin`, no `GRANT`, no RPC, no
alternative connection path. Routing around the refusal would destroy the only thing the probe
produces: a truthful answer.

## Objects

| | |
|---|---|
| function | `public.r02_probe_event_fn_v1` |
| event trigger | `r02_probe_event_trigger_v1` |

Deterministic, version-suffixed, unmistakably disposable. The canonical names **`ensure_rls`** and
**`rls_auto_enable`** are forbidden outright and refused by the policy auditor — a probe using them
would stop being disposable, cleanup would delete something Model C later needs, and a failed
cleanup would leave a half-real canonical object behind.

The function body is empty (`begin end`): no writes, no DDL, no network, no auth/storage access, no
audit rows. **Not `SECURITY DEFINER`** — local validation confirmed it is unnecessary, and an
unnecessary definer on a probe is an escalation nobody asked for.

## Cleanup model — explicit (B), not transactional rollback (A)

Local validation confirmed both statements **are** transactional; a `ROLLBACK` removed both. Model A
is therefore viable and is still **not** chosen:

1. **The Supabase SQL Editor's transaction handling is unverified.** A probe whose safety depends on
   an unverified property of the tool running it is not a safe probe.
2. **The failure path is the likely path**, and inside a transaction a failed statement aborts the
   block — every later statement returns *"current transaction is aborted"*, making the most
   important outcome the least legible one.
3. Explicit `DROP`s are auditable afterwards: the POST check proves the objects are gone regardless
   of how the session behaved.

Emergency cleanup is idempotent and included at the foot of the SQL file.

## Sequence

| step | statement | kind |
|---|---|---|
| 1 | PRE check | `SELECT` |
| 2 | create disposable function | DDL |
| 3 | **create disposable event trigger** | DDL — *the actual question* |
| 4 | verify | `SELECT` |
| 5 | drop event trigger | DDL |
| 6 | drop function | DDL |
| 7 | POST check | `SELECT` |

No table is created to make the trigger fire. The question is whether the **object** can be created.
Firing verification, if ever needed, is a separate later sub-step — deliberately not bundled in, so
one failure cannot be mistaken for the other.

## Failure semantics

| case | action | classification |
|---|---|---|
| step 2 fails | HALT. Do **not** attempt step 3. | `FUNCTION_CREATION_REFUSED` |
| step 3 fails | Run step 6 only (function cleanup), verify absent, HALT. Record the exact error text. | `EVENT_TRIGGER_CREATION_REFUSED` |
| step 3 succeeds | Verify name/event/tags/owner/binding, then clean up. **Do not proceed to Model C.** | `EVENT_TRIGGER_CREATION_PERMITTED` |
| cleanup fails | Run emergency cleanup, re-run POST. If still non-zero: report loudly, do not hide it. | `CLEANUP_INCOMPLETE` |

**No retry and no escalation in any case.**

## PRE / POST contract

Both are `SELECT`-only and structurally identical in intent: probe function absent, probe trigger
absent, canonical `rls_auto_enable` absent, canonical `ensure_rls` absent, public tables 0. POST adds
public policies, total event triggers, and migration-metadata objects, so the probe can be shown not
to have disturbed anything it never touched.

**POST must equal PRE.**

## Enforcement

`scripts/lib/r02ProbePolicy.mjs` permits exactly: `SELECT`, transaction control, `CREATE FUNCTION`
and `DROP FUNCTION` for the pinned function name, `CREATE EVENT TRIGGER` and `DROP EVENT TRIGGER`
for the pinned trigger name. Everything else — `CREATE TABLE`, `CREATE SCHEMA`, `CREATE EXTENSION`,
`ALTER`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `MERGE`, `GRANT`, `REVOKE`, `SET ROLE`, `DO`,
`CALL`, `COPY`, a `DROP` of anything else, `SECURITY DEFINER`, an extra trailing statement, missing
cleanup, missing PRE/POST, an empty script — is refused.

`event_trigger_probe` is its **own** operation with its **own** flag (`mutation_test_authorized`).
`bootstrap_authorized` does **not** enable it, and it does not enable a bootstrap.
`expected_model.probe_version` pins *which* reviewed probe an authorization covers, so editing the
probe cannot inherit an earlier approval.

## Local validation is not hosted proof

The probe file was executed end-to-end on ephemeral PostgreSQL 17: PRE all-zero → created → verified
→ cleaned → **POST identical to PRE**. That proves **syntax and cleanup**. It proves nothing about
hosted privileges, because the local container grants superuser and the hosted role does not — which
is the entire question.

## State

Running this probe would move `R02_3` → `R02_4_MUTATION_TEST_AUTHORIZED` **only after explicit
authorization**. A successful result would inform, but not by itself establish,
`R02_5_HOSTED_COMPONENT_COMPATIBILITY_VERIFIED`.
