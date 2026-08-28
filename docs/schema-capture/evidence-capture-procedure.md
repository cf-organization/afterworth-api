# Model C final evidence capture — manual procedure

```
STATUS:        PREPARED, NOT EXECUTED
EXECUTED BY:   the user, in the Supabase SQL Editor, project afterworth-dev
CLAUDE:        0 Supabase reads · 0 writes · 0 migrations · 0 production mutations
QUERIES:       docs/schema-capture/evidence-queries.sql  (4 statements, all SELECT)
SAFETY AUDIT:  passed, with positive controls proving the auditor detects real writes
```

## Why these two captures exist

Neither gap is a defect in the snapshot. Both are consequences of what `supabase db dump` covers:

| gap | why it is missing | why it matters to Model C |
|---|---|---|
| the event-trigger binding for `public.rls_auto_enable` | the dump emits no `CREATE EVENT TRIGGER` at all | a bootstrap that omits it would create tables with **no RLS** and say nothing |
| the two `storage.objects` policies | the dump excludes platform schemas | Model C phase 110 would otherwise source from an unhashed artifact |

**Absence from the snapshot is not absence from the database.** That is the whole reason these are
queries rather than inferences.

## Execution — **USER MUST RUN THIS IN THE SUPABASE SQL EDITOR**

Project: **afterworth-dev**. Open `docs/schema-capture/evidence-queries.sql` and run the four
statements. Run **Q1b and Q2b** — they are the positive controls, and without them a zero-row result
from Q1 cannot be distinguished from a permissions failure.

No credential is required beyond the dashboard session that already exists. **Do not paste a
password, service-role key, access token, connection string or `.env` content anywhere.**

## Export and hash

Export each result **unmodified** — do not open it in a spreadsheet and re-save, and do not tidy the
formatting. The hash is only meaningful for the bytes the server produced.

```bash
cd ~/aw-schema-capture

# after exporting each result set:
shasum -a 256 event-triggers-20260828.csv
shasum -a 256 storage-policies-20260828.csv
wc -l event-triggers-20260828.csv storage-policies-20260828.csv
```

If the SQL Editor's CSV export mangles the multi-line `function_definition` or the `qual` /
`with_check` predicates — both contain newlines and commas — **say so rather than hand-repairing
it**. A hand-edited export is an artifact whose provenance can no longer be stated, which is the
same failure as editing a dump. In that case re-run the query and copy the raw result, or use the
JSON form in Q1/Q2 output rather than CSV.

## What to return

Row counts · the two SHA-256 values · the exported files if analysis is wanted.

**Never**: DB password · service-role key · access token · connection string · `.env`.
