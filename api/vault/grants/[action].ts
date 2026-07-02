/**
 * POST /api/vault/grants/[action]   where action ∈ {create, create_asset, revoke, approve, list, list_asset, update_asset, update_document}
 *
 * ONE serverless function serving all four document-grant routes — consolidated to fit the
 * Vercel Hobby 12-function-per-deployment cap (matches the access-requests/[action].ts
 * pattern already in prod). The public URLs are UNCHANGED
 * (/api/vault/grants/{create,revoke,approve,list}); only the packaging is a single dynamic
 * route, so the iOS caller (LiveDocumentGrantService) needs NO change. Each mutating action
 * is a thin wrapper over its owner-gated SECURITY DEFINER RPC; `list` is a plain RLS-scoped
 * select. The RPCs/RLS are the security boundary; this forwards the caller's JWT
 * (auth.uid() = the caller) and passes the RPC's status + message through. See
 * db/functions/ + docs/live-data-migration.md Appendix A.2.
 *
 * Bodies:
 *   create      { estateId, granteeUserId, granteeRole, documentId, visibilityTier,
 *                 releaseCondition, professionalType?, requiresStepUp? }   -> { grant }
 *   create_asset{ estateId, granteeUserId, granteeRole, category, visibilityTier,
 *                 releaseCondition, professionalType?, requiresStepUp? }   -> { grant }  (category-scoped)
 *   revoke      { grantId }                                               -> { grant }
 *   approve     { grantId }                                               -> { grant }
 *   list        { estateId, documentId }                                  -> { grants: [] }  (RLS-scoped, doc grants, active)
 *   list_asset  { estateId, granteeUserId }                               -> { grants: [] }  (RLS-scoped, category grants, active)
 *   update_asset    { grantId, visibilityTier }                          -> { grant }  (in-place tier edit, category)
 *   update_document { grantId, visibilityTier }                          -> { grant }  (in-place tier edit, document)
 * Errors (RPC SQLSTATE -> HTTP, message passed through): 42501->403, 23505->409, P0001->400,
 *   else 502. 401 auth, 400 bad body, 404 unknown action, 405 method.
 */

import { enforce } from "../../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../../lib/auth.js";
import type { PostgrestError } from "@supabase/supabase-js";
import { type GrantRow, toGrantWire, grantRpcErrorResponse } from "../../../lib/grants.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACTIONS = new Set(["create", "create_asset", "revoke", "approve", "list", "list_asset", "update_asset", "update_document"]);
const ROLES = new Set(["beneficiary", "professional_delegate"]);
const TIERS = new Set([
  "hidden", "range_only", "category_summary", "limited_detail", "full_detail",
]);
// B2b: the asset-disclosure category grants (category-scoped, no document_id). Mirrors the
// access_grants.category CHECK for assets; create_asset_grant enforces the write-time ceiling.
const ASSET_CATEGORIES = new Set([
  "account_balances", "institution_names", "total_asset_value", "linked_account_details",
]);
const GRANT_COLUMNS =
  "id, estate_id, grantee_user_id, grantee_role, professional_type, document_id, " +
  "category, visibility_tier, release_condition, requires_step_up, status, " +
  "granted_by_user_id, created_at, updated_at, revoked_at, revoked_by_user_id, " +
  "approved_at, approved_by_user_id";

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

// Shape a single-row grant RPC result (data/error) into the wire response: error -> mapped
// HTTP (or 502), success -> { grant: GrantWire }. Identical behavior to the former
// create/revoke/approve endpoints.
function grantRpcResult(
  data: unknown,
  error: PostgrestError | null,
  fn: string,
): Response {
  if (error) {
    const mapped = grantRpcErrorResponse(error.code, error.message);
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
  return jsonResponse(200, { grant: toGrantWire(data[0] as GrantRow) });
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

  const rateLimitResponse = await enforce(req, `vault_grants_${action}`);
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  // ----- list: plain RLS-scoped select (owner sees all; grantee sees own), active only -----
  if (action === "list") {
    const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
    const documentId = typeof o.documentId === "string" ? o.documentId.trim() : "";
    if (![estateId, documentId].every((v) => UUID_RE.test(v))) {
      return errorResponse(400, "invalid_request");
    }

    const { data, error } = await supabase
      .from("access_grants")
      .select(GRANT_COLUMNS)
      .eq("estate_id", estateId)
      .eq("document_id", documentId)
      .eq("status", "active")
      .order("created_at", { ascending: false });

    if (error) {
      console.error("access_grants list error:", error);
      return errorResponse(502, "upstream_error");
    }
    // supabase-js can't infer a row type from a non-literal select string, so it widens to
    // GenericStringError[]; cast through unknown to the real row shape.
    const grants = ((data ?? []) as unknown as GrantRow[]).map(toGrantWire);
    return jsonResponse(200, { grants });
  }

  // ----- list_asset: RLS-scoped select of a grantee's ACTIVE category (asset) grants -----
  //   { estateId, granteeUserId } -> { grants: [] }. The asset counterpart of `list`: category
  //   grants have document_id NULL (never a document row), so this filters document_id IS NULL
  //   rather than by a documentId. Same RLS boundary as `list` and curl-proven on the live table:
  //   the owner sees the grantee's grants; a grantee sees only their own; a non-owner non-grantee
  //   member (e.g. a professional_delegate) sees NONE — the policy keys on ownership/grantee, not
  //   estate membership. Returns ALL asset categories; the iOS first cut manages account_balances
  //   only (the tier that gates the beneficiary asset view).
  if (action === "list_asset") {
    const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
    const granteeUserId = typeof o.granteeUserId === "string" ? o.granteeUserId.trim() : "";
    if (![estateId, granteeUserId].every((v) => UUID_RE.test(v))) {
      return errorResponse(400, "invalid_request");
    }

    const { data, error } = await supabase
      .from("access_grants")
      .select(GRANT_COLUMNS)
      .eq("estate_id", estateId)
      .eq("grantee_user_id", granteeUserId)
      .is("document_id", null)
      .eq("status", "active")
      .order("created_at", { ascending: false });

    if (error) {
      console.error("access_grants list_asset error:", error);
      return errorResponse(502, "upstream_error");
    }
    const grants = ((data ?? []) as unknown as GrantRow[]).map(toGrantWire);
    return jsonResponse(200, { grants });
  }

  // ----- create: owner-gated, ceiling-enforced RPC -----
  if (action === "create") {
    const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
    const granteeUserId = typeof o.granteeUserId === "string" ? o.granteeUserId.trim() : "";
    const documentId = typeof o.documentId === "string" ? o.documentId.trim() : "";
    const granteeRole = typeof o.granteeRole === "string" ? o.granteeRole : "";
    const visibilityTier = typeof o.visibilityTier === "string" ? o.visibilityTier : "";
    const releaseCondition = typeof o.releaseCondition === "string" ? o.releaseCondition : "";
    if (![estateId, granteeUserId, documentId].every((v) => UUID_RE.test(v))) {
      return errorResponse(400, "invalid_request");
    }
    if (!ROLES.has(granteeRole)) return errorResponse(400, "invalid_request");
    if (!TIERS.has(visibilityTier)) return errorResponse(400, "invalid_request");
    if (releaseCondition.length === 0) return errorResponse(400, "invalid_request");
    const professionalType = typeof o.professionalType === "string" ? o.professionalType : null;
    const requiresStepUp = typeof o.requiresStepUp === "boolean" ? o.requiresStepUp : false;

    const { data, error } = await supabase.rpc("create_document_grant", {
      p_estate_id: estateId,
      p_grantee_user_id: granteeUserId,
      p_grantee_role: granteeRole,
      p_document_id: documentId,
      p_visibility_tier: visibilityTier,
      p_release_condition: releaseCondition,
      p_professional_type: professionalType,
      p_requires_step_up: requiresStepUp,
    });
    return grantRpcResult(data, error, "create_document_grant");
  }

  // ----- create_asset: owner-gated, WRITE-TIME-ceiling-enforced asset-category grant (B2b) -----
  if (action === "create_asset") {
    const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
    const granteeUserId = typeof o.granteeUserId === "string" ? o.granteeUserId.trim() : "";
    const category = typeof o.category === "string" ? o.category : "";
    const granteeRole = typeof o.granteeRole === "string" ? o.granteeRole : "";
    const visibilityTier = typeof o.visibilityTier === "string" ? o.visibilityTier : "";
    const releaseCondition = typeof o.releaseCondition === "string" ? o.releaseCondition : "";
    if (![estateId, granteeUserId].every((v) => UUID_RE.test(v))) {
      return errorResponse(400, "invalid_request");
    }
    if (!ASSET_CATEGORIES.has(category)) return errorResponse(400, "invalid_request");
    if (!ROLES.has(granteeRole)) return errorResponse(400, "invalid_request");
    if (!TIERS.has(visibilityTier)) return errorResponse(400, "invalid_request");
    if (releaseCondition.length === 0) return errorResponse(400, "invalid_request");
    const professionalType = typeof o.professionalType === "string" ? o.professionalType : null;
    const requiresStepUp = typeof o.requiresStepUp === "boolean" ? o.requiresStepUp : false;

    const { data, error } = await supabase.rpc("create_asset_grant", {
      p_estate_id: estateId,
      p_grantee_user_id: granteeUserId,
      p_grantee_role: granteeRole,
      p_category: category,
      p_visibility_tier: visibilityTier,
      p_release_condition: releaseCondition,
      p_professional_type: professionalType,
      p_requires_step_up: requiresStepUp,
    });
    return grantRpcResult(data, error, "create_asset_grant");
  }

  // ----- revoke: owner-gated RPC -----
  if (action === "revoke") {
    const grantId = typeof o.grantId === "string" ? o.grantId.trim() : "";
    if (!UUID_RE.test(grantId)) return errorResponse(400, "invalid_request");

    const { data, error } = await supabase.rpc("revoke_document_grant", {
      p_grant_id: grantId,
    });
    return grantRpcResult(data, error, "revoke_document_grant");
  }

  // ----- update_asset / update_document: in-place tier edit (replaces revoke+recreate) -----
  //   { grantId, visibilityTier } -> { grant }. Both re-enforce the ceiling on the NEW tier:
  //   update_asset_grant explicitly (asset_category_grantable — the trigger skips category grants);
  //   update_document_grant via the enforce_grant_ceiling trigger (BEFORE UPDATE). TIERS is validated
  //   here because the document trigger doesn't police the tier value.
  if (action === "update_asset" || action === "update_document") {
    const grantId = typeof o.grantId === "string" ? o.grantId.trim() : "";
    const visibilityTier = typeof o.visibilityTier === "string" ? o.visibilityTier : "";
    if (!UUID_RE.test(grantId)) return errorResponse(400, "invalid_request");
    if (!TIERS.has(visibilityTier)) return errorResponse(400, "invalid_request");

    const fn = action === "update_asset" ? "update_asset_grant" : "update_document_grant";
    const { data, error } = await supabase.rpc(fn, {
      p_grant_id: grantId,
      p_visibility_tier: visibilityTier,
    });
    return grantRpcResult(data, error, fn);
  }

  // ----- approve: owner-gated RPC (activates after_owner_approval grants) -----
  const grantId = typeof o.grantId === "string" ? o.grantId.trim() : "";
  if (!UUID_RE.test(grantId)) return errorResponse(400, "invalid_request");

  const { data, error } = await supabase.rpc("approve_document_grant", {
    p_grant_id: grantId,
  });
  return grantRpcResult(data, error, "approve_document_grant");
}
