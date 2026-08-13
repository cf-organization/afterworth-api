# Phase 11-F — Release Authorization + Owner Liveness Delivery

**Date:** 2026-08-12 · **Repos:** afterworth-api, afterworth-mobile
**Deployment: NOT PERFORMED.** 11-B/C/D/E/F are all source-merged and deployment-pending.

11-E built the challenge window and deliberately deferred two decisions: who may release, and how
long the window runs. 11-F implements the five approved decisions.

| Decision | Implementation |
|---|---|
| D1 · two-person rule | `authorize_release` refuses `reviewer_b = reviewer_a`; `release_authorizations` carries a table CHECK so no writer of any kind can record a one-person release; the old one-person `release_estate` is **dropped** |
| D2 · 7×24h, clock starts at dispatch | `release_safety_policy` seeded with `interval '7 days'` by migration 0055; `owner_notified_at` stamped in `dispatch_owner_safety_notice`; elapse measured from it |
| D3 · owner challenge strongest | unchanged from 11-E; strict `>` keeps the boundary tie with the owner |
| D4 · email minimum | `owner_notice_outbox` row + in-app notice, both committed in the dispatch transaction; an unresolvable address refuses the whole transition |
| D5 · owner-authored intent only | release writes no grant/tier/membership/designation; bracket-asserted |

## 1 · The state machine (7 states, 10 edges)

```
active → death_verification_pending → death_verified
       → owner_notification_dispatched     ← D2/D4: the owner was TOLD; the clock starts here
       → challenge_window
       → released                          ← D1: two distinct operators

any pre-released death state → challenge_halted   (owner challenge; terminal)
```

**The `death_verified → challenge_window` edge is deleted.** A window can no longer open on an
un-notified owner even by mistake — the guarantee moved from "the routine remembers to check" into
the state machine. `challenge_halted` and `released` remain terminal.

## 2 · Owner liveness delivery (Stage 2)

`dispatch_owner_safety_notice(estate)` — admin-gated. In one transaction it resolves the owner's
address from `auth.users.email` (the address the account authenticates with, which a claimant cannot
repoint), commits an `owner_notice_outbox` row, commits the in-app notice, transitions to
`owner_notification_dispatched`, and stamps `owner_notified_at`.

- **Requirement is dispatch INITIATION, not delivery** — no read receipt, no open tracking, no
  acknowledgement. None of those are observable, and each would let a silent mail server hold a
  release hostage forever.
- **An unreachable owner is a hard failure.** `owner_channel_unreachable` refuses the transition;
  the estate stays at `death_verified`, where nothing can release. Proven by test that the failure
  rolls back *both* channels and the state.
- Copy is the existing `death_process.window_opened` catalog entry: asserts no death, names no
  claimant, no estate, no deadline.
- The audit records `'channel', 'email'` — the class, never the address.

## 3 · Outbox safety (Stage 3)

`owner_notice_outbox` is **separate** from `invitation_delivery_outbox`, which is drained daily by a
cron whose claim predicate has no age bound — the right class for an invitation, the wrong one for a
notice that starts a release clock.

- **Age gate** — `owner_notice_age_gate()` = challenge window + 1 day, **derived** so the two cannot
  drift; a drift's failure mode is a notice sent after its own window closed. Unconfigured ⇒
  `claim_owner_notices` refuses entirely rather than treating everything as fresh.
- **Stale protection** — rows past the gate settle as `failedPermanent` /
  `stale_beyond_age_gate`: never sent, **never deleted**. The row is the evidence that the owner was
  not reached in time.
- **Purge audit** — `purge_outbox_rows` writes the `outbox_purge_audit` row **before** the delete, in
  the same transaction. Requires a non-blank reason, refuses an unknown outbox name (closed
  vocabulary — no dynamic `format('delete from %I')`), and refuses to touch `queued`/`processing`
  rows, which are live safety messages still in flight.
- **Classification** — `owner_notice_census()` reports totals, status/age distribution and the
  actionable/stale/purgeable split against the *current* gate. Counts only; never an address.
- **No new cron is wired.** Enabling a delivery path is an operator step (below), and the brief's own
  instruction is to build the safety before enabling the path.

**Existing outboxes, classified from source:** `invitation_delivery_outbox` (7 statuses, daily cron,
`CRON_SECRET`-gated, no age gate but self-cancels non-actionable invitations) and
`storage_deletion_outbox`. 11-F adds rows to **neither**. A live row-level census needs service-role
credentials this phase did not use — the query is in the runbook. **No purge was performed.**

## 4 · Two-person release (Stages 4–5)

`authorize_release(estate, reason)` — admin-gated (AAL2 + freshness). Guards, in order: non-blank
audit reason → state is `challenge_window` → owner notified (both facts on the row) → email channel
present → verified case exists → **reviewer_a derived from `death_verification_cases.decided_by`** →
`reviewer_b ≠ reviewer_a` → duration configured → window **strictly** elapsed.

`reviewer_a` is derived, never a parameter: a parameter would let the caller nominate a "first
reviewer" who reviewed nothing and satisfy the rule against a stranger.

`release_authorizations` is its own model — not a claim packet, membership or designation — with
`estate_id, case_id, reviewer_a, reviewer_b, verified_at, authorized_at, released_at, audit_reason`,
one row per estate, and the two-person CHECK as a **table constraint**: the routine is the door, the
constraint is the wall.

## 5 · Operator runbook — DDL NOT EXECUTED

### Why the order is safe at every step

The first pasted artifact carries the predicate (death satisfies only at `released`) **and** the 7-state
vocabulary, and nothing that can write `released`. Release routines arrive last. There is no
intermediate deployed state in which `death_verified` releases, and none in which a window opens
un-notified.

1. **Build:**
   ```
   node scripts/buildReleaseConditionBundle.mjs && node scripts/buildEstateAssetBundle.mjs && \
   node scripts/buildLifecycleNotificationBundle.mjs && node scripts/buildDeathVerificationBundle.mjs
   ```
   `git status` must be clean afterwards.
2. **Paste, in order**, each as ONE run:
   1. `db/bundles/release_conditions_bundle.sql` — 0051→0052→0053→0054→**0055**→predicate→seam→gates.
      *After:* 7 states storable; `release_estate` **dropped**; window = 7 days; `released`
      unreachable (no writer deployed).
   2. `db/bundles/estate_inventory_and_discovery_bundle.sql`
   3. `db/bundles/lifecycle_notifications_bundle.sql`
   4. `db/bundles/death_verification_bundle.sql` — workflow + `release_safety.sql` + `outbox_safety.sql`.
      *After:* dispatch, window, challenge and two-person release are all live.
3. **Verify:**
   - `node scripts/verifySourceDeploymentDrift.mjs` → `release_authorization_authority` flips from
     `⋯ PENDING_DEPLOYMENT` to `· UNVERIFIABLE · DEPLOYED`; `notification_event_copy · EXACT` with
     no pending line; **no `release_estate (one-person lever)` row** — if that appears as
     `DEPLOYMENT_NEWER`, 0055 did not run and a one-person release path exists.
   - afterworth-mobile: `node scripts/verifyDeployedContracts.mjs` → `challenge_death_process →
     REACHABLE`. (The 11-E `release_estate → LOCKED` line is expected to read *not deployed* now —
     the function is gone by design.)
4. **SQL smoke** (read-only):
   ```sql
   select public.release_condition_satisfied('after_verified_death', null, 'standard', 'released');                       -- t
   select public.release_condition_satisfied('after_verified_death', null, 'standard', 'owner_notification_dispatched');  -- f
   select public.release_condition_satisfied('after_verified_death', null, 'standard', 'challenge_window');               -- f
   select public.release_condition_satisfied('after_verified_death', null, 'standard', 'challenge_halted');               -- f
   select p.challenge_window from public.release_safety_policy p;                                                          -- 7 days
   select to_regprocedure('public.release_estate(uuid)');                                                                  -- NULL
   ```
5. **Challenge-path smoke** (creates no death state): non-owner → `not_authorized`; owner of an
   untouched estate → `nothing_to_challenge`.
6. **Outbox census** (service role, operator):
   ```sql
   select status, count(*), min(requested_at), max(requested_at)
     from public.invitation_delivery_outbox group by status order by 2 desc;
   select public.owner_notice_census();   -- as an admin session
   ```
   **No purge is authorized by this phase.**
7. **Enabling email delivery** is a separate, later operator decision: wire a drain to
   `claim_owner_notices` + the Resend provider and add a cron. Until then a notice is *initiated*
   (row committed) but not transmitted — which is the deployed contract, stated plainly.

### Half-deployment symptoms
- `PARTIAL DEPLOYMENT — the Phase 11-F release surface is half-applied` → re-paste bundle 4 in full.
- `DEPLOYMENT_NEWER · release_estate (one-person lever)` → 0055 did not run; re-paste bundle 1.
- `invalid_window_state` when opening a window → the estate is at `death_verified`; dispatch first.
- `owner_channel_unreachable` → the owner has no `auth.users.email`; this is the intended refusal.

### Rollback
Bundles are additive and idempotent. **Rolling back 11-F while leaving 11-E deployed is
unsupported — deploy both or neither.** 11-E's `release_estate` is dropped by 0055; a partial
rollback would either leave a one-person lever beside a two-person door, or leave `challenge_window`
reachable with no release path at all. Roll back to a pre-11-E tag as one unit, or forward-fix.

## 6 · Deferred ledger

1. **Email transmission** — outbox row is committed; no drain/cron wired (operator decision).
2. **Push notifications** — supplemental per D4; not built.
3. **Challenge_halted recovery / admin override** — still deliberately absent.
4. **Release-authorization status on mobile** — deliberately NOT surfaced: reviewer identities are
   platform-operator data, and showing them to an estate participant would be a new disclosure class
   with no approval behind it. The owner surface stays the closed four-value union.
5. **Survivor mode, executor workspace, incapacity, jurisdiction adapters, policy unification,
   automatic beneficiary elevation, grant rewriting** — all out of scope by instruction.

## 7 · Where the proof lives

- `db/tests/release_safety_authorization.sql` — the full walk (dispatch → window → release), the
  two-person refusal, the blank-reason refusal, the authorization record shape, the exact-boundary
  tiebreak in both orderings, dispatch failure + rollback, the age gate (stale settled, fresh
  claimable), the purge (in-flight refused, audit written, blank reason and unknown outbox refused),
  and the census.
- `db/tests/release_condition_authorization.sql` — 4-axis truth table over **seven** lifecycles;
  every pre-release stage byte-identical, including `owner_notification_dispatched`.
- `test/deathVerificationFoundation.test.ts` — 10 map edges parsed and pinned, window entered only
  from dispatch, two-person constraint, derived reviewer_a, dispatch preconditions, age-gate
  derivation, purge-before-delete ordering.
- `scripts/reconReleasePaths.mjs` — the Stage 1 census, re-runnable.
- `scripts/mutateSqlAuthorization.mjs` — **110 mutations** (15 new `p11f-*`).
