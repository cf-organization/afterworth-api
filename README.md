# afterworth-api

Vercel edge function routes for the AfterWorth iOS app.

## Routes

- `POST /api/invitations/preview` - Public. Preview an invitation before signup.
- `POST /api/invitations/bind` - Auth required. Bind an invitation to the current user.
- `POST /api/invitations/resolve` - Auth required. Resolve membership from email or phone.

## Environment Variables

Required in Vercel project settings:

- `SUPABASE_URL` - `https://yiaavvkulrpqkkbqhwit.supabase.co`
- `SUPABASE_PUBLISHABLE_KEY` - `sb_publishable_...` (used by all routes)
- `SUPABASE_SECRET_KEY` - `sb_secret_...` (reserved for server-only operations; not yet used)

## Local Development

Install dependencies:

```sh
npm install
```

Run type checks:

```sh
npm run type-check
```
