/**
 * The recipient invitation email — accessible HTML plus a plain-text twin.
 *
 * ★ WHAT THIS MESSAGE MAY NOT CONTAIN, and structurally cannot:
 *
 *   - any monetary value, account, holding, or institution;
 *   - any document, filename, or vault reference;
 *   - any UUID, outbox id, estate id, or internal identifier;
 *   - any internal role or policy code (`beneficiary`, `professional_delegate`, tier names,
 *     release conditions, SQLSTATEs);
 *   - any statement of fiduciary authority or inheritance — an invitation is an invitation, not a
 *     grant, and telling someone they are inheriting something would be both false and cruel if
 *     the invitation is later revoked.
 *
 * The only variable content is: an optional estate display name, an optional inviter display name,
 * an expiry date, and the link. The two optional names are gated by the invitation's own
 * `preview_visibility`, which the owner set at creation — this template never overrides it.
 *
 * ★ WHAT IT MAY NOT CLAIM. Nothing here says delivered, received, opened, or accepted. The
 * recipient is being asked, not informed.
 *
 * ★ THE LINK CARRIES NO SECRET. Every recipient receives the IDENTICAL URL — a plain entry point
 * with no token, no invitation id, and no per-person path segment. That is possible because
 * authority is IDENTITY, not possession: accept_invitation, decline_invitation and
 * bind_invitation_token all require the caller's verified email or phone to match the invitee
 * (P0006), and POST /api/invitations/resolve surfaces pendingInvitations by that same identity.
 *
 * So this message's whole job is to say "sign in and you will find it waiting". A stolen copy of
 * the email grants nothing, because the URL inside it grants nothing.
 *
 * One functional consequence: the copy must tell the recipient to sign in with THIS address, since
 * that address is what matches them to the invitation. They already know their own address, so
 * saying so discloses nothing.
 */

export interface InvitationEmailInput {
  /** Shown only when the owner enabled it at creation. */
  readonly estateDisplayName: string | null;
  /** Shown only when the owner enabled it at creation. */
  readonly inviterDisplayName: string | null;
  readonly expiresAt: Date;
  /** Fully-formed acceptance URL, token already embedded. */
  readonly link: string;
}

export interface RenderedEmail {
  readonly subject: string;
  readonly html: string;
  readonly text: string;
}

/** Minimal, total HTML escaping. Display names are owner-supplied text and are never trusted. */
function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatExpiry(date: Date): string {
  return new Intl.DateTimeFormat("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  }).format(date);
}

/**
 * Names are optional by DESIGN, not by accident — an owner may invite someone without disclosing
 * whose estate it is. Both fallbacks stay deliberately vague rather than substituting a placeholder
 * that would imply the information exists but was lost.
 */
export function renderInvitationEmail(input: InvitationEmailInput): RenderedEmail {
  const estate = input.estateDisplayName?.trim() || null;
  const inviter = input.inviterDisplayName?.trim() || null;
  const expiry = formatExpiry(input.expiresAt);

  const subject = estate
    ? `You have been invited to ${estate} on AfterWorth`
    : "You have been invited to AfterWorth";

  const opening = inviter && estate
    ? `${inviter} has invited you to ${estate} on AfterWorth.`
    : inviter
      ? `${inviter} has invited you to AfterWorth.`
      : estate
        ? `You have been invited to ${estate} on AfterWorth.`
        : "You have been invited to AfterWorth.";

  // Says what happens NEXT and nothing about what is behind the door. The recipient decides after
  // seeing the invitation, and only then does anything become visible to them.
  //
  // "with this email address" is FUNCTIONAL, not decoration: the invitation is matched to the
  // caller's verified address, so signing in with a different one finds nothing. Saying it plainly
  // here is the difference between a recipient who gets in and one who thinks the link is broken.
  const body = [
    "AfterWorth helps people keep estate information organized and private.",
    "Open AfterWorth and sign in with this email address. Your invitation will be waiting, and you can read it and accept or decline from there — nothing is shared with you until you accept.",
    `This invitation expires on ${expiry}.`,
    "If you were not expecting this, you can ignore this message and nothing will happen.",
  ];

  const eOpening = escapeHtml(opening);
  const eLink = escapeHtml(input.link);
  const eBody = body.map(escapeHtml);

  // Semantic, single-column, no layout tables, real link text, explicit lang, and colours that hold
  // their contrast in both light and dark clients.
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(subject)}</title>
</head>
<body style="margin:0;padding:0;background:#f5f7f9;color:#111820;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<main style="max-width:560px;margin:0 auto;padding:32px 24px;">
<h1 style="font-size:22px;line-height:1.3;margin:0 0 20px;color:#111820;">${eOpening}</h1>
<p style="font-size:16px;line-height:1.6;margin:0 0 16px;color:#111820;">${eBody[0]}</p>
<p style="font-size:16px;line-height:1.6;margin:0 0 24px;color:#111820;">${eBody[1]}</p>
<p style="margin:0 0 28px;">
<a href="${eLink}" style="display:inline-block;background:#0c7489;color:#ffffff;font-size:16px;font-weight:600;text-decoration:none;padding:14px 28px;border-radius:8px;">Open AfterWorth</a>
</p>
<p style="font-size:15px;line-height:1.6;margin:0 0 12px;color:#586472;">${eBody[2]}</p>
<p style="font-size:15px;line-height:1.6;margin:0 0 24px;color:#586472;">${eBody[3]}</p>
<hr style="border:0;border-top:1px solid #d3dae2;margin:0 0 16px;">
<p style="font-size:13px;line-height:1.6;margin:0;color:#586472;">If the button does not work, copy and paste this address into your browser:<br>
<span style="word-break:break-all;">${eLink}</span></p>
</main>
</body>
</html>`;

  const text = [
    opening,
    "",
    body[0],
    "",
    body[1],
    "",
    "Open AfterWorth:",
    input.link,
    "",
    body[2],
    body[3],
  ].join("\n");

  return { subject, html, text };
}
