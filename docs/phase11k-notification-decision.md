# D-J3 — the two missing Phase 11 notifications: decision packet

**NOT IMPLEMENTED. This is a decision packet, not a proposal that was acted on.**

Stage 11 asked whether two notification gaps should be closed in this phase. The answer is **no, not
without a product decision**, and the reason is not caution — it is that one of the two cannot be
written in the current architecture without re-opening a disclosure hole 11-I deliberately closed.

---

## The architecture any answer must fit

The catalog is a **closed, immutable, ASCII-only table of 8 entries** in
`notification_event_copy`, verbatim-compared against deployment by the drift verifier. The shape is:

```
event constant → immutable copy → sanctioned recipient → allowlisted deep link
              → authority re-checked at the destination
```

**No emitter composes or interpolates text.** A notification is a constant keyed by an event name.
That is load-bearing and is not to be relaxed for either gap below.

## Gap 1 · Owner challenge / halt → the fiduciary

**Today.** The fiduciary who opened the process is never told it was stopped. `get_executor_workspace`
returns no reason. They will re-attempt and receive `lifecycle_conflict` — an error code, about a
decision that was made about them, with no explanation.

**Why it is the most consequential gap.** A person who believes someone has died, and who has begun a
legitimate process, is left to discover by error message that it was halted.

**Why it cannot simply be added.**

1. **The reason is the owner's, not the claimant's.** "Your claim was halted because…" is
   *unwritable* in this design, and that is correct. `challenge_death_process` records no provenance
   — not a channel, device, address, or location — precisely because provenance is
   security-sensitive information about a living owner who has just had to defend themselves.
2. **Telling fiduciary B that a case exists which B did not open discloses that another fiduciary
   exists.** 11-I explicitly refused that disclosure when it omitted `initiator_capacity`. Any
   fiduciary notification must be **scoped to the recipient's own action**, or it re-opens the hole.

**If approved, the shape would be:**

| | |
|---|---|
| event | `death_process.halted` |
| recipient | **the case initiator only** — `death_verification_cases.initiated_by`, never a designation-wide fan-out |
| copy | *"A process you started has stopped."* Names no party, gives no reason, asserts nothing about the owner |
| deep link | `afterworth://executor` (already allowlisted) |
| authority | re-checked at the destination: `get_executor_workspace` gates on `is_estate_executor` |
| emitter | inside `challenge_death_process`, **swallowing failure** — the owner's halt must commit whether or not a heads-up can be written. This is the opposite trade from the window-open notice, and correctly so: the halt protects the owner and must never be blocked by a notification |

**Open question for Christ: does telling the initiator that the owner halted the process disclose too
much?** It reveals that the owner is alive and acted. Arguably that is exactly what a legitimate
fiduciary should learn, and exactly what a fraudulent claimant should not. There is no way to tell
them apart at emit time.

## Gap 2 · Estate released → sanctioned recipients

**Today.** Beneficiaries whose death-conditioned grants just went live are told nothing. Access
appears silently the next time they open the app.

**Why it is less clear-cut than it looks.** "You now have access" is close to the announcement Phase
11 has spent five sub-phases refusing to make. `emit_lifecycle_notification` already carries a death
firewall: `after_verified_death_or_incapacity` is in the **dormant-deny** set precisely so that no
grant conditioned on death can produce a notification. Closing this gap means putting a hole in that
firewall, deliberately, with the release transition as the only key.

**If approved, the shape would be:**

| | |
|---|---|
| event | `estate.released` |
| recipient | **only grantees whose grants are live AT THIS MOMENT**, evaluated through `release_condition_satisfied` — never "everyone on the estate" |
| copy | *"Information has been shared with you."* Names no estate, no document, no value, no relationship, and does not mention a death |
| deep link | an existing allowlisted destination |
| authority | re-checked at the destination — the notification confers nothing |
| emitter | inside `authorize_release`, **swallowing failure** |

**Open question for Christ: is a notification the right channel for this at all?** An email saying
"information has been shared with you" arriving the week someone died is a product decision about
tone, not a technical one.

## Recommendation

| Gap | Recommendation |
|---|---|
| 1 · halt → initiator | **Approve, scoped to the initiator's own action.** It closes a real dead end and, scoped this way, discloses nothing 11-I refused. |
| 2 · released → grantees | **Defer.** It requires opening the death firewall, and the tone question is genuinely a product decision. Silent access is not a defect; it is the current, safe default. |

Neither is implemented. Both are cheap once decided — the catalog, the emitter, the allowlist and the
destination re-check all exist.

## What was NOT invented

No notification was added, no catalog entry was written, no emitter was touched. The catalog remains
8 entries and the drift verifier still compares it verbatim against deployment.
