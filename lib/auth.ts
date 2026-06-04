/**
 * Shared authentication helpers for AfterWorth Vercel routes.
 *
 * Responsibilities:
 *   1. Extract and verify Supabase JWTs from incoming requests
 *   2. Construct Supabase clients configured to forward those JWTs
 *      so that auth.uid() inside RPCs returns the real user ID
 *
 * Architecture notes:
 *   - Verification uses Supabase's JWKS endpoint (asymmetric ECC P-256).
 *     The legacy HS256 shared secret is no longer used.
 *   - JWKS responses are cached in-memory by jose for the lifetime
 *     of the warm Vercel function instance, so repeated requests
 *     don't re-fetch the keys.
 *   - AuthError is a discriminated union; each kind maps to a
 *     specific HTTP status in the route handler.
 */

import { createRemoteJWKSet, jwtVerify } from "jose";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

// ============================================================
// Types
// ============================================================

/**
 * A verified user identity extracted from a valid JWT.
 *
 * email may be null if the user signed up via a method that doesn't
 * include email (e.g., phone-only auth, which we don't support in V1
 * but might in V2). Routes that require email must check this and
 * respond with 400 if missing.
 */
export interface VerifiedUser {
  userId: string;
  email: string | null;
  jwt: string;
}

/**
 * Kinds of authentication failures. Each maps to HTTP 401 with a
 * different error body, letting iOS distinguish "you weren't signed in"
 * from "your session expired" if it wants to.
 */
export type AuthErrorKind =
  | "missing"   // No Authorization header at all
  | "malformed" // Header present but not "Bearer <something>"
  | "invalid"   // JWT signature failed, claims wrong, etc.
  | "expired";  // JWT was valid but is past its exp claim

export class AuthError extends Error {
  constructor(public readonly kind: AuthErrorKind, message: string) {
    super(message);
    this.name = "AuthError";
  }
}

// ============================================================
// JWKS setup
// ============================================================

/**
 * Supabase's JWKS endpoint URL.
 *
 * Derived from SUPABASE_URL at module load time. The endpoint serves
 * the project's public signing keys in JWK format. jose's
 * createRemoteJWKSet handles fetching, caching, and rotation
 * automatically.
 */
const SUPABASE_URL = process.env.SUPABASE_URL;
if (!SUPABASE_URL) {
  throw new Error(
    "SUPABASE_URL environment variable is required. Configure it in Vercel " +
    "project settings under Environment Variables.",
  );
}

const JWKS_URL = new URL(`${SUPABASE_URL}/auth/v1/.well-known/jwks.json`);

/**
 * Cached JWKS instance. Module-scoped so it persists across
 * invocations on the same warm Vercel function instance.
 *
 * jose handles cache TTLs, key rotation, and concurrent refresh
 * internally. We don't need to do anything beyond instantiating it once.
 */
const jwks = createRemoteJWKSet(JWKS_URL, {
  // Cache JWKS responses for 10 minutes. Supabase key rotation is
  // infrequent; this trades a tiny staleness window for far fewer
  // network calls during traffic bursts.
  cacheMaxAge: 10 * 60 * 1000,
  // If JWKS fetch fails, give up after 5 seconds rather than hanging
  // the request indefinitely.
  timeoutDuration: 5000,
});

// ============================================================
// JWT verification
// ============================================================

/**
 * Verify the Authorization header on an incoming Request.
 *
 * Returns a VerifiedUser on success. Throws AuthError on any failure
 * with a kind that callers can map to a specific HTTP response.
 *
 * What's verified:
 *   - Bearer token is present and well-formed
 *   - Signature is valid against Supabase's current JWKS
 *   - exp claim has not passed
 *   - iss claim matches the Supabase project's issuer
 *   - aud claim is "authenticated" (Supabase's default for signed-in users)
 *   - sub claim (the user ID) is present and is a valid UUID
 *
 * What's NOT verified here:
 *   - That the user actually still exists in auth.users (could have
 *     been deleted after the token was issued). Callers that care
 *     should query the database.
 *   - Email match against request body. That's a route-level concern.
 */
export async function verifyJwt(req: Request): Promise<VerifiedUser> {
  const authHeader = req.headers.get("authorization");
  if (!authHeader) {
    throw new AuthError("missing", "Missing Authorization header");
  }

  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    throw new AuthError(
      "malformed",
      "Authorization header is not in 'Bearer <token>' format",
    );
  }
  const token = match[1].trim();

  let payload: Record<string, unknown>;
  try {
    const result = await jwtVerify(token, jwks, {
      issuer: `${SUPABASE_URL}/auth/v1`,
      audience: "authenticated",
    });
    payload = result.payload;
  } catch (err) {
    // jose throws different error types for different failures.
    // We could distinguish them here, but for V1 the 'invalid' vs
    // 'expired' distinction is sufficient — jose's error messages
    // include "exp" for expired tokens.
    const msg = err instanceof Error ? err.message : "unknown error";
    if (msg.toLowerCase().includes("exp")) {
      throw new AuthError("expired", "JWT has expired");
    }
    throw new AuthError("invalid", `JWT verification failed: ${msg}`);
  }

  const userId = typeof payload.sub === "string" ? payload.sub : null;
  if (!userId) {
    throw new AuthError("invalid", "JWT missing 'sub' claim");
  }

  // Sanity-check that sub looks like a UUID. Supabase always issues
  // UUIDs for user IDs; anything else suggests a forged or malformed
  // token even if the signature happened to verify (unlikely but
  // defensive).
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(userId)) {
    throw new AuthError("invalid", "JWT 'sub' claim is not a UUID");
  }

  const email = typeof payload.email === "string" ? payload.email : null;

  return {
    userId,
    email,
    jwt: token,
  };
}

// ============================================================
// Authed Supabase client factory
// ============================================================

const SUPABASE_PUBLISHABLE_KEY = process.env.SUPABASE_PUBLISHABLE_KEY;
if (!SUPABASE_PUBLISHABLE_KEY) {
  throw new Error(
    "SUPABASE_PUBLISHABLE_KEY environment variable is required. Configure " +
    "it in Vercel project settings under Environment Variables.",
  );
}

/**
 * Construct a Supabase client that forwards the user's JWT on every
 * request. This is what makes auth.uid() return the real user ID
 * inside RPCs and lets RLS policies (when we add them in Phase 6)
 * enforce per-user access.
 *
 * IMPORTANT: We use the publishable key here, NOT the secret key.
 * The publishable key has minimal permissions on its own; combined
 * with the user's JWT, the effective permissions are the user's
 * permissions. This is the correct pattern for user-context calls.
 *
 * Using the secret key here would BYPASS RLS and grant full DB access,
 * which we never want from a per-user route.
 */
export function getAuthedSupabaseClient(jwt: string): SupabaseClient {
  return createClient(SUPABASE_URL!, SUPABASE_PUBLISHABLE_KEY!, {
    global: {
      headers: {
        Authorization: `Bearer ${jwt}`,
      },
    },
    auth: {
      // We're not using the client's own auth state — we're forwarding
      // an externally-issued JWT. Disable auto-refresh and persistence
      // to make that explicit.
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
}