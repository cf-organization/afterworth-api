# Current authoritative schema ↔ repository reconciliation

```
SNAPSHOT      live-schema-20260827.sql   sha256 a21df219…1f8b7   VERIFIED, schema-only
CLASSIFICATION CURRENT AUTHORITATIVE SCHEMA SNAPSHOT
PRE-0001      NOT RECOVERABLE FROM CURRENT REPOSITORY EVIDENCE  (unchanged)
INSTRUMENT    scripts/reconcileSchema.mjs  ·  read-only, offline, cannot express a remote target
REMOTE ACCESS 0 reads · 0 writes · 0 migrations executed · 0 production mutations
```

## The bootstrap gap, by category

Live objects reconciled: **339**. Of these **198** have a current-state base definition, **120** can
be built only by replaying historical migrations, and **20** cannot be built by any deployable
repository artifact.

### Irreducible — no deployable artifact creates these (20)

| object | kind | why |
|---|---|---|
| `assets` (+ `assets_read`, `assets_write`, 2 indexes, RLS) | table | **Orphan.** Nothing in `db/` creates or references it. |
| `beneficiaries`, `notifications` (+ RLS, `beneficiaries_write`, `notifications_self`, 2 indexes) | table | Only `CREATE` is in `db/tests/preamble_real_auth.sql`. |
| `rls_auto_enable` | function | `event_trigger` that auto-enables RLS on new tables. Absent from `db/`. |
| `estate_memberships_check_primary_user`, `estates_ensure_primary_user_membership` | trigger | Present in `db/` **only inside comments**. No executable statement creates them. |
| `pg_stat_statements`, `supabase_vault`, `uuid-ossp`, `pgcrypto` | extension | Platform prerequisites, not application defects. |

> ### Correction — `assets` is NOT an orphan, and NOT a legacy candidate
>
> The first version of this document called `public.assets` an orphan with "the shape of a legacy
> table left in place". **That was wrong, and the error was one of scope**: the search covered
> `afterworth-api`, `afterworth-mobile` and `afterworth-admin`, and there is a fourth repository.
>
> `afterworth-app` — the predecessor **SwiftUI iOS app**, `cf-organization/afterworth-app` — holds
> both a live consumer and the missing provenance:
>
> - `AfterWorth/Services/APIService.swift` calls `client.from("assets").select()`, `.insert()` and
>   `.delete()`.
> - `AfterWorth/supabase/migrations/0002b_invitations.sql` contains `assets_read` and `assets_write`
>   whose predicates are **semantically identical** to the live policies, plus `beneficiaries_write`
>   and `notifications_self`.
>
> That app is not retired. Its own go/no-go brief (2026-07-26) records the RN migration as
> incremental with "the SwiftUI app keeps shipping as a rollback the entire way", on a ~3–3.5 month
> estimate — i.e. still in progress today.
>
> **`public.assets` is LIVE-AND-UNDOCUMENTED, not legacy.** Dropping it would break the shipping iOS
> client. The absence was real; the interpretation was not.

Within the *api* schema `assets` is referenced by nothing — no FK targets it, no function body
mentions it — which is what made the wrong reading available. Its column set (`asset_type`,
`institution`, `identifier_last4`) is superseded by `estate_assets` for the RN client, so the two
tables serve two different clients during the migration window.

`afterworth-app`'s migrations begin at **0002** and contain no `create table … assets`. So a fourth
repository has now been checked and **pre-0001 remains unrecoverable** — the base predates that repo
too.

## What the instrument got wrong first, and how it was caught

Every figure below was published by an earlier run of this same tool and was **false**. Each was
found by a positive control, never by reading output and believing it.

| claimed | actual | cause |
|---|---|---|
| 201/201 repository files unparseable; 293-object gap | 0 unparseable; 142 | The CLI strips `--` comments from its dump, so `^CREATE` matched there. Every `db/` file has a comment header, so the same parser saw `-- header\ncreate table …` as one statement. **The parser passed on the snapshot by luck.** |
| all 36 policies apply to role `public` | 27 public, 9 authenticated | `${QN}` inside a **regex literal**, where it never interpolates. A security-relevant field that failed **open**. |
| `verification_level` has no repository definition | created in `db/tables/jurisdiction_policy.sql` | Created inside a `do $$ … if not exists … $$` guard; the block was treated as opaque. |
| `audit_logs_id_seq` has no repository definition | created by `id bigserial` in migration 0011 | pg_dump expands `bigserial` into explicit DDL. Same object, two spellings. |
| `parseRoles` fails closed on an unreadable `TO` | it returned `public` | Presence and readability of the clause were conflated into one regex. Caught by the test written to assert the property the comment already claimed. |

The last one matters most: the documentation asserted a fail-closed guarantee that the code did not
implement, and it survived the fix that was supposed to introduce it.

## Ordering and dependencies

83 foreign keys: **38 reference `auth.users`** (platform prerequisite — `auth` must exist before any
application table), 45 reference `public` tables. No cycles among application tables.
`owner_notice_outbox` self-references, which is orderable within one statement.

Application-owned objects live in a **platform** schema and are excluded from the dump by design:
`storage.objects.documents_estate_read` and `documents_estate_insert`. They are captured only by the
C2 catalog supplement. Any bootstrap that dumps `public` alone will silently omit them.

## Security observations — adjudication only, no fixes made

| # | observation | severity | evidence |
|---|---|---|---|
| S1 | 41/41 tables have RLS enabled; **0** use `FORCE`. | **Not a finding.** | `FORCE` only affects the table *owner* (`postgres`). Clients connect as `anon`/`authenticated`, which are not owners, so RLS applies to them regardless. Absence of FORCE is normal Supabase posture. |
| S2 | 21 RLS-enabled tables have **zero policies**. | **Not a finding — by design.** | RLS-on + no policy = deny-all. These tables have no client `GRANT` either, so they are unreachable by `anon`/`authenticated` twice over. This is the documented RPC-only pattern. `connection_secrets` has no GRANT and no policy. |
| S3 | 27 of 36 policies apply to `PUBLIC` rather than `authenticated`. | **LOW** | `PUBLIC` includes `anon`. Currently unreachable because `anon` holds no table GRANT anywhere, so this is imprecision, not exposure. It is defence-in-depth that depends on a grant table staying empty. |
| S4 | 131/147 functions are `SECURITY DEFINER`. | **Not a finding.** | **All 131 set an explicit `search_path`** — zero exceptions. The 104 `REVOKE ALL ON FUNCTION` / 83 re-`GRANT` pattern is default-deny then explicit allow. |
| S5 | `rls_auto_enable` is an event trigger with no repository definition. | **MEDIUM (governance)** | A live safety mechanism that auto-enables RLS on newly created tables exists only in production. A fresh environment built from the repository would silently lack it — new tables would be created without RLS and nothing would say so. |
| S6 | `public.assets` retains RLS + 2 policies but no provenance. | **LOW (governance)** | Not an exposure — its policies are `owner_id = auth.uid()` scoped. It is unowned surface area. |

Default privileges grant only to `postgres`. No `anon` table grants exist.

## What this does not establish

- It does **not** establish that migrations 0001–0060 replay onto any base. That remains
  `FRESH_DATABASE_FAILED`.
- It does **not** establish that `assets` is safe to drop. It establishes that the repository does not
  explain it.
- Client-code evidence about `assets` is **absent, not negative**: the positive control (`estates`)
  also returned nothing, because the app reaches tables through RPC rather than direct reads. No
  conclusion was drawn from it.
