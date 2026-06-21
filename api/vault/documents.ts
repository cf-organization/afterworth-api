/**
 * POST /api/vault/documents
 *
 * Lists the documents an estate caller may see, with per-document access-grant
 * gating applied (access-grant model slice — db/migrations/0002_*; design in
 * docs/live-data-migration.md Appendix A).
 *
 * TWO ENFORCEMENT LAYERS (Appendix A.6):
 *   - ROW visibility = RLS (HARD). documents_read + can_access_document() decide
 *     which rows the caller sees at all. Owner sees all (inherent); a non-owner sees
 *     a row only through a covering, released, ceiling-satisfied grant. This is the
 *     real boundary and cannot be bypassed by the authed client.
 *   - FIELD masking = THIS endpoint (SOFT). For rows RLS lets through, title and the
 *     derived fileName are masked when the resolved visibility_tier is below
 *     full_detail. This relies on this endpoint being the ONLY read path on
 *     public.documents for `authenticated`. A second read path bypasses this masking
 *     unless it re-applies it (row visibility stays safe regardless).
 *
 * Tier resolution mirrors can_access_document(): owner (owner_id = caller) ->
 * full_detail; else per-document grant -> category 'estate_documents' grant ->
 * masked-by-default ('hidden'). RLS guarantees a non-owner row has a grant, so the
 * default only fires defensively.
 *
 * Request:
 *   Headers: Authorization: Bearer <Supabase JWT>, Content-Type: application/json
 *   Body:    { estateId: string (uuid) }
 *
 * Response (200):
 *   { documents: EstateDocumentWire[] }
 *
 * Errors: 401 auth, 400 bad body, 403 not a member, 405 method, 502 upstream.
 */

import { enforce } from "../../lib/rateLimit.js";
import {
  verifyJwt,
  getAuthedSupabaseClient,
  AuthError,
} from "../../lib/auth.js";

interface DocumentsRequestBody {
  estateId: string;
}

// Raw row shape from public.documents.
interface DocumentRow {
  id: string;
  estate_id: string;
  owner_id: string;
  doc_type: string;
  title: string;
  storage_path: string;
  mime_type: string | null;
  size_bytes: number | null;
  sha256: string | null;
  is_encrypted: boolean | null;
  created_at: string | null;
  sensitivity: string; // 5-level ladder (low|medium|high|restricted|sealed)
}

// The caller's own active grants in this estate (RLS scopes to grantee = auth.uid()).
interface GrantRow {
  document_id: string | null;
  category: string | null;
  visibility_tier: string;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function parseBody(raw: unknown): DocumentsRequestBody | null {
  if (raw === null || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.estateId !== "string") return null;
  const estateId = obj.estateId.trim();
  if (!UUID_RE.test(estateId)) return null;
  return { estateId };
}

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
    case "missing":
      return errorResponse(401, "missing_token");
    case "malformed":
      return errorResponse(401, "malformed_token");
    case "expired":
      return errorResponse(401, "expired_token");
    case "invalid":
      return errorResponse(401, "invalid_token");
  }
}

/**
 * Reshape a raw documents row into the wire shape the iOS EstateDocument decoder
 * expects, applying FIELD masking for the resolved visibility tier (Appendix A.6
 * soft layer). Below full_detail the specific title and the derived fileName are
 * withheld; documentType (the category) stays visible so the row is still
 * meaningfully listed. sensitivity and visibilityTier now carry REAL values from
 * the DB / resolution (no longer placeholders). doc_type passes through unchanged
 * because the DB vocabulary matches the iOS DocumentCategory raw values exactly.
 */
function toWire(row: DocumentRow, tier: string): Record<string, unknown> {
  const full = tier === "full_detail";
  return {
    id: row.id,
    estateId: row.estate_id,
    title: full ? row.title : "Protected Document",
    documentType: row.doc_type, // category stays visible even when masked
    fileName: full ? deriveFileName(row.storage_path, row.title) : null,
    fileSizeBytes: row.size_bytes,
    uploadedAt: row.created_at,
    uploadedBy: row.owner_id,
    isVerified: false,
    accessLevel: "ownerOnly", // legacy carried field, not gating
    sensitivity: row.sensitivity, // REAL — from documents.sensitivity
    visibilityTier: tier, // REAL — resolved per grant / owner inherency
    status: "active",
  };
}

function deriveFileName(storagePath: string, title: string): string {
  const parts = storagePath.split("/");
  const last = parts[parts.length - 1];
  if (last && last.length > 0) return last;
  return `${title}`;
}

export async function POST(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  let user;
  try {
    user = await verifyJwt(req);
  } catch (err) {
    if (err instanceof AuthError) {
      return authErrorResponse(err);
    }
    console.error("Unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  let body: DocumentsRequestBody | null;
  try {
    const raw = await req.json();
    body = parseBody(raw);
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "vault_documents");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  // RLS (documents_read) scopes this select to ROW visibility: owner sees all;
  // a non-owner sees a row only via a covering, released, ceiling-satisfied grant.
  const { data, error } = await supabase
    .from("documents")
    .select(
      "id, estate_id, owner_id, doc_type, title, storage_path, mime_type, size_bytes, sha256, is_encrypted, created_at, sensitivity"
    )
    .eq("estate_id", body.estateId)
    .order("created_at", { ascending: false });

  if (error) {
    console.error("documents select error:", error);
    return errorResponse(502, "upstream_error");
  }

  // The caller's own active grants in this estate (RLS scopes to grantee =
  // auth.uid()). Used only to resolve the FIELD-masking tier; row visibility was
  // already decided by RLS above.
  const callerId = user.userId.toLowerCase();
  const { data: grantData, error: grantError } = await supabase
    .from("access_grants")
    .select("document_id, category, visibility_tier")
    .eq("estate_id", body.estateId)
    .eq("grantee_user_id", callerId)
    .eq("status", "active");

  if (grantError) {
    console.error("access_grants select error:", grantError);
    return errorResponse(502, "upstream_error");
  }

  const perDocTier = new Map<string, string>();
  let categoryDocTier: string | null = null;
  for (const g of (grantData ?? []) as GrantRow[]) {
    if (g.document_id) {
      perDocTier.set(g.document_id, g.visibility_tier);
    } else if (g.category === "estate_documents") {
      categoryDocTier = g.visibility_tier;
    }
  }

  // Resolve the field-masking tier per row (mirrors can_access_document):
  // owner/creator -> full_detail; else per-doc grant -> category grant ->
  // masked-by-default ('hidden'). RLS guarantees a non-owner row has a grant, so
  // the 'hidden' default only fires defensively (safe-by-default, never leaks).
  const effectiveTier = (row: DocumentRow): string => {
    if (row.owner_id && row.owner_id.toLowerCase() === callerId) {
      return "full_detail";
    }
    return perDocTier.get(row.id) ?? categoryDocTier ?? "hidden";
  };

  const rows = (data ?? []) as DocumentRow[];
  const documents = rows.map((row) => toWire(row, effectiveTier(row)));

  return jsonResponse(200, { documents });
}
