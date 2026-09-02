# U2 · assets destination-ownership hardening — hosted execution evidence

```
STATUS:          EXECUTED AND VERIFIED
TARGET:          afterworth-nonprod (qxzeougbaarecaiiqsay)   ← project ref, not a secret
EXECUTED BY:     the user, manually, in the Supabase SQL editor
CLAUDE EXECUTION: NONE — no hosted SQL in this programme was run by Claude
AUTHORIZATION:   one-shot, CONSUMED. No U2 rerun is authorized.
```

No credential, password, access token, connection string or database secret appears in this file
or in any U2 artifact.

## What U2 changed, and why

`assets_write` was `FOR ALL` with `WITH CHECK (owner_id = auth.uid())`. That constrains **who owns
the row** and says nothing about **which estate the row lands in**, so an owner-authorised write
could place or move an asset into an estate the caller does not own. Proven behaviourally against
the canonical prestate: a cross-estate `UPDATE` returned `UPDATE 1` and a cross-estate `INSERT`
returned `INSERT 0 1`.

U2 hardens `assets_write`'s `WITH CHECK` and adds a **restrictive** destination layer. PostgreSQL ORs
permissive policies and ANDs restrictive ones, so tightening only `assets_write` would be undone by
any future permissive policy; the restrictive layer cannot be.

The weakness was **not reachable in production** — `public.assets` carries zero client row-DML
grants — so this is proactive structural hardening, not incident response.

## Artifacts

| role | path | SHA256 |
|---|---|---|
| migration (EXECUTED, IMMUTABLE) | `db/migrations/0062_20260902_assets_policy_hardening.sql` | `112a1275443b7772e68c8ddd55b4261768e1f35df7b321720bba5ecd7e278ac5` |
| precheck | `docs/r02/u2/u2-1-TOCTOU-precheck.sql` | `4eac124ddc894695780da7387598111744d7448dc3a8de9bf3387f7d91919956` |
| postcheck (corrected) | `docs/r02/u2/u2-2-postcheck.sql` | `1acec5a896cbe5b7e2c0e8f14af66f531411df8f858266b0e5ae6fec3a45d85d` |
| rollback (prepared, NOT executed) | `docs/r02/u2/u2-rollback.sql` | `6bffb45fbedc1aaf12f848e3002ccb182c79b7b62420ee18d55a026c5d6b8fa3` |

### SUPERSEDED — DO NOT EXECUTE

| what | SHA256 | why superseded |
|---|---|---|
| earlier migration candidate | `315f86af113136620f549577d5fc1c6a982ed090f70abdb7b7e40b021017b342` | its in-transaction postcondition asserted *"two restrictive policies whose command is one of INSERT/UPDATE"* — a population, not a name-to-command mapping. Two UPDATE policies and no INSERT policy satisfied it, so a command-swapped build could COMMIT with the INSERT destination check missing. |
| earlier postcheck | `1a082b70f989b7bec172eaee31e2332401c0131d92066de1d7fa1358692c9fca` | gated on `assets_relacl = (null)`, a local vanilla-Postgres observation that is not a hosted invariant. |

## Execution

Fresh precheck, immediately before execution:

```
policy_state              = EXACT_PRESTATE
expected_migration_action = APPLY
assets_policy_fingerprint = cb7c54092dd29033d0b28fe15e839ada
client_row_dml_tables     = 0
migration_metadata_tables = 0
OVERALL                   = ELIGIBLE_APPLY
```

Exactly one authorized execution: **`Success. No rows returned`** → ratified `U2_ACTION = APPLIED`.

## The first postcheck HALTed — verifier defect, not a migration failure

`assets_relacl` expected `(null)`; hosted actual carried the Supabase platform Dxtm grants. Every
other gating row passed. Adjudicated:

**`VERIFIER_PLATFORM_BASELINE_EXPECTATION_DEFECT`** — explicitly **not** a U2 migration failure, not
hosted drift, and not a partial apply.

Traced rather than assumed:

- The executed migration contains `GRANT 0 · REVOKE 0 · ALTER DEFAULT PRIVILEGES 0 · ALTER TABLE 0 ·
  OWNER TO 0`. Its only schema mutations are `ALTER POLICY 1` and `CREATE POLICY 2`.
  **`U2_ACL_MUTATION_SURFACE = NONE`** — it has no statement capable of altering a table ACL.
- `db/bootstrap/100_grants.sql` issues **zero** GRANTs on `public.assets`; the only line naming it is
  `ALTER TABLE "public"."assets" OWNER TO "postgres"`. Its three `ALTER DEFAULT PRIVILEGES` grant to
  `postgres` only. Model C cannot produce Dxtm either.
- The Supabase **platform's own** default ACL grants Dxtm to `anon`/`authenticated`/`service_role` at
  `CREATE TABLE` time. `db/migrations/0012_20260709_grant_sweep.sql` names this exact root cause.
- `docs/r02/final/r02-6-final-equivalence.sql`, executed hosted and ratified **before** U2, already
  recorded `anon_truncate_tables = 41`, `anon_maintain_tables = 41`,
  `authenticated_truncate_tables = 41`, `service_role_truncate_tables = 41` against
  `public_tables = 41` on the same predicate. **41 of 41 is exhaustive**, so `public.assets` already
  carried Dxtm before U2. `ASSETS_Dxtm_PREEXISTENCE = PROVEN` from committed evidence; no hosted read
  was required.

The expectation came from a local bootstrap container, where a table with no grants has a NULL ACL,
and was promoted to a gating invariant without being checked against hosted evidence this repository
already held. It is also PG-version dependent: `m` (MAINTAIN) exists only on PG17+, and the local
containers are PG16, so the raw string cannot agree across the two environments even in principle.

## Corrected postcheck — `U2_APPLIED_AND_VERIFIED`

```
assets_policy_count       4        assets_read_intact            PASS
assets_write_hardened     PASS     insert_restrictive_exact      PASS
update_restrictive_exact  PASS     no_extra_assets_policy        PASS
no_permissive_beyond_two  PASS     restrictive_layer_is_two      PASS

client_row_dml_tables        0     assets_anon_row_dml           0
assets_authenticated_row_dml 0     assets_service_role_row_dml   0

public_policies_total       38     public_tables                41
public_functions           147     migration_metadata_tables     0

assets_policy_fingerprint  f3b3f92058a4be2945de72be3800e32f
OVERALL                    U2_APPLIED_AND_VERIFIED
```

### The four-policy poststate

| policy | command | permissiveness | roles | USING | WITH CHECK |
|---|---|---|---|---|---|
| `assets_read` | SELECT | PERMISSIVE | PUBLIC | `((owner_id = auth.uid()) OR is_estate_member(estate_id))` | absent |
| `assets_write` | ALL | PERMISSIVE | PUBLIC | `(owner_id = auth.uid())` | `((owner_id = auth.uid()) AND is_estate_owner(estate_id))` |
| `assets_insert_require_estate_owner` | INSERT | RESTRICTIVE | PUBLIC | absent | `is_estate_owner(estate_id)` |
| `assets_update_require_estate_owner` | UPDATE | RESTRICTIVE | PUBLIC | absent | `is_estate_owner(estate_id)` |

`assets_read` was not modified. No policy was dropped.

### Client row-DML

Zero for `anon`, `authenticated` and `service_role` — before and after. U2 widened nothing.

### Platform Dxtm — recorded, never gated

```
anon          = MAINTAIN+REFERENCES+TRIGGER+TRUNCATE
authenticated = MAINTAIN+REFERENCES+TRIGGER+TRUNCATE
service_role  = MAINTAIN+REFERENCES+TRIGGER+TRUNCATE
```

This is a **platform baseline owned by U3**, recorded so it can neither vanish nor grow unnoticed.
The postcheck deliberately does not gate it: demanding its presence would break the moment U3 removes
it, and demanding its absence breaks today. It is read via `aclexplode(relacl)` rather than
`has_table_privilege(…,'MAINTAIN')`, because naming MAINTAIN errors on PG16 and would reintroduce the
same non-portability this correction removed.

## Rollback

Prepared, **not executed**. Evidence-conditional: it does nothing when U2 RECOGNIZED an
already-converged state, and reverses only after re-proving the exact poststate it applied. Reversing
U2 restores a proven weakness — it is a breakglass, not routine.

## Authorization

```
U2_ACTION                       = APPLIED
U2_APPLIED_AND_VERIFIED         = true
U2_EXECUTED_MIGRATION_IMMUTABLE = true
authorization                   = CONSUMED — no U2 rerun authorized
U3_IMPLEMENTATION_AUTHORIZED    = false
U3_EXECUTION_AUTHORIZED         = false
R02_7_EXECUTION_AUTHORIZED      = false
```

## Carried follow-up

`table_acl_fingerprint` in R02_6 may combine Model C and Supabase platform Dxtm contributions into
one value. **Not fixed here.** Related: this unit corrected the U2 postcheck's raw `relacl` gate to
RECORD-only for the same underlying reason — raw ACL text is a platform-and-version-dependent
representation, not a portable invariant.
