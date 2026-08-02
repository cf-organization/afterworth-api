# Invitation link — domain, hosting and deployment setup

Manual steps, in order. **Nothing here has been done.** No DNS record was created, no environment
variable was set, no deployment was made, and no email was sent.

Two values in the repository are deliberate placeholders that only you can supply. Until both are
replaced, iOS and Android link verification **cannot** work — and they fail silently, with no error
surfaced anywhere. A test asserts the placeholders are still present so this cannot be forgotten
quietly:

| File | Placeholder | Where the real value comes from |
|---|---|---|
| `public/.well-known/apple-app-site-association` | `REPLACE_WITH_APPLE_TEAM_ID` | Apple Developer → Membership → Team ID |
| `public/.well-known/assetlinks.json` | `REPLACE_WITH_ANDROID_SIGNING_SHA256_FINGERPRINT` | The SHA-256 of the signing cert that actually ships the build |

---

## Why a new host, and not `mail.minifam.com`

`mail.minifam.com` is the Resend **sending** domain. Its DNS is owned by mail authentication —
SPF, DKIM and DMARC — and an Apple associated domain binds a host to an app identity. Those are two
unrelated trust decisions, and entangling them means a future mail-provider change risks breaking
invitation links, or vice versa.

Use a dedicated host. This document assumes:

```
invite.minifam.com
```

---

## 1 · Add the custom domain in Vercel

Vercel dashboard → the **afterworth-api** project → Settings → Domains → Add.

Enter `invite.minifam.com`. Vercel will then display the exact DNS record it wants.

**Do not use a record from this document.** Vercel's target values change and are per-project; the
dashboard is authoritative. It will show either a `CNAME` to a `*.vercel-dns.com` target or an `A`
record — take whichever it gives you.

## 2 · Create that record in Cloudflare

Cloudflare dashboard → `minifam.com` → DNS → Add record, exactly as Vercel specified.

⚠️ **Set Proxy status to DNS only (grey cloud), not Proxied (orange cloud).** An orange-clouded
record puts Cloudflare in front of Vercel, which breaks Vercel's domain verification and its
certificate issuance. If Vercel's dashboard says the domain is misconfigured after the record
propagates, this is almost always why.

## 3 · Wait for HTTPS, then verify the surface by hand

Vercel issues the certificate automatically once the record resolves. Then check all three:

```sh
# 1. The landing page renders, with the security headers attached
curl -sI https://invite.minifam.com/i | grep -iE 'HTTP/|content-security-policy|referrer-policy|x-content-type'

# 2. Apple's file — MUST be application/json, and MUST have no file extension
curl -sI https://invite.minifam.com/.well-known/apple-app-site-association | grep -iE 'HTTP/|content-type'
curl -s  https://invite.minifam.com/.well-known/apple-app-site-association | python3 -m json.tool

# 3. Android's file
curl -s https://invite.minifam.com/.well-known/assetlinks.json | python3 -m json.tool
```

Expected: `200` on all three, `Content-Type: application/json` on both association files, and
`Referrer-Policy: no-referrer` plus a `default-src 'none'` CSP on `/i`.

## 4 · Substitute the two placeholders

**Apple Team ID** — Apple Developer → Membership. Replace so the entry reads:

```json
"appIDs": ["ABCDE12345.com.afterworth.mobile"]
```

**Android signing fingerprint** — the SHA-256 of the certificate that signs the shipped build. For
an EAS-managed credential:

```sh
eas credentials --platform android     # read the SHA-256 fingerprint it prints
```

Use the **production** signing certificate. A debug-keystore fingerprint verifies your local build
and nothing your users install. If you ship through Play App Signing, use the fingerprint Google
Play reports under Release → Setup → App signing, not the upload key.

Then flip the two assertions in `test/landingSurface.test.ts` from `toContain("REPLACE_WITH_…")` to
assert the real shape, and redeploy so the corrected files are served.

## 5 · Configure the app side

**iOS** — `app.json` → `expo.ios.associatedDomains`:
```json
["applinks:invite.minifam.com"]
```

**Android** — `app.json` → `expo.android.intentFilters`, an autoVerify filter for
`https://invite.minifam.com/i`.

Both require a **native rebuild** — they are baked into the binary at build time, so an OTA update
cannot deliver them. That work lives in the mobile repository, not here.

## 6 · Set the environment variable — only now

Vercel → afterworth-api → Settings → Environment Variables:

```
INVITATION_LINK_BASE_URL=https://invite.minifam.com/i
```

**No token is appended, and none should be.** The worker uses this value verbatim as the link;
every recipient receives the identical URL. That is safe because authority is identity, not
possession — see `invitation-link-architecture.md`.

Also confirm, if not already set:

```
INVITATION_FROM_ADDRESS=AfterWorth <invitations@mail.minifam.com>
RESEND_API_KEY=<the minifam-invitation-worker key, sending-only>
CRON_SECRET=<already configured for the purge cron>
```

⚠️ `RESEND_API_KEY` must be the **`minifam-invitation-worker`** key, not
`minifam-supabase-auth`. The latter belongs to Supabase's own SMTP for auth email; sharing one key
across both means revoking either breaks the other, and it destroys the audit separation between
"we sent an auth email" and "we sent an invitation".

## 7 · Redeploy

The environment variable is read at request time, but a redeploy is the clean way to guarantee the
running deployment sees it.

## 8 · Synthetic delivery — only after everything above

Do this with an address **you control**, never a real invitee:

1. Create an invitation to your own address through `POST /api/invitations/create_owner`.
2. Confirm the response reads `deliveryState: "queued"` or `"providerAccepted"` — **never
   `"delivered"`**; no such state exists.
3. Check the inbox. The link must be exactly `https://invite.minifam.com/i` with nothing appended.
4. Tap it on a real iOS device and a real Android device. Verified links open the app directly;
   unverified ones show the landing page, which is the correct fallback, not a failure.
5. Sign in as the invited address and confirm the invitation appears.
6. Confirm the outbox row reached `providerAccepted` and that `invitations.token_hash` is
   **unchanged** — the token-free path must never rotate it.

Until step 8 has actually been performed, every link and delivery item in the validation matrix
stays **DEFERRED — MANUAL DOMAIN AND DEVICE VALIDATION**. Nothing here may be marked passed on the
strength of code review.

---

## Rollback

Unset `INVITATION_LINK_BASE_URL`. The worker then fails closed with `failedPermanent` /
`configuration` **before** taking a delivery notice, so no generation is consumed and no email is
attempted. The landing page and association files are inert static assets; leaving them served
costs nothing and reveals nothing.
