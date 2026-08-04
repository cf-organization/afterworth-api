/**
 * Legacy-domain regression gate (backend).
 *
 * The product moved to `after-worth.com`. `minifam.com` and `afterworth.com` are decommissioned as
 * ACTIVE configuration. `afterworth.com` in particular is not owned by this product — it is parked
 * for sale on HugeDomains — so a stale reference sends recipients to a domain-sale listing.
 *
 * This walks shipped source and fails if either legacy domain reappears. It deliberately does NOT
 * scan:
 *
 *   docs/            — recon and decision records. Preserved, and marked historical in place.
 *   db/migrations/   — applied migration history is immutable. It is never edited to tidy a name.
 *   db/verification/ — verification harnesses pinned to the migrations they prove.
 *   test/            — fixtures may need a legacy value to prove it is REJECTED.
 *
 * ★ `afterworth/invitation/<id>/<gen>` (the Resend idempotency key prefix) and `afterworth://`
 * (the mobile custom scheme) are NOT domains and contain no `afterworth.com` substring. They are
 * untouched, and the assertion at the end pins that.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");

/** Shipped source and deployed static assets. See the header for what is excluded and why. */
const SCANNED_DIRS = ["api", "lib", "public"];
const SCANNED_ROOT_FILES = ["vercel.json", "package.json"];
const SCANNED_EXT = new Set([".ts", ".js", ".json", ".html", ""]);

const LEGACY = ["minifam.com", "afterworth.com"] as const;

function walk(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) return e.name === "node_modules" ? [] : walk(full);
    // Extensionless files are included so `public/.well-known/apple-app-site-association` is covered.
    return SCANNED_EXT.has(path.extname(e.name)) ? [full] : [];
  });
}

const FILES = [
  ...SCANNED_DIRS.flatMap((d) => walk(path.join(ROOT, d))),
  ...SCANNED_ROOT_FILES.map((f) => path.join(ROOT, f)).filter((f) => fs.existsSync(f)),
];

function offendingLines(file: string): string[] {
  return fs
    .readFileSync(file, "utf8")
    .split("\n")
    .map((line, i) => ({ line, n: i + 1 }))
    .filter(({ line }) => {
      const scrubbed = line.replace(/after-worth\.com/gi, "");
      return LEGACY.some((d) => scrubbed.toLowerCase().includes(d));
    })
    .map(({ line, n }) => `${path.relative(ROOT, file)}:${n}: ${line.trim()}`);
}

describe("★ no active legacy-domain reference survives in shipped backend source", () => {
  it("the scan actually covers files — a silently empty walk would pass vacuously", () => {
    expect(FILES.length).toBeGreaterThan(10);
    expect(FILES).toContain(path.join(ROOT, "public", ".well-known", "apple-app-site-association"));
    expect(FILES).toContain(path.join(ROOT, "public", ".well-known", "assetlinks.json"));
  });

  it("no minifam.com or afterworth.com reference in shipped source", () => {
    const hits = FILES.flatMap(offendingLines);
    // Joined into the expected value so a failure prints every offending file:line, not a count.
    expect(hits.join("\n")).toBe("");
  });

  it("the sender fallback is the canonical production address", () => {
    // An unset INVITATION_FROM_EMAIL must not fall back to an unverified domain: Resend rejects an
    // unverified From with 422, which classifyStatus maps to failedPermanent — the row is burned
    // rather than retried, so a wrong default is silently destructive.
    const provider = fs.readFileSync(path.join(ROOT, "lib", "email", "resendProvider.ts"), "utf8");
    expect(provider).toContain("invitations@mail.after-worth.com");
    expect(provider).toContain("INVITATION_FROM_EMAIL");
    expect(provider).not.toContain("INVITATION_FROM_ADDRESS");
  });

  it("the app identity and custom scheme are NOT treated as domains", () => {
    // Each contains the product name without a TLD, so the scan above leaves them alone — which is
    // correct. `com.afterworth.mobile` is registered with Apple and Google and cannot be renamed
    // without new store listings; `afterworth://` is the installed app's deep-link scheme. Pinned
    // here so a future "rename everything" sweep has to make the change deliberately.
    const aasa = fs.readFileSync(path.join(ROOT, "public", ".well-known", "apple-app-site-association"), "utf8");
    const links = fs.readFileSync(path.join(ROOT, "public", ".well-known", "assetlinks.json"), "utf8");
    const landing = fs.readFileSync(path.join(ROOT, "public", "invitations", "index.html"), "utf8");

    expect(JSON.parse(aasa).applinks.details[0].appIDs[0]).toContain(".com.afterworth.mobile");
    expect(JSON.parse(links)[0].target.package_name).toBe("com.afterworth.mobile");
    expect(landing).toContain("afterworth://invitations");
  });
});
