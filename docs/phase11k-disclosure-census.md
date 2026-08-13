# Phase 11-K — operator disclosure census

Every field the operator console can see, why the workflow needs it, and what it is not.

**The premise.** Administrative workflow authority and estate-content disclosure are separate axes.
An operator adjudicating a death claim needs to know the case exists, what evidence arrived, what
the policy bar is, and where the lifecycle stands. They do not need to know what the estate contains,
what it is worth, who inherits, or how to contact the living person whose death is being claimed.

## 1 · `admin_list_death_verification_cases` — the queue

| Field | Source | Why the operator needs it | Sensitivity | Retention | Shown |
|---|---|---|---|---|---|
| `case_id` | `death_verification_cases.id` | Names the case for every subsequent action | internal id | case lifetime | row link |
| `estate_id` | `death_verification_cases.estate_id` | The argument the dispatch/window/release doors take | internal id | case lifetime | not rendered |
| `estate_name` | `estates.name` | Distinguishes one case from another | **owner-authored text** | estate lifetime | queue + case file |
| `case_status` | `.status` | Triage: which cases need a decision | workflow | case lifetime | badge |
| `lifecycle_state` | `estate_lifecycle.state` | Which action is next | workflow | estate lifetime | plain + raw |
| `event_type` | `.event_type` | Always `death` today; a future incapacity case reads differently | workflow | case lifetime | not rendered |
| `initiated_at` / `updated_at` | case row | Age of the case; ordering | workflow | case lifetime | queue |
| `initiator_capacity` | `.initiator_capacity` | Executor vs trustee — a fact about the claim | workflow | case lifetime | case file |
| `jurisdiction_context` | `.jurisdiction_context` | Explains the required level | low | case lifetime | case file |
| `required_level` | **re-derived LIVE** | The bar the decision routine will actually apply | policy | computed | both |
| `attained_level` | `.attained_level` | What review established | policy | case lifetime | both |
| `evidence_total` / `_awaiting_review` | evidence count | Is there review work | workflow | case lifetime | queue |
| `owner_channel_resolvable` | **boolean over `auth.users`** | Will dispatch succeed | derived boolean | computed | queue |
| `decided_at` | `.decided_at` | Whether a first reviewer exists | workflow | case lifetime | case file |

**`owner_channel_resolvable` is the whole design in one field.** The operator's question is *will
dispatch succeed for this estate*, not *what is this living person's address*. The boolean answers
the first exactly and the second not at all. `dispatch_owner_safety_notice` resolves the real address
itself, from `auth.users`, where no claimant can repoint it.

## 2 · `admin_get_death_verification_case` — the case file

Adds, beyond the queue:

| Field | Why | Sensitivity |
|---|---|---|
| `initiator.email` / `.name` | The operator is judging whether a claimed fiduciary is legitimate. This is the one identity the adjudication requires. | **personal data** — case file only, never the queue |
| `required_level_at_initiation` | The case file's record of policy at opening, labelled as a snapshot | policy |
| `decision_note`, evidence `review_note` | **Reviewer B must form an independent judgement about what reviewer A concluded.** A two-person rule where the second reviewer cannot read the first's reasoning is a rubber stamp with extra steps. | operator-authored |
| `lifecycle.*_at` timestamps | When the clock started, whether it halted, whether it released | workflow |
| `window.release_eligible_at` / `elapsed` | Whether a release call will be refused | workflow |
| `owner_notice[].status`, `attempts`, `failure_class` | Whether the independent channel actually went out | workflow |
| `evidence[]` title / doc_type / dates / review status | The review queue itself | document **metadata** |
| `release.reviewer_a`, `viewer_is_reviewer_a` | Stating release ineligibility truthfully | workflow |

## 3 · Withheld, and enforced

| Not disclosed | Enforced by |
|---|---|
| **Owner email address** | `o.recipient` never selected; migration text assertion; `operatorProjectionDisclosure.test.ts` §3; SQL suite §3 against a fixture that HAS an address |
| Evidence **bytes** / storage path | no `storage_path` in either projection; SQL suite §3 stores a real path and proves it is absent |
| Assets, valuations, net worth | forbidden-surface list, all naming real tables |
| Beneficiaries, memberships, designations | same |
| Access grants, visibility tiers | same |
| `encrypted_instructions` and its whole vocabulary | forbidden in both repos' audits |
| Claim packets / `estate_release_state` | forbidden-surface list |

**Why the absences are pinned structurally.** A runtime test proves what the current fixtures happen
to contain. It cannot prove that an edit adding `e.jurisdiction` or a join to `estate_assets` would
be caught, because a fixture with no assets returns no assets either way. So the SQL suite runs
against a **deliberately furnished** estate — named, owner with an address, beneficiary, designated
executor, a document with a storage path — and the source audit pins the absences against the
function text.

## 4 · What an operator can still learn, and the residual risk

An operator with a valid AAL2 session can enumerate every death-verification case in the product,
including the estate name and the initiator's email. That is the minimum the workflow requires and it
is not nothing:

- **estate names are owner-authored** and may themselves be identifying (`"Rivera Family Estate"`).
- **initiator identity is personal data** about a living person, disclosed on the case file.
- there is **no per-operator case scoping** — every operator sees every case. With two operators this
  is correct; at a larger operations team, case assignment would be the next control.

Recorded rather than solved: scoping cases to assigned operators is a product decision, not a defect
in this phase.

## 5 · Audit trail

`record_owner_notice_outcome` writes `actor_id = null`, `source = 'worker'` — the actor is a
scheduled worker, not a person, and inventing a synthetic operator identity would put a false name in
a permanent record. Its metadata carries outcome, failure class, attempts, channel and notice kind —
**never the recipient address**, matching the dispatch audit it follows. An audit row outlives every
reason anyone had to read it, so the logs cannot serve as a second disclosure channel for the one
field the projections withhold.
