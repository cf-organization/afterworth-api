/**
 * Phase 11-K · the owner-safety notice email.
 *
 * ★ THE CENTRAL TEST IS THE CATALOG COMPARISON. The in-app copy lives as a SQL constant in
 * `notification_event_copy`; this template carries a TypeScript twin. Two channels describing the
 * same event must not describe it differently, and the only way to know they still agree is to read
 * the SQL and compare. So this file parses the deployed source rather than restating the string —
 * a fixture that restated it would agree with whatever the template said and could never fail.
 */

import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  OWNER_NOTICE_BODY,
  OWNER_NOTICE_TITLE,
  ownerNoticeEntryUrl,
  renderOwnerNoticeEmail,
} from "../lib/ownerNotices/ownerNoticeTemplate.js";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CATALOG = resolve(ROOT, "db/functions/lifecycle_notification_rpcs.sql");
const LINK = "https://after-worth.com/invitations";

describe("the catalog is the source of the copy", () => {
  // ★ ASSERT THE SCAN SET BEFORE EVALUATING ANY RULE. A missing or renamed file would make every
  // match below fail against an empty string, and the failure would read like a copy mismatch.
  const sql = readFileSync(CATALOG, "utf8");

  it("reads a non-empty catalog containing the event (positive control)", () => {
    expect(sql.length).toBeGreaterThan(0);
    expect(sql).toContain("death_process.window_opened");
  });

  it("the email title is the catalog title, verbatim", () => {
    expect(sql).toContain(`'${OWNER_NOTICE_TITLE}'`);
  });

  it("the email body is the catalog body, verbatim", () => {
    expect(sql).toContain(`'${OWNER_NOTICE_BODY}'`);
  });

  it("both constants are pure ASCII, so neither channel can carry a character the other drops", () => {
    // eslint-disable-next-line no-control-regex
    expect(/^[\x20-\x7E]+$/.test(OWNER_NOTICE_TITLE)).toBe(true);
    // eslint-disable-next-line no-control-regex
    expect(/^[\x20-\x7E]+$/.test(OWNER_NOTICE_BODY)).toBe(true);
  });
});

describe("what the notice may never contain", () => {
  const rendered = renderOwnerNoticeEmail(LINK);
  const all = `${rendered.subject}\n${rendered.text}\n${rendered.html}`.toLowerCase();

  it("takes no parameter through which estate content could enter", () => {
    // The signature is the guarantee: one string, the link. There is no estate, claimant, case,
    // evidence, value or date parameter to pass, so none can be rendered.
    expect(renderOwnerNoticeEmail.length).toBe(1);
  });

  it("asserts no death and names no claimant", () => {
    for (const forbidden of [
      "died", "death", "deceased", "passed away", "executor", "trustee",
      "claimant", "beneficiary", "evidence", "certificate",
    ]) {
      expect(all).not.toContain(forbidden);
    }
  });

  it("prints no deadline arithmetic and no countdown", () => {
    for (const forbidden of ["7 day", "seven day", "days left", "expires", "deadline", "countdown", "remaining"]) {
      expect(all).not.toContain(forbidden);
    }
  });

  it("carries no internal state vocabulary", () => {
    for (const forbidden of [
      "challenge_window", "owner_notification_dispatched", "death_verified",
      "failedpermanent", "outcomeuncertain", "lifecycle", "outbox",
    ]) {
      expect(all).not.toContain(forbidden);
    }
  });

  it("carries no identifier and no deep link", () => {
    expect(all).not.toContain("afterworth://");
    // A UUID anywhere in the message would be an internal identifier reaching a recipient.
    expect(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i.test(all)).toBe(false);
  });

  it("gives every recipient the identical link, carrying no secret", () => {
    const a = renderOwnerNoticeEmail(LINK);
    const b = renderOwnerNoticeEmail(LINK);
    expect(a.html).toBe(b.html);
    expect(a.text).toBe(b.text);
    expect(a.text).toContain(LINK);
  });
});

describe("what the notice must contain", () => {
  const rendered = renderOwnerNoticeEmail(LINK);

  it("says a process is waiting and that the owner can halt it", () => {
    expect(rendered.subject).toBe(OWNER_NOTICE_TITLE);
    expect(rendered.text).toContain(OWNER_NOTICE_BODY);
    expect(rendered.text.toLowerCase()).toContain("halt");
  });

  it("tells the recipient they can reach the same notice without this message's link", () => {
    // The anti-phishing instruction. An unexpected email about releasing your estate is
    // indistinguishable from an attack; the only advice that survives someone spoofing this message
    // is "open the app yourself".
    expect(rendered.text.toLowerCase()).toContain("open the afterworth app directly");
  });

  it("has a plain-text twin of the HTML", () => {
    expect(rendered.text.length).toBeGreaterThan(0);
    expect(rendered.html).toContain("<html lang=\"en\">");
    expect(rendered.html).toContain(OWNER_NOTICE_TITLE);
  });

  it("escapes the link into the HTML", () => {
    const evil = renderOwnerNoticeEmail('https://x.test/"><script>alert(1)</script>');
    expect(evil.html).not.toContain("<script>");
    expect(evil.html).toContain("&lt;script&gt;");
  });
});

describe("the entry URL is configuration, never a guess", () => {
  const original = process.env.INVITATION_LINK_BASE_URL;
  const restore = () => {
    if (original === undefined) delete process.env.INVITATION_LINK_BASE_URL;
    else process.env.INVITATION_LINK_BASE_URL = original;
  };

  it("returns null when unset, so the drain refuses rather than sending a guessed origin", () => {
    delete process.env.INVITATION_LINK_BASE_URL;
    expect(ownerNoticeEntryUrl()).toBeNull();
    restore();
  });

  it("trims trailing slashes so the rendered link is stable", () => {
    process.env.INVITATION_LINK_BASE_URL = `${LINK}///`;
    expect(ownerNoticeEntryUrl()).toBe(LINK);
    restore();
  });
});
