# Supabase SQL Editor — observed hazard for reviewed R-02 / Model C statements

```
SEVERITY   material for hosted execution planning
OBSERVED   2026-08-30, afterworth-nonprod (qxzeougbaarecaiiqsay), event-trigger probe v1
STATUS     mitigated by an execution rule, narrowly scoped
```

## What was observed

The reviewed probe statement was:

```sql
create event trigger r02_probe_event_trigger_v1
  on ddl_command_end
  when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function public.r02_probe_event_fn_v1();
```

Executed in the Dashboard SQL Editor, the following happened — these are **observations**, listed
without inference:

1. The editor displayed **"Potential issue detected"**.
2. The warning stated the query **created a table without RLS**.
3. The warning surfaced **`AS`** as though it were a relation.
4. Two options were offered: **"Run without RLS"** and **"Run and enable RLS"**.
5. Choosing **"Run and enable RLS"** produced: **`ERROR: 42P01: relation "AS" does not exist`**.
6. Re-running the **identical, SHA-pinned** statement and choosing **"Run without RLS"** **succeeded**.

## What this is, and what it is not

**Classification: `SUPABASE_SQL_EDITOR_RLS_ASSISTANT_FALSE_POSITIVE`.**

The statement contains the *string literals* `'CREATE TABLE'`, `'CREATE TABLE AS'` and
`'SELECT INTO'` — they are **command tags the trigger listens for**, not DDL it performs. The editor's
RLS assistant evidently treated them as table-creation syntax and intervened.

**It is not a PostgreSQL privilege refusal.** No permission error was returned; `42P01` is
"relation does not exist". The identical statement succeeded moments later. Attributing this to
`rolsuper = false` would have been wrong, and would have led to redesigning Model C phase 120 around
a constraint that does not exist.

**What is NOT claimed:** the exact internal mechanism. Whether the assistant rewrites the SQL,
wraps it, or parses it for advice is undocumented, and nothing here asserts which. The evidence
supports the *behaviour*, not the implementation.

## Which Model C statements are exposed

Scanned across all 13 bootstrap phases, with string literals masked to separate real DDL from tag
text:

| class | count | notes |
|---|---|---|
| **A · real table creation** | **41** | genuine `CREATE TABLE` in phase 30. Model C is itself responsible for their RLS — phase 80 enables it on all 41. |
| **B · tag/literal false-positive candidates** | **2** | `60_functions.sql` (`rls_auto_enable` body lists the command tags) and `120_event_triggers.sql` (`WHEN TAG IN (…)`) |
| **C · other** | 0 | |

The two class-B statements are the same shape that produced the observed false positive.

## Execution rule — narrowly scoped

> For the reviewed R-02 / Model C statements whose **command-tag literals** trigger the assistant,
> do **not** accept automatic RLS intervention. Execute the reviewed statement unmodified.

**This is not a general recommendation to bypass RLS warnings.** It is scoped to statements that are
(a) part of a reviewed, SHA-pinned artifact and (b) demonstrably flagged because of tag literals
rather than real table creation.

For the **41 class-A** statements the question is different and has not been settled by evidence: they
*do* create tables, and Model C enables RLS on every one of them in phase 80. Accepting a Dashboard
RLS transformation there would inject unreviewed changes into canonical DDL, so the same rule
applies — **the SQL that executes must remain the reviewed SQL** — but the reasoning is "do not let
tooling edit canonical artifacts", not "the warning is wrong".

**Open item:** whether the assistant modifies the submitted SQL or only advises is unverified. The
bootstrap rehearsal must therefore verify the *result* (phase 80 enables RLS on all 41 tables, and
POST equivalence holds) rather than trusting that what ran was what was pasted.
