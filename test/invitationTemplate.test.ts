/**
 * The recipient email. Almost every test here is about what the message may NOT say — an
 * invitation that over-promises is worse than none, because the recipient acts on it.
 */
import { describe, expect, it } from "vitest";
import { renderInvitationEmail } from "../lib/email/invitationTemplate.js";

const base = {
  estateDisplayName: "The Example Estate",
  inviterDisplayName: "Alex Example",
  expiresAt: new Date("2026-09-01T00:00:00Z"),
  link: "https://example.test/invite?token=abc123",
};

const ALL_SHAPES = [
  base,
  { ...base, estateDisplayName: null },
  { ...base, inviterDisplayName: null },
  { ...base, estateDisplayName: null, inviterDisplayName: null },
];

describe("both formats are produced", () => {
  it("returns a subject, HTML, and a plain-text twin", () => {
    const r = renderInvitationEmail(base);
    expect(r.subject.length).toBeGreaterThan(0);
    expect(r.html).toContain("<!doctype html>");
    expect(r.text).not.toContain("<");
    expect(r.text).toContain(base.link);
  });

  it("the link is reachable in both formats", () => {
    const r = renderInvitationEmail(base);
    expect(r.html).toContain(`href="${base.link}"`);
    expect(r.html).toContain("copy and paste"); // link also present as visible text
    expect(r.text).toContain(base.link);
  });
});

describe("accessibility basics", () => {
  it("declares a language, a title, and a viewport", () => {
    const html = renderInvitationEmail(base).html;
    expect(html).toContain('<html lang="en">');
    expect(html).toContain("<title>");
    expect(html).toContain('name="viewport"');
  });

  it("uses a real anchor with descriptive text, not a bare URL as the only affordance", () => {
    const html = renderInvitationEmail(base).html;
    expect(html).toMatch(/<a href="[^"]+"[^>]*>View your invitation<\/a>/);
  });

  it("uses semantic landmarks and a heading rather than layout tables", () => {
    const html = renderInvitationEmail(base).html;
    expect(html).toContain("<main");
    expect(html).toContain("<h1");
    expect(html).not.toContain("<table");
  });
});

describe("★ the message never claims something it cannot know", () => {
  it("never says delivered, received, opened, viewed, or accepted", () => {
    for (const input of ALL_SHAPES) {
      const r = renderInvitationEmail(input);
      const all = `${r.subject}\n${r.html}\n${r.text}`.toLowerCase();
      for (const forbidden of ["delivered", "was received", "you opened", "has been accepted", "you have accepted"]) {
        expect(all, forbidden).not.toContain(forbidden);
      }
    }
  });
});

describe("★ the message never discloses estate substance", () => {
  /**
   * Word-bounded, NOT substring. A bare "will" matches the ordinary auxiliary verb in "nothing will
   * happen", and a matcher that flags plain English is a matcher nobody keeps. The legal senses are
   * targeted specifically; the sanity fixture below proves both directions.
   */
  const SUBSTANCE_PATTERNS: Array<[string, RegExp]> = [
    ["monetary value", /\$\d|\d+\s?%|\bUSD\b/i],
    ["bank", /\bbanks?\b/i],
    ["account", /\baccounts?\b/i],
    ["balance", /\bbalances?\b/i],
    ["portfolio", /\bportfolios?\b/i],
    ["asset", /\bassets?\b/i],
    ["insurance", /\binsurance\b/i],
    ["trust fund", /\btrust fund\b/i],
    ["document", /\bdocuments?\b/i],
    ["vault", /\bvault\b/i],
    ["will (the legal instrument)", /\b(a|the|last)\s+will\b|\bwill and testament\b/i],
    ["deed", /\bdeeds?\b/i],
    ["policy number", /\bpolicy number\b/i],
  ];

  it("carries no money, institution, document, or holding language", () => {
    for (const input of ALL_SHAPES) {
      const r = renderInvitationEmail(input);
      const all = `${r.subject}\n${r.html}\n${r.text}`;
      for (const [label, pattern] of SUBSTANCE_PATTERNS) {
        expect(all, label).not.toMatch(pattern);
      }
    }
  });

  it("detection sanity — substance is caught, ordinary English is not", () => {
    const will = SUBSTANCE_PATTERNS.find(([l]) => l.startsWith("will"))![1];
    expect(will.test("a copy of the will is attached")).toBe(true);
    expect(will.test("last will and testament")).toBe(true);
    expect(will.test("if you were not expecting this, nothing will happen")).toBe(false);

    const asset = SUBSTANCE_PATTERNS.find(([l]) => l === "asset")![1];
    expect(asset.test("your assets are listed")).toBe(true);
    expect(asset.test("we assessed the request")).toBe(false);
  });

  it("carries no internal role or policy code", () => {
    for (const input of ALL_SHAPES) {
      const all = JSON.stringify(renderInvitationEmail(input));
      for (const code of [
        "beneficiary", "professional_delegate", "primary_user", "executor", "trustee",
        "full_detail", "limited_detail", "after_owner_approval", "P0001", "42501",
      ]) {
        expect(all, code).not.toContain(code);
      }
    }
  });

  it("★ asserts no fiduciary authority and no inheritance", () => {
    for (const input of ALL_SHAPES) {
      const all = `${renderInvitationEmail(input).html}`.toLowerCase();
      for (const claim of ["inherit", "you are entitled", "your share", "estate of the late", "next of kin", "fiduciary"]) {
        expect(all, claim).not.toContain(claim);
      }
    }
  });

  it("carries no UUID or internal identifier", () => {
    const all = JSON.stringify(renderInvitationEmail(base));
    expect(all).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
    expect(all).not.toContain("outbox");
    expect(all).not.toContain("afterworth/invitation/");
  });
});

describe("owner disclosure choices drive the copy", () => {
  it("names the estate and inviter when both are supplied", () => {
    const r = renderInvitationEmail(base);
    expect(r.subject).toContain("The Example Estate");
    expect(r.html).toContain("Alex Example");
  });

  it("stays vague, without a placeholder, when both are withheld", () => {
    const r = renderInvitationEmail({ ...base, estateDisplayName: null, inviterDisplayName: null });
    expect(r.subject).toBe("You have been invited to AfterWorth");
    expect(r.html).not.toContain("null");
    expect(r.html).not.toContain("undefined");
    expect(r.html).not.toMatch(/\bsomeone's estate\b/i);
  });

  it("treats a blank name as withheld rather than rendering an empty gap", () => {
    const r = renderInvitationEmail({ ...base, inviterDisplayName: "   " });
    expect(r.html).not.toContain("  has invited");
  });
});

describe("owner-supplied names are untrusted text", () => {
  it("escapes HTML in a display name", () => {
    const r = renderInvitationEmail({ ...base, estateDisplayName: '<script>alert("x")</script>' });
    expect(r.html).not.toContain("<script>");
    expect(r.html).toContain("&lt;script&gt;");
  });

  it("escapes the link too", () => {
    const r = renderInvitationEmail({ ...base, link: 'https://example.test/i?token=a"onmouseover="x' });
    expect(r.html).not.toContain('"onmouseover="');
  });
});

describe("expiry is stated plainly", () => {
  it("renders a human date, not a timestamp", () => {
    const r = renderInvitationEmail(base);
    expect(r.text).toContain("September 1, 2026");
    expect(r.text).not.toContain("2026-09-01T00:00:00");
  });
});
