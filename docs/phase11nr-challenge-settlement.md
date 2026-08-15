# Phase 11-NR — the owner challenge settles the case it actually halted

**STATUS: DEPLOYED_AND_VERIFIED** — pasted 2026-08-15 by the operator, verified read-only the same
day. Evidence in §12. Claude did not execute production SQL.

Remediates **FINDING 4** of the Branch A production fire drill
(`afterworth-mobile/docs/phase11n-branch-a-report.md` §6). Branch A's verdict remains
**`BRANCH_A_FAILED`** and is not changed by this work. Branch B remains **NOT STARTED**: deployment
and verification were a precondition, not the authorization — it additionally needs a **different**
disposable estate and an explicit fresh drill decision (§11, §12.6).

---

## 1 · Root cause

`challenge_death_process` settled the death-verification case and captured the notification
recipient in ONE statement:

```sql
update public.death_verification_cases
   set status = 'halted', updated_at = now()
 where estate_id = p_estate and status = 'open'      -- ← ONLY 'open'
returning initiated_by into v_initiator;

if v_initiator is not null and v_initiator <> v_uid then
  perform public.emit_lifecycle_notification(v_initiator, p_estate, 'death_process.halted', null);
end if;
```

The owner challenge is reachable from **four** lifecycle states. `status = 'open'` is the case
status at exactly **one** of them:

| lifecycle at challenge | put there by | case status | old predicate matched |
|---|---|---|---|
| `death_verification_pending` | `initiate_death_verification_case` | `open` | ✅ |
| `death_verified` | `admin_decide_death_verification_case('verify')` | `verified` | ❌ |
| `owner_notification_dispatched` | `dispatch_owner_safety_notice` (requires a verified case) | `verified` | ❌ |
| `challenge_window` | `begin_challenge_window` (requires a verified case) | `verified` | ❌ |

Every operator-driven process passes through `verify`. So on the canonical path the UPDATE matched
no row, `v_initiator` came back NULL, and the emission was skipped — **the entire Phase 11-L
deliverable, dead on the only path a real death process takes.**

Because one statement did both jobs, the two symptoms are one defect: an untouched row proves the
UPDATE matched nothing, which proves the recipient was never captured.

## 2 · Measured production impact

Observed on the Branch A drill estate `86d7eede-c37a-4b2b-9c2b-d71e7ac2e0dc`, and **re-confirmed
read-only through product paths at the start of this phase** (ordinary password sign-in, publishable
key, no `service_role`):

| Observation | Value |
|---|---|
| `estate_lifecycle.state` | `challenge_halted` |
| `death_verification_cases.status` | **`verified`** — never settled |
| `case.updated_at` | identical to `decided_at`; the halt never wrote the row |
| fiduciary halt notifications | **0** |
| positive control — owner, same estate | 2 notifications ✓ (the layer works) |
| `get_executor_workspace.verification.state` | **`verified`** while `process.challenge_halted = true` |
| `get_owner_safety_status` | `halted` |
| operator queue `p_status => 'verified'` | **returns the halted case** |
| operator queue `p_status => 'halted'` | **empty** |

The divergence was client-visible: a fiduciary was told their verification stood while the estate
was terminally halted. The admin console's own lifecycle test already pins the correct pairing
(`{state: "challenge_halted", status: "halted"}`), so the console assumed a state the server never
produced.

## 3 · Why 3,000+ green assertions never saw it

`db/tests/release_safety_authorization.sql` §7 — the section named for this notification — halts
**immediately after `initiate`**, from `death_verification_pending`, on every one of its estates
(H, R, S, X). So does §2 (C, N) and §3 (the tiebreak estates). **Every halt in the suite fired on
the one branch where `status = 'open'` matched.**

This is not "a missing test". Following the wire-decoder precedent, the suite **specified the branch
that worked** and named it for the general behaviour. §1 does walk the full canonical path — and
terminates in `released`, never in a halt.

The repository's own transformation-test rule states it exactly: *the fixture must make the
transformation observable*. Here the fixture was the only input on which the transformation applied.

**Correction applied, not rewritten:** §7's title and header now say what it actually observes
(*"halted from `death_verification_pending`"*), and `docs/phase11l-halt-notification.md` carries a
superseding banner naming the two claims in it that read wider than they were. The historical record
is left standing.

## 4 · The fix

One predicate, in one routine. **No new vocabulary, no DDL, no grant, no migration** — `'halted'`
has been in `death_verification_cases_status_check` since migration 0054, added for this transition.

```sql
-  where estate_id = p_estate and status = 'open'
+  where estate_id = p_estate and status in ('open', 'verified')
 returning initiated_by into v_initiator;
```

**The set is closed and derived from the state machine, never "every row for this estate".**
`rejected` and `cancelled` both return the lifecycle to `active`, where the routine has already
raised `nothing_to_challenge` — they are decided history, and settling them would overwrite an
adjudication that really happened. `halted` is excluded as a second, independent guard against a
re-stamp; the idempotent early return already refuses to reach the statement.

**It still matches at most one row, and that no longer follows from the index alone.**
`death_verification_cases_one_open_per_estate` makes `open` unique per estate. `verified` is unique
for a different reason and the state machine supplies it: a verified case pins the lifecycle at
`death_verified` or beyond, `initiate` requires `active`, and no edge returns there — so a second
case cannot be opened once one is verified, and `open` cannot coexist with `verified`. Historical
`rejected`/`cancelled` rows DO coexist and are excluded by the predicate. `into` therefore has no set
to choose from arbitrarily.

**Recipient provenance is unchanged and still comes from the transition itself** — `returning
initiated_by into v_initiator`, never a later SELECT. No reordering: the case UPDATE, the lifecycle
transition, the emission and the audit all run in the caller's single transaction, so a failure
anywhere leaves nothing behind. Owner-liveness suppression, the owner-exclusion guard, the
one-argument signature and the absent deep link are all untouched.

**Not changed:** no authorization, no grant, no disclosure, no release behaviour, no lifecycle map
edge, no notification copy.

### Downstream re-derived, not assumed

Every consumer of `case.status` was checked against the flip from `verified` → `halted`:

- `dispatch_owner_safety_notice`, `begin_challenge_window`, `authorize_release` — all three gate on
  the **lifecycle** before their `status = 'verified'` lookup, so a halted estate is refused by state
  and no refusal shape changes (`invalid_release_state` still holds at `challenge_halted`).
- `initiate` gates on lifecycle; `attach_evidence`, `cancel`, `admin_decide`,
  `admin_set_attained_verification_level` all require `'open'` and already refused a `verified` case
  with the identical sentinel.
- `get_executor_workspace` projects the status; the mobile client has decoded `'halted'` since 11-I
  (`features/executor/model.ts`), and `deriveStanding` reads `process.challengeHalted` first. **No
  mobile release is required.**
- `admin_list_death_verification_cases` — the intended correction.

## 5 · Evidence

| Gate | Result |
|---|---|
| SQL authorization suite | **exit 0 · 410 assertions** (real `is_estate_owner`, RLS under role `authenticated`) |
| `vitest` | **exit 0 · 379 tests / 16 files** |
| `tsc --noEmit` | **exit 0** |
| bundle atomicity | **exit 0** — pure SQL, one transaction, corrupted-run rolls back |
| bundle determinism | rebuilt twice, byte-identical |
| gitleaks | **exit 0** — 154 commits, no leaks |
| CI credential-shape scan (run locally) | **0 hits**, no tracked `.env` |
| mutation suite | see §7 |

### The new regression test — `release_safety_authorization.sql` §8

Walks the real sequence through the real doors: prior case → **rejected** → new case → attained
level → **verify** → **dispatch** → **window** → owner challenge.

Built so the transformation is observable, which is precisely what §7 lacked:

- **the anchor is asserted**: lifecycle `challenge_window`, live case `verified`, and — stated
  explicitly so later fixture drift cannot make the section tautological again — **no `open` case
  exists**, so the pre-11-NR predicate matches nothing;
- **a decoy is present**: a prior case on the same estate, **rejected** by an operator and initiated
  by a **different** fiduciary, so an over-wide predicate and a wrong-row recipient are both
  detectable;
- **both rows are aged first**, because `now()` is transaction-constant and an `updated_at`
  assertion written against it is a control that cannot fail.

It then asserts: lifecycle `challenge_halted`; case `halted`; the row was actually written; the
rejected decoy is byte-unchanged; exactly one case settled; the operator's verification decision
(`decided_by`/`decided_at`) **preserved, not erased**; exactly one notification, to the settled
case's initiator, carrying catalog copy with no deep link, no identifier and no owner-liveness
disclosure; the owner, the decoy initiator and a beneficiary each receive nothing; and — the
positive control — the owner safety notice still exists, so the fiduciary assertions are not
measuring a dead notification layer.

**Operator queue proved through the real RPC**, not a hand-written approximation:
`admin_list_death_verification_cases('verified')` returns **0** rows for the estate and
`…('halted')` returns exactly **1**, whose `case_status` and `lifecycle_state` agree.

Negative controls: an unauthorized challenge settles nothing and emits nothing; replay emits no
second notification and moves no state; a foreign estate is unsettled and unnotified.

## 6 · The artifact

```
build:   node scripts/buildChallengeSettlementBundle.mjs
verify:  node scripts/buildChallengeSettlementBundle.mjs --check
path:    db/bundles/challenge_settlement_bundle.sql
parts:   db/functions/release_safety.sql          (1 part)
```

**One part, deliberately.** `halt_notification_bundle.sql` also carries this file, but it re-pastes
`lifecycle_notification_rpcs.sql` alongside it and nothing in the notification catalog changed. This
repository has already come within one paste of regressing production by re-applying a source file
that was behind the deployed body (`create_asset_grant`, Phase 10-E), so the remediation ships
exactly the file that changed: the deployment diff and the blast radius are the same set.

Pure SQL, no psql meta-commands, wrapped in exactly one explicit transaction. Re-paste safe — every
statement is `create or replace` / `revoke` / `grant` / `comment on`.

## 7 · Mutation evidence

All five new mutations are killed by the **runtime** layer (`DETECTED`, not `HARNESS_FAILURE`, not
`BUILD_FAILURE`, not a static audit), each inside a throwaway `git worktree` with the primary
checkout verified byte-identical afterwards.

| id | injection | killed by |
|---|---|---|
| `p11nr-settlement-narrowed-to-open` | **the exact production defect**, restored character for character | §8 — invisible to §7 |
| `p11nr-settlement-widened-to-every-case` | `status is not null` | §8 decoy: a rejected case is overwritten |
| `p11nr-recipient-from-a-later-select` | RETURNING replaced by a post-hoc SELECT | §8 decoy has a different initiator |
| `p11nr-case-status-not-settled` | the status assignment dropped | §8 operator-queue assertions |
| `p11nr-idempotent-replay-guard-neutered` | the replay `return` made a no-op | §2/§7/§8 replays |

`p11l-unrelated-estate-notified` was re-anchored on the corrected predicate — an existing mutation
kept valid, not weakened; it is still `DETECTED`.

**A build control did stand in front of the runtime once, and it was worked around rather than
loosened.** The natural form of the replay mutation (`if false`) is refused at build time by
`buildHaltNotificationBundle.mjs`'s standing control on `if v_state = 'challenge_halted' then`. That
control is deliberate and pre-existing, so instead of removing it the mutation now leaves the pinned
line exactly as it is and neuters the `return` inside — the established `if false` technique applied
correctly, keeping the artifact intact while the behaviour is unreachable, so the runtime layer is
what votes.

**No build control pins the settlement predicate**, in either the existing builders or the new one —
verified by inspection and proved by the fact that the exact-regression mutation reaches Postgres and
is caught there. The new builder's controls assert only that the six routine signatures and the two
privilege statements are present, which is a real completeness property: `create or replace` only
replaces what the artifact contains, so a part that had lost a routine would silently leave the
deployed body in place.

## 8 · Deployment

**Claude does not paste production SQL.** Christ pastes it.

1. Paste the full contents of `db/bundles/challenge_settlement_bundle.sql` into the Supabase Web SQL
   Editor and run it once.
2. Run the read-only verifiers in §9. All must pass.
3. Run `node scripts/verifySourceDeploymentDrift.mjs` — expect **exit 0**.

**Before state:** owner challenges from `death_verified` / `owner_notification_dispatched` /
`challenge_window` halt the lifecycle, leave the case `verified`, emit no halt notification, and
leave the case in the operator `verified` queue.

**After state:** the same challenges also settle the case to `halted` and emit exactly one
`death_process.halted` notification to the case's initiator. Challenges from
`death_verification_pending` are unchanged in every respect.

**Safe intermediate state:** none exists — one transaction, so the artifact either applies whole or
changes nothing.

**No backfill is included, and that is a decision rather than an omission.** The Branch A drill
estate's case row stays `verified` on a `challenge_halted` estate. It is terminal forensic evidence
of the defect and must not be repaired by a manual `service_role` write; `challenge_halted` has no
outbound transition, so no product path can re-settle it either. Any future backfill of historically
diverged rows is a separate, reviewed decision with its own artifact.

## 9 · Read-only post-deployment verifiers

None of these mutates anything. Run in order; every one must match.

```sql
-- 1 · THE FIX IS DEPLOYED: the settlement set is widened.
select prosrc like '%status in (''open'', ''verified'')%'  as widened_set_deployed,
       prosrc like '%returning initiated_by into v_initiator%' as recipient_from_the_transition
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'challenge_death_process';
-- expect: t, t

-- 2 · THE OLD ONE-PATH PREDICATE IS GONE. This is the assertion that would have caught the defect.
select position('and status = ''open''' in prosrc) = 0 as narrow_predicate_absent
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'challenge_death_process';
-- expect: t

-- 3 · NOTHING ELSE IN THE ROUTINE MOVED: owner gate, replay guard, catalog emitter, no composed text.
select prosrc like '%is_estate_owner(p_estate)%'   as owner_gated,
       prosrc like '%challenge_halted%'            as replay_guarded,
       prosrc like '%death_process.halted%'        as names_the_event,
       prosrc like '%emit_lifecycle_notification%' as uses_the_catalog_emitter,
       prosrc not like '%emit_notification(%'      as composes_no_text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'challenge_death_process';
-- expect: t, t, t, t, t

-- 4 · NO AUTHORIZATION OR GRANT WIDENING — the routine is still owner-only and client-reachable,
--     and the internal emitter is still internal.
select has_function_privilege('authenticated','public.challenge_death_process(uuid)','execute') as auth_can_challenge,
       has_function_privilege('anon','public.challenge_death_process(uuid)','execute')          as anon_can_challenge,
       has_function_privilege('authenticated','public.emit_lifecycle_notification(uuid,uuid,text,text)','execute') as client_can_emit,
       has_function_privilege('anon','public.emit_lifecycle_notification(uuid,uuid,text,text)','execute')          as anon_can_emit;
-- expect: t, f, f, f

-- 5 · THE SIGNATURE IS STILL ONE ARGUMENT — no caller can nominate a recipient.
select count(*) as should_be_one
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'challenge_death_process' and p.pronargs = 1;
-- expect: 1

-- 6 · THE CATALOG COPY IS UNCHANGED, VERBATIM.
select category, title, body
  from public.notification_event_copy('death_process.halted');
-- expect: claimUpdate | Estate process halted | The estate process you initiated has been halted.

-- 7 · THE CATALOG STILL REFUSES AN UNKNOWN EVENT (the closed-catalog property).
select count(*) as should_be_zero
  from public.notification_event_copy('death_process.aw_probe_not_an_event');
-- expect: 0

-- 8 · 'halted' AND 'verified' ARE BOTH STORABLE — the widened set cannot raise check_violation.
select pg_get_constraintdef(oid) like '%halted%'   as admits_halted,
       pg_get_constraintdef(oid) like '%verified%' as admits_verified
  from pg_constraint where conname = 'death_verification_cases_status_check';
-- expect: t, t

-- 9 · THE OTHER FIVE ROUTINES IN THE RE-PASTED FILE ARE ALL PRESENT (the file shipped whole).
select count(*) as should_be_six
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('challenge_window_duration','dispatch_owner_safety_notice',
                     'begin_challenge_window','authorize_release',
                     'challenge_death_process','get_owner_safety_status');
-- expect: 6
```

Then, from `afterworth-api`:

```
node scripts/verifySourceDeploymentDrift.mjs      # expect exit 0
node scripts/verifyOperatorDoorRefusal.mjs        # expect exit 0
node scripts/verifyOperatorAdmitPath.mjs          # expect exit 0
```

And from `afterworth-mobile`:

```
node scripts/verifyDeployedContracts.mjs          # expect exit 0
node scripts/fiduciaryFixtureSentinel.mjs         # expect exit 0, 23/23
```

**Deliberately NOT required: a production mutation to prove the body is deployed.** Verifier 1 reads
the deployed `prosrc` directly. Driving a real estate through a halt to observe the fix would mean
creating and terminally halting another production estate, which is a fire drill, not a verifier.

## 10 · Rollback

Re-paste `db/bundles/challenge_settlement_bundle.sql` **built from the parent commit** — one
`create or replace` on unchanged signatures, so privileges are preserved in both directions and no
grant is disturbed.

Rolling back restores the defect: canonical-path halts stop settling the case and stop notifying the
fiduciary. It strands no state. Rows already settled to `halted` by the fixed routine stay `halted`
and stay valid — `halted` was legal vocabulary before this phase and nothing reads it conditionally.
No notification already emitted is invalidated.

There is no runtime switch, deliberately: a safety transition that can be silenced by configuration
is one nobody can rely on having happened.

## 11 · What this does NOT do

- It does **not** change Branch A's verdict. `BRANCH_A_FAILED` stands: Stage 12 produced no
  artifact, and T2 (owner email delivery) remains calendar-bound and unobserved.
- It does **not** unblock Branch B. Branch B needs this deployed and verified, a **different**
  disposable estate, and an explicit fresh authorization.
- It does **not** re-run Branch A. Validating the corrected path end to end needs a new disposable
  drill, planned separately.
- It does **not** touch the standing fixture, the drill estate, or `afterworth-admin`.
- It does **not** address FINDING 1 (no estate-rename path), FINDING 2 (no owner-driven fiduciary
  designation) or FINDING 3 (break-glass invitation copy). Those remain open product decisions.

---

## 12 · Post-deployment verification — DEPLOYED_AND_VERIFIED

Pasted by the operator into the Supabase Web SQL Editor on 2026-08-15. Verified the same day.
**No production state was mutated to obtain any of this evidence**: no estate was challenged, no case
was repaired, no drain was triggered, and the historically diverged Branch A row was read only.

### 12.1 · Provenance

`db/bundles/challenge_settlement_bundle.sql` rebuilt from committed source at `a39098c` →
`0f2f0bdfd5b4701365ab8ba9a3bb55a7a3c023e01b110d715667e904f42a4b42`, byte-identical to the artifact
that was pasted, and the tree stayed clean across the rebuild.

### 12.2 · The nine §9 verifiers, reconciled against source

| # | Deployed answer | Committed source | Verdict |
|---|---|---|---|
| 1 | `widened_set_deployed=t`, `recipient_from_the_transition=t` | `release_safety.sql:497` — `and status in ('open', 'verified')`, one occurrence, with `returning initiated_by into v_initiator` | ✅ |
| 2 | `narrow_predicate_absent=t` | `and status = 'open'` occurs **0** times in source | ✅ |
| 3 | `owner_gated`, `replay_guarded`, `names_the_event`, `uses_the_catalog_emitter`, `composes_no_text` all `t` | all five present/absent as source declares | ✅ |
| 4 | `auth=t`, `anon=f`, `client_can_emit=f`, `anon_can_emit=f` | `release_safety.sql:547-548` revoke from public/anon + grant to authenticated; migration 0050 revokes the emitter from public, anon **and** authenticated | ✅ |
| 5 | `should_be_one=1` | `challenge_death_process(p_estate uuid)` — one parameter | ✅ |
| 6 | `claimUpdate` / `Estate process halted` / `The estate process you initiated has been halted.` | catalog literal unchanged by this phase | ✅ |
| 7 | `should_be_zero=0` | closed catalog preserved | ✅ |
| 8 | `admits_halted=t`, `admits_verified=t` | migration 0054 CHECK — `('open','verified','rejected','cancelled','halted')` | ✅ |
| 9 | `should_be_six=6` | `release_safety.sql` defines exactly six routines; the bundle carries six | ✅ |

**Verifier 2 is precise only because of its `and ` prefix, and that is not incidental.** `prosrc`
includes comments, and this phase's own remediation comment quotes the old predicate as
`` `status = 'open'` ``. A check written without the prefix would have matched that documentation and
reported the defect as still deployed — a false FAILED on a correct deployment. The prefix is what
separates the predicate from the prose about the predicate.

### 12.3 · Corroborating evidence (product paths, read-only)

`verifySourceDeploymentDrift` exit 0 — 4 reconcilable contracts EXACT, `notification_event_copy`
9/9 verbatim. `verifyDeployedContracts` exit 0 — `challenge_death_process` PRESENT with its own gate
observed, `authorize_release` ADMIN-GATED, `release_estate` ABSENT, `estate_release_state` and both
notification emitters LOCKED, `get_executor_workspace` / `get_my_fiduciary_estates` PRESENT.
`fiduciaryFixtureSentinel` **23/23 exit 0** — the standing fixture never moved.

**`release_authorization_authority` remains UNVERIFIABLE (stateful) in the drift reconciler and was
not rounded up to EXACT.** The §9 body verifiers above are what carry that proof, which is exactly
the division the reconciler documents for itself.

### 12.4 · The Branch A forensic estate — unchanged, and deliberately so

Read through the AAL2 operator case file and through product paths. Both agree:

| Property | Value |
|---|---|
| `lifecycle.state` | `challenge_halted` |
| `case.status` | `verified` |
| `case.updated_at` | `2026-08-15T06:43:42.403419Z` — byte-identical to `decided_at` |
| `lifecycle.halted_at` | `2026-08-15T06:47:15.534Z` |
| `lifecycle.released_at` | `null` |
| halt notifications | 0 |

The divergence is **expected historical evidence, not a live remediation failure**. `challenge_halted`
has no outbound transition and the routine's idempotent early return fires before the settlement
statement, so no code path — corrected or not — can reach this row. The fix is forward-looking. It
was not repaired, and repairing it would require exactly the manual write this programme forbids.

### 12.5 · T2 — still outstanding

`status=queued`, `dispatched_at=null`, `attempts=0`, `failure_class=null`, read at
2026-08-15T08:04Z. The earliest scheduled drain after the 06:46:18Z enqueue is **2026-08-16T04:00Z**.
`ENQUEUE_TO_DELIVERY_LATENCY` and `WINDOW_TO_DELIVERY_OFFSET` remain **NOT COMPUTABLE**. The drain
was not triggered and no `CRON_SECRET` was used. `providerAccepted` will be provider acceptance, not
inbox arrival.

### 12.6 · Classification

```
FINDING 4 REMEDIATION:  DEPLOYED_AND_VERIFIED
SUPABASE:               DEPLOYED_AND_VERIFIED
BRANCH A:               BRANCH_A_FAILED   (unchanged — the remediation does not convert it)
BRANCH B:               NOT STARTED
```

Branch A stays failed on its own terms: its Stage 12 produced no artifact and T2 was never observed.
Branch B remains blocked pending a fresh, explicitly authorized drill on a **different** disposable
estate — the corrected end-to-end path has not itself been exercised in production, and this
verification does not claim otherwise.
