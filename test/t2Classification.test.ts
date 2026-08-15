/**
 * PHASE 11-OB PREP · T2 CLASSIFICATION CONTROLS.
 *
 * ★ THE CLOCK IS AN ARGUMENT IN EVERY ONE OF THESE TESTS. "queued, attempts = 0" is the correct
 * resting state before the drain and a broken safety channel after it — the SAME row, classified
 * oppositely by nothing but the time. A test that read the real clock would flip meaning overnight
 * and would have been passing for the wrong reason on whichever side of 04:00Z it happened to run.
 *
 * ★ EVERY BOUNDARY FIXTURE ASSERTS ITS OWN PRECONDITION. The transformation-integrity rule: if a
 * fixture already sits on the expected side of the boundary before the rule runs, the test is not a
 * control. Each pair below is anchored either side of one computed instant, and the instant is
 * asserted.
 */
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_DRAIN_GRACE_MS,
  NOTICE_STATUS,
  T2,
  T2_DELIVERY_CAVEAT,
  classifyT2,
  drainScheduleFromManifest,
  nextDrainOpportunityAfter,
  parseDailyCron,
  parseInstant,
} from "../scripts/lib/t2Classification.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** The deployed schedule, parsed the way the observer parses it. */
const MANIFEST = JSON.parse(readFileSync(join(ROOT, "vercel.json"), "utf8"));
const SCHEDULE = drainScheduleFromManifest(MANIFEST);

/** Fixed, in the past, and unrelated to whenever this suite runs. */
const ENQUEUED = "2026-08-15T06:46:18.000Z";

const notice = (over: Record<string, unknown> = {}) => ({
  id: "11111111-2222-3333-4444-555555555555",
  channel: "email",
  notice_kind: "death_process_initiated",
  status: "queued",
  requested_at: ENQUEUED,
  dispatched_at: null,
  attempts: 0,
  failure_class: null,
  next_attempt_at: null,
  ...over,
});

const classify = (over: Record<string, unknown>, now: string, extra: Record<string, unknown> = {}) =>
  classifyT2({ notice: notice(over), now, schedule: SCHEDULE, ...extra });

describe("0 · the instrument is real and single-sourced", () => {
  it("the deployed manifest genuinely schedules the claims drain", () => {
    // ★ POSITIVE CONTROL. Every boundary below is computed from this. If the manifest stopped
    //   scheduling the drain, SCHEDULE would be null and every classification would answer
    //   `drain_schedule_unreadable` — which must fail here rather than pass quietly downstream.
    expect(MANIFEST.crons.some((c: { path: string }) => c.path === "/api/claims/drain_outboxes")).toBe(true);
    expect(SCHEDULE).not.toBeNull();
    expect(SCHEDULE!.hour).toBeGreaterThanOrEqual(0);
    expect(SCHEDULE!.hour).toBeLessThanOrEqual(23);
  });

  it("the status vocabulary matches the deployed CHECK-bearing routine", () => {
    // Read from source rather than restated, so a schema change fails here first.
    const sql = readFileSync(join(ROOT, "db/functions/outbox_safety.sql"), "utf8");
    for (const status of NOTICE_STATUS) expect(sql).toContain(`'${status}'`);
  });

  it("the caveat names the specific reason delivery is unprovable", () => {
    expect(T2_DELIVERY_CAVEAT).toMatch(/no provider message id/i);
    expect(T2_DELIVERY_CAVEAT).toMatch(/no delivery webhook/i);
    expect(T2_DELIVERY_CAVEAT).toMatch(/independent out-of-band/i);
  });
});

describe("1 · cron parsing refuses everything it cannot mean exactly", () => {
  it("parses the daily form", () => {
    expect(parseDailyCron("0 4 * * *")).toMatchObject({ minute: 0, hour: 4 });
    expect(parseDailyCron("30 4 * * *")).toMatchObject({ minute: 30, hour: 4 });
  });

  it.each([
    ["*/15 * * * *", "step syntax"],
    ["0 4 * * 1", "day-of-week restriction"],
    ["0 4,16 * * *", "hour list"],
    ["0 4 1 * *", "day-of-month restriction"],
    ["0 4 * *", "four fields"],
    ["0 24 * * *", "hour out of range"],
    ["60 4 * * *", "minute out of range"],
    ["", "empty"],
  ])("refuses %s (%s) rather than approximating it", (expr) => {
    expect(parseDailyCron(expr)).toBeNull();
  });

  it("a manifest without the drain path yields no schedule", () => {
    expect(drainScheduleFromManifest({ crons: [{ path: "/api/other", schedule: "0 4 * * *" }] })).toBeNull();
    expect(drainScheduleFromManifest({ crons: [] })).toBeNull();
    expect(drainScheduleFromManifest({})).toBeNull();
  });
});

describe("2 · the next drain opportunity is strictly after the enqueue", () => {
  const sched = parseDailyCron("0 4 * * *")!;

  it("an enqueue before the hour is drained the same day", () => {
    expect(nextDrainOpportunityAfter("2026-08-15T01:00:00.000Z", sched)!.toISOString()).toBe(
      "2026-08-15T04:00:00.000Z"
    );
  });

  it("an enqueue after the hour waits for tomorrow", () => {
    expect(nextDrainOpportunityAfter(ENQUEUED, sched)!.toISOString()).toBe("2026-08-16T04:00:00.000Z");
  });

  it("★ an enqueue at exactly the cron instant is NOT drained by that run", () => {
    // Strict, for the same reason the release door is strict: the run cannot carry a row that did
    // not exist when it started.
    expect(nextDrainOpportunityAfter("2026-08-15T04:00:00.000Z", sched)!.toISOString()).toBe(
      "2026-08-16T04:00:00.000Z"
    );
  });

  it("month and year roll over", () => {
    expect(nextDrainOpportunityAfter("2026-12-31T23:59:59.000Z", sched)!.toISOString()).toBe(
      "2027-01-01T04:00:00.000Z"
    );
  });
});

describe("★ 3 · the required classification matrix", () => {
  const OPPORTUNITY = nextDrainOpportunityAfter(ENQUEUED, SCHEDULE!)!;
  const beforeOpportunity = new Date(OPPORTUNITY.getTime() - 60_000).toISOString();
  const afterOpportunity = new Date(OPPORTUNITY.getTime() + DEFAULT_DRAIN_GRACE_MS + 60_000).toISOString();

  it("the fixture straddles the opportunity — the precondition every case below depends on", () => {
    // ★ Without this, both clocks could land on one side and the pair would prove nothing.
    expect(new Date(beforeOpportunity).getTime()).toBeLessThan(OPPORTUNITY.getTime());
    expect(new Date(afterOpportunity).getTime()).toBeGreaterThan(OPPORTUNITY.getTime() + DEFAULT_DRAIN_GRACE_MS);
    expect(new Date(beforeOpportunity).getTime()).toBeGreaterThan(new Date(ENQUEUED).getTime());
  });

  it("queued + attempts=0 BEFORE the cron opportunity → T2_PENDING", () => {
    const r = classify({ status: "queued", attempts: 0 }, beforeOpportunity);
    expect(r.verdict).toBe(T2.PENDING);
    expect(r.reason).toBe("before_first_drain_opportunity");
  });

  it("★ queued + attempts=0 AFTER the cron opportunity → T2_DRAIN_DID_NOT_RUN", () => {
    const r = classify({ status: "queued", attempts: 0 }, afterOpportunity);
    expect(r.verdict).toBe(T2.DRAIN_DID_NOT_RUN);
    expect(r.reason).toBe("never_claimed");
  });

  it("inside the grace margin it is still pending, not a missed drain", () => {
    const withinGrace = new Date(OPPORTUNITY.getTime() + DEFAULT_DRAIN_GRACE_MS - 60_000).toISOString();
    expect(classify({ status: "queued", attempts: 0 }, withinGrace).verdict).toBe(T2.PENDING);
  });

  it("failedPermanent → T2_DELIVERY_FAILED, carrying the class", () => {
    const r = classify(
      { status: "failedPermanent", attempts: 3, failure_class: "provider_rejected" },
      afterOpportunity
    );
    expect(r.verdict).toBe(T2.DELIVERY_FAILED);
    expect(r.reason).toBe("provider_rejected");
  });

  it("a stale-swept notice is a delivery failure with the age-gate class", () => {
    const r = classify(
      { status: "failedPermanent", attempts: 0, failure_class: "stale_beyond_age_gate" },
      afterOpportunity
    );
    expect(r.verdict).toBe(T2.DELIVERY_FAILED);
    expect(r.reason).toBe("stale_beyond_age_gate");
  });

  it("★ providerAccepted WITHOUT an independent observation → T2_PROVIDER_ACCEPTED_ONLY", () => {
    const r = classify(
      { status: "dispatched", attempts: 1, dispatched_at: "2026-08-16T04:00:12.000Z" },
      afterOpportunity
    );
    expect(r.verdict).toBe(T2.PROVIDER_ACCEPTED_ONLY);
    // ★ THE WHOLE POINT. Never DELIVERED on backend state alone.
    expect(r.verdict).not.toBe(T2.DELIVERED);
  });

  it("★ an explicit independently-observed delivery → T2_DELIVERED", () => {
    const r = classify(
      { status: "dispatched", attempts: 1, dispatched_at: "2026-08-16T04:00:12.000Z" },
      afterOpportunity,
      { deliveryObservedAt: "2026-08-16T04:03:00.000Z" }
    );
    expect(r.verdict).toBe(T2.DELIVERED);
  });

  it("★ a delivery observation the backend does not corroborate is REFUSED", () => {
    // The gate must not clear because a human asserted arrival for a row never handed to a provider.
    const r = classify({ status: "queued", attempts: 0 }, afterOpportunity, {
      deliveryObservedAt: "2026-08-16T04:03:00.000Z",
    });
    expect(r.verdict).toBe(T2.UNVERIFIABLE);
    expect(r.reason).toBe("delivery_observed_without_provider_acceptance");
  });

  it("a delivery observed before the notice was even enqueued is refused", () => {
    const r = classify(
      { status: "dispatched", attempts: 1, dispatched_at: "2026-08-16T04:00:12.000Z" },
      afterOpportunity,
      { deliveryObservedAt: "2026-08-14T00:00:00.000Z" }
    );
    expect(r.verdict).toBe(T2.UNVERIFIABLE);
    expect(r.reason).toBe("delivery_observed_before_enqueue");
  });
});

describe("★ 4 · unknown and inconsistent state fails closed", () => {
  const now = "2026-08-20T00:00:00.000Z";

  it.each([
    [{ status: "sent" }, "unknown_status"],
    [{ status: "dispatched", dispatched_at: null }, "dispatched_without_timestamp"],
    [{ status: "queued", dispatched_at: "2026-08-16T04:00:00.000Z" }, "dispatch_timestamp_on_undispatched_row"],
    [{ requested_at: null }, "requested_at_unreadable"],
    [{ requested_at: "not-a-date" }, "requested_at_unreadable"],
    [{ attempts: -1 }, "attempts_unreadable"],
    [{ attempts: 1.5 }, "attempts_unreadable"],
    [{ attempts: null }, "attempts_unreadable"],
    [{ status: "outcomeUncertain", attempts: 2 }, "provider_outcome_uncertain"],
  ])("%o → T2_UNVERIFIABLE (%s)", (over, reason) => {
    const r = classify(over as Record<string, unknown>, now);
    expect(r.verdict).toBe(T2.UNVERIFIABLE);
    expect(r.reason).toBe(reason);
  });

  it("a missing row is unverifiable, never 'nothing went wrong'", () => {
    expect(classifyT2({ notice: null, now, schedule: SCHEDULE }).verdict).toBe(T2.UNVERIFIABLE);
  });

  it("a missing clock is unverifiable", () => {
    expect(classifyT2({ notice: notice(), now: null, schedule: SCHEDULE }).verdict).toBe(T2.UNVERIFIABLE);
  });

  it("★ a missing schedule cannot silently become 'pending'", () => {
    const r = classifyT2({ notice: notice(), now, schedule: null });
    expect(r.verdict).toBe(T2.UNVERIFIABLE);
    expect(r.reason).toBe("drain_schedule_unreadable");
  });

  it("outcomeUncertain is neither delivered nor failed — the provider never answered", () => {
    const r = classify({ status: "outcomeUncertain", attempts: 2 }, now);
    expect(r.verdict).not.toBe(T2.DELIVERY_FAILED);
    expect(r.verdict).not.toBe(T2.PROVIDER_ACCEPTED_ONLY);
    expect(r.verdict).toBe(T2.UNVERIFIABLE);
  });
});

describe("5 · in-flight and retry states", () => {
  const OPPORTUNITY = nextDrainOpportunityAfter(ENQUEUED, SCHEDULE!)!;

  it("processing shortly after the claim is pending", () => {
    const r = classify(
      { status: "processing", attempts: 1 },
      new Date(OPPORTUNITY.getTime() + 60_000).toISOString()
    );
    expect(r.verdict).toBe(T2.PENDING);
    expect(r.reason).toBe("claimed_in_flight");
  });

  it("★ processing long past the opportunity is UNVERIFIABLE, not pending", () => {
    // Claimed and never settled: the provider may or may not hold the message. Reporting this as
    // pending would suggest an outcome is still coming; nothing is coming until the stale sweep.
    const r = classify(
      { status: "processing", attempts: 1 },
      new Date(OPPORTUNITY.getTime() + 5 * DEFAULT_DRAIN_GRACE_MS).toISOString()
    );
    expect(r.verdict).toBe(T2.UNVERIFIABLE);
    expect(r.reason).toBe("claimed_but_unsettled");
  });

  it("a requeued row inside its backoff is pending", () => {
    const r = classify(
      { status: "queued", attempts: 1, next_attempt_at: "2026-08-20T06:00:00.000Z" },
      "2026-08-20T05:00:00.000Z"
    );
    expect(r.verdict).toBe(T2.PENDING);
    expect(r.reason).toBe("retry_backoff");
  });

  it("★ a requeued row whose next opportunity has passed is a missed drain, not a retry", () => {
    const due = "2026-08-20T06:00:00.000Z";
    const nextOpp = nextDrainOpportunityAfter(due, SCHEDULE!)!;
    const after = new Date(nextOpp.getTime() + DEFAULT_DRAIN_GRACE_MS + 60_000).toISOString();
    expect(new Date(after).getTime()).toBeGreaterThan(new Date(due).getTime()); // precondition
    const r = classify({ status: "queued", attempts: 1, next_attempt_at: due }, after);
    expect(r.verdict).toBe(T2.DRAIN_DID_NOT_RUN);
    expect(r.reason).toBe("requeued_and_not_reclaimed");
  });

  it("cancelled is terminal and does not clear the gate", () => {
    const r = classify({ status: "cancelled", attempts: 0 }, "2026-08-20T00:00:00.000Z");
    expect(r.verdict).toBe(T2.DELIVERY_FAILED);
    expect(r.reason).toBe("notice_cancelled");
  });
});

describe("6 · instant parsing", () => {
  it.each([null, undefined, "", "   ", "not-a-date", 42, {}])("%o is not an instant", (v) => {
    expect(parseInstant(v as never)).toBeNull();
  });
  it("accepts ISO-8601 and Date alike", () => {
    expect(parseInstant("2026-08-15T06:46:18.000Z")!.toISOString()).toBe("2026-08-15T06:46:18.000Z");
    expect(parseInstant(new Date(0))!.toISOString()).toBe("1970-01-01T00:00:00.000Z");
  });
  it("an Invalid Date object is refused", () => {
    expect(parseInstant(new Date("nope"))).toBeNull();
  });
});

describe("7 · repeated evaluation is identical — no stateful matcher", () => {
  it("the same input classified twice in one process agrees", () => {
    const args = { notice: notice(), now: "2026-08-20T00:00:00.000Z", schedule: SCHEDULE };
    expect(JSON.stringify(classifyT2(args))).toBe(JSON.stringify(classifyT2(args)));
  });
});
