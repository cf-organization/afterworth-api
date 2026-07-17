/**
 * Rate-limit enforcement — Upstash Redis (sliding window) via @upstash/ratelimit.
 *
 * Drop-in for the former no-op: the EXACT signature `enforce(req, bucket) -> Response | null` is
 * preserved, so every call site (`const rl = await enforce(req, "<bucket>"); if (rl) return rl;`)
 * works unchanged. null = allow; a 429 Response = deny.
 *
 * DESIGN (locked per recon + review):
 *   - Two tiers. TIER 1 (auth-adjacent / financial-provisioning) FAILS CLOSED: any limiter error or
 *     timeout DENIES — these are the brute-force / cost-abuse targets, and a silent Redis outage must
 *     not open them. We do NOT rely on @upstash/ratelimit's built-in timeout, which ALLOWS on Redis
 *     silence (fail-open) and would silently invert Tier 1 — the SDK timeout is DISABLED (timeout:false)
 *     and an explicit ~2s Promise.race + try/catch is the sole timeout authority.
 *     TIER 2 (general authed reads/writes) FAILS OPEN: a limiter error/timeout ALLOWS with a loud log,
 *     so a Redis blip never breaks the app. Tier 2 also honours a DRY-RUN flag.
 *   - UNKNOWN BUCKET FAILS CLOSED: a bucket string not in the registry denies + logs loudly, so a typo
 *     can never silently create an unlimited path.
 *   - Identity is VERIFIED, not decoded: enforce may run before route-level auth, so a decoded-only sub
 *     would be attacker-controlled. We reuse lib/auth.ts's `verifyJwt` (the cached JWKS path — no
 *     duplication). Valid token -> sub; invalid/absent -> IP fallback. IP = x-forwarded-for (Phase-0a
 *     spoof-tested: Vercel REPLACES it with the edge-observed client IP; client values never leak).
 *
 * Log prefixes (greppable): RATELIMIT_INFRA_DENY (Tier-1 outage->deny), RATELIMIT_INFRA_ALLOW (Tier-2
 * outage->allow), RATELIMIT_DRYRUN_DENY (Tier-2 would-deny but dry-run->allow), RATELIMIT_UNKNOWN_BUCKET.
 */

import { Ratelimit } from "@upstash/ratelimit";
import { Redis } from "@upstash/redis";
import { verifyJwt } from "./auth.js";

// ============================================================
// Module scope — read env ONCE at load, throw if missing (lib/auth.ts precedent). One Redis client +
// one Ratelimit instance per bucket, built once so they persist across warm Vercel invocations.
// ============================================================

const UPSTASH_REDIS_REST_URL = process.env.UPSTASH_REDIS_REST_URL;
const UPSTASH_REDIS_REST_TOKEN = process.env.UPSTASH_REDIS_REST_TOKEN;
if (!UPSTASH_REDIS_REST_URL || !UPSTASH_REDIS_REST_TOKEN) {
  throw new Error(
    "UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN are required. Configure them in Vercel " +
    "project settings under Environment Variables (and .env.local for local dev).",
  );
}

const redis = new Redis({ url: UPSTASH_REDIS_REST_URL, token: UPSTASH_REDIS_REST_TOKEN });

// Tier-2 dry-run: when "true", a Tier-2 over-limit is LOGGED (would-be denial) and ALLOWED. Tier 1 is
// NEVER dry-run. Flipping to live enforcement = deleting the env var.
const TIER2_DRY_RUN = process.env.RATE_LIMIT_TIER2_DRY_RUN === "true";

const LIMIT_TIMEOUT_MS = 2000; // our explicit timeout; the SDK's own (fail-open) timeout is disabled.

type Tier = 1 | 2;
type KeyBy = "user" | "ip" | "user+ip";
type Window = `${number} ${"ms" | "s" | "m" | "h" | "d"}`;
interface BucketConfig {
  tier: Tier;
  keyBy: KeyBy;
  limit: number;
  window: Window;
}

// The registry — one declarative row per bucket. Bucket strings reconciled verbatim against every
// enforce() call site (the four [action].ts dispatchers build `<name>_${action}`, so every action has
// a row). A string not here fails closed.
const REGISTRY: Record<string, BucketConfig> = {
  // ---- TIER 1 — fail-closed (auth-adjacent / financial-provisioning) ----
  invitationPreview:             { tier: 1, keyBy: "ip",      limit: 30, window: "1 m" }, // PUBLIC (no JWT) -> IP
  mfa_recover:                   { tier: 1, keyBy: "user+ip", limit: 5,  window: "1 m" },
  bind:                          { tier: 1, keyBy: "user+ip", limit: 10, window: "1 m" },
  accept:                        { tier: 1, keyBy: "user",    limit: 10, window: "1 m" },
  decline:                       { tier: 1, keyBy: "user",    limit: 10, window: "1 m" },
  resolve:                       { tier: 1, keyBy: "user",    limit: 20, window: "1 m" },
  access_requests_create:        { tier: 1, keyBy: "user",    limit: 10, window: "1 m" },
  connections_create_link_token: { tier: 1, keyBy: "user",    limit: 10, window: "1 m" },
  connections_exchange:          { tier: 1, keyBy: "user",    limit: 10, window: "1 m" },

  // ---- TIER 2 — fail-open + dry-run capable (general authed reads/writes), all user-keyed ----
  // Owner-authorized writes (grant mutations, access-request decisions): 20/min.
  vault_grants_create:           { tier: 2, keyBy: "user", limit: 20, window: "1 m" },
  vault_grants_create_asset:     { tier: 2, keyBy: "user", limit: 20, window: "1 m" },
  vault_grants_revoke:           { tier: 2, keyBy: "user", limit: 20, window: "1 m" }, // security-positive; must not block on outage
  vault_grants_approve:          { tier: 2, keyBy: "user", limit: 20, window: "1 m" },
  vault_grants_update_document:  { tier: 2, keyBy: "user", limit: 20, window: "1 m" },
  vault_grants_update_asset:     { tier: 2, keyBy: "user", limit: 20, window: "1 m" },
  access_requests_approve:       { tier: 2, keyBy: "user", limit: 20, window: "1 m" },
  access_requests_deny:          { tier: 2, keyBy: "user", limit: 20, window: "1 m" },
  connections_refresh:           { tier: 2, keyBy: "user", limit: 20, window: "1 m" },
  // RLS-scoped reads: 30/min.
  vault_grants_list:             { tier: 2, keyBy: "user", limit: 30, window: "1 m" },
  vault_grants_list_asset:       { tier: 2, keyBy: "user", limit: 30, window: "1 m" },
  vault_documents:               { tier: 2, keyBy: "user", limit: 30, window: "1 m" },
  vault_members:                 { tier: 2, keyBy: "user", limit: 30, window: "1 m" },
  connections_list:              { tier: 2, keyBy: "user", limit: 30, window: "1 m" },
  connections_net_worth:         { tier: 2, keyBy: "user", limit: 30, window: "1 m" },
  access_requests_list:          { tier: 2, keyBy: "user", limit: 30, window: "1 m" },
  notifications_mark_all_read:   { tier: 2, keyBy: "user", limit: 30, window: "1 m" },
  // High-frequency / multi-surface (Phase 0b): beneficiaries reloads across 6+ surfaces on every
  // activeContext tick -> 60/min (raised from 30). Notifications are event-driven (no polling).
  beneficiaries:                 { tier: 2, keyBy: "user", limit: 60, window: "1 m" },
  notifications_list:            { tier: 2, keyBy: "user", limit: 60, window: "1 m" },
  notifications_mark_read:       { tier: 2, keyBy: "user", limit: 60, window: "1 m" },
  notifications_unread_count:    { tier: 2, keyBy: "user", limit: 60, window: "1 m" }, // 0 iOS callers today; defensive row
  // Acknowledgment-class consent (api/consents/[action].ts -> record_consent RPC / RLS-scoped read). Tier-2:
  // a consent write is not auth-adjacent, and an append-only record must not be blocked by a limiter outage.
  consents_record:               { tier: 2, keyBy: "user", limit: 20, window: "1 m" },
  consents_list:                 { tier: 2, keyBy: "user", limit: 30, window: "1 m" },
  // Client audit-forward pipe (api/audit.ts -> forward_client_audit). Tier-2 fail-open: telemetry must
  // never be gated by a limiter outage, and it's already best-effort/fire-and-forget on the client. 60/min
  // fits the bursty pre/post-signup coordinator fan-out (matches the beneficiaries/notifications tier).
  audit_forward:                 { tier: 2, keyBy: "user", limit: 60, window: "1 m" },
  // Admin evidence viewer (api/claims/[action].ts -> admin_authorize_claim_evidence). Tier-2 anti-abuse only:
  // the RPC's admin gate (auth->is_admin->aal2->freshness) is the security boundary; this bounds a scripted
  // pull of PII scans. 60/min covers a reviewer opening both docs across several claims per minute.
  claims_view_evidence:          { tier: 2, keyBy: "user", limit: 60, window: "1 m" },
};

// One Ratelimit per bucket, module-scope. timeout:false disables the SDK's fail-open timeout (ours is
// authoritative). analytics:false. Each gets its OWN ephemeral cache (a per-limiter Map, module-scope so
// it survives warm invocations) — never shared across buckets, or a userId blocked on one bucket would
// be treated as blocked on another.
const limiters = new Map<string, Ratelimit>();
for (const [bucket, cfg] of Object.entries(REGISTRY)) {
  limiters.set(
    bucket,
    new Ratelimit({
      redis,
      limiter: Ratelimit.slidingWindow(cfg.limit, cfg.window),
      prefix: `rl:${bucket}`,
      analytics: false,
      // The SDK's own timeout FAILS OPEN (returns success) on Redis silence — which would silently invert
      // Tier 1. v2 types `timeout` as a number (can't pass false), so set it comfortably ABOVE our own 2s
      // race so the SDK path is unreachable: withTimeout() in enforce() rejects at 2s first and IS the
      // authoritative timeout for both tiers (Tier-1 -> deny, Tier-2 -> allow).
      timeout: LIMIT_TIMEOUT_MS + 8000,
      ephemeralCache: new Map<string, number>(),
    }),
  );
}

// ============================================================
// enforce
// ============================================================

export async function enforce(req: Request, bucket: string): Promise<Response | null> {
  const cfg = REGISTRY[bucket];

  // UNKNOWN BUCKET -> FAIL CLOSED. A typo must never create an unlimited path.
  if (!cfg) {
    console.error(`RATELIMIT_UNKNOWN_BUCKET bucket=${bucket} — not in registry, failing closed (deny)`);
    return denyResponse(60);
  }

  const limiter = limiters.get(bucket)!;
  const identifier = await resolveIdentifier(req, cfg.keyBy);

  if (cfg.tier === 1) {
    // TIER 1 — fail CLOSED. Any error/timeout denies.
    let result: Awaited<ReturnType<Ratelimit["limit"]>>;
    try {
      result = await withTimeout(limiter.limit(identifier), LIMIT_TIMEOUT_MS);
    } catch (err) {
      console.error(`RATELIMIT_INFRA_DENY bucket=${bucket} — limiter unreachable, failing closed: ${errMsg(err)}`);
      return denyResponse(60);
    }
    result.pending?.catch(() => {});
    if (!result.success) {
      return denyResponse(retryAfterSeconds(result.reset));
    }
    return null;
  }

  // TIER 2 — fail OPEN. Any error/timeout allows (loud log).
  let result: Awaited<ReturnType<Ratelimit["limit"]>>;
  try {
    result = await withTimeout(limiter.limit(identifier), LIMIT_TIMEOUT_MS);
  } catch (err) {
    console.error(`RATELIMIT_INFRA_ALLOW bucket=${bucket} — limiter unreachable, failing open (allow): ${errMsg(err)}`);
    return null;
  }
  result.pending?.catch(() => {});
  if (!result.success) {
    if (TIER2_DRY_RUN) {
      const count = result.limit - result.remaining; // observed usage within the window
      console.warn(`RATELIMIT_DRYRUN_DENY bucket=${bucket} key=${identifier} count=${count} limit=${result.limit}`);
      return null; // dry-run: allow
    }
    return denyResponse(retryAfterSeconds(result.reset));
  }
  return null;
}

// ============================================================
// Identity + helpers
// ============================================================

async function resolveIdentifier(req: Request, keyBy: KeyBy): Promise<string> {
  const ip = clientIp(req);
  if (keyBy === "ip") return ip;

  // "user" / "user+ip": VERIFY the JWT (reusing the cached JWKS path) — a decoded-only sub would be
  // attacker-controlled. Invalid/absent -> IP fallback.
  let sub: string | null = null;
  try {
    sub = (await verifyJwt(req)).userId;
  } catch {
    sub = null;
  }

  if (keyBy === "user") return sub ?? ip;
  return sub ? `${sub}:${ip}` : ip; // user+ip, IP fallback when no valid sub
}

// Phase 0a (empirical, live preview): Vercel REPLACES x-forwarded-for with the edge-observed client IP
// and drops client-supplied values. So the first token is the real client IP. NOTE: this is authoritative
// ONLY because Vercel is the edge — if Cloudflare ever fronts the API, CF-Connecting-IP takes over.
function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  const xri = req.headers.get("x-real-ip");
  if (xri) return xri.trim();
  return "unknown";
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(`ratelimit timeout after ${ms}ms`)), ms),
    ),
  ]);
}

function retryAfterSeconds(reset: number): number {
  // reset is a Unix ms timestamp for when the window frees up.
  return Math.max(1, Math.ceil((reset - Date.now()) / 1000));
}

// Mirrors recover.ts's shape ({ error: <code> } + application/json), adds Retry-After (seconds).
function denyResponse(retryAfterSec: number): Response {
  return new Response(JSON.stringify({ error: "too_many_requests" }), {
    status: 429,
    headers: {
      "Content-Type": "application/json",
      "Retry-After": String(Math.max(1, retryAfterSec)),
    },
  });
}

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
