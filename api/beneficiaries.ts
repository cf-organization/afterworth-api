/**
 * POST /api/beneficiaries
 *
 * Lists the beneficiaries for an estate the caller belongs to. Scoping is
 * enforced by RLS on public.beneficiaries (beneficiaries_read: owner_id =
 * auth.uid() OR user_id = auth.uid() OR is_estate_owner(estate_id)) — the authed
 * client only sees rows the caller is permitted to read:
 *   - the estate OWNER sees ALL beneficiary rows in the estate;
 *   - a BENEFICIARY-role caller sees ONLY their own stamped row (user_id =
 *     auth.uid()), so a beneficiary cannot read co-beneficiaries;
 *   - a non-member receives an empty list.
 * The user_id link is stamped by accept_invitation() when a beneficiary accepts
 * (matched by invitee email/phone within the estate).
 *
 * Request:
 *   Headers: Authorization: Bearer <Supabase JWT>, Content-Type: application/json
 *   Body:    { estateId: string (uuid) }
 *
 * Response (200):
 *   { beneficiaries: BeneficiaryWire[] }
 *
 * Errors: 401 auth, 400 bad body, 405 method, 502 upstream.
 */

import { enforce } from "../lib/rateLimit.js";
import {
  verifyJwt,
  getAuthedSupabaseClient,
  AuthError,
} from "../lib/auth.js";

interface BeneficiariesRequestBody {
  estateId: string;
}

// Raw row shape from public.beneficiaries (only the columns this endpoint reads).
// allocation_percent is Postgres `numeric`, which PostgREST may serialize as a
// string — coerced to a number in toWire.
interface BeneficiaryRow {
  id: string;
  estate_id: string;
  user_id: string | null;
  full_name: string | null;
  relationship: string | null;
  email: string | null;
  phone: string | null;
  allocation_percent: number | string | null;
  created_at: string | null;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Closed vocabulary of the iOS Beneficiary.Relationship enum. The DB column is
// free text, so an unmapped value would break the whole array decode on iOS —
// normalize to this set with an "other" fallback (see toWire).
const KNOWN_RELATIONSHIPS = new Set([
  "spouse",
  "child",
  "sibling",
  "parent",
  "partner",
  "attorney",
  "trustee",
  "other",
]);

function parseBody(raw: unknown): BeneficiariesRequestBody | null {
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

function normalizeRelationship(raw: string | null): string {
  const v = (raw ?? "").trim().toLowerCase();
  return KNOWN_RELATIONSHIPS.has(v) ? v : "other";
}

/**
 * Reshape a raw beneficiaries row into the wire shape the iOS Beneficiary decoder
 * expects (literal camelCase keys — JSONDecoder.afterworthAPI does NOT convert
 * from snake_case). Column renames: full_name -> name, allocation_percent ->
 * percentage. The DB is lean; see the per-field notes for what is derived vs.
 * defaulted vs. coalesced.
 */
function toWire(row: BeneficiaryRow): Record<string, unknown> {
  return {
    id: row.id,
    estateId: row.estate_id,
    userId: row.user_id,
    // name/email are non-optional String on iOS; coalesce nullable columns to ""
    // so a sparse row can't fail the whole array decode.
    name: row.full_name ?? "",
    email: row.email ?? "",
    phone: row.phone,
    // relationship: free-text column normalized to the iOS enum; unknown -> "other".
    relationship: normalizeRelationship(row.relationship),
    // numeric -> number (PostgREST may hand back a string).
    percentage:
      row.allocation_percent == null ? null : Number(row.allocation_percent),
    // status: DERIVED from real data — a stamped user_id means the invitee
    // accepted (accept_invitation links the row), so "active"; otherwise "invited".
    // (declined/revoked aren't representable from the beneficiaries row alone —
    // that lives on invitations, which this read slice does not join.)
    status: row.user_id != null ? "active" : "invited",
    // Honest defaults for model fields with NO DB column (carried, not gating):
    invitedAt: null, // no invited_at column
    acceptedAt: null, // no accepted_at column
    limitedDisclosureEnabled: true, // matches the model's default
    requiresManualReview: false, // matches the model's default
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
    if (err instanceof AuthError) {
      return authErrorResponse(err);
    }
    console.error("Unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  let body: BeneficiariesRequestBody | null;
  try {
    const raw = await req.json();
    body = parseBody(raw);
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "beneficiaries");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  // RLS scopes this select: owner sees all in-estate rows; a beneficiary sees
  // only their own stamped row; a non-member sees none.
  const { data, error } = await supabase
    .from("beneficiaries")
    .select(
      "id, estate_id, user_id, full_name, relationship, email, phone, allocation_percent, created_at"
    )
    .eq("estate_id", body.estateId)
    .order("created_at", { ascending: false });

  if (error) {
    console.error("beneficiaries select error:", error);
    return errorResponse(502, "upstream_error");
  }

  const rows = (data ?? []) as BeneficiaryRow[];
  const beneficiaries = rows.map(toWire);

  return jsonResponse(200, { beneficiaries });
}
