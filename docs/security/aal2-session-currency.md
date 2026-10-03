# An AAL2 claim is a memory — and until 0064 the gate believed it

**Status: fixed in source, NOT YET DEPLOYED.** Migration
`db/migrations/0064_20261001_aal2_session_currency.sql` is reviewed and proven against a container.
It has not been applied to any hosted project. Until it is, MFA recovery on nonprod and production
leaves the window described below open.

---

## What was measured

Nonprod, 2026-10-01, using a dedicated MFA account created for this purpose that owns nothing else
and is not an E2E fixture persona. Identities and tokens are recorded as 8-character tags, never
values.

```
account acde7db9

0 · the account resolves its OWN estate (isolated from every fixture)   estate 657040ce
1 · enrol TOTP -> challengeAndVerify -> session is aal2
    factor 79e918fd verified · token c14c2edf carries aal=aal2, lifetime 3600s
2 · POSITIVE CONTROL, with that token
    get_estate_net_worth(657040ce)                     -> HTTP 200   (the gate is reached)
3 · POST /api/auth/mfa/recover with a valid recovery code
                                                       -> HTTP 200   (factor deleted, sessions revoked)
4 · the SAME token, three seconds later
    get_estate_net_worth(657040ce)                     -> HTTP 200   ✗ ACCEPTED
```

`get_estate_net_worth` was chosen because it is **non-mutating** and AAL2-gated. Its gate order puts
`is_estate_owner(p_estate_id)` *before* `require_aal2()`, so a caller with no estate never reaches
the MFA leg and the probe would have been inconclusive — which is why the account resolved an estate
of its own first.

## Why it happened

```sql
-- the pre-0064 gate, in full
if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
  raise exception 'mfa_required' using errcode = '42501';
end if;
```

`aal` is a **stateless JWT claim**. It records what was true when GoTrue minted the token, and no
later event can change it. Recovery does everything it can — `auth.admin.mfa.deleteFactor`, then an
explicit `POST /auth/v1/logout?scope=global` — but both act on **refresh** tokens and factor rows. An
already-issued **access** token is unrevokable by construction, and on this project its lifetime is
**3600 s**.

So for up to an hour after a user says *"I lost my authenticator, lock it out"*, the device holding
the old token kept full access to the exact estate totals and holdings that AAL2 exists to protect.
The window is open precisely in the scenario recovery exists for.

### Two things this is not

- **Not "refresh-token revocation is immediate access revocation".** It is not. The refresh token is
  revoked immediately and the access token is unaffected; calling the first the second is the
  conflation that let this sit unnoticed.
- **Not fixable by a shorter JWT lifetime.** That shrinks the window, never closes it, and taxes
  every request in the product to do so.

## The gates that were affected

| gate | route | mutating? | protects |
|---|---|---|---|
| `admin_require_gate` | `require_aal2()` | — | the whole admin/operator surface |
| `connections` | `require_aal2()` | yes | linking a financial account |
| `get_connection_access_token` | `require_aal2()` | read | a provider access token |
| `get_estate_net_worth` ×2 | `require_aal2()` | **read** | the exact estate total |
| `invitation_write_gate` | `require_aal2()` | yes | invitation writes |
| `list_estate_assets` ×2 | `require_aal2()` | **read** | exact balances and holdings |
| `connections_require_aal2` | **RESTRICTIVE RLS policy** | both | direct-query path |
| `normalized_assets_require_aal2` | **RESTRICTIVE RLS policy** | both | direct-query path |

★ **The two policies are the part a function-only fix would have missed.** Migration 0010 created
them with `coalesce(auth.jwt() ->> 'aal','aal1') = 'aal2'` **inlined** — their own copy of the rule.
Hardening `require_aal2()` alone would have left the direct-query path exactly as open as before, and
every audit pointed at the function would have reported success.

## The fix

One predicate, `public.aal2_is_current()`, consulted by both routes. Three legs:

| leg | requires | fires when |
|---|---|---|
| 1 | the token claims `aal2` | the caller never stepped up |
| 2 | `auth.sessions` row exists, belongs to this user, is not past `not_after` | **global logout / recovery** |
| 3 | a `verified` row in `auth.mfa_factors` for this user | **factor removal** — recovery, admin reset, self-unenrol |

Legs 2 and 3 fail **independently**; either alone closes the measured window. Both are kept because
they close it for different reasons, and one mechanism that is a single platform change away from
being wrong is not defence in depth.

Design points that are load-bearing:

- **`SECURITY DEFINER`.** `auth.sessions` and `auth.mfa_factors` are not readable by `authenticated`,
  and the two RESTRICTIVE policies are evaluated *as* that role — an invoker-rights predicate would
  raise `permission denied` there instead of answering, turning a deny into a 500. It takes **no
  arguments**, so a caller cannot aim it; it answers one question about its own request.
- **`EXECUTE` is granted to `anon` too**, because those policies carry no `TO` clause and so are
  evaluated for `anon` as well. Without the grant, anon's refusal arrives as a function-permission
  error rather than a clean deny.
- **Called from a policy as `(select public.aal2_is_current())`.** Wrapped in a scalar subquery the
  planner evaluates it once per statement as an InitPlan; bare, it is a STABLE call in a qual and runs
  **per row**. On `normalized_assets` that is two index lookups versus two per asset.
- **Every refusal is the same `mfa_required` / `42501`.** The client already maps it, so the fix needs
  **no mobile release**, and the holder of a stale token is not told which server-side fact defeated
  them — that is information about another device's state.

## How it is proven

`db/tests/aal2_session_currency_authorization.sql`, run by `npm run test:sql-auth` against a
throwaway Postgres container. **481 assertions, exit 0** (baseline before the change: 469).

```
ok   the currency predicate is loaded, DEFINER, and the gate delegates to it
ok   ★ a FRESH, currency-backed AAL2 session reads the exact total (21900000)
ok   ★ a revoked SESSION defeats a retained aal2 token
ok   ★ a removed FACTOR defeats a retained aal2 token, independently
ok   an UNVERIFIED factor does not satisfy the gate
ok   ★ THE MEASURED CASE: post-recovery state refuses the pre-recovery token
ok   ★ and the same token works again once the server state is restored
ok   five claim-shape legs fail closed, and the valid caller still passes
ok   ★ the RESTRICTIVE policy path denies a stale token too (0 rows, no error)
ok   and the policy path admits the owner again once currency is restored
ok   the sentinel is unchanged: mfa_required / 42501, identical for every leg
ok   policy dropped, every fixture row removed, claims reset
```

★ **Every refusal is bracketed by the same call succeeding.** §1 establishes the positive control (an
exact total of 21900000), each scenario breaks exactly one fact, and §2e restores it and requires the
original success back. A suite of refusals alone would be equally green with a broken fixture — a
missing estate, a non-owner caller or an unloaded function all refuse too.

### Mutation-proven

Seven mutations in `scripts/mutateSqlAuthorization.mjs`, each restoring one piece of the defect. The
first restores the pre-0064 gate character for character; if it survived, the suite would be proving
nothing about the fix it is named for.

## A coverage gap this uncovered

The harness granted `authenticated` **no privilege** on `public.normalized_assets`, while
`100_grants.sql:907` grants `SELECT, INSERT, DELETE`. So every direct query as `authenticated` raised
`permission denied for table` long before any policy was consulted — meaning **migration 0010's
restrictive AAL2 policy had never been exercised by this suite at all.** Not a weak assertion about
the direct-query path: no assertion, with a table privilege hiding it. A permission error and a policy
denial are both "nothing reached me" from the outside, and only one of them is authorization.

The preamble now mirrors the deployed privilege exactly — not `ALL`, which would also hand
`authenticated` an `UPDATE` production withholds and let a future assertion pass on a privilege that
does not exist.

## What remains, and who can do it

1. **Apply 0064 to nonprod**, then re-run the live probe and record that the stale token is now
   refused and a fresh AAL2 session still succeeds. That needs hosted SQL execution, which is not
   authorized in this unit — the container proof stands in for it until then, and is not the same
   claim.
2. **Then production.** Until both are applied, MFA recovery should be treated as "the factor is
   gone and no new token can be obtained", not as "existing access is revoked".
