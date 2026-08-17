# Phase 11-OC — deployment note

```
PHASE A:            DEPLOYED AND VERIFIED — 2026-08-17T17:50Z
PHASE B:            COMPLETE — census read, results in §B below
PHASE C:            NOT IMPLEMENTED — REQUIRED before Phase D (see §B.4)
PHASE D:            NOT IMPLEMENTED — the stricter release policy is NOT ACTIVE
BRANCH B:           NOT STARTED — gate closed
PRODUCTION CONTACT: READ-ONLY (two stable censuses + one operator projection)
```

Policy and reasoning: `docs/phase11oc-release-acceptance-authority.md`.

---

## PHASE A — the only artifact to paste now

| | |
|---|---|
| Artifact | `db/bundles/owner_notice_acceptance_bundle.sql` |
| SHA-256 | `92cba7870ab7cb03b44ff02724aef7c6f30b6128687e1a350a52a540bab9c7b2` |
| Bytes | 124,917 |
| Lines | 2,003 |
| Parts | `db/migrations/0058_20260817_owner_notice_acceptance_episode.sql`, `db/functions/outbox_safety.sql`, `db/functions/release_safety.sql` |
| Transaction | ONE explicit `begin;` / `commit;` — verified 1/1 |
| Meta-commands | 0 (verified) |
| Rebuild | byte-identical across two rebuilds (same SHA-256 above) |
| Atomicity | `applies=true rollback=true` against a throwaway Postgres |

### What it changes

- `owner_notice_outbox` gains `notice_accepted_at`, `case_id`, `generation`, `superseded_by`,
  `reissue_reason`, `reissued_by` — all additive, all nullable-safe.
- A `BEFORE INSERT` trigger requires every NEW owner-notice row to name its death-verification case.
  Legacy rows keep `case_id IS NULL` **and stay updatable**, which the drain depends on.
- A partial unique index enforces exactly ONE current generation per case episode.
- `record_owner_notice_outcome` stamps `notice_accepted_at` on the `providerAccepted` branch, in the
  same `UPDATE` as `status` and `dispatched_at`.
- `dispatch_owner_safety_notice` writes `case_id` and `generation = 1`.
- Two read-only censuses: `owner_notice_census()` gains acceptance/episode splits, and
  `owner_notice_release_readiness_census()` is new.

### What it does NOT change

**Nothing about when a release may proceed.** Migration 0058 asserts this about itself by reading the
deployed `authorize_release` and requiring the pre-Phase-D predicate to still be present, and the SQL
suite asserts it again (§10.7). Both R13 guards in migrations 0056 and 0057 pass unchanged in a full
clean replay, which is independent confirmation that this paste is behaviour-neutral.

### After pasting, run and record — this IS Phase B

```sql
select public.owner_notice_census();
select public.owner_notice_release_readiness_census();
```

Both are admin-gated, read-only, and return **counts only** — no estate id, no case id, no user id, no
recipient address, on any branch.

The migration also prints the same figures as a `NOTICE` during the paste. Capture them.

### The Phase D gate

The number that matters is `would_be_refused_by_phase_d`.

**If it is greater than zero, Phase D must not be built or activated for that class until the Phase C
re-notice remedy is deployed and operational.** Those estates have no provable provider acceptance in
their current case, so the stricter door would refuse them with `notice_never_accepted` and they would
have no route to release except a remedy that does not exist yet.

That is the entire reason the rollout is staged, and the reason Phase A is behaviour-neutral: the count
must be known **before** any estate is blocked.

### Honest consequence to expect at Phase D (not now)

The release clock will re-anchor from dispatch to **provider acceptance**. On the current daily cron
that is up to ~24h later, so release becomes eligible up to a day later than today. That is the
intended trade — the owner gets a full seven days of email-aware window instead of ~6 — and console
copy must say "seven days from provider acceptance", never "from dispatch". The lever is cron cadence,
not the policy.

### Rollback

Phase A is additive and nullable throughout. Leaving it in place is harmless; dropping it is neither
required nor recommended. The one non-obvious dependency: the `BEFORE INSERT` trigger requires
`dispatch_owner_safety_notice` to write `case_id`, and both ship in this same artifact, in this order.

---

---

# §B · PHASE A VERIFICATION AND THE PRODUCTION CENSUS

Read **2026-08-17T17:50:19Z**, project `yiaavvkulrpqkkbqhwit`, by
`scripts/verifyPhaseADeployment.mjs` — read-only, admin-gated, governed by
`test/noProductionMutation.test.ts`.

Repository state at verification: `afterworth-api` main = `6a4f60be6fcf34e94ae43f00ca95c8b1c7ee82e8`,
clean, one worktree. The artifact rebuilt to
`92cba7870ab7cb03b44ff02724aef7c6f30b6128687e1a350a52a540bab9c7b2` / 124,917 bytes — matching the
committed digest exactly, twice, with no regeneration drift.

## B.1 Deployment is verified

Both halves of the paste landed, proven by **execution** rather than introspection:

- The **function half**: `owner_notice_release_readiness_census()` is new in Phase A and answered.
- The **migration half**: `owner_notice_census()` under Phase A reads `notice_accepted_at`, `case_id`,
  `superseded_by` and `generation`. It returned all seven new keys, so every column exists — one
  assertion covering both halves. Every pre-Phase-A key also survived, so the routine was extended
  rather than replaced.

The gate was **passed, not bypassed**: a real synthetic admin stepped up to `aal=aal2` through a live
TOTP factor, and both censuses admitted it.

## B.2 The production reading

```json
readiness: { "estates_at_door": 0, "by_readiness": {},
             "would_be_refused_by_phase_d": 0, "would_be_admitted_by_phase_d": 0 }

outbox:    { "total": 1, "by_status": { "dispatched": 1 },
             "accepted_total": 0, "unaccepted_total": 1,
             "legacy_unaccepted": 1, "no_episode": 1,
             "superseded_total": 0, "current_total": 1,
             "by_generation": { "1": 1 },
             "oldest_requested_at": "2026-08-15T06:46:18Z" }
```

Every split reconciles: `0+1=1` accepted/unaccepted, `0+1=1` superseded/current, `by_generation` sums
to 1, `legacy_unaccepted ⊆ unaccepted_total`, and `0+0=0` admitted/refused against `estates_at_door`.
No `unclassified` bucket appeared.

**`would_be_refused_by_phase_d = 0`.**

## B.3 The zero is a REAL zero

A 0/0 census and a census that inspected nothing are indistinguishable from the outside, so the
production result is corroborated by an independent projection rather than taken at face value.
`admin_list_death_verification_cases` reaches the lifecycle by a different route and returned **7
cases** with the histogram `{ challenge_halted: 1, active: 6 }` — **none at `challenge_window`**. Queue
and census agree at 0.

The instrument is also known to be capable of a non-zero answer: `release_safety_authorization.sql`
§10.6 proves it reports **both** admitted and refused against furnished fixtures, in both directions.

## B.4 No backfill happened — and the numbers are the evidence

One outbox row exists, `dispatched`, requested `2026-08-15` (pre-Phase-A). It carries:

- `notice_accepted_at` **NULL** → `accepted_total = 0`, `legacy_unaccepted = 1`
- `case_id` **NULL** → `no_episode = 1`

Had acceptance been backfilled, this row — the only candidate — would carry a fabricated acceptance and
`accepted_total` would read 1. Had `case_id` been backfilled from the dispatch audit metadata (which is
*technically* possible and is forbidden in writing for exactly this reason), `no_episode` would read 0.
Both read the fail-closed value. **`notice_accepted_at` still means only "provider acceptance
established", and nothing else.**

This single row is the D5/D9 legacy class — `dispatched` **and** `notice_accepted_at IS NULL`. It must
never be read as accepted. Its estate is not at the door today, so it contributes nothing to the
refusal count, but Phase C must be able to remediate this status/fact pair.

## B.5 Behaviour neutrality

Phase A did not activate Phase D. Four independent instruments, each covering a different half:

| Instrument | What it settles |
|---|---|
| `verifySourceDeploymentDrift.mjs` | exit 0 — source and **deployed** agree exactly on all 4 reconcilable contracts, compared by executing both sides against one input matrix |
| `release_safety_authorization.sql` §10.7 | asserts on the deployed body that `authorize_release` still carries the pre-Phase-D predicate |
| migrations 0056 (×2), 0057 (×1), 0058 §5.4 | the predicate guards pass on every replay; 0058 asserts the inversion |
| `verifyOperatorDoorRefusal.mjs` / `verifyOperatorAdmitPath.mjs` | exit 0 — three operator doors deployed, non-admins refused `admin_required`, AAL2 admins admitted, `authorize_release` reachable and admin-gated, not open |

Observed once during this session by direct probe (since removed from the committed instrument so it
could be placed under the read-only audit): `authorize_release` on a nil estate refused with
**`invalid_release_state`** — the pre-Phase-D sentinel — and **not** `notice_never_accepted`, which only
the Phase D predicate raises.

Standing production fixture: **23/23 PASS, exit 0, lock FREE** ("FIXTURE RESTORED … Safe to mutate").
Branch B estate: **not provisioned**, the expected answer.

## B.6 Phase C — required, and for two different reasons

The decision gate distinguishes two questions that a zero count makes easy to conflate:

**Current production migration dependency: NONE.** `would_be_refused_by_phase_d = 0`, corroborated.
No live estate is blocked by a Phase D cutover today.

**Permanent product operability dependency: PHASE C IS REQUIRED.** Policy D creates *new legitimate*
refusal states that a running system reaches on its own. After cutover, an estate whose notice settles
`failedPermanent` or `outcomeUncertain` has **no provable acceptance and no route to obtain one** — the
drain will not re-send a terminal row, by design. Without a re-notice remedy the **first post-cutover
provider failure creates a permanently unreleasable estate**, and the only recovery would be
hand-written SQL against a safety table.

Today's zero is a statement about today's data. It is not a statement about the system's ability to
recover, and Phase D must not ship without that ability.

The single legacy row in B.4 also needs Phase C to support the `dispatched` + NULL-acceptance pair
before that class can ever be remediated.

---

## Not implemented, and deliberately so

~~**Phase C** (`reissue_owner_safety_notice`)~~ **is BUILT and DEPLOYED** — see
`docs/phase11oc-phase-c-owner-notice-reissue.md`, whose §14 carries the production verification
record (2026-08-17, verifier exit 0, artifact SHA256 exact, 0 legitimate live re-notice targets).

**Phase D** (the release-door cutover, the `release_eligible_at()` derivation and the clock re-anchor)
is specified in `docs/phase11oc-release-acceptance-authority.md` §5–§8 but is **not built**.

Phase B is complete and **Phase C is now built**, so the ordering constraint §B.6 stated —
**Phase C must precede Phase D**, on operability grounds rather than on today's legacy count — is
satisfied in the repository **and now in production**: Phase C was pasted and verified on
2026-08-17. The §B.6 ordering constraint — a cutover must never land ahead of its own remedy — is
therefore discharged, and Phase D DEVELOPMENT is unblocked. Phase D **deployment** remains closed
pending R13 resolution, the release-predicate and clock cutover, full replay and mutation proof.

**R13 remains PENDING.** Phase D will break the historical self-checks in migrations **0056** (two
guards) and **0057** (one), plus four mutation fixtures — seven pinning sites, enumerated in
`phase11oc-release-acceptance-authority.md` §7.3. Those guards are **deliberately unmodified**: they
currently pass, and while they pass they are active evidence that the cutover has not happened. The
treatment is decided in §7.5 and applies with Phase D, not before.
