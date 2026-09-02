# U3 · Dxtm privilege hardening — hosted execution evidence

```
STATUS:            EXECUTED AND INDEPENDENTLY RE-VERIFIED
TARGET:            afterworth-nonprod (qxzeougbaarecaiiqsay)   ← project ref, not a secret
EXECUTED BY:       the user, manually, in the Supabase SQL editor
CLAUDE EXECUTION:  NONE — no hosted SQL in this programme was run by Claude
AUTHORIZATION:     one-shot, CONSUMED. No U3 rerun is authorized.
SERIALIZATION:     OPERATOR_ENFORCED_DDL_ACL_FREEZE
DATABASE-ENFORCED SERIALIZATION: unavailable
```

No credential, password, access token, connection string or database secret appears in this file or
in any U3 artifact.

## What U3 changed, and why

Every ordinary table in `public` carried `TRUNCATE`, `REFERENCES`, `TRIGGER` and `MAINTAIN` for
`anon`, `authenticated` and `service_role`. **TRUNCATE operates outside row-level security**, so a
usable TRUNCATE privilege can destroy every row of an RLS-protected table. Defence-in-depth: not
presently reachable, because client row-DML is granted sparingly and the API exposes no such path.

The privileges came from a **default ACL**, not from any migration — Model C's Phase 100 issues no
client GRANT at all. A default ACL is applied at `CREATE TABLE` time and selected by the **creating**
role, so clearing existing tables without clearing the default would reinstate them on the next table.

## Why database-enforced serialization was unavailable

`GRANT` and `REVOKE` take **no relation lock** on the target table — they perform an MVCC update of
the `pg_class` row — so no `LOCK TABLE` on an application table can serialize them at any strength.
The only mechanism that works is `SHARE` on `pg_catalog.pg_class` and `pg_catalog.pg_default_acl`,
proven on PostgreSQL 17.11 to block concurrent `GRANT`, `REVOKE`, `ALTER DEFAULT PRIVILEGES` and
`CREATE TABLE`, to close the stale-default race, and to leave ordinary DML running.

The hosted executor cannot take those locks. Both catalogs are owned by `supabase_admin`; `postgres`
is not the owner, is not a member of the owner role, and holds no `UPDATE` / `DELETE` / `TRUNCATE` /
`MAINTAIN` on either — `share_mode_predicted = false`. It can take only `ACCESS SHARE`, which does not
conflict and therefore does not serialize.

The accepted control is therefore **procedural**, and no stronger claim is made for it anywhere. See
`u3-operational-freeze-protocol.md`.

## Artifacts

| role | path | SHA256 |
|---|---|---|
| migration (EXECUTED, IMMUTABLE) | `db/migrations/0063_20260902_dxtm_privilege_hardening.sql` | `06cfa699d9a7a3ad89642db165390fee6628892fbf2f93a37bc99bd123525e0c` |
| hosted diagnostic | `docs/r02/u3/u3-0-default-acl-readonly-diagnostic.sql` | `fed3285ec8bbf3ebf0ca15885d4ef2040d9359bbc3f17f2bd561572a35c1460c` |
| precheck | `docs/r02/u3/u3-1-TOCTOU-precheck.sql` | `f90d2980cb934b908ffdc93d4ab6df942d3c2c8166b7a565fc52ee2435ba297f` |
| postcheck | `docs/r02/u3/u3-2-postcheck.sql` | `577e5ff02762aaeed1f5fa0a53056ae051cb3df7aa582ad3cca73c445108bd5f` |
| independent verifier | `docs/r02/u3/u3-3-fresh-snapshot-verification.sql` | `61dd716591e83a6a87526231bf6d2aef11176bbb52baf54d93148e5bd4048be6` |
| freeze protocol | `docs/r02/u3/u3-operational-freeze-protocol.md` | `4dd9a23a159bbae515388e9665db75d5f6ec59263c2a20cd5cecc4dc8bb6f600` |

### SUPERSEDED — DO NOT EXECUTE

`75447fed4dcf3b3ab5a737dc15071fab438e8f15fad9da5fef318613c917b65d` — an earlier provisional candidate
that carried a 41-table `ACCESS SHARE` loop presented as a concurrency control. It was measurably
ineffective, because `GRANT`/`REVOKE` take no relation lock on the target table. **Never executed**,
and removed rather than left in place looking like a control.

## 1 · Hosted precheck — `ELIGIBLE_APPLY`

```
public_tables                    41
table_set_fingerprint            0009141a4788e0e4adf17a3209bab24c
distinct owners                  1        non-postgres owned   0
public_functions                 147      public_policies      38
row_dml_grant_rows               21
row_dml_fingerprint              052198590dd92ba70ab07c99cbd21f15
existing_table_dxtm_rows         492      (41 tables × 3 roles × 4 privileges)
postgres_public_default_dxtm     12       (3 roles × 4 privileges)
postgres_global_default_dxtm     0
postgres_public_default_rowdml   0
policy_state                     EXACT_PRESTATE
expected_migration_action        APPLY
OVERALL                          ELIGIBLE_APPLY
```

## 2 · Execution

Exactly one authorized execution: **`Success. No rows returned`**.

## 3 · Primary postcheck — `U3_APPLIED_AND_VERIFIED`

```
public_tables                        41        table_set_fingerprint  unchanged
existing_table_dxtm_total            0
  anon 0 · authenticated 0 · service_role 0
postgres_public_default_dxtm         0
postgres_global_default_dxtm         0
postgres_public_default_rowdml       0
row_dml_grant_rows                   21        row_dml_fingerprint    unchanged
OVERALL                              U3_APPLIED_AND_VERIFIED
```

## 4 · Independent fresh-snapshot verifier — `U3_INDEPENDENTLY_REVERIFIED`

Run in a separate query, after the postcheck. It does not include or invoke the postcheck, and
resolves privileges through `has_table_privilege` per table/role/privilege rather than decoding ACL
arrays with `aclexplode`, so a defect in one decoding path is unlikely to be shared by both.

```
privilege_probe_live                 PASS      ← positive control: the probe CAN return true
public_tables                        41        table_set_fingerprint  exact
owners                               all expected
tables_granting_truncate             0
tables_granting_references           0
tables_granting_trigger              0
tables_granting_maintain             0
postgres_public_dxtm                 0
postgres_global_dxtm                 0
row_dml_true_count                   21        row_dml_fingerprint    exact
OVERALL                              U3_INDEPENDENTLY_REVERIFIED
```

## 5 · Freeze lifecycle

```
ACTIVE       before the hosted precheck
MAINTAINED   through precheck → migration → primary postcheck → independent verifier
RELEASED     only after BOTH verifiers passed
```

## 6 · Platform boundary

`supabase_admin`'s `public` default ACL carries row-DML **and** Dxtm for client roles. It is
`PLATFORM_OWNED_OUT_OF_U3_SCOPE` and was **not touched**: a default ACL is selected by the role
creating the object, and all 41 application tables are created and owned by `postgres`, so the
platform defaults do not determine application-table ACLs.

The migration contains `supabase_admin` **zero times in executable code** (three times in comments),
and its postconditions deliberately do *not* assert "no Dxtm default anywhere" — that assertion would
fail on hosted for a reason U3 must not try to fix. Verified locally on a fixture where the platform
row demonstrably existed beforehand: byte-identical before and after.

## 7 · Rollback

`FORWARD_ONLY`. No rollback artifact exists and none should: reversing U3 would restore client
`TRUNCATE` on 41 RLS-protected tables — deliberately reintroducing the gap U3 closed. A failed
execution is repaired by a new forward migration after adjudication, never by a retry.

## 8 · Authorization

```
U3_ACTION                       = APPLIED
U3_APPLIED_AND_VERIFIED         = true
U3_INDEPENDENTLY_REVERIFIED     = true
U3_EXECUTED_MIGRATION_IMMUTABLE = true
authorization                   = CONSUMED — no U3 rerun authorized
U3_EXECUTION_AUTHORIZED         = false
HOSTED_MUTATION_AUTHORIZED      = false
R02_7_IMPLEMENTATION_AUTHORIZED = false
R02_7_EXECUTION_AUTHORIZED      = false
```

## 9 · Standing residual

Serialization was **operational, not database-enforced**. Without the freeze, a concurrent `GRANT`
can cross the RECOGNIZE path and a concurrent `CREATE TABLE` can read stale defaults and commit after
U3, producing a table carrying Dxtm that the migration's snapshot could never have seen. Both failure
modes are proven, not hypothetical. The control is as strong as the operator's confidence that
nothing else touched the database during the window, and no weaker claim should be made for it.

## 10 · R02_7 ACL model — carried forward

`TABLE_ACL_CLASSIFICATION_ADJUDICATED = true`. R02_7 must keep these six separate rather than merging
them into one fingerprint:

1. application table-set fingerprint
2. application owner invariant
3. application row-DML semantic fingerprint
4. application existing-table non-row-DML state
5. `postgres`/`public` application-creator default ACL
6. platform default ACL — recorded and classified separately, never merged

R02_6's historical fingerprint is unchanged, and remains valid as evidence of the 0060 hosted state.
