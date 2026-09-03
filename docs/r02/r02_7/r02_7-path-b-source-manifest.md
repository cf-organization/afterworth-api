# R02_7 · PATH B source manifest

PATH B models the **existing/current** application state at 0060. Its inputs are listed exhaustively
below. Nothing here was recreated, regenerated or approximated; a missing or mismatched input is a
HALT, not a prompt to rebuild.

| # | filename | SHA256 | provenance | committed pin | bytes | role in PATH B |
|---|---|---|---|---|---|---|
| 1 | `live-schema-20260827.sql` | `a21df219616e2f80e2885d3b29fb61723174300b6909af637bfa8c4f0ea1f8b7` | `supabase db dump`, schema-only, source project `afterworth-dev`, captured 2026-08-27 | `scripts/generateBootstrap.mjs:39` | **EXTERNAL_LOCAL** (`$HOME/aw-schema-capture/`) | user-schema application state |
| 2 | `storage-policies-20260828.csv` | `7b0adbe21f95fc61ff1773c31a1a89b6cbbce27dd819d59f2548a7426c98f13e` | catalog capture, 2026-08-28 | `scripts/generateBootstrap.mjs:42` | **EXTERNAL_LOCAL** | `storage.objects` policies — the dump is schema-scoped and cannot carry them |
| 3 | `storage-policy-controls-20260828.csv` | `7bfc85be19b07c0d1518dcbe9290322c2f99468777a9e099d4e6e8796bf422c4` | capture controls | `:43` | **EXTERNAL_LOCAL** | positive controls for #2 |
| 4 | `event-trigger-bindings-20260828.csv` | `e5c005cb27f959421a5f33c218eeb3c10819fd3c9b8070b2a31ce5681c1cb0a9` | catalog capture | `:40` | **EXTERNAL_LOCAL** | event triggers — cluster-level, outside the dump |
| 5 | `event-trigger-binding-controls-20260828.csv` | `7b1c894a4ea851eea768db2066c7be6e30b19aadda15d3a483e656009ed1f21c` | capture controls | `:41` | **EXTERNAL_LOCAL** | positive controls for #4 |
| 6 | U1 `auth.users` trigger supplement | — (derived, see below) | `docs/r02/u1/u1-execution-evidence.md` sha `eaa1df2343f4fd6435ddfb2a1802228723301887baf45d5392eacea2c97771f1`; shape from `docs/r02/u1/u1-1-TOCTOU-precheck.sql` sha `399b18fffd89c118b3fdbdc97b060a11a665019831c0bac333d243a2af91de12` | both **IN_REPO** | `on_auth_user_created` binding |

## Why input 6 exists

`auth` is a platform schema outside the dump's scope, so **omission from `live-schema-20260827.sql`
is not evidence of absence**. An earlier R02_7 build treated it as absence and had both paths take
the `CREATE` branch of 0061 — losing the dual-path proof entirely.

The committed U1 execution evidence states: *"`afterworth-dev` already holds the exact binding and
would take the RECOGNIZE path."* The binding's shape is taken from the committed **read-only
observation instrument** (`u3`… `u1-1-TOCTOU-precheck.sql`), whose `EXACT_EQUIVALENT` classifier pins
`tgname = on_auth_user_created`, AFTER INSERT FOR EACH ROW, `tgenabled = 'O'`,
`public.handle_new_user()`, `tgnargs = 0`.

It is **not** taken from `db/bootstrap`, **not** from PATH A's final state, and **not** synthesized
from migration 0061.

## Platform normalization applied to input 1

Exactly one statement neutralized: `CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA
"vault"` — unavailable in stock PostgreSQL, `PLATFORM_RECORDED_ONLY`, with **zero** schema-qualified
`vault.*` references anywhere in the snapshot. Resulting PATH B input sha
`b8bb6faaccd159bf4fe732b81642ee6272e7534b213bfde63f43c83aa63a8c83`; every other byte identical.
The `supabase_realtime` publication was **supplied as a platform prerequisite**, not deleted.

## Durability

```
PATH_B_RAW_EVIDENCE_STORAGE          = MACHINE_LOCAL_HASH_PINNED
PATH_B_RAW_EVIDENCE_DURABILITY_RISK  = OPEN
```

Inputs 1–5 live **outside Git**, in `$HOME/aw-schema-capture/`, gitignored by deliberate policy
(`docs/schema-capture/evidence/.gitignore`: raw captures are evidence, not canonical artifacts). The
repository durably records their **hashes** and refuses any non-matching file — so it can
*authenticate* the evidence but cannot *reproduce* it. **If that directory is lost, R02_7 becomes
unreproducible.** This is recorded as an open provenance finding; it is not permission to commit the
raw capture, which has not been reviewed for disclosure.
