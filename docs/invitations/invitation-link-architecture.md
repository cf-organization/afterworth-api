# Invitation link architecture — decision record

Decided from the evidence in `invitation-link-contract.md`. Applies to both repositories.

> **Domain correction, 2026-08-02.** This record originally named `app.afterworth.com` as the
> canonical host and `mail.minifam.com` as the sender. Both are superseded. The canonical domain is
> **`after-worth.com`** — link host `app.after-worth.com`, sending domain `mail.after-worth.com`.
>
> The correction was not cosmetic: `afterworth.com` is registered to HugeDomains.com and parked for
> sale, so it could never have served an association file. The hostnames throughout this document
> have been updated to the canonical values. **The architecture itself is unchanged** — token-free,
> identity-authorized, exact-equality parsing. Only the hostnames moved.
>
> A consequence worth recording: the sender and the link now share one registrable domain, which
> closes the from/link mismatch this document previously listed as an accepted risk.

---

## Selected: **Architecture B — HTTPS landing page with an explicit open-app action**

```
https://app.after-worth.com/invitations
```

Served as a **static asset** from the existing `afterworth-api` Vercel project (`public/invitations/`), which
costs no Serverless Function slot — the deployment is at 12/12 and cannot afford one.

### Why B rather than A

Architecture A (universal link straight into the app) is strictly better *once the app is
installed*. It is the wrong primary design here because of who receives these emails: an invitation
recipient is, by definition, frequently **someone who has never installed AfterWorth**. A universal
link with no landing page shows them a browser error or an App Store page with no explanation of
why a stranger's estate app is asking for them.

B degrades correctly. The same URL:
- opens the app directly when iOS/Android link verification succeeds (A's behaviour, preserved);
- otherwise renders a static page that explains what AfterWorth is and offers the store.

So B is a **superset** of A, not an alternative to it. The associated-domain and `assetlinks.json`
files that A requires are still shipped — they are what makes the direct-open path work.

### Why not C

Custom scheme (`afterworth://`) as the production boundary is rejected: any installed app may
register the same scheme. With a token-free link the consequence is small — an interceptor learns
only that a link was tapped — but a verified HTTPS link is still the correct production boundary,
and the scheme is retained for **development and simulator only**.

---

## ★ There is no token in the link at all

This is the load-bearing decision, and it follows from the contract recon rather than preference.

`accept_invitation`, `decline_invitation` and `bind_invitation_token` enforce the identical P0006
identity guard. Authority is the authenticated caller's verified email or phone matching the
invitee. **After authentication the token confers nothing.**

Therefore the link does not need to carry one, and does not:

```
tap link ──► shape validated ──► "invitation entry" intent (a boolean)
                                              │
                                              ▼
                                       authentication
                                              │
                                              ▼
                        existing id-based facade (PR #21) resolves
                        pendingInvitations BY IDENTITY, and owns
                        review / accept / decline
```

Nothing crosses the authentication boundary except the fact that the user arrived from an
invitation link. There is no secret to destroy, because none was ever created for the link.

### What this buys

- **No secret through sign-up, email confirmation, or MFA.** The longest and most interruptible
  part of the flow carries nothing sensitive.
- **Process death is free.** Nothing to lose, so no encrypted-persistence decision is required and
  none is requested.
- **The delivery worker mints nothing.** 0044's notice path leaves `invitations.token_hash`
  untouched, so sending an email no longer silently invalidates a previously issued link — which
  0043's minter did on every send.
- **No second accept/decline implementation.** The link flow converges on the PR #21 facade rather
  than duplicating it on `bind_invitation_token` — which could not offer decline anyway.
- **No pre-auth disclosure.** The app never calls `invitation_preview`, so estate name, inviter
  name, role and email hint stay unrevealed to an unauthenticated holder of the URL.

### What this costs

A recipient who signs up with a **different** email than the one invited sees no invitation. That is
not a regression: `bind_invitation_token` would refuse them with P0006 for the same reason. The
capability is not lost, because it never existed.

---

## Final URL shape

```
https://app.after-worth.com/invitations
└──┬──┘ └────────┬───────┘└─────┬─────┘
 https      exact host      exact path — nothing follows
```

**Every recipient receives this identical URL.** There is no token, no invitation id, no estate id,
no per-person segment, no query string and no fragment. It is navigation, not authorization.

Rules, all enforced by the mobile parser before anything else happens:

| Rule | Reason |
|---|---|
| Scheme must be `https` | `http` would allow a network attacker to redirect the entry point |
| Host equality against a literal allowlist, lowercased | Not `endsWith` — `app.after-worth.com.attacker.tld` and `evil-app.after-worth.com` must both fail |
| Path exactly `/invitations` | Rejects `/invitations/`, `/invitation`, `/invite`, `/i`, and any child segment |
| No query string, no fragment | Nothing in the contract uses them, so their presence means the URL was tampered with or is not ours |
| No userinfo, no explicit port | `https://app.after-worth.com@evil.tld/invitations` must fail |
| Nothing is read *out* of the URL | There is nothing in it to read. The parser returns a boolean intent, not data. |

The parser's entire output is "this was our invitation entry point, or it was not". No authority,
no identifier, and no string is carried forward from the URL into the app.

`mail.after-worth.com` is **not** the clickable origin — it is the Resend sending domain, and coupling
an Apple associated domain to mail-authentication DNS would entangle two unrelated trust decisions.

---

## Threat model

Most of the classic deep-link threats do not apply here, and it is worth being explicit about *why*
rather than listing mitigations for risks that no longer exist: **the link carries no secret, so
there is no secret to leak, persist, replay, or steal.**

| # | Threat | Status |
|---|---|---|
| T1 | Another app claims `afterworth://` and intercepts the link | **Neutralised.** The custom scheme carries no token and grants nothing. An app that steals it learns only that someone tapped an invitation link. Production still uses verified HTTPS links; the scheme is dev-only. |
| T2 | Link leaks via `Referer` to a third party | **Neutralised.** There is nothing in the URL to leak. `Referrer-Policy: no-referrer` is kept anyway, and the page loads no third-party resource. |
| T3 | Link persists in browser history, storage, or a mail scanner's cache | **Neutralised.** The URL is public, identical for everyone, and inert. |
| T4 | Attacker with the URL learns who was invited, or to which estate | **Neutralised.** The page is a single static file, byte-identical for every visitor, and the app never calls `invitation_preview`. There is no lookup to perform. |
| T5 | Attacker with the URL accepts the invitation | **Neutralised by P0006.** Acceptance requires an authenticated session whose *verified* email or phone matches the invitee. The URL grants nothing toward that. |
| T6 | Link-preview bot or mail scanner fetches the URL and consumes the invitation | **Neutralised.** The page performs no backend call. Nothing is consumed by fetching it. |
| T7 | Host confusion — `app.after-worth.com.evil.tld`, uppercase, unicode, userinfo | **Mitigated by the parser.** Exact lowercased host equality against a literal allowlist; no suffix matching; userinfo and ports rejected. |
| T8 | Path confusion — `/invitations/../admin`, `/invitations/<injected>` | **Mitigated by the parser.** Exact path equality, not a prefix match. Any child segment is rejected. |
| T9 | Open redirect via a return parameter | **Structurally impossible.** No such parameter exists, and any query string is rejected outright. |
| T10 | A recipient signs in with the wrong address and sees someone else's invitation | **Neutralised by P0006** on `resolve`, `accept` and `decline` alike. They see nothing, indistinguishably from having no invitation. |
| T11 | An attacker floods the entry point to enumerate invitations | **Nothing to enumerate.** The page is static, and the authenticated resolve path returns only the caller's own identity-matched rows. |

### Residual risks, accepted and stated

- **A recipient who signs up with a different address than the one invited sees nothing.** This is
  the cost of identity-based authority. `bind_invitation_token` would have refused them with P0006
  for the same reason, so no capability was lost — but the email must say plainly which address to
  use, and it does.
- **Anyone who can read the recipient's mailbox can reach the landing page.** They learn only that
  AfterWorth exists. Acceptance still requires controlling the invited identity, which for an email
  invitation means controlling that mailbox — a compromise that is out of scope for any design that
  delivers by email at all.
- **Link verification requires DNS and hosting that do not exist yet.** Until `app.after-worth.com`
  resolves and the association files are served with real values in place of the placeholders, only
  the development scheme works. This is why `INVITATION_LINK_BASE_URL` stays unset and no real send
  is enabled.

---

## Rejected alternatives

| Option | Why rejected |
|---|---|
| Architecture A alone | Fails the uninstalled-recipient case, which is the majority case for an invitation |
| Architecture C for production | Any app can claim the scheme (T1) |
| `mail.after-worth.com` as the click origin | Couples Apple/Android association to mail-auth DNS |
| Any token, id, or hash in the URL | Nothing needs it, and everything that carries it can leak it |
| Building review/accept/decline on `bind_invitation_token` | It has no decline, and it accepts as a side effect of inspection |
| Calling `invitation_preview` pre-auth for a richer landing page | Discloses estate name, inviter name, role and a contact hint to an unauthenticated caller (T4) |
| Persisting anything to survive process death | There is nothing worth persisting; reopening the email or simply signing in both resume the flow |
