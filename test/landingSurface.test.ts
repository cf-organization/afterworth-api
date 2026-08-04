/**
 * The static invitation entry surface.
 *
 * Everything here is asserted against the files as they will actually be served. The page has no
 * script tag, so most of its security properties are true by construction rather than by
 * discipline — these tests are what stop that changing quietly.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");
const PAGE = fs.readFileSync(path.join(ROOT, "public", "invitations", "index.html"), "utf8");

/**
 * Comments must go before matching. The page's own header block ENUMERATES what it may not do
 * ("no localStorage", "never claim delivered", "P0006"), so a naive matcher flags the prohibition
 * as the violation it forbids. A commented-out script tag is also inert, so stripping is correct
 * for inertness too — not just a convenience.
 */
function stripHtmlComments(html: string): string {
  return html.replace(/<!--[\s\S]*?-->/g, " ");
}

/** What a browser actually renders and executes. */
const RENDERED = stripHtmlComments(PAGE);
const VERCEL = JSON.parse(fs.readFileSync(path.join(ROOT, "vercel.json"), "utf8"));

function headersFor(source: string): Record<string, string> {
  const entry = (VERCEL.headers ?? []).find((h: { source: string }) => h.source === source);
  const out: Record<string, string> = {};
  for (const h of entry?.headers ?? []) out[h.key] = h.value;
  return out;
}

describe("★ the page discloses nothing", () => {
  it("names no estate, inviter, or recipient", () => {
    // It is a single static file with no input, so it has nothing to interpolate — but assert it,
    // because a future edit could add a templating step.
    expect(RENDERED).not.toMatch(/\{\{|\$\{|<%/);
    expect(RENDERED).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
    expect(RENDERED).not.toMatch(/@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/); // no email address anywhere
  });

  it("never states that an invitation exists, is valid, expired, or revoked", () => {
    const text = RENDERED.toLowerCase();
    for (const forbidden of ["expired", "revoked", "no longer valid", "invalid invitation", "already used"]) {
      expect(text, forbidden).not.toContain(forbidden);
    }
  });

  it("never claims delivery, acceptance, or membership", () => {
    const text = RENDERED.toLowerCase();
    for (const forbidden of ["delivered", "you are now", "you have joined", "membership", "has been accepted"]) {
      expect(text, forbidden).not.toContain(forbidden);
    }
    // It must say the opposite, plainly.
    expect(text).toContain("nothing has been shared with you yet");
  });

  it("carries no internal role or policy code", () => {
    for (const code of ["beneficiary", "professional_delegate", "primary_user", "executor", "trustee", "P0006"]) {
      expect(RENDERED, code).not.toContain(code);
    }
  });
});

describe("★ the page is inert", () => {
  it("has no script tag at all", () => {
    expect(RENDERED).not.toMatch(/<script/i);
  });

  it("loads nothing from a third party", () => {
    // Every src/href must be same-origin or the app scheme. No CDN, no font host, no pixel.
    const urls = [...RENDERED.matchAll(/(?:src|href)\s*=\s*"([^"]+)"/gi)].map((m) => m[1]);
    for (const u of urls) {
      expect(u.startsWith("afterworth://") || u.startsWith("/") || u.startsWith("#"), `external: ${u}`).toBe(true);
    }
  });

  it("uses no storage API and no analytics", () => {
    for (const api of ["localStorage", "sessionStorage", "document.cookie", "navigator.sendBeacon", "gtag", "analytics"]) {
      expect(RENDERED, api).not.toContain(api);
    }
  });

  it("detection sanity — real code is caught, the page's own prohibition comment is not", () => {
    expect(/<script/i.test(stripHtmlComments('<script>x()</script>'))).toBe(true);
    expect(stripHtmlComments("<!-- no localStorage here -->")).not.toContain("localStorage");
    expect(stripHtmlComments("<p>localStorage.setItem()</p>")).toContain("localStorage");
    // And the stripper must not eat real markup that merely looks comment-ish.
    expect(stripHtmlComments("<p>a -- b</p>")).toContain("a -- b");
  });

  it("asks not to be indexed and not to leak a referrer", () => {
    expect(PAGE).toContain('name="referrer" content="no-referrer"');
    expect(PAGE).toContain('name="robots" content="noindex, nofollow"');
  });
});

describe("★ served headers", () => {
  it("sets a restrictive CSP that forbids scripts outright", () => {
    const csp = headersFor("/invitations")["Content-Security-Policy"] ?? "";
    expect(csp).toContain("default-src 'none'");
    expect(csp).not.toMatch(/script-src[^;]*'unsafe-inline'/);
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).toContain("form-action 'none'");
  });

  it("sets Referrer-Policy: no-referrer at the edge as well as in the document", () => {
    expect(headersFor("/invitations")["Referrer-Policy"]).toBe("no-referrer");
  });

  it("sets nosniff and denies framing", () => {
    const h = headersFor("/invitations");
    expect(h["X-Content-Type-Options"]).toBe("nosniff");
    expect(h["X-Frame-Options"]).toBe("DENY");
  });

  it("serves both association files as application/json", () => {
    for (const src of ["/.well-known/apple-app-site-association", "/.well-known/assetlinks.json"]) {
      expect(headersFor(src)["Content-Type"], src).toBe("application/json");
    }
  });
});

describe("★ accessibility of the open-app action", () => {
  it("is a real anchor with descriptive text, not an icon or a bare URL", () => {
    expect(PAGE).toMatch(/<a class="cta" href="[^"]+">Open AfterWorth<\/a>/);
  });

  it("declares a language and a viewport, and has one h1", () => {
    expect(PAGE).toContain('<html lang="en">');
    expect(PAGE).toContain('name="viewport"');
    expect([...PAGE.matchAll(/<h1[\s>]/g)]).toHaveLength(1);
  });

  it("keeps a visible focus ring on the action", () => {
    expect(PAGE).toContain(".cta:focus-visible");
  });

  it("supports both colour schemes rather than assuming light", () => {
    expect(PAGE).toContain("color-scheme: light dark");
    expect(PAGE).toContain("prefers-color-scheme: dark");
  });
});

describe("association files", () => {
  const AASA = JSON.parse(
    fs.readFileSync(path.join(ROOT, "public", ".well-known", "apple-app-site-association"), "utf8")
  );
  const LINKS = JSON.parse(fs.readFileSync(path.join(ROOT, "public", ".well-known", "assetlinks.json"), "utf8"));

  it("apple-app-site-association has no file extension — Apple requires exactly this name", () => {
    expect(fs.existsSync(path.join(ROOT, "public", ".well-known", "apple-app-site-association"))).toBe(true);
    expect(fs.existsSync(path.join(ROOT, "public", ".well-known", "apple-app-site-association.json"))).toBe(false);
  });

  it("scopes iOS matching to the entry path only, never the whole origin", () => {
    const components = AASA.applinks.details[0].components.map((c: Record<string, string>) => c["/"]);
    // Exact path only — deliberately NOT the trailing-slash form, so AASA matches exactly what
    // the mobile parser accepts. A URL the OS opens but the app rejects is worse than a web fallback.
    expect(components).toEqual(["/invitations"]);
    expect(components).not.toContain("*");
  });

  it("names the real bundle id and package", () => {
    expect(AASA.applinks.details[0].appIDs[0]).toContain("com.afterworth.mobile");
    expect(LINKS[0].target.package_name).toBe("com.afterworth.mobile");
  });

  /**
   * ★ INVERTED 2026-08-03, when the real values landed. This assertion used to require the
   * placeholders to be PRESENT — it was the reminder that link verification could not work yet.
   * It now requires the opposite, because the failure mode has moved: a placeholder reaching
   * production is silent. Apple and Google fetch these files themselves, and a malformed appID or
   * fingerprint yields no error anywhere in the app — universal links simply never open, which is
   * indistinguishable from a user who has not installed the app.
   *
   * Shape, not literal equality: pinning the exact Team ID here would only assert the file equals
   * itself. The shapes below are what Apple and Google actually reject.
   */
  it("★ carries no deployment placeholder — a placeholder in production fails silently", () => {
    const appId = AASA.applinks.details[0].appIDs[0];
    const fingerprint = LINKS[0].target.sha256_cert_fingerprints[0];

    expect(appId).not.toMatch(/REPLACE_WITH/i);
    expect(fingerprint).not.toMatch(/REPLACE_WITH/i);

    // `<TEAMID>.<bundle id>` — Apple Team IDs are exactly 10 uppercase alphanumerics.
    expect(appId).toMatch(/^[A-Z0-9]{10}\.com\.afterworth\.mobile$/);
    // 32 colon-separated uppercase hex pairs, as `keytool`/Play Console print them.
    expect(fingerprint).toMatch(/^([0-9A-F]{2}:){31}[0-9A-F]{2}$/);
  });
});

describe("★ the deployment cost is still zero functions", () => {
  it("the landing surface is static, not a serverless function", () => {
    // Vercel counts files under api/. public/ is served statically, which is the entire reason the
    // page lives there — the deployment is at the 12/12 Hobby ceiling.
    const apiFiles: string[] = [];
    const walk = (d: string) => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const f = path.join(d, e.name);
        if (e.isDirectory()) walk(f);
        else if (f.endsWith(".ts")) apiFiles.push(f);
      }
    };
    walk(path.join(ROOT, "api"));
    expect(apiFiles).toHaveLength(12);
    expect(fs.existsSync(path.join(ROOT, "public"))).toBe(true);
  });

  // Named for `/invitations`, not the retired `/i` short path — the old name outlived the route it
  // described and read as if a second, undefended entry point still existed.
  it("the rewrite points /invitations at the static file", () => {
    expect(VERCEL.rewrites).toContainEqual({
      source: "/invitations",
      destination: "/invitations/index.html",
    });
    // The retired short path must not come back: it was never in AASA, so an OS following it would
    // land on the web page while the app sat installed and unused.
    const sources = (VERCEL.rewrites ?? []).map((r: { source: string }) => r.source);
    expect(sources).not.toContain("/i");
  });
});

/**
 * The deployment shape itself. Every 404 this surface has produced in practice came from a build
 * that simply did not contain these files — not from a bad rewrite — so the files' presence is
 * asserted directly rather than inferred from the routes that serve them.
 */
describe("★ the static output actually contains the deployed surface", () => {
  it("ships the landing page and both association files", () => {
    for (const rel of [
      ["public", "invitations", "index.html"],
      ["public", ".well-known", "apple-app-site-association"],
      ["public", ".well-known", "assetlinks.json"],
    ]) {
      expect(fs.existsSync(path.join(ROOT, ...rel)), rel.join("/")).toBe(true);
    }
  });

  it("the association files are extensionless/JSON exactly as Apple and Google fetch them", () => {
    // Apple requires the AASA to have NO extension and be served as JSON. A stray `.json` here
    // would still deploy, still return 200, and still never verify.
    expect(fs.existsSync(path.join(ROOT, "public", ".well-known", "apple-app-site-association.json"))).toBe(false);
    expect(() => JSON.parse(fs.readFileSync(path.join(ROOT, "public", ".well-known", "apple-app-site-association"), "utf8"))).not.toThrow();
    expect(() => JSON.parse(fs.readFileSync(path.join(ROOT, "public", ".well-known", "assetlinks.json"), "utf8"))).not.toThrow();
  });

  it("★ the canonical production host is app.after-worth.com", () => {
    // Pinned so a future edit cannot quietly reintroduce a host the mobile parser rejects. The
    // mobile client matches this host by exact equality; there is no prefix or suffix tolerance.
    const setup = fs.readFileSync(path.join(ROOT, "docs", "invitations", "invitation-domain-setup.md"), "utf8");
    expect(setup).toContain("https://app.after-worth.com/invitations");
    expect(setup).toContain("invitations@mail.after-worth.com");
  });
});
