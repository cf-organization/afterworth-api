/**
 * POST /api/vault/grants/approve
 *
 * Owner-only: approve a pending access grant by id (activates after_owner_approval grants).
 * Thin wrapper over the SECURITY DEFINER rpc `approve_document_grant` (owner-gated,
 * idempotent, audited; the enforce_grant_ceiling trigger re-checks the ceiling on the
 * approve UPDATE). Forwards the caller's JWT; passes the RPC's status + message through.
 *
 * Request:  Authorization: Bearer <JWT>; body { grantId }
 * Response (200): { grant: GrantWire }  (the approved row)
 * Errors (RPC SQLSTATE -> HTTP, message passed through):
 *   42501 -> 403 (not owner / ceiling violation)   P0001 -> 400 (grant_not_found)   else -> 502
 *   401 auth, 400 bad body, 405 method.
 */

import { enforce } from "../../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../../lib/auth.js";
import { type GrantRow, toGrantWire, grantRpcErrorResponse } from "../../../lib/grants.js";

interface ApproveGrantBody {
  grantId: string;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

function parseBody(raw: unknown): ApproveGrantBody | null {
  if (raw === null || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const grantId = typeof o.grantId === "string" ? o.grantId.trim() : "";
  if (!UUID_RE.test(grantId)) return null;
  return { grantId };
}

export async function POST(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  let user;
  try {
    user = await verifyJwt(req);
  } catch (err) {
    if (err instanceof AuthError) return authErrorResponse(err);
    console.error("Unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  let body: ApproveGrantBody | null;
  try {
    body = parseBody(await req.json());
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "vault_grants_approve");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);
  const { data, error } = await supabase.rpc("approve_document_grant", {
    p_grant_id: body.grantId,
  });

  if (error) {
    const mapped = grantRpcErrorResponse(error.code, error.message);
    if (mapped) {
      console.error("approve_document_grant raised:", error.code, error.message);
      return mapped;
    }
    console.error("Supabase RPC error (unmapped):", error);
    return errorResponse(502, "upstream_error");
  }

  if (!Array.isArray(data) || data.length === 0) {
    console.error("approve_document_grant returned unexpected shape:", data);
    return errorResponse(502, "upstream_unexpected_shape");
  }

  return jsonResponse(200, { grant: toGrantWire(data[0] as GrantRow) });
}
