# Invitation link architecture — decision record

Decided from the evidence in `invitation-link-contract.md`. Applies to both repositories.

---

## Selected: **Architecture B — HTTPS landing page with an explicit open-app action**

```
https://invite.minifam.com/i/<64-hex-token>
```

Served as a **static asset** from the existing `afterworth-api` Vercel project (`public/i/`), which
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

Custom scheme (`afterworth://`) as the production boundary is rejected outright: any installed app
may register the same scheme, so an attacker's app can intercept the invitation token. It is
retained for **development and simulator only**, gated so it cannot be accepted in a release build.

---

## ★ The token is a routing hint, not a credential

This is the load-bearing decision, and it follows from the contract recon rather than preference.

`accept_invitation`, `decline_invitation` and `bind_invitation_token` enforce the identical P0006
identity guard. Authority is the authenticated caller's verified email or phone matching the
invitee. **After authentication the token confers nothing.**

Therefore:

```
link captured ──► shape validated ──► authentication ──► TOKEN DESTROYED
                                                              │
                                                              ▼
                                   existing id-based facade (PR #21) resolves
                                   pendingInvitations by identity, and owns
                                   review / accept / decline
```

The token never crosses the authentication boundary. It is not needed on the other side.

### What this buys

- **No token through sign-up, email confirmation, or MFA.** The longest and most interruptible part
  of the flow carries no secret at all.
- **Process death is free.** Nothing to lose, so no encrypted-persistence decision is required and
  none is requested.
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
https://invite.minifam.com/i/<token>
        └────────┬────────┘ └┬┘ └──┬──┘
             host          path  single opaque segment, 64 hex chars
```

Rules, all enforced by the parser before any network call:

| Rule | Reason |
|---|---|
| Token in the **path**, never a query parameter | Query strings leak into `Referer`, server access logs, and browser history. The current `delivery.ts` composes `?token=…` and **must be changed**. |
| Exactly one path segment after `/i/` | No traversal, no ambiguity about which segment is the secret |
| `^[0-9a-f]{64}$` | Matches what `issue_invitation_delivery_token` mints (`encode(gen_random_bytes(32),'hex')`). Anything else is rejected without a request. |
| Host equality against a literal allowlist | Not `endsWith` — `evil-invite.minifam.com.attacker.tld` must fail |
| No userinfo, no port, no fragment, no query | Nothing in the contract uses them |
| No invitation id, estate id, email, or role in the URL | Those are the disclosures §6 forbids |
| No return-URL or redirect parameter | Eliminates open redirect as a category |

`mail.minifam.com` is **not** the clickable origin — it is the Resend sending domain, and coupling
an Apple associated domain to mail-authentication DNS would entangle two unrelated trust decisions.

---

## Threat model

| # | Threat | Mitigation |
|---|---|---|
| T1 | Another app claims `afterworth://` and intercepts the token | Custom scheme accepted in **dev builds only**; production uses verified HTTPS links bound by `apple-app-site-association` / `assetlinks.json` |
| T2 | Token leaks via `Referer` to a third party | Token is a path segment, landing page sends `Referrer-Policy: no-referrer`, and loads no third-party resource |
| T3 | Token persists in browser storage | Landing page uses no `localStorage`, `sessionStorage`, or cookies, and no analytics |
| T4 | Token reaches app logs, crash reports, or analytics | Continuation store is memory-only; audits assert the token never enters a log call, a React Query key, Zustand persistence, SecureStore, or an accessibility label |
| T5 | Token survives in the OS task-switcher snapshot | Token is destroyed at authentication, before the longest-lived screens; the review screen never holds it |
| T6 | Attacker with the URL learns who was invited and to which estate | The app never calls `invitation_preview`; the landing page renders **no** invitation data — it is byte-identical for a valid, expired, and fabricated token |
| T7 | Attacker with the URL accepts the invitation | P0006 — acceptance requires a session whose verified email/phone matches the invitee. A stolen URL alone is inert. |
| T8 | Host confusion (`minifam.com.evil.tld`, uppercase, unicode) | Exact, lowercased host equality against a literal allowlist; no suffix matching |
| T9 | Open redirect via a return parameter | No such parameter exists in the contract; the parser rejects any query string |
| T10 | Link preview bots fetch the URL and consume the invitation | The landing page is static and performs no backend call; nothing is consumed by fetching it. Acceptance requires an authenticated POST. |
| T11 | Replay of an old link after reissue | Reissue overwrites `token_hash`; the old link resolves to nothing, indistinguishable from a bad token |
| T12 | A superseding link opened mid-flow | Continuation store is generation-guarded; a newer capture supersedes the older and clears its token |

### Residual risks, accepted and stated

- **The token is in the recipient's inbox indefinitely.** Anyone with mailbox access has the URL.
  T7 is the mitigation: the URL alone cannot accept. Mailbox compromise is out of scope for a
  design that must deliver by email at all.
- **A shoulder-surfer can read the URL from the browser address bar** on the landing page. The token
  is inert without the matching identity.
- **Link verification requires DNS and hosting the app has not yet got.** Until
  `invite.minifam.com` resolves and the association files are served, only the development scheme
  works. This is why `INVITATION_LINK_BASE_URL` stays unset and no real send is enabled.

---

## Rejected alternatives

| Option | Why rejected |
|---|---|
| Architecture A alone | Fails the uninstalled-recipient case, which is the majority case for an invitation |
| Architecture C for production | Any app can claim the scheme (T1) |
| `mail.minifam.com` as the click origin | Couples Apple/Android association to mail-auth DNS |
| Token as a query parameter | `Referer`, access logs, browser history (T2) |
| Building review/accept/decline on `bind_invitation_token` | It has no decline, and it accepts as a side effect of inspection |
| Calling `invitation_preview` pre-auth for a richer landing page | Discloses exactly the fields §6 forbids (T6) |
| Persisting the token to survive process death | Unnecessary once the token is a routing hint; would add T4/T5 exposure for no capability |
