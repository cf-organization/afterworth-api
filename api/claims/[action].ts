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

const ACTIONS = new Set(["view_evidence", "sweep_orphans", "purge_document"]);
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

// Map a 42501 admin-gate exception message to the specific sentinel (so the console can silent-refresh on a
// stale token); shared by both actions. auth/admin/mfa are terminal (re-auth / step-up).
function gateSentinel(msg: string): string {
  return msg.includes("stale_token_reauth_required") ? "stale_token_reauth_required"
    : msg.includes("mfa_required") ? "mfa_required"
    : msg.includes("admin_required") ? "admin_required"
    : "forbidden";
}

/**
 * action=sweep_orphans — reclaim `documents`-bucket objects with no authoritative row (interrupted-submit PII).
 * Body: { confirm?: boolean, graceHours?: number, max?: number }.
 *   DRY-RUN (default): list what WOULD be deleted (age > grace AND no documents row) + audit; delete nothing.
 *   confirm:true: service-role storage.remove the identified paths, then audit. NO UNDO — dry-run is the default.
 * Admin gate lives INSIDE list_orphan_storage_objects (a non-admin/aal1 caller is denied there). Byte deletion
 * MUST use the storage API (a SQL row delete does not delete the S3 bytes), hence the service-role client here.
 */
async function handleSweepOrphans(req: Request, jwt: string, o: Record<string, unknown>): Promise<Response> {
  const rl = await enforce(req, "claims_sweep_orphans");
  if (rl) return rl;

  const confirm = o.confirm === true;
  const graceHours = typeof o.graceHours === "number" && Number.isFinite(o.graceHours) ? Math.floor(o.graceHours) : 72;
  const max = typeof o.max === "number" && Number.isFinite(o.max) ? Math.floor(o.max) : 100;

  const authed = getAuthedSupabaseClient(jwt);

  // 1. IDENTIFY (admin gate inside the RPC). Both doors: a direct rest/v1/rpc caller hits the same gate.
  const { data, error } = await authed.rpc("list_orphan_storage_objects", { p_grace_hours: graceHours, p_max: max });
  if (error) {
    if (error.code === "42501") return errorResponse(403, gateSentinel(error.message ?? ""));
    console.error("list_orphan_storage_objects error:", error.code, error.message);
    return errorResponse(502, "upstream_error");
  }
  const rows = Array.isArray(data) ? (data as Array<Record<string, unknown>>) : [];
  const paths = rows.map((r) => String(r.object_name)).filter((p) => p.length > 0);

  // 2a. DRY-RUN (default) — audit + return the would-delete list. Delete nothing.
  if (!confirm) {
    const { error: aErr } = await authed.rpc("record_orphan_sweep", { p_mode: "dry_run", p_paths: paths, p_grace_hours: graceHours, p_batch_cap: max });
    if (aErr) console.error("record_orphan_sweep(dry_run) error:", aErr.code, aErr.message);
    return jsonResponse(200, { mode: "dry_run", count: paths.length, orphans: rows });
  }

  // 2b. CONFIRM — service-role storage remove of the identified paths, then audit. Byte deletion needs the API.
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !serviceKey) {
    console.error("sweep_orphans: SUPABASE_URL / SUPABASE_SECRET_KEY not configured");
    return errorResponse(502, "config_error");
  }
  if (paths.length > 0) {
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const { error: rmErr } = await admin.storage.from(DOCUMENTS_BUCKET).remove(paths);
    if (rmErr) {
      console.error("sweep_orphans: storage remove error:", rmErr.message);
      return errorResponse(502, "storage_error");
    }
  }
  // Audit AFTER the (irreversible) delete. Best-effort: a failed audit is logged, never fails a completed delete.
  const { error: aErr } = await authed.rpc("record_orphan_sweep", { p_mode: "delete", p_paths: paths, p_grace_hours: graceHours, p_batch_cap: max });
  if (aErr) console.error("record_orphan_sweep(delete) error:", aErr.code, aErr.message);
  return jsonResponse(200, { mode: "delete", deleted: paths.length, paths });
}

/**
 * purge_document — the CLIENT-IMMEDIATE byte purge after delete_vault_document / replace_vault_document (which
 * committed the outbox row in-tx). Owner-gated INSIDE the RPCs (authorize_purge / record_purge_result); the
 * service-role storage.remove is confined to this endpoint (only place with the key). Idempotent: storage
 * remove of a missing key is a no-op, and a purged outbox row can't be re-authorized. This is the FAST path;
 * the GET cron drain + the 72h orphan sweeper are the reliability backstops.
 * Body: { outboxId: uuid } (the id returned by delete/replace).
 */
async function handlePurgeDocument(req: Request, jwt: string, o: Record<string, unknown>): Promise<Response> {
  const rl = await enforce(req, "claims_purge_document");
  if (rl) return rl;

  const outboxId = typeof o.outboxId === "string" ? o.outboxId.trim() : "";
  if (!UUID_RE.test(outboxId)) return errorResponse(400, "invalid_request");

  const authed = getAuthedSupabaseClient(jwt);

  // 1. AUTHORIZE (owner gate inside the RPC) — returns the object to remove + bumps attempts.
  const { data, error } = await authed.rpc("authorize_purge", { p_outbox_id: outboxId });
  if (error) {
    if (error.code === "42501") return errorResponse(403, "forbidden");
    if (error.code === "P0002") return errorResponse(404, "outbox_not_found");
    console.error("authorize_purge error:", error.code, error.message);
    return errorResponse(502, "upstream_error");
  }
  const row = Array.isArray(data) ? (data[0] as Record<string, unknown> | undefined) : undefined;
  const bucket = row && typeof row.v_bucket === "string" ? row.v_bucket : DOCUMENTS_BUCKET;
  const path = row && typeof row.v_path === "string" ? row.v_path : "";
  if (!path) return errorResponse(404, "outbox_not_found");

  // 2. REMOVE bytes (service role — the only place with the key; used ONLY for the storage op).
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !serviceKey) {
    console.error("purge_document: SUPABASE_URL / SUPABASE_SECRET_KEY not configured");
    return errorResponse(502, "config_error");
  }
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { error: rmErr } = await admin.storage.from(bucket).remove([path]);

  // 3. RECORD the result (owner gate). ok -> purged; not-ok -> failed (re-drainable by the cron/sweeper).
  const { error: recErr } = await authed.rpc("record_purge_result", {
    p_outbox_id: outboxId,
    p_ok: !rmErr,
    p_error: rmErr ? rmErr.message : null,
  });
  if (recErr) console.error("record_purge_result error:", recErr.code, recErr.message);

  if (rmErr) {
    console.error("purge_document: storage remove error:", rmErr.message);
    return errorResponse(502, "storage_error");
  }
  return jsonResponse(200, { purged: true });
}

/**
 * GET /api/claims/drain_purge_outbox — the SCHEDULED reliability backstop (Vercel Cron), CRON_SECRET-gated.
 * Drains pending/failed purge-outbox rows via the service role (the born-clean table grants select+update to
 * service_role). On Hobby, cron frequency is plan-limited (daily); the CLIENT-immediate purge is the primary
 * "not retained" path, and the 72h orphan sweeper is the FINAL catch-all. Tighten the schedule on Pro.
 */
export async function GET(req: Request): Promise<Response> {
  const action = actionFromUrl(req.url);
  if (action !== "drain_purge_outbox") return errorResponse(404, "not_found");

  // Vercel Cron sends `Authorization: Bearer $CRON_SECRET` automatically when CRON_SECRET is configured.
  const cronSecret = process.env.CRON_SECRET;
  const auth = req.headers.get("authorization");
  if (!cronSecret || auth !== `Bearer ${cronSecret}`) return errorResponse(401, "unauthorized");

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !serviceKey) return errorResponse(502, "config_error");
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const MAX_ATTEMPTS = 10;
  const BATCH = 50;
  const { data: rows, error } = await admin
    .from("storage_deletion_outbox")
    .select("id,bucket,object_path,attempts")
    .neq("status", "purged")
    .lt("attempts", MAX_ATTEMPTS)
    .order("requested_at", { ascending: true })
    .limit(BATCH);
  if (error) {
    console.error("drain_purge_outbox: select error:", error.message);
    return errorResponse(502, "upstream_error");
  }

  let purged = 0;
  let failed = 0;
  for (const r of rows ?? []) {
    const id = r.id as string;
    const bucket = (r.bucket as string) || DOCUMENTS_BUCKET;
    const path = r.object_path as string;
    const attempts = ((r.attempts as number) ?? 0) + 1;
    const { error: rmErr } = await admin.storage.from(bucket).remove([path]);
    if (rmErr) {
      await admin.from("storage_deletion_outbox")
        .update({ status: "failed", attempts, last_error: rmErr.message }).eq("id", id);
      failed++;
    } else {
      await admin.from("storage_deletion_outbox")
        .update({ status: "purged", purged_at: new Date().toISOString(), attempts, last_error: null }).eq("id", id);
      purged++;
    }
  }
  return jsonResponse(200, { drained: (rows ?? []).length, purged, failed });
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

  if (action === "sweep_orphans") {
    return handleSweepOrphans(req, user.jwt, o);
  }

  if (action === "purge_document") {
    return handlePurgeDocument(req, user.jwt, o);
  }

  // ---- view_evidence ----
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
