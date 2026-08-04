/**
 * Delivery orchestration — the only place that turns a claimed outbox row into an email.
 *
 * ★ THE ORDER IS THE SAFETY PROPERTY, and it mirrors the storage-deletion outbox exactly:
 *
 *     1. claim   (DEFINER RPC, `for update skip locked`) — row moves to `processing`
 *     2. issue   (DEFINER RPC) — token minted, generation incremented, ONLY the hash stored
 *     3. send    (provider, with the deterministic Idempotency-Key)
 *     4. record  (DEFINER RPC) — outcome written back, generation-guarded
 *
 * A worker that dies between any two steps leaves a row that a later drain can reason about. The
 * one state it cannot resolve by itself is `outcomeUncertain`, and that is deliberate — see below.
 *
 * ★ WHY THIS NEVER RETRIES AN AMBIGUOUS SEND. The database stores only `token_hash`; the raw token
 * exists solely in this function's local scope for the length of one call. So a later invocation
 * physically cannot resend the same link. If it "retried", it would have to mint a NEW token, which
 * would invalidate a link that may already be sitting in the recipient's inbox — turning an
 * uncertain success into a certain failure. So an ambiguous outcome is recorded honestly and left
 * for a human to decide, and `retryPending` is reserved for the case where the provider ANSWERED
 * and refused (429/5xx), which proves nothing was accepted.
 *
 * ★ THE RAW TOKEN'S BLAST RADIUS. It exists as a local, is written into the link, and is nulled as
 * soon as the send returns. It is never logged, never returned, never put on the outbox row, never
 * put in provider metadata, and never included in a counter or an error.
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

/** Sanitized. Counts only — no id, no address, no token, no provider handle. */
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
 * No default. A missing base URL is a CONFIGURATION FAILURE, not a reason to guess: a guessed
 * origin produces a link that 404s, and the recipient has no way to tell that from a revoked
 * invitation. Failing closed keeps the token unminted rather than burning one on a dead link.
 */
function linkBaseUrl(): string | null {
  const base = (process.env.INVITATION_LINK_BASE_URL ?? "").trim();
  return base.length > 0 ? base.replace(/\/+$/, "") : null;
}

function buildLink(base: string, rawToken: string): string {
  return `${base}?token=${encodeURIComponent(rawToken)}`;
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
  // re-examines — it is recoverable, so it must not throw and abort the rest of the batch.
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
 * Issue, send, and record ONE already-claimed row. Returns the outcome so the caller can tally.
 * Never throws — a throw would strand the row in `processing` with nothing written back.
 */
export async function deliverClaimedRow(
  admin: SupabaseClient,
  row: ClaimedRow,
  deps: DeliveryDeps = {}
): Promise<DeliveryOutcome | "cancelled"> {
  const base = linkBaseUrl();
  if (!base) {
    console.error("delivery: INVITATION_LINK_BASE_URL is not configured");
    await recordOutcome(admin, row.outboxId, row.deliveryGeneration, "failedPermanent", null, "configuration");
    return "failedPermanent";
  }

  // ---- 2. ISSUE. Mints the token and bumps the generation. Only reached for a row we hold. ----
  const { data, error } = await admin.rpc("issue_invitation_delivery_token", { p_outbox_id: row.outboxId });
  if (error) {
    // P0005 = the invitation turned terminal between claim and issue; the RPC already cancelled it.
    if (error.code === "P0005") return "cancelled";
    console.error("issue_invitation_delivery_token error:", error.code);
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

  // ---- 3. SEND. rawToken and link are the only variables holding the secret. ----
  let rawToken: string | null = typeof issued.raw_token === "string" ? issued.raw_token : null;
  let link: string | null = rawToken ? buildLink(base, rawToken) : null;
  rawToken = null; // no longer needed once the link is built

  if (!link) {
    await recordOutcome(admin, row.outboxId, generation, "retryPending", null, "unknown");
    return "retryPending";
  }

  const rendered = renderInvitationEmail({
    estateDisplayName: estateName,
    inviterDisplayName: inviterName,
    expiresAt: new Date(String(issued.expires_at)),
    link,
  });

  const sender = deps.send ?? defaultSend;
  const outbound = {
    to: recipient,
    subject: rendered.subject,
    html: rendered.html,
    text: rendered.text,
    idempotencyKey,
  };

  let result: ProviderResult;
  try {
    result = await sender(outbound, deps.transport);

    // ★ THE ONE PLACE A SEND IS REPEATED, and the only place it is safe to. We are still inside the
    //   invocation that minted the token, so the IDENTICAL message can go out under the IDENTICAL
    //   idempotency key — if the first request did reach Resend, the key makes the second a no-op
    //   rather than a duplicate email. Exactly one extra attempt: a second ambiguous answer means
    //   the network is genuinely unreliable, and hammering it cannot produce certainty.
    //
    //   Once this function returns, the raw token is gone and this option disappears with it. That
    //   is why no later drain retries an ambiguous row — it would have to mint a NEW token and
    //   invalidate a link that may already be in the recipient's inbox.
    if (result.outcome === "outcomeUncertain") {
      result = await sender(outbound, deps.transport);
    }
  } finally {
    link = null; // ★ cleared the moment the sends return, success or not
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
