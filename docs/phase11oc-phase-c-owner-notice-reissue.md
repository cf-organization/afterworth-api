# Phase 11-OC · PHASE C — the operator re-notice

**Status:** implemented, merged, and **DEPLOYED_AND_VERIFIED in production** (2026-08-17).
See §14 for the deployment verification record.
**Artifact:** `db/bundles/owner_notice_reissue_bundle.sql`.
**Phase D:** IMPLEMENTED, deployment required — `docs/phase11oc-phase-d-release-authority.md`.
**R13:** RESOLVED by Phase D. **Branch B:** not started, gate closed.

---

## 1 · WHY PHASE C EXISTS WHEN TODAY'S CENSUS IS ZERO

The Phase A production census measured `estates_at_door = 0`,
`would_be_refused_by_phase_d = 0`, one outbox row, `legacy_unaccepted = 1`. **No live estate needs
remediating today.**

Phase C is still required before Phase D, and the reason is operability rather than backlog.

Phase D creates **new legitimate refusal states that a running system reaches on its own**. After the
cutover, an estate whose notice settles `failedPermanent` or `outcomeUncertain` has no provable
acceptance and no route to obtain one — the drain will never re-send a terminal row, by design,
because a settled row may already be in the owner's inbox. Without a remedy, the **first
post-cutover provider failure produces a permanently unreleasable estate** whose only recovery is
hand-written SQL against a safety table.

Today's zero is a statement about today's data. It is not a statement about the system's ability to
recover, and Phase D must not ship without that ability.

The single legacy `dispatched` + NULL-acceptance row also needs Phase C before that class can ever be
remediated.

---

## 2 · THE ELIGIBILITY RULE, AND WHY IT IS NOT A STATUS LIST

A re-notice is permitted for the **current generation of the current case episode** when:

| # | Current generation | Verdict | Derived `reissue_reason` |
|---|---|---|---|
| A | `failedPermanent` | eligible | `prior_stale_beyond_age_gate` if `failure_class = 'stale_beyond_age_gate'`, else `prior_failed_permanent` |
| B | `outcomeUncertain` | eligible | `prior_outcome_uncertain` |
| C | `dispatched` **and** `notice_accepted_at IS NULL` | eligible | `legacy_no_acceptance_record` |
| — | `queued` | refused `notice_still_queued` | — |
| — | `processing` | refused `notice_still_processing` | — |
| — | `dispatched` **and** accepted | refused `notice_already_accepted` | — |
| — | `cancelled` | refused `notice_cancelled` | — |
| — | anything else | refused `notice_not_reissuable` (named, never a fall-through) | — |

**Case C is the load-bearing one.** `dispatched` is not proof of the Phase A acceptance fact: every
row written before Phase A carries that status with a NULL stamp, because the stamp did not exist.
Refusing that class on the strength of its status would leave exactly the population Phase D blocks
with no route to a remedy — which is the whole reason Phase C precedes Phase D.

Cases N3 and L in `db/tests/release_safety_authorization.sql` §11.5 are **both** `dispatched`. The
only difference is the FACT, and they reach opposite verdicts. Without that pair the rule would be a
status list wearing a timestamp's clothes.

### Lifecycle gate

Permitted: `owner_notification_dispatched`, `challenge_window`.
Refused: `active`, `death_verification_pending`, `death_verified`, `challenge_halted`, `released` —
all five asserted by execution in §11.6, alongside **both** permitted states as positive controls, so
a gate that refused everything cannot pass.

### Episode identity

The episode key is the **case**, resolved canonically (`status = 'verified'`, newest `decided_at`)
and compared against the caller's. A historical case, an unverified case and a nonexistent case are
each refused (§11.7). The routine takes **no estate parameter**, so estate/case mismatch is
unwritable rather than merely forbidden.

---

## 3 · WHAT A SUCCESSFUL CALL MEANS

> **NEW WARNING QUEUED.**

Not "the owner was warned". Not "the provider accepted". Not "delivered".

The new row starts `queued` with `notice_accepted_at` NULL, and only `record_owner_notice_outcome`'s
`providerAccepted` branch may ever stamp it. §11.3 proves this by reading the readiness census at
three points: `failedPermanent` → **REFUSED**; re-noticed and queued → **STILL REFUSED**; the
re-notice accepted → **ADMITTED**. The middle reading is the control — if a reissue alone moved the
estate into the admitted set, an operator would hold a button that manufactures release authority.

---

## 4 · WHAT CHANGED, AND THE TWO DECISIONS THAT ARE NOT OBVIOUS

### 4.1 A re-notice takes a DISTINCT `notice_kind`

`death_process.window_renotice`, not `death_process.window_opened`.

`window_opened` records a lifecycle transition that happened **once** and stamped `owner_notified_at`.
A second row carrying it would make the outbox assert the window opened twice, in the table an
investigator reads to reconstruct what the owner was told.

The Stage-3 design document (`phase11oc-release-acceptance-authority.md` §5.1) proposed keeping one
kind. **This phase supersedes that**, and the argument that motivated it is preserved intact: the
kind is OPERATOR vocabulary, and the OWNER is still told nothing new. `renderOwnerNoticeEmail` takes
only a link — no kind, no generation, no attempt count — so the second message is **byte-identical**
to the first, asserted in `test/ownerNoticeDrain.test.ts`.

### 4.2 The one-current-generation index follows the EPISODE, not the kind

This is the load-bearing consequence of 4.1 and the reason the two ship together.

Phase A's index was `(case_id, channel, notice_kind) WHERE superseded_by IS NULL`. With two kinds in
one episode that permits **one current `window_opened` row AND one current `window_renotice` row for
the same case** — two live generations, with nothing to say which the release door should read.

Migration 0059 replaces it with `(case_id, channel) WHERE superseded_by IS NULL`: strictly stronger,
and provably lossless on every extant row because `notice_kind` admitted exactly one value until this
migration. A pre-flight scan asserts that rather than assuming it, and runs **before** the drop, so a
violation fails with a sentence naming the problem while the old index is still in place.

§11.12 proves both directions by execution — a second current row of the **same** kind and of a
**different** kind are both refused — with a positive control (a superseded row is still accepted) so
the index cannot be refusing everything.

### 4.3 The readiness census reads the episode kind SET

`owner_notice_episode_kinds()` is single-sourced and consumed by `owner_notice_release_readiness_census`
and by the re-notice routine.

Left as the Phase A literal, the census could not see a re-notice at all: a remediated estate would
report as **refused** however many times it was re-noticed, its eventual provider acceptance would
never be counted, and Phase C would be inert **inside the very instrument built to prove it works**.

This is the change §11.3's third reading exists to protect, and mutation
`p11occ-readiness-blind-to-the-renotice-kind` is the proof that the protection is live.

Migration 0058's §6 blast-radius NOTICE still carries the single literal and is deliberately
unchanged: 0058 is a deployed artifact whose bytes are pinned, its §6 is a one-time paste-time
report rather than a predicate, and 0059 §4 is the Phase-C-aware counterpart.

---

## 5 · CONCURRENCY

Two layers, because a lock is a protocol and an index is a guarantee.

1. **Lock order** — the CASE row (episode identity), then the current generation. The winner
   supersedes and inserts; the loser blocks on the case row, then reads a fresh snapshot showing the
   newly queued successor and refuses with `notice_still_queued`.
2. **The wall** — `owner_notice_outbox_one_current_per_episode_idx`. Even with the lock defeated, a
   second row with `superseded_by IS NULL` for the same episode is refused by the database.

### The proof is a REAL two-session proof, not a simulation

§11.13B opens **two genuine backend sessions** via `dblink`. Session 1 calls the door and holds its
transaction open; session 2 issues the same call asynchronously and is observed **blocked**
(`dblink_is_busy = 1`). Session 1 commits, session 2 unblocks and refuses with `notice_still_queued`.

The fixture is built in its own top-level statement so it is **committed** before the remote sessions
connect — the first draft built it inside the same `DO` block, and both remote sessions saw no such
case and answered `case_not_found`. A concurrency test can only observe contention over rows that are
visible to the contending sessions.

If `dblink` is unavailable the section reports **SKIP** loudly and classifies itself down; it does
not claim a concurrency runtime proof it did not perform.

### One honest gap, stated

There is **no mutation removing a single `for update`**. Either lock alone serializes two operators —
with the case lock gone the loser parks on the notice row, with the notice lock gone it parks on the
case row, and both paths end in the same named refusal. A single-lock mutation is therefore genuinely
harmless, and a matrix entry that could only ever report NOT_DETECTED would be a false finding about
the suite rather than a real one about the code. The redundancy is deliberate.

---

## 6 · IDEMPOTENCY

`lib/ownerNotices/drain.ts` builds the provider `Idempotency-Key` from the **row id**.

| | domain |
|---|---|
| accidental retry / reclaim (same row) | **same** key — the provider no-ops a repeat |
| deliberate re-notice (new row) | **new** key — a genuinely new message |

A re-notice APPENDS rather than requeues, so the successor has its own primary key and therefore its
own idempotency domain — a property of the id, not of a flag anybody remembers to set. **No drain
change was required.** Mutation `p11occ-successor-reuses-the-prior-row-id` proves the distinction is
enforced.

Delivery semantics remain **AT-LEAST-ONCE**. No provider exactly-once behaviour is claimed anywhere.

---

## 7 · RECIPIENT DERIVATION, AND THE RESIDUAL RISK

Derived inside the definer through the same authoritative path as the initial dispatch:
`estate_owner_user_id()` → `auth.users.email`. There is **no recipient parameter**, and §11.0(b) pins
the signature at exactly `(uuid, text)` so adding one fails there.

**The residual risk is recorded rather than hidden.** Re-resolving means a re-notice goes to whatever
address the account carries now. `drain.ts` deliberately does NOT re-resolve at SEND time, and that is
the right rule there — a worker silently changing destination between enqueue and send is unaudited
and unattended. This is different: an operator decides, a reason is required, and an audit row is
written. Re-sending to the predecessor's stored address would also be inert for the commonest
remediable failure there is, a hard bounce on a dead address.

So the audit records **whether the resolved address differs** from the predecessor's, as a boolean,
never the address. An investigator gets the signal; the audit gains no contact detail it would then
carry forever.

**An unreachable owner fails closed** (§11.8b): refused with `owner_channel_unreachable`, no row
manufactured, and the current generation not retired. Queueing a row with no destination would leave
the episode with a second dead generation and the evidence of the first one retired — strictly worse
than before the button was pressed.

---

## 8 · AUDIT

Action `death_process.owner_notice_reissued`, severity `high`, source `admin`,
`target_table = 'owner_notice_outbox'`, `target_id = <new notice id>`.

Metadata: `case_id`, `prior_notice_id`, `prior_generation`, `prior_status`, `prior_failure_class`,
`prior_notice_kind`, `new_notice_id`, `new_generation`, `notice_kind`, `channel`, `reissue_reason`
(derived vocabulary), `reason` (the operator's free text), `recipient_changed` (boolean).

**No recipient address, on any branch.** An audit row outlives every reason anyone had to read it.

It is a **distinct action**, never `owner_notice_dispatched`: that action means "an operator opened
the window and started the challenge clock", and a reissue did neither. Reusing it would make the
trail assert a lifecycle transition that never happened and hide the reissue from anyone counting
dispatches.

---

## 9 · A FINDING FROM THIS PHASE — `btrim` DOES NOT TRIM TABS

The reason check was first written `btrim(p_reason) = ''`, matching the sibling routines. §11.9 sent
`E'\t\n'` and **it was accepted**: single-argument `btrim` strips SPACES only, so a reason of one tab
lands in the audit as a blank field.

The Phase C routine now uses `p_reason !~ '[^[:space:]]'` — "contains no non-whitespace character",
which is the requirement stated directly.

**The sibling routines were NOT changed.** `purge_outbox_rows` and `authorize_release` carry the
narrower spelling. Widening a deployed reason check is its own decision with its own blast radius,
and `authorize_release` is Phase D's file. Recorded here so it is a decision rather than an omission.

---

## 10 · CONSOLE CONTRACT

The operator console reads a **server-calculated verdict**. `admin_get_death_verification_case`
projects `owner_notice_reissue`, computed by `owner_notice_reissue_assessment` — the same function
`reissue_owner_safety_notice` consults. The console renders it and never recomputes it.

`reissue_owner_notice` is deliberately **not** an `ActionId` in the console, so a local mirror cannot
be added without first widening the type — which is the loud step that should be required.

### Labels

| Row state | Label |
|---|---|
| `queued` | Notice queued |
| `processing` | Notice processing |
| `dispatched` + acceptance | Provider accepted notice |
| `dispatched` + NULL acceptance | Legacy acceptance fact unavailable |
| `outcomeUncertain` | Provider outcome uncertain |
| `failedPermanent` | Notice failed |
| superseded generation | Historical notice generation |

**No notice state is ever labelled "Delivered."** `noticeStateLabel()` and
`historicalNoticeDetail()` — the two functions that name a row's state — contain no form of the word,
asserted across all 24 status × acceptance × currency combinations, and the rendered values of
`DISPATCH_SUMMARY_COPY` carry none either. `dispatched` + acceptance renders **Provider accepted
notice**, which is the strongest honest claim: the provider took the message, and mailbox delivery is
not something this product observes.

★ **THE BOUNDARY, STATED EXACTLY — an earlier draft of this section overclaimed.** It said the word
"appears nowhere", which is broader than what is enforced and broader than what is true. Two
occurrences survive, and both are correct:

- `DISPATCH_SUMMARY_COPY`'s **keys** `delivery_failed` / `delivery_uncertain` are internal union
  members, never rendered; their values are "Notice failed — it will not be retried" and "Provider
  outcome uncertain — it will not be retried".
- `REISSUE_REFUSAL_COPY.owner_channel_unreachable` renders *"…so a re-sent notice could not be
  delivered to anyone."* That is a **counterfactual about impossibility**, not a claim that anything
  was delivered, and it is true whenever it is shown.

The enforced rule is therefore *"no notice STATE is ever described with the word"*, not *"the token
never occurs"*. Found by a control run during production verification, and corrected here rather than
left standing — a claim wider than its instrument is the failure this repository has a standing rule
about.

---

## 11 · EVIDENCE

| Instrument | Result |
|---|---|
| SQL authorization suite (fresh Docker Postgres, full clean replay) | **450 assertions**, exit 0 (baseline 433) |
| §11 sub-sections | 11.0–11.13, all green |
| Real two-session concurrency proof | `dblink_is_busy = 1` while held; `notice_still_queued` after commit |
| API mutations | **31/31 DETECTED** (29 × `p11occ-*`, 2 retargeted `p11oc-*`), tree byte-identical before/after |
| Console mutations | **6/6 DETECTED**, tree byte-identical |
| vitest (api) | 641/641 |
| vitest (admin) | 101/101 |
| `tsc --noEmit` | clean, both repos |
| `next lint` | no warnings or errors |
| Bundle atomicity | all 14 artifacts apply + roll back; Phase C witness discriminates |
| Deterministic rebuild | byte-identical across two rebuilds |
| Source/deployment drift | source and deployment agree on all 4 reconcilable contracts |
| gitleaks | **no leaks in any changed file**; 4 pre-existing findings in `.env.local` and two Branch-B test files, untouched by this phase |

### Mutations retargeted, and why the move is recorded

- `p11oc-readiness-reads-current-generation-only` and `p11oc-readiness-scoped-to-estate` — their
  anchors span the kind predicate Phase C legitimately changed. Retargeted to the new text with their
  meaning preserved exactly; both still DETECTED.
- `p11oc-one-current-generation-not-enforced` — **retired**, and replaced by
  `p11occ-one-current-per-episode-not-enforced` plus `p11occ-episode-index-keeps-the-kind`. Migration
  0059 drops the index 0058 creates, so a mutation of 0058's index can no longer reach the database:
  the mutated index is dropped moments later and the verdict would be NOT_DETECTED, sending someone to
  rewrite tests that are fine. The invariant did not weaken — it got stronger — and its mutation
  follows it to the artifact that owns it, plus the cross-kind direction the retired entry could not
  see.

---

## 12 · R13 — STILL PENDING

The seven cutover-pinning sites (0056 ×2, 0057 ×1, four `p11e-*`/`p11f-*` mutation fixtures) are
**deliberately unmodified**. They currently pass, and while they pass they are active evidence that
the Phase D cutover has not happened. A full clean replay confirms it.

Phase C touched none of them: 0059 §3.3 asserts the pre-Phase-D predicate about itself, exactly as
0058 §5.4 does.

---

## 13 · DEPLOYMENT

Artifact: `db/bundles/owner_notice_reissue_bundle.sql` — one file, one transaction, pure SQL, no psql
meta-commands.

**Order:** paste after the Phase A bundle. 0059 drops the index 0058 creates, so re-pasting Phase A
*after* Phase C would resurrect the weaker per-kind index alongside the stronger one. That is not a
safety regression — the per-episode index still holds — but it is drift, and 0059 is self-healing:
re-running it drops the resurrected index and its §3.1 asserts the absence.

Post-deployment: `node scripts/verifyPhaseCDeployment.mjs` — read-only, calls three `stable` routines,
never invokes the writer, refuses a service-role key.

### Runtime proof

**`PRODUCTION_RUNTIME_PROOF_PENDING`.**

Executing a real re-notice would append a generation to a live safety queue and **queue an email to a
living person about their own death process**. That is a production action, not a check. Production
currently holds zero challenge-window estates and no live remediation target, so:

- **DEPLOYED CONTRACT PROOF** — the verifier above, runnable immediately after the paste.
- **LIVE REMEDIATION PROOF** — deferred until a legitimate fixture exists or a synthetic case is
  separately authorized.

Conflating the two would be faking evidence.

---

## 14 · PRODUCTION DEPLOYMENT VERIFICATION — 2026-08-17

Christ pasted `db/bundles/owner_notice_reissue_bundle.sql` into the Supabase Web SQL Editor. This
section records what was then established, and — as importantly — what was **not**.

### 14.1 Identity of what was deployed

| | |
|---|---|
| API merge | `e01d422bcafb5020225b009c45384530a78a1f5d` (PR #81) |
| Admin merge | `4611d37d942f3234faaec431ebcfa6b1f3f56281` (PR #8) |
| Artifact SHA256 | `128db113fef5e44f4339b22f45c75c8764c84ea55e4520ff2b85e005e3818a32` — **exact** |
| Artifact bytes | `129195` — **exact** |
| Rebuild | byte-identical to the committed file, twice, tree clean afterwards |
| Verifier | `node scripts/verifyPhaseCDeployment.mjs` → **exit 0** at 21:17:53Z |

### 14.2 What is live, and how each claim was established

The distinction matters more than the verdict, so it is written per routine rather than as one line.

| Routine | Established by |
|---|---|
| `owner_notice_reissue_assessment` | **EXECUTION** — the case file carries its verdict, on 7/7 production cases, with the full designed shape |
| `owner_notice_episode_kinds` | **EXECUTION** — `owner_notice_release_readiness_census` calls it and returned 200; a missing function is a plpgsql runtime error, so the 200 cannot have happened without it |
| `owner_notice_reissue_kind` | **TRANSACTIONAL CO-LOCATION** — same part, same single-`begin;`/`commit;` artifact as the assessment observed live. An inference, labelled as one |
| `reissue_owner_safety_notice` | **TRANSACTIONAL CO-LOCATION** — as above. **Never called** |
| migration 0059 | **TRANSACTIONAL PRECEDENCE** — it runs first in the same transaction; parts 2–4 being live means the transaction committed, and 0059's own §3 self-checks would otherwise have aborted it |

**Two instruments were tried and rejected, and the rejections bound what the table above may claim.**

1. **PostgREST's per-role OpenAPI document** (`GET /rest/v1/`) would have listed every routine each
   role may execute — existence *and* privilege, without dispatching to anything. This instance
   answers `401 {"message":"Secret API key required"}`. A secret key is refused by this session and by
   the committed verifier, because running an operator assertion as `service_role` bypasses
   `admin_require_gate()` — the very thing under test. **UNAVAILABLE, not merely unused.**
2. **An `OPTIONS` preflight** would have been pure metadata. It **failed its own negative control**:
   PostgREST answered `200` for `definitely_not_a_function_xyz` and `another_absent_routine_qqq`
   exactly as for `owner_notice_census`. It was discarded *before* being pointed at the writer.

So the writer's presence is an **inference from atomicity**, not a catalog read. That is weaker than
the evidence for the other routines and is recorded as such.

### 14.3 Privilege posture — probed on the SHARED gate, via READ doors only

`reissue_owner_safety_notice` runs the same `admin_require_gate()` that `owner_notice_census` runs, so
probing it through a read door is evidence about that gate without entering a routine that writes. The
gate's order (auth → is_admin → aal2 → freshness) means a non-admin is refused at `admin_required`
*before* the factor check, so an AAL1 persona still proves the identity half.

| Caller | Result |
|---|---|
| anon | `permission_denied` |
| a real ADMIN at AAL1 | `mfa_required` |
| an ordinary authenticated **owner** persona | `admin_required` |
| an ordinary authenticated **fiduciary** persona | `admin_required` |
| the operator at fresh AAL2 | admitted |

No projection returned a recipient (0 leaks across 7 cases); no address shape appeared in any
`owner_notice` row, any re-notice verdict, or either census.

### 14.4 Phase A regression — intact, and every split reconciles

```
total 1 · by_status {dispatched: 1} · age_gate 8 days
accepted_total 0 + unaccepted_total 1 = 1
superseded_total 0 + current_total 1 = 1
by_generation {1: 1} sums to 1 · by_status sums to 1
legacy_unaccepted 1 ⊆ unaccepted_total 1
no_episode 1
```

`accepted_total` is still **0** — no acceptance was backfilled by the Phase C paste, which is the one
number that would have exposed a guessed backfill. The single historical row remains
`dispatched` + `notice_accepted_at NULL` + `case_id NULL`, exactly as Phase A left it, and it was not
mutated.

Readiness census: `estates_at_door 0`, `by_readiness {}`, refused 0, admitted 0,
`would_be_admitted_by_current_predicate 0`. Admitted + refused = estates_at_door; buckets sum; no
`unclassified`.

### 14.5 Phase C remediation classification

Across all 7 operator cases — aggregated, never enumerated:

```
lifecycle          {challenge_halted: 1, active: 6}
re-notice verdicts {no_verified_case: 6, invalid_reissue_state: 1}
notice rows        1  (current 1, superseded 0)
rows naming an episode  0 / 1   (the legacy row's case_id is NULL)
generations beyond 1    0
notice state       {dispatched + NO-ACCEPTANCE (legacy): 1}
```

```
PHASE_C_LIVE_TARGET: NONE
```

Every case is refused for a lifecycle or currency reason, not for a notice-state reason. **No estate
in production is eligible for a re-notice**, which is the expected consequence of a zero
challenge-window population.

### 14.6 Phase D has NOT landed — and the proof executed IN production

The strongest evidence is not a static grep. **Migration 0059 §3.3 ran inside the production paste.**
It reads the deployed `authorize_release` and raises if the pre-Phase-D predicate is missing or if the
body already reads `notice_accepted_at`. The artifact carries exactly one `begin;` and one `commit;`,
so a raise would have aborted the entire paste and Phase C would not be deployed.

Phase C **is** deployed. Therefore, at paste time, production's `authorize_release` still carried
`status <> 'cancelled'` and did not read the acceptance fact. Nothing has been deployed since.

Corroborating, statically at `origin/main`:

- all seven R13 pins remain in pre-Phase-D posture — `0056` ×2 (lines 168, 176), `0057` ×1 (line 143),
  and the four mutation anchors `p11e-release-without-owner-notice`,
  `p11f-release-skips-dispatch-check`, `p11e-release-before-window-elapses`,
  `p11e-challenge-loses-the-tie`;
- `authorize_release` carries `o.status <> 'cancelled'` and **zero** occurrences of
  `notice_accepted_at` in its body;
- `owner_notified_at` retains its release-clock role;
- `notice_never_accepted` exists in no function and no migration — only in a NOTICE string and
  comments.

**Stated honestly:** the readiness census's `current_predicate ≥ phase_d` check is *vacuous today*
(0 ≥ 0) because no estate stands at the door. It is reported, not counted as evidence.

### 14.7 Standing fixture, drift, freshness

| | |
|---|---|
| Standing fixture | **23/23**, 0 failures, exit 0 |
| Fixture lock | **FREE** (`.aw-fixture-lock` absent) |
| Branch B | `BRANCH_B_FIXTURE_ABSENT` — the expected answer |
| Source/deployment drift | exit 0 — agree on all 4 reconcilable contracts |
| Registered-artifact freshness | 66/66 — every one of the 14 artifacts byte-identical to a fresh rebuild |
| Full clean replay | exit 0, **451 assertions**; `0057 OK`, `0058 OK`, `0059 OK`, both 0056 guards passed |

No challenge-window estate was manufactured, no disclosure changed, no owner notice was queued, and
no estate was modified during verification.

### 14.8 Admin production surface

Vercel **Production** deployment of `4611d37` — the Phase-C admin merge — state `success`,
2026-08-17T20:00:49Z. The deployed application therefore corresponds to the Phase-C merge.

Production data exercises exactly **one** label branch: the single outbox row is
`dispatched` + `notice_accepted_at NULL` + current, which the deployed logic renders **"Legacy
acceptance fact unavailable"** — the branch this phase exists to stop reading as an acceptance.

The other six branches have no production data. They are **`LOCAL_RENDER_PROOF_ONLY`**, covered by
101 admin tests and 6/6 console mutations, and were **not** synthesized in production.

### 14.9 Runtime proof

```
PHASE_C_RUNTIME_PROOF: PENDING — NO LEGITIMATE PRODUCTION TARGET
```

`reissue_owner_safety_notice` was **not invoked**. No production target satisfies the eligibility
rule, and manufacturing one would mean queueing an email to a living person about their own death
process. The absence of a production mutation here is **intentional and is the correct outcome**, not
a gap in the verification.
