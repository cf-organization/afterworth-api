# Database migrations (source of truth for schema DDL)

Until the Supabase CLI migration workflow is adopted, these `.sql` files are the
version-controlled record of schema changes (columns, constraints, RLS policies)
that the live database relies on. The live database is authoritative, but on a
reset these files are how the schema is rebuilt. This complements `db/functions/`
(RPC bodies) and `db/grants.sql` (table grants).

## Conventions
- One file per vertical slice, prefixed with a zero-padded number + ISO date:
  `NNNN_YYYYMMDD_<slice>.sql` (e.g. `0001_20260616_beneficiaries_live_read.sql`).
- Every statement is idempotent (`add column if not exists`; `drop policy if
  exists` then `create policy`; `create or replace`) so re-running is safe.
- A slice's file may grow as the slice is built; the finished file rebuilds the
  whole slice's DDL in order.

## What lives where (don't duplicate)
- Table GRANTs            -> `db/grants.sql`
- RPC / function bodies   -> `db/functions/*.sql`
- Columns, constraints, RLS policies -> here.

## Re-applying
Paste the file into the Supabase SQL editor and run, or use the Supabase CLI if
migrations are adopted.
