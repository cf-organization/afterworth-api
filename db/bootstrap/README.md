# Model C — canonical current-state bootstrap

```
BOOTSTRAP SCHEMA VERSION   0060
GENERATED FROM             live-schema-20260827.sql  (sha256 a21df219…1f8b7)
                           storage-policies-20260828.csv, event-trigger-bindings-20260828.csv
CLASSIFICATION             CURRENT AUTHORITATIVE SCHEMA — not a pre-0001 baseline
HOSTED SUPABASE PROVEN     NO — see 120_event_triggers.sql
```

## What this is, and what it is not

These files reproduce the AfterWorth application schema **as it exists today**, through migration
0060. They are **not** a replay of `db/migrations/0001–0060`, and they make no claim that those
migrations ever built a database from zero — they did not, and
`docs/fresh-database-migration-rehearsal.md` proves it.

**No pre-0001 schema is recoverable from any repository evidence**, including the predecessor
`afterworth-app` repo, whose own migrations begin at 0002. This bootstrap does not invent one.

## The cutover contract

| environment | how its schema is built |
|---|---|
| **virgin** | `db/bootstrap/` (this directory) → then migrations **0061+** |
| **existing** | its real history: migrations 0001–0060 already applied → then 0061+ |

Migrations **0001–0060 are immutable historical records**. They are never rewritten and are **never
executed during a virgin bootstrap**. Running them over this bootstrap would re-apply deltas to a
schema that already contains their outcome.

`VERSION` contains `0060`. A future migration is `0061_<date>_<name>.sql` and applies to both paths.

**Migration metadata is deliberately NOT initialized here.** Whether Supabase's
`supabase_migrations.schema_migrations` must be pre-seeded so the CLI does not attempt 0001–0060 is
a real question, and it cannot be answered without a real project. That is R-02 work, and seeding it
is a remote action outside this repository's local boundary.

## Order, and why it is this order

Phases run in numeric order. Two constraints are real rather than stylistic:

1. **Tables are created without foreign keys** (30), and constraints are added afterwards (40).
   This is pg_dump's strategy and it removes the ordering problem entirely — including
   `owner_notice_outbox`'s self-reference, which needs no special handling.
2. **Functions come after tables** (60), because `language sql` bodies ARE validated at creation
   (`check_function_bodies`) while `plpgsql` bodies are not. 29 of the 147 functions are `sql`.
   Phase 60 additionally sets `check_function_bodies = false`, exactly as pg_dump does, because the
   dump orders functions alphabetically and one body legitimately references a function defined
   later. The first fresh run failed on precisely this.

## Ownership boundaries

- `00_platform_contract.sql` **creates nothing**. It refuses if `auth.users`, `storage.objects`,
  `storage.buckets`, `auth.uid()`, `auth.jwt()`, the `extensions` schema, or the
  `anon`/`authenticated`/`service_role` roles are absent.
- `110_storage_policies.sql` creates two application policies on a **platform-owned** table.
  `storage.objects` itself is never created here.
- `120_event_triggers.sql` creates **only** `ensure_rls`. Six further event triggers exist in the
  live database and are owned by `supabase_admin` — they are Supabase's, and were excluded by
  **owner**, not by name.
- `testing/PLATFORM_SHIM_NOT_PRODUCTION.sql` fakes the platform surface for local container tests.
  It is not production DDL and no bootstrap file references it.

## `public.assets`

Present deliberately. It is an **application-owned legacy-compatibility surface**: the still-shipping
predecessor SwiftUI client performs runtime `SELECT`/`INSERT`/`DELETE` against it. **Dropping it is
not authorized**, and `estate_assets` is not a licence to remove it.

## Regenerating

```bash
node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence ~/aw-schema-capture
node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --check   # drift detector
```

The generator **refuses** any evidence file whose SHA-256 does not match its pinned value, and
refuses to emit if any snapshot statement cannot be assigned to a phase. Do not edit these files by
hand.
