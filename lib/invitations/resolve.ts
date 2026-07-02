/**
 * POST /api/invitations/resolve
 *
 * Resolves the authenticated user's membership context: their primary
 * estate (auto-created on first call if none exists), pending invitations
 * matching their email/phone, and additional estate memberships.
 *
 * Request:
 *   Headers: Authorization: Bearer <Supabase JWT>
 *            Content-Type: application/json
 *   Body:    { email: string, phone?: string }
 *
 * Response (200):
 *   {
 *     primaryEstateContext: EstateContext,
 *     pendingInvitations: PendingInvitation[],
 *     additionalContexts: EstateContext[]
 *   }
 *
 * Errors:
 *   401 — missing/invalid/expired JWT
 *   400 — bad body shape OR email in body doesn't match email in JWT
 *   405 — method not POST
 *   502 — Supabase RPC failed
 *   500 — anything else
 */

import { enforce } from "../rateLimit.js";
import {
  verifyJwt,
  getAuthedSupabaseClient,
  AuthError,
} from "../auth.js";

// ============================================================
// Types
// ============================================================

interface ResolveRequestBody {
  email: string;
  phone?: string;
}

// ============================================================
// Body validation
// ============================================================

/**
 * Type-narrow and validate the request body. Returns null if invalid;
 * the route handler maps null to a 400 response.
 *
 * V1 rules:
 *   - email is required, must be a non-empty string under 320 chars
 *     (RFC 5321 limit)
 *   - phone is optional, must be a non-empty string under 32 chars
 *     if present (E.164 max is 15 digits, but we allow formatting)
 */
function parseBody(raw: unknown): ResolveRequestBody | null {
  if (raw === null || typeof raw !== "object") return null;

  const obj = raw as Record<string, unknown>;

  if (typeof obj.email !== "string") return null;
  const email = obj.email.trim();
  if (email.length === 0 || email.length > 320) return null;

  let phone: string | undefined;
  if (obj.phone !== undefined && obj.phone !== null) {
    if (typeof obj.phone !== "string") return null;
    const phoneTrimmed = obj.phone.trim();
    if (phoneTrimmed.length > 32) return null;
    // Treat empty string as omitted phone.
    phone = phoneTrimmed.length > 0 ? phoneTrimmed : undefined;
  }

  return { email, phone };
}

// ============================================================
// Response helpers
// ============================================================

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, code: string): Response {
  return jsonResponse(status, { error: code });
}

/**
 * Map an AuthError kind to the appropriate 401 response code.
 * Returning distinct codes (vs a generic "unauthorized") lets iOS
 * distinguish "you weren't signed in" from "your session expired".
 */
function authErrorResponse(err: AuthError): Response {
  switch (err.kind) {
    case "missing":
      return errorResponse(401, "missing_token");
    case "malformed":
      return errorResponse(401, "malformed_token");
    case "expired":
      return errorResponse(401, "expired_token");
    case "invalid":
      return errorResponse(401, "invalid_token");
  }
}

// ============================================================
// Handler
// ============================================================

export async function handle(req: Request): Promise<Response> {
  // -- Step A: Method check --
  // POST is the only allowed method. Vercel routes the function regardless
  // of method, so we enforce it here.
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  // -- Step B: Verify JWT --
  let user;
  try {
    user = await verifyJwt(req);
  } catch (err) {
    if (err instanceof AuthError) {
      return authErrorResponse(err);
    }
    // Unexpected error from auth module (e.g., JWKS endpoint down)
    // — surface as 502 since it's an upstream dependency failing.
    console.error("Unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  // -- Step C: Parse and validate body --
  let body: ResolveRequestBody | null;
  try {
    const raw = await req.json();
    body = parseBody(raw);
  } catch {
    // JSON parse failed
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  // -- Step D: Email match check --
  // The email in the request body must match the email in the JWT.
  // This prevents a malicious client from sending a different email
  // to harvest pending invitations addressed to someone else.
  //
  // We compare case-insensitively because email matching in resolve_membership
  // is also case-insensitive (it lowercases both sides).
  if (user.email === null) {
    // JWT has no email claim — user signed up via a method that doesn't
    // provide one. Can't validate; reject defensively.
    return errorResponse(400, "jwt_missing_email");
  }
  if (body.email.toLowerCase() !== user.email.toLowerCase()) {
    return errorResponse(400, "email_mismatch");
  }

  // -- Step E: Rate limit --
  // Currently a no-op stub from Phase 1. Phase 3 will fill in real
  // Redis-backed rate limiting per user. The call is kept here so
  // Phase 3 can land without touching this file.
  const rateLimitResponse = await enforce(req, "resolve");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  // -- Step F: Call Supabase RPC --
  // The Supabase client is configured with the user's JWT, so
  // auth.uid() inside resolve_membership() returns the real user ID.
  const supabase = getAuthedSupabaseClient(user.jwt);

  const { data, error } = await supabase.rpc("resolve_membership", {
    p_email: body.email,
    p_phone: body.phone ?? null,
  });

  if (error) {
    // Differentiate between Supabase explicitly returning "unauthenticated"
    // (which would be odd — we already verified the JWT) and other failures.
    if (error.code === "42501") {
      console.error("Supabase reported unauthenticated despite valid JWT:", error);
      return errorResponse(401, "unauthenticated_at_db");
    }
    console.error("Supabase RPC error:", error);
    return errorResponse(502, "upstream_error");
  }

  // -- Step G: Return the JSON response --
  // resolve_membership returns the full structured jsonb. We pass
  // it through unchanged; iOS expects { primaryEstateContext,
  // pendingInvitations, additionalContexts }.
  if (data === null || typeof data !== "object") {
    console.error("Supabase RPC returned unexpected shape:", data);
    return errorResponse(502, "upstream_unexpected_shape");
  }

  return jsonResponse(200, data);
}