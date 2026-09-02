# U3 · operational DDL/ACL freeze protocol

```
DATABASE_ENFORCED_SERIALIZATION : unavailable
SERIALIZATION MODEL             : OPERATOR_ENFORCED_DDL_ACL_FREEZE
RESIDUAL CONTROL                : accepted, deliberately, for the reason below
TARGET                          : afterworth-nonprod (qxzeougbaarecaiiqsay)
```

## Why this document exists

U3 changes privileges whose semantics sit outside row-level security. Every other unit in this
programme was serialized by the database itself. **U3 cannot be**, and that is a measured fact, not a
convenience:

- `GRANT` and `REVOKE` take **no relation lock** on the target table — they perform an MVCC update of
  the `pg_class` row. So no `LOCK TABLE` on an application table, at any strength, can serialize
  them. An earlier candidate carried a 41-table `ACCESS SHARE` loop; it was measurably ineffective
  and has been removed rather than left in place looking like a control.
- The only mechanism that *does* work is `LOCK TABLE pg_catalog.pg_class` / `pg_catalog.pg_default_acl`
  `IN SHARE MODE`. Proven on PostgreSQL 17.11: it blocks concurrent `GRANT`, `REVOKE`,
  `ALTER DEFAULT PRIVILEGES` and `CREATE TABLE`, closes the stale-default race, and leaves ordinary
  DML running.
- **The hosted executor cannot take those locks.** `pg_class` and `pg_default_acl` are owned by
  `supabase_admin`; `postgres` is not a member and holds no `UPDATE`/`DELETE`/`TRUNCATE`/`MAINTAIN`.
  `share_mode_predicted = false` for both. It can take only `ACCESS SHARE`, which does not conflict
  and therefore does not serialize.

**No advisory lock may be presented as enforcing this freeze.** PostgreSQL advisory locks are
cooperative; a competing `GRANT` or `CREATE TABLE` issued by another operator or a CI job will not
consult one.

## What is at stake without the freeze

Both failure modes are proven, not hypothetical:

- a concurrent `GRANT` can cross the RECOGNIZE path, so U3 certifies a state that no longer holds;
- a concurrent `CREATE TABLE` can read the stale default ACL and commit **after** U3, producing a
  table carrying full Dxtm that U3's own transaction could never have seen — its snapshot excludes
  uncommitted work by construction.

## Preconditions — all must hold before the freeze is declared

- [ ] Operator has confirmed **in the Supabase dashboard** that the project is `afterworth-nonprod`
      (`qxzeougbaarecaiiqsay`). The precheck's `target_project_ref` row is a RECORD and cannot verify
      this — a project ref has no in-database source.
- [ ] No concurrent schema-migration deployment is running or queued.
- [ ] No second SQL operator is working on this project.
- [ ] No CI/CD migration job can fire during the window.
- [ ] No planned Supabase schema action (dashboard table editor, extension install, Storage policy UI).

## Freeze start

**Before the U3 hosted precheck**, not after it. The precheck's reading is only meaningful if nothing
can change between it and the migration.

## While frozen — prohibited

```
CREATE TABLE · ALTER TABLE · DROP TABLE
GRANT · REVOKE · ALTER DEFAULT PRIVILEGES
schema migration deployments · CI/CD database migration jobs
manual DDL by another operator
any application release step capable of public-schema DDL
```

**Ordinary application row DML may continue.** Measured: with the equivalent critical section held,
ordinary `SELECT` / `INSERT` / `UPDATE` and system-catalog reads all continued in ~0.09 s while DDL
and ACL mutation blocked. The freeze targets DDL and privilege change, not traffic.

## Execution order

| # | step | notes |
|---|---|---|
| 1 | freeze declared **ACTIVE** | record who declared it and when |
| 2 | `u3-1-TOCTOU-precheck.sql`, SELECT-only, fresh snapshot | must report `ELIGIBLE_APPLY` |
| 3 | **if and only if** `EXACT_PRESTATE` → one authorized execution of `0063` | one attempt only |
| 4 | `u3-2-postcheck.sql` in a **NEW query / fresh snapshot** | must report `U3_APPLIED_AND_VERIFIED` |
| 5 | `u3-3-fresh-snapshot-verification.sql` in **another** new query | independent implementation |
| 6 | only if 4 **and** 5 pass → freeze may be released | |

Steps 4 and 5 are separate on purpose. Because serialization is operational, a competing change could
land after the migration commits; a second read in a new snapshot is the only way to notice one that
arrived late. Step 5 does not call step 4 — it re-derives the security-critical assertions through
`has_table_privilege` rather than `aclexplode`, so a defect in one decoding path is unlikely to be
shared by both.

## Failure

Any of — an unexpected classifier state, an execution error, any operator uncertainty that the freeze
was maintained, or any evidence of concurrent DDL/ACL activity:

```
HALT
KEEP THE FREEZE ACTIVE
DO NOT RERUN THE MIGRATION
inspect state in a fresh SELECT-only snapshot, and adjudicate before anything else runs
```

U3 is **forward-only**. There is no rollback artifact, and none should be written: reversing U3 would
restore client `TRUNCATE` on 41 RLS-protected tables — deliberately reintroducing the gap U3 exists to
close. A failed execution is repaired by a new forward migration after adjudication, never by a retry.

## Standing residual

Even executed perfectly, this control is **procedural**. It is as strong as the operator's confidence
that nothing else touched the database during the window, and no weaker claim should be made for it in
any report. It is accepted here because the alternative — routing around the hosted privilege boundary
— is not available and should not be attempted.
