# Canonical schema snapshot — acquisition procedure

```
STATUS:              PREPARED, NOT EXECUTED
EXECUTED BY:         the user, manually
CLAUDE EXECUTION:    NONE — no command in this document has been run
ACCESS:              READ-ONLY. No CREATE / ALTER / DROP / INSERT / migration / seed / deploy
DATA:                EXCLUDED — schema only, structurally, not by convention
OUTPUT:              untracked evidence path, hashed, reviewed before anything is promoted
```

## What this captures, and what it does not

The artifact this procedure produces is the **CURRENT AUTHORITATIVE SCHEMA SNAPSHOT** — the shape of
the live database on the day it is taken, after roughly sixty migrations have run.

It is **not** a pre-0001 baseline and must never be labelled one. That standing finding is unchanged:

> **PRE-0001 SCHEMA: NOT RECOVERABLE FROM CURRENT REPOSITORY EVIDENCE.**

A current snapshot cannot become a historical one by being captured carefully. Migration 0001 *adds*
`beneficiaries.user_id`; any snapshot taken today contains that column, so replaying 0001 against it
is a verification no-op rather than a construction step. That is a legitimate bootstrap model — it is
just a different one, and it has to be named honestly. See
`docs/fresh-database-migration-rehearsal.md` § *Follow-up finding*.

## Why a capture is needed at all

`db/migrations/` cannot build a database from zero — proven, not assumed
(`FRESH_DATABASE_FAILED`, first failing file `0001`). The repository's four partial schema sources
disagree with each other:

| source | distinct tables | what it actually is |
|---|---|---|
| `db/tables/` | 17 | current-state capture, 2026-07-10, ~40 migrations in |
| `db/migrations/` | 31 | delta history over a database that already existed |
| `db/tests/preamble_real_auth.sql` | 17 | minimal test model — post-migration *and* incomplete |
| `db/bundles/` | 11 | deployment slices |

None is authoritative. The live database is — which is what `db/migrations/README.md` said from the
first commit: *"The live database is authoritative."* This procedure asks it directly.

---

## Method selection

Three methods were considered against the real constraints: read-only, schema-only, no new
credential exposure, and no guessed flags.

### A · `supabase db dump` — **RECOMMENDED**

Flags below are taken from `supabase db dump --help` on the installed CLI (**2.101.0**), not guessed.

- **Schema-only is the default.** There is no `--schema-only` flag because none is needed: the flag
  that exists is `--data-only`, the opt-in for data. Omitting it excludes table rows *structurally*.
  This is the single most important property of the method — the data exclusion is not a convention
  the operator has to remember, it is the default behaviour, and the `--dry-run` step below proves it
  before anything runs.
- `--dry-run` prints the `pg_dump` script that *would* execute, without executing it. This makes the
  whole operation reviewable in advance.
- Output is DDL that can actually be replayed, which the catalog-query method (C) cannot produce.

**Cost:** no project is currently linked (`supabase/` exists in none of the three repos), so this
needs either `supabase link` or `--db-url`. Both need the database password once. See § *Credentials*.

### B · `pg_dump --schema-only` directly

Highest fidelity and the most familiar tool, but it requires assembling a connection string
containing the password, which then lands in shell history. Method A wraps the same `pg_dump` — its
`--dry-run` output *is* a `pg_dump` invocation — with better credential handling. **Use A.**

Local `pg_dump` is 18.4; Supabase runs Postgres 15/16. A newer `pg_dump` against an older server is
supported; the reverse is not. Not a blocker, worth knowing.

### C · SQL-Editor catalog queries — **the zero-credential fallback**

Read-only `information_schema` / `pg_catalog` queries pasted into the Supabase SQL editor. This is
the repository's established manual pattern — `docs/invitations/owner-invitation-migration-runbook.md`
already has the user run exactly this kind of query by hand — and it needs **no new credential at
all**, because the SQL editor authenticates through the dashboard session that already exists.

Its limitation is real: it returns *metadata about* the schema, not replayable DDL. Good for
verification and for the specific gap below; not a substitute for A.

---

## The gap method A may leave — settle it, do not assume it

The application owns RLS policies that live in a **platform** schema:

```
db/migrations/0030_20260719_claim_evidence_storage_rls.sql:31   create policy documents_estate_read   on storage.objects
db/migrations/0030_20260719_claim_evidence_storage_rls.sql:46   create policy documents_estate_insert on storage.objects
```

`supabase db dump` scopes to user schemas and may exclude `storage`. **Whether it does is not
guessed here** — the `--dry-run` output states which schemas the underlying `pg_dump` receives, which
is precisely why the dry run is step 1 and not an optional nicety. If `storage` is excluded, query C2
below captures those policies separately.

`auth.*` needs no such treatment: the application creates nothing in it. Verified — every `auth.`
reference in `db/` is a read of `auth.uid()`, `auth.jwt()`, `auth.role()` or `auth.users`.

---

## Credentials — the boundary

- The project ref `yiaavvkulrpqkkbqhwit` is **already committed** in this repository. It is an
  identifier, not a secret, and it appears in commands below for that reason.
- The **database password** is a secret. It is entered *interactively, into the CLI prompt*, on the
  user's machine.
- **Do not pass `--password` / `-p` on the command line.** It would place the password in shell
  history and in the process table. The flag exists; it is deliberately not used here.
- **Do not paste any password, service-role key, access token, connection string or DB URL into this
  chat.** Nothing in this procedure requires Claude to see one, and none should ever be sent.

---

## Verification — how to know it is schema-only

Do not trust the flag; check the artifact. A dump with no `COPY` and no `INSERT` contains no rows.

```bash
grep -cE '^(COPY|INSERT INTO)' <file>     # expect: 0
```

`0` is the pass. Any non-zero number means data was captured and the file must be deleted, not
edited — an edited dump is an artifact whose provenance can no longer be stated.

A **positive control** matters as much as the negative one, per this repository's standing audit
rule: a `grep` that finds nothing proves nothing until it has been shown capable of finding
something. So also confirm the file has real DDL in it:

```bash
grep -cE '^CREATE TABLE' <file>           # expect: > 0 — proves the grep and the dump both work
```

A file with zero `COPY` **and** zero `CREATE TABLE` is an empty or failed capture, not a clean one.

## Where the output goes

`docs/schema-capture/evidence/` — **untracked** (`.gitignore` in that directory ignores everything
but itself and this README). A raw capture is evidence. Nothing is promoted to a canonical path
until it has been read, verified schema-only, and a bootstrap model has been adjudicated on the
strength of it.
