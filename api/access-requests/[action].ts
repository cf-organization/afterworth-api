/**
 * POST /api/access-requests/[action]   where action ∈ {create, list, approve, deny}
 *
 * ONE serverless function serving all four access-request routes — consolidated to fit the
 * Vercel Hobby 12-function-per-deployment cap. The public URLs are UNCHANGED
 * (/api/access-requests/{create,list,approve,deny}); only the packaging is a single dynamic
 * route. Each action is a thin wrapper over its SECURITY DEFINER RPC (create member-gated;
 * approve / deny owner-gated) except `list`, a plain RLS-scoped select. The RPCs are the
 * security boundary; this forwards the caller's JWT (auth.uid() = the caller) and passes the
 * RPC's status + message through. See db/functions/ + docs/live-data-migration.md A.4.
 *
 * Bodies:
 *   create  { estateId, category?, reason? }      -> { request }
 *   list    { estateId }                          -> { requests: [] }   (RLS-scoped)
 *   approve { requestId, visibilityTier? }        -> { request }
 *   deny    { requestId }                         -> { request }
 * Errors (RPC SQLSTATE -> HTTP, message passed through): 42501->403, 23505->409, P0001->400,
 *   else 502. 401 auth, 400 bad body, 404 unknown action, 405 method.
 */

import { enforce } from "../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../lib/auth.js";
import type { PostgrestError } from "@supabase/supabase-js";
import {
  type AccessRequestRow,
  toAccessRequestWire,
  accessRequestRpcErrorResponse,
} from "../../lib/accessRequests.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CATEGORIES = new Set(["estate_documents"]);
const TIERS = new Set(["full_detail", "limited_detail"]);
const ACTIONS = new Set(["create", "list", "approve", "deny"]);
const REQUEST_COLUMNS =
  "id, estate_id, requester_user_id, category, reason, status, " +
  "created_at, resolved_at, resolved_by_user_id, resulting_grant_id";

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

// Resolve the {action} segment from the request URL (robust to absolute URL or bare path,
// query strings, and trailing slashes).
function actionFromUrl(rawUrl: string): string {
  let path = rawUrl;
  try {
    path = new URL(rawUrl).pathname;
  } catch {
    /* rawUrl may already be a path */
  }
  path = path.replace(/[?#].*$/, "").replace(/\/+$/, "");
  return path.slice(path.lastIndexOf("/") + 1);
}

// Shape the RPC result (data/error) into the wire response: error -> mapped HTTP (or 502),
// success -> { request: AccessRequestWire }.
function rpcResult(
  data: unknown,
  error: PostgrestError | null,
  fn: string,
): Response {
  if (error) {
    const mapped = accessRequestRpcErrorResponse(error.code, error.message);
    if (mapped) {
      console.error(`${fn} raised:`, error.code, error.message);
      return mapped;
    }
    console.error("Supabase RPC error (unmapped):", error);
    return errorResponse(502, "upstream_error");
  }
  if (!Array.isArray(data) || data.length === 0) {
    console.error(`${fn} returned unexpected shape:`, data);
    return errorResponse(502, "upstream_unexpected_shape");
  }
  return jsonResponse(200, { request: toAccessRequestWire(data[0] as AccessRequestRow) });
}

export async function POST(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  const action = actionFromUrl(req.url);
  if (!ACTIONS.has(action)) {
    return errorResponse(404, "not_found");
  }

  let user;
  try {
    user = await verifyJwt(req);
  } catch (err) {
    if (err instanceof AuthError) return authErrorResponse(err);
    console.error("Unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (raw === null || typeof raw !== "object") {
    return errorResponse(400, "invalid_request");
  }
  const o = raw as Record<string, unknown>;

  const rateLimitResponse = await enforce(req, `access_requests_${action}`);
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  // ----- list: plain RLS-scoped select (owner sees all; requester sees own) -----
  if (action === "list") {
    const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
    if (!UUID_RE.test(estateId)) return errorResponse(400, "invalid_request");

    const { data, error } = await supabase
      .from("access_requests")
      .select(REQUEST_COLUMNS)
      .eq("estate_id", estateId)
      .order("created_at", { ascending: false });

    if (error) {
      console.error("access_requests list error:", error);
      return errorResponse(502, "upstream_error");
    }
    const requests = ((data ?? []) as unknown as AccessRequestRow[]).map(toAccessRequestWire);
    return jsonResponse(200, { requests });
  }

  // ----- create: member-gated RPC; requester_user_id STAMPED server-side -----
  if (action === "create") {
    const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
    if (!UUID_RE.test(estateId)) return errorResponse(400, "invalid_request");
    const category =
      typeof o.category === "string" && o.category.length > 0 ? o.category : "estate_documents";
    if (!CATEGORIES.has(category)) return errorResponse(400, "invalid_request");
    const reason = typeof o.reason === "string" ? o.reason : null;

    const { data, error } = await supabase.rpc("create_access_request", {
      p_estate_id: estateId,
      p_category: category,
      p_reason: reason,
    });
    return rpcResult(data, error, "create_access_request");
  }

  // ----- approve: owner-gated RPC; atomic grant + request update -----
  if (action === "approve") {
    const requestId = typeof o.requestId === "string" ? o.requestId.trim() : "";
    if (!UUID_RE.test(requestId)) return errorResponse(400, "invalid_request");
    const visibilityTier =
      typeof o.visibilityTier === "string" && o.visibilityTier.length > 0
        ? o.visibilityTier
        : "limited_detail";
    if (!TIERS.has(visibilityTier)) return errorResponse(400, "invalid_request");

    const { data, error } = await supabase.rpc("approve_access_request", {
      p_request_id: requestId,
      p_visibility_tier: visibilityTier,
    });
    return rpcResult(data, error, "approve_access_request");
  }

  // ----- deny: owner-gated RPC -----
  const requestId = typeof o.requestId === "string" ? o.requestId.trim() : "";
  if (!UUID_RE.test(requestId)) return errorResponse(400, "invalid_request");

  const { data, error } = await supabase.rpc("deny_access_request", {
    p_request_id: requestId,
  });
  return rpcResult(data, error, "deny_access_request");
}
