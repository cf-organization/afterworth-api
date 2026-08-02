/**
 * Delivery orchestration — the only place that turns a claimed outbox row into an email.
 *
 * ★ THE EMAIL CARRIES NO SECRET. This is the load-bearing property of the whole flow, and it is a
 * consequence of the 0042 contract rather than a preference:
 *
 *   accept_invitation, decline_invitation and bind_invitation_token all enforce the SAME guard —
 *   the caller's verified email or phone must match the invitee, or P0006. Authority is IDENTITY,
 *   not possession of a token. And POST /api/invitations/resolve already returns the caller's
 *   pendingInvitations matched by that same identity.
 *
 * So a recipient reaches their invitation by signing in, full stop. The email only has to tell
 * them that, and point at a page that helps them install the app. Minting a credential for that
 * would leave a live secret in an inbox indefinitely in exchange for no capability — and 0043's
 * token issuance additionally overwrote invitations.token_hash, so every send silently killed any
 * previously issued link.
 *
 * ★ THE ORDER IS THE SAFETY PROPERTY, and it mirrors the storage-deletion outbox exactly:
 *
 *     1. claim   (DEFINER RPC, `for update skip locked`) — row moves to `processing`
 *     2. notice  (DEFINER RPC, 0044) — generation advances, key derived, NOTHING minted
 *     3. send    (provider, with the deterministic Idempotency-Key)
 *     4. record  (DEFINER RPC) — outcome written back, generation-guarded
 *
 * Steps 1 and 4 are 0043's, reused verbatim — the claim predicate, SKIP LOCKED behaviour, retry
 * cap and generation guard are all unchanged. Only step 2 differs (0044).
 *
 * ★ AN AMBIGUOUS SEND IS STILL NOT RETRIED BY A LATER DRAIN. Not for token reasons any more —
 * there is no token — but because a second email would be a second email. `outcomeUncertain` stays
 * out of the claim predicate, and `retryPending` remains reserved for the case where the provider
 * ANSWERED and refused (429/5xx), which proves nothing was accepted.
 */

import type { SupabaseClient } from "@supabase/supabase-js";
import { renderInvitationEmail } from "../email/invitationTemplate.js";
import {
  send as defaultSend,
  type DeliveryOutcome,
  type FailureClass,
  type ProviderResult,
  type Transport,
} from "../email/resendProvider.js";

export interface ClaimedRow {
  readonly outboxId: string;
  readonly invitationId: string;
  readonly deliveryGeneration: number;
  readonly attempts: number;
}

/** Sanitized. Counts only — no id, no address, no provider handle. */
export interface DeliveryCounters {
  claimed: number;
  providerAccepted: number;
  retryPending: number;
  outcomeUncertain: number;
  failedPermanent: number;
  cancelled: number;
}

export interface DeliveryDeps {
  /** Injected in tests. Production omits it and gets the real provider. */
  readonly send?: (email: Parameters<typeof defaultSend>[0], transport?: Transport) => Promise<ProviderResult>;
  readonly transport?: Transport;
}

export function emptyCounters(): DeliveryCounters {
  return {
    claimed: 0,
    providerAccepted: 0,
    retryPending: 0,
    outcomeUncertain: 0,
    failedPermanent: 0,
    cancelled: 0,
  };
}

/**
 * The invitation entry point, used VERBATIM. There is no per-recipient path segment and no query
 * string, so this value IS the link — every recipient gets the identical URL.
 *
 * No default. A missing base URL is a CONFIGURATION FAILURE, not a reason to guess: a guessed
 * origin produces a link the recipient cannot distinguish from a broken invitation.
 */
function invitationEntryUrl(): string | null {
  const base = (process.env.INVITATION_LINK_BASE_URL ?? "").trim();
  if (base.length === 0) return null;
  // Trailing slashes trimmed so the value is stable whether or not the operator added one, and so
  // no double slash can appear in the rendered link.
  return base.replace(/\/+$/, "");
}

async function recordOutcome(
  admin: SupabaseClient,
  outboxId: string,
  generation: number,
  outcome: DeliveryOutcome | "cancelled",
  providerMessageId: string | null,
  failureClass: FailureClass | null
): Promise<void> {
  const { error } = await admin.rpc("record_invitation_delivery_outcome", {
    p_outbox_id: outboxId,
    p_delivery_generation: generation,
    p_outcome: outcome,
    p_provider_message_id: providerMessageId,
    p_failure_class: failureClass,
  });
  // Logged by code only. A failure here leaves the row in `processing`, which the next drain
  // re-examines — recoverable, so it must not throw and abort the rest of the batch.
  if (error) console.error("record_invitation_delivery_outcome error:", error.code);
}

function tally(counters: DeliveryCounters, outcome: DeliveryOutcome | "cancelled"): void {
  if (outcome === "providerAccepted") counters.providerAccepted++;
  else if (outcome === "retryPending") counters.retryPending++;
  else if (outcome === "outcomeUncertain") counters.outcomeUncertain++;
  else if (outcome === "failedPermanent") counters.failedPermanent++;
  else counters.cancelled++;
}

/**
 * Prepare, send and record ONE already-claimed row. Returns the outcome so the caller can tally.
 * Never throws — a throw would strand the row in `processing` with nothing written back.
 */
export async function deliverClaimedRow(
  admin: SupabaseClient,
  row: ClaimedRow,
  deps: DeliveryDeps = {}
): Promise<DeliveryOutcome | "cancelled"> {
  const link = invitationEntryUrl();
  if (!link) {
    console.error("delivery: INVITATION_LINK_BASE_URL is not configured");
    await recordOutcome(admin, row.outboxId, row.deliveryGeneration, "failedPermanent", null, "configuration");
    return "failedPermanent";
  }

  // ---- 2. NOTICE (0044). Advances the generation and derives the key. Mints nothing, and does
  //         not touch invitations.token_hash. ----
  const { data, error } = await admin.rpc("issue_invitation_delivery_notice", { p_outbox_id: row.outboxId });
  if (error) {
    // P0005 = the invitation turned terminal between claim and notice; the RPC already cancelled it.
    if (error.code === "P0005") return "cancelled";
    console.error("issue_invitation_delivery_notice error:", error.code);
    await recordOutcome(admin, row.outboxId, row.deliveryGeneration, "retryPending", null, "unknown");
    return "retryPending";
  }

  const issued = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | undefined;
  if (!issued) {
    await recordOutcome(admin, row.outboxId, row.deliveryGeneration, "retryPending", null, "unknown");
    return "retryPending";
  }

  const generation = Number(issued.delivery_generation);
  const idempotencyKey = String(issued.idempotency_key ?? "");
  const recipient = typeof issued.invitee_email === "string" ? issued.invitee_email.trim() : "";
  const preview = (issued.preview_visibility ?? {}) as Record<string, unknown>;

  // The owner's disclosure choices, honoured exactly. A name the owner hid is not substituted.
  const estateName = preview.showEstateName === true && typeof issued.estate_display_name === "string"
    ? issued.estate_display_name : null;
  const inviterName = preview.showInviterName === true && typeof issued.inviter_display_name === "string"
    ? issued.inviter_display_name : null;

  if (!recipient) {
    // Phone-only invitation: there is no SMS provider in this project, so there is nothing to send.
    await recordOutcome(admin, row.outboxId, generation, "failedPermanent", null, "invalid_recipient");
    return "failedPermanent";
  }

  const rendered = renderInvitationEmail({
    estateDisplayName: estateName,
    inviterDisplayName: inviterName,
    expiresAt: new Date(String(issued.expires_at)),
    link,
  });

  // ---- 3. SEND. ----
  const sender = deps.send ?? defaultSend;
  const outbound = {
    to: recipient,
    subject: rendered.subject,
    html: rendered.html,
    text: rendered.text,
    idempotencyKey,
  };

  let result = await sender(outbound, deps.transport);

  // ★ THE ONE PLACE A SEND IS REPEATED. An ambiguous first attempt is retried ONCE with the
  //   IDENTICAL message under the IDENTICAL idempotency key — if the first request did reach
  //   Resend, the key makes the second a no-op rather than a duplicate email. Exactly one extra
  //   attempt: a second ambiguous answer means the network is genuinely unreliable, and hammering
  //   it cannot produce certainty.
  if (result.outcome === "outcomeUncertain") {
    result = await sender(outbound, deps.transport);
  }

  // ---- 4. RECORD. ----
  await recordOutcome(admin, row.outboxId, generation, result.outcome, result.providerMessageId, result.failureClass);
  return result.outcome;
}

/**
 * Claim a bounded batch and deliver each. `outboxId` targets the single row an owner just created
 * (the immediate attempt); omitting it drains oldest-first (the cron).
 *
 * Returns sanitized counters ONLY.
 */
export async function claimAndDeliver(
  admin: SupabaseClient,
  opts: { readonly max?: number; readonly outboxId?: string },
  deps: DeliveryDeps = {}
): Promise<DeliveryCounters> {
  const counters = emptyCounters();

  const { data, error } = await admin.rpc("claim_invitation_deliveries", {
    p_max: opts.outboxId ? 1 : (opts.max ?? 25),
    p_outbox_id: opts.outboxId ?? null,
  });
  if (error) {
    console.error("claim_invitation_deliveries error:", error.code);
    return counters;
  }

  const rows: ClaimedRow[] = (Array.isArray(data) ? data : []).map((r: Record<string, unknown>) => ({
    outboxId: String(r.outbox_id),
    invitationId: String(r.invitation_id),
    deliveryGeneration: Number(r.delivery_generation),
    attempts: Number(r.attempts),
  }));
  counters.claimed = rows.length;

  // Sequential on purpose: a Hobby function has a short wall clock, and a burst of parallel sends
  // is the fastest way to trip a provider rate limit and convert clean work into retryPending.
  for (const row of rows) {
    tally(counters, await deliverClaimedRow(admin, row, deps));
  }
  return counters;
}
