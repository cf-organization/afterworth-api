# Phase 11 release fire drill — plan, updated against the built console

**NOT EXECUTED. DO NOT BEGIN WITHOUT CHRIST'S EXPLICIT AUTHORIZATION.**

11-J designed this drill and recorded that it could not be run: nine of the twelve steps had no
client, and `admin_require_gate` refuses a SQL-editor session. **That blocker is now removed in
source** — the console carries six of the nine, and the three fiduciary doors remain deliberately
unbound. This revises the plan against what was actually built.

---

## 1 · What changed since the 11-J design

| 11-J said | Now |
|---|---|
| "Nine of twelve steps have no client" | **Six now have one.** Review, attained level, decide, dispatch, window, release are all in `afterworth-admin /cases/[id]`. |
| "The drill would need raw PostgREST with a hand-minted admin JWT" | No longer true for the operator half. The drill exercises the interface an operator will actually use. |
| "Build the operator surface first" | Done, **in source**. Still `DEPLOYMENT_REQUIRED`. |
| Steps 4/5 (initiate, attach evidence) | **Still no client.** `get_executor_workspace` renders them as inert labels — honestly disclosed at 11-I. |

## 2 · Remaining blockers, in order

| # | Blocker | Owner | Status |
|---|---|---|---|
| B1 | `operator_console_bundle.sql` is not deployed | Christ | **DEPLOYMENT_REQUIRED** |
| B2 | Two individually-held AAL2 operator accounts must exist | Christ | **UNKNOWN — see §3** |
| B3 | Steps 4–5 have no client on any surface | product | see §4 |
| B4 | `jurisdiction_policy` is empty, so every estate requires `enhanced_kyc` | counsel | see §5 |
| B5 | The admin console is not deployed | Christ | after B1 |

**Every one of these blocks the drill. None is resolved by this phase.**

## 3 · The two-person rule, stated honestly

`authorize_release` derives reviewer A from the verified case's decider and refuses when
`auth.uid() = reviewer_a`. `release_authorizations` additionally carries a CHECK making a
single-reviewer row unwritable by **any** path. The routine is the door; the constraint is the wall.

**What that enforces is two distinct authenticated IDENTITIES. It cannot prove two distinct humans.**

Two acceptable postures, and they are not the same thing:

> ### TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE
>
> One operator holding two individually-authenticated AAL2 accounts. **Acceptable for pre-launch
> validation only.** It proves the mechanism refuses reviewer A and accepts a distinct reviewer B.
> It proves nothing about independent human judgement, which is the control's actual purpose.
>
> Any drill run this way **must be labelled with this heading in its evidence record.**

> ### TWO-PERSON CONTROL: PRODUCTION
>
> Two distinct humans, each holding their own credentials, neither able to authenticate as the other.
> **This is a launch requirement.** A console that logs in as a shared account satisfies the database
> and destroys the control in practice — which is precisely the disputed-release scenario the audit
> trail exists to resolve.

**LAUNCH REQUIREMENT (recorded here, not solved here): real production claim release requires two
distinct human operators.** Reporting two accounts held by one person as a true two-person control
would be a false statement about a safety property.

**I have not checked how many admin accounts exist** — that requires production credentials.
**STOP: Christ must confirm whether two individually-held AAL2 admin accounts exist, and authorize
their creation if not.** Claude does not create accounts.

## 4 · The sequence, against the built console

| # | Step | Routine | Actor | Client |
|---|---|---|---|---|
| 1 | Create synthetic owner + estate | signup | synthetic owner | ✅ mobile |
| 2 | Designate a fiduciary | `admin_create_executor_invitation` → `provision_from_invitation` | admin + designee | ✅ admin |
| 3 | Author a death-conditioned grant | `create_asset_grant` / `create_document_grant` | owner | ✅ mobile |
| 4 | Initiate the case | `initiate_death_verification_case` | designee | ❌ **B3** |
| 5 | Attach evidence | `attach_death_verification_evidence` | designee | ❌ **B3** |
| 6 | Review evidence | `admin_review_death_evidence` | operator A | ✅ **11-K** |
| 7 | Set attained level | `admin_set_attained_verification_level` | operator A | ✅ **11-K** |
| 8 | Verify | `admin_decide_death_verification_case('verify')` | operator A | ✅ **11-K** |
| 9 | Dispatch owner notice | `dispatch_owner_safety_notice` | operator A | ✅ **11-K** |
| 10 | **Confirm the email arrived** | the drain | — | ✅ **11-K, new** |
| 11 | Open the window | `begin_challenge_window` | operator A | ✅ **11-K** |
| 12 | **Wait 7 days** | wall clock | — | — |
| 13 | Authorize release | `authorize_release` | **operator B ≠ A** | ✅ **11-K** |

**Step 10 is new and it is the point of the email half.** Until this phase, "the owner was notified"
meant a row in a queue nothing drained. The drill must now confirm a real message reached a real
inbox — the first end-to-end proof the independent channel exists.

Note the daily cron: after step 9, **the email may take up to ~24h**. Plan the drill around that, or
trigger the drain manually with the `CRON_SECRET` bearer.

## 5 · The verification-level trap

`jurisdiction_policy` ships empty, so `required_verification_level` fails closed to `enhanced_kyc`
for **every** estate. `admin_set_attained_verification_level` takes an operator's assertion with a
free-text basis, and no KYC provider is integrated anywhere in the repo.

**So today the only route to `death_verified` is an operator manually asserting `enhanced_kyc` on no
evidence but their own judgement.** The drill will do exactly this at step 7, and the evidence record
must say so plainly rather than describing it as a verification.

This is D-J5 and it remains open. Either integrate a provider, or approve at least one jurisdiction
floor at `attestation` and accept that tier explicitly. The current state is the worst of both: a
maximum bar satisfied by an unaided human.

## 6 · Price

| Item | Cost |
|---|---|
| Accounts | **5** — synthetic owner ×2 (one per branch), fiduciary designee, operator A, operator B (**distinct**) |
| Estates | **2** — halt and release are terminal in opposite directions; one estate can only reach one |
| Calendar | **≥7 days per branch**, concurrent → ~8 days. `challenge_window_duration()` is read live at release time, so shortening it mid-drill shortens the window — and a shortened window proves a 7-day window was never tested |
| Irreversible | `released` is terminal; `challenge_halted` is terminal; `release_authorizations` rows are permanent; high-severity `audit_logs` rows are permanent and self-read-only |
| Manual operator acts | **7** (steps 6–9, 11, 13, plus the step-2 designation), each needing AAL2 and a token ≤900 s old |
| Environment | **Production, on synthetic estates.** A staging Supabase would not exercise the deployed grants, the PostgREST schema cache, or the real JWT/AAL2 path — the exact failure class that hid a missing migration for a week |
| Cleanup | **Retain, do not delete.** These become the only real evidence of a released estate. Prefix synthetic identities distinctly and record them in `e2e/fixturePersonas.ts`. Never place synthetic credentials in a repo doc. |

## 7 · Two runs, and why they cannot share an estate

- **Run A — halt.** Steps 1–11, then the owner challenges at step 12. Terminal at `challenge_halted`.
- **Run B — release.** Steps 1–13 uninterrupted. Terminal at `released`.

`challenge_halted` and `released` are both terminal with no outbound edges. One estate reaches one.

## 8 · What the drill closes that nothing else can

- executor authorized-branch device evidence at `released`
- fiduciary estate switching with a released estate in the set
- survivor released-state device evidence
- **owner-safety email delivered end to end** (new in 11-K)
- challenge behaviour on wall-clock time
- the two-person authorization exercised by two real sessions
- device validation of the `death_process.window_opened` notification, which has never had a dispatch
  to observe

## 9 · Credential-screen discipline during the drill

The drill involves repeated sign-in as five synthetic identities. The standing rule applies without
exception:

- **Enter the password FIRST** where entry order permits — it is the only masked field.
- **Never screenshot or enumerate a populated credential screen**, not to debug a failed paste, not
  to check a layout.
- Learn paste coordinates from an **empty** form, once, and **re-enumerate whenever the form may have
  changed** — a validation error shifts the layout and a remembered coordinate misses.
- When a paste misses, **reset the form**; do not photograph it.
- Leave the login screen entirely before collecting authenticated evidence.
- Inspect every screenshot before retaining it; delete any containing a synthetic identity.

Three incidents in this project came from violating these, the third from reusing a remembered
coordinate.
