# Owner invitation — API contract

Backed by migration `0042`. All five owner functions are **direct PostgREST RPCs**; no Vercel
endpoint is added, matching how `0016` and the claims/designation RPCs already reach the client.

## Authorization

Every owner function calls `estate_owner_gate(p_estate)` → `auth.uid()` present **and**
`is_estate_owner(p_estate)`. **Platform admin is not sufficient** (design record D2). The client
renders owner UI; the server decides.

## Functions

### `list_estate_invitations(p_estate uuid, p_limit int = 50)`

Actionable invitations plus terminal ones settled within 90 days, `created_at desc`, 1–100 rows.

Returns per row: `invitation_id, kind, proposed_role, status, invitee_email_hint,
invitee_phone_hint, token_fingerprint, created_at, expires_at, accepted_at, declined_at,
revoked_at, delivery_state, can_revoke, can_extend, can_redeliver`.

- `status` is the **effective** status — a `pending` row past `expires_at` reports `expired`.
- `delivery_state ∈ (none, queued, issued, failed)`. **There is no `delivered`.**
- Never returned: raw token, `token_hash`, `invitee_email`, `invitee_phone`, `invited_by`,
  `accepted_by`, `revoked_by`.

### `create_estate_invitation(p_estate, p_proposed_role, p_invitee_email?, p_invitee_phone?, p_show_estate_name?, p_show_inviter_name?, p_expires_in_days?)`

Returns `invitation_id, token_fingerprint, expires_at, delivery_state` — **no token**.

### `revoke_estate_invitation(p_estate, p_invitation)` → `invitation_id, status, revoked_at`

Idempotent on already-revoked. Cancels any queued delivery.

### `extend_estate_invitation(p_estate, p_invitation, p_expires_in_days = 14)` → `invitation_id, expires_at`

Interval, never a timestamp — an extend can never shorten. Capped at `created_at + 90 days`.

### `request_invitation_redelivery(p_estate, p_invitation)` → `invitation_id, delivery_state`

Enqueues. The secret is rotated at drain time, so the previous link stops working.

## Error → sanitized code

| Raised | SQLSTATE | HTTP | Sanitized code |
|---|---|---|---|
| `auth_required` | 42501 | 401 | `unauthenticated` |
| `owner_required` | 42501 | 403 | `forbidden` |
| `invitee_contact_required` | P0001 | 400 | `invalid_request` |
| `role_not_supported` | P0001 | 400 | `role_not_supported` |
| `invalid_expiry` | P0001 | 400 | `invalid_request` |
| `cannot_invite_self` | P0001 | 400 | `cannot_invite_self` |
| `already_member` | P0001 | 409 | `already_member` |
| `active_invitation_exists` | P0001 | 409 | `active_invitation_exists` |
| `pending_invitation_cap` | P0001 | 429 | `invitation_cap_reached` |
| `extension_would_not_lengthen` | P0001 | 400 | `invalid_request` |
| `invitation_not_found` | P0002 | 404 | `invitation_not_found` |
| `invitation_lifetime_exceeded` | P0003 | 409 | `invitation_lifetime_exceeded` |
| `redelivery_rate_limited` | P0004 | 429 | `rate_limited` |
| `invitation_not_actionable` | P0005 | 409 | `invitation_not_actionable` |

★ `42501` covers **two** outcomes and `P0001` covers **six**, so SQLSTATE alone cannot classify —
the message prefix is the discriminant. Raw Postgres text must never reach a response body.

★ **A cross-estate or unknown invitation returns the same `invitation_not_found`**, so an owner
cannot probe for another estate's invitations.

## Copy rules

Permitted: *"Invitation created."* · *"Queued for sending."*
**Forbidden:** delivered · sent · received · viewed · opened · *"they'll get an email"*.

## Rate limiting

No Vercel limiter applies (PostgREST). DB-resident throttles: **20 active invitations per estate**
(`pending_invitation_cap`) and **3 delivery requests per invitation per hour**
(`redelivery_rate_limited`). Both surface as errors, not 429 + `Retry-After`, so no `Retry-After`
handling is required client-side.
