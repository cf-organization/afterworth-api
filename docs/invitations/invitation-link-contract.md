# Invitation link contract — backend recon

Branch `feature/invitation-link-resolution`, stacked on `feature/invitation-delivery-worker`
(PR #35, which is itself stacked on `feature/owner-invitations-backend`, PR #34).
Starting SHA `81d33a6`. 0042 and 0043 are both **applied** to the live database.

Recon performed against the migration files, the captured function sources in `db/functions/`, the
live PostgREST schema, and `api/invitations/[action].ts`. Nothing here is inferred from
documentation alone.

---

## ★ The finding that changes the design

**The raw invitation token is not required for authorization, and never was.**

`accept_invitation(p_invitation_id)`, `decline_invitation(p_invitation_id)` and
`bind_invitation_token(p_token)` all enforce the *same* identity guard and all provision through
the *same* helper:

```sql
-- identical in all three functions
if not ((v_inv.invitee_email is not null and lower(v_inv.invitee_email) = lower(coalesce(v_user_email,'')))
     or (v_inv.invitee_phone is not null and v_inv.invitee_phone = coalesce(v_user_phone,''))) then
  raise exception 'invitation_not_for_caller' using errcode = 'P0006';
end if;
...
v_membership_id := public.provision_from_invitation(v_inv.id, v_user);
```

The authority is **the authenticated caller's verified email or phone matching the invitee**, not
possession of the token. A caller holding a perfectly valid token but signed in as the wrong person
is refused with P0006 — the token buys them nothing.

Consequences, all of which shrink this slice's attack surface:

- After authentication, the token grants **no capability the identity does not already grant**.
- `POST /api/invitations/resolve` already returns `pendingInvitations` matched by the caller's own
  identity, so an authenticated recipient can find, review, accept and decline their invitation
  **without the token ever leaving the link**.
- The token's only unique power is **pre-authentication disclosure** via `invitation_preview` —
  which §6 of this slice's brief explicitly forbids.

So the token is a *routing hint*, not a credential, from the moment authentication completes. That
is the safest possible custody model: the secret can be destroyed at the earliest point in the
flow rather than carried through sign-up, email confirmation and MFA.

---

## The eleven recon questions

> ⚠️ **Read Q1, Q2, Q5, Q6 and Q7 as a record of what was FOUND, not as the shipped design.** They
> describe 0043's token-bearing delivery path as it existed at recon time. The confirmed
> architecture is **token-free** — migration 0044 replaced the issue step, the link carries no
> secret, and `INVITATION_LINK_BASE_URL` is `https://app.afterworth.com/invitations` with nothing
> appended. See `invitation-link-architecture.md`. This section is preserved because the reasoning
> that led to the change is the reasoning that justifies it.

### 1 · Does 0043 require a secret-bearing link?

**Yes, as currently written.** `issue_invitation_delivery_token()` mints a 64-hex-character secret,
stores only `sha256(raw)` in `invitations.token_hash`, and returns the raw value transiently to the
worker. The worker composes `INVITATION_LINK_BASE_URL` + the token. There is no token-free
recipient entry point to link to today.

The link must therefore carry the secret. What this slice controls is how briefly the app holds it.

### 2 · Exact token parameter name and URL shape

**Not yet fixed by any deployed contract** — `INVITATION_LINK_BASE_URL` is unset, and
`lib/invitations/delivery.ts` composes `${base}?token=${encodeURIComponent(rawToken)}`.

That query-string shape is **rejected** by this slice (see the architecture record): query strings
land in Referer headers, server access logs, and browser history. The final shape is a single path
segment. `delivery.ts` must be updated accordingly — it is unreleased and unconfigured, so this is
a free change.

### 3 · Is the raw token verified through an existing endpoint or RPC?

**Yes, two of them**, both already live:

| Surface | Auth | Consumes token? | Discloses |
|---|---|---|---|
| `invitation_preview(p_token)` via `POST /api/invitations/preview` | **anon** | No | estate name, inviter name, role, masked email/phone hint, expiry, revoked flag |
| `bind_invitation_token(p_token)` via `POST /api/invitations/bind` | JWT | **Yes — it accepts** | membership, estate id, role |

### 4 · Does verification consume the token, or only inspect it?

- `invitation_preview` — **inspects only.** Hashes, looks up, returns display-safe fields. Returns
  an empty set for an unknown token, so existence does not leak. Does not raise on expired/revoked;
  it reports them as booleans.
- `bind_invitation_token` — **consumes and accepts in one operation.** It sets
  `status = 'accepted'`, stamps `accepted_by`/`accepted_at`, and calls `provision_from_invitation`.

There is no "verify without accepting" token operation. **A token-based flow therefore cannot offer
a decline**, because declining requires an invitation id that the token path never exposes
(`invitation_preview` returns a fingerprint, not an id).

That alone rules out building the review/accept/decline UI on the token.

### 5 · Which operation makes the token one-time-use?

`bind_invitation_token`, transitively. Once `status = 'accepted'`, a second bind by the same user
is an idempotent self-heal, and by a *different* user raises P0005 `invitation_already_accepted`.

The hash is also invalidated by:
- **reissue** — `issue_invitation_delivery_token` overwrites `token_hash`, killing the prior link;
- **revoke** — `revoke_estate_invitation` sets `status='revoked'`; bind raises P0004;
- **expiry** — `expires_at < now()`; bind raises P0003.

Note the asymmetry: revocation and expiry do not *erase* the hash, they gate on status and time.

### 6 · Can the token survive an authentication redirect without persistence?

**It does not need to.** Per the finding above, once the recipient is authenticated the token is
redundant — their pending invitations resolve by identity. The token survives only from link
capture until authentication completes, in process memory, and is destroyed there.

### 7 · Must continuation survive process death?

**No.** Since the token is destroyed at authentication anyway, losing it to a process kill during
sign-up costs the recipient nothing but a tap: they reopen the email link, or simply sign in — their
invitation is waiting in `pendingInvitations` regardless. The link remains valid (default 14 days,
extendable to 90).

This removes the entire reason to consider encrypted token persistence. No approval is being sought
for it, and none is needed.

### 8 · Which link platforms are required now?

| Platform | Required now | Why |
|---|---|---|
| HTTPS web fallback | **Yes** | The recipient may open the email on a device with no app installed. This is the common case for a first-time invitee. |
| iOS universal link | Yes, for production | Custom schemes can be claimed by any app; an invitation link must not be hijackable. |
| Android App Link | Yes, for production | Same reasoning, plus Android will not auto-verify without `assetlinks.json`. |
| Custom scheme (`afterworth://`) | **Development and simulator only** | Already configured (`app.json` → `scheme: "afterworth"`). Must not be the production security boundary. |

**Current state: none of the universal/app-link plumbing exists.** `app.json` has no
`ios.associatedDomains` and no `android.intentFilters`, and the mobile repo contains **no deep-link
handling code at all** — no `expo-linking` usage, no `getInitialURL`, no `useURL`.

### 9 · Is there an existing web deployment that can host a landing/fallback route?

**Yes — the backend Vercel project itself.** `afterworth-api` deploys with `framework: null`,
`buildCommand: null`, `outputDirectory: null`, and has no `public/` directory today.

### 10 · Can that deployment serve a landing page without increasing the function count?

**Yes.** Vercel counts *Serverless Functions* — files under `api/` — toward the Hobby limit of 12,
which this deployment is exactly at. Files under `public/` are served as **static assets** and cost
no function slot. A static `public/invitations/index.html` plus a `vercel.json` rewrite therefore adds a
landing surface at **zero function cost**.

The same mechanism serves the two link-verification files, which must be static and
`Content-Type: application/json`:
- `/.well-known/apple-app-site-association`
- `/.well-known/assetlinks.json`

### 11 · What should `INVITATION_LINK_BASE_URL` be?

Proposed, **not to be set until the route is deployed and returns 200**:

```
INVITATION_LINK_BASE_URL=https://app.afterworth.com/invitations
```

producing `https://app.afterworth.com/invitations`.

`mail.minifam.com` is deliberately **not** reused as the clickable origin: it is the Resend sending
domain, its DNS is owned by mail authentication (SPF/DKIM/DMARC), and binding an Apple associated
domain to it would couple two unrelated trust decisions.

---

## Additional contract facts this slice must respect

- **Rate limits.** `invitationPreview` is Tier 1 / fail-closed, IP-keyed, 30/min — the only
  IP-keyed bucket, because it is the sole unauthenticated invitation surface. `bind` is Tier 1,
  `user+ip`, 10/min. Any new action needs its own registry row; **an unregistered bucket denies
  every request** (`lib/rateLimit.ts` fails closed on unknown buckets).
- **Dispatcher.** `api/invitations/[action].ts` serves POST `{accept, bind, decline, preview,
  resolve, create_owner}` and GET `{drain_email_outbox}`. Adding an action costs no function slot.
- **Not-found indistinguishability.** `invitation_preview` returns an empty set for an unknown
  token; `bind` raises P0002. Both must stay indistinguishable from "not for you" at the API edge.
- **Audit events.** `invitation.bound` (token path), `invitation.accepted` / `invitation.declined`
  (id path), `invitation.delivery_issued` / `invitation.delivery_outcome` (0043). All record a
  12-char fingerprint of the **hash**, never the token.
- **Delivery generation.** Reissue increments it and invalidates the previous link. A recipient
  holding an older link after a reissue gets P0002, indistinguishable from a bad token.

---

## What this recon rules out

1. **Building review/accept/decline on the token.** There is no token-based decline, and no
   token-based "inspect while authenticated". The existing id-based facade (mobile PR #21) is the
   only complete surface, and it is already authoritative.
2. **Pre-authentication disclosure.** `invitation_preview` would satisfy a "show them what they're
   accepting before sign-up" product goal, but §6 of the brief forbids exactly the fields it
   returns. It is left live and unused by this slice.
3. **Token persistence of any kind.** Nothing in the flow needs it once the token is understood as
   a routing hint rather than a credential.
