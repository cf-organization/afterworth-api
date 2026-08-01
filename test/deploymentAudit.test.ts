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

  it("no pre-existing invitation handler was modified", () => {
    for (const file of ["accept.ts", "bind.ts", "decline.ts", "preview.ts", "resolve.ts"]) {
      const diff = execFileSync("git", ["diff", "origin/main...HEAD", "--", `lib/invitations/${file}`], {
        cwd: ROOT,
        encoding: "utf8",
      }).trim();
      expect(diff, file).toBe("");
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
});

describe("★ the rate-limit registry has a row for the new action", () => {
  it("invitations_create_owner is registered, and is fail-closed tier 1", () => {
    // An unregistered bucket denies every request, so a missing row is a silent outage.
    const src = fs.readFileSync(path.join(ROOT, "lib", "rateLimit.ts"), "utf8");
    expect(src).toMatch(/invitations_create_owner:\s*\{\s*tier:\s*1/);
  });
});
