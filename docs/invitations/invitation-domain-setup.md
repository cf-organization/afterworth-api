# Invitation link — domain, hosting and deployment setup

Manual steps, in order. **Nothing here has been done.** No DNS record was created, no environment
variable was set, no deployment was made, and no email was sent.

Canonical domain is **`after-worth.com`** (registered 2026-08-02, registrar Cloudflare, Cloudflare
nameservers). Every host below lives in that one zone.

| Purpose | Host |
|---|---|
| Public website | `after-worth.com` |
| App + invitation landing | `app.after-worth.com` |
| Invitation landing URL | `https://app.after-worth.com/invitations` |
| Email sending domain | `mail.after-worth.com` |
| Auth sender | `AfterWorth <no-reply@mail.after-worth.com>` |
| Invitation sender | `AfterWorth <invitations@mail.after-worth.com>` |
| Future API host, if introduced | `api.after-worth.com` |

Two values in the repository are deliberate placeholders that only you can supply. Until both are
replaced, iOS and Android link verification **cannot** work — and they fail silently, with no error
surfaced anywhere. A test asserts the placeholders are still present so this cannot be forgotten
quietly:

| File | Placeholder | Where the real value comes from |
|---|---|---|
| `public/.well-known/apple-app-site-association` | `REPLACE_WITH_APPLE_TEAM_ID` | Apple Developer → Membership → Team ID |
| `public/.well-known/assetlinks.json` | `REPLACE_WITH_ANDROID_SIGNING_SHA256_FINGERPRINT` | The SHA-256 of the signing cert that actually ships the build |

---

## Why the link host and the sending domain are now the same registrable domain

```
app.after-worth.com     ← the clickable link (this document)
mail.after-worth.com    ← the Resend SENDING domain
```

They remain **separate hosts** deliberately. `mail.after-worth.com` carries mail authentication —
SPF, DKIM, DMARC — while `app.after-worth.com` binds a host to an app identity through Apple's
associated-domains and Android's asset links. Keeping them on separate subdomains means a future
mail-provider change cannot break invitation links, or the reverse.

What has changed is that they now share one **registrable** domain. Under the previous split — from
`@mail.minifam.com`, linking to `app.afterworth.com` — the two were unrelated registrable domains,
which users are taught to read as a phishing signal and some filters score. That concern is resolved
by this migration, not merely flagged.

> **Historical.** The earlier revision of this document recorded the mismatch as an open decision
> ("flagging rather than deciding"). It is now closed: both sides are `after-worth.com`. Retained
> here so the decision trail is legible, not because it describes current configuration.

---

## 1 · Add the custom domain in Vercel

Vercel dashboard → the **afterworth-api** project → Settings → Domains → Add.

Enter `app.after-worth.com`. Vercel will then display the exact DNS record it wants.

**Do not use a record from this document.** Vercel's target values change and are per-project; the
dashboard is authoritative. It will show either a `CNAME` to a `*.vercel-dns.com` target or an `A`
record — take whichever it gives you.

## 2 · Create that record in Cloudflare

Cloudflare dashboard → the **`after-worth.com`** zone → DNS → Add record, exactly as Vercel
specified.

⚠️ **The record goes in the `after-worth.com` zone. Do not create it in `minifam.com`.** The
minifam zone holds legacy records and is not part of this product's configuration.

⚠️ **Set Proxy status to DNS only (grey cloud), not Proxied (orange cloud).** An orange-clouded
record puts Cloudflare in front of Vercel, which breaks Vercel's domain verification and its
certificate issuance. If Vercel's dashboard says the domain is misconfigured after the record
propagates, this is almost always why.

## 3 · Verify the sending domain in Resend — this is not a redirect

⚠️ **An email-domain migration is not an HTTP redirect.** There is no way to forward
`mail.minifam.com` to `mail.after-worth.com`. The new sending domain must be independently verified
with fresh DNS records, or every send fails.

1. Resend dashboard → Domains → Add domain → `mail.after-worth.com`.
2. Resend issues SPF and DKIM records. Create them in the **`after-worth.com`** zone — never in
   `minifam.com`.
3. Wait for Resend to report the domain **Verified**.
4. Confirm the API key in use is authorised to send from the new domain. The existing
   `minifam-invitation-worker` key was issued against the minifam sending domain; if it is scoped
   to that domain, issue a new sending-only key for `mail.after-worth.com` and use it.

Until the domain reads Verified in Resend, `INVITATION_FROM_EMAIL` will be rejected `422`, which
`classifyStatus` maps to `failedPermanent` — the outbox row is burned, not retried.

## 4 · Wait for HTTPS, then verify the surface by hand

Vercel issues the certificate automatically once the record resolves. Then check all three:

```sh
# 1. The landing page renders, with the security headers attached
curl -sI https://app.after-worth.com/invitations | grep -iE 'HTTP/|content-security-policy|referrer-policy|x-content-type'

# 2. Apple's file — MUST be application/json, and MUST have no file extension
curl -sI https://app.after-worth.com/.well-known/apple-app-site-association | grep -iE 'HTTP/|content-type'
curl -s  https://app.after-worth.com/.well-known/apple-app-site-association | python3 -m json.tool

# 3. Android's file
curl -s https://app.after-worth.com/.well-known/assetlinks.json | python3 -m json.tool
```

Expected: `200` on all three, `Content-Type: application/json` on both association files, and
`Referrer-Policy: no-referrer` plus a `default-src 'none'` CSP on `/invitations`.

A `302` to `hugedomains.com` means DNS is still pointing at a parked domain — see the note on
`afterworth.com` under Legacy hosts below.

## 5 · Substitute the two placeholders

**Apple Team ID** — Apple Developer → Membership. Replace so the entry reads:

```json
"appIDs": ["ABCDE12345.com.afterworth.mobile"]
```

`com.afterworth.mobile` is the **app identity**, not a domain. It is registered with Apple and
Google and is deliberately **not** migrated — renaming it would require new store listings. A test
pins it against exactly this kind of well-meaning sweep.

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

## 6 · Configure the app side

**iOS** — `app.json` → `expo.ios.associatedDomains`:
```json
["applinks:app.after-worth.com"]
```

**Android** — `app.json` → `expo.android.intentFilters`, an autoVerify filter for
`https://app.after-worth.com/invitations`.

Both are already committed in the mobile repository. Both require a **native rebuild** — they are
baked into the binary at build time, so an OTA update cannot deliver them.

## 7 · Set the environment variables — only now

Vercel → afterworth-api → Settings → Environment Variables:

```
INVITATION_LINK_BASE_URL=https://app.after-worth.com/invitations
INVITATION_FROM_EMAIL=AfterWorth <invitations@mail.after-worth.com>
```

**No token is appended, and none should be.** The worker uses `INVITATION_LINK_BASE_URL` verbatim as
the link; every recipient receives the identical URL. That is safe because authority is identity,
not possession — see `invitation-link-architecture.md`.

> ⚠️ `INVITATION_FROM_EMAIL` replaces the former `INVITATION_FROM_ADDRESS`. If the old name is still
> set in Vercel, **delete it** — it is no longer read, and leaving it gives a false impression that
> the sender is configured.

Also confirm, if not already set:

```
RESEND_API_KEY=<a sending-only key authorised for mail.after-worth.com>
CRON_SECRET=<already configured for the purge cron>
```

⚠️ `RESEND_API_KEY` must be an invitation-worker key, **not** the Supabase auth key. The auth key
belongs to Supabase's own SMTP for auth email; sharing one key across both means revoking either
breaks the other, and it destroys the audit separation between "we sent an auth email" and "we sent
an invitation".

## 8 · Redeploy

The environment variables are read at request time, but a redeploy is the clean way to guarantee the
running deployment sees them.

## 9 · Synthetic delivery — only after everything above

Do this with an address **you control**, never a real invitee:

1. Create an invitation to your own address through `POST /api/invitations/create_owner`.
2. Confirm the response reads `deliveryState: "queued"` or `"providerAccepted"` — **never
   `"delivered"`**; no such state exists.
3. Check the inbox. The link must be exactly `https://app.after-worth.com/invitations` with nothing
   appended, and the From address must be `invitations@mail.after-worth.com`.
4. Tap it on a real iOS device and a real Android device. Verified links open the app directly;
   unverified ones show the landing page, which is the correct fallback, not a failure.
5. Sign in as the invited address and confirm the invitation appears.
6. Confirm the outbox row reached `providerAccepted` and that `invitations.token_hash` is
   **unchanged** — the token-free path must never rotate it.

Until step 9 has actually been performed, every link and delivery item in the validation matrix
stays **DEFERRED — MANUAL DOMAIN AND DEVICE VALIDATION**. Nothing here may be marked passed on the
strength of code review.

---

## Legacy hosts

None of these is active configuration. A regression test (`test/legacyDomainAudit.test.ts`) fails the
build if any reappears in shipped source.

| Host | Status |
|---|---|
| `app.afterworth.com` | **Never owned by this product.** `afterworth.com` is registered to HugeDomains.com and parked for sale; every request 302s to a domain-sale listing. It was the canonical host in an earlier revision — that was the error this migration corrects. |
| `invite.minifam.com`, `app.minifam.com` | Decommissioned |
| `mail.minifam.com` | Decommissioned as a sender. Its DNS records may remain for historical mail, but nothing in this product sends from it. |

Web traffic **may** later redirect `minifam.com → after-worth.com` and
`app.minifam.com → app.after-worth.com`. If that redirect is configured it is explicitly labelled
legacy-redirect configuration and is the one permitted place a legacy host may appear.
`app.afterworth.com → app.after-worth.com` is **not** available: the domain is not ours to redirect.

Email is excluded from all of the above — see step 3.

---

## Rollback

Unset `INVITATION_LINK_BASE_URL`. The worker then fails closed with `failedPermanent` /
`configuration` **before** taking a delivery notice, so no generation is consumed and no email is
attempted. The landing page and association files are inert static assets; leaving them served
costs nothing and reveals nothing.
