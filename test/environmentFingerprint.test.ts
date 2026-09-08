/**
 * THE DEPLOYMENT IDENTITY FINGERPRINT.
 *
 * ★ WHAT THIS FILE IS DEFENDING. The endpoint's whole job is to let a client REFUSE a backend. Two
 *   ways it could betray that job, and both are tested rather than reasoned about:
 *
 *     1. Saying the wrong thing — a host matcher that accepts `…supabase.co.attacker.test`, or a
 *        parser that defaults an unset declaration to something convenient.
 *     2. Saying too much — a response assembled by filtering an environment object, which leaks the
 *        first variable somebody adds without touching this file.
 *
 * ★ THE WIRING IS TESTED THROUGH THE REAL DISPATCHER, NOT BY GREPPING FOR THE NAME. This repository
 *   has been burned by an audit whose predicate was `src.includes('ScreenBackHeader')` — satisfied by
 *   the import of a component nothing rendered. So the reachability tests below CALL the exported GET
 *   of `api/invitations/[action].ts` and assert on the response, which no amount of dead import can
 *   satisfy.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  environmentFingerprint,
  handle,
  parseDeclaredEnvironment,
  parseSourceSha,
  parseSupabaseProjectRef,
  parseVercelEnvironment,
} from "../lib/environmentFingerprint.js";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * ★ WHY @supabase/supabase-js IS STUBBED HERE, AND WHAT THAT CANNOT HIDE.
 *
 * The reachability tests import the REAL dispatcher, which statically imports the whole invitation
 * handler graph. `lib/invitations/preview.ts` builds a Supabase client AT MODULE SCOPE, and
 * supabase-js builds a RealtimeClient inside that constructor, which needs a native WebSocket.
 * CI's `verify` job runs Node 20, which has none — so importing the dispatcher throws there while
 * passing on this machine (Node 26) and in production (Vercel `nodeVersion: 24.x`).
 *
 * ★ THAT IS A PRE-EXISTING MISALIGNMENT THIS FILE MERELY SURFACED, NOT A DEFECT IT INTRODUCED. No
 *   test in this repository had ever imported an api/ route before, so nothing had occasion to
 *   discover that the verification runtime is two majors behind the deployed one. It is written up
 *   as a finding rather than silently absorbed here; production is unaffected.
 *
 * ★ THE STUB CANNOT MASK A FINGERPRINT DEFECT. `lib/environmentFingerprint.ts` imports NOTHING — it
 *   reads four process variables and returns an object. The stub stands in only for an SDK that
 *   UNRELATED SIBLING HANDLERS construct at import time, and the property under test is which action
 *   the router selects. Mocking the module under test would recreate the blind spot; mocking a
 *   third-party boundary that the subject never touches does not.
 */
vi.mock("@supabase/supabase-js", () => ({
  createClient: () => ({}),
}));

/** The two real project refs. Identifiers, not secrets — both are already committed in this repo. */
const NONPROD_REF = "qxzeougbaarecaiiqsay";
const APPLICATION_FACING_REF = "yiaavvkulrpqkkbqhwit";
const NONPROD_URL = `https://${NONPROD_REF}.supabase.co`;
const APPLICATION_FACING_URL = `https://${APPLICATION_FACING_REF}.supabase.co`;

const SHA = "90b8c8dae63aa716ce018f39da948b8154a82957";

/**
 * Clearly-synthetic stand-ins, ASSEMBLED AT RUNTIME so no credential-shaped literal is ever
 * committed. Every one of these must be absent from every response this module can produce.
 */
const SYNTHETIC = {
  SUPABASE_SECRET_KEY: ["sb", "secret", "S".repeat(40)].join("_"),
  SUPABASE_PUBLISHABLE_KEY: ["sb", "publishable", "P".repeat(40)].join("_"),
  RESEND_API_KEY: ["r", "e_", "R".repeat(32)].join(""),
  CRON_SECRET: "C".repeat(48),
  UPSTASH_REDIS_REST_TOKEN: "U".repeat(64),
  UPSTASH_REDIS_REST_URL: "https://synthetic-redis.upstash.test",
  PLAID_SECRET: "L".repeat(30),
  INVITATION_FROM_EMAIL: "noreply@synthetic.invalid",
};

// ════════════════════════════════════════════════════════════════════════════════════════════════
describe("parseSupabaseProjectRef — the host is matched at a label boundary", () => {
  it("★ POSITIVE CONTROLS — it can see BOTH real refs, so a later refusal is not a blind matcher", () => {
    expect(parseSupabaseProjectRef(NONPROD_URL)).toBe(NONPROD_REF);
    expect(parseSupabaseProjectRef(APPLICATION_FACING_URL)).toBe(APPLICATION_FACING_REF);
  });

  it("tolerates a trailing slash and an uppercase host, because hostnames are case-insensitive", () => {
    expect(parseSupabaseProjectRef(`${NONPROD_URL}/`)).toBe(NONPROD_REF);
    expect(parseSupabaseProjectRef(`HTTPS://${NONPROD_REF.toUpperCase()}.SUPABASE.CO`)).toBe(NONPROD_REF);
    expect(parseSupabaseProjectRef(`  ${NONPROD_URL}  `)).toBe(NONPROD_REF);
  });

  it("★ REFUSES THE SUFFIX ATTACK — the string a substring check would have accepted", () => {
    // Every one of these CONTAINS "<ref>.supabase.co" and resolves somewhere else entirely.
    expect(parseSupabaseProjectRef(`https://${NONPROD_REF}.supabase.co.attacker.test`)).toBeNull();
    expect(parseSupabaseProjectRef(`https://${NONPROD_REF}.supabase.co.evil.example`)).toBeNull();
    expect(parseSupabaseProjectRef(`https://attacker.test/${NONPROD_REF}.supabase.co`)).toBeNull();
    expect(parseSupabaseProjectRef(`https://x.${NONPROD_REF}.supabase.co`)).toBeNull();
  });

  it("refuses plaintext, because a project this deployment used would not be reachable over http", () => {
    expect(parseSupabaseProjectRef(`http://${NONPROD_REF}.supabase.co`)).toBeNull();
  });

  it("refuses a host that is not <ref>.supabase.co", () => {
    for (const bad of [
      "https://supabase.co",
      "https://notsupabase.co",
      `https://${NONPROD_REF}.supabase.io`,
      `https://${NONPROD_REF}.supabase.com`,
      `https://${NONPROD_REF}.example.co`,
    ]) {
      expect(parseSupabaseProjectRef(bad), bad).toBeNull();
    }
  });

  it("refuses a label that is not exactly twenty lowercase letters", () => {
    for (const label of ["a".repeat(19), "a".repeat(21), "a".repeat(19) + "1", "a".repeat(19) + "-"]) {
      expect(parseSupabaseProjectRef(`https://${label}.supabase.co`), label).toBeNull();
    }
  });

  it("refuses absent, empty and unparseable input rather than guessing", () => {
    for (const bad of [undefined, null, "", "   ", "not a url", "://", NONPROD_REF]) {
      expect(parseSupabaseProjectRef(bad as string | null | undefined), String(bad)).toBeNull();
    }
  });

  it("★ IS STATELESS — twice in one process gives the same answer", () => {
    // The private-palette matcher in the sibling repository was written /gm and used with .test(),
    // so `lastIndex` persisted and consecutive calls alternated. Never assume; assert.
    const runs = Array.from({ length: 6 }, (_, i) =>
      parseSupabaseProjectRef(i % 2 === 0 ? NONPROD_URL : APPLICATION_FACING_URL),
    );
    expect(runs).toEqual([NONPROD_REF, APPLICATION_FACING_REF, NONPROD_REF, APPLICATION_FACING_REF, NONPROD_REF, APPLICATION_FACING_REF]);
  });
});

// ════════════════════════════════════════════════════════════════════════════════════════════════
describe("parseDeclaredEnvironment — a closed union with no default", () => {
  it("accepts exactly the two declarations", () => {
    expect(parseDeclaredEnvironment("nonprod")).toBe("nonprod");
    expect(parseDeclaredEnvironment("production")).toBe("production");
  });

  it("★ HAS NO `dev` MEMBER — the project named 'dev' is the application-facing one", () => {
    expect(parseDeclaredEnvironment("dev")).toBeNull();
    expect(parseDeclaredEnvironment("development")).toBeNull();
    expect(parseDeclaredEnvironment("staging")).toBeNull();
  });

  it("does not default an unset, misspelled or padded value into an answer", () => {
    for (const bad of [undefined, null, "", " nonprod", "Nonprod", "NONPROD", "prod", "nonprod "]) {
      expect(parseDeclaredEnvironment(bad as string | null | undefined), JSON.stringify(bad)).toBeNull();
    }
  });

  it("★ IS NOT AN OBJECT LOOKUP — inherited property names are not members", () => {
    // A `raw in MAP` or `MAP[raw]` implementation would answer for these.
    for (const bad of ["toString", "constructor", "__proto__", "hasOwnProperty", "valueOf"]) {
      expect(parseDeclaredEnvironment(bad), bad).toBeNull();
    }
  });
});

// ════════════════════════════════════════════════════════════════════════════════════════════════
describe("parseSourceSha and parseVercelEnvironment", () => {
  it("accepts a full 40-character lowercase sha and nothing shorter", () => {
    expect(parseSourceSha(SHA)).toBe(SHA);
    expect(parseSourceSha(` ${SHA} `)).toBe(SHA);
    expect(parseSourceSha(SHA.slice(0, 39))).toBeNull();
    expect(parseSourceSha(SHA + "a")).toBeNull();
    expect(parseSourceSha(SHA.toUpperCase())).toBeNull();
    expect(parseSourceSha(SHA.slice(0, 7))).toBeNull();
    expect(parseSourceSha("z".repeat(40))).toBeNull();
    expect(parseSourceSha(undefined)).toBeNull();
  });

  it("reports Vercel's target only from its own closed vocabulary", () => {
    expect(parseVercelEnvironment("production")).toBe("production");
    expect(parseVercelEnvironment("preview")).toBe("preview");
    expect(parseVercelEnvironment("development")).toBe("development");
    for (const bad of [undefined, "", "nonprod", "prod", "Production"]) {
      expect(parseVercelEnvironment(bad as string | undefined), String(bad)).toBeNull();
    }
  });
});

// ════════════════════════════════════════════════════════════════════════════════════════════════
describe("environmentFingerprint — an allow-list of four reads, never a filter", () => {
  it("derives all four fields from a fully configured nonprod environment", () => {
    expect(
      environmentFingerprint({
        AFTERWORTH_API_ENV: "nonprod",
        SUPABASE_URL: NONPROD_URL,
        VERCEL_GIT_COMMIT_SHA: SHA,
        VERCEL_ENV: "production",
      }),
    ).toEqual({
      environment: "nonprod",
      supabaseProjectRef: NONPROD_REF,
      sourceSha: SHA,
      vercelEnv: "production",
    });
  });

  it("reports an empty environment as four nulls rather than as an error or a guess", () => {
    expect(environmentFingerprint({})).toEqual({
      environment: null,
      supabaseProjectRef: null,
      sourceSha: null,
      vercelEnv: null,
    });
  });

  it("★ REPORTS A DISAGREEMENT INSTEAD OF RESOLVING IT — the ref is the authority, not the label", () => {
    // An operator marks a deployment "nonprod" while it is wired to the application-facing project.
    // Nothing here may launder that into a single reassuring verdict; both facts must survive.
    const fp = environmentFingerprint({ AFTERWORTH_API_ENV: "nonprod", SUPABASE_URL: APPLICATION_FACING_URL });
    expect(fp.environment).toBe("nonprod");
    expect(fp.supabaseProjectRef).toBe(APPLICATION_FACING_REF);
  });

  it("★ THE FIELD SET IS CLOSED — a fifth key cannot appear without editing this expectation", () => {
    const keys = Object.keys(environmentFingerprint({ SUPABASE_URL: NONPROD_URL, ...SYNTHETIC })).sort();
    expect(keys).toEqual(["environment", "sourceSha", "supabaseProjectRef", "vercelEnv"]);
  });

  it("★ NO ENVIRONMENT VALUE OTHER THAN THE FOUR DERIVED FIELDS REACHES THE OUTPUT", () => {
    const body = JSON.stringify(
      environmentFingerprint({ AFTERWORTH_API_ENV: "nonprod", SUPABASE_URL: NONPROD_URL, ...SYNTHETIC }),
    );
    for (const [name, value] of Object.entries(SYNTHETIC)) {
      expect(body.includes(value), `${name} leaked into the response`).toBe(false);
    }
    // ★ POSITIVE CONTROL for the detector itself. A `includes` check that cannot find a value that
    //   IS present proves nothing about the values it reports as absent.
    const leaky = JSON.stringify({ ...JSON.parse(body), oops: SYNTHETIC.SUPABASE_SECRET_KEY });
    expect(leaky.includes(SYNTHETIC.SUPABASE_SECRET_KEY)).toBe(true);
  });

  it("★ EMITS THE REF BUT NEVER THE URL IT CAME FROM", () => {
    const body = JSON.stringify(environmentFingerprint({ SUPABASE_URL: NONPROD_URL }));
    expect(body).toContain(NONPROD_REF);          // the identifier, which the client bundle already ships
    expect(body).not.toContain("supabase.co");    // the endpoint it addresses
    expect(body).not.toContain(NONPROD_URL);
  });
});

// ════════════════════════════════════════════════════════════════════════════════════════════════
describe("handle — the response contract, running against the REAL process.env", () => {
  const saved = { ...process.env };
  beforeEach(() => {
    // ★ THE PRODUCTION DEFAULT IS THE THING UNDER TEST. `handle` reads process.env itself; a test
    //   that injected an environment would prove the parsers and nothing about the handler.
    for (const [k, v] of Object.entries(SYNTHETIC)) process.env[k] = v;
    process.env.AFTERWORTH_API_ENV = "nonprod";
    process.env.SUPABASE_URL = NONPROD_URL;
    process.env.VERCEL_GIT_COMMIT_SHA = SHA;
    process.env.VERCEL_ENV = "production";
  });
  afterEach(() => {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
    Object.assign(process.env, saved);
  });

  it("answers a GET with 200, JSON, and no-store", async () => {
    const res = await handle(new Request("https://api.example.test/api/environment"));
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/json");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(await res.json()).toEqual({
      environment: "nonprod",
      supabaseProjectRef: NONPROD_REF,
      sourceSha: SHA,
      vercelEnv: "production",
    });
  });

  it("★ THE RESPONSE BODY CARRIES NO CONFIGURED SECRET", async () => {
    const body = await (await handle(new Request("https://api.example.test/api/environment"))).text();
    for (const [name, value] of Object.entries(SYNTHETIC)) {
      expect(body.includes(value), `${name} leaked`).toBe(false);
    }
    expect(body.includes(NONPROD_REF)).toBe(true);   // positive control: it did produce a real answer
  });

  it("refuses a non-GET method", async () => {
    for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
      const res = await handle(new Request("https://api.example.test/api/environment", { method }));
      expect(res.status, method).toBe(405);
      expect(await res.json()).toEqual({ error: "method_not_allowed" });
    }
  });

  it("still answers when the deployment declares nothing", async () => {
    delete process.env.AFTERWORTH_API_ENV;
    delete process.env.VERCEL_GIT_COMMIT_SHA;
    const res = await handle(new Request("https://api.example.test/api/environment"));
    expect(res.status).toBe(200);
    // A 404 or a 500 here would be indistinguishable from a deployment that predates the endpoint,
    // and the guard that consumes this needs "declares nothing" to be an ANSWER.
    expect(await res.json()).toMatchObject({ environment: null, sourceSha: null, supabaseProjectRef: NONPROD_REF });
  });
});

// ════════════════════════════════════════════════════════════════════════════════════════════════
describe("★ REACHABILITY — through the real dispatcher, not through a grep", () => {
  const saved = { ...process.env };
  beforeEach(() => {
    // Every route in this repository dies at module load without these; the dispatcher imports the
    // whole invitation handler graph, so the fingerprint inherits that requirement.
    process.env.SUPABASE_URL = NONPROD_URL;
    process.env.SUPABASE_PUBLISHABLE_KEY = SYNTHETIC.SUPABASE_PUBLISHABLE_KEY;
    process.env.UPSTASH_REDIS_REST_URL = SYNTHETIC.UPSTASH_REDIS_REST_URL;
    process.env.UPSTASH_REDIS_REST_TOKEN = SYNTHETIC.UPSTASH_REDIS_REST_TOKEN;
    process.env.AFTERWORTH_API_ENV = "nonprod";
    vi.resetModules();
  });
  afterEach(() => {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
    Object.assign(process.env, saved);
  });

  const dispatcher = () => import("../api/invitations/[action].js");

  it("GET /api/invitations/environment — the PHYSICAL path — returns the fingerprint", async () => {
    const { GET } = await dispatcher();
    const res = await GET(new Request("https://api.example.test/api/invitations/environment"));
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ environment: "nonprod", supabaseProjectRef: NONPROD_REF });
  });

  it("★ GET /api/environment — the REWRITTEN path — resolves to the same action", async () => {
    // The route keys on the LAST path segment, so it does not matter whether the platform hands the
    // function the source path or the rewritten one. That is the property that lets this branch ship
    // a rewrite it is not permitted to deploy and therefore cannot observe.
    const { GET } = await dispatcher();
    const res = await GET(new Request("https://api.example.test/api/environment"));
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ supabaseProjectRef: NONPROD_REF });
  });

  it("tolerates a trailing slash and a query string, as the sibling actions do", async () => {
    const { GET } = await dispatcher();
    for (const url of [
      "https://api.example.test/api/environment/",
      "https://api.example.test/api/environment?cachebust=1",
      "https://api.example.test/api/invitations/environment/",
    ]) {
      expect((await GET(new Request(url))).status, url).toBe(200);
    }
  });

  it("an unknown GET action is still 404 — the dispatcher did not become permissive", async () => {
    const { GET } = await dispatcher();
    const res = await GET(new Request("https://api.example.test/api/invitations/not_an_action"));
    expect(res.status).toBe(404);
  });

  it("★ THE EXISTING CRON ACTION STILL ROUTES — adding a sibling did not displace it", async () => {
    const { GET } = await dispatcher();
    // No CRON_SECRET is configured here, so the drain must fail closed at 401 rather than 404.
    const res = await GET(new Request("https://api.example.test/api/invitations/drain_email_outbox"));
    expect(res.status).toBe(401);
  });

  it("POST /api/invitations/environment is NOT routed — the fingerprint is read-only at the router", async () => {
    const { POST } = await dispatcher();
    const res = await POST(new Request("https://api.example.test/api/invitations/environment", { method: "POST" }));
    expect(res.status).toBe(404);
  });
});

// ════════════════════════════════════════════════════════════════════════════════════════════════
describe("★ the deployment contract", () => {
  it("the public path is rewritten to the dispatcher, and both end in the same segment", () => {
    const vercel = JSON.parse(readFileSync(join(ROOT, "vercel.json"), "utf8"));
    const rewrite = (vercel.rewrites ?? []).find((r: { source: string }) => r.source === "/api/environment");
    expect(rewrite, "/api/environment rewrite is absent").toBeTruthy();
    expect(rewrite.destination).toBe("/api/invitations/environment");
    // The routing property the handler depends on, pinned so a future edit cannot silently break it.
    const last = (p: string) => p.split("/").filter(Boolean).pop();
    expect(last(rewrite.source)).toBe(last(rewrite.destination));
  });

  it("no cron was added — the Hobby two-job cap is still spent on the two drains", () => {
    const vercel = JSON.parse(readFileSync(join(ROOT, "vercel.json"), "utf8"));
    const paths = (vercel.crons ?? []).map((c: { path: string }) => c.path);
    expect(paths).toEqual(["/api/claims/drain_outboxes", "/api/invitations/drain_email_outbox"]);
  });

  it("★ THE FINGERPRINT IS NOT AN api/ FILE — that is the whole reason it rides a dispatcher", () => {
    const dispatcherSrc = readFileSync(join(ROOT, "api", "invitations", "[action].ts"), "utf8");
    // Usage, not merely import: the action must be in the GET map.
    expect(dispatcherSrc).toMatch(/GET_HANDLERS[^}]*\benvironment\b/s);
    expect(dispatcherSrc).toContain('from "../../lib/environmentFingerprint.js"');
  });
});
