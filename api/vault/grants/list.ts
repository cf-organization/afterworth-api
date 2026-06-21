/**
 * POST /api/vault/grants/list
 *
 * List the ACTIVE access grants for one document (owner-facing manage-access UI).
 * RLS on access_grants scopes the rows: the estate owner sees all grants for the
 * document; a grantee sees only their own. This is a plain select (no RPC) — the
 * grant model's read boundary is RLS (db/migrations/0002 access_grants_read).
 *
 * V1: status='active' only — a revoked grant drops off the list (the "access removed"
 * feedback). Revoked history would be a separate future read.
 *
 * Request:  Authorization: Bearer <JWT>; body { estateId, documentId }
 * Response (200): { grants: GrantWire[] }
 * Errors: 401 auth, 400 bad body, 405 method, 502 upstream.
 */

import { enforce } from "../../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../../lib/auth.js";
import { type GrantRow, toGrantWire } from "../../../lib/grants.js";

interface ListGrantsBody {
  estateId: string;
  documentId: string;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const GRANT_COLUMNS =
  "id, estate_id, grantee_user_id, grantee_role, professional_type, document_id, " +
  "category, visibility_tier, release_condition, requires_step_up, status, " +
  "granted_by_user_id, created_at, updated_at, revoked_at, revoked_by_user_id";

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

function parseBody(raw: unknown): ListGrantsBody | null {
  if (raw === null || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
  const documentId = typeof o.documentId === "string" ? o.documentId.trim() : "";
  if (![estateId, documentId].every((v) => UUID_RE.test(v))) return null;
  return { estateId, documentId };
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

  let body: ListGrantsBody | null;
  try {
    body = parseBody(await req.json());
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "vault_grants_list");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);
  const { data, error } = await supabase
    .from("access_grants")
    .select(GRANT_COLUMNS)
    .eq("estate_id", body.estateId)
    .eq("document_id", body.documentId)
    .eq("status", "active")
    .order("created_at", { ascending: false });

  if (error) {
    console.error("access_grants list error:", error);
    return errorResponse(502, "upstream_error");
  }

  // supabase-js can't infer a row type from a non-literal select string, so it widens
  // to GenericStringError[]; cast through unknown to the real row shape.
  const grants = ((data ?? []) as unknown as GrantRow[]).map(toGrantWire);
  return jsonResponse(200, { grants });
}
