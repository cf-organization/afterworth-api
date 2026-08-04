# Owner invitation management — backend design and decision record

Starting SHA `6ab72e0` · branch `feature/owner-invitations-backend` · migration `0042`.

Recon verified directly against `db/tables/`, `db/migrations/`, `db/functions/`, `api/`, and
`vercel.json`. The mobile repo's requirement docs were treated as input and re-verified here.

---

## 1 · Recon findings

| Object | Type | Defined in | Signature / shape | Caller | Authorization | Gap |
|---|---|---|---|---|---|---|
| `public.invitations` | table | `db/tables/invitations.sql` | see §2 | RPC only | RLS on, **no client grant** | no owner read path |
| `create_invitation` | fn | `0016` | `(estate,kind,role,email,phone,showEstate,showInviter,days) → (invitation_id, raw_token, fingerprint, expires_at)` | operator console | `invitation_write_gate` | **returns raw token** |
| `revoke_invitation` | fn | `0016` | `(invitation_id) → void` | operator console | `invitation_write_gate` | needs an id no owner can obtain |
| `extend_invitation` | fn | `0016` | `(invitation_id, days) → (id, expires_at)` | operator console | `invitation_write_gate` | same |
| `invitation_write_gate` | fn | `0016` | `(estate) → void` | internal | auth → **owner OR admin** | see D2 |
| `admin_list_invitations` | fn | `0018` | admin listing | console | `admin_require_gate` | not owner-callable |
| `invitation_preview` / `bind_invitation_token` / `accept_invitation` / `decline_invitation` / `resolve_membership` | fns | various | recipient consume path | mobile + console | own gates | **must not regress** |
| `storage_deletion_outbox` | table | `0039` | outbox precedent | cron | RLS on, `service_role` only | reused as the model |
| `/api/claims/drain_purge_outbox` | cron | `vercel.json` | daily 04:00, `CRON_SECRET` | Vercel | service-role client | delivery worker precedent |

**No email provider exists anywhere** — no `nodemailer`, `sendgrid`, `postmark`, `resend`, SES,
`mailgun`, or SMTP dependency in `package.json`, `api/`, or `lib/`. **No `pgsodium` or Supabase
Vault**, so encrypting a secret at rest is not available either. Both facts drive D3.

---

## 2 · Current data model

`public.invitations` already carries: `id, estate_id, invited_by, kind, proposed_role, status,
expires_at, invitee_email, invitee_phone, accepted_by, accepted_at, created_at, updated_at,
token_hash, estate_display_name, inviter_display_name, invitee_email_hint, invitee_phone_hint,
preview_visibility`.

Constraints already present:

- `kind ∈ (beneficiary, professional_delegate, executor, trustee)`
- **`proposed_role ∈ (beneficiary, professional_delegate)`** — ownership and fiduciary roles are
  already unrepresentable as a granted role. Invariants 14–17 hold at the schema level.
- `status ∈ (pending, matched, accepted, declined, expired, revoked)`
- `token_hash text NOT NULL` — one-way SHA-256 hex. The table's own header states the hard rule:
  *"the raw token is NEVER stored"*, and the fingerprint is **derived at read**, not a column.

**Missing for owner management:** `declined_at`, `revoked_at`, `revoked_by`, `extended_at`,
`extended_by`. Added in 0042. Deliberately **not** added: `delivered_at`, `opened_at`, `viewed_at`
— nothing can confirm them truthfully.

★ The table header also warns: *"`expired` is a stored status value AND a read-time
`expires_at < now()` derivation — filter BOTH in any listing."* Every function in 0042 honours this
through one shared projection helper.

---

## 3 · Decisions

### D1 · Terminal-status listing — **Option B (active + bounded history)**

`list_estate_invitations` returns actionable invitations **plus terminal ones settled within 90
days**, newest first, hard-capped at 100 rows.

Rationale: an owner needs to distinguish *"they declined"* from *"I never invited them"*, which
Option A cannot express. Option C is unbounded and inappropriate for a mobile payload. 90 days
matches the invitation lifetime ceiling already enforced by `extend_invitation`, so no new
retention concept is introduced.

- **Statuses returned:** all six, with `expired` **projected** — a `pending`/`matched` row past
  `expires_at` reports `expired` even though its stored status has not been rewritten.
- **Ordering:** `created_at desc, id desc` (id breaks ties deterministically for paging).
- **Limit:** caller may request 1–100; default 50. No cursor in this migration — with a 90-day
  window and a 20-active cap, the realistic ceiling is far below 100. A cursor can be added
  additively if that stops being true.
- **Recipient metadata on terminal rows:** the **masked hints only**, exactly as for active rows.
- **Unauthorized:** raises, never returns empty. An empty result must mean *no invitations*.

### D2 · ★ Ownership only — platform admin is NOT an owner here

The existing `invitation_write_gate` authorizes **owner OR admin**. The new consumer-mobile
functions use `is_estate_owner` **alone**.

This is a deliberate divergence, required by invariant 3. `invitation_write_gate` exists for the
operator console, where admin authority is the point. Reusing it for a mobile contract would let
platform-admin status silently confer estate-owner authority over a customer's estate through a
consumer path — a different and much weaker trust boundary. The console keeps its gate; the phone
gets ownership only.

### D3 · ★ Token custody — the secret is minted at DELIVERY, not at creation

Constraints: the raw token must never be returned to the client (invariant 6), never stored in
plaintext (invariant 7), and there is no encryption-at-rest primitive available. But a delivery
worker must eventually possess a raw token to build a link.

**Resolution:** the outbox carries **no secret at all** — only an `invitation_id`. A trusted worker
calls `issue_invitation_delivery(p_outbox_id)`, granted to `service_role` **only**, which mints a
fresh 256-bit token, stores only its SHA-256 hash, and returns the raw token to that caller
transiently. The secret therefore exists only in the worker's memory, never at rest and never in a
client-reachable function.

Consequences, all desirable:

- `create_estate_invitation` stores a hash of a **discarded** random value, so the invitation is
  created but **not yet usable**. An invitation nobody has been told about cannot be accepted —
  fail-closed by construction.
- **Redelivery is token rotation for free.** Issuing again mints a new token and overwrites the
  hash, so the previous link stops working. That is the correct security behaviour and needs no
  separate revocation step.

### D4 · Delivery is QUEUED, never claimed as sent

`delivery_state` is projected from the newest outbox row and is one of `queued`, `issued`,
`failed`, or `none`. **`delivered` does not exist**, because nothing can confirm it. The API and
UI may say *created* and *queued for sending*; they may never say delivered, received, opened, or
viewed.

### D5 · Duplicate policy — atomic expiry sweep, then a partial unique index

A partial unique index cannot reference `now()` (not immutable), so time alone cannot define
"active". Instead:

- a partial unique index on `(estate_id, lower(invitee_email), proposed_role)` where
  `status in ('pending','matched')`;
- `create_estate_invitation` **first** expires the estate's overdue rows in the same transaction
  (`status → 'expired'` where `expires_at < now()`), **then** inserts.

So a genuinely stale invitation never blocks a re-invitation, while a live one does. The same
recipient may hold one beneficiary **and** one professional-delegate invitation, because
`proposed_role` is part of the key — the two are different relationships, and the schema already
treats them as distinct.

### D6 · Extend — included, owner-scoped

`extend_invitation` already exists and proves the product policy. 0042 adds
`extend_estate_invitation(p_estate, p_invitation, p_days)` so the mobile contract is
ownership-gated (D2) and estate-scoped like its siblings. The server computes the new expiry from
an interval and caps it at `created_at + 90 days`; the client never supplies a timestamp, so an
"extend" can never shorten.

### D7 · Redelivery — included, because it is now implementable

Rejected in the earlier mobile recon because there was nothing to deliver *with*. With the outbox
and D3's issue-time minting, `request_invitation_redelivery` is a truthful operation: it enqueues,
the worker rotates and sends, and `can_redeliver` reports whether an actionable invitation exists.
It is **not** called "resend" — nothing is re-sent; a new secret is issued.

---

## 4 · What this migration does NOT do

- **It does not send anything.** SQL cannot. A worker (§API/worker work) must be written and
  deployed before any invitation reaches a recipient.
- It does not change `create_invitation`, `revoke_invitation`, `extend_invitation`, or any
  recipient function. All are left byte-identical so the operator console and the pending mobile
  recipient PR are unaffected.
- It does not weaken RLS or add any client grant on `invitations`.
