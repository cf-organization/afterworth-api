# Phase 11-OC · PHASE D — the release door is re-anchored on provider acceptance

**Status:** implemented and merged. **PRODUCTION DEPLOYMENT REQUIRED — not deployed.**
**Artifact:** `db/bundles/owner_notice_release_authority_bundle.sql`.
**R13:** RESOLVED (§7). **Branch B:** NOT STARTED — gate closed (§11).

```
PHASE A:   DEPLOYED_AND_VERIFIED
PHASE C:   DEPLOYED_AND_VERIFIED
PHASE D:   IMPLEMENTATION COMPLETE · DEPLOYMENT_REQUIRED
OB-2 PRODUCTION POLICY: NOT YET ACTIVE until Phase D is pasted
```

---

## 1 · WHAT WAS WRONG, IN TWO SENTENCES

`authorize_release` gated the irreversible `challenge_window → released` transition on an owner-notice
row for the **estate** with `status <> 'cancelled'` — a predicate nothing in production can falsify,
because `dispatch_owner_safety_notice` inserts that row in the same transaction as the transition and
no production path ever writes `'cancelled'`. And it measured the seven-day challenge window from
`owner_notified_at`, which is stamped when the row is **queued**, so the clock ran while the message
sat unsent and kept running after the provider rejected it outright.

The gate re-asserted its own precondition, and admitted `queued` (never sent), `processing` (never
settled), `outcomeUncertain` (unknown) and `failedPermanent` (definitively failed).

---

## 2 · WHAT REPLACES IT — one fact, four authorities, zero status strings

> A release may proceed only when the **current generation** of the **current case episode** carries
> `notice_accepted_at`, and `now() > that instant + challenge_window_duration()`, **strictly**.

| # | Authority | Mechanism | Decision |
|---|---|---|---|
| 1 | **Episode** | canonical current `verified` case re-resolved from the estate; caller's `p_case` compared against it | D3 |
| 2 | **Generation** | `superseded_by is null` — the partial-unique-indexed wall, never `max()` | D4 |
| 3 | **Acceptance** | `notice_accepted_at is not null` — no status participates | D1/D2 |
| 4 | **Clock** | strict `>` from the acceptance instant, no fallback to provenance | D5 |

All four live in **one** function, `owner_notice_release_authority(p_case) → jsonb`
(`db/functions/release_safety.sql`), which is `security definer`, `stable`, and revoked from every
client role.

### 2.1 · Provider accepted ≠ mailbox delivered

`notice_accepted_at` is written by exactly one branch of exactly one routine —
`record_owner_notice_outcome`, `providerAccepted` — and it means **the email provider accepted the
message for delivery**. It is *not* delivered, received, opened or read.

**Phase D protects on the strongest persisted provider fact this system currently has. It claims no
delivery attestation, and no console label, audit field or document may rename it.** The refusal code
is `notice_never_accepted` and deliberately **not** `notice_not_delivered`: mailbox delivery is not
known to this system, and naming it would be the product inventing the one fact this phase exists to
stop being invented. `RELEASE_REFUSAL_COPY` in the admin console is asserted free of the word
"delivered" by test.

### 2.2 · Why current-generation-only does not break monotonicity

`owner_notice_release_readiness_census` reads acceptance as an **existential over the whole episode**
and argues — correctly — that authority must be monotone: if issuing a re-notice could *remove*
release authority, an operator would hold a lever that suppresses a release. This function reads only
the current generation, which looks like it breaks that. It does not, and the reason is structural
rather than a promise:

- `record_owner_notice_outcome` no-ops on any row already `dispatched`, `outcomeUncertain`,
  `failedPermanent` or `cancelled`, so a settled row can never *gain* an acceptance stamp.
- `owner_notice_reissue_assessment` permits a re-notice **only** when the current generation is
  `failedPermanent`, `outcomeUncertain`, or `dispatched` with NULL acceptance — all settled, all
  NULL-acceptance at the instant of supersession. `queued` and `processing`, the only rows that can
  still gain acceptance, are refused and therefore never superseded.

So a superseded row carrying `notice_accepted_at` is **unreachable through the deployed doors**, the
two readings can differ only on a state the system cannot produce, and reading the current generation
costs no monotonicity. It is read strictly anyway, because D4 asks for the structural invariant rather
than for an argument that the loose one happens to be safe — and both migration 0060 §4.4 and suite
§12.5a construct that row **by hand** and prove it authorizes nothing, so the door's correctness does
not depend on two other routines never changing.

---

## 3 · WHAT DELIBERATELY DID NOT CHANGE

| Preserved | Why |
|---|---|
| the seven-day policy | `challenge_window_duration()` is untouched. Only the instant it counts *from* moved. |
| two-person rule + `release_authorizations` CHECK | Phase D **adds** owner-notice authority; it replaces no existing release guard. |
| reviewer_a derivation from the case decider | unchanged, and still refused *before* the clock. |
| `owner_notified_at` on the lifecycle row | kept as **provenance** and required at the door. Removing it would make one path easier, and Phase D makes no path easier. |
| refusal ORDER for every pre-existing sentinel | `invalid_release_state`, `owner_not_notified`, `no_verified_case`, `reviewer_a_unresolved`, `two_person_rule_violated` all still fire before any clock or notice question. |
| Phase C re-notice policy | unchanged. Its permitted and refused classes are exactly as deployed. |

### 3.1 · `begin_challenge_window` was corrected but NOT tightened (D7)

Its inert `status <> 'cancelled'` predicate is replaced by the fact it actually needs: **a committed
owner-safety email notice exists for the CURRENT CASE EPISODE** (`no_current_notice` otherwise).
Case-scoped, current-generation, and **without** `notice_accepted_at`.

Requiring acceptance there would read like consistency and is the inversion this phase refuses:
opening the window discloses nothing, the drain is asynchronous so the initial notice is still
`queued` at that instant, and gating the owner's **own protection** on an email provider would make
the protective act harder than the harmful one. Migration 0060 §2.2 asserts the absence; suite §1
observes the window opening on a `queued`, never-accepted notice.

---

## 4 · ONE AUTHORITY, THREE CONSUMERS

```
                    owner_notice_release_authority(case)
                    /                |                 \
        authorize_release   admin_get_death_...case   verifyPhaseDDeployment
           (the door)          (the projection)          (the verifier)
```

The projection does **no** clock arithmetic, no notice qualification and no episode matching of its
own — `window.release_eligible_at`, `window.elapsed` and the whole `release_authority` verdict come
from that single call. The console and the door cannot disagree, rather than merely being checked for
agreement. The admin console renders the verdict and **fails closed** when a pre-Phase-D server
projects none.

---

## 5 · THE LEGACY ROW, AND THE THREE-WAY AGREEMENT

For the exact production shape — current case, `challenge_window`, current generation, status
`dispatched`, `notice_accepted_at` NULL:

| Surface | Answer |
|---|---|
| `authorize_release` | **REFUSE** — `notice_never_accepted` |
| operator console | **REFUSE**, same code, and `release_eligible_at` renders NULL rather than a date derived from provenance |
| Phase C | **RE-NOTICE AVAILABLE**, `reissue_reason = legacy_no_acceptance_record` |

This agreement is load-bearing in both directions. A door that refuses while the console offers the
control trains operators to ignore errors; a door that refuses while Phase C **also** refuses leaves
an estate permanently unreleasable with no recovery but hand-written SQL against a safety table.
Proven together in suite §12.4. **No manual SQL repair is required, or permitted.**

---

## 6 · EVIDENCE

| Instrument | Result |
|---|---|
| SQL authorization suite (fresh replay, ephemeral Docker Postgres) | **466 assertions**, exit 0 (baseline before Phase D: 451) |
| migration 0060 §4 — behavioural proof, in-transaction, provably rolled back | prior-case acceptance REFUSED · superseded acceptance REFUSED · NULL acceptance REFUSED despite 60-day-old provenance · exact boundary REFUSED · +1µs ADMITTED on the current generation · `release_eligible_at = notice_accepted_at + window` and **not** `owner_notified_at + window` |
| suite §12 — invariants A–J | all green (§12.1–§12.9) |
| vitest (api) | 646 passed |
| admin console | 105 passed · typecheck clean · lint clean |

### 6.2 · The verifier's own summary is now a tested surface

`verifyPhaseDDeployment.mjs` shipped printing `PROVED: the Phase D release authority is deployed`
**unconditionally** — so its first production run, whose verdict was correctly
`PHASE_C_STILL_ACTIVE` with exit 1, asserted the opposite three lines above that verdict. The checks
were right; the summary contradicted them, and the summary is what a human carries away.

It was **untestable by construction**: the wording lived inline in `main()`, which cannot run without
a live AAL2 session, so no test and no mutation could reach it. The fix is therefore the seam as much
as the conditional — `scripts/lib/phaseDVerdictProse.mjs` derives verdict, exit code and prose from
one call, and `test/phaseDVerdictProse.test.ts` proves *prose claims deployment ⟺ phase is deployed
and nothing failed* across every combination. Six mutations pin it, including the defect exactly as
it shipped and its mirror (a clean deployed run reporting Phase C).

Fixing it also exposed a gap in the mutation harness: reachability was asked only as "does the
mutated text reach the DATABASE", which is false for a spec-driven mutation on a JS module. It is now
asked per route.

### 6.1 · The transformation is observable, not assumed

The §1 happy path ages `owner_notified_at` to **eight days** — exactly what the pre-Phase-D suite did
to release that estate — and then requires the door to still refuse, because the acceptance fact is
seconds old. §12 goes further and ages provenance **30 days past the window** for its entire length.
A door still reading provenance admits loudly in both. Without this the cutover would be untested on
the happy path: ageing both fields together, the obvious edit, passes identically with the anchor
moved and with it left alone.

---

## 7 · R13 — RESOLVED

### 7.1 · The census was re-enumerated, and it was not seven

The Stage-3 design listed **7** pinning sites. Re-measuring found **9 in-repo guards plus 3
test-source pins**, because 0058 and 0059 were written *after* that census and each added its own
inversion guard, and Phase A added a fifth mutation anchor.

| # | Site | What it asserted | Why Phase D invalidates it | Resolution |
|---|---|---|---|---|
| 1 | `0056` `begin_challenge_window` | prosrc contains `status <> 'cancelled'` | D7 replaces that wording | supersession disjunction: OB-1 predicate **or** OB-2 episode scope, never neither/both |
| 2 | `0056` `authorize_release` | same | cutover removes it | disjunction: OB-1 predicate **or** OB-2 acceptance authority |
| 3 | `0057` `authorize_release` | prosrc contains `o.status <> 'cancelled'` | cutover removes it | same disjunction |
| 4 | `0058` §5.4 | old text present **and** `notice_accepted_at` absent | both flip | **catalog-decided posture**: matches whether 0060 is applied |
| 5 | `0059` §3.3 | same | both flip | same catalog-decided posture |
| 6 | mutation `p11e-release-before-window-elapses` | anchor spans the clock | clock moved out of the routine | retargeted to the authority |
| 7 | mutation `p11e-challenge-loses-the-tie` | anchor spans the clock | same | retargeted to the authority |
| 8 | mutation `p11e-release-without-owner-notice` | anchor spans the predicate | predicate gone | retargeted to the surviving provenance guard |
| 9 | mutation `p11f-release-skips-dispatch-check` | anchor spans the predicate | predicate gone | retargeted to dropping the authority consultation |
| 10 | mutation `p11oc-phase-a-changes-the-release-door` *(missed by the original census)* | anchor is the predicate line | predicate gone | retargeted to the mirror-image hazard: authority deployed, door quietly reverted |
| 11 | `deathVerificationFoundation.test.ts` | `now() > v_row.owner_notified_at + v_duration` | expression moved | re-pinned at the authority **plus** a new assertion that the door holds no second clock |
| 12 | `operatorProjectionDisclosure.test.ts` | projection carries a faithful copy of the door's comparison | there is no longer a copy | re-pinned as the **absence** of local arithmetic |
| 13 | suite §7 | deployed body carries the old predicate | cutover removes it | catalog-decided posture, as 4/5 |

### 7.2 · The amendments are strictly STRONGER than what they replaced

Each historical guard was amended **in its assertion layer only** — zero DDL changed in any of them,
under an explicit supersession banner naming migration 0060.

- The originals could be satisfied **only** by the old literal and **could not fail on the absence of
  both** predicates. The amendments cannot pass on absence: delete the guard with nothing replacing
  it and they still raise.
- They additionally catch a **half-cutover** (both postures present at once), which the originals
  could not express.
- Each OB-2 branch requires `to_regprocedure('public.owner_notice_release_authority(uuid)')` — a
  **catalog** fact no prose can supply.

### 7.3 · Comments are stripped before matching, and that closed the refused "fix" for good

`docs/phase11oc-release-acceptance-authority.md` §7.4 records *"plant the literal in a comment"* as
the worst available R13 option, refused because `prosrc` includes comments. It was refused as a
matter of discipline; it is now **unavailable**. Every amended guard strips `--` comments before
matching.

**This was found by execution, in both directions, on the first Phase D replay.** The `0060` guard
asserting `begin_challenge_window` does *not* require acceptance failed against a body that does not
require it and never did — the routine's own comment explaining that it deliberately does not gate on
acceptance was enough to fail an absence test. The same trap fired on `authorize_release`, whose Phase
D banner quotes the superseded predicate in order to state that it is gone.

**String literals are deliberately NOT stripped.** The evidence class these matchers exist to find
lives inside quoted SQL — `status <> 'cancelled'` *is* a string literal in the predicate, and every
refusal sentinel is a literal in a `raise`. Stripping them would erase exactly what is being looked
for. Comments must go; strings must stay. Each site carries a non-vacuity control (the stripped body
must still contain recognisable code), and 0060 §2 carries a positive control proving the stripper
removes commented text and preserves code string literals.

### 7.4 · The replay instruments are themselves mutation-tested

- `p11ocd-r13-amendment-reverted-to-the-old-pin` reverts 0057 to its original unconditional pin. A
  clean replay **must** fail — which is the evidence that the guard is genuinely reached, can still
  fail, and that the suite passes because of the supersession rather than because anybody taught the
  harness to look away.
- `p11ocd-r13-comment-stripping-removed` deletes the stripping step. The guard then sees both postures
  in the Phase D banner's prose and fires its half-cutover branch on a perfectly correct tree.

No decorative literal was planted, no guard was deleted, no check was weakened to something every
implementation satisfies, and the harness was not taught to ignore failure.

---

## 8 · DEPLOYMENT

**One artifact, one transaction, pure SQL, no psql meta-commands:**
`db/bundles/owner_notice_release_authority_bundle.sql`.

Part order is **inverted** relative to every earlier phase, and that is required rather than
stylistic. Phase D contains **no DDL** — 0058 added every column, 0059 added the episode wall — so its
migration is an *assertion* artifact and every assertion inspects the function bodies. A migration
cannot certify a cutover that has not been pasted yet.

1. `db/functions/release_safety.sql` — the authority, plus both doors that consume it
2. `db/functions/operator_console.sql` — the projection reading the same authority
3. `db/migrations/0060_20260817_owner_notice_release_authority.sql` — certification, behavioural
   proof, R13 re-proof from the catalog side, cutover census

The R13 amendments to 0056–0059 ship in the four bundles that already carry those migrations, all of
which were regenerated in this commit. 0060 §5 covers the gap from the other side: at Phase D paste
time it asserts no release-path routine still demands the superseded literal.

### 8.0 · The first production paste ABORTED, and why that is recorded here

```
0060 FAILED: the behavioural self-check could not run:
null value in column "id" of relation "users" violates not-null constraint (23502)
```

§4 built a synthetic fixture with `insert into auth.users default values`. That works **only** against
the test harness: `db/tests/preamble_real_auth.sql` defines a simplified `auth.users` with
`id uuid primary key default gen_random_uuid()`, and real Supabase has **no default** on that column —
GoTrue supplies the id. The self-check had therefore only ever been exercised against a **fake
boundary that was more permissive than the real one**. It is this repository's own recorded failure
class — *"a dependency-injection seam is not tested if every test replaces the production default"* —
with the substitution one layer down: the schema under test was the harness's, not the product's, and
nothing compared them.

**The fail-closed design held, and that is the one good thing to record.** The artifact is a single
transaction, so the abort deployed nothing, applied no half-cutover, and left no synthetic row
anywhere. A migration that had continued past a failed self-check would have shipped an uncertified
cutover instead.

**The replacement writes nothing at all.** A production migration has no business creating estates,
cases or owner notices in safety tables — not transiently, and not attached to a real person's
account, which reusing an existing `auth.users` row would have required. §4 now proves the authority
by *running* it, with zero writes:

- **§4.1** fail-closed probes on a NULL case and an unknown case id — a real call, so a body that is
  syntactically present but broken raises here rather than passing a text match;
- **§4.2–§4.3** the acceptance and anchor invariants evaluated over **every case the database
  actually holds** — real production rows, which no synthetic fixture can imitate;
- **§4.4** reports `SKIPPED-VACUOUS` out loud when the database holds no cases, because a green check
  over zero rows is not a pass.

The exhaustive A–J matrix stays where it can be built safely:
`db/tests/release_safety_authorization.sql` §12.1–§12.11, against an ephemeral Postgres where
fabricating an identity is legitimate. **Build type follows evidence type** — paste time gets the
evidence a paste can safely produce, and the suite gets the rest.

Two further instruments came out of it. `test/migrationRuntimeFidelity.test.ts` forbids any pasted
artifact from writing to a Supabase-managed table (comments stripped, with positive controls in both
directions, and `db/tests/*` deliberately out of scope). And the builder's positive control — which
required the now-deleted fixture sentinel — is retargeted to a token of the block that actually
ships, after it correctly refused the stale input and a `&& echo "rebuilt"` wrapper reported success
by never seeing the exit code.

### 8.1 · Self-checks that abort the transaction

Authority exists · SECURITY DEFINER · STABLE · INTERNAL (no client EXECUTE) · door consumes it · old
predicate absent · clock no longer anchored on provenance · strict `>` retained · episode binding ·
current-generation binding · prior and superseded rows cannot satisfy authority (**by execution**) ·
`begin_challenge_window` does **not** require acceptance · projection uses the canonical authority ·
Phase C remedy deployed and gated · `release_estate` absent · `estate_release_state` locked ·
two-person CHECK survives.

The behavioural block (§4) writes its fixture inside a plpgsql exception block ended by a sentinel
`raise`, so Postgres rolls it back **unconditionally on every path** — success, assertion failure, or
unexpected error. §4.9 re-counts `auth.users`, `estates`, `owner_notice_outbox` and
`death_verification_cases` after the rollback and fails if a single synthetic row survived. This
matters because the block is pasted into **production** and creates rows in safety tables; "we
remember to delete them" is not good enough.

### 8.2 · Rollback

Rolling Phase D back restores a predicate that admits `queued` and `failedPermanent`. It is possible
and it is a **safety regression**, so it is a decision, not a reflex. Phase A and Phase C are additive
and remain correct either way.

### 8.3 · Post-deployment verification

`node scripts/verifyPhaseDDeployment.mjs` — read-only, never names a writer, refuses a service-role
key, and distinguishes `PHASE_D_DEPLOYED` from `PHASE_C_STILL_ACTIVE`. Its decisive signal is
arithmetic rather than nominal: a Phase C server computes `release_eligible_at` from
`owner_notified_at`, which is never null on a dispatched case, so a **NULL** there on a case carrying
a dispatch timestamp is proof the anchor changed.

---

## 9 · SILENT DEGRADATION AND OPERATOR COPY

The console owns the sentence; the server owns the rule. `notice_never_accepted`,
`superseded_by`, `generation` and `release_authority` are internal vocabulary and do not render.
Operator copy describes **impact and next action**:

> "The email provider has not accepted the owner safety notice for this case, so there is no record
> that the warning was ever sent. Re-send the notice and wait for the challenge window to run from
> the point the provider accepts it."

The console label `Owner notified at` was **relabelled `Notice dispatch started`**: it is stamped when
the outbox row is queued, before any worker has run, and the old label claimed more than it knew.

---

## 10 · WHAT IS NOT PROVED

- **That a release succeeds in production.** Executing one would irreversibly disclose an estate.
  That is not a check; it is the act itself. `PRODUCTION_RUNTIME_PROOF_PENDING`.
- **That an owner received anything.** Provider acceptance is the strongest fact available; delivery
  is not observed at any layer.

---

## 11 · BRANCH B

**NOT STARTED — GATE CLOSED.** Phase D must first be implemented, merged, manually deployed and
verified. Only then may a separate decision open Branch B. The real seven-day window remains required.

**Branch-B prerequisite — RESOLVED.** `scripts/lib/branchBCheckpoint.mjs` carried
`release_eligible_at == owner_notified_at + challenge_window_duration_seconds`, the pre-Phase-D
anchor. A harness computing a resume time from provenance wakes the second session of a seven-day
drill up to the full provider lag EARLY, and the correct refusal it then meets reads as a product
defect rather than a harness one. It is now re-anchored on `notice_accepted_at`:

- `notice_accepted_at` is a first-class checkpoint field, **nullable** — NULL is the honest record of
  a notice the provider has not accepted, which a live drill legitimately reaches while the drain is
  still asynchronous. A non-nullable field would have forced the writer to invent one, and every
  value it invented would be a fabricated provider acceptance on a safety notice.
- `release_eligible_at` and `recommended_resume_after` are **paired** with it and NULL when it is.
  There is no fallback: `deriveWindowInstants` has no provenance parameter to fall back *to*, so the
  coalesce is **unwritable** rather than merely discouraged.
- A new resume gate, **`owner_notice_provider_accepted`**, names the blocked state separately from
  the clock. "The provider never accepted it" and "seven days have not passed" need **opposite**
  operator actions — re-send versus wait — and collapsing them into one date comparison would report
  the second when the truth is the first.
- A checkpoint whose acceptance and dispatch instants **coincide is refused as evidence**: it
  satisfies both formulas and so cannot prove which rule produced it. The transformation-test rule,
  applied to the artifact itself.

Pinned by `test/branchBCheckpoint.test.ts` §8 — stale-provenance-with-fresh-acceptance, exact
boundary, boundary + 1 ms, NULL acceptance as a named block, provenance-anchored decode rejected, and
no-coalesce — and by four mutations, each DETECTED:
`p11ocd-checkpoint-anchored-on-provenance`, `-coalesces-acceptance-to-provenance`,
`-resume-gate-ignores-acceptance`, `-boundary-becomes-inclusive`.

The server remains canonical: nothing in the checkpoint grants a release, and `authorize_release`
re-derives everything through `owner_notice_release_authority` on every call. This only decides when
it is worth ASKING.

**Branch B remains NOT STARTED — gate closed.** No Branch-B identity, estate, designation, grant or
case was created; only the schema the future drill will use.
