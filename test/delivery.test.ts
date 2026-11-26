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
const ENTRY_URL = "https://app.example.test/invitations";

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
      // Nothing may follow the exact entry path — no segment, no slash, no fragment.
      expect(body).not.toMatch(/\/invitations[/#?]\S/);
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

/**
 * ★ 0069 — THE INVITER NAME IS RELEASED ONLY AS THE OWNER CHOSE, AND ONLY WHEN IT IS A NAME.
 *
 * The notice RPC hands the orchestrator the stored column RAW (recorded in scripts/verifyInviterNamePrivacy.mjs
 * §5), so the rendered HTML and plain text asserted here are the recipient-facing truth for the email. The
 * sender's address is DIFFERENT from the recipient's in every case, so "the sender address is absent" and
 * "delivery still targets the recipient" are two separable facts, both asserted on both formats.
 */
describe("★ the inviter name reaches the recipient only as the owner chose, and only when it is a name", () => {
  const SENDER = "owner-sender@example.test";
  const RECIPIENT = "recipient@example.test";
  const ESTATE = "The Example Estate";
  const NEUTRAL = `You have been invited to ${ESTATE} on AfterWorth.`;

  /** Render one invitation whose stored inviter name and visibility are as given; returns the one send. */
  async function rendered(inviter_display_name: string | null, showInviterName: boolean) {
    const db = makeDb();
    db.invitations[0].invitee_email = RECIPIENT;
    db.invitations[0].inviter_display_name = inviter_display_name;
    db.invitations[0].preview_visibility = { showEstateName: true, showInviterName };
    const { send, calls } = scriptedSender([accepted]);
    const counters = await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });
    expect(counters.providerAccepted).toBe(1); // the send happened — a missing name never blocks delivery
    expect(calls).toHaveLength(1);
    return calls[0];
  }
  const bothFormats = (c: { html: string; text: string }) => [c.html, c.text];

  it("precondition — the fixture's sender and recipient addresses differ, and neither is a substring of the other", () => {
    expect(SENDER).not.toBe(RECIPIENT);
    expect(RECIPIENT.includes(SENDER)).toBe(false);
    expect(SENDER.includes(RECIPIENT)).toBe(false);
  });

  it("★ positive control — a SHOWN valid name opens the message, in HTML and in text, and the recipient is the target", async () => {
    const c = await rendered("Dana Hartley", true);
    expect(c.to).toBe(RECIPIENT);
    for (const body of bothFormats(c)) {
      expect(body).toContain(`Dana Hartley has invited you to ${ESTATE} on AfterWorth.`);
      expect(body).not.toContain(NEUTRAL);
      expect(body).not.toContain(SENDER);
    }
  });

  it("a HIDDEN valid name → neutral wording; the name and the sender address appear nowhere", async () => {
    const c = await rendered("Dana Hartley", false);
    expect(c.to).toBe(RECIPIENT);
    for (const body of bothFormats(c)) {
      expect(body).toContain(NEUTRAL);
      expect(body).not.toContain("Dana Hartley");
      expect(body).not.toContain(SENDER);
      expect(body).not.toMatch(/\S@\S/.source === "\\S@\\S" ? /[^\s>"]+@[^\s<"]+/ : /@/); // no address of any kind in the copy
    }
  });

  it("a BLANK profile name with an email on file: the post-0069 row stores NULL → neutral wording, sent to the recipient", async () => {
    // What create_estate_invitation / create_invitation now persist for an owner whose full_name is '' or NULL
    // (proven in the container script §1); the owner had chosen to show a name, so showInviterName is true.
    const c = await rendered(null, true);
    expect(c.to).toBe(RECIPIENT);
    for (const body of bothFormats(c)) {
      expect(body).toContain(NEUTRAL);
      expect(body).not.toContain(SENDER);
      expect(body).not.toContain("null");
      expect(body).not.toContain("  has invited");
    }
  });

  it("★ a LEGACY row that already stores the sender's ADDRESS as the name, with showInviterName=true → neutral wording; the address is absent from HTML and text", async () => {
    // Exactly the pre-0069 shape: coalesce(nullif(full_name,''), email) wrote the owner's address into the
    // name column, and the owner's choice to show a name gated it straight into the email.
    const c = await rendered(SENDER, true);
    expect(c.to).toBe(RECIPIENT);
    for (const body of bothFormats(c)) {
      expect(body).toContain(NEUTRAL);
      expect(body).not.toContain(SENDER);
      expect(body).not.toContain("has invited you");
    }
  });

  it("★ the gate and the sanitizer both apply on a QUEUED RETRY — the drain renders the same neutral message for a legacy row", async () => {
    const db = makeDb();
    db.invitations[0].invitee_email = RECIPIENT;
    db.invitations[0].inviter_display_name = SENDER;
    db.invitations[0].preview_visibility = { showEstateName: true, showInviterName: true };
    const { send, calls } = scriptedSender([transient, accepted]);
    const admin = makeFakeAdmin(db);
    await claimAndDeliver(admin, { outboxId: OUTBOX_ID }, { send }); // immediate attempt: provider refused
    expect(db.outbox[0].status).toBe("retryPending");
    db.outbox[0].next_attempt_at = new Date(Date.now() - 1000).toISOString();
    await claimAndDeliver(admin, { max: 25 }, { send }); // the cron drain's retry
    expect(calls).toHaveLength(2);
    for (const c of calls) {
      expect(c.to).toBe(RECIPIENT);
      for (const body of bothFormats(c)) {
        expect(body).toContain(NEUTRAL);
        expect(body).not.toContain(SENDER);
      }
    }
    expect(calls[1].html).toBe(calls[0].html); // the retry is the same message, not a differently-gated one
  });

  it("an address-shaped PROFILE NAME (someone typed their email as their name) → neutral, even when shown", async () => {
    const c = await rendered("addr-as-name@example.test", true);
    for (const body of bothFormats(c)) {
      expect(body).toContain(NEUTRAL);
      expect(body).not.toContain("addr-as-name@example.test");
    }
  });

  it("the estate-name choice is separate: hidden estate + shown name still names the inviter and not the estate", async () => {
    const db = makeDb();
    db.invitations[0].invitee_email = RECIPIENT;
    db.invitations[0].inviter_display_name = "Dana Hartley";
    db.invitations[0].preview_visibility = { showEstateName: false, showInviterName: true };
    const { send, calls } = scriptedSender([accepted]);
    await claimAndDeliver(makeFakeAdmin(db), { outboxId: OUTBOX_ID }, { send });
    for (const body of bothFormats(calls[0])) {
      expect(body).toContain("Dana Hartley has invited you to AfterWorth.");
      expect(body).not.toContain(ESTATE);
    }
  });
});
