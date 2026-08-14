# Phase 11-MA — fiduciary provisioning authority: the defect, and why the fix needs a decision

**NO CODE WAS CHANGED. NO PRODUCTION DATA WAS TOUCHED. NO FIXTURE WAS MINTED. NO DEATH PROCESS WAS
STARTED.** This is Stages 0–3, 5 and 9, and it stops exactly where Stage 4 says to stop.

> **TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE.** Production release requires two distinct human
> operators.

---

## Stage 0 · Baseline

| Repo | HEAD == origin/main | Tree |
|---|---|---|
| afterworth-api | `40661ce` ✓ | clean |
| afterworth-mobile | `2acd54e` ✓ | clean |
| afterworth-admin | `fd7ef03` ✓ | foreign `M .gitignore`, `?? python3` — untouched |

| Check | Result |
|---|---|
| source/deployment drift | **exit 0** |
| notification catalog | **9 entries compared verbatim · EXACT** |
| 11-L | **DEPLOYED_AND_VERIFIED** (`death_process.halted` → `claimUpdate`) |
| `get_executor_workspace` | PRESENT |
| `estate_release_state` | LOCKED |
| operator console | ● Ready |

## Stage 1 · The defect, re-derived

### Where each thing happens

| Step | Location | What it does |
|---|---|---|
| role forced | `db/functions/create_invitation.sql:36` | `if p_kind in ('executor','trustee') then p_proposed_role := 'beneficiary';` |
| membership inserted | `db/functions/provision_from_invitation.sql:28–33` | `insert into estate_memberships (… role …) values (…, v_inv.proposed_role, 'approved', …)` |
| beneficiary self-link | `provision_from_invitation.sql:39–44` | if proposed_role is `beneficiary`, links a matching `beneficiaries` row by email/phone |
| designation stamped | `provision_from_invitation.sql:46–56` | `if v_inv.kind in ('executor','trustee')` → `estate_designations … status 'active'` + `designation.created` audit |

**The rule is confirmed, and it is unconditional:**

```
executor/trustee invitation
  → proposed_role FORCED to 'beneficiary'   (hardcoded, not a parameter, not a branch)
  → approved estate_memberships row at that role
  → estate_designations row, active
```

### Caller / consumer matrix

| Caller | Gate | Path to a designation |
|---|---|---|
| `create_invitation` | `invitation_write_gate` — **estate owner**, or admin+AAL2+freshness | the only minting routine |
| `admin_create_executor_invitation` | `admin_require_gate` + **break-glass** (`require_breakglass_justification`, HIGH-severity audit, returns a raw token) | **delegates to `create_invitation`** |
| `accept_invitation` | invitee identity guards | → `provision_from_invitation` |
| `bind_invitation_token` | token binding | → `provision_from_invitation` |
| `provision_from_invitation` | INTERNAL (revoked from public/anon/authenticated) | does both inserts |

**There is exactly one minting path.** Both the owner route and the break-glass admin route converge
on `create_invitation`, so the forced role applies identically to both — which answers Stage 9: the
two paths already share authority semantics, and the admin path grants no broader recipient authority
than the owner path. Neither should manufacture beneficiary standing, and both do.

### Who later assumes the membership exists

This is the load-bearing half, and it is why the obvious fix is wrong.

| Consumer | Reads | Consequence if the membership is absent |
|---|---|---|
| `resolve_membership` → `additionalContexts` | `estate_memberships` **only** | **The estate never appears in the user's context list** |
| mobile estate selector | consumes `additionalContexts` | the estate cannot be activated |
| `get_executor_workspace` | `is_estate_executor` — **designation only** | unaffected; still correctly authorized |

## Stage 5 · Routing / context dependency — answered

1. **Does `resolve_membership` require `estate_memberships`?** **Yes, exclusively.** `additionalContexts`
   is built from `estate_memberships m join estates e … where m.status='approved' and not
   is_ownership_role(m.role)`. **`estate_designations` is never queried anywhere in the routine.**
2. **Does the estate selector enumerate memberships only?** **Yes** — it consumes `additionalContexts`.
3. **Can a designation-only fiduciary reach `/executor` today?** **No.** The estate would never be
   offered as a context, so it can never be made active.
4. **Does `get_executor_workspace` require only the designation?** **Yes** — `authorized:false` comes
   from `is_estate_executor(p_estate, v_uid)` alone. Membership is not consulted.
5. **Would removing the beneficiary membership make the estate unreachable in mobile?** **Yes.**

**So the manufactured beneficiary membership is doing two jobs at once: it is the disclosure defect,
and it is the only routing mechanism.** Deleting the forced role without replacing the routing would
solve the authority defect by making the workflow unreachable — precisely what Stage 5 forbids.

## Stage 4 · Why this stops here

Stage 4's instruction is conditional, and the condition is met:

> If an `estate_membership` row is technically required for routing/context: **STOP** and inspect
> whether a distinct non-disclosure access class already exists. … If the schema cannot represent a
> designated fiduciary without a membership row, that is a schema/product decision. **STOP rather than
> inventing a role.**

**Inspected. No non-disclosure access class exists.** From the captured live definition
`db/tables/estate_memberships.sql`:

```sql
constraint estate_memberships_role_check
  check (role = any (array['primary_user','beneficiary','professional_delegate'])),
constraint estate_members_estate_id_user_id_key unique (estate_id, user_id),
```

All three permitted values are ownership or disclosure classes:

| Role | Meaning | Usable for fiduciary capacity? |
|---|---|---|
| `primary_user` | estate ownership | No — `is_ownership_role` treats it as the owner |
| `beneficiary` | disclosure recipient | No — this is the defect |
| `professional_delegate` | a different disclosure class | No — Stage 4 forbids the substitution |

`role` is `text` with a CHECK, so a fourth value is DDL, not a config change. And
`unique (estate_id, user_id)` means a person holds **at most one** membership per estate — so the
membership role cannot carry two meanings at once even if one wanted it to.

**The good news, and it is structural:** membership and designation are already **separate tables**.
Beneficiary disclosure and fiduciary capacity can coexist as independent authorities without either
overloading the other. The target invariant is representable. What is missing is only the
**discovery** projection.

## Stage 3 · Existing-data provenance

**Provenance exists and the distinction is decidable** — which is better than the Stage 3 brief
allowed for:

- `estate_memberships.source_invitation_id` → `invitations(id)` (indexed, `on delete set null`)
- `estate_designations.source_invitation_id` → `invitations(id)`

So for any beneficiary membership:

| Provenance | Classification |
|---|---|
| `source_invitation_id` → invitation with `kind in ('executor','trustee')` | **B — mechanically manufactured** by provisioning |
| `source_invitation_id` → invitation with `kind = 'beneficiary'` | **A — independently intended** |
| `source_invitation_id is null` | **A — independently intended** (or pre-dates invitations) |

**The counts could not be executed.** `service_role` holds **no** SELECT on `estate_designations`,
`estate_memberships` or `invitations` — all three answer **403**, which is this project's Posture B
working as designed (everything through DEFINER routines). Obtaining the counts needs either a new
admin-gated read projection or a human running SQL. **Nothing was mutated, and no count is asserted
here.**

Per Stage 8, the recommended first release preserves every existing row regardless: **new provisioning
corrected, existing rows untouched**, ambiguous rows recorded as legacy authority composition. No
silent cleanup.

## The three designs, and a recommendation

All three need a decision because all three are schema/product changes.

### A · Extend the membership vocabulary

Widen `estate_memberships_role_check` with a non-disclosure class (e.g. `fiduciary`), and stop forcing
`beneficiary`.

- Routing keeps working unchanged — `additionalContexts` already excludes only ownership roles.
- **Cost:** every consumer of `m.role` must be audited to prove the new value grants nothing —
  `displayRole`, disclosure tiers, beneficiary surfaces, the professional workspace, and the mobile
  client's role union. A single missed filter grants or denies wrongly.
- This is the "invent a role" path. Legitimate with product approval; it is what Stage 4 asks not to
  do unilaterally.

### B · Teach `resolve_membership` to union in designations

Emit a context for estates where the user holds an active designation, with no membership row created.

- Matches the target invariant exactly: designation → workflow capacity, discovery derived from the
  authoritative source for that capacity. Touches no disclosure code.
- **Cost:** changes the shape of a widely-consumed payload — a designation-derived context has no
  membership `id` and no membership `role`. Client decoders currently assume both.

### C · A separate fiduciary-estate projection *(recommended)*

Add one additive, read-only RPC — `get_my_fiduciary_estates()` — and have the estate selector union it
with `additionalContexts`. Stop forcing `beneficiary`. Create **no** membership row.

- **Smallest correct change.** No existing payload changes shape, so no existing decoder breaks.
- No new membership role, so no disclosure consumer needs re-auditing.
- 11-I already built the per-estate authority answer (`get_executor_workspace`); what is missing is
  only the **enumeration**, and that is exactly what this adds.
- Composes with Stage 7's dual-role case for free: a person who is independently a beneficiary keeps
  their membership and their grants, and gains a designation-derived fiduciary context alongside.
- **Cost:** one new RPC plus a mobile estate-selector change; the selector must merge two sources
  without double-listing an estate where the user is both beneficiary and fiduciary.

**Recommendation: C.** It corrects the authority model without inventing a role, without reshaping an
existing contract, and without touching a single disclosure code path.

## Status

**Stage 12: no bundle produced** — a bundle would encode a design that has not been chosen. Producing
one now would be the schema decision, made quietly.

**Remaining fixture blocker:** unchanged and now fully explained. The fiduciary fixture cannot be
minted without either accepting manufactured beneficiary standing (rejected by this phase's own
decision) or landing one of A/B/C first.
