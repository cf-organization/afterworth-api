# Phase 11-OC — Release requires established provider acceptance

**Status:** implementation specification. Authorized policy, staged rollout, evidence.

```
POLICY AUTHORITY:      Phase 11-OB2 Stage 3.5 decisions D1-D14 (authoritative)
SUPERSEDES:            the OB-2 "Policy B" recommendation (see §11)
PRODUCTION POLICY:     NOT YET ACTIVE — active only once Phase D is pasted
BRANCH B:              NOT STARTED — gate closed

PHASE A:  DEPLOYED_AND_VERIFIED
PHASE C:  DEPLOYED_AND_VERIFIED   docs/phase11oc-phase-c-owner-notice-reissue.md
PHASE D:  IMPLEMENTED · DEPLOYMENT_REQUIRED
          docs/phase11oc-phase-d-release-authority.md   ← the cutover, R13, and its evidence
R13:      RESOLVED by Phase D (§7 of the Phase D document). The census in §7.3 below listed SEVEN
          pinning sites; re-measuring at implementation time found NINE in-repo guards plus three
          test-source pins, because 0058 and 0059 each added their own inversion guard AFTER that
          census was written, and Phase A added a fifth mutation anchor. The corrected table is in
          the Phase D document; §7.3 below is left in place as the record of what was believed.
```

This document is the corrected successor to the Stage-3 design. Stage 3 was written before the
Stage 3.5 policy decisions existed and before any replay evidence had been gathered; §11 records
what changed and why, rather than deleting it.

---

## 1 · THE DEFECT

`authorize_release` gates the irreversible `challenge_window → released` transition on:

```sql
exists (… where estate_id = p_estate and channel = 'email' and status <> 'cancelled')
```

`'cancelled'` **has no production writer.** One statement in the whole repository sets it —
`db/tests/release_safety_authorization.sql:998`, a direct `UPDATE` in a test fixture. No migration,
no routine, no worker, no console path produces it.

So in production the predicate reduces to *"a row exists for this estate on the email channel"* —
which is exactly what `dispatch_owner_safety_notice` guaranteed by inserting that row in the same
transaction as the lifecycle transition. **The gate re-asserts its own precondition.** It admits
`queued` (never sent), `processing` (never settled), `outcomeUncertain` (unknown), and
`failedPermanent` (definitively failed).

The predicate does not need narrowing. It needs **replacing**, because there is no status list that
repairs a predicate whose real content is row existence.

### 1.1 The status-list shape is itself the defect class

Any replacement written `status in (…)` inherits the failure that produced this phase: the CHECK
constraint has already grown once (0056 added `outcomeUncertain`), and each growth silently
re-decides release authority for a door that reads statuses by exclusion. The release door must stop
reading `status` at all.

### 1.2 `dispatched_at` cannot be promoted to release authority

`record_owner_notice_outcome` has written `dispatched_at` since 11-K. From 11-K until 0057 the entire
settle path raised `check_violation` on every call (OB-4), so no row could reach `dispatched` by the
normal path; rows carrying `dispatched_at` today did so under a contract that was demonstrably
broken. **Authority is decided by SOURCE.** A new fact needs a new column whose only writer is the
branch that establishes it.

### 1.3 An estate can legitimately hold notices from more than one death process

`challenge_death_process` and the case-decision paths return the lifecycle to `active` on `rejected`
and `cancelled`. A later, unrelated case can run the full path again and dispatch a second notice.
Generation must therefore be scoped to a **death-verification case**, not to an estate — otherwise an
accepted notice from a prior, rejected process authorizes release under a new process whose own
notice never went out.

---

## 2 · AUTHORIZED POLICY (D1-D14)

| # | Decision |
|---|---|
| **D1** | A release may qualify only when the CURRENT case episode has at least one owner-notice generation whose provider acceptance is **established**. `outcomeUncertain` does not authorize release. |
| **D2** | `notice_accepted_at timestamptz NULL`, written **only** by `record_owner_notice_outcome(… providerAccepted …)`. Never for queued/processing/outcomeUncertain/failedPermanent/cancelled. Never synthesized, never backfilled, never coalesced to `owner_notified_at`. |
| **D3** | Episode identity is `death_verification_cases.id`. Estate id is insufficient. |
| **D4** | A deliberate re-notice creates a **NEW** row. Never mutate a terminal generation back into queue state. |
| **D5** | Re-notice permitted only when the current generation is `failedPermanent` or `outcomeUncertain` — see §3 for the legacy reading. Not from queued/processing/cancelled. |
| **D6** | Platform admin/operator only, `admin_require_gate()` (admin + AAL2 + freshness), non-blank reason, HIGH-severity audit. No break-glass, no two-person rule. |
| **D7** | A re-notice must never make an estate release-eligible earlier. **Prove it; do not rely on comments.** |
| **D8** | Release clock = `notice_accepted_at + challenge_window_duration()` for the qualifying current episode. Strict `now() > release_eligible_at`. `owner_notified_at` becomes provenance only. |
| **D9** | Legacy rows keep `notice_accepted_at IS NULL`. No backfill, no guess, no `coalesce`. A current challenge-window case with no qualifying accepted notice fails with a distinct `notice_never_accepted`. Remediation is operator re-notice. |
| **D10** | `begin_challenge_window` is **not** tightened to acceptance. Replace the inert `status <> 'cancelled'` with an honest committed-row predicate, preserving current opening semantics. |
| **D11** | No release on `outcomeUncertain`. It is UNKNOWN — not accepted, not failed. |
| **D12** | Explicit `case_id` / `generation` / `superseded_by` with a partial-uniqueness invariant. Never `MAX(row)`, never "latest by timestamp". |
| **D13** | Do not modify applied migration 0057 as the default. Prove the actual failure by fresh replay first. |
| **D14** | `afterworth-admin` mirrors release availability, notice state and eligibility time. The primary admin checkout holds foreign state and must not be touched; use an isolated worktree from `origin/main`. |

---

## 3 · THE ONE POLICY TENSION, RESOLVED EXPLICITLY

D5 lists the permitted prior statuses as `failedPermanent` and `outcomeUncertain`, and excludes
`dispatched` with the stated reason: *"For dispatched: provider acceptance is already established."*

D9 requires that the legacy population — rows that are `dispatched` with **no** acceptance fact —
be remediated by **operator re-notice**.

These are only in tension if `dispatched` is read as a bare status. It is not: D5's own reason scopes
its own exclusion. The exclusion exists **because acceptance is established**, and for a legacy row
acceptance is precisely what is *absent*.

**Resolution — the permitted set is a status/fact pair, not a status:**

| Prior current generation | Verdict | Reason |
|---|---|---|
| `failedPermanent` | permit | D5 |
| `outcomeUncertain` | permit | D5 |
| `dispatched` **and** `notice_accepted_at IS NULL` | **permit** | D9 legacy remediation. D5's exclusion reason does not hold: nothing is established. |
| `dispatched` **and** `notice_accepted_at IS NOT NULL` | refuse `notice_already_accepted` | D5 exactly as written |
| `queued` / `processing` | refuse `notice_still_in_flight` | D5; OB-1 reclaim/retry is the remedy |
| `cancelled` | refuse `notice_cancelled` | D5; unreachable in production (§1) |

The legacy shape is **structurally unreachable after Phase A**, because `status='dispatched'` and
`notice_accepted_at` are written by a single `UPDATE` statement (§5.2). That unreachability is an
asserted invariant, not a hope — so this branch cannot mis-fire on a post-Phase-A row.

---

## 4 · ARCHITECTURE

Three ideas, in dependency order.

1. **Acceptance is a stamped fact, not a status.** `notice_accepted_at` is written by exactly one
   branch of exactly one routine. Release reads that column. No status-vocabulary change can ever
   again alter what release means (D1, D11).

2. **A notice is an EPISODE of generations, keyed by the case.** Re-notice appends a generation; it
   never mutates a settled row. The active generation is the one nothing supersedes, enforced by a
   partial unique index rather than by `max()` (D3, D4, D12).

3. **The release clock anchors on the FIRST acceptance in the episode, and is derived, never
   stored** — `MIN(notice_accepted_at)`, read live, through one internal function consumed by both
   the door and the console (D8).

Two properties fall out, and are the reason to prefer this shape:

- **Monotonicity.** Creating a generation can only ever *add* authority. No operator action can
  suppress or delay a release. This is **how D7 is proven structurally** rather than asserted.
- **Vocabulary-independence.** A seventh status added in 2027 cannot become release-qualifying,
  because the door never enumerates statuses.

### 4.1 The anchor is MIN — and D7 requires it

Stage 3 left MIN-vs-MAX as a reasoned preference. Under D7 it is **determined**, and the ambiguity is
removed here:

- **MAX** would let a reissue *restart* the seven days. A reissue is an operator action, so MAX makes
  the release clock console-controllable — a direct D7 violation. It sounds conservative and is the
  same class of error with the sign flipped.
- **Latest-generation-only** would make a reissue *remove* authority: an accepted G1 would stop
  qualifying the moment G2 was created. That hands an operator a lever that suppresses a release.
- **MIN over acceptances** is monotone in both directions: the owner's protection began the first time
  a message about this process was accepted for them, and no later generation, later acceptance, or
  operator action can move it.

```
episode(case)   := { n : n.case_id = case ∧ n.channel = 'email'
                                          ∧ n.notice_kind = 'death_process.window_opened' }
accepted(case)  := { n ∈ episode(case) : n.notice_accepted_at IS NOT NULL }

ReleaseNoticeAuthority(case) := accepted(case) ≠ ∅
AcceptanceAnchor(case)       := MIN{ n.notice_accepted_at : n ∈ accepted(case) }
```

### 4.2 Why the door reads a timestamp rather than `status = 'dispatched'`

D1 names the current representation as `status = 'dispatched'`. The door instead reads
`notice_accepted_at IS NOT NULL`. These agree by construction — the timestamp is written in the same
`UPDATE` that sets `status='dispatched'`, on the `providerAccepted` branch only — and the timestamp is
the stronger form, because it satisfies Stage 7's requirement that *"the released decision must not
become true merely because a new status is added later."* The pair is asserted, by execution, so the
two can never drift (§8, T-A4).

---

## 5 · DATA MODEL

### 5.1 `owner_notice_outbox` additions (all additive, all nullable-safe)

| Column | Type | Null | Notes |
|---|---|---|---|
| `notice_accepted_at` | timestamptz | yes, permanently | The one release-authoritative fact. Never backfilled (D2, D9). |
| `generation` | int | no, default 1 | Which attempt within the episode. |
| `case_id` | uuid FK `death_verification_cases(id)` | yes in the column, `NOT VALID` CHECK enforces presence on new writes | The episode key (D3). |
| `superseded_by` | uuid FK self, `ON DELETE SET NULL` | yes | Explicit retirement link (D12). |
| `reissue_reason` | text CHECK(4) | yes | Why generation ≥ 2 exists. Derived, never a caller parameter. |
| `reissued_by` | uuid FK `auth.users(id)` | yes | Derived from `auth.uid()` inside the definer. |

**`notice_kind` stays at one value** (`death_process.window_opened`). A reissue says the identical
thing to the identical person about the identical window. The owner must not be told which attempt
this is — internal state is not user copy. The real distinctions live in `generation` (which attempt)
and `reissue_reason` (why), both operator-facing only.

**`status` stays at six values.** A seventh value `'superseded'` is rejected twice over: supersession
is a relationship *between rows*, not a delivery outcome of one; and overwriting a `failedPermanent`
row would destroy the `failure_class` that is the evidence a reissue was warranted. Retired
generations keep their terminal status and gain a pointer.

### 5.2 Acceptance is written in ONE statement

```sql
update public.owner_notice_outbox
   set status = v_status,
       dispatched_at      = case when v_status = 'dispatched' then now() else dispatched_at end,
       notice_accepted_at = case when p_outcome = 'providerAccepted' then now()
                                 else notice_accepted_at end
 where id = p_id;
```

Keyed on `p_outcome = 'providerAccepted'`, **not** on `v_status = 'dispatched'`, so the stamp is tied
to the outcome the provider reported rather than to a status another branch could later reach. One
statement, so `dispatched` + NULL acceptance is structurally unreachable for new rows.

First-write-wins needs no `where … is null` clause: the settled-status no-op already makes a second
settle unreachable, and a redundant guard would mask a future change to that no-op.

### 5.3 `case_id` backfill is FORBIDDEN — and it is technically possible, which is the point

The dispatch audit row carries `case_id` in its metadata JSON, so a backfill *could* be written.
Populating an FK that governs release authority by joining an audit JSON blob is exactly the
"softened load-bearing identifier" pattern. NULL routes to the explicit legacy branch.

`generation` is the **only** backfill in this design, and it is vacuous: no re-notice mechanism has
ever existed, so every extant row is definitionally the first generation of its episode. Note what
must **not** be asserted — multiple rows per *estate* are legitimate (§1.3), so the migration must not
assert one-row-per-estate.

### 5.4 The legacy NULL branch — no `coalesce`, ever

`coalesce(notice_accepted_at, dispatched_at, owner_notified_at)` is forbidden for the reason this
repository has already learned twice: a fallback chain makes the *content* of a weaker column into
authority, and authority is decided by SOURCE. `dispatched_at` was written by a settle path that was
totally broken from 11-K until 0057; `owner_notified_at` is an enqueue stamp Branch A measured 2.2
seconds ahead of an email that had not been sent.

The refusal code is **`notice_never_accepted`**, distinct from `owner_channel_unreachable`. A shared
code would make a legacy estate indistinguishable from a genuinely unreachable owner, and the
operator's next action differs completely between them.

**Remediation is ordinary re-notice** — not an exemption, not an attestation column, not a flag. The
legacy branch resolves itself by *producing the missing fact*, never by excusing its absence.

---

## 6 · STAGED ROLLOUT

The stricter release policy is **not** activated in one step.

| Phase | Artifact | Contains | Behaviour change to release |
|---|---|---|---|
| **A** | migration `0058` | additive schema; acceptance stamp; `dispatch` writes `case_id`+`generation`; census keys; projection additions | **NONE** |
| **B** | *(no artifact)* | read-only production census; measure legacy blast radius | none |
| **C** | migration `0059` | `reissue_owner_safety_notice`; admin console compatibility | none |
| **D** | migration `0060` | release-door cutover; `release_eligible_at()`; clock re-anchor; honest `begin_challenge_window` predicate | **THE cutover** |

**Why the acceptance stamp ships in Phase A, not Phase D.** Stamping acceptance is additive and
observational — nothing reads the column until Phase D. Landing it first means every notice accepted
between Phase A and Phase D accumulates a *real* acceptance fact, so the legacy population measured in
Phase B shrinks by ordinary operation rather than by remediation. Deferring the stamp to Phase D would
guarantee a larger blocked population on cutover day.

**Why `case_id` must also ship in Phase A.** Without it, new dispatches keep landing with no episode,
so the Phase B census would measure a population that cannot stop growing.

### 6.1 Gate before the cutover

If any current challenge-window estate lacks a provable accepted fact, **Phase D must not activate**
until the re-notice remedy (Phase C) is deployed and operational for that class. This is why B
precedes C precedes D, and why the count is produced by A.

### 6.2 Rollback asymmetry, stated

Rolling Phase D back restores a predicate that admits `queued` and `failedPermanent`. It is possible
and it is a safety regression, so it is a decision, not a reflex. Phase A is additive and nullable
throughout; leaving it in place is harmless and dropping it is neither required nor recommended.

---

## 7 · R13 — RESOLVED BY EVIDENCE, AND THE DESIGN'S HYPOTHESIS WAS WRONG

D13 required a fresh complete replay to prove the actual failure before choosing a treatment. It was
run. **The hypothesis was incomplete in two ways that matter.**

### 7.1 What the replay measured

Baseline, `afterworth-api` @ `5421eaf`, canonical suite (`scripts/verifySqlAuthorization.mjs`,
ephemeral Docker Postgres):

```
✓ SQL AUTHORIZATION VERIFIED — 424 assertions, real is_estate_owner, RLS enforced
exit 0
```

**Positive control:** the replay log carries `0057 OK: … OB-2 untouched …`. The self-check is
genuinely *reached and live* in replay — not skipped, not vacuous. Without this control, a later green
run could not distinguish "the guard passed" from "the guard never ran".

### 7.2 The proven failure

A single-variable experiment in a **throwaway git worktree** (primary checkout never written;
byte-identical restore verified by comparing `git diff --stat` and `git status --porcelain` before and
after): `authorize_release`'s `o.status <> 'cancelled'` was replaced by `o.status is not null` —
semantically identical in production, literal removed. Every registered bundle was rebuilt inside the
worktree so the edit genuinely reached the database.

```
✗ FAILED while applying db/bundles/operator_console_bundle.sql
ERROR: 0056 FAILED: authorize_release no longer gates on status <> cancelled
exit 1
```

**The failure is in 0056, not 0057** — and 0056 fires *earlier* in the replay, at
`operator_console_bundle` (part 5), before `owner_notice_claim_visibility_bundle` (part 6) is ever
reached. The Stage-3 design named 0057 alone.

### 7.3 The full census of pinning sites

| # | Site | Pins | Broken by |
|---|---|---|---|
| 1 | `0056:167` | `begin_challenge_window` prosrc | Phase D (D10 replaces that wording) |
| 2 | `0056:175` | `authorize_release` prosrc | Phase D |
| 3 | `0057:143` | `authorize_release` prosrc | Phase D |
| 4 | `mutateSqlAuthorization.mjs` `p11e-release-without-owner-notice` | anchor text spans the predicate | Phase D |
| 5 | `mutateSqlAuthorization.mjs` `p11f-release-skips-dispatch-check` | anchor text spans the predicate | Phase D |
| 6 | `mutateSqlAuthorization.mjs` `p11e-release-before-window-elapses` | anchor spans the clock expression | Phase D |
| 7 | `mutateSqlAuthorization.mjs` `p11e-challenge-loses-the-tie` | anchor spans the clock expression | Phase D |

D10 does not spare 0056:167: it explicitly replaces the inert wording in `begin_challenge_window`
while preserving opening semantics, so that guard breaks too.

### 7.4 The rejected alternatives

**Rejected — plant the literal in a comment.** `prosrc` includes comments inside the function body, so
a comment containing `status <> 'cancelled'` would satisfy all three checks. This is the worst
available option and it is recorded because it is the tempting one: it converts three live guards into
decorations that match a comment, which is precisely the vacuous-audit failure this repository has
shipped five times. Refused.

**Rejected — neutralize the checks in the replay harness.** The self-checks live *inside the migration
text embedded in the bundles*. Neutralizing them would require the harness to rewrite bundle bytes at
load time, so the suite would no longer test the artifact an operator pastes. That trades a
replay failure for a loss of paste-fidelity. Refused.

**Rejected — reorder the suite parts** so the Phase D body loads after the guards. This inverts real
operator deployment order and would make the replay unrepresentative of production. Refused.

### 7.5 The chosen treatment — supersession-aware amendment, of BOTH guards

D13's five conditions, each met:

1. **Otherwise impossible** — proven by §7.2 and the three refusals in §7.4.
2. **Repo architecture genuinely requires it** — `db/migrations/README.md` states these files are how
   the schema is *rebuilt on reset* and that "a slice's file may grow as the slice is built", and
   requires every statement to be idempotent and re-runnable. They are replayed build steps, not
   immutable historical records.
3. **Limited to a self-check** — zero DDL, zero deployed semantics, in both files.
4. **Documented** — here, plus a loud supersession banner in each amended file naming migration 0060.
5. **A replay regression test proves the result** — the full clean replay is re-run after
   implementation, and the amendment's own logic is mutation-proven.

**The amendment keeps each check load-bearing rather than deleting it.** Each becomes a
supersession-aware disjunction:

> `authorize_release` must gate on **either** the OB-1-era `status <> 'cancelled'` predicate **or** the
> OB-2 acceptance authority — detected structurally by the existence of the named OB-2 routine, not by
> a text match on a comment. **Never neither.**

This is strictly stronger than the original: the original could be satisfied only by the old text, and
the amendment can never be satisfied by *absence of both*. If a future edit deletes the guard with
nothing replacing it, it still raises. The Phase D migration additionally asserts the new predicate is
present **and** the old text is gone, so the two directions are both pinned.

---

## 7A · WHAT IMPLEMENTATION FOUND THAT THE DESIGN DID NOT

Three defects in the specification itself, each caught by execution rather than review. They are
recorded because each was a *plausible* design that a reader would have approved.

### 7A.1 `CHECK (case_id IS NOT NULL) NOT VALID` would have broken the drain

The design specified `NOT VALID` and described it as "exactly the required semantics: existing rows
are never scanned and keep their NULL, and every new INSERT and UPDATE is checked." The mechanism is
correct and the **consequence** is inverted: "every UPDATE is checked" is the problem.

Measured against Postgres:

| Direction | `NOT VALID` CHECK | Required |
|---|---|---|
| legacy NULL row persists | ✓ | ✓ |
| new NULL-`case_id` INSERT refused | ✓ | ✓ |
| **UPDATE of a legacy NULL row** | **REFUSED** | **must succeed** |

The owner-notice drain UPDATEs legacy rows as a matter of routine — the stale sweep moves
`queued`/`processing` to `failedPermanent`, and `record_owner_notice_outcome` settles them. Every one
of those UPDATEs would have raised `check_violation`, so a migration whose entire claim is "changes no
behaviour" would have broken the only independent channel that warns a living owner.

**Resolution.** A `BEFORE INSERT` trigger. The requirement is "no NEW row without an episode", which
is a statement about INSERT; enforcing it on UPDATE was never asked for. Proven in four directions,
including a positive control that a populated INSERT still succeeds — without which a trigger that
refused *everything* would have satisfied the refusal test and read as correct.

### 7A.2 An immediate `superseded_by` FK makes a supersession pair UNWRITABLE

The design specified the FK as `ON DELETE SET NULL` with no deferral. Measured, that makes the entire
re-notice mechanism impossible — **both** orderings are refused:

- **INSERT the successor first** → `unique_violation`. The predecessor is still current, so two rows
  momentarily satisfy `superseded_by IS NULL` for one case and the partial unique index correctly
  refuses.
- **UPDATE the predecessor first** → `foreign_key_violation`. It must point at a row that does not
  exist yet.

A partial unique *index* cannot be deferred, and PostgreSQL has no partial unique *constraint*, so the
FK is the half that must yield.

**Resolution.** `DEFERRABLE INITIALLY DEFERRED`, and the re-notice routine pre-generates the
successor's uuid, retires the predecessor, then inserts under that id. **Integrity is unchanged, and
that was proven by a positive control rather than assumed:** a genuinely dangling `superseded_by` is
still rejected, at constraint-check time instead of statement time. Without that control, "deferrable"
could have silently meant "unenforced", and the supersession model would have rested on a pointer
nothing validates.

### 7A.3 The readiness census read acceptance from the CURRENT generation only

The first implementation classified an estate by its current generation's status. Its own
direction-1 positive control caught it: estate Y, holding a genuinely accepted generation 1 plus three
later generations, was reported as **not admissible**.

That is the "latest generation only" model §4.1 rejects explicitly — an already-accepted generation
would stop qualifying the moment a later one was created, so issuing a protective notice would
*remove* release authority and hand an operator a suppression lever. Acceptance must be an
**existential over the whole episode**.

**This is the value of the two-directional control, stated concretely.** A census asserted only to
report REFUSED would have passed with this defect in place, and would have read as safely
conservative while being wrong in the direction that blocks every legitimate release.

### 7A.4 Two standing audits fired, and the design changed rather than the audit

- **`deathVerificationFoundation.test.ts`** — the readiness census touches `estate_lifecycle`. The
  one-line fix was to widen the sanctioned list. The census joins `LIFECYCLE_TABLE_READERS` (the list
  `operator_console.sql` already occupies, for an operator projection that reports where the machine
  stands) rather than `LIFECYCLE_MODULES`, because those are different privileges: the latter would
  also have granted permission to WRITE the lifecycle. Routing through `estate_lifecycle_state()`
  instead was considered and rejected — it requires a local comparison, which the *same* audit forbids
  as "release policy leaking back out of the canonical module one `if` at a time". The stricter-looking
  route violates the stricter rule.
- **`operatorArtifactSafety.test.ts`** — a new operator artifact appeared. The count is asserted rather
  than derived specifically so that "a new operator artifact cannot appear without a human deciding it
  should". It fired as designed; the 13th entry is recorded with its reason.

---

## 8 · TEST STRATEGY

Every entry names what it proves. **[M]** entries are mutation-proven — the mutation is stated and the
test must be observed failing before it is believed.

### Release predicate
- **T-A1** *Positive control FIRST:* a release that SUCCEEDS under the new policy. Without it, every
  refusal below measures a door that refuses everything.
- **T-A2** refuses on `queued` only → `notice_never_accepted`. **[M** delete the acceptance clause **]**
- **T-A3** refuses on `processing`, on `failedPermanent`, and on `outcomeUncertain` (D11).
- **T-A4** refuses on `dispatched` + NULL acceptance (the legacy shape), **and** asserts by execution
  that `providerAccepted` writes status, `dispatched_at` and `notice_accepted_at` in ONE statement —
  the invariant that makes §3's legacy branch structurally unreachable for new rows.
- **T-A5** succeeds with acceptance stamped and the window elapsed **from the anchor**.
- **T-A6** refuses at the exact boundary, succeeds one instant later, and the owner challenge still
  wins the tie. **[M** `>` → `>=` **]**
- **T-A7** the anchor is **MIN, not MAX** — G1 accepted at T, G2 at T+2d ⇒ eligible at T+7d. The
  fixture must *interleave*, or MIN and MAX agree and the test is tautological. **[M** MIN→MAX **]**
- **T-A8** the anchor is **immutable under reissue** (D7, proven not commented). **[M** make reissue
  touch the anchor **]**
- **T-A9** **episode scoping** — an accepted notice from a prior *rejected* case does not authorize a
  new case. **[M** drop the `case_id` join **]**
- **T-A10** cross-estate: an accepted notice on estate X never authorizes estate Y.
- **T-A11** `begin_challenge_window` still opens on dispatched-but-unaccepted (D10) and refuses when
  no committed row exists for the case.
- **T-A12** unchanged neighbours re-asserted **whole**: two-person rule, halted refusal, unconfigured
  window, no-verified-case, `owner_not_notified`. A predicate rewrite is exactly when a neighbouring
  guard gets lost.
- **T-A13** no `coalesce(notice_accepted_at, …)` anywhere — a source audit following full scanner
  discipline: assert the resolved root exists and the file list is nonempty **before** evaluating any
  rule; strip comments but **not** string literals; pure-ASCII positive control; run twice in one
  process and assert identical results; cover `coalesce`, `COALESCE`, and multiline forms.

### Re-notice
- **T-C1** every refusal branch individually, including `notice_still_in_flight` from both `queued`
  and `processing`, `notice_already_accepted`, `reissue_cap_exhausted`, `invalid_reissue_state` from
  halted/released/active/death_verified, `no_active_notice`, `audit_reason_required`.
- **T-C2** every permitted branch: `failedPermanent`, `stale_beyond_age_gate`, `outcomeUncertain`,
  and the legacy `dispatched` + NULL-acceptance shape (§3).
- **T-C3** supersession: the predecessor's `superseded_by` points at the successor and its `status`
  and `failure_class` are **unchanged** — its evidence survives. **[M** remove the assignment **]**
- **T-C4** the partial unique index refuses a second active row for one case, **by execution**.
- **T-C5** the successor's recipient equals the predecessor's and **does not** equal a changed
  `auth.users.email`. The fixture must actually change the auth email, or it passes vacuously.
- **T-C6** reissue moves neither `owner_notified_at` nor the lifecycle state.
- **T-C7** admin-gated: anon, non-admin authenticated, AAL1 admin and stale-AAL2 admin all refuse
  with identical bytes.
- **T-C8** `reissued_by` is derived, not supplied — asserted against the routine **signature**, so
  the mistake is unwritable rather than merely untested.
- **T-C9** two sequential reissue calls: the second refuses `notice_still_in_flight`. Non-idempotent
  **and guarded**.

### Census, replay, compatibility
- **T-X1** the census's new keys reconcile against `total` with no nameless gap, on a **non-zero**
  furnished fixture. A 0/0 census may not prove correctness.
- **T-X2** a pre-Phase-A-shaped row survives Phase A with no value invented.
- **T-X3** the `NOT VALID` check permits a legacy NULL-`case_id` row to persist **AND** refuses a new
  NULL-`case_id` insert. Both directions.
- **T-X4** re-applying each migration is a no-op; running a bundle twice yields identical census
  output.
- **T-X5** **full clean replay end to end** — the R13 regression test (§7.5 condition 5).
- **T-X6** mobile is unaffected — a scan of `afterworth-mobile` for these column names returns zero,
  with a positive control proving the scan can find a column name that IS referenced.
- **T-X7** the console's `release_eligible_at` is **byte-identical** to the door's for the same case,
  proven by execution rather than by reading two expressions.
- **T-X8** every refusal code is raisable, and every raisable code is documented. Both directions.

### Historical estates
- **T-H1** an estate released before Phase D is unaffected — the predicate governs the
  `challenge_window → released` transition only.
- **T-H2** an estate at `challenge_window` with a legacy row becomes **non-releasable** with
  `notice_never_accepted` — the blast radius proven, not described.
- **T-H3** that same estate becomes releasable after reissue → drain → acceptance → seven days **from
  the new acceptance**. The full legacy remediation, end to end.
- **T-H4** an estate with two episodes (prior rejected case + current case) releases only on the
  current case's acceptance.

---

## 9 · OPERATOR EXPERIENCE (the contract `afterworth-admin` must satisfy)

Its enforcement point is that `admin_get_death_verification_case` must **project** these fields, so a
console cannot invent, infer or approximate them.

**Copy must distinguish** — notice queued · notice being processed · provider accepted notice ·
delivery outcome uncertain · notice failed · re-notice available.

**Never say "delivered."** `providerAccepted` is not delivered, received, opened, or viewed, and
nothing downstream is allowed to rename it. The product has no delivery attestation.

**Never render internal state.** `degraded`, `outcomeUncertain`, `malformed_payload` and similar are
development diagnostics. Operator copy describes the situation: *"The email provider never confirmed
whether the previous notice was accepted. It may already be in the owner's inbox."*

**Show all four dates with distinct labels** — `owner_notified_at` ("Notice dispatched"),
`notice_accepted_at` per generation ("Provider accepted"), the anchor ("Window started"), and
`release_eligible_at` ("Release eligible", **derived from the same function the door calls**). Showing
one date is how a console and a door come to disagree in front of an operator.

**The two-person rule does NOT extend to re-notice** (D6), stated explicitly so a reviewer does not
"complete" the pattern. A re-notice is a protective act toward the owner and cannot itself disclose
estate information; requiring a second operator would make the safest action the hardest one. No new
reviewer exclusion is created either — the operator who reissues MAY later be `reviewer_b`. Adding an
exclusion would be inventing a three-person rule by accident.

**The audit INSERT must not be wrapped in an exception handler.** This is the direct OB-4 lesson: a
swallowed `check_violation` on the audit write is precisely how every owner notice stranded for weeks
while the suite stayed green.

---

## 10 · RISKS

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | **Duplicate sends to a living owner.** A reissue is a genuinely new message; the provider cannot dedupe across generations because the idempotency key is row-scoped | HIGH | Cap at 3 generations; `dispatched`+accepted refuses outright; `queued`/`processing` refuse; the successor's own `queued` status blocks a double-click |
| R2 | **Permanently blocked legacy estates** | HIGH | Phase A produces the count **before** Phase D changes behaviour; product agrees remediation first; the remedy is ordinary reissue; T-H2/T-H3 prove both the blocking and the unblocking |
| R3 | **Console/database divergence** | HIGH | ONE derivation consumed by both; T-X7 proves byte-identity by execution |
| R4 | **A prior rejected case authorizes a new one** | HIGH | `case_id` episode scope; legacy NULL `case_id` matches no episode and is fail-closed; T-A9 mutation-proven |
| R5 | **A future seventh status becomes release-qualifying** | HIGH today → **eliminated** | Structural: the predicate never mentions `status` |
| R6 | **The window silently lengthens** by up to ~24h (the clock now starts at provider acceptance, and the cron is daily on Vercel Hobby) | MEDIUM | Stated in the deployment note and in console copy ("seven days from provider acceptance"). The real lever is cron cadence. This is the intended trade — the owner gets a full seven days of email-aware window instead of ~6 |
| R7 | **Bundle drift** — the pasted bytes are not the reviewed source | HIGH | `verifySourceDeploymentDrift.mjs`; `verifyBundleAtomicity.mjs`; SHA-256 + byte count recorded; deterministic rebuild proven twice. **The builder must not pin any line a mutation test edits** |
| R8 | **Audit drift** — a new action the constraint refuses, swallowed by a catch | HIGH | `source='admin'` is already admitted since 0014, so no constraint change is needed; the self-check inserts the reissue audit row **by execution**; no exception handler around it |
| R9 | **`superseded_by` breaks a purge** | MEDIUM | `ON DELETE SET NULL` prevents a hard failure **and** the purge asserts supersession-closure — the FK prevents a crash, the assertion prevents an incoherent leftover |
| R10 | **Mutation cleanup destroys branch work** | MEDIUM | Worktree or reverse-patch only; never `git checkout <production-file>`; `git diff --stat` compared before and after |
| R11 | **A test that specifies the defect** — any assertion pinning `status <> 'cancelled'` as correct | HIGH | §7.3 enumerates all seven sites. `release_safety_authorization.sql:998` pins a rejection for a state production cannot produce; after Phase D the door no longer reads it at all, so that assertion is **retired rather than migrated** |

---

## 11 · SUPERSEDED DURING STAGE 3.5

Retained for history. **None of the following is authoritative.**

1. **"Policy B" — `outcomeUncertain` may qualify a release.** Superseded by **D11**.
   `outcomeUncertain` means provider acceptance is *unknown*; it is neither accepted nor failed, so it
   cannot satisfy an irreversible release door. The remedy is deliberate operator re-notice. This also
   removes any need to stamp an "accepted" timestamp on an uncertain outcome — a fabrication D2 now
   forbids outright. Note that the final architecture disposes of the Policy A/B question
   *structurally* rather than by picking a status list: `outcomeUncertain` does not qualify because it
   stamps no acceptance.

2. **MIN/MAX left as a reasoned preference.** Superseded by **§4.1**: under D7 the anchor *must* be
   MIN, because MAX makes the clock operator-controllable. This is now determined, not preferred.

3. **R13's recommendation to "amend 0057's self-check in place" as the default.** Superseded by
   **D13** and corrected by evidence in **§7**. The recommendation was also factually incomplete: the
   first guard to fire is **0056**, and there are **two** guards in 0056 plus one in 0057. Amendment
   remains the outcome, but only after a replay proved it, three alternatives were refused, and the
   amendment was made supersession-aware in both files rather than simply relaxed.

4. **Stage 3's four-migration numbering (0058 schema / 0059 functions / 0060 console / 0061
   observer).** Superseded by the **Phase A-D staged rollout** in §6, which additionally moves the
   acceptance stamp and `case_id` writing *forward* into Phase A so the Phase B census measures a
   population that has stopped growing.

5. **"`reissue_reason` distinguishes an automatic path"** implying an automatic reissue exists. Under
   **D6** re-notice is operator-only; there is no automatic path in this phase. The reason vocabulary
   remains, derived from the predecessor's state and never a caller parameter — a caller-supplied
   reason would let an operator relabel an `outcomeUncertain` reissue and skip its acknowledgement.

---

## 12 · OUT OF SCOPE, FLAGGED SO IT IS NOT DECIDED SILENTLY

- **`get_owner_safety_status`.** Whether the owner is told about provider acceptance is a
  *disclosure* decision, not a synchronization one. It stays a closed four-value union.
- **`cancelled` has no production writer.** Recorded, not fixed. After Phase D the release door no
  longer reads it at all.
- **The age gate must NOT be re-derived from the anchor.** `owner_notice_age_gate()` is measured from
  `requested_at` and answers "is this still worth *sending*?". The anchor answers "has the owner had
  their *window*?". Deriving one from the other would recreate exactly the drift its own comment warns
  against. They stay independent.
- **Branch B remains closed** throughout every phase.
