/**
 * The owner safety notice — the independently reachable half of the D4 control.
 *
 * ★ THIS IS THE HIGHEST-STAKES MESSAGE THE PRODUCT SENDS, and the reason it exists is narrow: the
 * in-app notice reaches an owner who opens the app, and the population this channel is FOR is the
 * owner who does not. That is exactly the population a false death claim succeeds against. So the
 * message has one job — get a living person to look — and every other temptation is refused below.
 *
 * ★ THE COPY IS THE CATALOG'S, NOT A NEW COMPOSITION. `notification_event_copy` holds the immutable
 * in-app copy for `death_process.window_opened`:
 *
 *     title  "A release process is waiting"
 *     body   "A release process is waiting on your estate. You can review and halt it now."
 *
 * This template says the same thing in the same voice. Two channels carrying the same event must not
 * describe it differently, or the owner who receives both learns that one of them is imprecise. The
 * catalog remains a SQL constant and this remains a TypeScript constant — they are checked against
 * each other by `test/ownerNoticeTemplate.test.ts` rather than shared through a build step, because
 * a server that could interpolate this copy is a server that could be made to say something else.
 *
 * ★ WHAT THIS MESSAGE MAY NOT CONTAIN, and structurally cannot — it takes no parameters at all:
 *
 *   - the estate name, or any estate content, value, holding, document or beneficiary;
 *   - the claimant's name, the initiator's name, or any indication that a specific person acted —
 *     naming them would hand a living owner a target, and would be a disclosure the fiduciary
 *     surfaces themselves refuse (11-I withheld `initiator_capacity` for the same reason);
 *   - the evidence, or any characterisation of it;
 *   - an assertion that anyone has died. Nothing here says a death was reported, accepted, or
 *     verified. "A release process is waiting" is the strongest honest claim, and it is the claim
 *     the 11-E brief sanctions;
 *   - deadline arithmetic. The window duration is read LIVE at release time, so any date printed
 *     here could be wrong by the time it is read — and a countdown in this message would be the
 *     product performing urgency at the person it is supposed to be protecting;
 *   - any UUID, case id, outbox id, estate id or internal identifier;
 *   - any internal state vocabulary (`challenge_window`, `owner_notification_dispatched`,
 *     `failedPermanent`). Internal state is not user copy.
 *
 * ★ AND IT CARRIES NO SECRET AND NO PER-RECIPIENT URL. Every owner receives the identical link to
 * the app's entry point, for the invitation template's reason and one more: authority to halt is
 * `is_estate_owner` inside `challenge_death_process`, checked at the destination. A stolen copy of
 * this email grants nothing, because the URL inside it grants nothing — and a one-click "halt" link
 * would be a release-process control operable by anyone who reads the owner's inbox.
 *
 * The deep link `afterworth://challenge` is the in-app notice's destination and is deliberately NOT
 * used here: a custom scheme in an email opens nothing for a recipient reading on a desktop, and a
 * dead link in this message is worse than a plain instruction.
 */

export interface RenderedOwnerNotice {
  readonly subject: string;
  readonly html: string;
  readonly text: string;
}

/**
 * The catalog copy, mirrored. Exported so the test can compare it against the SQL constant rather
 * than against a second copy written in the test file — a fixture that restated the string would
 * agree with whatever this file said and could never fail.
 */
export const OWNER_NOTICE_TITLE = "A release process is waiting";
export const OWNER_NOTICE_BODY =
  "A release process is waiting on your estate. You can review and halt it now.";

/**
 * No default. A missing base URL is a CONFIGURATION FAILURE, not a reason to guess: a guessed origin
 * produces a link the recipient cannot distinguish from a broken message, in the one message where
 * "this looks like phishing" is the most expensive possible reaction.
 */
export function ownerNoticeEntryUrl(): string | null {
  const base = (process.env.INVITATION_LINK_BASE_URL ?? "").trim();
  if (base.length === 0) return null;
  return base.replace(/\/+$/, "");
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Renders the notice. Takes ONLY the link — there is no per-recipient content of any kind, so there
 * is no parameter through which estate content could ever enter this message.
 */
export function renderOwnerNoticeEmail(link: string): RenderedOwnerNotice {
  const subject = OWNER_NOTICE_TITLE;

  // Says what is happening, what the owner can do, and how to be sure this message is real. The
  // last line matters: an unexpected email about releasing your estate is indistinguishable from a
  // phishing attempt, and telling the recipient to open the app THEMSELVES rather than trust this
  // message is both safer for them and the only advice that survives someone spoofing it.
  const body = [
    OWNER_NOTICE_BODY,
    "Open AfterWorth and sign in to see what is waiting. If you did not expect this, sign in and halt it now — halting takes one step and needs no explanation from you.",
    "If you would rather not use the link in this message, open the AfterWorth app directly and sign in. You will find the same notice waiting there.",
  ];

  const eLink = escapeHtml(link);
  const eBody = body.map(escapeHtml);

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(subject)}</title>
</head>
<body style="margin:0;padding:0;background:#f5f7f9;color:#111820;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<main style="max-width:560px;margin:0 auto;padding:32px 24px;">
<h1 style="font-size:22px;line-height:1.3;margin:0 0 20px;color:#111820;">${escapeHtml(OWNER_NOTICE_TITLE)}</h1>
<p style="font-size:16px;line-height:1.6;margin:0 0 16px;color:#111820;">${eBody[0]}</p>
<p style="font-size:16px;line-height:1.6;margin:0 0 24px;color:#111820;">${eBody[1]}</p>
<p style="margin:0 0 28px;">
<a href="${eLink}" style="display:inline-block;background:#0c7489;color:#ffffff;font-size:16px;font-weight:600;text-decoration:none;padding:14px 28px;border-radius:8px;">Open AfterWorth</a>
</p>
<p style="font-size:15px;line-height:1.6;margin:0 0 24px;color:#586472;">${eBody[2]}</p>
<hr style="border:0;border-top:1px solid #d3dae2;margin:0 0 16px;">
<p style="font-size:13px;line-height:1.6;margin:0;color:#586472;">If the button does not work, copy and paste this address into your browser:<br>
<span style="word-break:break-all;">${eLink}</span></p>
</main>
</body>
</html>`;

  const text = [
    OWNER_NOTICE_TITLE,
    "",
    body[0],
    "",
    body[1],
    "",
    "Open AfterWorth:",
    link,
    "",
    body[2],
  ].join("\n");

  return { subject, html, text };
}
