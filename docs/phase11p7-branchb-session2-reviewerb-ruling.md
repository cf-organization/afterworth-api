# Phase 11-P.7 — the Session-2 reviewer-B introduction ruling

```
PRE-B PREFLIGHT RESULT:       25/28 PASS · REFUSE_RESUME · PRESERVED, NOT REINTERPRETED
PROTOCOL CIRCULARITY:         FOUND — three gates need facts reviewer B alone can produce
RULING:                       PHASE_11P7_SESSION2_REVIEWER_B_INTRODUCTION_V1
AUTHORIZES:                   reviewer-B AUTHENTICATION ONLY
DOES NOT AUTHORIZE:           release, or the irreversible release writer
RELEASE BOUNDARY:             unchanged — 28/28 PASS plus canonical RESUME
```

This ruling adds an artifact. It rewrites nothing.
`docs/phase11p6-branchb-session2-preflight/` is historical evidence and stays byte-for-byte as
written; its `MANIFEST.sha256` is quoted here so the linkage is checkable rather than asserted.

---

## 1 · What the pre-B preflight actually proved

Every gate that could be evaluated without reviewer B was green: the seven-day window elapsed, the
sentinel passed, the Session-1 checkpoint cold-rehydrated and stayed hash-bound to the addendum,
T2 was `T2_DELIVERED`, the standing fixture read 23/23 with a free lock, Phase C and Phase D were
deployed, source/deployment drift was zero, and release authority read `ready=true`.

Three gates refused:

```
observed_reviewers_distinct   decider=<reviewer-A uid>  acting=undefined
acting_admin_is_reviewer_b    acting=undefined
acting_admin_has_aal2         aal=undefined
```

**The instrument was correct.** `acting_release_admin_uid` and `acting_admin_aal` were absent, and
an unobserved fact is a failed gate, never a skipped one.

---

## 2 · Why the old ordering could never terminate

The protocol said:

```
28/28  →  RESUME  →  introduce AW_ADMIN_TEST_B
```

But `acting_release_admin_uid` and `acting_admin_aal` are facts about **the reviewer-B session that
performs the release**. `db/functions/operator_console.sql` projects `release.reviewer_a` (the case
decider) and `release.authorized` (null until a release exists). It projects **no acting release
admin**, because before reviewer B acts there is no such person to project.

So the three gates cannot pass until B is introduced, and B could not be introduced until the three
gates passed. That is a cycle in the protocol, not a defect in the instrument — and
`branchBSession2Preflight.mjs` says as much in its own header: the production-state gates "need a
live authenticated read that belongs to the Session-2 operator."

**The narrowest cut that breaks the cycle** is to authorize reviewer-B *authentication* — and
nothing else — as its own boundary, ahead of the release boundary.

---

## 3 · Two traps this ruling records so they are not re-encountered

### 3.1 · Exit code 0 is not RESUME

`branchBSession2Preflight.mjs` scores **only** the six provenance gates and two instrument gates in
its exit code, deliberately and documented. The pre-B run exited **0** while printing
`SESSION-2 VERDICT : REFUSE_RESUME`. A caller gating on `$?` would have read release clearance out of
a refusal.

**The gate set plus the printed canonical verdict is the authority. The exit code is not.**

### 3.2 · `reviewer_identities_not_swapped` passed vacuously

Its predicate is a negation:

```
!(case_decided_by === reviewer_b_uid && acting_release_admin_uid === reviewer_a_uid)
```

With `acting_release_admin_uid` absent the conjunction is false, so the negation is true and the gate
passes having compared nothing. **That pre-B pass is not evidence** and must not be carried forward.
It is re-evaluated in the reviewer-B run with a real acting identity present, which is the only state
in which it can fail.

This is the repository's own transformation-test rule applied to a gate: a control that cannot fail
is not a control.

---

## 4 · The ruling

> The pre-B Session-2 preflight result of `25/28 PASS / REFUSE_RESUME` is preserved exactly as
> observed and is not equivalent to `RESUME`.
>
> All production/provenance/release-readiness gates available before reviewer-B authentication were
> green.
>
> The only refusing gates were `observed_reviewers_distinct`, `acting_admin_is_reviewer_b`, and
> `acting_admin_has_aal2`.
>
> Those three predicates require facts belonging to the live authenticated reviewer-B Session-2
> operator and therefore cannot become evaluable/passing while `AW_ADMIN_TEST_B` remains unused.
>
> This ruling authorizes introducing `AW_ADMIN_TEST_B` solely for establishing the reviewer-B
> Session-2 authenticated context required to evaluate those three gates and rerun the canonical
> preflight.
>
> This ruling does NOT authorize release.
>
> This ruling does NOT authorize invocation of the irreversible release writer.
>
> The release boundary remains `28/28 PASS` plus canonical verdict `RESUME` from a fresh
> authenticated reviewer-B Session-2 preflight.

---

## 5 · What this ruling is careful NOT to do

It does not waive a gate. It does not convert `25/28` into `28/28`. It does not convert the earlier
`REFUSE_RESUME` into `RESUME`. It does not touch the instrument, the checkpoint, the addendum, or any
prior observation.

The canonical instrument must still evaluate the **real** reviewer-B facts and independently produce
`28/28 PASS` and `RESUME`. If it does not, the workflow halts.

**Fabrication is the specific failure this ruling exists to avoid.** The two missing fields could
have been typed by hand from the checkpoint's `reviewer_b_uid` and the string `aal2`, and every gate
would have gone green against values no session ever produced. That is why the ruling authorizes an
*authentication*, not an *observation* — the fields must be read from the session, and the session
has to exist.

---

## 6 · Provenance

| Artifact | SHA-256 |
|---|---|
| `docs/phase11p6-branchb-session2-preflight/MANIFEST.sha256` | `689cce239874cfb399651137340f7969f15c0faf6f4a5a7269b1dd56aba0eefc` |
| `…/03-session2-observation.json` | `b0bff673cff4a4af16d858ff6a3595f0ac9d83876da980a2bcb957670d7398c1` |
| `…/12-preflight-28-gate.txt` | `bf04c20746f7dc7697f0c3cb09fc6cd9f51ce4d6dd3c9cf636065d5607b4e236` |

Machine-readable ruling: `docs/phase11p7-branchb-session2-reviewerb-ruling.json`.
Reviewer-B re-preflight evidence: `docs/phase11p7-branchb-session2-reviewerb-repreflight/`.

---

## 7 · The boundary after this one

`RESUME` means the next boundary may be *considered*. It is not authorization to execute it.
The irreversible release requires separate explicit authorization, against a synthetic estate, with
reviewer B acting and reviewer A already having decided.
