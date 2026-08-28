# R-02 — non-production Supabase environment, hosted compatibility

```
R-02 STATE            R02_0_NO_NONPROD   (no suitable non-production project exists)
HOSTED COMPATIBILITY  NOT PROVEN
BOOTSTRAP VERSION     0060  (fixed cutover base, rolling = false)
REMOTE ACTIVITY       1 credential-safe project listing · 0 SQL reads · 0 writes · 0 provisions
```

## The finding that governs everything below

`supabase projects list` reports **two** projects in org `rvudommjwqgtluhvfgcw`:

| Supabase name | ref | region | actual role |
|---|---|---|---|
| `afterworth-prod` | `rpjjwkoezuihpobotbjh` | `us-east-1` | **INACTIVE (paused)** · retained as a future production candidate · referenced nowhere in this repository |
| `afterworth-dev` | `yiaavvkulrpqkkbqhwit` | `us-west-2` | **ACTIVE** · the database the deployed application uses |

`README.md` pins `SUPABASE_URL = https://yiaavvkulrpqkkbqhwit.supabase.co` for Vercel, corroborated
by ten `docs/*-proof.md` files. **The project named "dev" is production in function.** The project
named "prod" appears in no code, no doc, and no proof.

> ### Near-miss, recorded because it nearly mattered
>
> Acting on the CLI's names, this session briefly "corrected" `nonProdSeedGuard`'s production pin
> from `yiaavvkulrpqkkbqhwit` to `rpjjwkoezuihpobotbjh` — which would have **removed protection from
> the database serving users** and protected an unused one. It was caught by the existing test that
> corroborates the pin against `README.md` and the proof docs, and reverted immediately.
>
> The original constant was right. **Classification is by evidenced role, never by project name** —
> the same lesson as event-trigger ownership, in a place where the cost would have been higher.

Neither project is an R-02 target. Both are refused with distinct, evidenced reasons:

| ref | protected_reason |
|---|---|
| `yiaavvkulrpqkkbqhwit` | `APPLICATION_FACING_EXISTING_DATABASE` |
| `rpjjwkoezuihpobotbjh` | `EXISTING_PAUSED_FUTURE_PRODUCTION_CANDIDATE` |

The second is **protected by uncertainty**. It previously received `DRY_RUN_AUTHORIZED` from the
seed guard because nothing had established what it is — which is backwards. **An absence of
information is not a licence: unknown real infrastructure is not disposable infrastructure.** Both
`scripts/lib/r02TargetGuard.mjs` and `scripts/lib/nonProdSeedGuard.mjs` now refuse it.

## Neither existing project can be reused

- `yiaavvkulrpqkkbqhwit` — application-facing **and** the source of the hash-verified Model C
  snapshot. Bootstrapping onto it would destroy both the live service and the evidence baseline.
- `rpjjwkoezuihpobotbjh` — role unestablished. An unestablished role is not a licence to treat a
  project as disposable.

**A new project is required.** Proposed specification:

| | |
|---|---|
| name | `afterworth-nonprod` (avoids the prod/dev naming trap entirely) |
| organization | `rvudommjwqgtluhvfgcw` (the existing org) |
| region | `us-west-2` (West US, Oregon) — the code was read from the existing project, not guessed |
| classification | nonproduction |
| lifecycle | disposable; expected to be reset repeatedly, possibly deleted after R-02 |
| retention | decide after R-02 whether it becomes a standing staging environment |
| cost | a Supabase project has a plan cost; **not discoverable from the CLI** and must be confirmed by the account owner before provisioning |

> ### COST_CONFIRMATION_REQUIRED — and the CLI cannot resolve it
>
> `supabase billing`, `supabase usage` and `supabase plan` **are not real commands** — each falls
> through to top-level help. The CLI exposes no plan, quota or billing information at all, so
> whether a third project fits the current plan **cannot be established from tooling**.
>
> `supabase projects create` additionally takes `--size` (an instance-size / compute selection with
> no discoverable default) and `--db-password` **as a command-line flag** — which would place the
> database password in shell history and the process table. Provisioning must therefore go through
> the dashboard, or an interactive CLI session the operator drives.
>
> No project-creation command has been executed.
>
> **USER AUTHORIZATION REQUIRED TO CREATE NON-PRODUCTION SUPABASE PROJECT** — not crossed.

Provisioning options, prepared and **not executed** — either is acceptable:

| route | how |
|---|---|
| Dashboard | supabase.com → org `rvudommjwqgtluhvfgcw` → New project → name `afterworth-nonprod`, region West US (Oregon). A database password is generated; it is entered **only** into the dashboard/CLI prompt and never into this repository or chat. |
| CLI | `supabase projects create afterworth-nonprod --org-id rvudommjwqgtluhvfgcw --region us-west-1` — flags not verified against the installed CLI, since verifying them is not a reason to run them. Confirm with `supabase projects create --help` at execution time. |

After provisioning, the new ref goes into a **local** manifest at
`~/aw-r02-evidence/environment-manifest.json` (template: `docs/r02/environment-manifest.example.json`),
with `bootstrap_authorized: false` and `destructive_reset_authorized: false`. The guard requires the
ref to be **both** named and allowlisted, so a mistyped or pasted ref is not authorized by accident.

## Target guard

`scripts/lib/r02TargetGuard.mjs`, 44 tests. **Allowlist, not denylist**: an unknown ref is refused
rather than permitted by default. Refuses absent/malformed/unallowlisted refs, absent or production
classification, unknown operations, bootstrap mutation without `bootstrap_authorized`, destructive
reset without its own separate flag, bootstrap-version mismatch, and **any manifest containing a
secret-shaped key**. No force flag, no environment-variable escape hatch — asserted by a test that
greps the source, with a positive control proving the scanner can see such a token.

## Migration workflow — ADJUDICATED

```
SUPABASE_CLI_MIGRATION_WORKFLOW_ADOPTED = false
SCHEMA_MIGRATIONS_PRESEED_AUTHORIZED    = false
MIGRATION_REPAIR_AUTHORIZED             = false
migration_execution_model.current       = MANUAL_MODEL_C_HOSTED_COMPATIBILITY
```

The Supabase CLI migration workflow is **not adopted for R-02 hosted bootstrap**. Therefore, in this
programme: no `supabase/migrations/` is created, `supabase migration up` and `migration repair` are
not run, `supabase_migrations.schema_migrations` is not written, and **nothing pretends migrations
0001–0060 were applied**.

Writing that table before an execution model exists would manufacture history with no operational
meaning — recording that 0001–0060 "ran" on a database where they demonstrably did not. Refusing to
pretend that is the whole point of Model C.

Migration tooling adoption is a **separate future unit**, after hosted compatibility is proven. This
decision concerns **execution tooling only**; the schema contract is untouched:
**bootstrap@0060 + future migrations 0061+**.

Pinned in `scripts/lib/r02TargetGuard.mjs` as `MIGRATION_EXECUTION_MODEL` and enforced by tests —
including static refusal of `migration up`, `migration repair`, and any write to
`supabase_migrations`.

## Migration metadata — findings

From the installed CLI (2.101.0), not assumption:

- `supabase migration up` applies migrations **not present in the remote history table**; `--include-all` forces everything missing from it.
- `supabase migration repair <version...> --status applied` is the **supported baseline mechanism** — it marks a migration applied without executing it. This is exactly the primitive a Model C cutover needs.
- `supabase migration list` compares local files against remote history and is **read-only** — usable in preflight.

**But the question is conditional, and the condition is unmet.** The CLI tracks migrations in
`supabase/migrations/` using timestamped filenames. AfterWorth uses `db/migrations/` with
`NNNN_YYYYMMDD_name.sql`, has **no `supabase/` directory at all**, and `db/migrations/README.md` has
said since its first commit: *"Until the Supabase CLI migration workflow is adopted…"*.

So:

- **Does `migration up` attempt 0001–0060?** Only if those files are in `supabase/migrations/` and absent from the history table. Today it would see **no** local migrations.
- **Is pre-seeding supported?** Yes — `migration repair --status applied`. It is a **write** and needs its own authorization.
- **Is it necessary?** Only if R-02 adopts the CLI workflow. If AfterWorth keeps applying SQL manually, `supabase_migrations.schema_migrations` is not the mechanism of record and seeding it would be theatre.
- **Correct end state for a virgin Model C@0060 — IF the CLI workflow is adopted:** 0001–0060 recorded as applied, before 0061 is introduced, so `up` applies only 0061+.

**Adjudication required before any metadata write:** does R-02 adopt the Supabase CLI migration
workflow, or does Model C remain a manually-applied bootstrap? Both are coherent; they need
different metadata handling, and picking one silently would be the wrong kind of decision.

## Mutation compatibility plan — designed, NOT executed

Each step gates the next; none may be skipped.

| # | step | irreversible? | evidence | stop condition |
|---|---|---|---|---|
| 1 | prove target identity (`current_user`, `current_database()`) | no | `environment-identity.txt` | ref ≠ manifest ref |
| 2 | prove target is non-production and virgin (query G) | no | `virginity.csv` | any public table exists |
| 3 | capture pristine hosted state | no | `pristine-*.csv` | capture fails |
| 4 | platform prerequisites (query E) | no | `platform-prerequisites.csv` | any prerequisite absent |
| 5 | extension availability (query C) | no | `extension-inventory.csv` | pgcrypto or uuid-ossp unavailable |
| 6 | Model C phases 00–110 in order | **yes** | per-phase exit + error | first non-zero exit |
| 7 | phase 120 `CREATE EVENT TRIGGER` **separately** | **yes** | exit + `pg_event_trigger` | permission denied → record, do not retry |
| 8 | storage.objects policies **separately** | **yes** | `pg_policies` diff | policy creation refused |
| 9 | ownership statements | **yes** | error text | `ALTER … OWNER TO postgres` refused |
| 10 | migration metadata strategy | **yes** | `migration list` before/after | adjudication not yet made |
| 11 | full virgin bootstrap end-to-end | **yes** | 27-dimension drift audit | any drift |
| 12 | compare against Model C expected state | no | drift report | non-equivalent |
| 13 | reset/destroy | **yes** | — | requires `destructive_reset_authorized` |

Rollback for 6–11 is **project reset**, which is why the target must be disposable and why steps 7–9
are separated: a failure there is the *finding*, and it must not be buried inside a bulk apply.

## Evidence plan

`~/aw-r02-evidence/` — outside the repository, never committed without separate authorization.
Artifacts: `environment-identity.txt`, `project-inventory.txt`, `role-capabilities.csv`,
`extension-inventory.csv`, `platform-prerequisites.csv`, `event-trigger-inventory.csv`,
`migration-metadata.csv`, `virginity.csv`.

Every artifact: **no secrets**, SHA-256 hashed, recording acquisition timestamp, target project ref,
and whether the query was SELECT-only — the same discipline that produced the Model C snapshot.

## State machine

```
R02_0_NO_NONPROD                            ← CURRENT
R02_1_NONPROD_IDENTIFIED                      after provisioning + manifest
R02_2_IDENTITY_VERIFIED                       after step 1-2
R02_3_READ_ONLY_CAPABILITIES_VERIFIED         after steps 3-5
R02_4_MUTATION_TEST_AUTHORIZED                requires explicit user authorization
R02_5_HOSTED_COMPONENT_COMPATIBILITY_VERIFIED after steps 6-9
R02_6_FULL_MODEL_C_BOOTSTRAP_VERIFIED         after steps 11-12
R02_7_MIGRATION_CUTOVER_VERIFIED              after step 10 + the adjudication above
R02_RESOLVED
```

No state may be skipped. Reaching `R02_RESOLVED` is what clears
`hosted_compatibility.proven` in `db/AUTHORITY.json` — and nothing else may.
