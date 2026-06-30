/**
 * POST /api/auth/mfa/recover
 *
 * MFA account recovery. A user who lost their authenticator (session is aal1) presents a
 * one-time recovery code; on a valid code we REMOVE their MFA factor via the SUPPORTED admin
 * API (auth.admin.mfa.deleteFactor — which ALSO revokes all their sessions, the security-
 * correct response to an MFA reset), so they fall back to password-only, can sign in, and
 * re-enroll. We do NOT raw-delete auth.mfa_factors (that would skip the session revocation).
 *
 * ORDER (load-bearing): code-check FIRST (the RLS-self-scoped consume_recovery_code RPC, run
 * AS THE USER), THEN the admin factor-delete — never the reverse. The service role is used
 * ONLY for the auth-admin op, and ONLY after a valid code is consumed. It is NOT an RLS bypass
 * on data (the "never service key for data" invariant is intact — this is an auth-admin op).
 *
 * Request:  Authorization: Bearer <aal1 JWT>; body { code }
 * Response (200): { recovered: true }   (the client routes to login; the session is revoked)
 * Errors: 401 auth, 400 invalid code / bad body, 429 locked (too many attempts), 405 method,
 *   502 upstream / missing service-role config.
 */

import { createClient } from "@supabase/supabase-js";
import { enforce } from "../../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../../lib/auth.js";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
function errorResponse(status: number, code: string): Response {
  return jsonResponse(status, { error: code });
}
function authErrorResponse(err: AuthError): Response {
  switch (err.kind) {
    case "missing": return errorResponse(401, "missing_token");
    case "malformed": return errorResponse(401, "malformed_token");
    case "expired": return errorResponse(401, "expired_token");
    case "invalid": return errorResponse(401, "invalid_token");
  }
}

export async function POST(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  // The caller is the aal1 user (lost their factor); their JWT identifies WHO.
  let user;
  try {
    user = await verifyJwt(req);
  } catch (err) {
    if (err instanceof AuthError) return authErrorResponse(err);
    console.error("Unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  let code: string;
  try {
    const raw = await req.json();
    code = raw && typeof (raw as Record<string, unknown>).code === "string"
      ? ((raw as Record<string, unknown>).code as string).trim()
      : "";
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (code.length === 0) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "mfa_recover");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  // ---- 1. VALIDATE the code (do NOT consume yet): RLS-self-scoped, run AS THE USER. Returns the
  //         code's id, or null for a wrong/used code; raises P0001 on lockout. The code is NOT
  //         burned here — so a later deleteFactor failure can't strand the user on a dead code. ----
  const authed = getAuthedSupabaseClient(user.jwt);
  const { data: codeId, error: validateErr } = await authed.rpc("validate_recovery_code", {
    p_code: code,
  });
  if (validateErr) {
    if (validateErr.code === "P0001") {
      return errorResponse(429, "too_many_attempts"); // lockout active
    }
    console.error("validate_recovery_code error:", validateErr);
    return errorResponse(502, "upstream_error");
  }
  if (!codeId || typeof codeId !== "string") {
    // null = wrong/used code (the failed attempt was already counted inside the RPC).
    return errorResponse(400, "invalid_recovery_code");
  }

  // ---- 2. THEN the admin factor-delete (service-role; revokes sessions). Reached ONLY after a
  //         VALID code (not yet consumed). If anything here fails we return 502 with the code
  //         still UNUSED → the user retries cleanly, no burned code. Service role is scoped to
  //         this endpoint's env, used ONLY for the auth-admin op. ----
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SECRET_KEY;
  const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!supabaseUrl || !serviceKey || !publishableKey) {
    console.error("recover: SUPABASE_URL / SUPABASE_SECRET_KEY / SUPABASE_PUBLISHABLE_KEY not configured");
    return errorResponse(502, "config_error");
  }
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const { data: listData, error: listErr } = await admin.auth.admin.mfa.listFactors({
    userId: user.userId,
  });
  if (listErr) {
    console.error("recover: listFactors error:", listErr);
    return errorResponse(502, "upstream_error");
  }

  // Delete ALL the user's factors (the verified TOTP triggers the session revocation;
  // unverified ones are cleaned for a full reset). Idempotent if there are none. A failure
  // here returns 502 with the recovery code STILL UNUSED (not marked) → clean retry.
  for (const factor of listData?.factors ?? []) {
    const { error: delErr } = await admin.auth.admin.mfa.deleteFactor({
      id: factor.id,
      userId: user.userId,
    });
    if (delErr) {
      console.error("recover: deleteFactor error:", delErr);
      return errorResponse(502, "upstream_error");
    }
  }

  // ---- 3. REVOKE all of the user's sessions. deleteFactor's documented "logs out all sessions"
  //         does NOT fire on this project (curl-verified: device-A's refresh survived a factor
  //         delete), so we revoke EXPLICITLY via the supported GoTrue global-logout (the user
  //         logging themselves out everywhere). This is the security-critical step that makes
  //         recovery invalidate stale aal2 sessions on other devices. Fail -> 502 with the code
  //         STILL UNUSED (not yet marked) -> clean retry. ----
  const logoutRes = await fetch(`${supabaseUrl}/auth/v1/logout?scope=global`, {
    method: "POST",
    headers: { apikey: publishableKey, Authorization: `Bearer ${user.jwt}` },
  });
  if (!logoutRes.ok) {
    console.error("recover: global logout failed:", logoutRes.status);
    return errorResponse(502, "upstream_error");
  }

  // ---- 4. ONLY after BOTH the factor delete AND the session revocation succeeded: mark the code
  //         used. BEST-EFFORT — the user is already recovered, so a mark hiccup leaves inert
  //         residue (an unused code whose factor is gone), never failing a completed recovery.
  //         The access JWT stays signature/exp-valid for this call despite the global logout
  //         (revocation invalidates refresh tokens, not the outstanding stateless access token). ----
  const { error: markErr } = await authed.rpc("mark_recovery_code_used", { p_id: codeId });
  if (markErr) {
    console.error("recover: mark_recovery_code_used failed (recovery already stands):", markErr);
  }

  return jsonResponse(200, { recovered: true });
}
