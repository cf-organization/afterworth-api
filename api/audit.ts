/**
 * POST /api/audit — the client audit-forward pipe.
 *
 * iOS (AuditForwardingService) POSTs a ForwardedAuditEvent (its sanitized wire envelope); this endpoint
 * ADAPTS that shape to the forward_client_audit DEFINER RPC — the ONLY client-reachable audit write path
 * (write_audit's direct EXECUTE was revoked from authenticated in migration 0011).
 *
 * THE RPC IS THE REAL GATE: allowlist (client-only vocabulary; server-reserved actions reject), metadata
 * size cap, actor_id = auth.uid(), source = 'ios_forward', server ip/ua. A DIRECT PostgREST caller hits
 * the same gates — this endpoint is only the OUTER adapter/layer (auth taxonomy, rate limit, cheap 400s,
 * wire->RPC mapping, 202).
 *
 * Wire (ForwardedAuditEvent): { id, timestamp, category, action, outcome, actorId, estateId, context:{…} }.
 *   -> RPC: p_action=action, p_estate=estateId, p_meta={category, outcome, event_id:id, ...non-null context},
 *      p_client_ts=timestamp, p_table/p_target=null. actorId is IGNORED (the RPC derives actor from the JWT).
 *
 * Best-effort by design: the iOS side fires-and-forgets, so a failed forward never blocks a user action.
 * 202 forwarded. 400 bad body / disallowed action / oversize. 401 auth. 403 RPC-unauth. 405 method. 429 rate.
 */

import { enforce } from "../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../lib/auth.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

export async function POST(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  // Tier-2 (fail-open, dry-run) — telemetry must not be gated by a limiter outage. Registry row must exist
  // (lib/rateLimit.ts) or an unknown bucket fails closed -> 429 from request one.
  const rateLimitResponse = await enforce(req, "audit_forward");
  if (rateLimitResponse) {
    return rateLimitResponse;
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

  // Cheap OUTER 400 — the RPC re-validates the action against the allowlist authoritatively.
  const action = typeof o.action === "string" ? o.action.trim() : "";
  if (action.length === 0) {
    return errorResponse(400, "invalid_request");
  }
  const estateId = typeof o.estateId === "string" && UUID_RE.test(o.estateId) ? o.estateId.toLowerCase() : null;
  const clientTs = typeof o.timestamp === "string" ? o.timestamp : null;

  // Adapt the ForwardedAuditEvent envelope -> a flat metadata object. actorId is DROPPED (server-derived);
  // category/outcome/event_id + the non-null bounded context fields fold into metadata (all leak-safe by
  // the iOS ForwardedAuditContext bounding). No client-settable source/ip/ua/actor here.
  const metadata: Record<string, unknown> = {};
  if (typeof o.category === "string") metadata.category = o.category;
  if (typeof o.outcome === "string") metadata.outcome = o.outcome;
  if (typeof o.id === "string") metadata.event_id = o.id;
  if (o.context && typeof o.context === "object") {
    for (const [k, v] of Object.entries(o.context as Record<string, unknown>)) {
      if (v !== null && v !== undefined) metadata[k] = v;
    }
  }
  if (JSON.stringify(metadata).length > 4096) {
    return errorResponse(400, "metadata_too_large");
  }

  const supabase = getAuthedSupabaseClient(user.jwt);
  const { error } = await supabase.rpc("forward_client_audit", {
    p_action: action,
    p_estate: estateId,
    p_table: null,
    p_target: null,
    p_meta: metadata,
    p_client_ts: clientTs,
  });
  if (error) {
    // P0001 = the RPC's own gate (disallowed action / oversize) -> 400. 42501 = anon at RPC -> 403.
    if (error.code === "P0001") return errorResponse(400, "audit_rejected");
    if (error.code === "42501") return errorResponse(403, "forbidden");
    console.error("forward_client_audit error:", error.code, error.message);
    return errorResponse(502, "upstream_error");
  }
  return jsonResponse(202, { forwarded: true });
}
