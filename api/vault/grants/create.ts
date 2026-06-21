/**
 * POST /api/vault/grants/create
 *
 * Owner-only: create a per-document access grant. Thin wrapper over the SECURITY
 * DEFINER rpc `create_document_grant` (owner-gated, ceiling-enforced, audited — see
 * afterworth-api db/functions/ + docs/live-data-migration.md Appendix A.2). The RPC is
 * the security boundary; this endpoint forwards the caller's JWT (so auth.uid() is the
 * caller) and passes the RPC's status + message through.
 *
 * Request:  Authorization: Bearer <JWT>; body {
 *   estateId, granteeUserId, granteeRole, documentId, visibilityTier,
 *   releaseCondition, professionalType?, requiresStepUp? }
 * Response (200): { grant: GrantWire }
 * Errors (RPC SQLSTATE -> HTTP, message passed through):
 *   42501 -> 403 (not owner / ceiling)   23505 -> 409 (duplicate)
 *   P0001 -> 400 (owner-grant / document-not-found)   else -> 502
 *   401 auth, 400 bad body, 405 method.
 */

import { enforce } from "../../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../../lib/auth.js";
import { type GrantRow, toGrantWire, grantRpcErrorResponse } from "../../../lib/grants.js";

interface CreateGrantBody {
  estateId: string;
  granteeUserId: string;
  granteeRole: string;
  documentId: string;
  visibilityTier: string;
  releaseCondition: string;
  professionalType: string | null;
  requiresStepUp: boolean;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ROLES = new Set(["beneficiary", "professional_delegate"]);
const TIERS = new Set([
  "hidden", "range_only", "category_summary", "limited_detail", "full_detail",
]);

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

function parseBody(raw: unknown): CreateGrantBody | null {
  if (raw === null || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
  const granteeUserId = typeof o.granteeUserId === "string" ? o.granteeUserId.trim() : "";
  const documentId = typeof o.documentId === "string" ? o.documentId.trim() : "";
  const granteeRole = typeof o.granteeRole === "string" ? o.granteeRole : "";
  const visibilityTier = typeof o.visibilityTier === "string" ? o.visibilityTier : "";
  const releaseCondition = typeof o.releaseCondition === "string" ? o.releaseCondition : "";
  if (![estateId, granteeUserId, documentId].every((v) => UUID_RE.test(v))) return null;
  if (!ROLES.has(granteeRole)) return null;
  if (!TIERS.has(visibilityTier)) return null;
  if (releaseCondition.length === 0) return null;
  const professionalType = typeof o.professionalType === "string" ? o.professionalType : null;
  const requiresStepUp = typeof o.requiresStepUp === "boolean" ? o.requiresStepUp : false;
  return {
    estateId, granteeUserId, granteeRole, documentId,
    visibilityTier, releaseCondition, professionalType, requiresStepUp,
  };
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

  let body: CreateGrantBody | null;
  try {
    body = parseBody(await req.json());
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "vault_grants_create");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);
  const { data, error } = await supabase.rpc("create_document_grant", {
    p_estate_id: body.estateId,
    p_grantee_user_id: body.granteeUserId,
    p_grantee_role: body.granteeRole,
    p_document_id: body.documentId,
    p_visibility_tier: body.visibilityTier,
    p_release_condition: body.releaseCondition,
    p_professional_type: body.professionalType,
    p_requires_step_up: body.requiresStepUp,
  });

  if (error) {
    const mapped = grantRpcErrorResponse(error.code, error.message);
    if (mapped) {
      console.error("create_document_grant raised:", error.code, error.message);
      return mapped;
    }
    console.error("Supabase RPC error (unmapped):", error);
    return errorResponse(502, "upstream_error");
  }

  if (!Array.isArray(data) || data.length === 0) {
    console.error("create_document_grant returned unexpected shape:", data);
    return errorResponse(502, "upstream_unexpected_shape");
  }

  return jsonResponse(200, { grant: toGrantWire(data[0] as GrantRow) });
}
