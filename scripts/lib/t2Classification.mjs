/**
 * PHASE 11-OB PREP · T2 CLASSIFICATION — what the owner-notice channel can and cannot prove.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE ONE THING THIS MODULE EXISTS TO REFUSE: `dispatched` IS NOT `delivered`.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `record_owner_notice_outcome` writes `status = 'dispatched'` when the provider answered
 * `providerAccepted`. `resendProvider.ts` states in its own header what that word means: "Resend
 * answered with a message id. It accepted the message FOR delivery. That is not delivered,
 * received, opened, or viewed, and nothing downstream is allowed to rename it."
 *
 * This module is downstream. It does not rename it.
 *
 * ★ AND THE SCHEMA CANNOT BE MADE TO PROVE DELIVERY, BY DESIGN. `record_owner_notice_outcome`
 * documents that no provider message id is stored and the table gains no column for one: "A provider
 * handle is a lookup key into a third party's log of a message addressed to a living owner." There
 * is no delivery webhook, no bounce table, no `delivered_at`. So there is no query — none, at any
 * privilege level — that returns inbox arrival. `T2_DELIVERED` is therefore reachable ONLY from an
 * explicit, out-of-band, human-supplied observation, and even then only when the backend
 * independently agrees the message was handed to a provider at all.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE OBSERVABLE FACT INVENTORY (Stage 1), and where each fact comes from.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 *   REQUIRED DISTINCTION    OBSERVABLE?   EVIDENCE
 *   QUEUED                  yes           status = 'queued'
 *   CLAIMED / PROCESSING    yes           status = 'processing'  (attempts incremented by the claim)
 *   PROVIDER_ACCEPTED       yes           status = 'dispatched' + dispatched_at
 *   DELIVERED               ★ NO          nothing in the schema records it; see above
 *   FAILED                  yes           status = 'failedPermanent' + failure_class
 *   STALE                   yes           failure_class = 'stale_beyond_age_gate'
 *
 * `claimed_at` EXISTS since migration 0057 (Phase 11-OBR / OB-1) — `claim_owner_notices` stamps it
 * on every claim, and the reclaim predicate times out against it. It is NOT readable from here:
 * `admin_get_death_verification_case` does not select the column, so the observer prints the
 * sentinel `NOT_OBSERVABLE_HERE` rather than a value. This comment previously asserted the column
 * did not exist and the observer printed a hard-coded `null` — after the OB-1 recovery that would
 * have read as a failed claim stamp on a row that had just been re-claimed successfully.
 *
 * Classification never depended on it, and still must not: `attempts` is what proves a claim.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE DRAIN OPPORTUNITY IS READ FROM `vercel.json`, NEVER REMEMBERED.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * "queued with attempts = 0" means one of two opposite things depending only on the clock: BEFORE
 * the first scheduled drain it is the correct resting state, and AFTER it the drain did not run.
 * A hardcoded `04:00Z` would silently answer the wrong question the day someone edits the cron, so
 * the schedule is parsed from the deployment manifest and an unparseable one is a refusal, not a
 * default.
 *
 * ★ EVERY BOUNDARY IS FAIL-CLOSED. Unknown status, contradictory timestamps, a delivery claim the
 * backend does not corroborate, an unparseable schedule — all of these answer `T2_UNVERIFIABLE`.
 * The one verdict that clears the owner-email-delivery gate is `T2_DELIVERED`, and nothing reaches
 * it by inference.
 *
 * PURE. No clock, no network, no filesystem. The caller injects `now`.
 */

/** The verdict vocabulary. Closed — `classifyT2` returns nothing outside it. */
export const T2 = Object.freeze({
  DELIVERED: 'T2_DELIVERED',
  PROVIDER_ACCEPTED_ONLY: 'T2_PROVIDER_ACCEPTED_ONLY',
  DELIVERY_FAILED: 'T2_DELIVERY_FAILED',
  DRAIN_DID_NOT_RUN: 'T2_DRAIN_DID_NOT_RUN',
  PENDING: 'T2_PENDING',
  UNVERIFIABLE: 'T2_UNVERIFIABLE',
});

/**
 * The deployed `owner_notice_outbox.status` vocabulary, from `outbox_safety.sql`.
 * A status outside this set is a schema change this module has not been taught, and is refused.
 */
export const NOTICE_STATUS = Object.freeze([
  'queued',
  'processing',
  'dispatched',
  'outcomeUncertain',
  'failedPermanent',
  'cancelled',
]);

/**
 * How long after a scheduled cron instant the drain is still allowed to be "about to happen".
 * Vercel cron is best-effort and not instantaneous; below this margin a queued row is PENDING, above
 * it the opportunity is considered missed. Deliberately generous — a false `DRAIN_DID_NOT_RUN`
 * would be read as a broken safety channel.
 */
export const DEFAULT_DRAIN_GRACE_MS = 60 * 60 * 1000;

/**
 * How far BEFORE `dispatched_at` a human delivery observation may fall and still be believed.
 *
 * Not slop. It covers exactly two things a delivery attestation cannot avoid: a mail client that
 * displays MINUTES (so an honest 04:41:31 is reported as 04:41), and the fact that the mailbox
 * timestamp and `dispatched_at` come from two clocks nobody has synchronised. Requiring strict
 * ordering across those would manufacture precision that does not exist.
 *
 * Five minutes absorbs both and remains three orders of magnitude below the five-hour timezone
 * error the guard exists to reject.
 */
export const DELIVERY_OBSERVATION_TOLERANCE_MS = 5 * 60 * 1000;

const isFiniteInstant = (v) => v instanceof Date && Number.isFinite(v.getTime());

/** ISO-8601 → Date, or null. Rejects the empty string and `Invalid Date` alike. */
export function parseInstant(value) {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) return isFiniteInstant(value) ? value : null;
  if (typeof value !== 'string' || value.trim() === '') return null;
  const d = new Date(value);
  return isFiniteInstant(d) ? d : null;
}

/**
 * Parse a DAILY cron expression of the exact shape `M H * * *`.
 *
 * ★ IT REFUSES EVERY OTHER SHAPE RATHER THAN APPROXIMATING ONE. Step syntax, lists, ranges and
 * day-of-week restrictions all change what "the next opportunity" means, and a parser that guessed
 * would place the boundary somewhere defensible-looking and wrong. Returns null; the caller reports
 * COULD NOT VERIFY.
 */
export function parseDailyCron(expr) {
  if (typeof expr !== 'string') return null;
  const parts = expr.trim().split(/\s+/);
  if (parts.length !== 5) return null;
  const [minute, hour, dom, month, dow] = parts;
  if (dom !== '*' || month !== '*' || dow !== '*') return null;
  if (!/^\d{1,2}$/.test(minute) || !/^\d{1,2}$/.test(hour)) return null;
  const m = Number(minute);
  const h = Number(hour);
  if (m > 59 || h > 23) return null;
  return Object.freeze({ minute: m, hour: h, expression: expr.trim() });
}

/**
 * The cron entry that drains the owner-notice queue, read from a parsed `vercel.json`.
 *
 * The owner-notice half has NO ENDPOINT OF ITS OWN — `outbox_safety.sql` records that
 * `drain_owner_notices` is a log label, not a route, and that probing it returns 404. It rides the
 * claims cron slot. So the path this looks for is the claims drain, and a manifest that no longer
 * schedules it is a refusal.
 */
export function drainScheduleFromManifest(manifest, path = '/api/claims/drain_outboxes') {
  const crons = manifest && Array.isArray(manifest.crons) ? manifest.crons : null;
  if (!crons || crons.length === 0) return null;
  const entry = crons.find((c) => c && c.path === path);
  if (!entry) return null;
  return parseDailyCron(entry.schedule);
}

/**
 * The first instant at or after which the daily drain was scheduled to run, STRICTLY after `after`.
 *
 * Strict: a row enqueued at exactly 04:00:00Z is not drained by the 04:00:00Z run it did not exist
 * for. Same tie-breaking discipline as the release door.
 */
export function nextDrainOpportunityAfter(after, schedule) {
  const from = parseInstant(after);
  if (!from || !schedule) return null;
  const candidate = new Date(
    Date.UTC(
      from.getUTCFullYear(),
      from.getUTCMonth(),
      from.getUTCDate(),
      schedule.hour,
      schedule.minute,
      0,
      0
    )
  );
  if (candidate.getTime() <= from.getTime()) candidate.setUTCDate(candidate.getUTCDate() + 1);
  return candidate;
}

const verdict = (v, reason, extra = {}) => Object.freeze({ verdict: v, reason, ...extra });

/**
 * Classify one owner-notice outbox row into the T2 vocabulary.
 *
 * @param {object}  input
 * @param {object|null} input.notice            the projected row (never carries `recipient`)
 * @param {Date|string} input.now               INJECTED clock — this module never reads one
 * @param {object|null} input.schedule          from `drainScheduleFromManifest`
 * @param {number}  [input.graceMs]
 * @param {string|Date|null} [input.deliveryObservedAt]  an INDEPENDENT out-of-band observation
 */
export function classifyT2({ notice, now, schedule, graceMs = DEFAULT_DRAIN_GRACE_MS, deliveryObservedAt = null }) {
  const nowAt = parseInstant(now);
  if (!nowAt) return verdict(T2.UNVERIFIABLE, 'clock_not_supplied');
  if (!notice || typeof notice !== 'object') return verdict(T2.UNVERIFIABLE, 'no_notice_row');

  const status = notice.status;
  if (!NOTICE_STATUS.includes(status)) {
    return verdict(T2.UNVERIFIABLE, 'unknown_status', { observed_status: String(status) });
  }

  const requestedAt = parseInstant(notice.requested_at);
  if (!requestedAt) return verdict(T2.UNVERIFIABLE, 'requested_at_unreadable');

  const attempts = notice.attempts;
  if (!Number.isInteger(attempts) || attempts < 0) {
    return verdict(T2.UNVERIFIABLE, 'attempts_unreadable');
  }

  const dispatchedAt = parseInstant(notice.dispatched_at);
  // ★ The two directions of the same contradiction. `record_owner_notice_outcome` stamps
  //   dispatched_at IF AND ONLY IF the row becomes `dispatched`, so either mismatch means the row
  //   was written by something other than that routine — which is exactly when a confident verdict
  //   is least defensible.
  if (status === 'dispatched' && !dispatchedAt) {
    return verdict(T2.UNVERIFIABLE, 'dispatched_without_timestamp');
  }
  if (status !== 'dispatched' && dispatchedAt) {
    return verdict(T2.UNVERIFIABLE, 'dispatch_timestamp_on_undispatched_row', { observed_status: status });
  }

  // ★ AN INDEPENDENT DELIVERY OBSERVATION IS THE ONLY ROUTE TO `T2_DELIVERED` — and it must be
  //   CORROBORATED. Accepting the operator's word alone would let a mistaken observation clear the
  //   owner-email-delivery gate against a row the backend says was never handed to a provider.
  if (deliveryObservedAt !== null && deliveryObservedAt !== undefined) {
    const observedAt = parseInstant(deliveryObservedAt);
    if (!observedAt) return verdict(T2.UNVERIFIABLE, 'delivery_observation_unreadable');
    if (status !== 'dispatched') {
      return verdict(T2.UNVERIFIABLE, 'delivery_observed_without_provider_acceptance', {
        observed_status: status,
      });
    }
    if (observedAt.getTime() < requestedAt.getTime()) {
      return verdict(T2.UNVERIFIABLE, 'delivery_observed_before_enqueue');
    }
    /**
     * ★ AND IT MUST NOT PRE-DATE THE SEND — the bound `requested_at` cannot supply.
     *
     * Enqueue is the wrong corroboration anchor. A notice can sit `queued` for days before a worker
     * touches it, so "after enqueue" admits any instant in that whole window, including instants
     * hours before the provider was ever handed the message. Mail cannot arrive before it is sent.
     *
     * ★ FOUND BY A REAL ATTESTATION, NOT BY REVIEW. The Branch A closeout was attested as
     * "2026-08-16 23:41" against a row whose `dispatched_at` was 2026-08-17T04:41:31Z. Read as local
     * time (CDT) that is 04:41Z — an exact match, and the truth. Read as UTC it is FIVE HOURS BEFORE
     * the provider accepted the message, and the old rule returned `T2_DELIVERED` for it anyway,
     * because 23:41 on the 16th is still comfortably after the 15th enqueue.
     *
     * A bare local timestamp is exactly what a human reads off a mail client, so the ambiguous case
     * is the COMMON case, and the gate this clears is the one protecting a living owner's chance to
     * object. `dispatched_at` is non-null here by construction (status is `dispatched`, checked
     * above, and the two are stamped together).
     *
     * ★ THE TOLERANCE IS NOT SLOP, AND A STRICT COMPARISON WAS TRIED FIRST AND WAS WRONG. The real
     * attestation read `23:41` against a dispatch at `04:41:31Z` — the SAME minute, and a strict
     * `<` refused it over 31 seconds. Two independent reasons forbid strictness here:
     *
     *   · QUANTISATION. A mail client displays minutes, so an honest observation of 04:41:31 is
     *     reported as 04:41 and is legitimately up to 59s "early".
     *   · UNSYNCHRONISED CLOCKS. `dispatched_at` is Postgres's clock; the mailbox timestamp is the
     *     mail provider's. Requiring strict ordering across two clocks nobody has synchronised
     *     manufactures precision that does not exist — the repository's own cross-device rule.
     *
     * Five minutes absorbs both and is still three orders of magnitude smaller than the five-hour
     * timezone error this guard exists to catch. The guard rejects a WRONG DAY or a WRONG ZONE; it
     * does not adjudicate seconds.
     */
    if (dispatchedAt && observedAt.getTime() < dispatchedAt.getTime() - DELIVERY_OBSERVATION_TOLERANCE_MS) {
      return verdict(T2.UNVERIFIABLE, 'delivery_observed_before_provider_accepted', {
        delivery_observed_at: observedAt.toISOString(),
        dispatched_at: dispatchedAt.toISOString(),
      });
    }
    return verdict(T2.DELIVERED, 'independently_observed_and_provider_accepted', {
      delivery_observed_at: observedAt.toISOString(),
    });
  }

  if (status === 'dispatched') {
    // The high-water mark of what backend state can establish. Not delivery.
    return verdict(T2.PROVIDER_ACCEPTED_ONLY, 'provider_accepted_no_independent_observation');
  }
  if (status === 'failedPermanent') {
    return verdict(T2.DELIVERY_FAILED, notice.failure_class ?? 'failed_permanent_unclassified');
  }
  if (status === 'cancelled') {
    // Terminal and definite: no email will be sent. Not a provider failure, and not pending —
    // reported as a failure of the CHANNEL because the gate it feeds can never clear from here.
    return verdict(T2.DELIVERY_FAILED, 'notice_cancelled');
  }
  if (status === 'outcomeUncertain') {
    // The provider never answered. `resendProvider.ts`: "NOT a failure and NOT a success."
    return verdict(T2.UNVERIFIABLE, 'provider_outcome_uncertain');
  }

  // Everything below needs the schedule.
  if (!schedule) return verdict(T2.UNVERIFIABLE, 'drain_schedule_unreadable');

  if (status === 'processing') {
    const claimDeadline = nextDrainOpportunityAfter(requestedAt, schedule).getTime() + graceMs;
    if (nowAt.getTime() <= claimDeadline) {
      return verdict(T2.PENDING, 'claimed_in_flight');
    }
    // Claimed, and no outcome was ever written back. The provider may or may not hold it.
    return verdict(T2.UNVERIFIABLE, 'claimed_but_unsettled');
  }

  // status === 'queued'
  const dueFrom = parseInstant(notice.next_attempt_at) ?? requestedAt;
  if (nowAt.getTime() < dueFrom.getTime()) {
    return verdict(T2.PENDING, 'retry_backoff', { due_from: dueFrom.toISOString() });
  }
  const opportunity = nextDrainOpportunityAfter(dueFrom, schedule);
  if (nowAt.getTime() <= opportunity.getTime() + graceMs) {
    return verdict(T2.PENDING, 'before_first_drain_opportunity', {
      first_opportunity_at: opportunity.toISOString(),
    });
  }
  // ★ THE LOAD-BEARING BRANCH. Past the opportunity and still queued: the scheduled drain did not
  //   claim this row. `attempts` distinguishes "never claimed at all" from "claimed, failed, and
  //   then missed by a later run" — both are the drain not running, and neither is pending.
  return verdict(T2.DRAIN_DID_NOT_RUN, attempts === 0 ? 'never_claimed' : 'requeued_and_not_reclaimed', {
    first_opportunity_at: opportunity.toISOString(),
    attempts,
  });
}

/**
 * The sentence every report must carry. Kept here so no caller can quote a verdict without it.
 */
export const T2_DELIVERY_CAVEAT =
  'Backend state cannot prove inbox delivery. owner_notice_outbox stores no provider message id, ' +
  'there is no delivery webhook and no delivered_at column, so `dispatched` means the provider ' +
  'ACCEPTED the message and nothing more. T2_DELIVERED requires an independent out-of-band ' +
  'observation supplied by a human.';
