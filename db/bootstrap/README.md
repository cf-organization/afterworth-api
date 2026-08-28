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

> ### Do NOT run migrations 0001–0060 after this bootstrap.
>
> They are never executed during a virgin bootstrap. This directory already contains their outcome;
> re-applying them would replay deltas onto a schema that has already absorbed them. They also
> cannot build from zero — that is a proven fact, not a caution.

**Virgin install**

```
platform prerequisites (Supabase-provided: auth, storage, roles, extensions schema)
  → db/bootstrap/  (00 … 120, in numeric order)   ← schema through 0060
  → db/migrations/0061+
```

**Existing install**

```
its real history: migrations 0001–0060, already applied over time
  → db/migrations/0061+
```

Both paths converge on the same schema, and that is tested rather than asserted —
`scripts/bootstrapCutoverProof.mjs` applies one synthetic future migration to a restored live-state
snapshot and to this bootstrap, then compares 944 schema fingerprint lines.

Migrations **0001–0060 are immutable historical records** and are never rewritten.

`VERSION` contains `0060`. A future migration is `0061_<date>_<name>.sql` and applies to both paths.

### Future migration numbering

**No future migration may be numbered at or below the bootstrap cutoff.**
**Legitimate future migrations begin at 0061.**

`VERSION = 0060` means *"this fixed artifact produces schema state through migration 0060"*. It is
**not** a ceiling on migration numbers in the repository — an earlier validator read it that way and
rejected a perfectly valid 0061, producing nine failures across three suites, every one a bug in the
guard rather than a problem with the migration.

Authoring a real `0061_<date>_<name>.sql`:

| | |
|---|---|
| **does** change | `db/migrations/` |
| **does not** change | `db/bootstrap/` |
| **does not** change | `db/bootstrap/VERSION` (stays `0060`) |
| **does not** require | regenerating the bootstrap |
| **does not** cause | 0001–0060 to replay on virgin installs |

Enforced by `scripts/lib/migrationAuthority.mjs` and `test/schemaAuthority.test.ts`: historical
0001–0060 immutable, future numbers strictly increasing and unique, malformed names refused, and
**test-fixture content refused from `db/migrations/` for being a fixture — never for its number**.

### `db/bootstrap` is a FIXED cutover base, not a rolling snapshot

Future schema change is layered as `0061+`; it is **not** folded back into this directory. When real
0061 is authored, the file that must change is `db/migrations/0061_*.sql` — and nothing here.
Re-generating the bootstrap for every migration would make its version a moving target, so a virgin
install and an upgraded install would no longer be provably the same schema, which is the one
property this model exists to guarantee. See `db/AUTHORITY.json`.

## Schema authority

`db/AUTHORITY.json` is the machine-readable contract, enforced by `test/schemaAuthority.test.ts`.

| level | path | role |
|---|---|---|
| 1 | `db/bootstrap/` | **canonical virgin base through 0060** |
| 2 | `db/migrations/0061+` | future delta authority |
| 3 | `db/migrations/0001–0060` | immutable historical record |
| 4 | `db/tables/`, `db/functions/`, `db/bundles/`, `db/tests/`, `db/grants.sql` | **non-authoritative** |

Level-4 paths still exist because real tooling consumes them — `db/functions/` is the source for 15
bundle builders and the SQL-authorization suite. They cannot supply an object missing from this
bootstrap, and a **new** schema-bearing directory under `db/` that nobody classified **fails
closed**.

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

## Hosted Supabase compatibility — NOT PROVEN

`HOSTED_COMPATIBILITY_PROOF_REQUIRED` applies to:

- **`CREATE EVENT TRIGGER ensure_rls`** — event triggers conventionally require privileges a hosted
  migration role may not hold. Local containers grant superuser; hosted Supabase does not.
- **Migration metadata / cutover behaviour** — whether `supabase_migrations.schema_migrations` must
  be pre-seeded so the CLI does not attempt 0001–0060 against a virgin bootstrap.
- **Extension creation** (`pgcrypto`, `uuid-ossp`) under the hosted role.
- **Ownership statements** (`ALTER … OWNER TO postgres`) under the hosted role.

No local test clears any of these, and none may be cleared by local success. **R-02 is BLOCKED** —
no non-production Supabase environment exists.

## Provenance of the evidence

The snapshot was captured from **`afterworth-dev`**, not from production. Where this work observes
that the schema-only dump is less complete than the captured live state, the claim is about
**`afterworth-dev` live-state evidence** — the Supabase CLI dump excludes platform-owned schemas and
emits no cluster-level or event-trigger material. **No claim is made about production state.**

## Regenerating

```bash
node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence ~/aw-schema-capture
node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --check   # drift detector
```

The generator **refuses** any evidence file whose SHA-256 does not match its pinned value, and
refuses to emit if any snapshot statement cannot be assigned to a phase. Do not edit these files by
hand.
