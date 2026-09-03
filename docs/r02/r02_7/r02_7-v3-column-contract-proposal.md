# R02_7 · proposed V3 column normalization contract

**Status: PROPOSAL. Not adopted, not executed, and no verifier has been changed.** The canonical
expectation `4b5b967fcbb085db5e7ae4fd20a07653` remains in force until the binding adjudication
completes.

## Why V2's contract must change

V2 compared five coarse fields:

```
table_name . column_name : data_type : is_nullable : coalesce(column_default,'-')
```

Two independent defects follow from that:

1. **`column_default` is a rendered string, and rendering is search_path-sensitive.** Hosted
   `search_path = "$user", public, extensions` renders `extensions.uuid_generate_v4()` as
   `uuid_generate_v4()`. Fourteen columns differ in text while — pending the binding diagnostic —
   binding to the same function. A verifier that compares renderings reports drift where there is
   none.
2. **`data_type` from `information_schema` is coarse and carries no typmod**, and the contract omits
   identity, generated and collation entirely. Proven locally: a collation change moves no V2 field,
   so V2 cannot see it.

The first produces false positives; the second produces false negatives. Both are corrected below.

## The correction is NOT string-stripping

Removing `"extensions."` from arbitrary default text would be the wrong fix — it would hide a real
rebinding to a different `uuid_generate_v4()` in another schema, which is exactly the mutation the
binding diagnostic kills. **Defaults are compared by semantic identity, not by spelling.**

| default kind | V3 comparison |
|---|---|
| function-call (`uuid_generate_v4()`, `now()`, `gen_random_uuid()`) | resolve `pg_attrdef → pg_depend → pg_proc`: **namespace + function name + identity arguments + return type**. Never the rendered text, never the OID. |
| sequence (`nextval(...)`) | semantic sequence identity: owning schema + sequence name + data type + increment/start; never the rendered `regclass` text. |
| literal / expression | deterministic normalized expression from `pg_get_expr`, with whitespace collapsed and **casts and schema qualification preserved**, since both can be semantically meaningful. |
| absent | explicit `(none)` sentinel, distinct from an empty string. |

## Full V3 column contract

| # | field | source | note |
|---|---|---|---|
| 1 | schema | `pg_namespace` | explicit, not implied |
| 2 | table | `pg_class` | |
| 3 | column | `pg_attribute.attname` | |
| 4 | ordinal position | `pg_attribute.attnum` | physical position, dropped columns excluded |
| 5 | semantic type | `pg_type` namespace + name | resolved identity, not `information_schema.data_type` |
| 6 | typmod / precision | `format_type(atttypid, atttypmod)` | closes the `varchar(100)→varchar(500)` blind spot |
| 7 | domain base type | `pg_type.typbasetype` | where the type is a domain |
| 8 | nullability | `pg_attribute.attnotnull` | catalog truth, not `YES`/`NO` text |
| 9 | **default semantic identity** | per the table above | the substantive change |
| 10 | identity | `attidentity` | absent from V2 |
| 11 | generated | `attgenerated` | absent from V2 |
| 12 | collation | `pg_collation.collname` | absent from V2 — proven undetectable under V2 |

Normalization rules carry over unchanged: no OIDs in any fingerprint, deterministic `ORDER BY` on
schema/table/ordinal, explicit sentinels for absent values, and no reliance on session `search_path`.

## Sequencing

1. Execute the binding diagnostic (`fac65a5a…9578`) — **not yet authorized**.
2. If all 14 bind to `extensions.uuid_generate_v4()`, classify the V2 failure
   `SEARCH_PATH_SENSITIVE_DEFAULT_RENDERING` / `RENDERING_ONLY`, and only then adjudicate adopting
   V3 and recomputing the canonical column fingerprint under the new contract.
3. If any default binds elsewhere, `REAL_HOSTED_COLUMN_DRIFT = true` and this proposal is set aside
   in favour of a drift investigation.

Recomputing the canonical fingerprint is a **verifier correction**. It authorizes no schema change of
any kind.
