/**
 * Phase 11-K · the owner-safety notice drain.
 *
 * ★ WHAT THIS FILE PROVES AND WHAT IT CANNOT. The fake below models the SEMANTICS of
 * `claim_owner_notices` and `record_owner_notice_outcome` — the age gate applied before the claim,
 * the stale settle, the terminal statuses, the retry cap — so the ORCHESTRATOR can be tested against
 * them. It does not prove the SQL: only Postgres can prove `for update skip locked`, the CHECK
 * constraint, the grants, and the service-role posture. Those are migration 0056's self-check and
 * `db/tests/`, run against a database. No test here is named in a way that implies otherwise.
 *
 * ★ NO NETWORK. The provider is injected in every test. Nothing reaches Resend and no key exists.
 */

import { describe, expect, it, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  claimAndDeliverOwnerNotices,
  deliverClaimedNotice,
  OWNER_NOTICE_BATCH,
} from "../lib/ownerNotices/drain.js";
import { captureConsole } from "./fakes.js";
import type { ProviderResult } from "../lib/email/resendProvider.js";

const LINK = "https://after-worth.com/invitations";
const ESTATE = "33333333-3333-4333-8333-333333333333";
const OWNER_ADDRESS = "owner@example.test";

/** The deployed gate: challenge window (7d) + 1 day of queue slack. */
const AGE_GATE_MS = 8 * 864e5;
const RETRY_CAP = 3;

interface Row {
  id: string;
  estate_id: string;
  recipient: string;
  notice_kind: string;
  status: string;
  attempts: number;
  requested_at: string;
  next_attempt_at: string | null;
  failure_class: string | null;
  dispatched_at: string | null;
}

function makeRow(over: Partial<Row> = {}): Row {
  return {
    id: "44444444-4444-4444-8444-444444444444",
    estate_id: ESTATE,
    recipient: OWNER_ADDRESS,
    notice_kind: "death_process.window_opened",
    status: "queued",
    attempts: 0,
    requested_at: new Date().toISOString(),
    next_attempt_at: null,
    failure_class: null,
    dispatched_at: null,
    ...over,
  };
}

/** Mirrors the two deployed routines. Kept deliberately close to the SQL so a divergence is visible. */
function makeFakeAdmin(rows: Row[], opts: { ageGateConfigured?: boolean } = {}) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const rpc = async (name: string, args: Record<string, unknown>) => {
    calls.push({ name, args });
    const now = Date.now();

    if (name === "claim_owner_notices") {
      if (opts.ageGateConfigured === false) {
        return { data: null, error: { code: "P0001", message: "owner_notice_age_gate_unconfigured" } };
      }
      // STALE FIRST, exactly as the SQL does — so a stale row can never be claimed by the same call.
      for (const r of rows) {
        if (["queued", "processing"].includes(r.status) && now - Date.parse(r.requested_at) > AGE_GATE_MS) {
          r.status = "failedPermanent";
          r.failure_class = "stale_beyond_age_gate";
          r.next_attempt_at = null;
        }
      }
      const max = Math.min(Math.max(Number(args.p_max ?? 25), 1), 100);
      const claimed: Array<Record<string, unknown>> = [];
      for (const r of [...rows].sort((a, b) => a.requested_at.localeCompare(b.requested_at))) {
        if (claimed.length >= max) break;
        if (r.status !== "queued") continue;
        if (now - Date.parse(r.requested_at) > AGE_GATE_MS) continue;
        if (r.next_attempt_at && Date.parse(r.next_attempt_at) > now) continue;
        r.status = "processing";
        r.attempts += 1;
        claimed.push({
          id: r.id, estate_id: r.estate_id, recipient: r.recipient, notice_kind: r.notice_kind,
        });
      }
      return { data: claimed, error: null };
    }

    if (name === "record_owner_notice_outcome") {
      const r = rows.find((x) => x.id === args.p_id);
      if (!r) return { data: null, error: { code: "P0002", message: "outbox_entry_not_found" } };
      if (["dispatched", "outcomeUncertain", "failedPermanent", "cancelled"].includes(r.status)) {
        return { data: r.status, error: null }; // settled: no-op
      }
      const outcome = String(args.p_outcome);
      if (outcome === "providerAccepted") {
        r.status = "dispatched";
        r.dispatched_at = new Date().toISOString();
        r.failure_class = null;
      } else if (outcome === "outcomeUncertain") {
        r.status = "outcomeUncertain";
        r.failure_class = null;
      } else if (outcome === "failedPermanent") {
        r.status = "failedPermanent";
        r.failure_class = (args.p_failure_class as string) ?? null;
      } else {
        if (r.attempts >= RETRY_CAP) {
          r.status = "failedPermanent";
          r.failure_class = ((args.p_failure_class as string) ?? null) ?? "retry_cap_exhausted";
        } else {
          r.status = "queued";
          r.failure_class = (args.p_failure_class as string) ?? null;
          r.next_attempt_at = new Date(now + 36e5).toISOString();
        }
      }
      return { data: r.status, error: null };
    }

    throw new Error(`unexpected rpc: ${name}`);
  };
  return { admin: { rpc } as unknown as SupabaseClient, calls };
}

function provider(...results: ProviderResult[]) {
  const sent: Array<Record<string, unknown>> = [];
  let i = 0;
  const send = async (email: Record<string, unknown>): Promise<ProviderResult> => {
    sent.push(email);
    return results[Math.min(i++, results.length - 1)];
  };
  return { send: send as never, sent };
}

const accepted: ProviderResult = { outcome: "providerAccepted", providerMessageId: "msg_1", failureClass: null };
const uncertain: ProviderResult = { outcome: "outcomeUncertain", providerMessageId: null, failureClass: "timeout" };
const retry: ProviderResult = { outcome: "retryPending", providerMessageId: null, failureClass: "rate_limited" };
const permanent: ProviderResult = { outcome: "failedPermanent", providerMessageId: null, failureClass: "invalid_recipient" };

const ORIGINAL_BASE = process.env.INVITATION_LINK_BASE_URL;
beforeEach(() => { process.env.INVITATION_LINK_BASE_URL = LINK; });
afterEach(() => {
  if (ORIGINAL_BASE === undefined) delete process.env.INVITATION_LINK_BASE_URL;
  else process.env.INVITATION_LINK_BASE_URL = ORIGINAL_BASE;
});

describe("owner notice drain — the happy path", () => {
  it("claims a fresh row, sends once, and records dispatched", async () => {
    const rows = [makeRow()];
    const { admin } = makeFakeAdmin(rows);
    const p = provider(accepted);

    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });

    expect(counters).toEqual({
      claimed: 1, dispatched: 1, retryPending: 0, outcomeUncertain: 0, failedPermanent: 0,
    });
    expect(p.sent).toHaveLength(1);
    expect(rows[0].status).toBe("dispatched");
    expect(rows[0].dispatched_at).not.toBeNull();
  });

  it("sends to the address stored at dispatch, never to one this module chose", async () => {
    const rows = [makeRow({ recipient: "stored-at-dispatch@example.test" })];
    const { admin } = makeFakeAdmin(rows);
    const p = provider(accepted);

    await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });

    expect(p.sent[0].to).toBe("stored-at-dispatch@example.test");
  });

  it("uses a deterministic idempotency key carrying only the outbox id", async () => {
    const rows = [makeRow()];
    const { admin } = makeFakeAdmin(rows);
    const p = provider(accepted);

    await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });

    const key = String(p.sent[0].idempotencyKey);
    expect(key).toBe(`afterworth/owner-notice/${rows[0].id}`);
    // The key is a surrogate: it must not carry the estate or the recipient.
    expect(key).not.toContain(ESTATE);
    expect(key).not.toContain(OWNER_ADDRESS);
  });

  /**
   * ★ PHASE 11-OC / PHASE C — THE DISTINCTION THE IDEMPOTENCY DOMAIN ENCODES, AND WHY NO CODE
   * CHANGE WAS REQUIRED TO GET IT.
   *
   *     ACCIDENTAL RETRY   → same row, same id, SAME key      → the provider no-ops a repeat
   *     DELIBERATE REISSUE → new row, new id,  NEW key        → a genuinely new message
   *
   * `reissue_owner_safety_notice` APPENDS a generation rather than requeuing the terminal row, so the
   * successor has its own primary key and therefore its own idempotency domain — for free, as a
   * property of the id rather than of a flag anybody remembers to set. The two assertions below pin
   * both halves, because a "fix" that requeued the old row would silently collapse them into one and
   * the second warning would never leave the building.
   *
   * ★ AND THIS IS AT-LEAST-ONCE, NOT EXACTLY-ONCE. The provider's dedupe retention is a vendor
   * property this repository does not pin; the key makes a repeat CHEAP to ignore, never impossible
   * to deliver twice.
   */
  it("gives a DELIBERATE re-notice its own idempotency domain, because it is a new row", async () => {
    const gen1 = makeRow({ id: "44444444-4444-4444-8444-444444444444" });
    const gen2 = makeRow({
      id: "55555555-5555-4555-8555-555555555555",
      notice_kind: "death_process.window_renotice",
    });

    const a = provider(accepted);
    await claimAndDeliverOwnerNotices(makeFakeAdmin([gen1]).admin, {}, { send: a.send });
    const b = provider(accepted);
    await claimAndDeliverOwnerNotices(makeFakeAdmin([gen2]).admin, {}, { send: b.send });

    expect(String(a.sent[0].idempotencyKey)).toBe(`afterworth/owner-notice/${gen1.id}`);
    expect(String(b.sent[0].idempotencyKey)).toBe(`afterworth/owner-notice/${gen2.id}`);
    expect(a.sent[0].idempotencyKey).not.toBe(b.sent[0].idempotencyKey);
    // The key is derived from the ROW, never from the kind or a generation counter — so it cannot
    // drift apart from the identity the database actually assigns.
    expect(String(b.sent[0].idempotencyKey)).not.toContain("renotice");
  });

  /**
   * ★ THE SECOND WARNING SAYS THE SAME THING AS THE FIRST, AND THAT IS A PRODUCT DECISION.
   *
   * `renderOwnerNoticeEmail` takes ONLY the link — no kind, no generation, no attempt count, no
   * failure class — so it is structurally incapable of telling a recipient "this is our second
   * attempt to reach you". Internal state is not user copy, and on this channel the rule is sharper
   * than usual: the recipient may be the target of a false claim, and narrating our delivery troubles
   * would spend their attention on our problem instead of theirs.
   *
   * Asserted by BYTE EQUALITY across the two kinds rather than by reading the template, because the
   * claim is about what the drain sends, not about what the renderer's signature looks like.
   */
  it("sends byte-identical copy for a re-notice and for the initial notice", async () => {
    const a = provider(accepted);
    await claimAndDeliverOwnerNotices(
      makeFakeAdmin([makeRow()]).admin, {}, { send: a.send });
    const b = provider(accepted);
    await claimAndDeliverOwnerNotices(
      makeFakeAdmin([makeRow({ notice_kind: "death_process.window_renotice" })]).admin,
      {}, { send: b.send });

    expect(b.sent[0].subject).toBe(a.sent[0].subject);
    expect(b.sent[0].html).toBe(a.sent[0].html);
    expect(b.sent[0].text).toBe(a.sent[0].text);
    // Nothing in the message names the internal vocabulary, on either kind.
    for (const field of [b.sent[0].subject, b.sent[0].html, b.sent[0].text]) {
      expect(String(field)).not.toContain("renotice");
      expect(String(field)).not.toContain("generation");
      expect(String(field)).not.toContain("failedPermanent");
    }
  });

  /**
   * ★ THE DRAIN IS KIND-AGNOSTIC BY CONSTRUCTION, AND THAT IS WHY PHASE C NEEDED NO WORKER CHANGE.
   * `claim_owner_notices` applies no kind filter and this module branches on none, so a re-notice is
   * claimed, sent and settled by exactly the code path the initial notice uses. A kind check here
   * would be a second vocabulary to keep in step with the SQL one.
   */
  it("claims and settles a re-notice through the identical path", async () => {
    const rows = [makeRow({ notice_kind: "death_process.window_renotice" })];
    const { admin, calls } = makeFakeAdmin(rows);
    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: provider(accepted).send });

    expect(counters.claimed).toBe(1);
    expect(counters.dispatched).toBe(1);
    expect(rows[0].status).toBe("dispatched");
    // No kind was passed to the claim RPC — the server decides what is claimable.
    expect(Object.keys(calls[0].args)).toEqual(["p_max"]);
  });
});

describe("owner notice drain — an ambiguous send is never turned into two emails", () => {
  it("retries an uncertain send exactly once, under the identical idempotency key", async () => {
    const rows = [makeRow()];
    const { admin } = makeFakeAdmin(rows);
    const p = provider(uncertain, uncertain);

    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });

    expect(p.sent).toHaveLength(2);
    expect(p.sent[0].idempotencyKey).toBe(p.sent[1].idempotencyKey);
    expect(counters.outcomeUncertain).toBe(1);
  });

  it("settles a still-uncertain row as outcomeUncertain, which is TERMINAL", async () => {
    const rows = [makeRow()];
    const { admin } = makeFakeAdmin(rows);
    await claimAndDeliverOwnerNotices(admin, {}, { send: provider(uncertain, uncertain).send });
    expect(rows[0].status).toBe("outcomeUncertain");

    // ★ THE LOAD-BEARING ASSERTION. A second drain must not re-send a message that may already be
    // in a living owner's inbox. If `outcomeUncertain` ever became claimable this fails.
    const second = provider(accepted);
    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: second.send });
    expect(counters.claimed).toBe(0);
    expect(second.sent).toHaveLength(0);
  });

  it("stops at one retry when the second attempt succeeds", async () => {
    const rows = [makeRow()];
    const { admin } = makeFakeAdmin(rows);
    const p = provider(uncertain, accepted);

    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });

    expect(p.sent).toHaveLength(2);
    expect(counters.dispatched).toBe(1);
    expect(rows[0].status).toBe("dispatched");
  });
});

describe("owner notice drain — retry and the cap", () => {
  it("returns a provider-refused row to queued so the next drain retries it", async () => {
    const rows = [makeRow()];
    const { admin } = makeFakeAdmin(rows);
    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: provider(retry).send });

    expect(counters.retryPending).toBe(1);
    expect(rows[0].status).toBe("queued");
    expect(rows[0].next_attempt_at).not.toBeNull();
  });

  it("burns the row failedPermanent once the attempt cap is spent", async () => {
    const rows = [makeRow({ attempts: RETRY_CAP, next_attempt_at: null })];
    const { admin } = makeFakeAdmin(rows);
    await claimAndDeliverOwnerNotices(admin, {}, { send: provider(retry).send });

    expect(rows[0].status).toBe("failedPermanent");
  });

  it("records a permanent provider refusal without retrying", async () => {
    const rows = [makeRow()];
    const { admin } = makeFakeAdmin(rows);
    const p = provider(permanent);
    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });

    expect(p.sent).toHaveLength(1);
    expect(counters.failedPermanent).toBe(1);
    expect(rows[0].status).toBe("failedPermanent");
    expect(rows[0].failure_class).toBe("invalid_recipient");
  });
});

describe("owner notice drain — the age gate is the server's, and it is not re-implemented here", () => {
  it("never sends a stale notice, and the drain reports having sent nothing", async () => {
    const stale = makeRow({ requested_at: new Date(Date.now() - 30 * 864e5).toISOString() });
    const { admin } = makeFakeAdmin([stale]);
    const p = provider(accepted);

    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });

    expect(p.sent).toHaveLength(0);
    expect(counters.claimed).toBe(0);
    expect(stale.status).toBe("failedPermanent");
    expect(stale.failure_class).toBe("stale_beyond_age_gate");
  });

  it("sends a fresh notice in the same batch as a stale one, and only the fresh one", async () => {
    // ★ ANCHORED ON INPUT THE FILTER MUST CHANGE. A batch of only-fresh or only-stale rows would
    // pass with the gate deleted; this one interleaves, so it cannot.
    const stale = makeRow({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", recipient: "stale@example.test",
      requested_at: new Date(Date.now() - 30 * 864e5).toISOString() });
    const fresh = makeRow({ id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", recipient: "fresh@example.test" });
    const { admin } = makeFakeAdmin([stale, fresh]);
    const p = provider(accepted);

    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });

    expect(counters.claimed).toBe(1);
    expect(p.sent.map((e) => e.to)).toEqual(["fresh@example.test"]);
    expect(stale.status).toBe("failedPermanent");
    expect(fresh.status).toBe("dispatched");
  });

  it("drains nothing at all when the age gate is unconfigured", async () => {
    const rows = [makeRow()];
    const { admin } = makeFakeAdmin(rows, { ageGateConfigured: false });
    const p = provider(accepted);
    const cap = captureConsole();

    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });
    cap.restore();

    expect(counters.claimed).toBe(0);
    expect(p.sent).toHaveLength(0);
    expect(rows[0].status).toBe("queued"); // untouched, not burned
  });
});

describe("owner notice drain — configuration failure claims nothing", () => {
  it("refuses BEFORE claiming when the entry URL is unset, leaving the queue intact", async () => {
    delete process.env.INVITATION_LINK_BASE_URL;
    const rows = [makeRow()];
    const { admin, calls } = makeFakeAdmin(rows);
    const p = provider(accepted);
    const cap = captureConsole();

    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: p.send });
    cap.restore();

    expect(counters.claimed).toBe(0);
    expect(p.sent).toHaveLength(0);
    // ★ THE POINT: no claim was even attempted, so no live safety row was moved to `processing`
    // and then burned for a configuration mistake.
    expect(calls.filter((c) => c.name === "claim_owner_notices")).toHaveLength(0);
    expect(rows[0].status).toBe("queued");
  });
});

describe("owner notice drain — nothing identifying reaches a log or a response", () => {
  it("emits counters only, with no id, address, estate or provider handle", async () => {
    const rows = [makeRow()];
    const { admin } = makeFakeAdmin(rows);
    const counters = await claimAndDeliverOwnerNotices(admin, {}, { send: provider(accepted).send });

    const serialized = JSON.stringify(counters);
    expect(serialized).not.toContain(OWNER_ADDRESS);
    expect(serialized).not.toContain(ESTATE);
    expect(serialized).not.toContain(rows[0].id);
    expect(serialized).not.toContain("msg_1");
    expect(Object.keys(counters).sort()).toEqual(
      ["claimed", "dispatched", "failedPermanent", "outcomeUncertain", "retryPending"]
    );
  });

  it("keeps the recipient out of the log on a record-outcome failure", async () => {
    const rows = [makeRow()];
    const admin = {
      rpc: async (name: string) => {
        if (name === "claim_owner_notices") {
          rows[0].status = "processing";
          return { data: [{ id: rows[0].id, estate_id: ESTATE, recipient: OWNER_ADDRESS,
                            notice_kind: rows[0].notice_kind }], error: null };
        }
        return { data: null, error: { code: "P0002", message: `boom for ${OWNER_ADDRESS}` } };
      },
    } as unknown as SupabaseClient;

    const cap = captureConsole();
    await claimAndDeliverOwnerNotices(admin, {}, { send: provider(accepted).send });
    cap.restore();

    const logged = cap.lines.join("\n");
    expect(logged).toContain("record_owner_notice_outcome error");
    // The RPC's MESSAGE carried the address; only its CODE may be logged.
    expect(logged).not.toContain(OWNER_ADDRESS);
  });
});

describe("owner notice drain — batching", () => {
  it("asks for the bounded batch size by default", async () => {
    const { admin, calls } = makeFakeAdmin([makeRow()]);
    await claimAndDeliverOwnerNotices(admin, {}, { send: provider(accepted).send });
    expect(calls[0].args.p_max).toBe(OWNER_NOTICE_BATCH);
  });

  it("settles a row with no destination rather than re-claiming it forever", async () => {
    const rows = [makeRow({ recipient: "" })];
    const { admin } = makeFakeAdmin(rows);
    rows[0].status = "processing";
    const p = provider(accepted);

    const outcome = await deliverClaimedNotice(
      admin,
      { id: rows[0].id, estateId: ESTATE, recipient: "", noticeKind: rows[0].notice_kind },
      LINK,
      { send: p.send }
    );

    expect(outcome).toBe("failedPermanent");
    expect(p.sent).toHaveLength(0);
    expect(rows[0].status).toBe("failedPermanent");
  });
});
