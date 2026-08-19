# Guarded non-production seed / reset — the GUARD LAYER

**Status, stated before anything else, because the whole risk of this document is being misread as
an announcement that seeding now works:**

| | |
|---|---|
| **Guard layer** | **IMPLEMENTED** |
| **Execution layer** | **NOT IMPLEMENTED** — no seed, no reset, no connection, no SQL |
| **Non-production environment** | **NOT PROVISIONED** |
| **Production** | **UNTOUCHED** |

Nothing here can write to any database. The most permissive verdict the module can return is
`DRY_RUN_AUTHORIZED`, which authorizes the printing of that word and nothing else. R-02 (no
non-production environment exists) remains **OPEN**; this closes only the plan's prerequisite that
guarded tooling exist *before* any seeding.

## Where the contract came from

`afterworth-mobile/docs/testing/environment-and-seeding-plan.md` § *"Guarded seed/reset tooling
(must exist before seeding)"* is the authority. It commits to **five** guards. Two of them are pre-
write decisions a pure classifier can make, one is an execution-layer property, and one is a
repository property:

| Plan guard | Here |
|---|---|
| 1 · project-ref guard | **G1** explicit target + **G2** production pin — the plan states both halves in one sentence; they are separated because "no target supplied" and "the target is production" are different operator mistakes deserving different words |
| 2 · estate-id allowlist | **G6** manifest allowlist |
| 3 · synthetic-identity guard | **G5** plus-addressed on the approved domain |
| 4 · idempotent seed + reset | **NOT IMPLEMENTED** — execution-layer. The declared delete order is carried as inert data in `RESET_FK_ORDER` so the future adapter cannot invent one |
| 5 · no secrets in the repo | enforced by registering the module in `noProductionMutation.test.ts`'s `READ_ONLY_FILES` |

**G3 (environment intent) and G4 (destructive confirmation) are additions, not plan guards.** The
decision is recorded rather than left implicit: the plan's project-ref guard protects only against
refs it already knows, so it is a single point of failure for any ref the pin has never heard of.
G3 forces the operator to *state* non-production intent; G4 forces a destructive operation to *name
its own target*. Neither weakens a committed guard.

## The six guards

All six are evaluated on **every** call — there is no short-circuit, and each contributes its own
refusal reason. That independence is what makes "delete any one guard" a detectable mutation: a
short-circuiting chain would hide a deleted guard behind whichever earlier one happened to fire.

| Guard | Refuses when |
|---|---|
| `G1_explicit_target` | target missing / empty / whitespace (`target_missing`) or not 20 lowercase letters (`target_malformed`) |
| `G2_production_pin` | the target is a pinned production ref (`production_target_forbidden`) |
| `G3_environment_intent` | intent absent (`environment_intent_missing`), not a known label (`environment_intent_unrecognized`), or `production` (`environment_intent_is_production`) |
| `G4_destructive_confirmation` | **reset only** — confirmation absent (`destructive_confirmation_missing`) or naming a different project (`destructive_confirmation_target_mismatch`) |
| `G5_synthetic_identity` | any identity is not plus-addressed on the approved domain (`synthetic_identity_required`) |
| `G6_estate_manifest` | any named estate is absent from the manifest (`estate_not_in_manifest`) |

An unusable policy yields `guard_policy_unresolved` and refuses everything — the plan's *"fail
closed on an unreadable ref"*, generalized.

### G2 cannot be argued down

G2 consults the **target** and the **pin**, and nothing else. It does not read the declared
environment, the confirmation, or the operation. Every combination of every environment label and
every operation against the production ref refuses — asserted exhaustively, not by sampling.

### The pin is committed source, not configuration

A production ref resolved from the operator's environment protects nothing when that environment is
the thing that is wrong, and *stale environment variables* is on the threat list. Pinned in source,
the denylist cannot be changed by a shell, a CI variable, a `.env` file or a flag.

The ref is **not a secret** and its presence introduces no disclosure — the same value is already
committed in `README.md` and ten `docs/*-proof.md` files. A project ref is an identifier, not a
credential; it authorizes nothing on its own, which is exactly why it is safe to write down and
useful to deny.

**The pin is checked against committed repository content by test.** A denylist pinning the *wrong*
ref would deny a project that does not exist and leave production wide open — while every refusal
test still passed, because they would all feed it the same wrong value. That is the same defect
class as a scanner that inspects nothing, and it is why `nonProdSeedGuard.test.ts` group 1 exists.

### Reset demands strictly more than seed

Seed needs no destructive confirmation; reset requires one that **equals the target ref**. A boolean
`--yes` is satisfied by muscle memory; retyping the project cannot be. A boolean-ish *string*
(`"yes"`, `"true"`) refuses as a **mismatch** rather than as missing — the operator did supply
something, and it was not the project.

## No I/O, proved rather than asserted

The module has **no imports at all**, and that is load-bearing. A classifier that could read
`process.env` would let a stale environment participate in the decision; one that could read the
filesystem could be pointed at a different policy than the one under review.

Pinned by test: no import, no `require`, no fetch/XHR/axios, no `child_process`, no `node:fs`, no
Supabase client, no `process.env`, no SQL verb, and no `async`/`await`/`Promise`. The API-absence
checks run on **comment-stripped** source via `readOnlyAudit`'s stripper — the header deliberately
names the APIs it refuses to use, so a raw match would report the documentation as the violation it
documents. A positive control proves the stripper removes prose and keeps string literals.

## Evidence

- **60** guard tests + **37** firewall tests (the module is registered in `READ_ONLY_FILES`)
- **12/12 mutations DETECTED**, tree restored byte-identically after each
- No network call, no subprocess, no database, no credential loaded, at any point

## What must happen before this tool may ever run

Everything in the plan's definition of done, unchanged. In particular a non-production project must
be provisioned and its ref recorded **outside this repository**, and an execution adapter must be
written and separately reviewed. The guard layer existing is a prerequisite, not permission.
