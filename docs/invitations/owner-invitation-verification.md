# Migration 0042 — verification and security proofs

## Static proofs (run in this repository, no database required)

Executed against the migration source; all passed.

| Proof | Result |
|---|---|
| No function granted to `authenticated` returns `raw_token` | ✓ — only `issue_invitation_delivery` and `record_invitation_delivery_failure` return/handle it, both `service_role` only |
| Every SECURITY DEFINER function sets `search_path` **and** revokes from `PUBLIC` | ✓ — 9 of 9 |
| No raw token is written to any table | ✓ — `v_raw` is returned, never inserted or updated into a column |
| No client grant added to `public.invitations` | ✓ |
| No `delivered_at` / `opened_at` / `viewed_at`, and no `'delivered'` state | ✓ — only `none, queued, issued, failed` |
| Single balanced transaction, balanced `$function$` delimiters | ✓ |

## Runtime assertions

`db/verification/0042_owner_invitation_verification.sql` — 8 sections, rolls back at the end:

1. **Authorization** — non-owner and cross-estate **raise**, never return empty.
2. **Create** — queued (not sent); no token OUT parameter; executor/owner roles rejected;
   duplicate active rejected; same recipient may hold one invitation *per role*; self-invitation
   rejected; one outbox row per invitation.
3. **Expiry sweep** — a stale invitation does not permanently block re-invitation.
4. **List** — no token or hash exposed; masked hints only; closed status vocabulary;
   `delivery_state` never claims delivered; action flags derive from **effective** status.
5. **Revoke** — authoritative, idempotent, cancels queued delivery, cross-estate indistinguishable
   from not-found.
6. **★ Token custody** — `authenticated` cannot call `issue_invitation_delivery`; issuing rotates
   the hash so any prior link dies; only the hash is stored; the raw token is never persisted.
7. **Recipient regression** — every recipient function still exists; the console's original
   `create_invitation` is untouched.
8. **Privileges/RLS** — RLS on the outbox; zero `authenticated`/`anon` grants on either table; the
   worker surface is `service_role` only.

## ★ Not yet validated

**The migration has not been executed.** No local Supabase environment is configured in this
repository, and no environment was improvised. Everything above marked *runtime* is written and
reviewable but **unrun** until applied to a disposable non-production project.

Also unvalidated: concurrency behaviour under genuine parallel load (the unique indexes and
`for update` locks are designed for it, but only a real database proves it), and delivery
end-to-end (no worker or email provider exists).

## Evidence hygiene

The harness uses generated UUIDs and `@verify.test` addresses only. No production identifier,
email, token, or project reference appears in any committed file.
