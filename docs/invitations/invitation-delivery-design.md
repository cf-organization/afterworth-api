# Invitation delivery — verified design and decision record

Branch `feature/invitation-delivery-worker`, based on `feature/owner-invitations-backend` (0042).
Migration `0043`. **0042 is applied to the live database and is treated as immutable history — it is
neither edited nor reapplied here.**

---

## 1 · Three-way comparison

### 1a · Repository 0042 vs deployed 0042 — IDENTICAL

Verified against the live PostgREST schema (service-role OpenAPI introspection), not assumed.

| Object | In repo file | Deployed | Verdict |
|---|---|---|---|
| `invitation_delivery_outbox` | 10 columns | same 10 columns, same order | match |
| `invitation_effective_status(text,timestamptz)` | yes | yes | match |
| `estate_owner_gate(uuid)` | yes | yes | match |
| `list_estate_invitations(p_estate,p_limit)` | yes | same arg names | match |
| `create_estate_invitation(7 args)` | yes | same arg names | match |
| `revoke_estate_invitation(p_estate,p_invitation)` | yes | same | match |
| `extend_estate_invitation(p_estate,p_invitation,p_expires_in_days)` | yes | same | match |
| `request_invitation_redelivery(p_estate,p_invitation)` | yes | same | match |
| `issue_invitation_delivery(p_outbox_id)` | yes | same | match |
| `record_invitation_delivery_failure(p_outbox_id,p_error)` | yes | same | match |

`invitation_delivery_outbox` currently holds **zero rows**. No backfill or data migration is needed
for the status-vocabulary change in §3, and none is written.

### 1b · Deployed 0042 vs the required worker contract — the gaps

| Required | 0042 today | Gap |
|---|---|---|
| Outcome vocabulary `queued/processing/providerAccepted/outcomeUncertain/retryPending/failedPermanent/cancelled` | CHECK allows only `pending/issued/failed` | **0043** |
| Delivery generation for idempotency keying | absent | **0043** |
| Deterministic provider idempotency key persisted | absent | **0043** |
| Provider message id (server-confined) | absent | **0043** |
| Sanitized failure classification | free-text `last_error` only | **0043** |
| Bounded retry limit + retry scheduling | absent | **0043** |
| Batch claim with `for update skip locked` | single-row by id only | **0043** |
| Oldest queued / retry-pending age on the heartbeat | absent | **0043** |
| Atomic invitation + outbox insert | **already atomic** — both inserts are inside `create_estate_invitation`'s single transaction | none |
| RLS on, no authenticated grants on the outbox | already correct | none |
| Recipient email server-confined | already correct (`issue_invitation_delivery` is `service_role` only) | none |

### 1c · ★ The token-issuance finding that shapes everything

`issue_invitation_delivery()` **mints a new token and overwrites `invitations.token_hash` on every
single call.** Its own header states this as intended: *"Rotation is inherent: issuing again
overwrites the hash, so any previously issued link stops working."*

That is correct for a deliberate redelivery and **wrong for a retry**. Under the required contract a
cron retry must not rotate the token, so 0043 must split the fused operation in two:

- **claim** — mark a row `processing`, mint nothing;
- **issue** — mint a token, and only when a *new generation* is genuinely intended.

0042's function is left in place, unused by the new worker, rather than dropped — dropping it would
edit applied history and break nothing that exists. See D4.

---

## 2 · Decision records

### D1 · The raw token cannot be recovered after the worker's memory is gone

The database stores only `token_hash`. A raw token exists solely inside one worker invocation. This
is a hard constraint, not a preference, and it decides the retry model:

- A retry **inside the same invocation** can resend the identical link — the raw token is still in
  memory, and the same idempotency key applies.
- A retry **in a later invocation** cannot. The link is unreconstructable.

So a row left ambiguous by a dying process has exactly two honest futures: reconcile with the
provider, or sit in `outcomeUncertain` until an operator deliberately reissues. It must never
silently mint a second link, because that would invalidate a link that may already be in an inbox.

### D2 · Ambiguous ≠ failed

`outcomeUncertain` is a first-class terminal-ish state, not a retry state. It means the request left
this process and no acceptance was confirmed. The email may or may not have gone out. Nothing in the
system is permitted to describe it as either sent or failed.

`retryPending` is used only where the provider gave a *definitive* transient refusal (connection
refused before send, 429, explicit 5xx with no message id). Those are safe to retry with the same
generation and same key.

### D3 · Idempotency key derivation

```
afterworth/invitation/<outbox-id>/<delivery-generation>
```

Both components are server-side surrogate identifiers. Deliberately **not** derived from the raw
token (which would leak the secret into provider metadata) or the recipient email (which would leak
PII and collide across generations). Persisted on the row so a same-generation retry provably reuses
it rather than recomputing and hoping.

### D4 · 0042's `issue_invitation_delivery` is superseded, not dropped

0043 adds `issue_invitation_delivery_token`. The 0042 function keeps its grants and keeps working;
nothing calls it. Dropping it would be a destructive change to applied history for no benefit, and
its `service_role`-only grant means no client can reach it regardless.

### D5 · Cron is recovery, not delivery

The owner-create request makes **one bounded immediate attempt** after commit. The daily
`CRON_SECRET`-gated drain exists to recover rows that the immediate attempt never reached (process
died, provider down, deploy mid-flight). On the current free tier the drain runs daily, so a
recovered row can lag by roughly a day. That is stated plainly in the operator docs and never
papered over in user-facing copy.

### D6 · `providerAccepted` is the strongest claim available

Resend returning a message id means Resend accepted the message for delivery. It is not delivery,
receipt, opening, or viewing, and no column, response field, log line, or email sentence in this
change says otherwise. There is no `delivered` state anywhere, exactly as 0042 established.

### D8 · The ambiguous retry happens in-process, or not at all

The brief asks that an ambiguous response reuse the same idempotency key. That is only possible
while the raw token is still in memory, so the retry lives exactly there: **one** extra attempt,
same message, same key, inside the invocation that minted the token. If the first request did reach
Resend, the key makes the second a no-op instead of a second email.

Exactly one extra attempt. A second ambiguous answer means the network is genuinely unreliable, and
repeating cannot manufacture certainty.

Once that invocation returns, the option is gone with the token, which is why `outcomeUncertain` is
**not in the claim predicate**. No drain will ever pick such a row up, so no live link is ever
rotated by a schedule. Recovery is a deliberate human decision.

### D9 · A cron retry after a *definitive* refusal does mint a fresh token, and that is not rotation

`retryPending` is only ever set when the provider **answered and refused** (429, 5xx). Because it
answered, nothing was accepted and no link reached anyone. There is therefore no live link to
invalidate — and minting is unavoidable regardless, since the previous raw token died with the
previous invocation.

So the invariant the brief protects — never invalidate a link that may already be in an inbox — is
preserved exactly, while "do not rotate on every cron retry" is honoured in the only sense that can
be true here: the token is never rotated while a delivered-or-possibly-delivered link exists.

### D7 · No mobile resend/reissue surface

Reissue is a deliberate operator/owner action with real consequences — it invalidates a link that
may already be in someone's inbox. `request_invitation_redelivery` (0042) already exists as the
owner-initiated path and enqueues a fresh outbox row. No new mobile behaviour is invented here, and
afterworth-mobile is untouched by this change.

---

## 3 · The 0043 state machine

```
                    create_estate_invitation (0042, atomic)
                                 │
                                 ▼
                            [ queued ]
                                 │  claim_invitation_deliveries()  ── for update skip locked
                                 ▼
                          [ processing ]
                                 │  issue_invitation_delivery_token()  → generation += 1, token minted
                                 │  provider send with Idempotency-Key
        ┌────────────────┬───────┴────────┬──────────────────┐
        ▼                ▼                ▼                  ▼
[ providerAccepted ] [ retryPending ] [ outcomeUncertain ] [ failedPermanent ]
   terminal            next_attempt_at    terminal until      attempts >= cap
                       → claim again      operator acts       or permanent class
```

`cancelled` is entered from any non-terminal state when the invitation is found revoked, accepted,
declined, or expired at claim time.

---

## 4 · What this change does NOT do

- **Does not deploy.** No `vercel deploy`, no migration applied.
- **Does not invoke Resend.** No network call to the provider is made anywhere in this change,
  including in tests, which use an injected fake transport.
- **Does not send email.**
- **Does not modify afterworth-mobile.**
- **Does not add a Vercel function.** The deployment is at 12/12 on the Hobby limit; both new
  actions ride the existing `api/invitations/[action].ts` dispatcher. See §5.

## 5 · Function-count note (correcting the brief's premise)

The brief asked to *replace* `api/invitations/resolve.ts` with `api/invitations/[action].ts`. That
consolidation **already happened** — `api/invitations/resolve.ts` does not exist, and
`api/invitations/[action].ts` has served `{accept, bind, decline, preview, resolve}` since July.
There is no standalone route to remove. The invariant the brief is protecting still holds and is
asserted by test: the file count under `api/` is 12 before and after.
