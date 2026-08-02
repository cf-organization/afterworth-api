/**
 * Delivery orchestration.
 *
 * These exercise the claim → issue → send → record sequence against a fake that models the 0043
 * state machine. Where the property under test is genuinely a DATABASE property (`for update skip
 * locked`, the CHECK constraints, the grants), the test name says which part is modelled and the
 * real proof lives in db/verification/0043_invitation_delivery_verification.sql.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { claimAndDeliver, deliverClaimedRow } from "../lib/invitations/delivery.js";
import { captureConsole, jsonResponse, makeDb, makeFakeAdmin, makeTransport, MAX_ATTEMPTS } from "./fakes.js";
import type { ProviderResult } from "../lib/email/resendProvider.js";

const OUTBOX_ID = "22222222-2222-4222-8222-222222222222";
const ENTRY_URL = "https://invite.example.test/i";

beforeEach(() => {
  process.env.INVITATION_LINK_BASE_URL = ENTRY_URL;
});
afterEach(() => {
  delete process.env.INVITATION_LINK_BASE_URL;
});

/** A send double that records what it was asked to send and returns a scripted outcome. */
function scriptedSender(results: ProviderResult[]) {
  const calls: Array<{ to: string; idempotencyKey: string; html: string; text: string }> = [];
  let i = 0;
  const send = async (e: { to: string; idempotencyKey: string; html: string; text: string }) => {
    calls.push({ to: e.to, idempotencyKey: e.idempotencyKey, html: e.html, text: e.text });
    return results[Math.min(i++, results.length - 1)];
  };
  return { send, calls };
}

const accepted: ProviderResult = { outcome: "providerAccepted", providerMessageId: "msg_1", failureClass: null };
const uncertain: ProviderResult = { outcome: "outcomeUncertain", providerMessageId: null, failureClass: "timeout" };
const transient: ProviderResult = { outcome: "retryPending", providerMessageId: null, failureClass: "provider_unavailable" };
const permanent: ProviderResult = { outcome: "failedPermanent", providerMessageId: null, failureClass: "invalid_recipient" };

describe("the immediate attempt", () => {
  it("sends once and settles the row to providerAccepted", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    const counters = await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    expect(counters).toMatchObject({ claimed: 1, providerAccepted: 1 });
    expect(calls).toHaveLength(1);
    expect(db.outbox[0].status).toBe("providerAccepted");
    expect(db.outbox[0].provider_message_id).toBe("msg_1");
    expect(db.outbox[0].delivery_generation).toBe(1);
  });

  it("records a provider failure without pretending anything was sent", async () => {
    const db = makeDb();
    const { send } = scriptedSender([permanent]);
    const counters = await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    expect(counters.failedPermanent).toBe(1);
    expect(db.outbox[0].status).toBe("failedPermanent");
    expect(db.outbox[0].failure_class).toBe("invalid_recipient");
    expect(db.outbox[0].provider_message_id).toBeNull();
  });

  it("★ records an ambiguous response as outcomeUncertain, not as success or failure", async () => {
    const db = makeDb();
    const { send } = scriptedSender([uncertain]);
    const counters = await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    expect(counters.outcomeUncertain).toBe(1);
    expect(db.outbox[0].status).toBe("outcomeUncertain");
    expect(counters.providerAccepted).toBe(0);
    expect(counters.failedPermanent).toBe(0);
  });

  it("★ an ambiguous response retries ONCE in-process with the SAME idempotency key", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([uncertain, uncertain]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    expect(calls).toHaveLength(2);
    expect(calls[1].idempotencyKey).toBe(calls[0].idempotencyKey); // ← the whole point
    expect(calls[1].html).toBe(calls[0].html);                     // same link, same message
    expect(db.outbox[0].delivery_generation).toBe(1);              // ← one notice, not two
    expect(db.outbox[0].status).toBe("outcomeUncertain");
  });

  it("an ambiguous first attempt that succeeds on the in-process retry is providerAccepted", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([uncertain, accepted]);
    const counters = await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    expect(calls).toHaveLength(2);
    expect(calls[1].idempotencyKey).toBe(calls[0].idempotencyKey);
    expect(counters.providerAccepted).toBe(1);
    expect(db.outbox[0].status).toBe("providerAccepted");
  });

  it("stops after exactly one in-process retry — it never loops", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([uncertain, uncertain, uncertain]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });
    expect(calls).toHaveLength(2);
  });

  it("fails closed when no link base URL is configured, before taking a notice", async () => {
    delete process.env.INVITATION_LINK_BASE_URL;
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    expect(calls).toHaveLength(0);
    // Configuration is checked BEFORE the notice RPC, so no generation is burned on a dead link.
    expect(db.tokenHashReads).toHaveLength(0);
    expect(db.outbox[0].delivery_generation).toBe(0);
    expect(db.outbox[0].status).toBe("failedPermanent");
  });
});

describe("★ generations, retries, and the absence of any secret", () => {
  it("an ambiguous outcome does NOT trigger a second notice on its own", async () => {
    const db = makeDb();
    const { send } = scriptedSender([uncertain]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    expect(db.outbox[0].delivery_generation).toBe(1);
    // outcomeUncertain is not claimable, so no drain picks it up and quietly emails again.
    const second = await claimAndDeliver(makeFakeAdmin(db), { max: 10 }, { send });
    expect(second.claimed).toBe(0);
    expect(db.outbox[0].delivery_generation).toBe(1);
  });

  it("a cron retry after a DEFINITIVE refusal takes a fresh generation and a fresh key", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([transient, accepted]);
    const admin = makeFakeAdmin(db);

    await claimAndDeliver(admin, { outboxId: OUTBOX_ID }, { send });
    expect(db.outbox[0].status).toBe("retryPending");

    db.outbox[0].next_attempt_at = new Date(Date.now() - 1000).toISOString();
    await claimAndDeliver(admin, { max: 10 }, { send });

    expect(calls).toHaveLength(2);
    // retryPending means the provider ANSWERED and refused, so nothing reached anyone. The retry
    // is a second attempt at the same informational email; the key must not collide with the first,
    // or Resend would dedupe a genuinely-needed send away.
    expect(new Set(calls.map((c) => c.idempotencyKey)).size).toBe(2);
    expect(calls.every((c) => c.idempotencyKey.startsWith(`afterworth/invitation/${OUTBOX_ID}/`))).toBe(true);
    expect(db.outbox[0].delivery_generation).toBe(2);
  });

  it("★ an ambiguous row is never claimed by a later drain, so no duplicate email is sent", async () => {
    const db = makeDb();
    const { send } = scriptedSender([uncertain, uncertain]);
    const admin = makeFakeAdmin(db);

    await claimAndDeliver(admin, { outboxId: OUTBOX_ID }, { send });
    expect(db.outbox[0].status).toBe("outcomeUncertain");

    // Even with time advanced and next_attempt_at forced, outcomeUncertain is not in the claim
    // predicate — recovery requires a deliberate human decision, not a schedule.
    db.outbox[0].next_attempt_at = new Date(Date.now() - 864e5).toISOString();
    const later = await claimAndDeliver(admin, { max: 25 }, { send });

    expect(later.claimed).toBe(0);
    expect(db.outbox[0].delivery_generation).toBe(1);
  });

  it("an owner-initiated redelivery gets its own key, and leaves token_hash alone", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    const admin = makeFakeAdmin(db);
    const originalHash = db.invitations[0].token_hash;

    await claimAndDeliver(admin, { outboxId: OUTBOX_ID }, { send });
    const firstKey = calls[0].idempotencyKey;

    // An owner-initiated redelivery enqueues a NEW outbox row (0042's request_invitation_redelivery).
    db.outbox.push({ ...db.outbox[0], id: "44444444-4444-4444-8444-444444444444", status: "queued",
      attempts: 0, delivery_generation: 0, idempotency_key: null, provider_message_id: null,
      failure_class: null, next_attempt_at: null, issued_at: null,
      requested_at: new Date(Date.now() + 1000).toISOString() });

    await claimAndDeliver(admin, { max: 10 }, { send });

    expect(calls).toHaveLength(2);
    expect(calls[1].idempotencyKey).not.toBe(firstKey);
    // ★ 0043's minter overwrote token_hash on every send, silently killing any prior link. The
    //   token-free path must never touch it — not on a first send, not on a redelivery.
    expect(db.invitations[0].token_hash).toBe(originalHash);
    expect(db.tokenHashReads.every((h) => h === originalHash)).toBe(true);
  });
});

describe("the cron drain", () => {
  it("recovers a queued row the immediate attempt never reached", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    const counters = await claimAndDeliver(makeFakeAdmin(db), { max: 25 }, { send });

    expect(counters).toMatchObject({ claimed: 1, providerAccepted: 1 });
    expect(calls).toHaveLength(1);
  });

  it("a second drain over an already-accepted row sends nothing", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    const admin = makeFakeAdmin(db);

    await claimAndDeliver(admin, { max: 25 }, { send });
    const second = await claimAndDeliver(admin, { max: 25 }, { send });

    expect(second.claimed).toBe(0);
    expect(calls).toHaveLength(1); // ← sent exactly once
  });

  it("two overlapping drains send once (models SKIP LOCKED; SQL proof is in the harness)", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    const admin = makeFakeAdmin(db);

    // Interleaved: both start before either records an outcome.
    await Promise.all([
      claimAndDeliver(admin, { max: 25 }, { send }),
      claimAndDeliver(admin, { max: 25 }, { send }),
    ]);

    expect(calls).toHaveLength(1);
    expect(db.outbox[0].delivery_generation).toBe(1);
  });

  it("skips a terminal invitation and cancels the row instead of sending", async () => {
    for (const status of ["revoked", "accepted", "declined"]) {
      const db = makeDb();
      db.invitations[0].status = status;
      const { send, calls } = scriptedSender([accepted]);
      const counters = await claimAndDeliver(makeFakeAdmin(db), { max: 25 }, { send });

      expect(calls, `status=${status}`).toHaveLength(0);
      expect(counters.claimed).toBe(0);
      expect(db.outbox[0].status).toBe("cancelled");
      expect(db.tokenHashReads).toHaveLength(0);
    }
  });

  it("skips an expired invitation the same way", async () => {
    const db = makeDb();
    db.invitations[0].expires_at = new Date(Date.now() - 864e5).toISOString();
    const { send, calls } = scriptedSender([accepted]);
    await claimAndDeliver(makeFakeAdmin(db), { max: 25 }, { send });

    expect(calls).toHaveLength(0);
    expect(db.outbox[0].status).toBe("cancelled");
  });

  it("★ enforces the retry cap and lands on failedPermanent", async () => {
    const db = makeDb();
    db.outbox[0].attempts = MAX_ATTEMPTS - 1; // next claim takes it to the cap
    const { send } = scriptedSender([transient]);
    await claimAndDeliver(makeFakeAdmin(db), { max: 25 }, { send });

    expect(db.outbox[0].attempts).toBe(MAX_ATTEMPTS);
    expect(db.outbox[0].status).toBe("failedPermanent");
    expect(db.outbox[0].next_attempt_at).toBeNull();
  });

  it("a failedPermanent row is never claimed again", async () => {
    const db = makeDb();
    db.outbox[0].status = "failedPermanent";
    const { send, calls } = scriptedSender([accepted]);
    const counters = await claimAndDeliver(makeFakeAdmin(db), { max: 25 }, { send });

    expect(counters.claimed).toBe(0);
    expect(calls).toHaveLength(0);
  });
});

describe("★ the email carries no secret at all", () => {
  it("the link is the bare configured entry point — every recipient gets the identical URL", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    // No token, no invitation id, no estate id, no per-person segment, no query string.
    expect(calls[0].html).toContain(ENTRY_URL);
    expect(calls[0].text).toContain(ENTRY_URL);
    for (const body of [calls[0].html, calls[0].text]) {
      expect(body).not.toMatch(/[?&]token=/);
      expect(body).not.toMatch(/\/i\/[0-9a-f]{16,}/);
      expect(body).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
    }
  });

  it("two different invitations produce byte-identical links", async () => {
    const linksFor = async (invitationEmail: string) => {
      const db = makeDb();
      db.invitations[0].invitee_email = invitationEmail;
      const { send, calls } = scriptedSender([accepted]);
      await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });
      return calls[0];
    };
    const a = await linksFor("one@example.test");
    const b = await linksFor("two@example.test");

    // Same URL for both, and the recipient address is the ONLY difference between the sends.
    expect(a.html).toBe(b.html);
    expect(a.to).not.toBe(b.to);
  });

  it("★ the notice path never writes invitations.token_hash", async () => {
    const db = makeDb();
    const original = db.invitations[0].token_hash;
    const { send } = scriptedSender([accepted]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    // 0043's minter overwrote this on every send. 0044's notice must not.
    expect(db.invitations[0].token_hash).toBe(original);
    expect(db.tokenHashReads).toEqual([original]);
  });

  it("★ calling 0043's minter would fail the suite — the fake refuses it", async () => {
    // Backward compatibility keeps issue_invitation_delivery_token in the database. This proves
    // the production orchestrator does not reach for it.
    const db = makeDb();
    const { send } = scriptedSender([accepted]);
    await expect(
      claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send })
    ).resolves.toBeDefined();
    expect(db.tokenHashReads).toHaveLength(1); // took a notice, not a token
  });

  it("nothing secret reaches a log line, on any outcome", async () => {
    for (const result of [accepted, transient, uncertain, permanent]) {
      const cap = captureConsole();
      try {
        const db = makeDb();
        const { send } = scriptedSender([result]);
        await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });
      } finally {
        cap.restore();
      }
      const logged = cap.lines.join("\n");
      expect(logged).not.toContain("recipient@example.test");
      expect(logged).not.toContain(ENTRY_URL);
    }
  });

  it("the returned counters carry no identifiers at all", async () => {
    const db = makeDb();
    const { send } = scriptedSender([accepted]);
    const counters = await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    const serialized = JSON.stringify(counters);
    expect(serialized).not.toContain("recipient@example.test");
    expect(serialized).not.toContain(OUTBOX_ID);
    expect(serialized).not.toContain("msg_1");
    expect(Object.keys(counters).sort()).toEqual([
      "cancelled", "claimed", "failedPermanent", "outcomeUncertain", "providerAccepted", "retryPending",
    ]);
  });
});
