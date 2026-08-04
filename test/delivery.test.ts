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

beforeEach(() => {
  process.env.INVITATION_LINK_BASE_URL = "https://example.test/invite";
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
    expect(db.mintedTokens).toHaveLength(1);                       // ← no second token
    expect(db.outbox[0].delivery_generation).toBe(1);
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

  it("fails closed when no link base URL is configured — and mints no token", async () => {
    delete process.env.INVITATION_LINK_BASE_URL;
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    expect(calls).toHaveLength(0);
    expect(db.mintedTokens).toHaveLength(0); // ← the point: no token burned on a dead link
    expect(db.outbox[0].status).toBe("failedPermanent");
  });
});

describe("★ same generation vs deliberate reissue", () => {
  it("an ambiguous outcome does NOT mint a second token on its own", async () => {
    const db = makeDb();
    const { send } = scriptedSender([uncertain]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    expect(db.mintedTokens).toHaveLength(1);
    expect(db.outbox[0].delivery_generation).toBe(1);
    // outcomeUncertain is not claimable, so no drain will pick it up and quietly reissue.
    const second = await claimAndDeliver(makeFakeAdmin(db), { max: 10 }, { send });
    expect(second.claimed).toBe(0);
    expect(db.mintedTokens).toHaveLength(1);
  });

  it("a cron retry after a DEFINITIVE refusal mints a fresh token — no live link is rotated", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([transient, accepted]);
    const admin = makeFakeAdmin(db);

    await claimAndDeliver(admin, { outboxId: OUTBOX_ID }, { send });
    expect(db.outbox[0].status).toBe("retryPending");

    db.outbox[0].next_attempt_at = new Date(Date.now() - 1000).toISOString();
    await claimAndDeliver(admin, { max: 10 }, { send });

    expect(calls).toHaveLength(2);
    // retryPending means the provider ANSWERED and refused, so no link ever reached anyone — there
    // is nothing live to invalidate, and a fresh token is the only way to send at all (the previous
    // raw token died with the previous invocation). A key must never collide across generations.
    expect(new Set(calls.map((c) => c.idempotencyKey)).size).toBe(2);
    expect(calls.every((c) => c.idempotencyKey.startsWith(`afterworth/invitation/${OUTBOX_ID}/`))).toBe(true);
    expect(db.outbox[0].delivery_generation).toBe(2);
  });

  it("★ an ambiguous row is never claimed by a later drain, so no live link is ever rotated", async () => {
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
    expect(db.mintedTokens).toHaveLength(1);
    expect(db.outbox[0].delivery_generation).toBe(1);
  });

  it("a deliberate reissue advances the generation AND the key", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    const admin = makeFakeAdmin(db);

    await claimAndDeliver(admin, { outboxId: OUTBOX_ID }, { send });
    const firstKey = calls[0].idempotencyKey;
    const firstToken = db.mintedTokens[0];

    // An owner-initiated redelivery enqueues a NEW outbox row (0042's request_invitation_redelivery).
    db.outbox.push({ ...db.outbox[0], id: "44444444-4444-4444-8444-444444444444", status: "queued",
      attempts: 0, delivery_generation: 0, idempotency_key: null, provider_message_id: null,
      failure_class: null, next_attempt_at: null, issued_at: null,
      requested_at: new Date(Date.now() + 1000).toISOString() });

    await claimAndDeliver(admin, { max: 10 }, { send });

    expect(calls).toHaveLength(2);
    expect(calls[1].idempotencyKey).not.toBe(firstKey);
    expect(db.mintedTokens).toHaveLength(2);
    expect(db.mintedTokens[1]).not.toBe(firstToken);
    // The old link is dead: only the newest hash is stored.
    expect(db.invitations[0].token_hash).toBe(`hash-of-${db.mintedTokens[1]}`);
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
    expect(db.mintedTokens).toHaveLength(1);
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
      expect(db.mintedTokens).toHaveLength(0);
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

describe("★ the raw token's blast radius", () => {
  it("never appears on the outbox row", async () => {
    const db = makeDb();
    const { send } = scriptedSender([accepted]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    const serialized = JSON.stringify(db.outbox);
    for (const token of db.mintedTokens) expect(serialized).not.toContain(token);
    expect(db.mintedTokens).toHaveLength(1);
  });

  it("never appears in provider metadata — only in the link inside the body", async () => {
    const db = makeDb();
    const { send, calls } = scriptedSender([accepted]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    const token = db.mintedTokens[0];
    expect(calls[0].idempotencyKey).not.toContain(token);
    expect(calls[0].to).not.toContain(token);
    // It IS in the body — that is the verified recipient contract, and the only place it may be.
    expect(calls[0].html).toContain(encodeURIComponent(token));
    expect(calls[0].text).toContain(encodeURIComponent(token));
  });

  it("never appears in a log line, on any outcome", async () => {
    for (const result of [accepted, transient, uncertain, permanent]) {
      const db = makeDb();
      const cap = captureConsole();
      try {
        const { send } = scriptedSender([result]);
        await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });
      } finally {
        cap.restore();
      }
      const logged = cap.lines.join("\n");
      for (const token of db.mintedTokens) expect(logged).not.toContain(token);
    }
  });

  it("never appears in the returned counters, which carry no identifiers at all", async () => {
    const db = makeDb();
    const { send } = scriptedSender([accepted]);
    const counters = await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });

    const serialized = JSON.stringify(counters);
    for (const token of db.mintedTokens) expect(serialized).not.toContain(token);
    expect(serialized).not.toContain("recipient@example.test");
    expect(serialized).not.toContain(OUTBOX_ID);
    expect(serialized).not.toContain("msg_1");
    expect(Object.keys(counters).sort()).toEqual([
      "cancelled", "claimed", "failedPermanent", "outcomeUncertain", "providerAccepted", "retryPending",
    ]);
  });
});

describe("owner disclosure choices are honoured", () => {
  it("omits estate and inviter names when the owner hid them", async () => {
    const db = makeDb();
    db.invitations[0].preview_visibility = { showEstateName: false, showInviterName: false };
    // issue_invitation_delivery_token only accepts an already-claimed row, so put it in the state a
    // claim would have left it in before calling the row-level path directly.
    db.outbox[0].status = "processing";
    const { send, calls } = scriptedSender([accepted]);

    await deliverClaimedRow(
      makeFakeAdmin(db),
      { outboxId: OUTBOX_ID, invitationId: db.invitations[0].id, deliveryGeneration: 0, attempts: 1 },
      { send }
    );

    expect(calls).toHaveLength(1);
    expect(calls[0].html).not.toContain("The Example Estate");
    expect(calls[0].html).not.toContain("Alex Example");
    expect(calls[0].text).not.toContain("The Example Estate");
  });

  it("includes them when the owner allowed them", async () => {
    const db = makeDb();
    db.outbox[0].status = "processing";
    const { send, calls } = scriptedSender([accepted]);

    await deliverClaimedRow(
      makeFakeAdmin(db),
      { outboxId: OUTBOX_ID, invitationId: db.invitations[0].id, deliveryGeneration: 0, attempts: 1 },
      { send }
    );

    expect(calls[0].html).toContain("The Example Estate");
    expect(calls[0].html).toContain("Alex Example");
  });
});
