# Database functions (source of truth)

These RPCs live in the Supabase Postgres database and are invoked from the Vercel
routes (or directly via PostgREST `rpc` with the caller's JWT). The database is the
live source, but these `.sql` files are the version-controlled source of truth: if the
database is reset or recreated, re-apply each file (they are `CREATE OR REPLACE`, so
they are safe to re-run).

| Function | Called by | Auth |
|---|---|---|
| `resolve_membership(p_email, p_phone)` | `api/invitations/resolve.ts` | JWT (auth.uid) |
| `bind_invitation_token(p_token)` | `api/invitations/bind.ts` | JWT (auth.uid) |
| `invitation_preview(p_token)` | `api/invitations/preview.ts` | none (anon) |
| `accept_invitation(p_invitation_id)` | `api/invitations/accept.ts` | JWT (auth.uid) |
| `decline_invitation(p_invitation_id)` | `api/invitations/decline.ts` | JWT (auth.uid) |
| `create_document_grant(...)` | PostgREST `rpc` (JWT) — Vault grant mgmt | JWT (auth.uid) |
| `revoke_document_grant(p_grant_id)` | PostgREST `rpc` (JWT) — Vault grant mgmt | JWT (auth.uid) |

## Re-applying
Paste each file into the Supabase SQL editor and run, or use the Supabase CLI
if/when migrations are adopted.

## Notes
- All are `SECURITY DEFINER` with `search_path` pinned to `public, extensions`, and
  gate on `auth.uid()`. The grant RPCs additionally re-check `is_estate_owner()`
  explicitly as their first step — SECURITY DEFINER bypasses RLS, so that owner-check
  IS the access boundary (see each file's header).
- Invitation RPCs depend on: `public.estates`, `public.estate_memberships`,
  `public.invitations`, `public.profiles`, `public.is_ownership_role(...)`,
  `public.write_audit(...)`, and the trigger `estates_ensure_primary_user_membership`.
- Grant RPCs depend on: `public.access_grants` (+ its `enforce_grant_ceiling` trigger,
  `document_grantable()`, and unique indexes — see `db/migrations/0002_*`),
  `public.documents`, `public.estate_memberships`, `public.is_estate_owner(...)`,
  `public.is_ownership_role(...)`, `public.write_audit(...)`.
- Error codes use PostgREST-mapped SQLSTATEs (`42501`→403, `23505`→409, `P0001`→400);
  custom `Pxxxx` codes return HTTP 500 (PostgREST does not map them) — don't use them.
- A redundant `preview_invitation_token` function was created during development
  and dropped in favor of `invitation_preview`. Do not recreate it.
