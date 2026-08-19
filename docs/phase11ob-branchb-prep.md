# Phase 11-OB PREP — Branch B drill instrumentation

**This is not Branch B.** No identity, estate, invitation, membership, designation, grant,
verification case or notification was created. No production mutation RPC was called. No drain was
triggered. `CRON_SECRET` was never read.

```
BRANCH B:                        NOT STARTED
BRANCH A:                        BRANCH_A_FAILED
BRANCH A T2:                     awaiting the 2026-08-16T04:00Z drain opportunity
PRODUCTION MUTATIONS THIS SLICE: ZERO
```

Repo SHAs this slice was built from — `afterworth-api` `e17f214`, `afterworth-mobile` `b7d8605`,
`afterworth-admin` `fd7ef03` (untouched).

---

## 1 · What the owner-notice channel can and cannot prove (Stage 1)

Read from `db/functions/outbox_safety.sql`, `db/functions/operator_console.sql`,
`lib/ownerNotices/drain.ts` and `lib/email/resendProvider.ts`.

| Required distinction | Observable? | Evidence |
|---|---|---|
| QUEUED | yes | `owner_notice_outbox.status = 'queued'` |
| CLAIMED / PROCESSING | yes | `status = 'processing'`; `claim_owner_notices` also increments `attempts` |
| PROVIDER_ACCEPTED | yes | `status = 'dispatched'` + `dispatched_at` |
| **DELIVERED** | **NO** | — |
| FAILED | yes | `status = 'failedPermanent'` + `failure_class` |
| STALE | yes | `failure_class = 'stale_beyond_age_gate'` |

**Delivery is not derivable from backend state, and cannot be made so without a schema change.**
`record_owner_notice_outcome` deliberately stores no provider message id — its own comment gives the
reason: "A provider handle is a lookup key into a third party's log of a message addressed to a
living owner." There is no delivery webhook, no bounce table and no `delivered_at` column.
`resendProvider.ts` states the same rule from the other end: `providerAccepted` "is not delivered,
received, opened, or viewed, and nothing downstream is allowed to rename it."

So `T2_DELIVERED` is reachable only from an explicit human observation supplied out of band, and even
then only when the backend independently agrees the message reached a provider.

**There is no `claimed_at`.** The claim routine stamps no timestamp. The observer reports
`claimed_at: null` with that reason attached rather than substituting a nearby value.

**The authoritative read surface** is `admin_get_death_verification_case(p_case)` — `stable`,
admin + AAL2 gated, and its `owner_notice` projection deliberately omits `recipient`.
`owner_notice_census()` is counts-only and cannot answer about one row.

---

## 2 · The instruments (Stages 2–10, 13)

| # | Instrument | Kind | Proof |
|---|---|---|---|
| 1 | `scripts/observeOwnerNoticeDelivery.mjs` | read-only CLI | T2 observation through the operator door |
| 2 | `scripts/lib/t2Classification.mjs` | pure | the six-verdict vocabulary; `dispatched ≠ delivered` |
| 3 | `scripts/branchBSentinel.mjs` | read-only CLI | standing fixture + Branch B, `ABSENT` is a first-class answer |
| 4 | `scripts/lib/branchBSentinel.mjs` | pure | classification; a hole is never a null |
| 5 | `scripts/lib/branchBBaseline.mjs` | pure | closed-allowlist baseline + SHA-256 |
| 6 | `scripts/lib/branchBCheckpoint.mjs` | pure | strict decoder + the 22-gate resume validator |
| 7 | `scripts/lib/disclosureOracle.mjs` | pure | pre/post release information equivalence |
| 8 | `scripts/lib/canonicalJson.mjs` | pure | one spelling per value, so a digest means something |
| 9 | `scripts/lib/readOnlyAudit.mjs` | rule declaration | the no-mutation rule set |

### The drain opportunity is read from `vercel.json`, never remembered

"queued, `attempts = 0`" is the correct resting state *before* the scheduled drain and a broken
safety channel *after* it — the same row, classified oppositely by nothing but the clock. The
schedule is parsed from `crons[/api/claims/drain_outboxes]`; an unparseable one is a refusal, not a
default. The clock is injected in every test, so no assertion depends on the day it runs.

### The observer cannot mutate, and that is checked rather than asserted

`test/noProductionMutation.test.ts` strips comments (keeping strings — an RPC name reaches the
network *as a string literal*) and fails on any mutation routine name, any secret token
(`CRON_SECRET`, `SUPABASE_SECRET_KEY`, …), any `PATCH`/`PUT`/`DELETE`, any absolute URL, and any
network path outside `/auth/v1/**` and `/rest/v1/rpc/**`.

> **A defect the audit had, and its regression control.** The first tokenizer tracked quotes only.
> `…replace(/^["']|["']$/g, '')` — one ordinary line of env parsing in the observer — puts a `'` and
> a `"` *inside a regex*. The scanner read them as string delimiters, and every quote in the next 180
> lines paired one off: comments were kept as code and strings skipped as comments. It surfaced as
> two false positives, which is the lucky direction; the same desynchronisation hides a real call
> just as easily. The tokenizer now distinguishes division from a regex the way a parser does, and
> that exact line is pinned as a test control.

---

## 3 · The future Branch B grant — the smallest non-vacuous object (Stage 11)

**Nothing below was created.** This is the sequence a future authorized drill would run.

### Why a per-document grant, and not an asset

`release_condition_satisfied` gates the asset-value surfaces under `legacy_immediate_only`, where
**`immediately` is the only satisfiable condition at every lifecycle state**. An asset grant
therefore cannot demonstrate a death-conditioned disclosure at all. Documents run under `standard`,
where `after_verified_death` is satisfied **only** at lifecycle `released`. That is the property
Branch B exists to prove, so the object must be a document.

### Why it needs no beneficiary membership

`create_document_grant`'s own header: *"Pre-granting is allowed: the RPC does NOT require the grantee
to be an existing member."* Access is re-evaluated at read against `auth.uid()`.

`grantee_role` on the grant row is a **ceiling parameter**, not a membership and not an identity.
`document_grantable(role, sensitivity)` uses it to decide what sensitivities the grant may reach. The
`AW_BRANCHB_FID` identity remains designation-only — no membership row, no beneficiary row, no
delegate role — exactly like the standing `AW_FIDUCIARY` fixture.

> Per the identity-authority rule: this grant does **not** make the holder a beneficiary, and nothing
> in the drill may read `grantee_role = 'beneficiary'` as a statement about who they are.

### The two traps

1. **`create_vault_document` defaults `p_sensitivity` to `'sealed'`.** `document_grantable` returns
   `false` for `sealed` under *every* role — so a document created with the default is invisible
   after release too, and the drill would record a correct release as a failed disclosure. The
   sensitivity must be passed explicitly as `low` or `medium`.
2. **`visibility_tier` must not be `'hidden'`.** The ladder returns `false` at the tier check, before
   the release predicate is ever consulted. `full_detail` is the tier to use.

### The sequence (owner's own product path, in order)

| # | Actor | Call | Notes |
|---|---|---|---|
| 1 | `AW_BRANCHB_OWNER` | `create_vault_document(estate, doc_id, storage_path, title, subtype, 'low')` | subtype resolved through `test/fixtures/canonicalDocumentTaxonomy.ts`; **never a literal** |
| 2 | `AW_BRANCHB_OWNER` | `create_vault_document(…, 'sealed')` ×2 | the unrelated world that must stay hidden throughout |
| 3 | `AW_BRANCHB_OWNER` | `create_document_grant(estate, fid_uid, 'beneficiary', open_doc, 'full_detail', 'immediately')` | an already-visible item, so a hide-everything gate is observably wrong |
| 4 | `AW_BRANCHB_OWNER` | `create_document_grant(estate, fid_uid, 'beneficiary', doc_id, 'full_detail', 'after_verified_death')` | **the object under test** |

Step 3 is not optional. Against a world with nothing else in it, a gate that hides everything and a
gate that exposes everything both look correct for at least one phase — which is why
`evaluateDisclosureEquivalence` refuses such a world with `UNVERIFIABLE` rather than passing it.

### The expected oracle observations

| Phase | Lifecycle | Fiduciary sees | Owner sees |
|---|---|---|---|
| pre | `challenge_window` | the `immediately` doc only | everything |
| post | `released` | the `immediately` doc **and** the death-conditioned doc | everything |
| both | — | the two sealed docs: **never** | — |

`release_condition_satisfied('after_verified_death', …, 'standard', 'challenge_window')` is `false`
and `(…, 'released')` is `true`. `death_verified` and `challenge_halted` satisfy nothing.

---

## 4 · Resume gates (Stages 7–9)

`evaluateResume` emits 22 gates and **evaluates every one of them** — no short-circuit, because a
resume that fails four gates and reports one sends the operator round the loop four times. An
unobserved fact is a **failed** gate, never a skipped one.

> **★ SUPERSEDED BY PHASE D (11-OC), CORRECTED IN 11-P.** The paragraph below was written against the
> Phase C door and said the clock anchor was `owner_notified_at`. **It is not, and has not been since
> Phase D deployed.** The deployed authority is
> `now() > notice_accepted_at + challenge_window_duration()`, strictly — anchored on the instant a
> provider ACCEPTED the notice, not on the instant it was queued. The two differ by however long the
> notice sits in the outbox, which for Branch B was over 22 hours, and on Branch A was **two days**.
>
> The formula is retained here only as history. `scripts/lib/branchBCheckpoint.mjs` has always been
> correct and refuses a `coalesce(notice_accepted_at, owner_notified_at)` fallback by construction;
> the stale text was in this prose alone. Anyone reading this section for instruction must use the
> acceptance anchor.

The window gate is **strict**: `now > release_eligible_at`, matching `authorize_release`, which uses
`now() > notice_accepted_at + challenge_window_duration()`. At the exact boundary instant the release
door refuses and the owner's challenge still wins. `recommended_resume_after` adds a five-minute
margin so the resuming session does not race a door it knows is shut — **harness scheduling only; the
seven-day policy is untouched.**

### The three SHA gates are SUPERSEDED for Session 2 (Phase 11-P.5)

> **★ `api_sha_unchanged`, `mobile_sha_unchanged` and `admin_sha_unchanged` are no longer the
> Session-2 authority.** They compared three observed SHAs to three checkpoint SHAs with a uniform
> `===` and never said WHERE an observed SHA is read from. That omission failed in both directions at
> once:
>
> - **False refusal.** The checkpoint pins `api_sha = 9f06a86^` and `mobile_sha = 58268bf^` — the
>   parents of the commits that created it. Committing the artifact advanced main past its own pin,
>   so the only tree satisfying the gate is one that does not contain the checkpoint.
> - **False admission.** `admin_sha = fd7ef03` is the stale FOREIGN LOCAL CHECKOUT, already
>   superseded in production ~28 hours before the checkpoint was authored. Observing
>   `git rev-parse HEAD` returns a GREEN gate over a console two production deployments behind the
>   one reviewer B will use — with the Phase C and Phase D release-authority rework in between.
>
> The fields remain in the frozen checkpoint as **historical authoring provenance** and are never
> rewritten. Session 2 evaluates source-qualified provenance instead:
> `docs/phase11p5-branchb-session15-provenance.json`, decoded and gated by
> `scripts/lib/branchBProvenance.mjs`, bound to the checkpoint by SHA-256.
>
> | Component | Revision | Source of truth |
> |---|---|---|
> | API Branch-B baseline | `9f06a86` | reviewed revision, in the lineage of `main` — **NOT the release door** |
> | Mobile Branch-B baseline | `58268bf` | reviewed revision, in the lineage of `main` — no deployed mobile revision exists |
> | Admin console | `cd044fe` | successful **Production** deployment metadata, never a local checkout |
> | Session-2 resume instrument | `7c7c25c` | reviewed revision, held separately from the baseline |
>
> The Postgres release door carries no git revision; its integrity is proven behaviourally by
> `verifyPhaseDDeployment`, source/deployment drift, the Branch-B sentinel and the standing fixture.
> Rationale and mutation evidence: `docs/phase11p5-branchb-sha-provenance.md`.

```
TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE
```

`AW_ADMIN_TEST_A` is reviewer A (the case decider); `AW_ADMIN_TEST_B` is reviewer B (the release
authorizer). The guard refuses on the same uid in both seats, on **swapped** identities (which pass
distinctness — hence a gate of their own), on an unexpected case decider, and on a session that is
not AAL2. Two accounts held by one person prove the mechanism distinguishes two identities and
nothing about independent human judgement.

---

## 5 · What still gates Branch B

| Gate | Status |
|---|---|
| Branch A T2 — owner email delivery | **NOT CLASSIFIED** — earliest drain opportunity 2026-08-16T04:00Z |
| Branch B authorization | **NOT GIVEN** |
| Branch B identities | **NOT CREATED** — `AW_BRANCHB_OWNER` / `AW_BRANCHB_FID` are catalogued as `planned` and their absence from the credential store is asserted by test |
| Branch B estate | **NOT PROVISIONED** — `branchBSentinel` reports `BRANCH_B_FIXTURE_ABSENT` |

**Next action:** run the T2 observation in the session that owns it, after the scheduled drain.

```
node scripts/observeOwnerNoticeDelivery.mjs --case=<branch-a-case-uuid>
```

Exit 0 means `T2_DELIVERED` and only that. Exit 1 is a definite verdict that does **not** clear the
gate. Exit 2 is `COULD NOT VERIFY`, which is a failure and never a pass.
