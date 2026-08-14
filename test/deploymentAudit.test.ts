/**
 * Source-text audits — the properties no runtime test can observe.
 *
 * These read the repository as text, because that is where "the key is only touched in one place"
 * and "the deployment did not grow a function" are actually visible.
 */
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");

function walk(dir: string, acc: string[] = []): string[] {
  if (!fs.existsSync(dir)) return acc;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, acc);
    else acc.push(full);
  }
  return acc;
}

const API_FUNCTIONS = walk(path.join(ROOT, "api")).filter((f) => f.endsWith(".ts"));
const SOURCE_FILES = [...walk(path.join(ROOT, "api")), ...walk(path.join(ROOT, "lib"))].filter((f) =>
  f.endsWith(".ts")
);

describe("★ the Vercel function budget is unchanged", () => {
  it("api/ still contains exactly 12 function files", () => {
    // The deployment is at the Hobby ceiling; api/claims/[action].ts calls itself the last slot.
    // Both new actions ride an existing dispatcher, so this number must not move.
    expect(API_FUNCTIONS).toHaveLength(12);
  });

  it("no new file was added under api/ by this change", () => {
    const changed = execFileSync("git", ["diff", "--name-only", "--diff-filter=A", "origin/main...HEAD", "--", "api/"], {
      cwd: ROOT,
      encoding: "utf8",
    }).trim();
    expect(changed).toBe("");
  });

  it("the invitation dispatcher serves both new actions without a new file", () => {
    const src = fs.readFileSync(path.join(ROOT, "api", "invitations", "[action].ts"), "utf8");
    expect(src).toContain("create_owner");
    expect(src).toContain("drain_email_outbox");
    expect(fs.existsSync(path.join(ROOT, "api", "invitations", "resolve.ts"))).toBe(false);
  });
});

describe("★ existing invitation behaviour is untouched", () => {
  it("the five original actions are still routed", () => {
    const src = fs.readFileSync(path.join(ROOT, "api", "invitations", "[action].ts"), "utf8");
    for (const action of ["accept", "bind", "decline", "preview", "resolve"]) {
      expect(src, action).toContain(action);
    }
  });

  it("lib/invitations/resolve.ts is byte-identical to main", () => {
    const diff = execFileSync("git", ["diff", "origin/main...HEAD", "--", "lib/invitations/resolve.ts"], {
      cwd: ROOT,
      encoding: "utf8",
    }).trim();
    expect(diff).toBe("");
  });

  /**
   * ★ THIS LIST LOST `accept.ts` AND `bind.ts` IN PHASE 11-MC, DELIBERATELY AND WITH A REPLACEMENT.
   *
   * The blanket "byte-identical to main" guard was written when adding invitation ACTIONS, to prove the
   * existing handlers were not disturbed. 11-MC genuinely must disturb two of them: a fiduciary
   * acceptance no longer provisions a membership, so the RPC returns three nulls, and the old validator
   * required all five columns to be strings and answered 502 `upstream_unexpected_shape`. Left unchanged,
   * every executor acceptance would look like a server fault to the invitee while the designation had in
   * fact committed.
   *
   * ★ A BLANKET "DO NOT TOUCH" IS NOT A BEHAVIOURAL INVARIANT, so it is replaced by one rather than
   * dropped. The property that actually matters about these two files is asserted below, and
   * `test/provisioningFirewall.test.ts` pins it in more detail. `decline.ts`, `preview.ts` and
   * `resolve.ts` have no reason to move and keep the strict guard.
   *
   * ★ AND A CAVEAT WORTH KNOWING: this audit diffs `origin/main...HEAD`, so it sees only COMMITTED work.
   * It passed vacuously through the whole of 11-MC's implementation and only fired after the commit —
   * which is exactly when it was needed, but do not read a green local run as evidence that these files
   * are untouched.
   */
  it("no UNRELATED invitation handler was modified", () => {
    for (const file of ["decline.ts", "preview.ts", "resolve.ts"]) {
      const diff = execFileSync("git", ["diff", "origin/main...HEAD", "--", `lib/invitations/${file}`], {
        cwd: ROOT,
        encoding: "utf8",
      }).trim();
      expect(diff, file).toBe("");
    }
  });

  it("accept and bind still validate the estate fields strictly", () => {
    // What 11-MC relaxed is the MEMBERSHIP triple, and only that. Estate identity is present on every
    // acceptance, so a genuinely broken response must still fail closed.
    for (const file of ["accept.ts", "bind.ts"]) {
      const src = fs.readFileSync(path.join(ROOT, "lib", "invitations", file), "utf8");
      expect(src, file).toContain('typeof row.estate_id !== "string"');
      expect(src, file).toContain('typeof row.estate_display_name !== "string"');
      expect(src, file).toContain("upstream_unexpected_shape");
    }
  });

  it("accept and bind reject a PARTIAL membership rather than reporting a roleless claim", () => {
    // All three present, or all three null. A mixture would let a future regression report a role with
    // no membership behind it — a disclosure claim with nothing supporting it.
    for (const file of ["accept.ts", "bind.ts"]) {
      const src = fs.readFileSync(path.join(ROOT, "lib", "invitations", file), "utf8");
      expect(src, file).toContain("membershipPresent");
      expect(src, file).toContain("membershipAbsent");
      expect(src, file).toMatch(/if \(!membershipPresent && !membershipAbsent\)/);
    }
  });
});

describe("★ RESEND_API_KEY custody", () => {
  const PROVIDER = path.join(ROOT, "lib", "email", "resendProvider.ts");

  it("exactly one module names it", () => {
    const touching = SOURCE_FILES.filter((f) => fs.readFileSync(f, "utf8").includes("RESEND_API_KEY"));
    expect(touching.map((f) => path.relative(ROOT, f))).toEqual(["lib/email/resendProvider.ts"]);
  });

  it("it is never given a client-inlined prefix", () => {
    for (const f of SOURCE_FILES) {
      const src = fs.readFileSync(f, "utf8");
      expect(src, f).not.toContain("EXPO_PUBLIC_RESEND");
      expect(src, f).not.toContain("NEXT_PUBLIC_RESEND");
      expect(src, f).not.toContain("VITE_RESEND");
    }
  });

  it("it is never exported, returned, or interpolated into a log", () => {
    const src = fs.readFileSync(PROVIDER, "utf8");
    expect(src).not.toMatch(/export\s+(const|function|let)\s+\w*[aA]piKey/);
    // The only permitted use is the Authorization header.
    const uses = [...src.matchAll(/apiKey/g)].length;
    expect(uses).toBeGreaterThan(0);
    expect(src).toContain("Authorization: `Bearer ${apiKey}`");
    expect(src).not.toMatch(/console\.(log|error|warn)\([^)]*apiKey/);
  });

  it("no committed file contains anything shaped like a live Resend key", () => {
    for (const f of walk(ROOT).filter((f) => !f.includes("/test/"))) {
      if (/\.(png|jpg|ico|lock)$/.test(f)) continue;
      const src = fs.readFileSync(f, "utf8");
      // Resend live keys are `re_` + a long token. The fixtures in test/ are excluded above.
      expect(src.match(/\bre_[A-Za-z0-9]{20,}\b/), f).toBeNull();
    }
  });
});

describe("★ the raw invitation token never reaches a client surface", () => {
  it("no handler returns a raw_token field", () => {
    for (const f of SOURCE_FILES) {
      const src = fs.readFileSync(f, "utf8");
      // The orchestrator reads issued.raw_token; nothing may put it on a Response.
      expect(src, f).not.toMatch(/jsonResponse\([^)]*raw_?[Tt]oken/);
      expect(src, f).not.toMatch(/JSON\.stringify\(\s*\{[^}]*raw_?[Tt]oken/);
    }
  });

  it("the create_owner response shape carries a fingerprint, never a token", () => {
    const src = fs.readFileSync(path.join(ROOT, "lib", "invitations", "createOwner.ts"), "utf8");
    expect(src).toContain("tokenFingerprint");
    expect(src).not.toContain("rawToken");
  });

  it("the drain response is counters only", () => {
    const src = fs.readFileSync(path.join(ROOT, "lib", "invitations", "drainEmailOutbox.ts"), "utf8");
    expect(src).toContain("counters");
    expect(src).not.toMatch(/invitationId|outboxId|invitee_email|provider_message_id/);
  });
});

describe("★ the cron is CRON_SECRET-gated and fails closed", () => {
  it("requires a configured secret and an exact bearer match", () => {
    const src = fs.readFileSync(path.join(ROOT, "lib", "invitations", "drainEmailOutbox.ts"), "utf8");
    expect(src).toContain("process.env.CRON_SECRET");
    expect(src).toContain("!cronSecret || auth !== `Bearer ${cronSecret}`");
  });

  it("is registered as a Vercel cron", () => {
    const vercel = JSON.parse(fs.readFileSync(path.join(ROOT, "vercel.json"), "utf8"));
    const paths = (vercel.crons ?? []).map((c: { path: string }) => c.path);
    expect(paths).toContain("/api/invitations/drain_email_outbox");
    // Hobby permits two cron jobs; going over would silently drop one.
    expect(paths.length).toBeLessThanOrEqual(2);
  });

  /**
   * ★ PHASE 11-K. The owner-safety notice drain has NO CRON OF ITS OWN — the two-job cap is spent,
   * and a third entry would have been silently dropped (this audit caught exactly that when the
   * drain was first written with its own entry). It therefore shares the claims-domain slot, and
   * that arrangement needs pinning from BOTH ends: the cron path must be the one that runs it, and
   * the route must actually run it. Either half alone passes while the owner goes un-notified.
   */
  it("the owner-notice drain is reachable from a registered cron path", () => {
    const vercel = JSON.parse(fs.readFileSync(path.join(ROOT, "vercel.json"), "utf8"));
    const paths: string[] = (vercel.crons ?? []).map((c: { path: string }) => c.path);
    expect(paths).toContain("/api/claims/drain_outboxes");

    const route = fs.readFileSync(path.join(ROOT, "api", "claims", "[action].ts"), "utf8");
    // The path resolves to the combined action…
    expect(route).toContain('const withOwnerNotices = action === "drain_outboxes"');
    // …and the combined action actually calls the drain.
    expect(route).toContain("claimAndDeliverOwnerNotices");
    expect(route).toMatch(/withOwnerNotices\s*\n?\s*\?\s*jsonResponse\(200, \{ purge, ownerNotices:/);
  });

  it("the owner-notice drain is CRON_SECRET-gated and fails closed", () => {
    const route = fs.readFileSync(path.join(ROOT, "api", "claims", "[action].ts"), "utf8");
    expect(route).toContain("process.env.CRON_SECRET");
    expect(route).toContain("!cronSecret || auth !== `Bearer ${cronSecret}`");
  });

  it("the owner-notice drain response is counters only", () => {
    const src = fs.readFileSync(path.join(ROOT, "lib", "ownerNotices", "drain.ts"), "utf8");
    expect(src.length).toBeGreaterThan(0); // positive control: the file was actually read
    expect(src).toContain("OwnerNoticeCounters");
    // The recipient reaches the provider and nothing else. No id, address or provider handle may
    // appear in a response or a log line.
    expect(src).not.toMatch(/console\.(error|log)\([^)]*recipient/);
    expect(src).not.toMatch(/console\.(error|log)\([^)]*estateId/);
    expect(src).not.toContain("providerMessageId");
  });
});

describe("★ the rate-limit registry has a row for the new action", () => {
  it("invitations_create_owner is registered, and is fail-closed tier 1", () => {
    // An unregistered bucket denies every request, so a missing row is a silent outage.
    const src = fs.readFileSync(path.join(ROOT, "lib", "rateLimit.ts"), "utf8");
    expect(src).toMatch(/invitations_create_owner:\s*\{\s*tier:\s*1/);
  });
});
