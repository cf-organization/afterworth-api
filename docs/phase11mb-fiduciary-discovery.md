# Phase 11-MB — fiduciary estate discovery

**STATUS: DEPLOYMENT_REQUIRED.** Claude does not execute production SQL.

This ships **only** the discovery routine. The provisioning correction it enables is deliberately
**not** in this artifact — see §7, because the ordering is the safety property.

> **TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE.** Production release requires two distinct human
> operators.

---

## 1 · The artifact

```
build:   node scripts/buildFiduciaryDiscoveryBundle.mjs
verify:  node scripts/buildFiduciaryDiscoveryBundle.mjs --check
path:    db/bundles/fiduciary_discovery_bundle.sql
```

**SHA256** `7ab65b386512cb1d1786c5196fab9d7c16e4bf7358d7ba362b4a2e0199c2634a`

```
shasum -a 256 db/bundles/fiduciary_discovery_bundle.sql
```

**Determinism** — three rebuilds in one session, identical digests.

## 2 · Contents

| # | Part | What it adds |
|---|---|---|
| 1 | `db/functions/fiduciary_estate_discovery.sql` | `get_my_fiduciary_estates()` |

**No migration.** No table, no constraint, no column, no existing body changed. One new routine and its
two privilege statements.

```sql
get_my_fiduciary_estates() returns table(estate_id uuid, estate_display_name text, capacity text)
```

- `security definer`, `stable`, `set search_path to 'public'`
- `revoke execute … from public, anon` · `grant execute … to authenticated`
- Scoped to `auth.uid()`; **zero arguments**, so no caller can name another subject
- One row per estate; `min(designation_type)` reproduces `initiate_death_verification_case`'s tiebreak
  (`order by designation_type limit 1` → `executor` precedes `trustee`)

## 3 · Why it exists

`resolve_membership` builds `additionalContexts` from `estate_memberships` **alone** — it never queries
`estate_designations`. So an estate reachable only through a fiduciary designation could never be
listed, activated, or reached at `/executor`. Provisioning bridged that gap by forcing the invitation's
`proposed_role` to `beneficiary`, which manufactures a disclosure class as a side effect of granting
workflow capacity. **This routine removes the reason for that.**

`get_executor_workspace` already answers *may I act on this estate* from the designation alone. What did
not exist was *which estates*. This adds exactly that.

## 4 · The one new disclosure, named rather than slipped in

`estate_display_name`.

No existing routine gives a designation-only participant the estate's name: `get_executor_workspace`
returns capacity, process and verification state and **no display metadata at all**;
`resolve_membership` returns `e.name` only to people holding a membership; the invitation preview gates
it behind `preview_visibility->>'showEstateName'`.

It is here because a selector row that cannot name the estate cannot be chosen between, and an executor
administering an estate needs to know which one it is — a beneficiary already learns the same string.
It is owner-authored free text, it is the only content field in the payload, and dropping it is a
one-line change if product decides otherwise.

## 5 · Pre-flight checks, already run

| Check | Result |
|---|---|
| `--check` (3 positive controls) | pass |
| Pure SQL, no meta-commands | pass (0) |
| Exactly one `begin;` / `commit;` | pass |
| **Atomicity against real Postgres** | **`applies=true rollback=true`** — a real state delta, not `NO_STATE_DELTA` |
| Determinism (3 rebuilds) | identical |
| SQL authorization suite | **377** assertions (+13) |
| Security mutations | **5/5 killed** |
| vitest | 358 |
| `tsc` | clean |
| source ↔ deployment drift | exit 0 |

## 6 · Post-deployment verifiers

Read-only. Run in order.

```sql
-- 1 · the routine exists at the expected signature
select to_regprocedure('public.get_my_fiduciary_estates()') is not null as present;
-- expect: t

-- 2 · it takes NO argument (a caller must not be able to name another subject)
select pronargs as should_be_zero
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname='get_my_fiduciary_estates';
-- expect: 0

-- 3 · the privilege posture: authenticated yes, anon no
select has_function_privilege('authenticated','public.get_my_fiduciary_estates()','execute') as client_can_read,
       has_function_privilege('anon','public.get_my_fiduciary_estates()','execute')          as anon_can_read;
-- expect: t, f

-- 4 · the payload is exactly three columns and carries no estate content
select array_to_string(proargnames, ',') as columns
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname='get_my_fiduciary_estates';
-- expect: estate_id,estate_display_name,capacity

-- 5 · it is scoped to the caller and to ACTIVE designations only
select prosrc like '%auth.uid()%'        as self_scoped,
       prosrc like '%''active''%'        as active_only
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname='get_my_fiduciary_estates';
-- expect: t, t

-- 6 · PROVISIONING IS UNCHANGED BY THIS PASTE (it must still force the role — see §7)
select prosrc like '%p_proposed_role := ''beneficiary''%' as provisioning_untouched
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname='create_invitation';
-- expect: t
```

**Verifier 6 is the one not to skip.** It asserts this artifact did *not* change provisioning. If it
answers `f`, something else altered `create_invitation` and the ordering guarantee in §7 no longer
holds.

### Read-only smoke probe

Signed in as any authenticated persona:

```
POST {SUPABASE_URL}/rest/v1/rpc/get_my_fiduciary_estates   →  200  []
```

An empty array is the **correct** result for anyone holding no designation — which is currently every
identity in the project. A `404 PGRST202` means the routine is not deployed.

## 7 · What is NOT in here, and why the ordering matters

The provisioning correction — removing `p_proposed_role := 'beneficiary'` from `create_invitation` —
is **not** in this artifact, and must not be deployed until the mobile selector consumes this routine.

Deployed in the wrong order, a newly provisioned fiduciary would get a designation, **no** membership,
and an estate the app cannot find: correctly authorized and permanently unable to reach the workflow.
That is the failure Stage 5 of the brief names as the thing not to do. Two artifacts is what makes the
ordering enforceable rather than remembered.

**Deploy order:**

1. **This artifact** (safe now — purely additive, grants nothing, changes no existing behaviour).
2. Mobile: independent-axis context model + selector merge, consuming this routine.
3. *Then* the provisioning correction, as its own artifact.
4. *Then* the standing fiduciary fixture.

## 8 · Rollback

`drop function if exists public.get_my_fiduciary_estates();`

Clean and complete — nothing depends on it yet (step 2 above has not shipped). No data is written by
this routine, so there is nothing to strand.

## 9 · Recovery / re-paste

Idempotent. Re-pasting is safe and is the correct response to any partial or failed apply.
