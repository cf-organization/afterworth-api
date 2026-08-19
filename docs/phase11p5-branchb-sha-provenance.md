# Phase 11-P.5 — the Branch B Session-2 SHA provenance addendum

```
FROZEN SESSION-1 CHECKPOINT:  UNCHANGED (sha256 2a0a0b92...24d4cb)
LEGACY SHA GATES:             SUPERSEDED_FOR_SESSION2 (exactly three, by name)
SESSION-2 PROVENANCE:         UNAMBIGUOUS — source-qualified
PRODUCTION MUTATIONS:         ZERO
BRANCH B:                     IN_FLIGHT — CHALLENGE_WINDOW
BRANCH B RELEASE:             NOT AUTHORIZED
```

This remediation replaces one uniform SHA comparison with a **source-qualified** provenance contract.
It adds files; it rewrites nothing. `docs/phase11p-branchb-session1-checkpoint.json` is historical
evidence and stays byte-for-byte as written.

---

## 1 · Why the legacy uniform equality was defective

`evaluateResume` compared three observed SHAs to three checkpoint SHAs with `===`, under the header
*"THE CODE UNDER TEST HAS NOT MOVED"*. Nothing in code, tests or docs ever said **where an observed
SHA is read from** — and that omission is the whole defect. A SHA proves nothing on its own; what it
proves depends entirely on its source.

Two failures followed, pointing in **opposite** directions, which is why neither widening nor
tightening the same rule could fix both.

### 1.1 · The API and mobile pins are structurally unsatisfiable

The checkpoint was added by API commit `9f06a86`, and pins `api_sha = 18ef102` — which is
`9f06a86^`. The artifact could not contain its own commit's SHA, so **committing it advanced main
past its own pin**. Mobile is identical: the pinned `8584324` is `58268bf^`.

> The only tree in which `api_sha_unchanged` is satisfiable is one that **does not contain the
> checkpoint being evaluated**.

Under every honest observation source — local HEAD, `origin/main`, deployed revision — both gates
refuse permanently, on evidence-only movement. That is a false refusal no observation can clear, and
waiting does not help: it is a fixed property of the artifact, not drift.

### 1.2 · The admin pin was stale at birth, and it fails OPEN

`admin_sha = fd7ef03` is the deliberately-stale **foreign local checkout**. It stopped being the
deployed admin revision at `2026-08-18T00:15Z` — roughly **28 hours before the checkpoint was
authored**. Admin production is `cd044fe`, and the two commits in between are exactly:

| Commit | Subject |
|---|---|
| `4611d37` | Phase 11-OC / Phase C — the console can tell an accepted notice from a legacy one |
| `cd044fe` | Phase 11-OC / Phase D — **the console reads the server's release authority instead of keeping its own clock** |

So an operator who observes the obvious thing — `git rev-parse HEAD` — gets a **green**
`admin_sha_unchanged` over a console two production deployments behind the one reviewer B will
actually use, with its release-authority surface rewritten in between. This is the same shape as the
Vault write gate: **fail-closed by coincidence is not fail-closed.**

---

## 2 · The operator ruling

`PHASE_11P5_SHA_PROVENANCE_ADDENDUM_V1`.

The legacy `api_sha` / `mobile_sha` / `admin_sha` fields are **historical authoring-provenance
facts**. They remain in the frozen checkpoint and are never rewritten. For Session 2 they are
`superseded_for_session2` — and **only those three comparisons**. Every other checkpoint and resume
gate remains authoritative and is retained verbatim.

---

## 3 · Session-2 provenance, by source

| Component | Revision | Source kind | Observation source |
|---|---|---|---|
| `api_branch_b_source` | `9f06a86` | `reviewed_revision` | exists in repo **and** in the lineage of `refs/heads/main` |
| `mobile_branch_b_source` | `58268bf` | `reviewed_revision` | exists in repo **and** in the lineage of `refs/heads/main` |
| `admin_console_production` | `cd044fe` | `production_deployment` | successful **Production** deployment metadata |
| `resume_instrument` | `7c7c25c` | `reviewed_revision` | exists in repo **and** in the lineage of `refs/heads/main` |

### 3.0 · A reviewed baseline is a claim about a COMMIT, not about a branch tip

**Proven by this remediation's own merge (Phase 11-P.5b).** The first cut pinned the reviewed
baseline `9f06a86` as a `source_revision` against `refs/heads/main`. Merging the remediation advanced
main to `7c7c25c`, and the gate went red — not because provenance had drifted, but because a
**reviewed baseline had been tied to a moving ref**. That is the same shape as the defect being
remediated, one level up. The architecture surfaced it instead of hiding it, which is exactly what
Stage 19 asked for.

So the two questions are given two kinds:

- **`reviewed_revision`** — the commit must still EXIST and still be IN THE LINEAGE. It was not
  force-pushed away, rewritten, or left behind on a parked branch. It does **not** move when main
  advances, so an unrelated merge cannot falsely refuse a drill.
- **`production_deployment`** — here the tip IS the fact, so the current successful Production
  deployment is required and nothing older will do.

Lineage is decided by `behind_by === 0` together with `status ∈ {ahead, identical}` — **never by the
status word alone**, because `diverged` also reports a positive `ahead_by` and would otherwise be
admitted (mutation M18).

### 3.1 · The API SHA is not the release door

**`api_branch_b_source` is source/instrument provenance only.** `authorize_release` appears solely
under `db/` — **no `api/` route invokes it** — so the release path is:

> admin console (Vercel, `cd044fe`) → PostgREST RPC → `authorize_release` (Postgres)

The Postgres tier is applied by manual SQL-bundle paste and **carries no git revision of any kind**.
There is deliberately no `API_RELEASE_DOOR_DEPLOYED_SHA`, because no such value exists. Release-door
integrity is proven **behaviourally**, by instruments that already exist:

- `scripts/verifyPhaseDDeployment.mjs` → `PHASE_D_DEPLOYED`
- `scripts/verifySourceDeploymentDrift.mjs` → `source_deployment_drift_clean`
- `verifyDeployedContracts` → `deployed_contracts_clean`
- the Branch-B sentinel and the standing fixture

Inventing a door SHA would be worse than having none: it would look like proof.

### 3.2 · Mobile has no deployed revision

No GitHub deployments exist for the mobile repo; `expo.updates` and `runtimeVersion` are both `null`.
There is no deployed binary or OTA revision to observe, and the addendum does not pretend otherwise.
`58268bf` is an **explicitly reviewed and pinned** evidence revision — accepted because it was
reviewed, *never* because a commit message looked harmless. Any other mobile revision, including a
later `main`, still refuses.

---

## 4 · Source kind is the containment mechanism

The closed vocabulary is what makes `fd7ef03` unrecoverable as authority:

| Kind | Expectable? | Observable? |
|---|---|---|
| `reviewed_revision` | yes | yes |
| `source_revision` | yes | yes |
| `production_deployment` | yes | yes |
| `local_checkout` | **NO** | yes |

`local_checkout` is **observable but never expectable**. A mis-wired collector that reads a working
tree must be able to *say so*, so the mismatch is refused by name — remove the kind and the same
mis-wiring simply reappears mislabelled as `source_revision`, which nothing could detect.

**Source kind is checked BEFORE the sha, and a mismatch is fatal even when the sha agrees.** That
ordering is the point: `cd044fe` read from a working tree is not the same fact as `cd044fe` read from
a successful Production deployment, and only the second is provenance.

A `production_deployment` observation additionally requires `environment = Production` **and**
`state = success`, as three independent facts. A successful Preview and a failed Production are
different mistakes and both refuse.

---

## 5 · The binding — how the frozen evidence stays immutable

The addendum carries `branch_b_checkpoint_sha256`, the digest of the checkpoint's **raw bytes**. The
Session-2 evaluator recomputes it and refuses on any mismatch. One edited byte of the checkpoint
turns every Session-2 gate red. That is what allows corrected semantics to be added without the
original evidence becoming editable — and it is proven by mutation M14, which rewrites the
checkpoint's `admin_sha` to the "correct" value and is detected.

---

## 6 · Supersession names exactly three ids

```
api_sha_unchanged   mobile_sha_unchanged   admin_sha_unchanged
```

Named in full, in code **and** in the artifact, and required to match exactly and in order. A
wildcard such as `/_sha_/` selects the same three today and would silently swallow any future gate
whose id contains `_sha_` — plausibly one added to close a hole. A control asserts that a new gate
named `pre_release_payload_sha_verified` is **retained**, so the wildcard form is detected (M15).

A superseded id that is absent from the legacy evaluator is a **contract break**, not a no-op:
`supersession_targets_exist` refuses rather than dropping nothing while everyone believes a gate was
replaced.

`evaluateResume` is **untouched** and is delegated to, so every non-SHA gate keeps its exact legacy
behaviour because it *is* the legacy behaviour. There is no second copy to drift. Retained: **20**.
Superseded: **3**. Legacy total: **23**.

---

## 7 · The instrument revision is a separate fact

`resume_instrument` is a first-class field, distinct from `api_branch_b_source`. It was **null** in
the first cut for an honest reason: the commit carrying the evaluator did not exist while the
artifact was being written, and inventing a value would have reproduced the exact self-referential
defect being remediated. **NULL refuses**, which made pinning it after merge mandatory rather than
optional.

It is now pinned to `7c7c25c` — the merged Phase 11-P.5 remediation. The two fields hold **different
revisions**, which is the whole point: `9f06a86` is the reviewed Branch-B evidence baseline and
`7c7c25c` is the reviewed instrument. Overloading one onto the other is how the checkpoint's
`api_sha` came to mean neither thing, and mutation M19 collapses them and is detected.

---

## 8 · Unavailable is never "unchanged"

Every collector returns `null` on failure, and a null observation fails its gate by name with
`observation_missing`. There is no degraded mode in which a missing observation reads as agreement.
Proven at the orchestrator level (M16), not only at the individual collectors — the substitution
would have been added one level up, where every collector-level test stays green.

---

## 9 · Running it

```
node scripts/branchBSession2Preflight.mjs                        # provenance only, read-only
node scripts/branchBSession2Preflight.mjs --observed=<file.json> # full resume evaluation
```

Exit 0 provenance green · 1 a provenance gate refused · 2 could not verify.

The **provenance verdict** and the **Session-2 resume verdict** are printed separately and neither
may stand in for the other. A green provenance result before the clock proves the remediation is
ready without opening Session 2 — the resume verdict still refuses, because production state is
unobserved and an unobserved fact is a failed gate.

The script GETs `gh api` and reads git refs. It never calls `authorize_release`, never challenges or
halts, never drains or reissues, and never touches `AW_ADMIN_TEST_B`.
