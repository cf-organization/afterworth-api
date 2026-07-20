/**
 * POST /api/claims/[action]   where action ∈ {view_evidence}
 *
 * Slice C1.6b — the admin evidence-serving door for the operator console's claims-review surface. Serves the
 * BYTES of a death-claim's evidence documents (death certificate / executor ID) to an authenticated ADMIN,
 * PROXIED (never a signed URL) so nothing bearer-shaped leaks. The console reaches this only via its OWN
 * same-origin BFF route (afterworth-admin app/api/claim-evidence) — so the console CSP stays connect-src 'self'.
 *
 * This is the LAST Vercel Hobby function slot (12/12). It's a DISPATCHER (claims/[action].ts) so any future
 * claims-domain service-role op rides it rather than taking a slot that no longer exists. NEXT new endpoint
 * anyone needs -> consolidate first (candidate: fold vault/members.ts into a vault/documents/[action].ts) or
 * move to Vercel Pro. (The DECIDE action needs no endpoint — it's the admin_decide_claim_packet RPC direct.)
 *
 * TWO LAYERS:
 *   1. GATE + RESOLVE (security boundary) = admin_authorize_claim_evidence RPC, called with the admin's JWT.
 *      It runs the full admin gate (auth -> is_admin -> aal2 -> 15-min freshness) INSIDE the function and
 *      resolves the storage_path FROM THE NAMED CLAIM ONLY (the client sends {claimId, slot}, never a path or
 *      document_id -> arbitrary-document read is unrepresentable). It also writes the claim.evidence_viewed
 *      audit. A direct rest/v1/rpc/... caller hits the identical gate; this endpoint buys no privilege.
 *   2. STREAM (mechanics only) = a service-role storage download of the resolved path (the recover.ts
 *      service-role pattern, confined here), STREAMED back via blob.stream() — NOT buffered. Streaming bypasses
 *      Vercel's 4.5 MB *buffered* response cap (proven, not doc-trusted), so evidence up to the upload_policy
 *      limit (25 MB) is viewable. The size guard is now DEFENSIVE and POLICY-SOURCED (max_upload_bytes from the
 *      admin_authorize RPC), never a hardcoded number. Service role reads an ALREADY-AUTHORIZED path only.
 *
 * Request:  Authorization: Bearer <admin aal2 JWT>; body { claimId: uuid, slot: 'death_cert'|'executor_id' }
 * Response (200): the raw PDF bytes, STREAMED (Content-Type from the documents row; no-store; nosniff; inline).
 * Errors (RPC SQLSTATE -> HTTP): 42501->403 (admin gate), P0001->400 (invalid_slot), P0002->404
 *   (claim_not_found / evidence_not_found), else 502. 401 auth, 400 bad body, 404 unknown action, 405 method,
 *   413 object too large, 429 rate, 502 config/storage.
 */

import { createClient } from "@supabase/supabase-js";
import { enforce } from "../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../lib/auth.js";

const ACTIONS = new Set(["view_evidence"]);
const SLOTS = new Set(["death_cert", "executor_id"]);
const DOCUMENTS_BUCKET = "documents";
const FALLBACK_MAX_BYTES = 25 * 1024 * 1024; // only if the admin_authorize RPC omits max_upload_bytes.
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
  const claimId = typeof o.claimId === "string" ? o.claimId.trim() : "";
  const slot = typeof o.slot === "string" ? o.slot.trim() : "";
  // The ONLY inputs are a claim id + a fixed slot enum — no path/document_id can be injected.
  if (!UUID_RE.test(claimId) || !SLOTS.has(slot)) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "claims_view_evidence");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  // ---- 1. GATE + RESOLVE: run as the admin. The RPC enforces the full admin gate and resolves the path
  //         from THIS claim only, and writes the claim.evidence_viewed audit. ----
  const authed = getAuthedSupabaseClient(user.jwt);
  const { data, error } = await authed.rpc("admin_authorize_claim_evidence", {
    p_claim: claimId,
    p_slot: slot,
  });
  if (error) {
    // Surface the SPECIFIC admin-gate sentinel (not a generic 'forbidden') so the console can silent-refresh
    // on a stale token and retry — mirroring the rpc() client. auth/admin/mfa are terminal (re-auth/step-up).
    if (error.code === "42501") {
      const msg = error.message ?? "";
      const sentinel = msg.includes("stale_token_reauth_required") ? "stale_token_reauth_required"
        : msg.includes("mfa_required") ? "mfa_required"
        : msg.includes("admin_required") ? "admin_required"
        : "forbidden";
      return errorResponse(403, sentinel);
    }
    if (error.code === "P0001") return errorResponse(400, "invalid_request");     // invalid_slot
    if (error.code === "P0002") return errorResponse(404, "evidence_not_found");  // claim/evidence not found
    console.error("admin_authorize_claim_evidence error:", error.code, error.message);
    return errorResponse(502, "upstream_error");
  }
  const row = Array.isArray(data) ? (data[0] as Record<string, unknown> | undefined) : undefined;
  const storagePath = row && typeof row.storage_path === "string" ? row.storage_path : "";
  const mimeType = row && typeof row.mime_type === "string" ? row.mime_type : "application/pdf";
  // Serving-guard ceiling, SOURCED from policy (the RPC reads upload_policy). Defensive-only — the bucket +
  // submit-RPC quotas are the real gates; this just caps a pathological object. bigint may arrive as a string.
  const maxUploadBytes = row && row.max_upload_bytes != null ? Number(row.max_upload_bytes) : FALLBACK_MAX_BYTES;
  if (!storagePath) {
    return errorResponse(404, "evidence_not_found");
  }

  // ---- 2. STREAM: service-role storage download of the ALREADY-AUTHORIZED path. Service role scoped to
  //         this endpoint's env, used ONLY for the storage read (not an RLS data bypass). ----
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !serviceKey) {
    console.error("claims/view_evidence: SUPABASE_URL / SUPABASE_SECRET_KEY not configured");
    return errorResponse(502, "config_error");
  }
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const { data: blob, error: dlErr } = await admin.storage.from(DOCUMENTS_BUCKET).download(storagePath);
  if (dlErr || !blob) {
    console.error("claims/view_evidence: storage download error:", dlErr?.message);
    return errorResponse(502, "storage_error");
  }
  if (blob.size > maxUploadBytes) {
    return errorResponse(413, "evidence_too_large");
  }

  // STREAM (not buffer): blob.stream() is a ReadableStream body, which Vercel serves WITHOUT the 4.5 MB
  // buffered-payload cap. Content-Length is known (blob.size) so the browser still gets a progress bar.
  return new Response(blob.stream(), {
    status: 200,
    headers: {
      "Content-Type": mimeType,
      "Content-Length": String(blob.size),
      "Content-Disposition": "inline",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
