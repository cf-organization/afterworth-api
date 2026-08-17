# Phase 11-OC — deployment note

```
PHASE A:            READY TO PASTE — NOT YET PASTED
PHASE B:            BLOCKED ON PHASE A (read-only census)
PHASE C:            NOT IMPLEMENTED
PHASE D:            NOT IMPLEMENTED — the stricter release policy is NOT ACTIVE
BRANCH B:           NOT STARTED — gate closed
PRODUCTION CONTACT: NONE
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

## Not implemented, and deliberately so

**Phase C** (`reissue_owner_safety_notice`) and **Phase D** (the release-door cutover, the
`release_eligible_at()` derivation and the clock re-anchor) are specified in
`docs/phase11oc-release-acceptance-authority.md` §5–§8 but are **not built**. Phase D additionally
carries the R13 hazard proven in Stage 2: it will break the historical self-checks in migrations
**0056** (two of them) and **0057** (one), and the treatment for that is decided in §7.5 but not yet
applied.

Building either ahead of the Phase B census would defeat the staging.
