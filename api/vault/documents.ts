/**
 * POST /api/vault/documents
 *
 * Lists the documents for an estate the caller belongs to. Scoping is enforced
 * by RLS on public.documents (documents_read: owner_id = auth.uid() OR
 * is_estate_member(estate_id)) — the authed client only sees rows the caller is
 * permitted to read. A non-member receives an empty list.
 *
 * NOTE ON GATING: this lists all documents in the estate that the caller (as an
 * approved member or owner) may read — faithful to the current app behavior
 * (MockVaultService.scopedDocuments filters by estate only). Per-document
 * protected-disclosure gating (VisibilityTier / PolicyContext) is a separate
 * future layer and is NOT applied here.
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
 * Reshape a raw documents row into the wire shape the iOS EstateDocument
 * decoder expects. The DB is lean; fields without a column are given honest
 * defaults (they are carried as metadata, not enforced gating). doc_type is
 * passed through unchanged because the DB vocabulary now matches the iOS
 * DocumentCategory raw values exactly.
 */
function toWire(row: DocumentRow): Record<string, unknown> {
  return {
    id: row.id,
    estateId: row.estate_id,
    title: row.title,
    documentType: row.doc_type, // matches DocumentCategory raw values
    fileName: deriveFileName(row.storage_path, row.title),
    fileSizeBytes: row.size_bytes,
    uploadedAt: row.created_at,
    uploadedBy: row.owner_id,
    isVerified: false,
    // Honest defaults for fields with no DB column (carried, not gating):
    accessLevel: "ownerOnly",
    sensitivity: "medium",
    visibilityTier: "full_detail",
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

  // RLS scopes this select: caller sees rows only if owner or approved member.
  const { data, error } = await supabase
    .from("documents")
    .select(
      "id, estate_id, owner_id, doc_type, title, storage_path, mime_type, size_bytes, sha256, is_encrypted, created_at"
    )
    .eq("estate_id", body.estateId)
    .order("created_at", { ascending: false });

  if (error) {
    console.error("documents select error:", error);
    return errorResponse(502, "upstream_error");
  }

  const rows = (data ?? []) as DocumentRow[];
  const documents = rows.map(toWire);

  return jsonResponse(200, { documents });
}
