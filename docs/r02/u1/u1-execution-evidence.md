# U1 — handle_new_user trigger completeness · execution evidence

```
UNIT            R-02 / U1
TARGET          afterworth-nonprod   ref qxzeougbaarecaiiqsay
PRECONDITION    R02_6_FULL_MODEL_C_BOOTSTRAP_VERIFIED = true
EXECUTED BY     the user, manually, in the Supabase SQL Editor
CLAUDE EXECUTION  NONE — no hosted SQL was run by Claude at any point
AUTHORIZATION   one execution, explicitly authorized, now consumed
```

## Why U1 existed

Model C bootstrap 0060 contains `public.handle_new_user()` but not the trigger that invokes it.
The CLI schema dump feeding the generator excludes platform-owned schemas, and the binding lives on
`auth.users`. A virgin bootstrap therefore created no `profiles` row on signup: invitation
redemption failed closed, estate-member listings silently dropped the member, and a self-invitation
guard stopped firing. `bootstrap@0060` is immutable, so the repair is a post-0060 migration.

## Artifacts (SHA-256)

| Role | Path | SHA-256 |
|---|---|---|
| migration | `db/migrations/0061_20260901_handle_new_user_trigger.sql` | `790c14c8daff74ac0258fea1d6ce34657568d4697c066902de540671fbf316df` |
| precheck | `docs/r02/u1/u1-1-TOCTOU-precheck.sql` | `399b18fffd89c118b3fdbdc97b060a11a665019831c0bac333d243a2af91de12` |
| postcheck | `docs/r02/u1/u1-2-postcheck.sql` | `14b623c659213faea391013f4db2643c55c2dff9a9538cf00a1126b7cbda39d1` |
| rollback | `docs/r02/u1/u1-rollback.sql` | `c2d28182f402294c386a18d36519f8098d882ccafd4877062e4f0ba47556627c` |

## Sequence

**1 · Precheck** — SELECT-only.

```
trigger_state              = ABSENT
expected_migration_action  = CREATE
OVERALL                    = PASS / ELIGIBLE_CREATE
```

**2 · Execution** — exactly one authorized run of the migration.

```
Success. No rows returned
```

**3 · Postcheck** — SELECT-only.

```
exact_binding_count        = 1     PASS
equivalent_binding_total   = 1     PASS
auth_users_triggers_total  = 1     PASS
trigger_definition                 PASS
handle_new_user body SHA-256 = 205a0555f463d294c286732bd9bd7be21fe4201f8310eb30a9ffcfa25b4bc456  PASS
SECURITY DEFINER = true            PASS
owner = postgres                   PASS
public_functions           = 147   unchanged
public_ordinary_triggers   = 9     unchanged
migration_metadata_tables  = 0     unchanged

OVERALL = U1_APPLIED_AND_VERIFIED
```

## Ratified outcome

```
U1_ACTION               = CREATED
U1_APPLIED_AND_VERIFIED = true
```

**`U1_ACTION = CREATED` is the fact rollback governance depends on.** The rollback script refuses to
act without it: on `RECOGNIZED` it drops nothing, because a recognized binding is pre-existing
authoritative infrastructure the migration never created. Here the prestate was `ABSENT`, so a
narrowly re-verified drop is permissible if a rollback is ever separately authorized.

## Design record

- **Dual-path contract.** `ABSENT → CREATE` and `EXACT_EQUIVALENT → RECOGNIZE`; all six other
  classifier states HALT with zero mutation. `afterworth-dev` already holds the exact binding and
  would take the RECOGNIZE path.
- **`ROW EXCLUSIVE` lock, not `SHARE ROW EXCLUSIVE`.** A two-session test proved the RECOGNIZE path
  held *zero* locks on `auth.users` (it performs only catalog reads), letting a concurrent session
  commit a duplicate binding before the migration committed. `ROW EXCLUSIVE` is the narrowest mode
  that conflicts with `CREATE TRIGGER`'s `ShareRowExclusiveLock`, and being self-compatible it does
  not block ordinary signups.
- **Forbidden constructs.** No `DROP TRIGGER IF EXISTS` (would delete a pre-existing authoritative
  binding), no `CREATE OR REPLACE TRIGGER` (would silently overwrite a same-name conflict).

## Boundary

No rerun is authorized. The precheck now reports `EXACT_EQUIVALENT / ELIGIBLE_RECOGNIZE` against
this target, so a second run would be a no-op — but it still requires its own authorization.
U2, U3 and R02_7 remain unauthorized. This record contains no authentication material of any kind.
