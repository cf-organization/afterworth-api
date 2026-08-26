# Phase 11-Q — post-release verification hardening

```
SENTINEL RELEASED-STATE SEMANTICS:   HARDENED
FABRICATED AUTHORIZATION COUNT:      REMOVED
CANONICAL DISCLOSURE PRE-CAPTURE:    IMPLEMENTED
CANONICAL POST-RELEASE VERIFIER:     IMPLEMENTED
MIGRATION:                           NONE
BRANCH B DISCLOSURE GAP:             STILL OPEN — and now unclosable, by design
```

Three findings from the Branch B closeout (`docs/phase11p11-*`), fixed for the **next** drill.
Nothing here retroactively closes Branch B's gap, and §4 explains why that is the correct outcome
rather than a shortfall.

---

## 1 · The sentinel could not describe a successful release

`classifyBranchBSentinel` is pinned to a checkpoint written at `challenge_window`. A correct release
flips three of its expectations at once — `released_at` becomes non-null, the pinned `lifecycle`
moves to `released`, and the death-conditioned document becomes DISCLOSED. Each produced a finding,
and any finding forced `BRANCH_B_SENTINEL_DRIFTED` at exit 1.

> **The `SENTINEL.OK` branch was unreachable.** The classifier ended with
> `released_at === null ? IN_FLIGHT : OK` and its comment called `OK` "the drill finished cleanly",
> but the findings list could never be empty once a release existed. A verdict no input can produce
> is not a verdict.

**The fix is phase awareness, not tolerance.** `observedPhase()` reads two independent signals —
`released_at` and `lifecycle` — and each phase carries its own expectations:

| Phase | Condition | Disclosure expectation | Verdict when clean |
|---|---|---|---|
| `pre_release` | neither released signal | must be `hidden` | `BRANCH_B_IN_FLIGHT_WAITING` |
| `released` | both released signals | must be `sentinel_DISCLOSED` | `BRANCH_B_SENTINEL_OK` |
| `inconsistent` | exactly one | — | `BRANCH_B_RELEASED_INCONSISTENT` |

`RELEASED_INCONSISTENT` exists so the fix cannot become a post-release amnesty. The release routine
writes both fields in one transaction, so they cannot honestly disagree; a half-released estate is
neither a healthy in-flight drill nor a clean finish and must borrow neither verdict.

Pre-release drift detection is **unchanged**. In the released phase only `lifecycle` is dropped from
the pinned set — and only because the phase itself asserts it. Every identity fact (estate, case,
outbox, both reviewer uids, the acceptance instants) is still compared, so a seat that moved across a
release is still caught.

Mutation-proven: forcing `observedPhase` to always return `pre_release` fails 4 tests; deleting the
inconsistent branch fails 3.

---

## 2 · The authorization count was fabricated, and it printed

`scripts/branchBSentinel.mjs` set `release_authorizations: 0` as a **literal** and never read a
database. Two live consequences:

1. The consumer check `if (branchB.release_authorizations !== 0)` could **never fire**.
2. The CLI *printed* it: `reviewer B <uid> (reserved, 0 authorization(s))`. After a real release the
   sentinel still called reviewer B **reserved with zero authorizations** — a claim production
   directly contradicted.

**It was removed, not repaired.** `release_authorizations` has RLS enabled with **zero grants and
zero policies** — DEFINER-routine-only — so no client can count it, and inventing a read would mean
widening a deliberately sealed table to satisfy an instrument. Duplication is already bounded where
it belongs:

| Layer | Guarantee |
|---|---|
| `release_authorizations_one_per_estate` unique index on `(estate_id)` | a second row is impossible |
| `release_authorizations_two_person check (reviewer_a <> reviewer_b)` | no single-reviewer release is insertable |
| writer early-return on an already-released state | replay inserts no row and re-audits nothing |

`released_at` is the observable fact and is pinned. A static regression forbids the literal returning,
with a positive control proving the matcher can see the pattern it bans.

---

## 3 · The future-drill sequence

```
CHALLENGE_WINDOW
        ↓
CAPTURE COMPLETE CANONICAL DISCLOSURE PRE SNAPSHOT     ← MANDATORY, and only possible here
        ↓
VALIDATE COMPLETENESS + RECORD DIGEST
        ↓
NORMAL RELEASE QUALIFICATION  (preflight, sentinel, T2, drift, authority)
        ↓
IRREVERSIBLE RELEASE
        ↓
CAPTURE COMPLETE CANONICAL DISCLOSURE POST SNAPSHOT
        ↓
evaluateDisclosureEquivalence(pre, ownerPre, post)
        ↓
CANONICAL POST-RELEASE DISCLOSURE VERDICT
```

```bash
# BEFORE the release boundary — refuses once the estate is released
node scripts/captureDisclosureSnapshot.mjs --phase=pre \
     --case=<uuid> --grant=<uuid> --sanctioned=<uuid[,uuid]> --out=pre.json

# AFTER the release
node scripts/captureDisclosureSnapshot.mjs --phase=post \
     --case=<uuid> --grant=<uuid> --sanctioned=<uuid[,uuid]> --out=post.json

node scripts/verifyDisclosureEquivalence.mjs --pre=pre.json --post=post.json \
     --expect-pre-digest=<sha256 printed by the pre capture>
```

**PRE capture is mandatory before crossing the release boundary.** There is no single-file mode and
no reconstruction path. Skipping it means the drill can never obtain a canonical disclosure verdict —
which is exactly what happened to Branch B.

### What the collector guarantees

- **The universe is enumerated, never assumed.** `documents_read` lets the owner select every
  document on the estate and a non-owner only what `can_access_document` admits, so the owner's
  SELECT *is* the universe. The four Branch B documents are **not** hardcoded; a drill with eleven
  documents captures eleven.
- **Both access signals are recorded** — the `can_access_document` policy gate *and* the RLS-filtered
  product read. They answer the same question by different mechanisms, and the verifier refuses when
  they disagree rather than picking the nicer answer.
- **Completeness is proved, not assumed.** Missing documents, duplicate ids and undeclared documents
  each refuse. This is the exact hole Branch B fell through: two of four observed, and nothing said so.
- **Wrong lifecycle refuses**, with `PRE_RELEASE_OBSERVATION_WINDOW_CLOSED`.
- **The phase is a field, not a filename**, covered by the digest — so a snapshot cannot be renamed
  into the other role.

### Refusal is not failure

`REFUSE_INCOMPLETE_PRE`, `REFUSE_IDENTITY_MISMATCH`, `REFUSE_WRONG_LIFECYCLE` and
`REFUSE_PROVENANCE_FAILURE` are distinct from `FAIL` and exit 2 rather than 1. *"This release was
wrong"* and *"I cannot say whether this release was wrong"* need opposite responses from an operator.

Two refusals are deliberately named apart: a pre-image that is **short** (go collect more) and a
pre-image that **is not a pre-image** (nothing can fix it) are different problems.

### The sealed invariant is checked outside the oracle

The oracle reasons about *sets*, so it catches a sealed document that **changed** visibility. It would
not object to one visible in **both** phases, because nothing moved. `sealed` is never grantable under
any role at any lifecycle, so that case is caught separately by sensitivity — in both phases.

---

## 4 · Branch B's gap stays open

The historical drill has no complete pre-image and never will. Running the new verifier against its
shape returns `REFUSE_INCOMPLETE_PRE`, and a regression test pins that.

> **A reconstructed pre-image agrees with whatever the release did**, so the oracle would confirm any
> release — including a leaking one. That is why the collector refuses after release rather than
> offering a best-effort mode, and why `docs/phase11p11-*` is not amended.

The P.11 sealed-document result remains what it was: a **diagnostic** PASS, not a canonical one.

---

## 5 · Scope

No migration. No production deployment. No RLS change. No parked feature work.
`docs/phase11p6-*` through `docs/phase11p11-*` are untouched.

The two new instruments are governed by `test/noProductionMutation.test.ts` from the day they were
written. They are audited under a **separately scoped** path allowlist — widening the shared one would
hand every existing instrument a table surface it has no reason to touch — plus an explicit assertion
that every table path is read with a GET, which a path prefix cannot express on its own.
