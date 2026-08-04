/**
 * The ONLY module in this repository permitted to touch RESEND_API_KEY.
 *
 * ★ KEY CUSTODY. The key is read from the server environment inside this file and nowhere else. It
 * is never exported, never returned, never placed on a response, never written to a log or an
 * error message, and never given an EXPO_PUBLIC_/NEXT_PUBLIC_ prefix that would inline it into a
 * client bundle. afterworth-mobile does not import this module and cannot — it lives in the API
 * repository. An audit test asserts every one of those properties against the source text.
 *
 * ★ NO NETWORK IN TESTS. `send()` takes an optional `transport`. Production passes nothing and gets
 * the fetch-backed transport; tests inject a fake. There is no code path in the test suite that
 * reaches Resend, and no test needs a key to exist.
 *
 * ★ OUTCOME HONESTY. This module reports what actually happened and refuses to round up:
 *
 *   providerAccepted  Resend answered with a message id. It accepted the message FOR delivery.
 *                     That is not delivered, received, opened, or viewed, and nothing downstream
 *                     is allowed to rename it.
 *   retryPending      Resend ANSWERED and did not accept (429, 5xx). Because it answered, we know
 *                     the message was not taken, so retrying the same generation is safe.
 *   failedPermanent   Resend answered with a permanent refusal (malformed recipient, auth, 4xx
 *                     that will never succeed). Retrying changes nothing.
 *   outcomeUncertain  The request left this process and no answer came back — timeout, socket
 *                     error, aborted read. It may or may not have been accepted. This is NOT a
 *                     failure and NOT a success, and it is never silently retried into a second
 *                     link (see the delivery orchestrator).
 */

const RESEND_ENDPOINT = "https://api.resend.com/emails";
const REQUEST_TIMEOUT_MS = 10_000;

export type DeliveryOutcome =
  | "providerAccepted"
  | "outcomeUncertain"
  | "retryPending"
  | "failedPermanent";

export type FailureClass =
  | "provider_rejected"
  | "provider_unavailable"
  | "rate_limited"
  | "invalid_recipient"
  | "configuration"
  | "timeout"
  | "unknown";

export interface OutboundEmail {
  readonly to: string;
  readonly subject: string;
  readonly html: string;
  readonly text: string;
  /** `afterworth/invitation/<outbox-id>/<generation>` — surrogate ids only. */
  readonly idempotencyKey: string;
}

export interface ProviderResult {
  readonly outcome: DeliveryOutcome;
  /** Server-confined. Never returned to a client, never logged. */
  readonly providerMessageId: string | null;
  readonly failureClass: FailureClass | null;
}

/**
 * A single HTTP round trip. Narrow on purpose: a transport cannot see the API key (the provider
 * adds the Authorization header itself), so a test double can never leak one it never had.
 */
export interface Transport {
  (url: string, init: RequestInit): Promise<Response>;
}

const fetchTransport: Transport = (url, init) => fetch(url, init);

/** Reads the key at CALL time, never at import time, so importing this module is side-effect free. */
function readApiKey(): string | null {
  const key = (process.env.RESEND_API_KEY ?? "").trim();
  return key.length > 0 ? key : null;
}

function senderAddress(): string {
  // A non-secret. Kept in env so staging and production differ without a code change.
  return (process.env.INVITATION_FROM_ADDRESS ?? "").trim() || "AfterWorth <invitations@afterworth.app>";
}

/** HTTP status → outcome. The rule is simply whether Resend answered, and whether it can ever succeed. */
function classifyStatus(status: number): { outcome: DeliveryOutcome; failureClass: FailureClass } {
  if (status === 429) return { outcome: "retryPending", failureClass: "rate_limited" };
  if (status >= 500) return { outcome: "retryPending", failureClass: "provider_unavailable" };
  if (status === 401 || status === 403) {
    // A bad key will not fix itself on a retry; burning attempts on it hides the real problem.
    return { outcome: "failedPermanent", failureClass: "configuration" };
  }
  if (status === 422 || status === 400) {
    return { outcome: "failedPermanent", failureClass: "invalid_recipient" };
  }
  return { outcome: "failedPermanent", failureClass: "provider_rejected" };
}

/**
 * Send one message. Never throws — every failure mode is a typed outcome, because a throw here
 * would leave the outbox row stranded in `processing` with nothing recorded.
 */
export async function send(email: OutboundEmail, transport: Transport = fetchTransport): Promise<ProviderResult> {
  const apiKey = readApiKey();
  if (!apiKey) {
    // Deliberately says the key is ABSENT and never echoes any part of it.
    console.error("resendProvider: RESEND_API_KEY is not configured");
    return { outcome: "failedPermanent", providerMessageId: null, failureClass: "configuration" };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const res = await transport(RESEND_ENDPOINT, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        // ★ Defence in depth, not the primary guard. The database claim/result state is the source
        //   of truth for "did we already send this"; this stops a same-generation retry from
        //   producing a second message even if the state machine were somehow wrong.
        "Idempotency-Key": email.idempotencyKey,
      },
      body: JSON.stringify({
        from: senderAddress(),
        to: [email.to],
        subject: email.subject,
        html: email.html,
        text: email.text,
      }),
      signal: controller.signal,
    });

    if (!res.ok) {
      const { outcome, failureClass } = classifyStatus(res.status);
      // Status only. The provider's body can echo the recipient address, so it is not read or logged.
      console.error("resendProvider: send refused", { status: res.status, failureClass });
      return { outcome, providerMessageId: null, failureClass };
    }

    let messageId: string | null = null;
    try {
      const body = (await res.json()) as { id?: unknown };
      messageId = typeof body.id === "string" && body.id.length > 0 ? body.id : null;
    } catch {
      /* A 2xx with an unreadable body still means accepted; we just have no handle for it. */
    }
    return { outcome: "providerAccepted", providerMessageId: messageId, failureClass: null };
  } catch (err) {
    // ★ The honest branch. The request left this process and we never learned its fate. Reporting
    //   this as a failure would invite a retry that could produce a SECOND email; reporting it as
    //   success would be a lie. It is neither.
    const timedOut = err instanceof Error && err.name === "AbortError";
    console.error("resendProvider: outcome uncertain", { timedOut });
    return {
      outcome: "outcomeUncertain",
      providerMessageId: null,
      failureClass: timedOut ? "timeout" : "unknown",
    };
  } finally {
    clearTimeout(timer);
  }
}
