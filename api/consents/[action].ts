/**
 * POST /api/consents/[action]   where action ∈ {record, list}
 *
 * The acknowledgment-class consent transport (Slice C2). iOS (LiveConsentService) records + reads durable,
 * versioned, append-only consent. One dynamic route (Vercel Hobby 12-fn cap), mirroring
 * vault/grants/[action].ts. The RPC/RLS are the security boundary; this forwards the caller's JWT
 * (auth.uid() = the caller) — a direct PostgREST caller hits the same gates.
 *
 * SCOPE = acknowledgment consent ONLY (tax disclaimer / ToS / privacy / data-sharing / beneficiary-disclosure
 * / platform-disclosure). Attestation-grade consent is a stricter class deferred to C4 — NOT this endpoint.
 *
 * Bodies:
 *   record  { consentType, documentVersion }  -> { id }          (record_consent DEFINER; server-stamps
 *                                                                  user_id=auth.uid() + accepted_at)
 *   list    { consentType? }                  -> { consents: [] } (RLS-scoped own read; optional type filter)
 *
 * Errors (RPC SQLSTATE -> HTTP): 42501->403 (auth at RPC), P0001->400 (version_required), 23514->400
 *   (bad consent_type CHECK), else 502. 401 auth, 400 bad body, 404 unknown action, 405 method, 429 rate.
 */

import { enforce } from "../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../lib/auth.js";

const ACTIONS = new Set(["record", "list"]);
// Mirror of the consent_records.consent_type CHECK (the acknowledgment vocabulary). The RPC/CHECK is
// authoritative; this is a cheap OUTER 400 so a typo never reaches the DB.
const CONSENT_TYPES = new Set([
  "terms_of_service", "privacy_policy", "data_sharing",
  "beneficiary_disclosure", "tax_disclaimer", "platform_disclosure",
]);

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
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

  const rateLimitResponse = await enforce(req, `consents_${action}`);
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  if (action === "record") {
    const consentType = typeof o.consentType === "string" ? o.consentType.trim() : "";
    const documentVersion = typeof o.documentVersion === "string" ? o.documentVersion.trim() : "";
    if (!CONSENT_TYPES.has(consentType) || documentVersion.length === 0) {
      return errorResponse(400, "invalid_request");
    }
    const { data, error } = await supabase.rpc("record_consent", {
      p_type: consentType,
      p_version: documentVersion,
    });
    if (error) {
      if (error.code === "P0001") return errorResponse(400, "invalid_request");   // version_required
      if (error.code === "23514") return errorResponse(400, "invalid_request");   // consent_type CHECK
      if (error.code === "42501") return errorResponse(403, "forbidden");
      console.error("record_consent error:", error.code, error.message);
      return errorResponse(502, "upstream_error");
    }
    return jsonResponse(201, { id: data });
  }

  // action === "list" — RLS-scoped own read (optional consentType filter).
  const filterType = typeof o.consentType === "string" ? o.consentType.trim() : null;
  if (filterType !== null && !CONSENT_TYPES.has(filterType)) {
    return errorResponse(400, "invalid_request");
  }
  let query = supabase
    .from("consent_records")
    .select("id, consent_type, document_version, accepted_at")
    .order("accepted_at", { ascending: false });
  if (filterType !== null) {
    query = query.eq("consent_type", filterType);
  }
  const { data, error } = await query;
  if (error) {
    console.error("consents list error:", error.code, error.message);
    return errorResponse(502, "upstream_error");
  }
  const consents = (data ?? []).map((r) => ({
    id: r.id,
    consentType: r.consent_type,
    documentVersion: r.document_version,
    acceptedAt: r.accepted_at,
  }));
  return jsonResponse(200, { consents });
}
