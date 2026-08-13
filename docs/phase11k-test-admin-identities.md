# Phase 11 — synthetic operator test identities

> ## TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE
>
> Two accounts held by **one** person. They prove the *mechanism* refuses reviewer A and accepts a
> distinct reviewer B. They prove **nothing** about independent human judgement, which is the
> control's actual purpose.
>
> **LAUNCH REQUIREMENT: real production claim release requires two distinct human operators**, each
> holding their own credentials and their own MFA factor, neither able to authenticate as the other.
> Any drill run with these accounts must carry this heading in its evidence record.

---

## 1 · The record

| Field | Value |
|---|---|
| Prefixes | `AW_ADMIN_TEST_A_*`, `AW_ADMIN_TEST_B_*` |
| Purpose | Phase 11 operator-console verification and fire-drill preparation |
| Classification | **SINGLE-OPERATOR TEST MODE** |
| Created | 2026-08-13 |
| Retirement trigger | After the production fire drill, **or** when replaced by real independently-held human operator accounts — whichever comes first |
| Store | `afterworth-mobile/.env.test` — mode 600, ignored by a **committed** `.gitignore` rule (line 58), proven with `git check-ignore -v` |

Keys held per account: `_EMAIL`, `_PASSWORD`, `_TOTP_SECRET`, `_FACTOR_ID`, `_UID`.

**No uid appears in this file.** `db/seed_admin.sql` sets that rule — a real uid lives only in the
operator's executed SQL copy, the resulting `public.admins` row, and the mode-600 store. The
verifier prints the uids on demand when they are needed.

## 2 · How they were made, and what was deliberately not done

- Identities created through the **Auth Admin API** with `email_confirm`, so no inbox is required.
  Addresses derive from the store's own existing plus-addressing convention rather than an invented
  mailbox.
- Passwords from `crypto.randomBytes` — **CSPRNG, no fallback**. A load-bearing secret must never
  degrade to a guessable source, and a loud failure is safer than a quietly weakened credential.
- MFA through the **real Supabase enrolment path**: `POST /auth/v1/factors` → `challenge` → `verify`
  with a genuine RFC-6238 code computed in process. **No auth table was touched directly, no factor
  was marked verified by SQL, and `admin_require_gate()` was not weakened.** The seed is stored and
  never displayed, so no QR payload and no human transcription was involved.
- The TOTP generator is **self-tested against the RFC 6238 published vector** (`T=59 → 287082`)
  before it is used. A wrong implementation is indistinguishable from "the server rejected the code",
  and would have sent someone looking for a server fault.
- Every value was generated, used and stored in process. Nothing reached argv, a log, a clipboard, a
  screenshot, an `EXPO_PUBLIC_*` variable, or git.

## 3 · Posture: they carry no estate authority

`handle_new_user()` inserts **only** into `public.profiles` — it creates no estate, no membership,
no designation and no grant. So the "unavoidable bootstrap estate" case does not arise here: the
accounts consist of one `auth.users` row and one `profiles` row each.

Both sessions carry `role=authenticated`. **Neither holds any service-role capability** — this
project grants `service_role` nothing on these tables, and an operator assertion may never be made
with a service key regardless, because it would prove the value was obtainable rather than that the
caller was authorized.

## 4 · The one thing automation cannot do

`public.admins` has **zero grants to any role, `service_role` included** — verified by a 403 whose
own hint reads `GRANT SELECT ON public.admins TO service_role`. That is deliberate: the admins row is
the root of all operator authority, and `is_admin()` is SECURITY DEFINER precisely so the table needs
no grant at all.

**So no automated path can grant admin membership, and none should exist.** A human runs the insert,
per `db/seed_admin.sql`. `scripts/verifyOperatorAdmitPath.mjs` prints the exact statement with the
live uids substituted, and exits **2 — could not verify, never a pass** — until the rows exist.

## 5 · Why the two axes are tested separately

`admin_require_gate()` checks auth → `is_admin` → `require_aal2` → 15-minute freshness, **in that
order**, so the sentinel names which axis rejected the caller:

| Subject | Sentinel | Means |
|---|---|---|
| non-admin, aal1 | `admin_required` | authorization refused; the assurance check was never reached |
| non-admin, **aal2** | `admin_required` | **full MFA assurance buys no operator authority** |
| **admin**, aal1 | `mfa_required` | authorized, insufficiently assured |
| admin, aal2 | *succeeds* | both axes satisfied |

Rows 2 and 3 are the demonstration, and they mean opposite things: an unauthorized person with strong
authentication, versus an authorized person with weak authentication. A test that only recorded "it
failed" could not tell them apart.

**Row 2 is already proven** — both accounts reach genuine `aal2` through a real TOTP factor and are
still refused `admin_required`. Rows 3 and 4 need the admins rows.

## 6 · Rotation

`afterworth-mobile/scripts/rotateE2ECredentials.js` rotates the E2E fixture personas from
`e2e/fixturePersonas.catalog.json`. **These two prefixes are deliberately NOT in that catalog** —
they are operator identities, not app fixtures, and the E2E loader must not resolve them. Rotating a
password would not disturb an enrolled factor, so adding them later is safe; leaving them out today
keeps the E2E persona set meaning what it says.
