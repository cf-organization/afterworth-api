# Database functions (source of truth)

These RPCs live in the Supabase Postgres database and are invoked from the
Vercel routes under `api/invitations/`. The database is the live source, but
these `.sql` files are the version-controlled source of truth: if the database
is reset or recreated, re-apply each file (they are `CREATE OR REPLACE`, so they
are safe to re-run).

| Function | Called by | Auth |
|---|---|---|
| `resolve_membership(p_email, p_phone)` | `api/invitations/resolve.ts` | JWT (auth.uid) |
| `bind_invitation_token(p_token)` | `api/invitations/bind.ts` | JWT (auth.uid) |
| `invitation_preview(p_token)` | `api/invitations/preview.ts` | none (anon) |

## Re-applying
Paste each file into the Supabase SQL editor and run, or use the Supabase CLI
if/when migrations are adopted.

## Notes
- All three are `SECURITY DEFINER` with `search_path` pinned to `public, extensions`.
- They depend on: `public.estates`, `public.estate_memberships`,
  `public.invitations`, `public.profiles`, `public.is_ownership_role(...)`,
  `public.write_audit(...)`, and the trigger
  `estates_ensure_primary_user_membership`.
- A redundant `preview_invitation_token` function was created during development
  and dropped in favor of `invitation_preview`. Do not recreate it.
