/**
 * Owner-safety notice delivery — the drain that 11-F built the safety for and deliberately did not
 * wire.
 *
 * ★ THE ORDER IS THE SAFETY PROPERTY, and it is the invitation drain's order with one step removed:
 *
 *     1. claim   (DEFINER RPC, `for update skip locked`) — fresh rows move to `processing`,
 *                 stale rows are settled failedPermanent FIRST and never handed out
 *     2. send    (provider, with a deterministic Idempotency-Key)
 *     3. record  (DEFINER RPC) — outcome written back, already-settled rows a no-op
 *
 * There is no "notice" step because there is nothing to mint: this message carries no token, no
 * per-recipient URL, and no estate content. `claim_owner_notices` returns the recipient because
 * `dispatch_owner_safety_notice` already resolved and stored it.
 *
 * ★ THE ADDRESS IS NOT THIS MODULE'S TO CHOOSE, AND CANNOT BE OVERRIDDEN. It was resolved at
 * dispatch time from `auth.users.email` — the address the account authenticates with, which a
 * claimant cannot repoint — and committed to the outbox row in the same transaction as the lifecycle
 * transition. This drain sends to `row.recipient` and has no parameter, env var, header or request
 * body through which any other destination could enter. Two consequences worth stating:
 *
 *   · A CLAIMANT CANNOT SUPPLY OR REDIRECT IT. There is no code path from claimant-controlled input
 *     to a destination address. `owner_notice_outbox` has no client grants at all, so the stored
 *     value is unwritable except by the DEFINER routine that resolved it.
 *   · IT IS DELIBERATELY NOT RE-RESOLVED AT SEND TIME. Re-reading `auth.users` here would send the
 *     notice to whatever address the account carries NOW — which, if an attacker has just taken the
 *     account and changed the email, is the attacker. The dispatch-time snapshot is the address the
 *     owner had when the process started, and that is the one that must be warned.
 *
 * ★ THE AGE GATE IS THE SERVER'S, NOT THIS WORKER'S. `claim_owner_notices` applies it before
 * handing anything over: rows older than the challenge window + 1 day are settled
 * `failedPermanent`/`stale_beyond_age_gate` and are never returned, so this module CANNOT send a
 * stale notice even if it tried. Re-implementing the gate here would be a second, drifting copy of
 * a decision that already has one authoritative home. A drain that ran after a long outage
 * therefore settles the backlog and sends nothing from it — which is the intended behaviour, not a
 * failure: a notice about a window that has already closed arrives as either a false alarm or an
 * alarm nobody can act on.
 *
 * ★ THE RESPONSE AND EVERY LOG LINE ARE COUNTERS ONLY. No outbox id, no estate id, no case id, no
 * recipient address, no provider message id. A cron log is retained by the platform indefinitely,
 * so anything emitted here is effectively permanent — and this queue's rows are, by construction,
 * about living people who may be the target of a false claim.
 *
 * ★ DELIVERY LAG IS REAL, IS BOUNDED, AND COSTS THE OWNER PART OF THEIR WINDOW. Vercel Hobby limits
 * cron frequency to DAILY, so a queued notice can wait up to ~24h for this drain. The challenge
 * clock is stamped at DISPATCH (`owner_notified_at`), not at delivery — so that lag is subtracted
 * from the owner's 7 days rather than added to them, leaving a worst case of ~6 days of email-aware
 * window. Two things bound the damage and neither is an accident:
 *
 *   · The IN-APP notice commits in the same transaction as the dispatch, so an owner who opens the
 *     app is notified immediately. This channel exists for the owner who does not.
 *   · The age gate is 8 days, comfortably wider than the lag, so lag alone can never turn a fresh
 *     notice stale.
 *
 * Raising this to hourly requires Vercel Pro and one line in `vercel.json`. It is recorded as a
 * launch consideration in `docs/phase11k-operator-console.md` rather than left to be discovered.
 */

import type { SupabaseClient } from "@supabase/supabase-js";
import { ownerNoticeEntryUrl, renderOwnerNoticeEmail } from "./ownerNoticeTemplate.js";
import {
  send as defaultSend,
  type DeliveryOutcome,
  type FailureClass,
  type ProviderResult,
  type Transport,
} from "../email/resendProvider.js";

/** Bounded so one invocation cannot exceed the function wall clock and strand claimed rows. */
export const OWNER_NOTICE_BATCH = 25;

export interface ClaimedNotice {
  readonly id: string;
  readonly estateId: string;
  readonly recipient: string;
  readonly noticeKind: string;
}

/** Sanitized. Counts only — no id, no address, no provider handle. */
export interface OwnerNoticeCounters {
  claimed: number;
  dispatched: number;
  retryPending: number;
  outcomeUncertain: number;
  failedPermanent: number;
}

export interface OwnerNoticeDeps {
  /** Injected in tests. Production omits it and gets the real provider. */
  readonly send?: (email: Parameters<typeof defaultSend>[0], transport?: Transport) => Promise<ProviderResult>;
  readonly transport?: Transport;
}

export function emptyOwnerNoticeCounters(): OwnerNoticeCounters {
  return { claimed: 0, dispatched: 0, retryPending: 0, outcomeUncertain: 0, failedPermanent: 0 };
}

async function recordOutcome(
  admin: SupabaseClient,
  id: string,
  outcome: DeliveryOutcome,
  failureClass: FailureClass | null
): Promise<void> {
  const { error } = await admin.rpc("record_owner_notice_outcome", {
    p_id: id,
    p_outcome: outcome,
    p_failure_class: failureClass,
  });
  // Logged by CODE only — a PostgREST error message can echo row values. A failure here leaves the
  // row in `processing`; the stale sweep will eventually settle it, and the next drain re-examines
  // it. Recoverable, so it must not throw and abort the rest of the batch.
  if (error) console.error("record_owner_notice_outcome error:", error.code);
}

function tally(counters: OwnerNoticeCounters, outcome: DeliveryOutcome): void {
  if (outcome === "providerAccepted") counters.dispatched++;
  else if (outcome === "retryPending") counters.retryPending++;
  else if (outcome === "outcomeUncertain") counters.outcomeUncertain++;
  else counters.failedPermanent++;
}

/**
 * Send and record ONE already-claimed notice. Never throws — a throw would strand the row in
 * `processing` with nothing written back.
 */
export async function deliverClaimedNotice(
  admin: SupabaseClient,
  row: ClaimedNotice,
  link: string,
  deps: OwnerNoticeDeps = {}
): Promise<DeliveryOutcome> {
  const recipient = row.recipient?.trim() ?? "";
  if (!recipient) {
    // Unreachable through the dispatch routine, which refuses the whole transition on an
    // unresolvable address. Handled anyway: a row with no destination is permanently undeliverable,
    // and settling it is how it stops being re-claimed forever.
    await recordOutcome(admin, row.id, "failedPermanent", "invalid_recipient");
    return "failedPermanent";
  }

  const rendered = renderOwnerNoticeEmail(link);
  const outbound = {
    to: recipient,
    subject: rendered.subject,
    html: rendered.html,
    text: rendered.text,
    // Surrogate id only — never the estate, the case, or the recipient. Deterministic per row, so a
    // same-row retry is a provider no-op rather than a second message. There is no generation
    // counter because a safety notice is dispatched once and never re-minted.
    idempotencyKey: `afterworth/owner-notice/${row.id}`,
  };

  const sender = deps.send ?? defaultSend;
  let result = await sender(outbound, deps.transport);

  // ★ THE ONE PLACE A SEND IS REPEATED, and only for an AMBIGUOUS first attempt: retried ONCE with
  //   the IDENTICAL message under the IDENTICAL idempotency key, so if the first request did reach
  //   the provider the second is a no-op rather than a duplicate. Exactly one extra attempt — a
  //   second ambiguous answer means the network is genuinely unreliable, and hammering it cannot
  //   produce certainty. A still-uncertain outcome is then TERMINAL (recorded as such), because a
  //   second copy of this particular message is not a cost worth paying for a lost HTTP response.
  if (result.outcome === "outcomeUncertain") {
    result = await sender(outbound, deps.transport);
  }

  await recordOutcome(admin, row.id, result.outcome, result.failureClass);
  return result.outcome;
}

/**
 * Claim a bounded batch and deliver each. Returns sanitized counters ONLY.
 *
 * `claimed` is the count the claim RPC returned — the FRESH rows. Rows the same call settled as
 * stale are not returned by the RPC and so are not counted here; `owner_notice_census()` is the
 * surface that reports them, and it reports them against the current age gate.
 */
export async function claimAndDeliverOwnerNotices(
  admin: SupabaseClient,
  opts: { readonly max?: number } = {},
  deps: OwnerNoticeDeps = {}
): Promise<OwnerNoticeCounters> {
  const counters = emptyOwnerNoticeCounters();

  const link = ownerNoticeEntryUrl();
  if (!link) {
    // ★ REFUSE BEFORE CLAIMING, NOT AFTER. Claiming first would move live safety rows into
    //   `processing` and then burn them all as failedPermanent for a configuration mistake — an
    //   owner un-notified because an env var was unset. Claiming nothing leaves the queue intact
    //   for the next run, once someone fixes the config.
    console.error("ownerNotices: INVITATION_LINK_BASE_URL is not configured; claimed nothing");
    return counters;
  }

  const { data, error } = await admin.rpc("claim_owner_notices", {
    p_max: opts.max ?? OWNER_NOTICE_BATCH,
  });
  if (error) {
    // `owner_notice_age_gate_unconfigured` lands here: with no configured challenge window there is
    // no defensible notion of "too old", so the RPC refuses to drain at all. Correct, and visible.
    console.error("claim_owner_notices error:", error.code);
    return counters;
  }

  const rows: ClaimedNotice[] = (Array.isArray(data) ? data : []).map((r: Record<string, unknown>) => ({
    id: String(r.id),
    estateId: String(r.estate_id),
    recipient: typeof r.recipient === "string" ? r.recipient : "",
    noticeKind: String(r.notice_kind),
  }));
  counters.claimed = rows.length;

  // Sequential on purpose: a burst of parallel sends is the fastest way to trip a provider rate
  // limit and convert clean work into retryPending on the one queue where lateness matters most.
  for (const row of rows) {
    tally(counters, await deliverClaimedNotice(admin, row, link, deps));
  }
  return counters;
}
