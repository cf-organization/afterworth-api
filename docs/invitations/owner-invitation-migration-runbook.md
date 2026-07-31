# Migration 0042 — runbook

**Nothing in this migration has been applied.** No local Supabase environment is configured in
this repository (`supabase/config.toml` absent), so per the task constraints no environment was
improvised. These are the exact manual steps.

## 1 · Prerequisites

- A **non-production** Supabase project. Do not run this against production.
- Migrations 0001–0041 applied; 0042 is the next number and the sequence is contiguous.
- `psql` available (confirmed present).

## 2 · Files

| File | Purpose |
|---|---|
| `db/migrations/0042_20260731_owner_invitation_management.sql` | the migration |
| `db/verification/0042_owner_invitation_verification.sql` | assertion harness (rolls back) |

## 3 · Apply (non-production)

```bash
export NONPROD_DB_URL='postgresql://…'      # non-production ONLY
psql "$NONPROD_DB_URL" -v ON_ERROR_STOP=1 \
  -f db/migrations/0042_20260731_owner_invitation_management.sql
```

Expected: `BEGIN … COMMIT` with no notices. The migration is a single transaction — a failure
leaves the database untouched.

## 4 · Verify

```bash
psql "$NONPROD_DB_URL" -v ON_ERROR_STOP=1 \
  -f db/verification/0042_owner_invitation_verification.sql
```

Expected final line: `ALL ASSERTIONS PASSED`. The harness **rolls back**, so it persists nothing
even on a disposable project. Any failure aborts at the first bad assertion and names it.

## 5 · Spot checks

```sql
-- no client grant was added to invitations or the outbox
select table_name, grantee, privilege_type from information_schema.role_table_grants
 where table_name in ('invitations','invitation_delivery_outbox')
   and grantee in ('authenticated','anon');           -- expect ZERO rows

-- the trusted worker surface is service_role only
select routine_name, grantee from information_schema.role_routine_grants
 where routine_name in ('issue_invitation_delivery','record_invitation_delivery_failure');
                                                       -- expect service_role only

-- every new DEFINER function pins search_path
select proname, proconfig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and proname like '%invitation%' and prosecdef;
```

## 6 · Failure interpretation

| Symptom | Meaning |
|---|---|
| `relation "profiles" does not exist` | migrations not fully applied; stop |
| duplicate-index error on re-run | already applied — `create … if not exists` covers repeats, so investigate before forcing |
| an assertion aborts | the named invariant is broken; do **not** proceed to API work |

## 7 · Rollback

See [owner-invitation-rollback.md](owner-invitation-rollback.md).

## 8 · ★ Dependencies before this reaches a user

1. **API layer** — five owner actions wired to the RPCs with the sanitized error mapping in the
   contract doc.
2. **Delivery worker** — ★ **REQUIRED**. Until one exists, `create_estate_invitation` produces an
   invitation whose token has never been issued, so it **cannot be accepted by anyone**. Nothing is
   broken by that (it is fail-closed), but no invitation reaches a recipient.
3. **Mobile** — blocked on 1 and 2. See the readiness gate in the design record.

## 9 · Delivery worker contract

A trusted worker (service-role, `CRON_SECRET`-gated, modelled on
`/api/claims/drain_purge_outbox`) must:

1. select `id` from `invitation_delivery_outbox where status = 'pending'`;
2. call `issue_invitation_delivery(id)` — returns the raw token **transiently**;
3. build the link and send it via an email/SMS provider (**none exists in this repo yet**);
4. on failure call `record_invitation_delivery_failure(id, error)`;
5. never log, persist, or forward the raw token.
