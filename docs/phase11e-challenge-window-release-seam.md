# Phase 11-E — Challenge Window + Release Authorization Seam

**Date:** 2026-08-12 · **Repos:** afterworth-api (backend + safety routines), afterworth-mobile (owner challenge surface)
**Deployment: NOT PERFORMED.** 11-B/C/D/E are all source-merged and deployment-pending.

11-D let an accepted death verification satisfy `after_verified_death` at `death_verified` — which
connected verification directly to irreversible disclosure. 11-E inserts the safety seam:

```
active → death_verification_pending → death_verified
       → challenge_window     (owner notified in-transaction; release deliberately waiting)
       → released             (the ONLY lifecycle that satisfies a death-conditioned grant)

any pre-released death-process state → challenge_halted   (the owner objected; terminal in 11-E)
```

## 1 · The predicate change (R7)

`after_verified_death` is now satisfied **only** under `standard` at **`released`**. False at
`active`, `death_verification_pending`, `death_verified`, throughout `challenge_window`, and at
`challenge_halted`. `legacy_immediate_only` unchanged (R10). Incapacity, the fused legacy value,
claim, identity and `never` remain satisfiable by nothing. Unknown condition, policy **and**
lifecycle all fail closed — the validity gate now names six states, anchored at run time against the
deployed CHECK so the two vocabularies cannot drift.

## 2 · The three transitions

| Routine | Move | Authority | Notes |
|---|---|---|---|
| `begin_challenge_window` | `death_verified → challenge_window` | admin (AAL2 + freshness) | Owner notice REQUIRED to commit; verified case required; idempotent |
| `challenge_death_process` | any pre-released death state → `challenge_halted` | **the authenticated owner, alone** | No evidence, review, waiting or designation (R13); idempotent; terminal |
| `release_estate` | `challenge_window → released` | **INTERNAL — no client role, no caller** | Strictly elapsed window, committed notice, verified case, configured duration |

The transition map grew from three edges to eight. Two absences are load-bearing and pinned by
test: **nothing leaves `challenge_halted`** (no resume, no admin override) and **nothing leaves
`released`** (R15 — disclosure cannot be undone). `released` is entered from `challenge_window`
alone.

## 3 · The tiebreak (R14) — challenge wins, provably

Release requires the window **strictly** elapsed (`now() > owner_notified_at + duration`); the
challenge does not consult the clock at all. At the exact boundary instant release refuses and the
challenge succeeds. Both serialize on the lifecycle row lock (`for update`).

Tested at the **exact instant**, not ±1 second: `now()` is the transaction timestamp and constant
within a transaction, so `owner_notified_at := now() - duration` constructs `now() = notified +
duration` precisely. Both orderings are exercised (release-first and challenge-first), each ending
`challenge_halted`, plus a control one second past the boundary where release **does** succeed — so
the refusals are the tie, not a release path that never works. A one-character `>` → `>=` mutation
is killed by this fixture and by nothing else.

## 4 · The window duration is configuration, never a default (a STOP condition, handled)

`release_safety_policy` ships **empty**. No migration seeds a duration, because the challenge-window
length is a product decision this phase does not own. The fail-closed direction is deliberate: an
estate can always **enter** the window (the owner gets their notice and their clock starts), but with
no configured duration the window **never elapses** and release refuses with
`release_window_not_configured`. The duration is read **live** at release time (the H2 precedent), so
a policy lengthened mid-window lengthens that window; nothing is stamped at entry.

This is why 11-E did not stop on "challenge-window duration is not approved": the phase is complete
and safe without it, and release is unreachable until an operator sets it deliberately.

## 5 · The release actor is deferred (a STOP condition, handled the same way)

`release_estate` exists so its guards are real and testable, and has **EXECUTE revoked from every
client role with no caller anywhere**. Who may pull the lever — a single admin, a two-person rule
(11-A threat model T5), an elapse job — is an 11-F product decision. In 11-E, `released` is
unreachable in any deployed environment. The deployed-contract verifier reports this function's
privilege posture in both directions, so a future silent `GRANT` is loud.

## 6 · Owner notification is the safety precondition (§9)

`emit_lifecycle_notification` deliberately swallows insert failure everywhere else — the right trade
for a heads-up beside a grant. **That trade is inverted here.** `begin_challenge_window` requires the
emit to return a committed row id and raises `owner_notification_failed` otherwise, rolling back the
transition: the window cannot begin un-notified.

**Reliability class, stated honestly:** one in-app notification row, committed in the same
transaction as the transition. It does **not** travel the invitation email outbox — an at-least-once
queue drained by a daily cron with no age gate, which would mean a window opening today on a notice
readable tomorrow. That separation is structurally pinned, not conventional.

Copy (`death_process.window_opened`): *"A release process is waiting / A release process is waiting
on your estate. You can review and halt it now."* It asserts no death, names no claimant, no
evidence, no estate and no deadline.

## 7 · Outbox / backlog classification (§10) — read-only

- **What the outbox carries:** invitation delivery emails only (`invitation_delivery_outbox`,
  statuses `queued`/`processing`/`retryPending`/`providerAccepted`/`outcomeUncertain`/
  `failedPermanent`/`cancelled`). Drained daily by `/api/invitations/drain_email_outbox` under
  `CRON_SECRET` (fails closed when unset).
- **11-E adds ZERO rows to it.** The safety notice is in-app and same-transaction.
- **Age gate:** the claim predicate has none — any `queued` row is claimable whenever the drain next
  runs. It does cancel rows whose invitation is no longer actionable, which bounds *invitation*
  staleness but is not an age gate. Because 11-E routes nothing here, no gate is required by this
  phase; a gate becomes mandatory the moment any safety-critical notice is queued, and the
  structural test above is what makes that a deliberate change rather than a drift.
- **A live row-level census requires service-role credentials, which this phase did not use.** The
  exact read-only census query is in the runbook below for the operator to run. No purge was
  performed or scheduled.

## 8 · The verifier blind spot (§26) — fixed, not annotated

`42501` is `insufficient_privilege` **and** the errcode every gate in this product raises
(`auth_required`, `not_authorized`). The deployed-contract verifier read `42501` as "EXECUTE is
revoked" — so a **granted, merely-refusing** routine would have been reported `LOCKED`. That is a
false positive on a security claim, and §26 forbids printing it.

Fixed in two required parts:

1. **LOCKED now requires the privilege MESSAGE** (`permission denied for function …`), not the code
   alone. A body-raised refusal carries its own sentinel and is classified `refused` — present,
   executable, and failing the posture exactly like `open`.
2. **A negative control that would have caught the old bug**: `challenge_death_process` is granted
   and answers `42501 not_authorized` for a non-owner. If it ever looks `LOCKED`, the instrument
   refuses to vote at all.

Both are pinned by `scripts/__tests__/deployedContractVerifier.test.ts` (38 tests), which now also
requires that *every* lock verdict in the file pairs code with message.

## 9 · Mobile — the owner challenge surface

`/challenge` (guarded, **no route params**) → `OwnerChallengeScreen`. Reachable from the safety
notification via the allowlisted `afterworth://challenge`, in **two meaningful actions**: tap the
notification, press "Halt this process".

- The deep link is a lookup key: exact-match only, no parsing, no estate id, case id or token. The
  screen re-derives everything from session + capability snapshot; the server refuses non-owners
  identically.
- The client holds **no release authority**: no `release_estate` binding, no elapse/countdown
  arithmetic, no lifecycle vocabulary at all (the server collapses six states into four
  presentation words). An unknown status fails closed to `none`, never `challengeable`.
- Accessibility: one ranked landmark, safe-area rooted on all edges, back affordance, explicit
  action label + hint; no countdown, no urgency animation, no celebratory or accusatory iconography,
  and the halt action is never rendered disabled.

## 10 · Operator runbook (§25) — DDL NOT EXECUTED

### Why the order is safe at every step

The first pasted artifact carries the **predicate that satisfies death only at `released`** plus the
lifecycle vocabulary — and nothing that can write `released`. The transition routines arrive last.
So there is **no intermediate deployed state in which `death_verified` releases information**: before
step 4 nothing can move an estate past `death_verified`, and after step 4 `release_estate` is
client-unreachable and refuses on an unconfigured window.

1. **Build** (all four; each prints its positive-control count; `git status` must be clean after):
   ```
   node scripts/buildReleaseConditionBundle.mjs && node scripts/buildEstateAssetBundle.mjs && \
   node scripts/buildLifecycleNotificationBundle.mjs && node scripts/buildDeathVerificationBundle.mjs
   ```
2. **Paste, in order**, each as ONE run in the Supabase SQL editor:
   1. `db/bundles/release_conditions_bundle.sql` — 0051→0052→0053→**0054**→predicate→seam→gates.
      *After this step:* death satisfies only at `released`; `released` is storable but unreachable
      (no writer deployed); `release_safety_policy` exists and is EMPTY.
   2. `db/bundles/estate_inventory_and_discovery_bundle.sql` — inventory/asset consumers.
   3. `db/bundles/lifecycle_notifications_bundle.sql` — adds the `death_process.window_opened` copy.
      *Emission stays lifecycle-blind:* `notification_grant_is_live` pins `'active'`.
   4. `db/bundles/death_verification_bundle.sql` — workflow + **`release_safety.sql`** LAST.
      *After this step:* the owner challenge becomes AVAILABLE; release remains unreachable
      (client-revoked, no caller, unconfigured window).
3. **Verify deployment**:
   - `node scripts/verifySourceDeploymentDrift.mjs` → expect `release_condition_authority · EXACT ·
     DEPLOYED at the 11-D shape` (the 4 spot checks now include `death → released = true`,
     `death → death_verified = false`), `notification_event_copy · EXACT` with **no** pending line,
     `death_verification_authority · DEPLOYED`, exit 0.
     - **Half-deploy symptoms:** `PARTIAL DEPLOYMENT` naming absent objects → re-paste that bundle in
       full; `DEPLOYED release authority is LIFECYCLE-BLIND` → 0053 did not run, re-paste bundle 1.
   - In afterworth-mobile: `node scripts/verifyDeployedContracts.mjs` → expect
     `PHASE 11-E POSTURE`: `release_estate → LOCKED ("permission denied" confirmed)` and
     `challenge_death_process → REACHABLE`. A `refused` or `open` verdict on the lever fails the run.
4. **Post-deploy SQL smoke** (read-only, SQL editor):
   ```sql
   select public.release_condition_satisfied('after_verified_death', null, 'standard', 'released');        -- t
   select public.release_condition_satisfied('after_verified_death', null, 'standard', 'death_verified');  -- f
   select public.release_condition_satisfied('after_verified_death', null, 'standard', 'challenge_window');-- f
   select public.release_condition_satisfied('after_verified_death', null, 'standard', 'challenge_halted');-- f
   select public.release_condition_satisfied('after_verified_death', null, 'legacy_immediate_only', 'released'); -- f
   select count(*) from public.release_safety_policy;                                                      -- 0
   ```
5. **Challenge-path smoke** (no death fixture required): as any authenticated non-owner, call
   `challenge_death_process` against an estate you do not own → `not_authorized`. As an owner of an
   estate with no death process → `nothing_to_challenge`. Both prove the door is live and gated
   without creating any death state.
6. **Release remains unreachable** until (a) an operator inserts a duration into
   `release_safety_policy` AND (b) 11-F wires an actor. Neither is part of this deployment.
7. **Outbox census** (read-only, service role, operator):
   ```sql
   select status, count(*), min(requested_at), max(requested_at)
     from public.invitation_delivery_outbox group by status order by 2 desc;
   ```
   Classify before any drain change. **No purge is authorized by this phase.**
8. **Rollback containment:** the bundles are additive and idempotent. Once pasted, reverting 11-E
   behaviour requires pasting rebuilt bundles from the prior tag as one unit. Do not hand-edit
   deployed routines. Note that rolling back 11-E while leaving 11-D deployed would restore
   disclosure at `death_verified` — roll back both or neither.
9. **Information-equivalence smoke:** with no estate at `challenge_window` or `released` in
   production, activation cannot be exercised there; it is proven in the SQL suite against fresh
   Postgres. Do **not** manufacture a real death/release fixture in production.

## 11 · Deferred ledger

1. **Challenge-window duration** — product decision; `release_safety_policy` empty until taken.
2. **Release actor** — 11-F; `release_estate` unreachable until then.
3. **Challenge_halted recovery / admin override** — deliberately absent; a new product decision.
4. **Survivor UI, executor powers, incapacity flow, policy unification, fused-row mapping** — all
   still deferred (R16–R19, R11).
5. **Outbox age gate** — not required while no safety notice is queued; mandatory if that changes.
6. **Email/push channel for the safety notice** — in-app only today; a second channel is a
   provider decision (§30) and would change the reliability class.
7. **11-C/D carry-overs** unchanged: vault-delete sentinel, case read surface, harness
   `documents_read` fidelity, `estates.status` vestige.

## 12 · Where the proof lives

- `db/tests/release_safety_authorization.sql` — the full walk (A–F) through real doors, the
  challenge matrix (6 byte-identical refusals + the no-designation owner), terminality, the exact
  tiebreak in both orderings, release guards, and the claim/evidence/attainment firewall.
- `db/tests/release_condition_authorization.sql` — 4-axis truth table over six lifecycles; the
  single satisfying region; §9 activation matrix re-anchored to `released` with every earlier stage
  byte-identical.
- `db/tests/death_verification_authorization.sql` — `death_verified` now moves **no** payload,
  including the death-grant holder's.
- `test/deathVerificationFoundation.test.ts` — map edges parsed and pinned, terminality, six-state
  CHECK, empty policy table, safety-module forbidden set, R13 signature, strict boundary, notice
  precondition, copy discipline, outbox separation.
- `scripts/mutateSqlAuthorization.mjs` — **95 mutations, all killed** (22 new `p11e-*`).
- Mobile: `features/safety/__tests__/ownerChallenge.test.tsx` (45 tests),
  `scripts/__tests__/deployedContractVerifier.test.ts` (38).
