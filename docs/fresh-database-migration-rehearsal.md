# Fresh-database migration rehearsal

```
INSTRUMENT:            scripts/rehearseFreshDatabase.mjs
TARGET:                ephemeral local Postgres container ONLY
REAL SUPABASE ACCESS:  NONE — and no argument can express one
PRODUCTION ACCESS:     NONE
MIGRATION FILES:       UNCHANGED
CURRENT VERDICT:       FRESH_DATABASE_FAILED  ← see § The finding
```

## The question

`db/migrations/` has only ever been applied **incrementally, one file at a time, to one long-lived
project**. Every signal a developer sees — the files exist, CI is green, the deployed schema works —
is a statement about that database's *history*, not about whether the recorded history *reproduces*
it. Those are different claims, and only the second matters the day a second environment is created.

R-02's definition-of-done requires *"All migrations + functions applied"* against a newly provisioned
project. This instrument asks that question against a throwaway container first, so the answer costs
a container rather than a paid project and a lost day.

## Running it

```bash
node scripts/rehearseFreshDatabase.mjs          # human output
node scripts/rehearseFreshDatabase.mjs --json   # machine output
node scripts/rehearseFreshDatabase.mjs --keep   # leave the container for inspection
```

Exit: `0` built · `1` failed · `2` could not verify. Docker is required; its absence is
`FRESH_DATABASE_UNVERIFIABLE`, never a pass.

## What it does

1. discovers migrations **from disk** — there is no list of filenames in any source file;
2. refuses an empty set, an unparseable filename, or a duplicate sequence number;
3. orders lexically, which equals numeric order because the filename rule admits exactly four digits;
4. runs a **symbolic pre-flight** naming any statement that alters a table no earlier migration creates;
5. starts a container it names and owns, creates the Supabase platform surface the history has always
   been written against (`auth` schema, `auth.uid()`, the three roles, `pgcrypto`) and **nothing of
   the application schema**;
6. applies every migration whole, through `psql -f`, with `ON_ERROR_STOP=1`;
7. **stops at the first error** and names the failing file;
8. smoke-checks that the result is not an empty database;
9. tears the container down in `finally`, on success and on failure alike.

## Why it cannot be pointed at a real database

There is no `--database-url`, `--project-ref`, `--remote`, `--production`, `--host` or `--dsn`; those
flags are **explicitly refused**, not merely unused, so an operator who believes they redirected the
run is told they did not. The runner reads no `.env`, no `SUPABASE_URL`, no service key and no
`process.env` database configuration. It starts its own container, invents its own throwaway
password, and talks to it over `docker exec`.

Having no way to express a remote target is a stronger property than validating one, and the test
suite proves it **behaviourally** — by invoking the binary with each flag and requiring exit 2.

## The finding

**The recorded migration history cannot build a database from zero.** It fails on the first file:

```
FIRST FAILING MIGRATION  0001_20260616_beneficiaries_live_read.sql
  psql: ERROR:  relation "public.beneficiaries" does not exist
```

The pre-flight names the shape of it: **39 tables are ALTERed by migrations that no migration
creates**. `db/migrations/` begins mid-life. The base schema it assumes was created outside the
migration stream, and today the only complete `create table public.beneficiaries` in the repository
lives in `db/tests/preamble_real_auth.sql` — a **test** preamble, not a schema source.

So the repository's fresh-build inputs are spread across four overlapping places:

| source | distinct tables created |
|---|---|
| `db/tables/` | 17 |
| `db/migrations/` | 31 |
| `db/tests/preamble_real_auth.sql` | 17 |
| `db/bundles/` | 11 |

**No migration file was edited to make this pass, and none should be.** Editing history to satisfy a
rehearsal forges the very thing the rehearsal exists to check. Repairing it — whether by extracting a
baseline `0000`, promoting `db/tables/` to a declared bootstrap, or something else — is a separate
migration-history adjudication with its own review.

## CI

**Deliberately not wired as a required check yet.** The audit is red for a real reason, and adding a
red required check would block every unrelated PR while teaching everyone to ignore it. The pure
rules *are* pinned in the normal suite (`test/freshDatabaseRehearsal.test.ts`, 27 tests), including a
test that asserts the finding still holds — so the day the history is repaired that test fails and
forces the docs, the risk register and the CI wiring to be updated in the same change.

## R-02

`R-02` remains **BLOCKED**. This satisfies the *rehearsal* prerequisite behind DoD box 2 — the
question is now answered rather than assumed — but the box itself cannot be checked while the answer
is "no", and boxes 1 and 3 still need a provisioned project and a deployed API.

## Supabase workflow

**This unit requires no manual SQL in Supabase and touches no Supabase project.**

When a real non-production project is eventually initialized, the established boundary still applies:
repository migrations remain authoritative, exact SQL is prepared for review, the operator runs it in
the Supabase SQL editor, and verification follows. This instrument does not deploy, and adding remote
execution to it is explicitly out of scope.
