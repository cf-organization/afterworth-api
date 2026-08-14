# Phase 11-MC — fiduciary provisioning correction

**STATUS: DEPLOYMENT_REQUIRED.** Claude does not execute production SQL.

**READ §5 BEFORE PASTING.** The Vercel side must already be live, and merging this PR is what makes it
so. Pasting against the old routes breaks every executor acceptance.

> **TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE.** Production release requires two distinct human
> operators.

---

## 1 · The artifact

```
build:   node scripts/buildProvisioningCorrectionBundle.mjs
verify:  node scripts/buildProvisioningCorrectionBundle.mjs --check
path:    db/bundles/provisioning_correction_bundle.sql
```

**SHA256** `2014032dc5dfadb2319351ec4f3e1ea33f705d1aaa5a6267941c94ab1bcd8718`

```
shasum -a 256 db/bundles/provisioning_correction_bundle.sql
```

**Determinism** — three rebuilds in one session, identical digests.

## 2 · Contents, in paste order

| # | Part | Why |
|---|---|---|
| 1 | `db/functions/provision_from_invitation.sql` | **the correction** — gates the membership insert and beneficiary self-link on the invitation's `kind` |
| 2 | `db/functions/accept_invitation.sql` | stops reporting a role/status for an acceptance that created no membership |
| 3 | `db/functions/bind_invitation_token.sql` | same, on the token path |
| 4 | `db/functions/create_invitation.sql` | **documentation only** — the forced line is unchanged; the file ships so the deployed body carries the comment explaining why it is now inert |

**No migration.** No table, column, constraint or grant changes.

## 3 · What changes

**Before:** every acceptance inserted an approved `estate_memberships` row at the invitation's
`proposed_role`, which `create_invitation` forces to `'beneficiary'` for executor/trustee. Granting
workflow capacity silently granted a disclosure class.

**After:** an executor/trustee acceptance stamps the designation and creates **no** membership, **no**
beneficiary linkage and **no** grant. The recipient is discoverable through
`get_my_fiduciary_estates()` and authorized through `get_executor_workspace`.

Unchanged: beneficiary and professional-delegate invitations still provision their memberships exactly
as before, and an independently-held access class is **reported, never rewritten**.

### The gate is `kind`, not `proposed_role` — and that is the whole compatibility story

`proposed_role` is **persisted at CREATE time**. Every executor invitation already in the table carries
`'beneficiary'`, so a provisioner keyed on that column would honour it forever and **correcting
`create_invitation` alone fixes nothing for outstanding invitations**. `kind` is immutable and
authoritative, so new and outstanding invitations are both handled with no data migration and nothing
to cancel.

**Removing the forced line alone would have been worse than leaving it.** Without the `kind` gate, an
executor invitation minted with `p_proposed_role = 'professional_delegate'` would provision a
*professional delegate* membership — a different manufactured disclosure class, and a worse one.

### Why the forced line stays

`invitations.proposed_role` is `text NOT NULL` with
`check (proposed_role = any (array['beneficiary','professional_delegate']))`. There is no value meaning
"no access class". Making it nullable is DDL on a live table and is recorded as a follow-up, together
with surfacing `kind` in `resolve_membership`'s pending-invitation payload — today a fiduciary
invitation card can still show the wrong relationship **word**, because the client maps `proposedRole`
to a presentation-only label. `features/invitations/model.ts` states outright that nothing gates on it.

## 4 · Pre-flight checks, already run

| Check | Result |
|---|---|
| `--check` (5 positive controls) | pass |
| Pure SQL, no meta-commands | pass (0) |
| Exactly one `begin;` / `commit;` | pass |
| Applies cleanly against real Postgres | pass |
| Rolls back completely when corrupted mid-file | pass |
| Determinism (3 rebuilds) | identical |
| SQL authorization suite | **390** assertions (+13) |
| Security mutations | **6/6 killed** |
| vitest | 374 |
| `tsc` | clean |
| source ↔ deployment drift | exit 0 |

**Atomicity is `NO_STATE_DELTA`, and that is honest rather than disappointing.** The witness is body
content (does `provision_from_invitation` carry the `kind` gate), and
`lifecycle_notifications_bundle` — rebuilt from the same corrected file — installs the corrected body
before this artifact runs. The harness excludes such a witness from its verdict instead of scoring it.
Atomicity here rests on structure: pure SQL, one transaction, both asserted.

## 5 · Deployment order — the Vercel side FIRST

**This is not a preference.** `lib/invitations/accept.ts` and `lib/invitations/bind.ts` previously
required all five RPC columns to be strings and returned `502 upstream_unexpected_shape` otherwise. A
fiduciary acceptance now returns three nulls, so pasting this SQL against the **old** routes would make
every executor acceptance look like a server fault to the invitee — while the designation had in fact
committed.

Those routes ship with the Vercel build on merge to `main`, so:

1. **Merge this PR** → Vercel deploys the tolerant routes.
2. **Confirm the production deployment is Ready** (`vercel inspect https://app.minifam.com`).
3. **Then paste** `db/bundles/provisioning_correction_bundle.sql`.

| | Before the paste | After the paste |
|---|---|---|
| New executor/trustee invitations | manufacture a beneficiary membership | designation-only |
| Outstanding executor/trustee invitations | manufacture a beneficiary membership on accept | designation-only on accept |
| Beneficiary / delegate invitations | unchanged | unchanged |
| Existing memberships and designations | untouched | untouched |

## 6 · Post-deployment verifiers

Read-only. Run in order.

```sql
-- 1 · the correction is deployed, and keys on kind rather than the persisted column
select prosrc like '%v_is_fiduciary%'                          as gate_present,
       prosrc like '%coalesce(v_inv.kind in%'                  as null_safe,
       prosrc like '%if not v_is_fiduciary then%'              as branch_present
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname='provision_from_invitation';
-- expect: t, t, t

-- 2 · the designation half SURVIVED the correction (a fiduciary must not end with neither authority)
select prosrc like '%insert into public.estate_designations%'   as designation_kept,
       prosrc like '%source_invitation_id%'                     as provenance_kept
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname='provision_from_invitation';
-- expect: t, t

-- 3 · both callers report a membership-less acceptance honestly
select p.proname, prosrc like '%v_membership_id is null%' as null_guarded
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname in ('accept_invitation','bind_invitation_token')
 order by p.proname;
-- expect: both t

-- 4 · create_invitation is unchanged in behaviour and carries the new comment
select prosrc like '%p_proposed_role := ''beneficiary''%' as still_derives,
       prosrc like '%INERT%'                              as comment_shipped
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname='create_invitation';
-- expect: t, t

-- 5 · no membership row anywhere carries a fiduciary capacity (should already be true; now enforced)
select count(*) as should_be_zero
  from public.estate_memberships where role in ('executor','trustee');
-- expect: 0
```

### Read-only smoke probe

```
POST {SUPABASE_URL}/rest/v1/rpc/get_my_fiduciary_estates   →  200  []
```

Unchanged by this paste — `[]` remains correct for anyone holding no designation.

**Do not accept an invitation as a smoke test.** Acceptance is a real authority grant on a real estate.

## 7 · Outstanding invitations

**Census: UNVERIFIABLE, not zero.** `service_role` holds no SELECT on `public.invitations` — HTTP 403,
Posture B working as designed. The count of outstanding `kind in ('executor','trustee')` invitations in
`pending`/`matched` could not be obtained read-only.

**It does not gate the deployment**, because the correction keys on `kind` and therefore handles
outstanding invitations correctly whatever the count. Nothing needs cancelling. If you want the number,
verifier 5 above plus:

```sql
select count(*) from public.invitations
 where kind in ('executor','trustee') and status in ('pending','matched') and expires_at > now();
```

## 8 · Legacy rows

**LEGACY FIDUCIARY-DERIVED BENEFICIARY MEMBERSHIPS: PRESERVED.** Nothing is cleaned up by this phase.

Provenance is decidable — `estate_memberships.source_invitation_id → invitations.kind` identifies
mechanically-manufactured rows — but automatic deletion could remove authority a user now depends on.
Cleanup is a separate product/data decision. **No silent cleanup.**

## 9 · Rollback

Re-paste this artifact built from the parent commit. All four parts are `create or replace` on unchanged
signatures, so privileges are preserved in both directions.

Rolling back **restores the defect**: new fiduciary acceptances would manufacture beneficiary
memberships again. Nothing is stranded either way — the correction writes no new state, it declines to
write some.

## 10 · Recovery / re-paste

Idempotent. Re-pasting is safe and is the correct response to any partial or failed apply.
