# R02_7 · post-0060 end-state equivalence — final evidence

```
REPOSITORY HEAD AT FREEZE : 43212c0e079af1793847a70e7c5a08d60ad1a223
CLAIM                     : PATH A == PATH B == hosted afterworth-nonprod, post-0063
HOSTED MUTATION           : NONE. Every hosted execution in R02_7 was SELECT-only.
MIGRATIONS CREATED        : NONE. VERSION stays 0060; migration count stays 63; no 0064.
```

## Model C authority

| layer | authority |
|---|---|
| `db/bootstrap` | canonical virgin bootstrap through 0060 — `MODEL_C_BOOTSTRAP_0060 = AUTHORITATIVE_VIRGIN_BASELINE` |
| `db/migrations/0001–0060` | `IMMUTABLE_DELTA_HISTORY` — **never executed against an empty database** in R02_7 |
| `db/migrations/0061+` | post-bootstrap deltas: 0061 = U1, 0062 = U2, 0063 = U3 |

R02_6 is neither rewritten nor reinterpreted.

## The two paths

| | PATH A — virgin Model C | PATH B — existing/current Model C |
|---|---|---|
| source | `db/bootstrap` 13 phases @0060 | `live-schema-20260827.sql` + 4 hash-pinned evidence CSVs + U1 prestate supplement |
| then | 0061 → 0062 → 0063 | 0061 → 0062 → 0063 |

Both ran on PostgreSQL 17.11 on an **identical** platform prerequisite layer, so no platform
difference could masquerade as an application difference. These are **distinct executable
representations with common authoritative provenance** — `db/bootstrap` was generated *from* that
snapshot — not independently derived baselines, and they are not described as such.

## Corrected U1 dual path

An earlier build treated omission from a schema-scoped dump as absence; `auth` is outside the dump's
scope, so omission is not evidence. Corrected using committed U1 evidence:

```
PATH A @0060  auth.users trigger = ABSENT              0061 → U1_ACTION = CREATED
PATH B @0060  auth.users trigger = EXACT_POSTSTATE     0061 → U1_ACTION = RECOGNIZED
final state, both paths                                IDENTICAL
```

The paths take **different admissible branches and converge** — strictly stronger than both creating
the same missing object. 0062 and 0063 were APPLIED on both paths.

## Local equivalence

Primary comparator: 24 dimensions, all application-owned dimensions equal.
Independent verifier (different mechanisms — `pg_get_triggerdef`, per-policy assertions,
`has_table_privilege` rather than `aclexplode`): PASS on both paths.
Original required security mutation suite: **31 killed · 0 survived · 0 N/A**, plus four
normalization/platform controls that behaved as designed and are not counted as kills.

## Hosted chronology — recorded in order, not rewritten

### 1 · V1 — executed read-only, PARTIAL COVERAGE

`92423f2c27f92fe8eecd0e118979bd073624b80b5217a9c8f972130cad2d01fb`

Every gate it implemented PASSed and its OVERALL read `ALL_PASS`. It gated **12 of 24** required
dimensions, four of those by count alone. The shortfall was found *after* execution, by reading gate
definitions rather than the OVERALL verdict. V1 is valid evidence for what it gated and is **not**
sufficient for final authority. Its bytes are unchanged.

### 2 · V2 — executed read-only, 44 PASS / 1 FAIL

`9bf2e19334a5bf88be754573f8214c4a9546888501488946906730e46b282af2`

```
gate_columns_fingerprint   expected 4b5b967fcbb085db5e7ae4fd20a07653
                           hosted   9521ca65dda82d442f34a3d75d8d5a59
gate_columns (count)       415 / 415  PASS
OVERALL                    HALT — INVESTIGATE
```

### 3 · Column forensic — executed read-only

`9099811783fae12f9ee850273185b1e0a369788975de3f5c5cc4e4567afc758f`

415 actual columns, 415 expected embedded, controls PASS, and **exactly 14 differences, all
`DEFAULT_MISMATCH`**: canonical `extensions.uuid_generate_v4()` vs hosted `uuid_generate_v4()`, under
hosted `search_path = "$user", public, extensions`. No other five-field attribute differed.

### 4 · Binding diagnostic — executed read-only

`fac65a5ab1e5a69aae8e576b923a70454f88bc66549a8ad01e949a191ff69578`

A rendered string is not a binding. Resolving `pg_attrdef → pg_depend → pg_proc`:

```
function dependency rows visible  14
bindings_to_extensions_uuid_generate_v4   14 / 14   PASS
bindings_elsewhere                         0        PASS
shadow candidates enumerated              yes — exactly one, extensions.uuid_generate_v4()
```

### 5 · Adjudication

```
HOSTED_COLUMN_DIFFERENCE_CLASS = RENDERING_ONLY
REAL_HOSTED_COLUMN_DRIFT       = false
V2_COLUMN_FP_FAILURE_CAUSE     = SEARCH_PATH_SENSITIVE_DEFAULT_RENDERING
```

**V2's failure was a verifier false positive, not schema drift.** No hosted default was altered.
Reproduced locally beyond doubt: the identical unchanged schema yields V2 `4b5b967f…` under
`search_path=public` and `9521ca65…` — the exact hosted value — under `public,extensions`.

### 6 · V3 — final semantic column contract

`c33060783b51a554f3ce58a6011f74e5bb2d4e67d376a8ee40a6defd2ff55efd`

Fourteen semantic fields: schema, table, column, ordinal, type namespace/name, `format_type`, typmod,
typtype, domain/base type, nullability, identity, generated, collation, and **default semantic
identity** — function defaults resolved through `pg_depend → pg_proc` (namespace + name + identity
args + return type), sequence defaults through `pg_depend → pg_class`, literals by deterministic
normalized expression with casts and qualification preserved.

The fix is semantic, **not** textual. Stripping `"extensions."` from rendered text would have hidden
a rebinding to a same-signature function in another schema; V3 detects it.

V3 also closes V2's false negatives — V2 omitted typmod, identity, generated, collation and ordinal.
Proven locally: `varchar(100) → varchar(500)` is **invisible** to V2 and detected by V3.

```
canonical column fingerprint  e17e4f0e750680a8003f52cff1fa5a16
PATH A 415 columns · PATH B 415 columns · semantic rows equal
rendering-only control  PASS   (identical under search_path=public and public,extensions)
shadow-binding control  PASS   (zzshadow rebinding moves the fingerprint)
column mutations   16 killed · 0 survived
regression suite   12 killed · 0 survived
coverage           24 dimensions gated · 0 missing · 45 gates · 17 controls · read-only
independent V3 column verification  PASS on both paths
```

### 7 · V3 hosted execution — ALL_PASS

Executed exactly once, SELECT-only. Every gate PASSed, including
`gate_columns_v3_semantic_fingerprint = e17e4f0e750680a8003f52cff1fa5a16`,
`ctl_col_uuid_default_binding_visible = 14/14`, U2 fingerprint `f3b3f920…`, U3 client/creator/global
Dxtm all 0, row-DML 21 and `052198590d…`, FORCE RLS 0, migration metadata 0.

```
OVERALL = HOSTED_POST0063_MATCHES_CANONICAL_V3
```

### 8 · Final three-way equivalence

```
PATH_A_FINAL == PATH_B_FINAL == HOSTED_AFTERWORTH_NONPROD_POST0063
R02_7_HOSTED_EQUIVALENCE_PROVEN = true
```

## Operator project-identity confirmation

```
OPERATOR_PROJECT_IDENTITY_CONFIRMATION_REQUIRED = true
OPERATOR_PROJECT_IDENTITY_CONFIRMATION_PERFORMED = true (operator attestation)
project afterworth-nonprod · ref qxzeougbaarecaiiqsay
confirmed manually in the dashboard immediately before V3 execution
```

**SQL did not and cannot verify project identity.** A Supabase project ref has no in-database source;
the `target_project_ref` row in every verifier is a RECORD pin that always passes. This record rests
on the operator's attestation, not on any check the verifier performed.

## PATH B durability finding — OPEN

```
PATH_B_RAW_EVIDENCE_STORAGE         = MACHINE_LOCAL_HASH_PINNED
PATH_B_RAW_EVIDENCE_DURABILITY_RISK = OPEN
```

PATH B's raw inputs live **outside Git**, in `$HOME/aw-schema-capture/`, gitignored by deliberate
policy. The repository durably records their **hashes** and refuses any non-matching file, so it can
*authenticate* the evidence but cannot *reproduce* it. If that directory is lost, R02_7 becomes
unreproducible.

**R02_7 equivalence is proven. Broader R02 operational closure still carries this provenance residual
until it is separately resolved or explicitly accepted.** The raw capture was not committed; it has
not been reviewed for disclosure.

## Authorization at freeze

```
R02_7_HOSTED_EQUIVALENCE_PROVEN = true      R02_7_MERGED  = false
R02_7_CLOSED                    = false     HOSTED_SQL_AUTHORIZED       = false
HOSTED_MUTATION_AUTHORIZED      = false     MIGRATION_0064_RESERVED     = false
PARTIAL_BOOTSTRAP               = false
```
