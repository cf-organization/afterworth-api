/**
 * The provider adapter — outcome honesty and key custody.
 *
 * Every test injects a transport double. Nothing here reaches api.resend.com, and the key used is a
 * fixture string that exists only inside this file.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { send } from "../lib/email/resendProvider.js";
import { captureConsole, jsonResponse, makeTransport } from "./fakes.js";

const FIXTURE_KEY = "re_fixture_key_never_real_0000";

const email = {
  to: "recipient@example.test",
  subject: "You have been invited",
  html: "<p>hi</p>",
  text: "hi",
  idempotencyKey: "afterworth/invitation/22222222-2222-4222-8222-222222222222/1",
};

beforeEach(() => {
  process.env.RESEND_API_KEY = FIXTURE_KEY;
  process.env.INVITATION_FROM_ADDRESS = "AfterWorth <invitations@example.test>";
});
afterEach(() => {
  delete process.env.RESEND_API_KEY;
  delete process.env.INVITATION_FROM_ADDRESS;
});

describe("outcome mapping is honest", () => {
  it("a 200 with an id is providerAccepted — and is never called delivered", async () => {
    const { transport } = makeTransport([jsonResponse(200, { id: "msg_abc123" })]);
    const r = await send(email, transport);
    expect(r.outcome).toBe("providerAccepted");
    expect(r.providerMessageId).toBe("msg_abc123");
    expect(r.failureClass).toBeNull();
    // The type itself forbids it, but assert the vocabulary explicitly.
    expect(["delivered", "received", "opened", "viewed"]).not.toContain(r.outcome);
  });

  it("a 2xx with an unreadable body is still accepted, just without a handle", async () => {
    const { transport } = makeTransport([new Response("not json", { status: 200 })]);
    const r = await send(email, transport);
    expect(r.outcome).toBe("providerAccepted");
    expect(r.providerMessageId).toBeNull();
  });

  it("429 is retryPending/rate_limited — the provider ANSWERED, so nothing was accepted", async () => {
    const { transport } = makeTransport([jsonResponse(429, { message: "slow down" })]);
    const r = await send(email, transport);
    expect(r).toMatchObject({ outcome: "retryPending", failureClass: "rate_limited", providerMessageId: null });
  });

  it("5xx is retryPending/provider_unavailable", async () => {
    const { transport } = makeTransport([jsonResponse(503, {})]);
    expect((await send(email, transport)).outcome).toBe("retryPending");
  });

  it("401/403 is failedPermanent/configuration — a bad key will not fix itself", async () => {
    const { transport } = makeTransport([jsonResponse(401, {})]);
    const r = await send(email, transport);
    expect(r).toMatchObject({ outcome: "failedPermanent", failureClass: "configuration" });
  });

  it("422 is failedPermanent/invalid_recipient", async () => {
    const { transport } = makeTransport([jsonResponse(422, {})]);
    expect((await send(email, transport)).failureClass).toBe("invalid_recipient");
  });

  it("★ a network error is outcomeUncertain — NOT a failure, NOT a success", async () => {
    const { transport } = makeTransport([new TypeError("socket hang up")]);
    const r = await send(email, transport);
    expect(r.outcome).toBe("outcomeUncertain");
    expect(r.providerMessageId).toBeNull();
  });

  it("a missing key is failedPermanent/configuration and never throws", async () => {
    delete process.env.RESEND_API_KEY;
    const { transport, requests } = makeTransport([jsonResponse(200, { id: "x" })]);
    const r = await send(email, transport);
    expect(r).toMatchObject({ outcome: "failedPermanent", failureClass: "configuration" });
    expect(requests).toHaveLength(0); // never even attempted
  });
});

describe("★ the idempotency key is sent, and is derived from surrogate ids only", () => {
  it("goes out as the Idempotency-Key header verbatim", async () => {
    const { transport, requests } = makeTransport([jsonResponse(200, { id: "m" })]);
    await send(email, transport);
    expect(requests[0].headers["Idempotency-Key"]).toBe(email.idempotencyKey);
  });

  it("contains neither the recipient address nor anything token-shaped", async () => {
    expect(email.idempotencyKey).not.toContain("@");
    expect(email.idempotencyKey).toMatch(/^afterworth\/invitation\/[0-9a-f-]{36}\/\d+$/);
  });
});

describe("★ key custody", () => {
  it("the key never appears in the returned result", async () => {
    const { transport } = makeTransport([jsonResponse(200, { id: "m" })]);
    const r = await send(email, transport);
    expect(JSON.stringify(r)).not.toContain(FIXTURE_KEY);
  });

  it("the key never reaches a log — on success, refusal, or uncertainty", async () => {
    for (const response of [jsonResponse(200, { id: "m" }), jsonResponse(500, {}), new TypeError("boom")]) {
      const cap = captureConsole();
      try {
        const { transport } = makeTransport([response]);
        await send(email, transport);
      } finally {
        cap.restore();
      }
      expect(cap.lines.join("\n")).not.toContain(FIXTURE_KEY);
    }
  });

  it("a refusal log carries the status and class only — never the provider body", async () => {
    const cap = captureConsole();
    try {
      const { transport } = makeTransport([jsonResponse(422, { message: "invalid to: recipient@example.test" })]);
      await send(email, transport);
    } finally {
      cap.restore();
    }
    const logged = cap.lines.join("\n");
    expect(logged).toContain("422");
    // The provider echoed the recipient in its body; it must not reach the log through us.
    expect(logged).not.toContain("recipient@example.test");
  });
});
