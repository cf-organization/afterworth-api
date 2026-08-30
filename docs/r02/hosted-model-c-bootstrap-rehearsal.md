# R-02 · hosted Model C bootstrap rehearsal (design)

```
STATUS      DESIGN ONLY — NOT AUTHORIZED
GUARD       model_c_bootstrap_0060_authorized = false
OPERATION   MODEL_C_BOOTSTRAP_0060
TARGET      afterworth-nonprod · qxzeougbaarecaiiqsay · us-west-2
VERSION     0060  (fixed cutover base, rolling = false)
STATE       R02_5_HOSTED_COMPONENT_COMPATIBILITY_VERIFIED
```

## The question

> Can the fixed Model C bootstrap through VERSION 0060 be applied to the virgin `afterworth-nonprod`
> environment and produce a schema equivalent to `bootstrap@0060`, while preserving the platform
> contract and Supabase-owned surfaces?

That is `R02_6`. **Not** migration cutover, which is later and separate.

## Authority path

```
Supabase platform prerequisites
  → db/bootstrap @ VERSION 0060      (13 phases, 921 executable statements)
  → db/migrations/0061+              only when separately authorized
```

**Migrations 0001–0060 are NOT replayed.** They are the immutable historical record; the bootstrap
already contains their outcome, and they cannot build from zero anyway. `db/bootstrap` stays fixed at
0060 — it does not roll forward.

## Inventory, recomputed from current main

13 phases · **921 executable statements** (+28 `SET` preamble lines).

41 tables · 415 columns · 147 functions · 36 public policies · **2 storage policies** · 59 indexes ·
9 table triggers · 176 constraints · 1 enum · 1 sequence · 0 views · **2 extensions created** ·
101 GRANT · 104 REVOKE · 3 default privileges · 41 RLS enabled · 0 FORCE · 1 event trigger.

Three figures differ from earlier stated numbers and are **explained, not adjusted**:

- **policies 38 vs 36** — 36 public (phase 90) **plus** 2 storage (phase 110). The historical 36
  counts public only; both are right for different questions.
- **extensions 2 vs 4** — phase 10 creates `pgcrypto` and `uuid-ossp`. `pg_stat_statements` and
  `supabase_vault` are platform-supplied and recorded as prerequisites in phase 00, never created.
- **921 vs 922** — `db/bootstrap/manifest.json` counts the phase-00 *recorded platform-extension
  note* as an entry; it is a comment, not an executable statement.

## Execution model — phase by phase, never one paste

Each phase is a separate SQL Editor execution, in numeric order, with its own verification.
`docs/r02/model-c-bootstrap-0060-manifest.json` pins every phase's **sha256**, the phase order, and a
**cumulative hash**.

**Authorization is by hash, not by inspection.** Verb-level allowlisting worked for a six-statement
probe; it cannot make 921 statements safe, because an allowlist permissive enough to admit
`CREATE TABLE`, `GRANT`, `CREATE POLICY` and `CREATE EVENT TRIGGER` would also admit one substituted
statement hidden among them. `scripts/lib/bootstrapExecutionAudit.mjs` refuses on any phase hash
mismatch, missing phase, extra phase, reorder, cumulative mismatch, version mismatch, target
mismatch, **any migration 0001–0060 in the execution set**, or **any write to
`supabase_migrations`**.

| phase | file | statements | class |
|---|---|---|---|
| 00 | `00_platform_contract.sql` | 1 | refusal gate — creates nothing |
| 10 | `10_extensions.sql` | 2 | extensions |
| 20 | `20_types.sql` | 1 | enum |
| 30 | `30_tables.sql` | 42 | tables + sequence |
| 40 | `40_constraints.sql` | 128 | constraints, defaults |
| 50 | `50_indexes.sql` | 59 | indexes |
| 60 | `60_functions.sql` | 147 | functions |
| 70 | `70_triggers.sql` | 9 | table triggers |
| 80 | `80_rls_enable.sql` | 41 | RLS enable |
| 90 | `90_policies.sql` | 36 | public policies |
| 100 | `100_grants.sql` | 452 | ownership, grants, revokes |
| 110 | `110_storage_policies.sql` | 2 | app policies on platform table |
| 120 | `120_event_triggers.sql` | 1 | `ensure_rls` |

## SQL Editor policy

See `docs/r02/supabase-sql-editor-risks.md`. Two phases (60, 120) contain command-tag literals of the
shape that produced the observed RLS-assistant false positive. **The SQL that executes must remain
the reviewed SQL** — do not accept automatic RLS intervention on canonical artifacts.

Because it is unverified whether the assistant *modifies* submitted SQL or only advises, verification
checks the **result**, not the submission: phase 80 must show RLS enabled on all 41 tables, and POST
equivalence must hold.

## PRE contract (SELECT-only, immediately before)

Virginity — AfterWorth tables/functions/policies **0**, `assets` absent, `rls_auto_enable` absent,
`ensure_rls` absent. Platform — `auth.users`, `auth.uid()`, `auth.jwt()`, `storage.objects`,
`storage.buckets`, `anon`, `authenticated`, `service_role`, `extensions` schema all present.
Extensions — required set available. Event triggers — platform baseline of 6 only, no application
trigger. Storage — 0 AfterWorth policies. Migration metadata — unchanged, no writes.

**Any application-owned object present ⇒ HALT.** Do not bootstrap onto non-virgin application state.

## Failure semantics — the hard part

A bootstrap creates hundreds of objects across 13 committed phases. **Whole-bootstrap rollback
through the Dashboard is not assumed to be practical.**

| where it fails | consequence |
|---|---|
| before phase 00 passes | nothing created — safe retry after fixing prerequisites |
| inside a phase | that phase is partially applied — **PARTIAL_BOOTSTRAP** |
| after earlier phases committed | earlier phases stand — **PARTIAL_BOOTSTRAP** |
| phase 120 (`ensure_rls`) | schema complete, event trigger missing — recoverable by re-running phase 120 alone once the cause is known |
| phase 110 (storage policies) | recoverable by re-running phase 110 alone |
| phase 100 (grants) | recoverable by re-running phase 100 alone |
| final equivalence check | no mutation occurred; investigate the drift |

Phases 100/110/120 are individually re-runnable because their statements are additive and
independently identifiable. Phases 30–90 are **not** assumed re-runnable mid-phase.

> **If recovery would require a destructive reset: HALT.** Classify the environment
> `PARTIAL_BOOTSTRAP` and return for separate authorization.
> `destructive_reset_authorized` is **false**. This design must not make reset and retry an
> implicit behaviour. **Do not drop large object sets to recover.**

## POST / equivalence contract

Use the existing canonical auditor (`scripts/bootstrapFreshRun.mjs`'s 27-dimension drift audit) —
**not a second, inconsistent definition of equivalence**. Dimensions: tables, columns, functions,
SECURITY DEFINER count and `search_path`, triggers, RLS enabled, FORCE RLS, public policies with
roles/commands/predicates, enum types, sequences, views, extensions, grants/revokes/default
privileges, constraints, indexes, storage policies, event trigger and its tags, plus identity-set
comparisons so a matching count with differing members still fails.

## Canonical phase-120 verification — closing the probe-v1 gap

Probe v1 proved `CREATE EVENT TRIGGER` is **accepted**, but its Stage 4 catalog snapshot was not captured. For the canonical object the rehearsal must capture, by `SELECT`, after creation:

`ensure_rls` exists · `evtevent = ddl_command_end` · tags `CREATE TABLE`, `CREATE TABLE AS`,
`SELECT INTO` · bound to `public.rls_auto_enable` · owner · `evtenabled` · and the function's
`prosecdef` and `search_path`.

## Virgin-to-bootstrapped difference manifest

Expected application-owned additions: +41 tables, +147 functions, +36 public policies, +2 storage
policies, +59 indexes, +9 triggers, +176 constraints, +1 enum, +1 sequence, +2 extensions,
+1 event trigger, plus grants/revokes/default privileges. **Platform-owned objects stay classified
separately**, so an unexpected hosted addition is visible rather than absorbed into a total.

## Local rehearsal is not hosted proof

Executed twice on ephemeral **PostgreSQL 17** (hosted reports 17.6): virgin → `bootstrap@0060` →
**BOOTSTRAP_EQUIVALENT** both times, byte-identical audits, ~4s each, all dimensions matching.

That proves the artifact is internally coherent and self-consistent. It does **not** prove hosted
behaviour: the local container grants superuser and applies a **platform shim** that fabricates
`auth`/`storage`, whereas hosted Supabase supplies the real thing under a non-superuser role.

## Exclusions

Not covered: migration cutover, migration metadata, `0061+`, production deployability, destructive
reset, and any protected project.
